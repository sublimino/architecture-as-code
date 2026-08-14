"""Checkpoint construction, chaining, and divergence localisation.

These run against an in-memory reader rather than Postgres, so they cover the
logic without needing a cluster.  The live proof -- insert, checkpoint, tamper
with the row directly in the database, watch the verifier go red -- is
scripts/audit-anchor-tamper-demo.sh, and it is the one that actually matters.
A verifier nobody has watched fail is not a verifier.
"""
import pytest

from audit_anchor.canonical import encode_row, leaf_hash
from audit_anchor.checkpoint import (
    GENESIS_DIGEST,
    Checkpoint,
    ChainError,
    build_checkpoint,
    verify_against_reader,
    verify_chain_structure,
)


def _row(seq: int, *, actor="demo-actor", detail=None):
    return {
        "id": f"00000000-0000-0000-0000-{seq:012d}",
        "tenant_id": "tenant-demo",
        "ts": f"2026-08-13T22:00:{seq:02d}.000000Z",
        "event_type": "agent.stunned",
        "agent_id": None,
        "agent_name": "Cardvault Agent",
        "actor": actor,
        "detail": detail or '{"outcome": "stunned"}',
    }


class FakeReader:
    """Stands in for the audit table. Windows are (start, end] on `ts`."""

    def __init__(self, rows):
        self.rows = list(rows)

    def fetch_window(self, tenant_scope, start_exclusive, end_inclusive):
        return [
            r
            for r in self.rows
            if (start_exclusive is None or r["ts"] > start_exclusive)
            and r["ts"] <= end_inclusive
            and (tenant_scope == "*" or r["tenant_id"] == tenant_scope)
        ]


def _chain(reader, boundaries, tenant_scope="*"):
    """Build a checkpoint chain at the given window boundaries."""
    checkpoints = []
    prev_digest, prev_end, cumulative = GENESIS_DIGEST, None, 0
    for i, end in enumerate(boundaries):
        rows = reader.fetch_window(tenant_scope, prev_end, end)
        cp = build_checkpoint(
            rows,
            index=i,
            prev_checkpoint_digest=prev_digest,
            window_start_exclusive=prev_end,
            window_end_inclusive=end,
            cumulative_row_count_before=cumulative,
            tenant_scope=tenant_scope,
            boundary_basis="xact_clamp",
        )
        checkpoints.append(cp)
        prev_digest, prev_end, cumulative = cp.digest(), end, cp.cumulative_row_count
    return checkpoints


# ══════════════════════════════════════════════════════════════════════════════
# Digest determinism
# ══════════════════════════════════════════════════════════════════════════════


def test_checkpoint_digest_is_deterministic():
    rows = [_row(1), _row(2)]
    a = build_checkpoint(rows, index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                         window_start_exclusive=None, window_end_inclusive="2026-08-13T22:01:00.000000Z",
                         cumulative_row_count_before=0, tenant_scope="*", boundary_basis="xact_clamp")
    b = build_checkpoint(list(reversed(rows)), index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                         window_start_exclusive=None, window_end_inclusive="2026-08-13T22:01:00.000000Z",
                         cumulative_row_count_before=0, tenant_scope="*", boundary_basis="xact_clamp")
    # Row arrival order from the database is not part of the commitment; the
    # canonical sort is. Otherwise a verifier would have to reproduce the
    # planner's chosen scan order, which is not reproducible even in principle.
    assert a.digest() == b.digest()


def test_checkpoint_digest_covers_every_field():
    """Each field must be inside the digest, or an attacker can restate a
    checkpoint over a different window and reuse the signature."""
    base = dict(index=0, prev_checkpoint_digest=GENESIS_DIGEST, window_start_exclusive=None,
                window_end_inclusive="2026-08-13T22:01:00.000000Z", cumulative_row_count_before=0,
                tenant_scope="*", boundary_basis="xact_clamp")
    original = build_checkpoint([_row(1)], **base).digest()
    for field, value in [
        ("index", 1),
        ("prev_checkpoint_digest", "11" * 32),
        ("window_start_exclusive", "2026-08-13T21:00:00.000000Z"),
        ("window_end_inclusive", "2026-08-13T22:02:00.000000Z"),
        ("cumulative_row_count_before", 5),
        ("tenant_scope", "tenant-demo"),
        ("boundary_basis", "settle_lag_only"),
    ]:
        altered = build_checkpoint([_row(1)], **{**base, field: value}).digest()
        assert altered != original, f"{field} is not covered by the digest"


def test_merkle_root_matches_a_hand_built_tree():
    rows = [_row(1), _row(2)]
    cp = build_checkpoint(rows, index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                          window_start_exclusive=None, window_end_inclusive="2026-08-13T22:01:00.000000Z",
                          cumulative_row_count_before=0, tenant_scope="*", boundary_basis="xact_clamp")
    import hashlib

    leaves = [leaf_hash(encode_row(r)) for r in rows]
    expected = hashlib.sha256(b"\x01" + leaves[0] + leaves[1]).hexdigest()
    assert cp.merkle_root == expected


def test_predicate_round_trips():
    """The predicate is what gets signed and stored. If it does not round-trip
    exactly, verification re-derives a different digest from the same anchor."""
    cp = build_checkpoint([_row(1)], index=3, prev_checkpoint_digest="ab" * 32,
                          window_start_exclusive="2026-08-13T21:00:00.000000Z",
                          window_end_inclusive="2026-08-13T22:01:00.000000Z",
                          cumulative_row_count_before=9, tenant_scope="tenant-demo",
                          boundary_basis="settle_lag_only")
    assert Checkpoint.from_predicate(cp.to_predicate()) == cp
    assert Checkpoint.from_predicate(cp.to_predicate()).digest() == cp.digest()


def test_empty_window_is_a_valid_checkpoint():
    """Quiet periods are normal and must still advance the chain. A gap in the
    chain is indistinguishable from a deleted checkpoint, so we never skip."""
    cp = build_checkpoint([], index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                          window_start_exclusive=None, window_end_inclusive="2026-08-13T22:01:00.000000Z",
                          cumulative_row_count_before=7, tenant_scope="*", boundary_basis="xact_clamp")
    import hashlib

    assert cp.row_count == 0
    assert cp.cumulative_row_count == 7
    assert cp.merkle_root == hashlib.sha256(b"").hexdigest()


# ══════════════════════════════════════════════════════════════════════════════
# Chain structure
# ══════════════════════════════════════════════════════════════════════════════


def test_a_well_formed_chain_has_no_structural_errors():
    reader = FakeReader([_row(i) for i in range(1, 7)])
    chain = _chain(reader, ["2026-08-13T22:00:02.000000Z",
                            "2026-08-13T22:00:04.000000Z",
                            "2026-08-13T22:00:06.000000Z"])
    assert verify_chain_structure(chain) == []
    assert chain[0].prev_checkpoint_digest == GENESIS_DIGEST
    assert chain[2].cumulative_row_count == 6


def test_a_broken_back_link_is_detected():
    reader = FakeReader([_row(i) for i in range(1, 5)])
    chain = _chain(reader, ["2026-08-13T22:00:02.000000Z", "2026-08-13T22:00:04.000000Z"])
    forged = Checkpoint.from_predicate({**chain[1].to_predicate(), "prev_checkpoint_digest": "00" * 31 + "01"})
    errors = verify_chain_structure([chain[0], forged])
    assert any(e.kind == "broken_link" for e in errors)


def test_a_removed_checkpoint_is_detected():
    """Dropping a checkpoint from the middle is the cheapest way to hide a
    window. Both the index sequence and the window contiguity catch it."""
    reader = FakeReader([_row(i) for i in range(1, 7)])
    chain = _chain(reader, ["2026-08-13T22:00:02.000000Z",
                            "2026-08-13T22:00:04.000000Z",
                            "2026-08-13T22:00:06.000000Z"])
    errors = verify_chain_structure([chain[0], chain[2]])
    assert {e.kind for e in errors} >= {"index_gap"}


def test_a_window_gap_is_detected():
    """Windows must abut exactly: checkpoint N+1 starts where N ended. A gap is
    an unanchored interval, which is where a deletion would be hidden."""
    reader = FakeReader([_row(i) for i in range(1, 5)])
    chain = _chain(reader, ["2026-08-13T22:00:02.000000Z", "2026-08-13T22:00:04.000000Z"])
    forged = Checkpoint.from_predicate(
        {**chain[1].to_predicate(), "window_start_exclusive": "2026-08-13T22:00:03.000000Z"}
    )
    errors = verify_chain_structure([chain[0], forged])
    assert any(e.kind == "window_gap" for e in errors)


def test_cumulative_arithmetic_is_checked():
    reader = FakeReader([_row(i) for i in range(1, 5)])
    chain = _chain(reader, ["2026-08-13T22:00:02.000000Z", "2026-08-13T22:00:04.000000Z"])
    forged = Checkpoint.from_predicate({**chain[1].to_predicate(), "cumulative_row_count": 99})
    errors = verify_chain_structure([chain[0], forged])
    assert any(e.kind == "cumulative_mismatch" for e in errors)


def test_a_non_monotonic_window_is_rejected():
    with pytest.raises(ChainError):
        build_checkpoint([], index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                         window_start_exclusive="2026-08-13T22:00:05.000000Z",
                         window_end_inclusive="2026-08-13T22:00:01.000000Z",
                         cumulative_row_count_before=0, tenant_scope="*",
                         boundary_basis="xact_clamp")


def test_rows_outside_the_declared_window_are_rejected():
    """A caller that hands in rows the window does not cover would produce a
    checkpoint that no honest verifier can ever reproduce."""
    with pytest.raises(ChainError):
        build_checkpoint([_row(9)], index=0, prev_checkpoint_digest=GENESIS_DIGEST,
                         window_start_exclusive=None,
                         window_end_inclusive="2026-08-13T22:00:05.000000Z",
                         cumulative_row_count_before=0, tenant_scope="*",
                         boundary_basis="xact_clamp")


# ══════════════════════════════════════════════════════════════════════════════
# Divergence detection -- the part that has to actually work
# ══════════════════════════════════════════════════════════════════════════════

BOUNDARIES = ["2026-08-13T22:00:02.000000Z",
              "2026-08-13T22:00:04.000000Z",
              "2026-08-13T22:00:06.000000Z"]


def _anchored():
    rows = [_row(i) for i in range(1, 7)]
    reader = FakeReader(rows)
    return reader, _chain(reader, BOUNDARIES)


def test_an_untouched_log_verifies_intact():
    reader, chain = _anchored()
    result = verify_against_reader(chain, reader)
    assert result.intact
    assert result.first_divergence is None


def test_a_modified_row_is_detected_and_localised():
    reader, chain = _anchored()
    reader.rows[2] = _row(3, actor="not-the-original-actor")  # window index 1
    result = verify_against_reader(chain, reader)
    assert not result.intact
    assert result.first_divergence.checkpoint_index == 1
    assert result.first_divergence.kind == "merkle_root_mismatch"


def test_a_modified_detail_payload_is_detected():
    """The interesting tamper: keep every column plausible, change the story
    the JSON tells. This is what someone covering up a stun would actually do."""
    reader, chain = _anchored()
    reader.rows[0] = _row(1, detail='{"outcome": "allowed"}')
    result = verify_against_reader(chain, reader)
    assert not result.intact
    assert result.first_divergence.checkpoint_index == 0


def test_a_deleted_row_is_detected_and_localised():
    reader, chain = _anchored()
    del reader.rows[4]  # window index 2
    result = verify_against_reader(chain, reader)
    assert not result.intact
    assert result.first_divergence.checkpoint_index == 2
    assert result.first_divergence.kind == "row_count_mismatch"
    assert result.first_divergence.expected_row_count == 2
    assert result.first_divergence.observed_row_count == 1


def test_a_back_dated_insertion_into_an_anchored_window_is_detected():
    """Inserting a row with a timestamp inside an already-anchored window is
    tampering, not a late write: the boundary is chosen so no in-flight
    transaction can still land there. See checkpoint.choose_boundary."""
    reader, chain = _anchored()
    reader.rows.append(_row(1, actor="back-dated"))
    result = verify_against_reader(chain, reader)
    assert not result.intact
    assert result.first_divergence.checkpoint_index == 0


def test_divergence_reports_the_earliest_checkpoint_not_just_any():
    """Naming the wrong checkpoint sends the investigation to the wrong day."""
    reader, chain = _anchored()
    reader.rows[0] = _row(1, actor="tampered-early")
    reader.rows[5] = _row(6, actor="tampered-late")
    result = verify_against_reader(chain, reader)
    assert result.first_divergence.checkpoint_index == 0


def test_rows_after_the_last_checkpoint_do_not_trigger_divergence():
    """New audit rows land continuously. Unanchored rows are simply not yet
    covered -- reporting them as tampering would make the verifier useless."""
    reader, chain = _anchored()
    reader.rows.append(_row(7))
    result = verify_against_reader(chain, reader)
    assert result.intact
    assert result.unanchored_row_count == 1


def test_verification_reports_every_diverged_checkpoint_not_only_the_first():
    reader, chain = _anchored()
    reader.rows[0] = _row(1, actor="x")
    reader.rows[5] = _row(6, actor="y")
    result = verify_against_reader(chain, reader)
    assert [d.checkpoint_index for d in result.divergences] == [0, 2]


def test_an_empty_chain_verifies_but_says_so():
    """Nothing anchored means nothing proven. It must not read as 'intact'
    without qualification -- that is exactly the overclaim to avoid."""
    result = verify_against_reader([], FakeReader([_row(1)]))
    assert result.anchored_row_count == 0
    assert result.unanchored_row_count == 1
    assert not result.proves_anything
