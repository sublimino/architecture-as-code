"""Verified persisted-segment inventory adapted to ``AuditLogReader``."""

import json
import os
import tempfile
from dataclasses import dataclass, field
from hashlib import sha256
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from audit_anchor.anchor import AnchorError, IntegrityError, key_id, verify_envelope

SEGMENT_SCHEMA = "signalloom.segment/v1"
SEGMENT_SCOPE = "signaldb/observations"
SEGMENT_PREDICATE_TYPE = "https://controlplane.io/attestations/signalloom-segment/v1"
HIGH_WATER_SCHEMA = "signalloom.segment.highwater/v1"
SEQUENCE_WIDTH = 20
_SIGNED_FIELDS = {
    "schema_version", "sequence", "segment_id", "digest", "byte_length",
    "signer_key_id", "state", "error",
}
_REQUIRED_FIELDS = _SIGNED_FIELDS | {"attestation"}
_OPTIONAL_FIELDS = {"key_version", "checkpoint_inclusion"}
_ALL_FIELDS = _REQUIRED_FIELDS | _OPTIONAL_FIELDS


@dataclass
class TrustedKeyring:
    keys: dict
    revoked: set[str] = field(default_factory=set)
    expected: set[str] | None = None

    @classmethod
    def from_public_keys(cls, public_keys, *, revoked=(), expected=None):
        keys = {key_id(public_key): public_key for public_key in public_keys}
        return cls(keys, set(revoked), set(expected) if expected is not None else set(keys))

    def verify(self, envelope: dict, declared_key_id: str) -> dict:
        if declared_key_id in self.revoked:
            raise IntegrityError(f"segment signer key {declared_key_id} is revoked")
        if self.expected is not None and declared_key_id not in self.expected:
            raise IntegrityError(f"segment signer key {declared_key_id} is not pinned")
        public_key = self.keys.get(declared_key_id)
        if public_key is None:
            raise IntegrityError(f"segment signer key {declared_key_id} is not pinned in keyring")
        return verify_envelope(envelope, public_key, expected_key_id=declared_key_id)


def load_keyring(paths, *, revoked=(), expected=None) -> TrustedKeyring:
    from audit_anchor.anchor import load_public_key
    return TrustedKeyring.from_public_keys(
        [load_public_key(path) for path in paths], revoked=revoked, expected=expected
    )


@runtime_checkable
class SegmentDigestReader(Protocol):
    """Structural interface consumed by the shared checkpoint verifier."""

    def fetch_window(
        self,
        tenant_scope: str,
        start_exclusive: str | None,
        end_inclusive: str,
    ) -> list: ...


class JournalSegmentDigestReader:
    """Validate the append-only journal and expose canonical Merkle rows."""

    def __init__(self, journal_path, segment_root, keyring: TrustedKeyring, *,
                 high_water_path=None, checkpoint_count: Callable[[], int] | None = None):
        self.journal_path = Path(journal_path)
        self.segment_root = Path(segment_root).resolve()
        self.keyring = keyring
        self.high_water_path = Path(high_water_path) if high_water_path else None
        self.checkpoint_count = checkpoint_count or (lambda: 0)

    def _records(self) -> list[dict]:
        try:
            lines = self.journal_path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise AnchorError(f"cannot read segment journal {self.journal_path}: {exc}") from exc
        records = []
        for line_number, line in enumerate(lines, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise AnchorError(f"segment journal line {line_number} is invalid JSON: {exc}") from exc
            self._validate_record(record, line_number)
            if record["sequence"] != line_number:
                raise IntegrityError(
                    f"segment sequence must be contiguous from 1: line {line_number} "
                    f"declares {record['sequence']}"
                )
            records.append(record)
        self._verify_high_water(records)
        return records

    def _validate_record(self, record: dict, line_number: int) -> None:
        if not _REQUIRED_FIELDS <= set(record) or not set(record) <= _ALL_FIELDS:
            raise AnchorError(f"segment journal line {line_number} has unexpected field set")
        if record["schema_version"] != SEGMENT_SCHEMA:
            raise AnchorError(f"segment journal line {line_number} has unsupported schema")
        if not isinstance(record["sequence"], int) or record["sequence"] < 1:
            raise AnchorError(f"segment journal line {line_number} has invalid sequence")
        segment_id = record["segment_id"]
        relative = Path(segment_id)
        if relative.is_absolute() or ".." in relative.parts or not segment_id.startswith(SEGMENT_SCOPE + "/"):
            raise IntegrityError(f"segment {segment_id!r} is outside {SEGMENT_SCOPE}")
        state = record["state"]
        if state != "ok":
            if state == "pending":
                raise AnchorError(f"segment {segment_id} remains pending")
            if state == "error":
                detail = record["error"] or "unspecified persistence failure"
                raise IntegrityError(f"segment {segment_id} persistence error: {detail}")
            raise AnchorError(f"segment {segment_id} has invalid state {state!r}")
        if record["error"] != "":
            raise IntegrityError(f"successful segment {segment_id} carries an error")
        digest = record["digest"]
        if not isinstance(digest, str) or len(digest) != 64 or digest != digest.lower():
            raise AnchorError(f"segment {segment_id} has invalid lowercase SHA256 digest")
        try:
            int(digest, 16)
        except ValueError:
            raise AnchorError(f"segment {segment_id} has non-hex SHA256 digest") from None

        path = (self.segment_root / relative).resolve()
        if self.segment_root not in path.parents:
            raise IntegrityError(f"segment {segment_id!r} escapes configured root")
        try:
            persisted = path.read_bytes()
        except OSError as exc:
            raise IntegrityError(f"cannot re-read persisted segment {segment_id}: {exc}") from exc
        if len(persisted) != record["byte_length"]:
            raise IntegrityError(f"persisted byte length mismatch for segment {segment_id}")
        if sha256(persisted).hexdigest() != digest:
            raise IntegrityError(f"persisted byte digest mismatch for segment {segment_id}")

        attestation = Path(record["attestation"])
        if attestation.is_absolute() or ".." in attestation.parts:
            raise IntegrityError(f"segment {segment_id} has unsafe attestation path")
        try:
            envelope = json.loads((self.journal_path.parent / attestation).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise IntegrityError(f"cannot read segment attestation {attestation}: {exc}") from exc
        statement = self.keyring.verify(envelope, record["signer_key_id"])
        expected_predicate = {key: record[key] for key in _SIGNED_FIELDS}
        if record.get("key_version"):
            expected_predicate["key_version"] = record["key_version"]
        if statement.get("predicateType") != SEGMENT_PREDICATE_TYPE:
            raise AnchorError(f"segment {segment_id} has unexpected predicate type")
        if statement.get("predicate") != expected_predicate:
            raise IntegrityError(f"segment {segment_id} journal disagrees with signed predicate")
        try:
            subject = statement["subject"][0]
        except (KeyError, IndexError, TypeError):
            raise AnchorError(f"segment {segment_id} has malformed signed subject") from None
        if subject.get("name") != segment_id or subject.get("digest", {}).get("sha256") != digest:
            raise IntegrityError(f"segment {segment_id} signed subject disagrees with journal")

    def _verify_high_water(self, records: list[dict]) -> None:
        if not self.high_water_path:
            return
        try:
            high = json.loads(self.high_water_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise AnchorError(f"cannot read protected high-water state: {exc}") from exc
        if high.get("schema_version") != HIGH_WATER_SCHEMA:
            raise AnchorError("protected high-water state has unsupported schema")
        required = {
            "max_sequence": int,
            "journal_size": int,
            "attestation_count": int,
            "checkpoint_count": int,
            "last_segment_id": str,
            "last_digest": str,
        }
        if any(not isinstance(high.get(name), kind) for name, kind in required.items()):
            raise AnchorError("protected high-water state has invalid fields")
        historical = high.get("historical_segments", [])
        lost_error_count = high.get("lost_error_count", 0)
        if not isinstance(historical, list):
            raise AnchorError("protected high-water state has invalid historical_segments")
        if not isinstance(lost_error_count, int) or isinstance(lost_error_count, bool):
            raise AnchorError("protected high-water state has invalid lost_error_count")
        if any(high[name] < 0 for name in (
            "max_sequence", "journal_size", "attestation_count", "checkpoint_count",
        )):
            raise AnchorError("protected high-water state has negative counters")
        if lost_error_count < 0:
            raise AnchorError("protected high-water state has negative counters")
        if any(not isinstance(segment_id, str) for segment_id in historical):
            raise AnchorError("protected high-water state has invalid historical_segments")
        if len(historical) != len(set(historical)):
            raise AnchorError("protected high-water state has duplicate historical_segments")
        if lost_error_count:
            raise IntegrityError(
                f"protected high-water records {lost_error_count} lost segment errors"
            )
        if high["max_sequence"] == 0 and (high["last_segment_id"] or high["last_digest"]):
            raise AnchorError("empty protected high-water state carries a segment tip")
        if len(records) < high["max_sequence"] or self.journal_path.stat().st_size < high["journal_size"]:
            raise IntegrityError("segment journal is below protected high-water state")
        attestations = sum(1 for record in records if (self.journal_path.parent / record["attestation"]).is_file())
        if attestations < high["attestation_count"]:
            raise IntegrityError("segment attestation inventory is below protected high-water state")
        if self.checkpoint_count() < high["checkpoint_count"]:
            raise IntegrityError("segment checkpoint inventory is below protected high-water state")
        if high["max_sequence"]:
            tip = records[high["max_sequence"] - 1]
            if tip["segment_id"] != high["last_segment_id"] or tip["digest"] != high["last_digest"]:
                raise IntegrityError("segment tip differs from protected high-water state")
        journaled = {record["segment_id"] for record in records}
        historical_set = set(historical)
        if journaled & historical_set:
            raise AnchorError("protected historical segment is also present in the journal")
        for segment_id in historical:
            relative = Path(segment_id)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or relative.as_posix() != segment_id
                or not segment_id.startswith(SEGMENT_SCOPE + "/")
            ):
                raise AnchorError(
                    f"protected high-water has invalid historical segment {segment_id!r}"
                )
            resolved = (self.segment_root / relative).resolve()
            if self.segment_root not in resolved.parents:
                raise IntegrityError(f"historical segment {segment_id!r} escapes configured root")
        scope_root = self.segment_root / SEGMENT_SCOPE
        actual = {
            path.relative_to(self.segment_root).as_posix()
            for path in scope_root.glob("*/data.parquet")
            if path.is_file()
        } if scope_root.exists() else set()
        expected = journaled | historical_set
        missing = sorted(expected - actual)
        if missing:
            raise IntegrityError(f"protected segment inventory is missing {missing[0]}")
        unknown = sorted(actual - expected)
        if unknown:
            raise IntegrityError(f"persisted segment inventory contains unknown {unknown[0]}")

    @staticmethod
    def _row(record: dict) -> dict:
        return {
            "id": record["segment_id"],
            "tenant_id": SEGMENT_SCOPE,
            "ts": f"{record['sequence']:0{SEQUENCE_WIDTH}d}",
            "event_type": "segment.persisted",
            "agent_id": None,
            "agent_name": None,
            "actor": record["signer_key_id"],
            "detail": json.dumps(record, sort_keys=True, separators=(",", ":")),
        }

    def fetch_window(self, tenant_scope, start_exclusive, end_inclusive):
        if tenant_scope not in ("*", SEGMENT_SCOPE):
            return []
        return [self._row(record) for record in self._records()
                if (start_exclusive is None or f"{record['sequence']:0{SEQUENCE_WIDTH}d}" > start_exclusive)
                and f"{record['sequence']:0{SEQUENCE_WIDTH}d}" <= end_inclusive]


def write_high_water(path, records, journal_path, attestation_directory,
                     *, checkpoint_count: int, historical_segments=None,
                     lost_error_count: int | None = None) -> None:
    """Atomically advance protected freshness state after checkpoint publication."""
    if not records:
        raise AnchorError("cannot write segment high-water state for an empty inventory")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    previous = None
    if path.exists():
        try:
            previous = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise AnchorError(f"cannot read existing protected high-water state: {exc}") from exc
        if previous.get("schema_version") != HIGH_WATER_SCHEMA:
            raise AnchorError("existing protected high-water state has unsupported schema")
    if historical_segments is None:
        historical_segments = previous.get("historical_segments", []) if previous else []
    if lost_error_count is None:
        lost_error_count = previous.get("lost_error_count", 0) if previous else 0
    state = {
        "schema_version": HIGH_WATER_SCHEMA,
        "max_sequence": records[-1]["sequence"],
        "journal_size": Path(journal_path).stat().st_size,
        "attestation_count": len(list(Path(attestation_directory).glob("*.dsse.json"))),
        "checkpoint_count": checkpoint_count,
        "last_segment_id": records[-1]["segment_id"],
        "last_digest": records[-1]["digest"],
        "historical_segments": list(historical_segments),
        "lost_error_count": lost_error_count,
    }
    if previous is not None:
        for counter in (
            "max_sequence", "journal_size", "attestation_count", "checkpoint_count"
        ):
            if not isinstance(previous.get(counter), int):
                raise AnchorError(
                    f"existing protected high-water state has invalid {counter}"
                )
            if state[counter] < previous[counter]:
                raise IntegrityError(
                    f"refusing to decrease protected high-water {counter} from "
                    f"{previous[counter]} to {state[counter]}"
                )
        if state["max_sequence"] == previous["max_sequence"] and (
            state["last_segment_id"] != previous.get("last_segment_id")
            or state["last_digest"] != previous.get("last_digest")
        ):
            raise IntegrityError(
                "refusing to replace protected high-water segment tip at equal sequence"
            )
        if state["historical_segments"] != previous.get("historical_segments", []):
            raise IntegrityError("refusing to replace protected historical segment inventory")
        previous_lost = previous.get("lost_error_count", 0)
        if not isinstance(previous_lost, int) or isinstance(previous_lost, bool):
            raise AnchorError("existing protected high-water state has invalid lost_error_count")
        if state["lost_error_count"] < previous_lost:
            raise IntegrityError("refusing to decrease protected lost_error_count")
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(state, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
