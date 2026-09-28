#!/usr/bin/env python3
"""Validate SLED teardown evidence structure and internal consistency.

This validator does not collect evidence, authenticate supplied JSON, or prove
live cleanup. Its output deliberately cannot certify the complete SLED phase.

The manifest is read through one descriptor: the path is never resolved twice,
symlinks are refused, only regular files are read, and at most
MAX_MANIFEST_BYTES + 1 bytes ever leave the kernel. The SHA-256 digest in the
report is computed over exactly the bytes that were parsed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn


SCHEMA_VERSION = "sled-teardown-evidence/v1"
REQUIRED_PLANES = ("drain_routes", "openbao", "spire_svid", "tailscale", "namespace")
UNVERIFIED_CLAIMS = (
    "cryptographic_backup_erasure",
    "kernel_payload_sanitisation",
)
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{3,127}$")
# RFC 3339 UTC only: full date, "T", full time with seconds, optional fraction, "Z".
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$")
MAX_MANIFEST_BYTES = 524_288  # 512 KiB, SP-P1 hard ceiling
READ_CHUNK_BYTES = 65_536
MAX_JSON_DEPTH = 32  # a valid v1 manifest nests 6 levels deep
SYNTHETIC = "synthetic"

# Stable error codes -> (category, operator-facing triage text). The text is
# static: it never contains manifest values, so it cannot leak secrets.
ERROR_CATALOG: dict[str, tuple[str, str]] = {
    "manifest-unavailable": ("io", "manifest could not be opened; it is missing, unreadable, or a symlink"),
    "manifest-not-regular": ("io", "manifest is not a regular file (FIFO, device, directory or socket)"),
    "manifest-path-raced": ("io", "manifest path changed between lstat and open; re-collect and retry"),
    "manifest-too-large": ("io", "manifest exceeds the 512 KiB ceiling"),
    "manifest-digest-mismatch": ("integrity", "SHA-256 of the bytes read differs from --expected-sha256"),
    "malformed-expected-sha256": ("usage", "--expected-sha256 must be 64 lowercase hex characters"),
    "malformed-expected-commit": ("usage", "--expected-commit must be a full 40-character lowercase SHA"),
    "malformed-max-age": ("usage", "--max-age-seconds must be a positive integer"),
    "malformed-json": ("parse", "manifest is not strict UTF-8 JSON (bad syntax, NaN, huge number, or excessive nesting)"),
    "duplicate-json-key": ("parse", "manifest repeats a JSON object key"),
    "malformed-data": ("schema", "a manifest value has the wrong JSON type"),
    "malformed-field": ("schema", "a manifest field has an invalid value or format"),
    "missing-field": ("schema", "a required manifest field is absent"),
    "unexpected-field": ("schema", "the manifest carries a field outside the closed schema"),
    "unsupported-schema": ("schema", "schema_version is not sled-teardown-evidence/v1"),
    "plane-set-mismatch": ("schema", "the plane set is not exactly the five required planes"),
    "target-mismatch": ("consistency", "target_commit differs from --expected-commit"),
    "non-synthetic-fixture": ("safety", "the target fixture or its tenant is not declared synthetic"),
    "non-synthetic-sentinel": ("safety", "the sentinel fixture or its tenant is not declared synthetic"),
    "timestamp-order": ("consistency", "timestamps are not ordered started <= before < after <= finished"),
    "future-run": ("freshness", "finished_at is later than the reference time"),
    "stale-run": ("freshness", "finished_at is older than --max-age-seconds"),
    "stale-observation": ("freshness", "a before/after observation is older than --max-age-seconds"),
    "run-duration-exceeded": ("freshness", "the run lasted longer than --max-age-seconds"),
    "evidence-unavailable": ("evidence", "an observation reports the plane was unavailable"),
    "evidence-permission-denied": ("evidence", "an observation reports permission was denied"),
    "observation-failed": ("evidence", "an observation reports it did not succeed"),
    "duplicate-resource": ("consistency", "a resource identifier appears twice in one inventory"),
    "vacuous-before": ("evidence", "a plane or expected inventory was empty before teardown"),
    "plane-resource-mismatch": ("consistency", "a resource_type does not match the plane it is listed under"),
    "fixture-ownership-mismatch": ("consistency", "a target resource belongs to a different tenant"),
    "fixture-attribution-mismatch": ("consistency", "a target resource is attributed to a different fixture"),
    "preinventory-mismatch": ("consistency", "the observed pre-teardown inventory differs from the declared expected inventory"),
    "cleanup-incomplete": ("evidence", "target resources remain after teardown"),
    "missing-sentinel": ("evidence", "the sentinel inventory is empty"),
    "sentinel-ownership-mismatch": ("safety", "a sentinel resource or tenant overlaps the target fixture tenant"),
    "sentinel-attribution-mismatch": ("safety", "a sentinel resource or fixture overlaps the target fixture"),
    "sentinel-changed": ("safety", "the unrelated sentinel inventory changed during teardown"),
    "unverifiable-claim": ("consistency", "an unverifiable claim is not labelled UNVERIFIED"),
}


class EvidenceValidationError(ValueError):
    """A stable, non-sensitive validation failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class EvidenceSizeError(EvidenceValidationError):
    """The manifest byte stream exceeded MAX_MANIFEST_BYTES."""

    def __init__(self) -> None:
        super().__init__("manifest-too-large")


def _fail(code: str) -> NoReturn:
    raise EvidenceValidationError(code)


def describe_error(code: str) -> dict[str, str]:
    """Return static triage metadata for an error code; never manifest data."""

    category, detail = ERROR_CATALOG.get(code, ("unknown", "unclassified validation failure"))
    return {"error_category": category, "error_detail": detail}


def _read_manifest(path: str | os.PathLike[str]) -> bytes:
    """Read at most MAX_MANIFEST_BYTES from one descriptor bound to ``path``.

    lstat() records the directory entry, open() refuses to traverse a terminal
    symlink (O_NOFOLLOW) or block on a FIFO (O_NONBLOCK), and fstat() on the
    open descriptor must name the same (st_dev, st_ino) and a regular file.
    Where O_NOFOLLOW is unavailable, the (dev, ino) comparison still rejects a
    symlink, because lstat() describes the link and fstat() its target.
    """

    entry = os.lstat(path)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOCTTY", 0)
    )
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (entry.st_dev, entry.st_ino):
            _fail("manifest-path-raced")
        if not stat.S_ISREG(opened.st_mode):
            _fail("manifest-not-regular")
        if opened.st_size > MAX_MANIFEST_BYTES:
            raise EvidenceSizeError()
        chunks: list[bytes] = []
        total = 0
        # Read one byte past the ceiling so growth after fstat is still caught.
        while total <= MAX_MANIFEST_BYTES:
            chunk = os.read(fd, min(READ_CHUNK_BYTES, MAX_MANIFEST_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > MAX_MANIFEST_BYTES:
            raise EvidenceSizeError()
        return b"".join(chunks)
    finally:
        os.close(fd)


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate-json-key")
        result[key] = value
    return result


def _check_depth(value: Any) -> None:
    """Reject nesting deeper than any v1 manifest needs, independent of the
    interpreter's own recursion limit (which differs across Python versions)."""

    stack: list[tuple[Any, int]] = [(value, 1)]
    while stack:
        node, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            _fail("malformed-json")
        if isinstance(node, dict):
            stack.extend((child, depth + 1) for child in node.values())
        elif isinstance(node, list):
            stack.extend((child, depth + 1) for child in node)


def _parse_manifest(raw: bytes) -> Any:
    """Strictly decode UTF-8 and parse JSON; every parser failure is typed."""

    value = _parse_json(raw)
    _check_depth(value)
    return value


def _parse_json(raw: bytes) -> Any:
    try:
        return json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_json_object,
            parse_constant=lambda _value: _fail("malformed-json"),
        )
    except EvidenceValidationError:
        raise
    except (ValueError, RecursionError):
        # UnicodeDecodeError, JSONDecodeError, int-digit-limit ValueError and
        # deep-nesting RecursionError all mean the same thing to the caller.
        _fail("malformed-json")


def _object(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        _fail("malformed-data")
    return value


def _closed_object(
    value: Any,
    *,
    required: set[str],
    allowed: set[str] | None = None,
) -> dict[str, Any]:
    result = _object(value)
    missing = required - result.keys()
    if missing:
        _fail("missing-field")
    unexpected = result.keys() - (allowed or required)
    if unexpected:
        _fail("unexpected-field")
    return result


def _identifier(value: Any) -> str:
    if not isinstance(value, str) or not IDENTIFIER_RE.fullmatch(value):
        _fail("malformed-field")
    return value


def _identifier_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        _fail("malformed-data")
    identifiers = [_identifier(item) for item in value]
    if not identifiers:
        _fail("vacuous-before")
    if len(identifiers) != len(set(identifiers)):
        _fail("duplicate-resource")
    return sorted(identifiers)


def _timestamp(value: Any) -> datetime:
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        _fail("malformed-field")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        _fail("malformed-field")
    return parsed.astimezone(timezone.utc)


def _resource(value: Any) -> tuple[str, str, str, str]:
    item = _closed_object(
        value,
        required={"resource_id", "resource_type", "tenant_id", "fixture_id"},
    )
    return (
        _identifier(item["resource_id"]),
        _identifier(item["resource_type"]),
        _identifier(item["tenant_id"]),
        _identifier(item["fixture_id"]),
    )


def _observation(value: Any) -> list[tuple[str, str, str, str]]:
    item = _closed_object(
        value,
        required={"available", "permitted", "succeeded", "resources"},
    )
    for field, error in (
        ("available", "evidence-unavailable"),
        ("permitted", "evidence-permission-denied"),
        ("succeeded", "observation-failed"),
    ):
        if type(item[field]) is not bool:
            _fail("malformed-field")
        if not item[field]:
            _fail(error)
    if not isinstance(item["resources"], list):
        _fail("malformed-data")
    resources = [_resource(resource) for resource in item["resources"]]
    resource_ids = [resource[0] for resource in resources]
    if len(resource_ids) != len(set(resource_ids)):
        _fail("duplicate-resource")
    return resources


def _planes(value: Any) -> dict[str, Any]:
    planes = _object(value)
    if set(planes) != set(REQUIRED_PLANES):
        _fail("plane-set-mismatch")
    return planes


def _snapshot(value: Any) -> tuple[datetime, dict[str, Any], Any]:
    item = _closed_object(value, required={"observed_at", "planes", "sentinel"})
    return _timestamp(item["observed_at"]), _planes(item["planes"]), item["sentinel"]


def _synthetic(item: dict[str, Any], error: str) -> None:
    if item["kind"] != SYNTHETIC or item["tenant_kind"] != SYNTHETIC:
        _fail(error)


def _parse_now(value: str | datetime) -> datetime:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            _fail("malformed-field")
        return value.astimezone(timezone.utc)
    return _timestamp(value)


def validate_manifest(
    manifest: Any,
    *,
    expected_commit: str,
    now: str | datetime,
    max_age_seconds: int = 3600,
) -> dict[str, Any]:
    """Return a bounded report for a valid v1 manifest, otherwise raise."""

    if not isinstance(expected_commit, str) or not COMMIT_RE.fullmatch(expected_commit):
        _fail("malformed-expected-commit")
    if type(max_age_seconds) is not int or max_age_seconds <= 0:
        _fail("malformed-max-age")

    item = _closed_object(
        manifest,
        required={
            "schema_version",
            "run_id",
            "target_commit",
            "started_at",
            "finished_at",
            "fixture",
            "sentinel_fixture",
            "before",
            "after",
            "unverified_claims",
        },
    )
    if item["schema_version"] != SCHEMA_VERSION:
        _fail("unsupported-schema")
    run_id = _identifier(item["run_id"])
    target_commit = item["target_commit"]
    if not isinstance(target_commit, str) or not COMMIT_RE.fullmatch(target_commit):
        _fail("malformed-field")
    if target_commit != expected_commit:
        _fail("target-mismatch")

    # Synthetic status is declared, never inferred from identifier spelling.
    fixture = _closed_object(
        item["fixture"],
        required={"kind", "tenant_kind", "fixture_id", "tenant_id", "expected_preinventory"},
    )
    _synthetic(fixture, "non-synthetic-fixture")
    fixture_id = _identifier(fixture["fixture_id"])
    fixture_tenant = _identifier(fixture["tenant_id"])
    expected = _planes(fixture["expected_preinventory"])
    expected_ids = {plane: _identifier_list(expected[plane]) for plane in REQUIRED_PLANES}

    sentinel_fixture = _closed_object(
        item["sentinel_fixture"],
        required={"kind", "tenant_kind", "fixture_id", "tenant_id", "expected_resource_ids"},
    )
    _synthetic(sentinel_fixture, "non-synthetic-sentinel")
    sentinel_fixture_id = _identifier(sentinel_fixture["fixture_id"])
    sentinel_tenant = _identifier(sentinel_fixture["tenant_id"])
    if sentinel_tenant == fixture_tenant:
        _fail("sentinel-ownership-mismatch")
    if sentinel_fixture_id == fixture_id:
        _fail("sentinel-attribution-mismatch")
    if not isinstance(sentinel_fixture["expected_resource_ids"], list) or not sentinel_fixture["expected_resource_ids"]:
        _fail("missing-sentinel")
    sentinel_expected = _identifier_list(sentinel_fixture["expected_resource_ids"])

    started_at = _timestamp(item["started_at"])
    finished_at = _timestamp(item["finished_at"])
    before_at, before_planes, before_sentinel_value = _snapshot(item["before"])
    after_at, after_planes, after_sentinel_value = _snapshot(item["after"])
    if not (started_at <= before_at < after_at <= finished_at):
        _fail("timestamp-order")
    reference_time = _parse_now(now)
    if finished_at > reference_time:
        _fail("future-run")
    if (reference_time - finished_at).total_seconds() > max_age_seconds:
        _fail("stale-run")
    for observed_at in (before_at, after_at):
        if (reference_time - observed_at).total_seconds() > max_age_seconds:
            _fail("stale-observation")
    if (finished_at - started_at).total_seconds() > max_age_seconds:
        _fail("run-duration-exceeded")

    for plane in REQUIRED_PLANES:
        before_resources = _observation(before_planes[plane])
        if not before_resources:
            _fail("vacuous-before")
        if any(resource_type != plane for _, resource_type, _, _ in before_resources):
            _fail("plane-resource-mismatch")
        if any(tenant_id != fixture_tenant for _, _, tenant_id, _ in before_resources):
            _fail("fixture-ownership-mismatch")
        if any(owner != fixture_id for _, _, _, owner in before_resources):
            _fail("fixture-attribution-mismatch")
        if sorted(resource_id for resource_id, _, _, _ in before_resources) != expected_ids[plane]:
            _fail("preinventory-mismatch")

        after_resources = _observation(after_planes[plane])
        if after_resources:
            _fail("cleanup-incomplete")

    before_sentinel = _observation(before_sentinel_value)
    after_sentinel = _observation(after_sentinel_value)
    if not before_sentinel:
        _fail("missing-sentinel")
    for _, _, tenant_id, owner in before_sentinel + after_sentinel:
        if tenant_id != sentinel_tenant:
            _fail("sentinel-ownership-mismatch")
        if owner != sentinel_fixture_id:
            _fail("sentinel-attribution-mismatch")
    if sorted(resource_id for resource_id, _, _, _ in before_sentinel) != sentinel_expected:
        _fail("preinventory-mismatch")
    if sorted(before_sentinel) != sorted(after_sentinel):
        _fail("sentinel-changed")

    claims = _closed_object(item["unverified_claims"], required=set(UNVERIFIED_CLAIMS))
    if any(claims[name] != "UNVERIFIED" for name in UNVERIFIED_CLAIMS):
        _fail("unverifiable-claim")

    return {
        "schema_version": SCHEMA_VERSION,
        "valid": True,
        "status": "STRUCTURE_AND_CONSISTENCY_VERIFIED",
        "run_id": run_id,
        "target_commit": target_commit,
        "machine_verified_planes": list(REQUIRED_PLANES),
        "sentinel_unchanged": True,
        "unverified_claims": list(UNVERIFIED_CLAIMS),
        "phase3_certified": False,
        "authenticity_verified": False,
        "live_runtime_collection_required": True,
    }


def _error_report(code: str) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "valid": False,
        "error_code": code,
        **describe_error(code),
        "phase3_certified": False,
        "authenticity_verified": False,
        "live_runtime_collection_required": True,
    }


def verify_file(
    path: str | os.PathLike[str],
    *,
    expected_commit: str,
    now: str | datetime,
    max_age_seconds: int = 3600,
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Read, digest, parse and validate one manifest from a single descriptor."""

    if expected_sha256 is not None and not SHA256_RE.fullmatch(expected_sha256):
        _fail("malformed-expected-sha256")
    raw = _read_manifest(path)
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 is not None and digest != expected_sha256:
        _fail("manifest-digest-mismatch")
    report = validate_manifest(
        _parse_manifest(raw),
        expected_commit=expected_commit,
        now=now,
        max_age_seconds=max_age_seconds,
    )
    report["manifest_sha256"] = digest
    report["manifest_bytes"] = len(raw)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate SLED teardown evidence structure and consistency only."
    )
    parser.add_argument("manifest", nargs="?", type=Path, default=None)
    parser.add_argument("--evidence-file", type=Path, default=None, help="alternative path to manifest")
    parser.add_argument("--expected-commit", default=None, help="expected 40-character target commit")
    parser.add_argument(
        "--now",
        default=None,
        help="RFC3339 UTC reference time; injectable for deterministic validation",
    )
    parser.add_argument("--max-age-seconds", type=int, default=3600)
    parser.add_argument(
        "--expected-sha256",
        default=None,
        help="optional SHA-256 the manifest bytes must match (pins collector output)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    manifest_path = args.manifest or args.evidence_file
    if manifest_path is None:
        print(json.dumps(_error_report("manifest-unavailable"), sort_keys=True))
        return 2

    expected_commit = args.expected_commit
    if expected_commit is None:
        try:
            raw = _read_manifest(manifest_path)
            parsed = _parse_manifest(raw)
            if isinstance(parsed, dict) and "target_commit" in parsed:
                expected_commit = parsed["target_commit"]
        except Exception:
            pass

    now_ref = args.now or datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    try:
        report = verify_file(
            manifest_path,
            expected_commit=expected_commit or "",
            now=now_ref,
            max_age_seconds=args.max_age_seconds,
            expected_sha256=args.expected_sha256,
        )
    except EvidenceValidationError as error:
        print(json.dumps(_error_report(error.code), sort_keys=True))
        return 2
    except OSError:
        print(json.dumps(_error_report("manifest-unavailable"), sort_keys=True))
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
