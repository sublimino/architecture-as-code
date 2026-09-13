import json
from pathlib import Path
import pytest
from pydantic import ValidationError
from external_agent_contract import (
    AssertionEnvelope,
    EnrollmentRequest,
    EnrollmentResult,
    ContractError,
    Evidence,
    ExternalUpload,
    PrivacyContract,
    EvidencePage,
    RevocationRequest,
    RevocationResult,
    ServerEvidence,
    ServerIntegrityResult,
    UploadResult,
    canonical_signing_bytes,
    parse_external_upload,
)
from generate_external_agent_types import OUTPUT, render

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "signal-ingest/collectors/agentnono/fixtures/contracts"

def load(name: str):
    return json.loads((FIXTURES / name).read_text())

def test_shape_models_accept_real_signed_vectors_without_claiming_crypto_validity():
    assert ExternalUpload.model_validate(load("valid-upload.v1.json")).assertion_envelope.algorithm == "Ed25519"
    assert ExternalUpload.model_validate(load("tampered-upload.v1.json")).original_chain_reference.event_count == 1
    assert ExternalUpload.model_validate(load("valid-artifact-upload.v1.json")).assertion_envelope.assertions[0].evidence_type == "artifact"

def test_shape_models_reject_malformed_and_oversize_vectors():
    for name in ("malformed-upload.v1.json", "malformed-oversize-artifact.v1.json"):
        with pytest.raises(ValidationError):
            ExternalUpload.model_validate(load(name))

def test_enrollment_uses_bearer_token_only():
    assert EnrollmentRequest.model_validate(load("valid-enrollment.v1.json")).key_algorithm == "Ed25519"
    with pytest.raises(ValidationError):
        EnrollmentRequest.model_validate(load("malformed-enrollment.v1.json"))

def test_privacy_fixture_reproduces_the_frozen_p1_2_boundary():
    privacy = PrivacyContract.model_validate(load("privacy-policy.v1.json"))
    assert privacy.integrity_implies_completeness is False
    assert privacy.integrity_implies_host_trust is False
    assert len(privacy.prohibited_export_fields) == 10

def test_inbound_chain_reference_cannot_claim_server_authority_or_state():
    payload = load("valid-upload.v1.json")
    payload["original_chain_reference"]["state"] = "integrity-verified"
    with pytest.raises(ValidationError):
        ExternalUpload.model_validate(payload)

def test_dashboard_types_are_reproducible_from_every_schema():
    generated = render()
    assert OUTPUT.read_text() == generated
    assert "ExternalAgentEnrollmentV1" in generated
    assert "ExternalAgentPrivacyV1" in generated
    assert "ExternalAgentServerProjectionV1IntegrityResult" in generated

def test_python_contract_contains_no_cryptographic_verifier():
    source = Path(__file__).parents[1].joinpath("external_agent_contract.py").read_text()
    assert "cryptography" not in source
    assert "verify_signature" not in source


def test_inbound_provenance_cannot_claim_server_verification():
    payload = load("valid-upload.v1.json")
    evidence = payload["assertion_envelope"]["assertions"][0]
    for field, value in (("source", "signal-ingest"), ("integrity_state", "integrity-verified")):
        mutated = json.loads(json.dumps(payload))
        mutated["assertion_envelope"]["assertions"][0][field] = value
        with pytest.raises(ValidationError):
            ExternalUpload.model_validate(mutated)


def test_python_oracle_rejects_duplicates_missing_scalars_and_numeric_forms():
    raw = (FIXTURES / "valid-upload.v1.json").read_bytes()
    mutations = (
        raw.replace(b'"sequence_start":0,', b'', 1),
        raw.replace(b',"algorithm":"Ed25519"', b'', 1),
        raw.replace(b',"decision":"allowed"', b'', 1),
        raw.replace(b'"event_count":1,', b'', 1),
        raw.replace(b'"sequence_start":0', b'"sequence_start":null', 1),
        raw.replace(b'"sequence":0', b'"sequence":null', 1),
        raw.replace(b'"upload_id":', b'"upload_id":"duplicate-upload-0001","upload_id":', 1),
        raw.replace(b'"decision":', b'"decision":"denied","decision":', 1),
        raw.replace(b'"sequence":0', b'"sequence":0.0', 1),
        raw.replace(b'"sequence":0', b'"sequence":0e0', 1),
        raw.replace(b'"sequence":0', b'"sequence":9007199254740992', 1),
    )
    for mutation in mutations:
        with pytest.raises((ValueError, ValidationError)):
            parse_external_upload(mutation)


def test_python_canonical_oracle_matches_go_fixture_after_reordering():
    raw = (FIXTURES / "valid-upload.v1.json").read_bytes()
    expected = (FIXTURES / "valid-upload.v1.canonical.json").read_bytes().rstrip(b"\n")
    assert canonical_signing_bytes(raw) == expected
    def reverse_objects(value):
        if isinstance(value, dict):
            return {key: reverse_objects(item) for key, item in reversed(tuple(value.items()))}
        if isinstance(value, list):
            return [reverse_objects(item) for item in value]
        return value
    reordered = json.dumps(reverse_objects(json.loads(raw)), separators=(",", ":")).encode()
    assert canonical_signing_bytes(reordered) == expected
    escaped_key = raw.replace(b'"upload_id"', b'"\\u0075pload_id"', 1)
    assert canonical_signing_bytes(escaped_key) == expected


def test_process_exit_code_is_required_and_nullable():
    payload = load("valid-upload.v1.json")
    evidence = payload["assertion_envelope"]["assertions"][0]
    evidence["evidence_type"] = "process"
    evidence["attributes"] = {"health_state": "running", "cpu_time_ms": 0, "resident_memory_bytes": 0, "exit_code": None, "restart_count": 0}
    assert ExternalUpload.model_validate(payload).assertion_envelope.assertions[0].attributes["exit_code"] is None
    del evidence["attributes"]["exit_code"]
    with pytest.raises(ValidationError):
        ExternalUpload.model_validate(payload)


def test_artifact_mtime_is_bounded_uint64_decimal_string():
    payload = load("valid-artifact-upload.v1.json")
    attributes = payload["assertion_envelope"]["assertions"][0]["attributes"]
    attributes["mtime_ns"] = "18446744073709551615"
    assert ExternalUpload.model_validate(payload)
    for invalid in ("18446744073709551616", "01", "1.0", 1):
        attributes["mtime_ns"] = invalid
        with pytest.raises(ValidationError):
            ExternalUpload.model_validate(payload)


def test_evidence_discriminator_rejects_mismatched_attributes_and_limit_state():
    payload = load("valid-upload.v1.json")["assertion_envelope"]["assertions"][0]
    payload["evidence_type"] = "process"
    with pytest.raises(ValidationError):
        Evidence.model_validate(payload)
    with pytest.raises(ValidationError):
        ServerEvidence.model_validate(dict(payload, source="signal-ingest", integrity_state="unavailable"))
    payload["evidence_type"] = "collection-limit"
    payload["attributes"] = {
        "reason_code": "oversize",
        "max_file_size_bytes": 16777216,
        "max_files_per_window": 120,
        "max_bytes_per_window": 67108864,
        "window_seconds": 60,
    }
    payload["observation_state"] = "observed"
    with pytest.raises(ValidationError):
        Evidence.model_validate(payload)
    server = dict(payload, source="signal-ingest", integrity_state="unavailable")
    with pytest.raises(ValidationError):
        ServerEvidence.model_validate(server)


def test_timestamp_wire_grammar_rejects_aliases_and_accepts_offsets():
    payload = load("valid-upload.v1.json")
    for invalid in (
        "2026-09-13t10:00:00Z",
        "2026-09-13T10:00:00z",
        "2026-09-13 10:00:00Z",
        "2026-09-13T10:00:00.1234567890Z",
    ):
        payload["assertion_envelope"]["assertions"][0]["observed_at"] = invalid
        with pytest.raises(ValidationError):
            ExternalUpload.model_validate(payload)
    payload["assertion_envelope"]["assertions"][0]["observed_at"] = "2026-09-13T11:00:00+01:00"
    assert ExternalUpload.model_validate(payload)


def test_server_integrity_result_enforces_state_reason_digest_combinations():
    base = {
        "authority": "agentnono-go-v1",
        "session_id": "session-001",
        "event_count": 1,
        "final_digest": "a" * 64,
        "state": "integrity-verified",
        "evaluated_at": "2026-09-13T10:00:00Z",
        "reason": "verified",
    }
    assert ServerIntegrityResult.model_validate(base)
    for invalid in (
        dict(base, reason="event-tampered"),
        dict(base, state="tampered", final_digest=None),
        dict(base, state="unavailable", reason="empty-chain"),
    ):
        with pytest.raises(ValidationError):
            ServerIntegrityResult.model_validate(invalid)
    assert ServerIntegrityResult.model_validate(
        dict(base, state="unavailable", reason="empty-chain", event_count=0, final_digest=None)
    )


def test_signature_text_requires_canonical_ed25519_base64url():
    envelope = load("valid-upload.v1.json")["assertion_envelope"]
    assert AssertionEnvelope.model_validate(envelope)
    envelope["signature"] = envelope["signature"][:-1] + "B"
    with pytest.raises(ValidationError):
        AssertionEnvelope.model_validate(envelope)


def test_generator_emits_discriminator_preserving_evidence_unions():
    generated = render()
    assert "export type ExternalAgentEvidenceV1 =" in generated
    assert "export type ExternalAgentServerProjectionV1ServerEvidence =" in generated
    assert 'evidence_type: "process"' in generated
    assert 'observation_state: "unobserved"' in generated
    assert "export type ExternalAgentServerProjectionV1IntegrityResult =" in generated
    assert "ExternalAgentServerProjectionV1IntegrityResultIntegrityVerified" in generated
    assert "event_count: number" in generated


def test_enrollment_key_and_existing_mtls_binding_are_canonical():
    assert EnrollmentRequest.model_validate(load("valid-enrollment.v1.json"))
    for name in ("malformed-enrollment.v1.json", "malformed-enrollment-key-alias.v1.json"):
        with pytest.raises(ValidationError):
            EnrollmentRequest.model_validate(load(name))


@pytest.mark.parametrize(
    ("model", "valid_name", "malformed_name"),
    (
        (EnrollmentResult, "valid-enrollment-result.v1.json", "malformed-enrollment-result.v1.json"),
        (UploadResult, "valid-upload-result.v1.json", "malformed-upload-result.v1.json"),
        (EvidencePage, "valid-evidence-page.v1.json", "malformed-evidence-page.v1.json"),
        (RevocationRequest, "valid-revocation-request.v1.json", "malformed-revocation-request.v1.json"),
        (RevocationResult, "valid-revocation-result.v1.json", "malformed-revocation-result.v1.json"),
        (PrivacyContract, "privacy-policy.v1.json", "malformed-privacy-policy.v1.json"),
        (ContractError, "valid-error.v1.json", "malformed-error.v1.json"),
    ),
)
def test_request_and_response_fixtures(model, valid_name, malformed_name):
    assert model.model_validate(load(valid_name))
    with pytest.raises(ValidationError):
        model.model_validate(load(malformed_name))


def test_evidence_page_preserves_host_provenance_without_local_integrity():
    page = EvidencePage.model_validate(load("valid-evidence-page.v1.json"))
    item = page.items[0]
    assert item.evidence.source == "host-sensor-v1"
    assert item.evidence.integrity_state == "not-integrity-verified"
    assert item.acceptance.host_signature_state == "host-signature-verified"
    assert item.acceptance.original_chain_state == "original-chain-not-verified"
    assert "integrity_result" not in item.model_dump()


def test_response_identifiers_match_schema_boundaries():
    enrollment = load("valid-enrollment-result.v1.json")
    for invalid in ("", "ab", "bad/key", "a" * 129):
        with pytest.raises(ValidationError):
            EnrollmentResult.model_validate(dict(enrollment, key_id=invalid))
    upload = load("valid-upload-result.v1.json")
    for invalid in ("", "short", "upload_invalid_01", "a" * 129):
        with pytest.raises(ValidationError):
            UploadResult.model_validate(dict(upload, upload_id=invalid))
