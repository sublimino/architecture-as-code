import json
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from audit_anchor.anchor import (
    AnchorError,
    FileAnchorStore,
    IntegrityError,
    build_statement,
    key_id,
    sign_envelope,
)
from audit_anchor.checkpoint import (
    GENESIS_DIGEST,
    VerificationResult,
    build_checkpoint,
    verify_against_reader,
    verify_chain_structure,
)
from audit_anchor.segments import (
    SEGMENT_PREDICATE_TYPE,
    SEGMENT_SCOPE,
    JournalSegmentDigestReader,
    SegmentDigestReader,
    TrustedKeyring,
    write_high_water,
)
from audit_anchor.cli import (
    _load_segment_chain,
    _load_trusted_chain,
    _passes_gate,
    _sources_pass_gate,
    _sources_prove_anything,
    main,
)


def _fixture(tmp_path, count=3, keys=None):
    root = tmp_path / "objects"
    attestations = tmp_path / "attestations"
    root.mkdir()
    attestations.mkdir()
    keys = keys or [ed25519.Ed25519PrivateKey.generate()]
    records = []
    for sequence in range(1, count + 1):
        private = keys[min(sequence - 1, len(keys) - 1)]
        segment_id = f"signaldb/observations/{sequence:02d}/data.parquet"
        data = f"parquet-{sequence}".encode()
        path = root / segment_id
        path.parent.mkdir(parents=True)
        path.write_bytes(data)
        import hashlib

        record = {
            "schema_version": "signalloom.segment/v1",
            "sequence": sequence,
            "segment_id": segment_id,
            "digest": hashlib.sha256(data).hexdigest(),
            "byte_length": len(data),
            "signer_key_id": key_id(private.public_key()),
            "state": "ok",
            "error": "",
            "attestation": f"attestations/{sequence:020d}.dsse.json",
            "checkpoint_inclusion": None,
        }
        predicate = {k: v for k, v in record.items() if k not in {"attestation", "checkpoint_inclusion"}}
        statement = {
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [{"name": segment_id, "digest": {"sha256": record["digest"]}}],
            "predicateType": SEGMENT_PREDICATE_TYPE,
            "predicate": predicate,
        }
        (tmp_path / record["attestation"]).write_text(json.dumps(sign_envelope(statement, private)))
        records.append(record)
    journal = tmp_path / "segments.jsonl"
    journal.write_text("".join(json.dumps(record) + "\n" for record in records))
    keyring = TrustedKeyring.from_public_keys([key.public_key() for key in keys])
    return root, journal, attestations, records, keyring


def _reader(tmp_path, **kwargs):
    root, journal, attestations, records, keyring = _fixture(tmp_path, **kwargs)
    return JournalSegmentDigestReader(journal, root, keyring), root, journal, attestations, records, keyring


def test_reader_satisfies_window_interface_and_reuses_checkpoint_merkle(tmp_path):
    reader, *_ = _reader(tmp_path)
    assert isinstance(reader, SegmentDigestReader)
    rows = reader.fetch_window("signaldb/observations", None, "00000000000000000003")
    checkpoint = build_checkpoint(rows, index=0, prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None, window_end_inclusive="00000000000000000003",
        cumulative_row_count_before=0, tenant_scope="signaldb/observations",
        boundary_basis="segment_sequence")
    result = verify_against_reader([checkpoint], reader)
    assert result.intact and result.proves_anything and result.unanchored_row_count == 0


def test_checkpoint_inclusion_field_is_optional(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path, count=1)
    records[0].pop("checkpoint_inclusion")
    journal.write_text(json.dumps(records[0]) + "\n")
    assert len(reader.fetch_window("signaldb/observations", None, "00000000000000000001")) == 1


def test_persisted_byte_flip_is_detected(tmp_path):
    reader, root, *_ = _reader(tmp_path)
    (root / "signaldb/observations/02/data.parquet").write_bytes(b"changed!!")
    with pytest.raises(AnchorError, match="persisted byte digest"):
        reader.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_signed_digest_swap_is_rejected(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path)
    records[0]["digest"], records[1]["digest"] = records[1]["digest"], records[0]["digest"]
    journal.write_text("".join(json.dumps(record) + "\n" for record in records))
    with pytest.raises(AnchorError, match="digest"):
        reader.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_reordered_journal_is_rejected(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path)
    journal.write_text(json.dumps(records[1]) + "\n" + json.dumps(records[0]) + "\n")
    with pytest.raises(AnchorError, match="sequence"):
        reader.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_historical_rotation_accepts_both_pinned_keys(tmp_path):
    keys = [ed25519.Ed25519PrivateKey.generate(), ed25519.Ed25519PrivateKey.generate()]
    reader, *_ = _reader(tmp_path, count=2, keys=keys)
    reader.keyring.expected = {key_id(key.public_key()) for key in keys}
    assert len(reader.fetch_window("signaldb/observations", None, "00000000000000000002")) == 2


def test_loaded_key_is_rejected_when_its_identifier_is_not_expected(tmp_path):
    reader, *_ = _reader(tmp_path, count=1)
    reader.keyring.expected = set()
    with pytest.raises(IntegrityError, match="not pinned"):
        reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000001")


def test_key_replacement_is_rejected(tmp_path):
    reader, _, _, _, _, _ = _reader(tmp_path)
    replacement = ed25519.Ed25519PrivateKey.generate().public_key()
    reader.keyring = TrustedKeyring.from_public_keys([replacement])
    with pytest.raises(AnchorError, match="not pinned"):
        reader.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_revoked_historical_key_is_rejected(tmp_path):
    keys = [ed25519.Ed25519PrivateKey.generate(), ed25519.Ed25519PrivateKey.generate()]
    reader, *_ = _reader(tmp_path, count=2, keys=keys)
    reader.keyring.revoked.add(key_id(keys[0].public_key()))
    with pytest.raises(AnchorError, match="revoked"):
        reader.fetch_window("signaldb/observations", None, "00000000000000000002")


def test_tail_truncation_is_detected_by_protected_high_water(tmp_path):
    reader, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    journal.write_text("".join(json.dumps(record) + "\n" for record in records[:-1]))
    guarded = JournalSegmentDigestReader(journal, root, keyring, high_water_path=high_water,
                                         checkpoint_count=lambda: 2)
    with pytest.raises(AnchorError, match="high-water"):
        guarded.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_unknown_persisted_segment_is_rejected(tmp_path):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    unknown = root / SEGMENT_SCOPE / "new-rotation" / "data.parquet"
    unknown.parent.mkdir(parents=True)
    unknown.write_bytes(b"not journaled")
    guarded = JournalSegmentDigestReader(
        journal, root, keyring, high_water_path=high_water, checkpoint_count=lambda: 2
    )
    with pytest.raises(IntegrityError, match="inventory contains unknown"):
        guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")


def test_genesis_historical_segment_is_exempt_but_must_remain(tmp_path):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    historical_id = f"{SEGMENT_SCOPE}/old-rotation/data.parquet"
    historical = root / historical_id
    historical.parent.mkdir(parents=True)
    historical.write_bytes(b"before hook installation")
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(
        high_water,
        records,
        journal,
        attestations,
        checkpoint_count=2,
        historical_segments=[historical_id],
    )
    guarded = JournalSegmentDigestReader(
        journal, root, keyring, high_water_path=high_water, checkpoint_count=lambda: 2
    )
    assert len(guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")) == 3
    historical.unlink()
    with pytest.raises(IntegrityError, match="inventory is missing"):
        guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")


@pytest.mark.parametrize("lost_error_count", [1, 17])
def test_protected_lost_error_count_is_divergence(tmp_path, lost_error_count):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(
        high_water,
        records,
        journal,
        attestations,
        checkpoint_count=2,
        lost_error_count=lost_error_count,
    )
    guarded = JournalSegmentDigestReader(
        journal, root, keyring, high_water_path=high_water, checkpoint_count=lambda: 2
    )
    with pytest.raises(IntegrityError, match="lost segment errors"):
        guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")


@pytest.mark.parametrize(
    ("field", "value"),
    [("historical_segments", [1]), ("lost_error_count", True)],
)
def test_malformed_protected_inventory_fields_are_rejected(tmp_path, field, value):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    state = json.loads(high_water.read_text())
    state[field] = value
    high_water.write_text(json.dumps(state))
    guarded = JournalSegmentDigestReader(
        journal, root, keyring, high_water_path=high_water, checkpoint_count=lambda: 2
    )
    with pytest.raises(AnchorError, match=field):
        guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")


def test_go_omitted_zero_value_inventory_fields_are_accepted(tmp_path):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    state = json.loads(high_water.read_text())
    state.pop("historical_segments")
    state.pop("lost_error_count")
    high_water.write_text(json.dumps(state))
    guarded = JournalSegmentDigestReader(
        journal, root, keyring, high_water_path=high_water, checkpoint_count=lambda: 2
    )
    assert len(guarded.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")) == 3


def test_attestation_removal_is_detected_by_high_water(tmp_path):
    reader, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    (tmp_path / records[-1]["attestation"]).unlink()
    guarded = JournalSegmentDigestReader(journal, root, keyring, high_water_path=high_water,
                                         checkpoint_count=lambda: 2)
    with pytest.raises(AnchorError, match="attestation"):
        guarded.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_checkpoint_removal_is_detected_by_high_water(tmp_path):
    _, root, journal, attestations, records, keyring = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    guarded = JournalSegmentDigestReader(journal, root, keyring, high_water_path=high_water,
                                         checkpoint_count=lambda: 1)
    with pytest.raises(AnchorError, match="checkpoint inventory"):
        guarded.fetch_window("signaldb/observations", None, "00000000000000000003")


def test_high_water_writer_refuses_checkpoint_count_rollback(tmp_path):
    _, _, journal, attestations, records, _ = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    with pytest.raises(IntegrityError, match="checkpoint_count"):
        write_high_water(high_water, records, journal, attestations, checkpoint_count=1)


def test_high_water_writer_refuses_segment_count_rollback(tmp_path):
    _, _, journal, attestations, records, _ = _reader(tmp_path)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=2)
    journal.write_text("".join(json.dumps(record) + "\n" for record in records[:-1]))
    with pytest.raises(IntegrityError, match="max_sequence"):
        write_high_water(
            high_water, records[:-1], journal, attestations, checkpoint_count=2
        )


def test_checkpoint_root_swap_diverges(tmp_path):
    reader, *_ = _reader(tmp_path)
    rows = reader.fetch_window("signaldb/observations", None, "00000000000000000003")
    checkpoint = build_checkpoint(rows, index=0, prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None, window_end_inclusive="00000000000000000003",
        cumulative_row_count_before=0, tenant_scope="signaldb/observations",
        boundary_basis="segment_sequence")
    forged = checkpoint.__class__.from_predicate({**checkpoint.to_predicate(), "merkle_root": "00" * 32})
    assert not verify_against_reader([forged], reader).intact


def test_unsigned_checkpoint_inclusion_row_edit_diverges(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path, count=1)
    rows = reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000001")
    checkpoint = build_checkpoint(
        rows,
        index=0,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive="00000000000000000001",
        cumulative_row_count_before=0,
        tenant_scope=SEGMENT_SCOPE,
        boundary_basis="segment_sequence",
    )
    records[0]["checkpoint_inclusion"] = {"checkpoint_index": 0, "leaf_index": 99}
    journal.write_text(json.dumps(records[0]) + "\n")
    result = verify_against_reader([checkpoint], reader)
    assert [divergence.kind for divergence in result.divergences] == [
        "merkle_root_mismatch"
    ]


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("tenant_scope", "*", "tenant scope"),
        ("boundary_basis", "xact_clamp", "subject name"),
        ("window_end_inclusive", "3", "twenty-digit"),
    ],
)
def test_segment_checkpoint_rejects_incompatible_boundaries(
    tmp_path, field, value, message
):
    private = ed25519.Ed25519PrivateKey.generate()
    reader, *_ = _reader(tmp_path, keys=[private])
    rows = reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000003")
    checkpoint = build_checkpoint(
        rows,
        index=0,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive="00000000000000000003",
        cumulative_row_count_before=0,
        tenant_scope=SEGMENT_SCOPE,
        boundary_basis="segment_sequence",
    )
    incompatible = checkpoint.__class__.from_predicate(
        {**checkpoint.to_predicate(), field: value}
    )
    store = FileAnchorStore(tmp_path / "anchors")
    statement = build_statement(incompatible)
    statement["subject"][0]["name"] = (
        f"signalloom-segment-checkpoint/{incompatible.tenant_scope}/00000000"
    )
    store.publish(incompatible, sign_envelope(statement, private))
    keyring = TrustedKeyring.from_public_keys(
        [private.public_key()], expected=[key_id(private.public_key())]
    )
    with pytest.raises(IntegrityError, match=message):
        _load_segment_chain(store, keyring)


def test_first_checkpoint_signed_count_must_equal_its_window_count(tmp_path):
    reader, *_ = _reader(tmp_path, count=1)
    rows = reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000001")
    checkpoint = build_checkpoint(
        rows,
        index=0,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive="00000000000000000001",
        cumulative_row_count_before=0,
        tenant_scope=SEGMENT_SCOPE,
        boundary_basis="segment_sequence",
    )
    rolled_back = checkpoint.__class__.from_predicate(
        {**checkpoint.to_predicate(), "cumulative_row_count": 0}
    )
    assert {issue.kind for issue in verify_chain_structure([rolled_back])} == {
        "cumulative_mismatch"
    }


def test_failed_segment_state_is_explicit_divergence(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path, count=1)
    records[0]["state"] = "error"
    records[0]["error"] = "object upload failed"
    journal.write_text(json.dumps(records[0]) + "\n")
    with pytest.raises(IntegrityError, match="object upload failed"):
        reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000001")


def test_pending_segment_state_is_operational_failure(tmp_path):
    reader, _, journal, _, records, _ = _reader(tmp_path, count=1)
    records[0]["state"] = "pending"
    journal.write_text(json.dumps(records[0]) + "\n")
    with pytest.raises(AnchorError, match="remains pending") as excinfo:
        reader.fetch_window(SEGMENT_SCOPE, None, "00000000000000000001")
    assert not isinstance(excinfo.value, IntegrityError)


@pytest.mark.parametrize(
    "checkpoints,unanchored,expected",
    [(1, 0, True), (0, 0, False), (1, 1, False)],
)
def test_json_success_gate_requires_positive_complete_evidence(checkpoints, unanchored, expected):
    result = VerificationResult([], [], 3, unanchored, checkpoints)
    assert _passes_gate(result) is expected


def test_combined_gate_requires_positive_evidence_from_each_source():
    positive = VerificationResult([], [], 3, 0, 1)
    absent = VerificationResult([], [], 0, 0, 0)
    mutated = VerificationResult([], [object()], 3, 0, 1)
    assert _sources_pass_gate([("audit", positive), ("segments", positive)])
    assert not _sources_pass_gate([("audit", absent), ("segments", positive)])
    assert not _sources_pass_gate([("audit", positive), ("segments", absent)])
    assert not _sources_pass_gate([("audit", positive), ("segments", mutated)])
    assert not _sources_prove_anything([("audit", absent), ("segments", positive)])


def _audit_checkpoint(rows, index, previous, start, end):
    return build_checkpoint(
        rows,
        index=index,
        prev_checkpoint_digest=previous,
        window_start_exclusive=start,
        window_end_inclusive=end,
        cumulative_row_count_before=index,
        tenant_scope="tenant-demo",
        boundary_basis="xact_clamp",
    )


def test_audit_historical_keyring_requires_pins_and_respects_revocation(tmp_path):
    keys = [ed25519.Ed25519PrivateKey.generate(), ed25519.Ed25519PrivateKey.generate()]
    row1 = {"id": "1", "tenant_id": "tenant-demo", "ts": "1", "event_type": "x",
            "agent_id": None, "agent_name": None, "actor": "a", "detail": "{}"}
    row2 = {**row1, "id": "2", "ts": "2"}
    first = _audit_checkpoint([row1], 0, GENESIS_DIGEST, None, "1")
    second = _audit_checkpoint([row2], 1, first.digest(), "1", "2")
    store = FileAnchorStore(tmp_path / "anchors")
    store.publish(first, sign_envelope(build_statement(first), keys[0]))
    store.publish(second, sign_envelope(build_statement(second), keys[1]))
    identifiers = {key_id(key.public_key()) for key in keys}
    trusted = TrustedKeyring.from_public_keys(
        [key.public_key() for key in keys], expected=identifiers
    )
    assert len(_load_trusted_chain(store, trusted, "signalloom-audit-checkpoint/")) == 2
    trusted.expected.remove(key_id(keys[0].public_key()))
    with pytest.raises(IntegrityError, match="not pinned"):
        _load_trusted_chain(store, trusted, "signalloom-audit-checkpoint/")
    trusted.expected = identifiers
    trusted.revoked.add(key_id(keys[0].public_key()))
    with pytest.raises(IntegrityError, match="revoked"):
        _load_trusted_chain(store, trusted, "signalloom-audit-checkpoint/")


def test_cli_requires_expected_signer_for_audit_verification(tmp_path, capsys):
    exit_code = main([
        "--source", "audit",
        "--dsn", "postgres://unused",
        "--public-key", str(tmp_path / "replacement.pem"),
        "verify", "--json",
    ])
    assert exit_code == 1
    assert "--expected-key-id" in json.loads(capsys.readouterr().out)["error"]


def test_cli_byte_tamper_exits_two_with_diverged_json(tmp_path, monkeypatch, capsys):
    reader, root, journal, attestations, records, keyring = _reader(tmp_path)
    public = next(iter(keyring.keys.values()))
    public_path = tmp_path / "public.pem"
    public_path.write_bytes(public.public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
    (root / "signaldb/observations/02/data.parquet").write_bytes(b"changed!!")
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=0)
    monkeypatch.setenv("AUDIT_ANCHOR_DIR", str(tmp_path / "anchors"))
    exit_code = main([
        "--source", "segments",
        "--public-key", str(public_path),
        "--expected-key-id", key_id(public),
        "--segment-journal", str(journal),
        "--segment-root", str(root),
        "--protected-high-water", str(high_water),
        "verify", "--json",
    ])
    output = json.loads(capsys.readouterr().out)
    assert exit_code == 2
    assert output["status"] == "diverged"


def _publish_segment_checkpoint(tmp_path, private, reader, boundary="00000000000000000003"):
    rows = reader.fetch_window(SEGMENT_SCOPE, None, boundary)
    checkpoint = build_checkpoint(
        rows,
        index=0,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive=boundary,
        cumulative_row_count_before=0,
        tenant_scope=SEGMENT_SCOPE,
        boundary_basis="segment_sequence",
    )
    FileAnchorStore(tmp_path / "anchors").publish(
        checkpoint, sign_envelope(build_statement(checkpoint), private)
    )


def test_cli_intact_segments_json_proves_complete_evidence(tmp_path, monkeypatch, capsys):
    private = ed25519.Ed25519PrivateKey.generate()
    reader, root, journal, attestations, records, _ = _reader(tmp_path, keys=[private])
    _publish_segment_checkpoint(tmp_path, private, reader)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=1)
    public = private.public_key()
    public_path = tmp_path / "public.pem"
    public_path.write_bytes(public.public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
    monkeypatch.setenv("AUDIT_ANCHOR_DIR", str(tmp_path / "anchors"))

    exit_code = main([
        "--source", "segments",
        "--public-key", str(public_path),
        "--expected-key-id", key_id(public),
        "--segment-journal", str(journal),
        "--segment-root", str(root),
        "--protected-high-water", str(high_water),
        "verify", "--json",
    ])

    output = json.loads(capsys.readouterr().out)
    assert exit_code == 0
    assert output["status"] == "intact"
    assert output["proves_anything"] is True
    assert output["checkpoints_checked"] > 0
    assert output["unanchored_row_count"] == 0


def test_cli_operational_failure_is_json_error_not_divergence(tmp_path, capsys):
    exit_code = main([
        "--source", "segments",
        "--segment-journal", str(tmp_path / "missing.jsonl"),
        "--expected-key-id", "00" * 32,
        "--protected-high-water", str(tmp_path / "high-water.json"),
        "verify", "--json",
    ])
    output = json.loads(capsys.readouterr().out)
    assert exit_code == 1
    assert output["status"] == "error"
    assert "divergences" not in output


def test_cli_rejects_segment_key_without_expected_identifier(tmp_path, capsys):
    exit_code = main([
        "--source", "segments",
        "--segment-journal", str(tmp_path / "missing.jsonl"),
        "--protected-high-water", str(tmp_path / "high-water.json"),
        "verify", "--json",
    ])
    output = json.loads(capsys.readouterr().out)
    assert exit_code == 1
    assert output["status"] == "error"
    assert "--expected-key-id" in output["error"]


def test_source_all_remains_accepted_as_compatibility_alias(monkeypatch):
    seen = {}

    async def fake_verify(args):
        seen["source"] = args.source
        return 0

    monkeypatch.setattr("audit_anchor.cli.cmd_verify", fake_verify)
    assert main(["--source", "all", "--dsn", "postgres://unused", "verify"]) == 0
    assert seen["source"] == "both"


def test_source_both_verifies_real_audit_and_segment_chains_once(
    tmp_path, monkeypatch, capsys
):
    private = ed25519.Ed25519PrivateKey.generate()
    public = private.public_key()
    reader, root, journal, attestations, records, _ = _reader(tmp_path, keys=[private])
    _publish_segment_checkpoint(tmp_path, private, reader)
    high_water = tmp_path / ".keys" / "segments-high-water.json"
    write_high_water(high_water, records, journal, attestations, checkpoint_count=1)

    audit_rows = [{
        "id": "00000000-0000-0000-0000-000000000001",
        "tenant_id": "tenant-demo",
        "ts": "2026-09-05T18:00:00.000000Z",
        "event_type": "agent.created",
        "agent_id": None,
        "agent_name": "Verifier",
        "actor": "tester",
        "detail": "{}",
    }]
    audit_checkpoint = build_checkpoint(
        audit_rows,
        index=0,
        prev_checkpoint_digest=GENESIS_DIGEST,
        window_start_exclusive=None,
        window_end_inclusive="2026-09-05T18:00:01.000000Z",
        cumulative_row_count_before=0,
        tenant_scope="tenant-demo",
        boundary_basis="xact_clamp",
    )
    audit_reference = FileAnchorStore(tmp_path / "anchors").publish(
        audit_checkpoint, sign_envelope(build_statement(audit_checkpoint), private)
    )

    class AuditReader:
        def fetch_window(self, tenant_scope, start_exclusive, end_inclusive):
            return [
                row for row in audit_rows
                if tenant_scope in ("*", row["tenant_id"])
                and (start_exclusive is None or row["ts"] > start_exclusive)
                and row["ts"] <= end_inclusive
            ]

    class Connection:
        async def close(self):
            pass

    async def fake_connect(_dsn):
        return Connection()

    async def fake_load(_conn, _scope):
        return AuditReader()

    public_path = tmp_path / "public.pem"
    public_path.write_bytes(public.public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
    monkeypatch.setenv("AUDIT_ANCHOR_DIR", str(tmp_path / "anchors"))
    monkeypatch.setattr("audit_anchor.cli._connect", fake_connect)
    monkeypatch.setattr("audit_anchor.cli.AsyncpgAuditLogReader.load", fake_load)

    arguments = [
        "--source", "both",
        "--dsn", "postgres://unused",
        "--public-key", str(public_path),
        "--expected-key-id", key_id(public),
        "--segment-journal", str(journal),
        "--segment-root", str(root),
        "--protected-high-water", str(high_water),
        "verify", "--json",
    ]
    exit_code = main(arguments)
    output = json.loads(capsys.readouterr().out)
    assert exit_code == 0
    assert output["status"] == "intact"
    assert output["checkpoints_checked"] == 2
    assert output["anchored_row_count"] == 4
    assert output["unanchored_row_count"] == 0
    assert output["proves_anything"] is True

    segment = root / records[0]["segment_id"]
    original_segment = segment.read_bytes()
    segment.write_bytes(b"mutated")
    assert main(arguments) == 2
    assert json.loads(capsys.readouterr().out)["status"] == "diverged"
    segment.write_bytes(original_segment)

    attestation = tmp_path / records[0]["attestation"]
    original_attestation = attestation.read_text()
    unsigned = json.loads(original_attestation)
    unsigned["signatures"] = []
    attestation.write_text(json.dumps(unsigned))
    assert main(arguments) == 2
    assert json.loads(capsys.readouterr().out)["status"] == "diverged"
    attestation.write_text(original_attestation)

    Path(audit_reference).unlink()
    assert main(arguments) == 2
    output = json.loads(capsys.readouterr().out)
    assert output["status"] == "diverged"
    assert output["proves_anything"] is False
