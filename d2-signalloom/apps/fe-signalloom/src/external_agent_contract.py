"""Pure AMXO-P1-3 shape models; cryptographic decisions belong to Go."""
from __future__ import annotations
import base64
import json
import re
from typing import Annotated, Any, Literal
from pydantic import AwareDatetime, BaseModel, BeforeValidator, ConfigDict, Field, model_validator

SafeID = Annotated[str, Field(pattern=r"^[a-z][a-z0-9-]{2,63}$")]
SessionID = Annotated[str, Field(pattern=r"^[A-Za-z0-9-]{3,128}$")]
Hex64 = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
KeyID = Annotated[str, Field(pattern=r"^[A-Za-z0-9._:-]{3,128}$")]
UploadID = Annotated[str, Field(pattern=r"^[A-Za-z0-9-]{16,128}$")]
MAX_SAFE_INTEGER = 9007199254740991
MAX_UINT64 = 18446744073709551615
SafeUInt = Annotated[int, Field(strict=True, ge=0, le=MAX_SAFE_INTEGER)]
TIMESTAMP_PATTERN = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$")

def _datetime_string(value: Any) -> Any:
    if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
        raise ValueError("timestamp must use the strict RFC 3339 wire grammar")
    return value

def _canonical_ed25519_signature(value: Any) -> Any:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{85}[AQgw]", value):
        raise ValueError("signature must be canonical unpadded Ed25519 base64url")
    try:
        decoded = base64.urlsafe_b64decode(value + "==")
    except ValueError as exc:
        raise ValueError("signature must be canonical unpadded Ed25519 base64url") from exc
    if len(decoded) != 64 or base64.urlsafe_b64encode(decoded).decode("ascii").rstrip("=") != value:
        raise ValueError("signature must be canonical unpadded Ed25519 base64url")
    return value

def _canonical_ed25519_public_key(value: Any) -> Any:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]", value):
        raise ValueError("public_key must be canonical unpadded Ed25519 base64url")
    decoded = base64.urlsafe_b64decode(value + "=")
    if len(decoded) != 32 or base64.urlsafe_b64encode(decoded).decode("ascii").rstrip("=") != value:
        raise ValueError("public_key must be canonical unpadded Ed25519 base64url")
    return value

Rfc3339Datetime = Annotated[AwareDatetime, BeforeValidator(_datetime_string)]

class ClosedModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

class EnrollmentRequest(ClosedModel):
    schema_version: Literal["1.0.0"]
    agent_id: SafeID
    host_id: SafeID
    key_id: KeyID
    key_algorithm: Literal["Ed25519"]
    public_key: Annotated[str, BeforeValidator(_canonical_ed25519_public_key)]
    client_nonce: Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{22,86}$")]
    credential_kind: Literal["existing-mtls-identity"]
    credential_scope: Literal["audit-upload-only"]
    credential_bootstrap: Literal["pre-provisioned-out-of-band"]
    credential_reference: Annotated[str, Field(pattern=r"^spiffe://[A-Za-z0-9._~:/-]+$", max_length=512)]

class ProcessAttributes(ClosedModel):
    health_state: Literal["starting", "running", "stopped", "failed", "unknown"]
    cpu_time_ms: SafeUInt
    resident_memory_bytes: SafeUInt
    exit_code: Annotated[int, Field(strict=True, ge=-2147483648, le=2147483647)] | None
    restart_count: SafeUInt

class ArtifactAttributes(ClosedModel):
    artifact_id: Annotated[str, Field(pattern=r"^hmac-sha256:[0-9a-f]{64}$")]
    root_id: Literal["agent-work", "agent-output"]
    sha256: Hex64
    size_bytes: Annotated[int, Field(strict=True, ge=0, le=16777216)]
    mtime_ns: Annotated[str, Field(pattern=r"^(0|[1-9][0-9]{0,19})$")]

    @model_validator(mode="after")
    def bounded_mtime(self) -> "ArtifactAttributes":
        if int(self.mtime_ns) > MAX_UINT64:
            raise ValueError("mtime_ns exceeds uint64")
        return self

class NetworkAttributes(ClosedModel):
    destination_id: Literal["signal-loom-ingest", "agentmaxxing-api"]
    decision: Literal["allowed", "denied"]

class LimitAttributes(ClosedModel):
    reason_code: Literal["oversize", "files-rate-exhausted", "bytes-rate-exhausted"]
    max_file_size_bytes: Annotated[int, Field(strict=True, ge=16777216, le=16777216)]
    max_files_per_window: Annotated[int, Field(strict=True, ge=120, le=120)]
    max_bytes_per_window: Annotated[int, Field(strict=True, ge=67108864, le=67108864)]
    window_seconds: Annotated[int, Field(strict=True, ge=60, le=60)]

class Evidence(ClosedModel):
    schema_version: Literal["1.0.0"]
    session_id: SessionID
    sequence: SafeUInt
    observed_at: Rfc3339Datetime
    source: Literal["nono-0.73.0", "host-sensor-v1"]
    evidence_type: Literal["process", "artifact", "network", "collection-limit"]
    observation_state: Literal["observed", "denied", "unobserved"]
    integrity_state: Literal["not-integrity-verified"]
    agent_id: SafeID
    host_id: SafeID
    attributes: dict[str, Any]

    @model_validator(mode="after")
    def validate_attributes(self) -> "Evidence":
        models: dict[str, type[ClosedModel]] = {"process": ProcessAttributes, "artifact": ArtifactAttributes, "network": NetworkAttributes, "collection-limit": LimitAttributes}
        models[self.evidence_type].model_validate(self.attributes)
        if self.evidence_type == "collection-limit" and self.observation_state != "unobserved":
            raise ValueError("collection-limit evidence must be unobserved")
        return self

class AssertionEnvelope(ClosedModel):
    format: Literal["signalloom-host-assertions-v1"]
    algorithm: Literal["Ed25519"]
    payload_sha256: Hex64
    key_id: KeyID
    signature: Annotated[str, BeforeValidator(_canonical_ed25519_signature)]
    assertions: Annotated[tuple[Evidence, ...], Field(min_length=1, max_length=500)]

class OriginalChainReference(ClosedModel):
    session_id: SessionID
    event_count: Annotated[int, Field(strict=True, ge=1, le=100000)]
    final_digest: Hex64

class PrivacyContract(ClosedModel):
    schema_version: Literal["1.0.0"]
    policy_id: Literal["amxo-host-policy-v1"]
    unobserved_fields: tuple[Literal["read_only_input_file_digests"], Literal["file_contents"], Literal["process_memory_contents"], Literal["in_memory_synthesis_contents"], Literal["streamed_payload_digests"], Literal["streamed_payload_contents"], Literal["network_payload_contents"]]
    prohibited_export_fields: tuple[Literal["raw_nono_record"], Literal["command"], Literal["path"], Literal["url"], Literal["error"], Literal["file_contents"], Literal["memory_contents"], Literal["streamed_payload_digest"], Literal["streamed_payload_contents"], Literal["network_payload_contents"]]
    raw_paths_exported: Literal[False]
    raw_urls_exported: Literal[False]
    raw_errors_exported: Literal[False]
    integrity_implies_completeness: Literal[False]
    integrity_implies_host_trust: Literal[False]
    evidence_retention_days: Literal[30]
    deletion_deadline_days: Literal[7]
    retention_owner: Literal["ControlPlane Signal Loom Operations"]
    deletion_owner: Literal["ControlPlane Signal Loom Operations"]
    host_unenrollment_owner: Literal["AgentMaxxing Platform Engineering"]
    deletion_trigger: Literal["verified-tenant-request-or-host-unenrollment"]
    revocation_semantics: Literal["audit-only-independent-no-evidence-rewrite"]

class ServerIntegrityResult(ClosedModel):
    authority: Literal["agentnono-go-v1"]
    session_id: SessionID
    event_count: Annotated[int, Field(strict=True, ge=0, le=100000)]
    final_digest: Hex64 | None
    state: Literal["integrity-verified", "tampered", "unavailable"]
    evaluated_at: Rfc3339Datetime
    reason: Literal["verified", "verifier-unavailable", "empty-chain", "event-cap-exceeded", "not-finalized", "chain-continuity-failed", "event-tampered", "event-unverified"]

    @model_validator(mode="after")
    def coherent_state(self) -> "ServerIntegrityResult":
        if self.state == "integrity-verified":
            valid = self.reason == "verified" and self.final_digest is not None and self.event_count >= 1
        elif self.state == "tampered":
            valid = self.reason in {"chain-continuity-failed", "event-tampered"} and self.final_digest is not None and self.event_count >= 1
        else:
            valid = self.reason in {"verifier-unavailable", "empty-chain", "event-cap-exceeded", "not-finalized", "event-unverified"} and self.final_digest is None and self.event_count == 0
        if not valid:
            raise ValueError("invalid integrity state, reason, digest, and count combination")
        return self

class ServerEvidence(ClosedModel):
    schema_version: Literal["1.0.0"]
    session_id: SessionID
    sequence: SafeUInt
    observed_at: Rfc3339Datetime
    source: Literal["nono-0.73.0", "host-sensor-v1"]
    evidence_type: Literal["process", "artifact", "network", "collection-limit"]
    observation_state: Literal["observed", "denied", "unobserved"]
    integrity_state: Literal["not-integrity-verified"]
    agent_id: SafeID
    host_id: SafeID
    attributes: dict[str, Any]

    @model_validator(mode="after")
    def validate_attributes(self) -> "ServerEvidence":
        models: dict[str, type[ClosedModel]] = {"process": ProcessAttributes, "artifact": ArtifactAttributes, "network": NetworkAttributes, "collection-limit": LimitAttributes}
        models[self.evidence_type].model_validate(self.attributes)
        if self.evidence_type == "collection-limit" and self.observation_state != "unobserved":
            raise ValueError("collection-limit evidence must be unobserved")
        return self

class EnrollmentResult(ClosedModel):
    schema_version: Literal["1.0.0"]
    tenant_id: SafeID
    agent_id: SafeID
    host_id: SafeID
    key_id: KeyID
    enrollment_state: Literal["enrolled"]
    credential_kind: Literal["existing-mtls-identity"]
    credential_scope: Literal["audit-upload-only"]
    credential_bootstrap: Literal["pre-provisioned-out-of-band"]
    credential_reference: Annotated[str, Field(pattern=r"^spiffe://[A-Za-z0-9._~:/-]+$", max_length=512)]
    credential_expires_at: Rfc3339Datetime
    revocation_endpoint: Annotated[str, Field(pattern=r"^/v1/external-agents/[a-z][a-z0-9-]{2,63}/revocations$", max_length=256)]

class UploadResult(ClosedModel):
    schema_version: Literal["1.0.0"]
    upload_id: UploadID
    replay_result: Literal["accepted", "idempotent-replay"]
    host_signature_state: Literal["host-signature-verified"]
    original_chain_state: Literal["original-chain-not-verified"]

class Acceptance(ClosedModel):
    schema_version: Literal["1.0.0"]
    upload_id: UploadID
    accepted_at: Rfc3339Datetime
    replay_result: Literal["accepted", "idempotent-replay"]
    host_signature_state: Literal["host-signature-verified"]
    original_chain_state: Literal["original-chain-not-verified"]

class EvidenceItem(ClosedModel):
    evidence: ServerEvidence
    acceptance: Acceptance

class EvidencePage(ClosedModel):
    schema_version: Literal["1.0.0"]
    tenant_id: SafeID
    items: Annotated[tuple[EvidenceItem, ...], Field(max_length=500)]
    next_cursor: Annotated[str, Field(max_length=256)] | None

RevocationReason = Literal["operator-request", "host-unenrolled", "credential-compromise", "credential-expired", "key-rotation"]

class RevocationRequest(ClosedModel):
    schema_version: Literal["1.0.0"]
    reason_code: RevocationReason

class RevocationResult(ClosedModel):
    schema_version: Literal["1.0.0"]
    agent_id: SafeID
    credential_reference: Annotated[str, Field(pattern=r"^spiffe://[A-Za-z0-9._~:/-]+$", max_length=512)]
    revocation_state: Literal["revocation-accepted"]
    reason_code: RevocationReason
    revoked_at: Rfc3339Datetime

class ContractError(ClosedModel):
    schema_version: Literal["1.0.0"]
    error_code: Literal["malformed-request", "unauthenticated", "forbidden", "conflict", "payload-too-large", "unsupported-media-type", "validation-failed"]
    message: Annotated[str, Field(min_length=1, max_length=256)]
    request_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9-]{8,128}$")]

class ExternalUpload(ClosedModel):
    schema_version: Literal["1.0.0"]
    upload_id: UploadID
    replay_key: Hex64
    session_id: SessionID
    sequence_start: SafeUInt
    sequence_end: SafeUInt
    assertion_envelope: AssertionEnvelope
    original_chain_reference: OriginalChainReference

    @model_validator(mode="after")
    def coherent(self) -> "ExternalUpload":
        if self.sequence_end < self.sequence_start:
            raise ValueError("sequence range reversed")
        if len(self.assertion_envelope.assertions) != self.sequence_end - self.sequence_start + 1:
            raise ValueError("assertion count differs from sequence range")
        if self.original_chain_reference.session_id != self.session_id:
            raise ValueError("original-chain reference session mismatch")
        for offset, assertion in enumerate(self.assertion_envelope.assertions):
            if assertion.session_id != self.session_id or assertion.sequence != self.sequence_start + offset:
                raise ValueError("assertion session or sequence mismatch")
        return self


def _reject_float(value: str) -> None:
    raise ValueError(f"integer lexical form required: {value}")


def _parse_safe_integer(value: str) -> int:
    if not re.fullmatch(r"-?(0|[1-9][0-9]*)", value) or value == "-0":
        raise ValueError(f"non-canonical integer: {value}")
    parsed = int(value)
    if abs(parsed) > MAX_SAFE_INTEGER:
        raise ValueError(f"integer exceeds JavaScript safe range: {value}")
    return parsed


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _require_ascii(value: Any) -> None:
    if isinstance(value, str):
        if not value.isascii():
            raise ValueError("contract strings must be ASCII")
    elif isinstance(value, dict):
        for key, item in value.items():
            _require_ascii(key)
            _require_ascii(item)
    elif isinstance(value, list):
        for item in value:
            _require_ascii(item)


def _load_external_json(data: bytes | str) -> dict[str, Any]:
    parsed = json.loads(
        data,
        object_pairs_hook=_unique_object,
        parse_int=_parse_safe_integer,
        parse_float=_reject_float,
        parse_constant=_reject_float,
    )
    _require_ascii(parsed)
    if not isinstance(parsed, dict):
        raise ValueError("external upload must be a JSON object")
    return parsed


def parse_external_upload(data: bytes | str) -> ExternalUpload:
    return ExternalUpload.model_validate(_load_external_json(data))


def canonical_signing_bytes(data: bytes | str) -> bytes:
    upload = _load_external_json(data)
    ExternalUpload.model_validate(upload)
    document = {
        "assertions": upload["assertion_envelope"]["assertions"],
        "domain": "signalloom.external-agent-upload.v1",
        "original_chain_reference": upload["original_chain_reference"],
        "schema_version": upload["schema_version"],
        "sequence_end": upload["sequence_end"],
        "sequence_start": upload["sequence_start"],
        "session_id": upload["session_id"],
        "upload_id": upload["upload_id"],
    }
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
