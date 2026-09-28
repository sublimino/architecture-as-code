#!/usr/bin/env python3
"""Hermetic tests for the SLED teardown evidence validator."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
VALIDATOR = ROOT / "scripts/eap/verify_teardown_evidence.py"
TARGET_COMMIT = "a" * 40
NOW = "2026-09-28T02:30:00Z"
PLANES = ("drain_routes", "openbao", "spire_svid", "tailscale", "namespace")


def resource(
    plane: str,
    tenant_id: str = "tenant-alpha",
    fixture_id: str = "fixture-alpha",
) -> dict[str, str]:
    return {
        "resource_id": f"expected-{plane}",
        "resource_type": plane,
        "tenant_id": tenant_id,
        "fixture_id": fixture_id,
    }


def observation(resources: list[dict[str, str]]) -> dict[str, object]:
    return {
        "available": True,
        "permitted": True,
        "succeeded": True,
        "resources": resources,
    }


def valid_manifest() -> dict[str, object]:
    sentinel = resource("namespace", "tenant-sentinel", "fixture-sentinel")
    sentinel["resource_id"] = "expected-sentinel-namespace"
    return {
        "schema_version": "sled-teardown-evidence/v1",
        "run_id": "sled-run-20260928-alpha",
        "target_commit": TARGET_COMMIT,
        "started_at": "2026-09-28T02:20:00Z",
        "finished_at": "2026-09-28T02:25:00Z",
        "fixture": {
            "kind": "synthetic",
            "tenant_kind": "synthetic",
            "fixture_id": "fixture-alpha",
            "tenant_id": "tenant-alpha",
            "expected_preinventory": {
                plane: [f"expected-{plane}"] for plane in PLANES
            },
        },
        "sentinel_fixture": {
            "kind": "synthetic",
            "tenant_kind": "synthetic",
            "fixture_id": "fixture-sentinel",
            "tenant_id": "tenant-sentinel",
            "expected_resource_ids": ["expected-sentinel-namespace"],
        },
        "before": {
            "observed_at": "2026-09-28T02:21:00Z",
            "planes": {plane: observation([resource(plane)]) for plane in PLANES},
            "sentinel": observation([sentinel]),
        },
        "after": {
            "observed_at": "2026-09-28T02:24:00Z",
            "planes": {plane: observation([]) for plane in PLANES},
            "sentinel": observation([copy.deepcopy(sentinel)]),
        },
        "unverified_claims": {
            "cryptographic_backup_erasure": "UNVERIFIED",
            "kernel_payload_sanitisation": "UNVERIFIED",
        },
    }


def load_validator():
    spec = importlib.util.spec_from_file_location("verify_teardown_evidence", VALIDATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load validator")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.validator = load_validator()

    def assert_invalid(self, manifest: dict[str, object], code: str) -> None:
        with self.assertRaises(self.validator.EvidenceValidationError) as raised:
            self.validator.validate_manifest(
                manifest,
                expected_commit=TARGET_COMMIT,
                now=NOW,
                max_age_seconds=3600,
            )
        self.assertEqual(raised.exception.code, code)

    def test_positive_control_returns_bounded_report(self) -> None:
        manifest = valid_manifest()
        manifest["ignored_success_claim"] = True
        self.assert_invalid(manifest, "unexpected-field")
        manifest.pop("ignored_success_claim")
        report = self.validator.validate_manifest(
            manifest,
            expected_commit=TARGET_COMMIT,
            now=NOW,
            max_age_seconds=3600,
        )
        self.assertTrue(report["valid"])
        self.assertFalse(report["phase3_certified"])
        self.assertEqual(report["run_id"], manifest["run_id"])
        self.assertEqual(report["target_commit"], TARGET_COMMIT)
        self.assertEqual(set(report["machine_verified_planes"]), set(PLANES))
        self.assertEqual(
            report["unverified_claims"],
            ["cryptographic_backup_erasure", "kernel_payload_sanitisation"],
        )
        self.assertNotIn("fixture", report)
        self.assertNotIn("before", report)
        self.assertNotIn("after", report)

    def test_rejects_stale_run(self) -> None:
        manifest = valid_manifest()
        manifest["started_at"] = "2026-09-28T00:00:00Z"
        manifest["before"]["observed_at"] = "2026-09-28T00:01:00Z"  # type: ignore[index]
        manifest["after"]["observed_at"] = "2026-09-28T00:02:00Z"  # type: ignore[index]
        manifest["finished_at"] = "2026-09-28T00:03:00Z"
        self.assert_invalid(manifest, "stale-run")

    def test_rejects_mismatched_target_commit(self) -> None:
        manifest = valid_manifest()
        manifest["target_commit"] = "b" * 40
        self.assert_invalid(manifest, "target-mismatch")

    def test_rejects_malformed_target_commit(self) -> None:
        manifest = valid_manifest()
        manifest["target_commit"] = "main"
        self.assert_invalid(manifest, "malformed-field")

    def test_rejects_missing_run_id(self) -> None:
        manifest = valid_manifest()
        del manifest["run_id"]
        self.assert_invalid(manifest, "missing-field")

    def test_rejects_non_synthetic_fixture(self) -> None:
        manifest = valid_manifest()
        manifest["fixture"]["kind"] = "production"  # type: ignore[index]
        self.assert_invalid(manifest, "non-synthetic-fixture")

    def test_rejects_never_populated_before_plane(self) -> None:
        manifest = valid_manifest()
        manifest["before"]["planes"]["tailscale"]["resources"] = []  # type: ignore[index]
        self.assert_invalid(manifest, "vacuous-before")

    def test_rejects_omitted_plane(self) -> None:
        manifest = valid_manifest()
        del manifest["after"]["planes"]["openbao"]  # type: ignore[index]
        self.assert_invalid(manifest, "plane-set-mismatch")

    def test_rejects_extra_plane(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["unknown"] = observation([])  # type: ignore[index]
        self.assert_invalid(manifest, "plane-set-mismatch")

    def test_rejects_unsuccessful_observation(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["namespace"]["succeeded"] = False  # type: ignore[index]
        self.assert_invalid(manifest, "observation-failed")

    def test_rejects_unavailable_evidence(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["spire_svid"]["available"] = False  # type: ignore[index]
        self.assert_invalid(manifest, "evidence-unavailable")

    def test_rejects_permission_denied_evidence(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["openbao"]["permitted"] = False  # type: ignore[index]
        self.assert_invalid(manifest, "evidence-permission-denied")

    def test_rejects_success_flag_without_inventory(self) -> None:
        manifest = valid_manifest()
        del manifest["after"]["planes"]["drain_routes"]["resources"]  # type: ignore[index]
        self.assert_invalid(manifest, "missing-field")

    def test_rejects_target_resource_remaining_after_cleanup(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["tailscale"]["resources"] = [resource("tailscale")]  # type: ignore[index]
        self.assert_invalid(manifest, "cleanup-incomplete")

    def test_rejects_unrelated_tenant_deletion(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["sentinel"]["resources"] = []  # type: ignore[index]
        self.assert_invalid(manifest, "sentinel-changed")

    def test_rejects_unrelated_tenant_modification(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["sentinel"]["resources"][0]["resource_id"] = "changed"  # type: ignore[index]
        self.assert_invalid(manifest, "sentinel-changed")

    def test_rejects_fixture_resource_owned_by_sentinel(self) -> None:
        manifest = valid_manifest()
        manifest["before"]["planes"]["namespace"]["resources"][0]["tenant_id"] = "tenant-sentinel"  # type: ignore[index]
        self.assert_invalid(manifest, "fixture-ownership-mismatch")

    def test_rejects_sentinel_owned_by_fixture(self) -> None:
        manifest = valid_manifest()
        manifest["before"]["sentinel"]["resources"][0]["tenant_id"] = "tenant-alpha"  # type: ignore[index]
        self.assert_invalid(manifest, "sentinel-ownership-mismatch")

    def test_rejects_bad_timestamp_order(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["observed_at"] = "2026-09-28T02:20:30Z"  # type: ignore[index]
        self.assert_invalid(manifest, "timestamp-order")

    def test_rejects_future_finished_timestamp(self) -> None:
        manifest = valid_manifest()
        manifest["finished_at"] = "2026-09-28T03:00:00Z"
        self.assert_invalid(manifest, "future-run")

    def test_requires_unverified_claim_labels(self) -> None:
        manifest = valid_manifest()
        manifest["unverified_claims"]["cryptographic_backup_erasure"] = "VERIFIED"  # type: ignore[index]
        self.assert_invalid(manifest, "unverifiable-claim")

    def test_rejects_secret_bearing_or_unknown_fields(self) -> None:
        manifest = valid_manifest()
        manifest["fixture"]["token"] = "do-not-echo"  # type: ignore[index]
        self.assert_invalid(manifest, "unexpected-field")

    def test_rejects_duplicate_resource_identifiers(self) -> None:
        manifest = valid_manifest()
        duplicate = resource("tailscale")
        manifest["before"]["planes"]["tailscale"]["resources"] = [duplicate, duplicate]  # type: ignore[index]
        self.assert_invalid(manifest, "duplicate-resource")

    def test_rejects_expected_preinventory_mismatch(self) -> None:
        manifest = valid_manifest()
        manifest["fixture"]["expected_preinventory"]["tailscale"] = ["different-id"]  # type: ignore[index]
        self.assert_invalid(manifest, "preinventory-mismatch")

    def test_rejects_resource_fixture_attribution_mismatch(self) -> None:
        manifest = valid_manifest()
        manifest["before"]["planes"]["tailscale"]["resources"][0]["fixture_id"] = "other-fixture"  # type: ignore[index]
        self.assert_invalid(manifest, "fixture-attribution-mismatch")

    def test_identifiers_do_not_fabricate_proof_from_names(self) -> None:
        manifest = valid_manifest()
        manifest["fixture"]["fixture_id"] = "arbitrary-fixture-id"  # type: ignore[index]
        manifest["fixture"]["tenant_id"] = "arbitrary-tenant-id"  # type: ignore[index]
        for plane in PLANES:
            record = manifest["before"]["planes"][plane]["resources"][0]  # type: ignore[index]
            record["fixture_id"] = "arbitrary-fixture-id"
            record["tenant_id"] = "arbitrary-tenant-id"
        self.validator.validate_manifest(
            manifest, expected_commit=TARGET_COMMIT, now=NOW, max_age_seconds=3600
        )

    def test_rejects_non_synthetic_sentinel_tenant(self) -> None:
        manifest = valid_manifest()
        manifest["sentinel_fixture"]["tenant_kind"] = "production"  # type: ignore[index]
        self.assert_invalid(manifest, "non-synthetic-sentinel")

    def test_rejects_sentinel_fixture_attribution_mismatch(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["sentinel"]["resources"][0]["fixture_id"] = "other-fixture"  # type: ignore[index]
        self.assert_invalid(manifest, "sentinel-attribution-mismatch")

    def test_rejects_unknown_nested_observation_field(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["openbao"]["claim"] = "success"  # type: ignore[index]
        self.assert_invalid(manifest, "unexpected-field")

    def test_rejects_observation_outside_freshness_window(self) -> None:
        manifest = valid_manifest()
        manifest["started_at"] = "2020-01-01T00:00:00Z"
        manifest["before"]["observed_at"] = "2020-01-01T00:01:00Z"  # type: ignore[index]
        self.assert_invalid(manifest, "stale-observation")

    def test_rejects_run_duration_exceeding_freshness_window(self) -> None:
        # Observations stay fresh; only the run start is outside the window.
        # (The preserved suite set before.observed_at too, which made this
        # input identical to the stale-observation test above.)
        manifest = valid_manifest()
        manifest["started_at"] = "2020-01-01T00:00:00Z"
        self.assert_invalid(manifest, "run-duration-exceeded")

    def test_rejects_non_rfc3339_timestamp_variants(self) -> None:
        for invalid in (
            "20260928T022000Z",
            "2026-W40-1T02:20:00Z",
            "2026-09-28 02:20:00Z",
            "2026-09-28T02:20Z",
        ):
            with self.subTest(invalid=invalid):
                manifest = valid_manifest()
                manifest["started_at"] = invalid
                self.assert_invalid(manifest, "malformed-field")

    def test_read_manifest_rejects_raced_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text(json.dumps(valid_manifest()), encoding="utf-8")
            real_lstat = os.lstat
            original = real_lstat(path)
            replacement = types.SimpleNamespace(st_dev=original.st_dev, st_ino=original.st_ino + 1)
            with mock.patch.object(self.validator.os, "lstat", return_value=replacement):
                with self.assertRaises(self.validator.EvidenceValidationError) as raised:
                    self.validator._read_manifest(path)
        self.assertEqual(raised.exception.code, "manifest-path-raced")


class CliTests(unittest.TestCase):
    def run_cli(self, manifest: object) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT,
                 "--now", NOW, "--max-age-seconds", "3600"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_cli_positive_control_outputs_json(self) -> None:
        result = self.run_cli(valid_manifest())
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["valid"])
        self.assertFalse(report["phase3_certified"])
        self.assertEqual(result.stderr, "")

    def test_cli_negative_control_returns_two(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["namespace"]["resources"] = [resource("namespace")]  # type: ignore[index]
        result = self.run_cli(manifest)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertFalse(report["valid"])
        self.assertEqual(report["error_code"], "cleanup-incomplete")
        self.assertFalse(report["phase3_certified"])

    def test_cli_never_echoes_unknown_secret_value(self) -> None:
        manifest = valid_manifest()
        manifest["api_token"] = "super-secret-value"
        result = self.run_cli(manifest)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("super-secret-value", result.stdout + result.stderr)

    def test_cli_rejects_target_mismatch(self) -> None:
        manifest = valid_manifest()
        manifest["target_commit"] = "b" * 40
        result = self.run_cli(manifest)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_code"], "target-mismatch")

    def test_cli_rejects_stale_evidence(self) -> None:
        result = self.run_cli(valid_manifest())
        self.assertEqual(result.returncode, 0)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text(json.dumps(valid_manifest()), encoding="utf-8")
            stale = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT,
                 "--now", "2026-09-28T04:30:00Z", "--max-age-seconds", "3600"],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
        self.assertEqual(stale.returncode, 2)
        self.assertEqual(json.loads(stale.stdout)["error_code"], "stale-run")

    def test_cli_rejects_missing_manifest(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "/path/that/does/not/exist.json",
             "--expected-commit", TARGET_COMMIT, "--now", NOW],
            cwd=ROOT, text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_code"], "manifest-unavailable")

    def test_cli_rejects_invalid_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text("{not-json", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT, "--now", NOW],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_code"], "malformed-json")

    def test_cli_rejects_duplicate_json_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text('{"schema_version":"one","schema_version":"two"}', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT,
                 "--now", NOW],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_code"], "duplicate-json-key")

    def test_cli_rejects_nested_duplicate_json_keys(self) -> None:
        raw = json.dumps(valid_manifest())
        raw = raw.replace('"fixture_id": "fixture-alpha"',
                          '"fixture_id": "fixture-alpha", "fixture_id": "other"', 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text(raw, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT,
                 "--now", NOW], cwd=ROOT, text=True, capture_output=True, check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_code"], "duplicate-json-key")

    def test_cli_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target.json"
            target.write_text(json.dumps(valid_manifest()), encoding="utf-8")
            link = Path(tmp) / "evidence.json"
            link.symlink_to(target)
            result = self.run_cli_path(link)
        self.assert_cli_error(result, "manifest-unavailable")

    def test_cli_rejects_fifo_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fifo = Path(tmp) / "evidence.fifo"
            os.mkfifo(fifo)
            result = self.run_cli_path(fifo, timeout=2)
        self.assert_cli_error(result, "manifest-not-regular")

    def test_cli_rejects_device(self) -> None:
        result = self.run_cli_path(Path("/dev/null"))
        self.assert_cli_error(result, "manifest-not-regular")

    def test_cli_rejects_oversized_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(b" " * (1_048_576 + 1))
            result = self.run_cli_path(path)
        self.assert_cli_error(result, "manifest-too-large")

    def test_cli_catches_huge_integer_value_error(self) -> None:
        self.assert_raw_json_error('{"value":' + ("9" * 10000) + "}")

    def test_cli_catches_excessive_nesting_recursion_error(self) -> None:
        self.assert_raw_json_error("[" * 2000 + "]" * 2000)

    def run_cli_path(
        self, path: Path, *, timeout: float = 5, extra: list[str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(path), "--expected-commit", TARGET_COMMIT,
             "--now", NOW, "--max-age-seconds", "3600", *(extra or [])],
            cwd=ROOT, text=True, capture_output=True, check=False, timeout=timeout,
        )

    def assert_cli_error(self, result: subprocess.CompletedProcess[str], code: str) -> None:
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout)["error_code"], code)

    def assert_raw_json_error(self, raw: str) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text(raw, encoding="utf-8")
            result = self.run_cli_path(path)
        self.assert_cli_error(result, "malformed-json")

    def test_cli_error_report_carries_static_triage_detail(self) -> None:
        manifest = valid_manifest()
        manifest["after"]["planes"]["namespace"]["resources"] = [resource("namespace")]  # type: ignore[index]
        result = self.run_cli(manifest)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["error_category"], "evidence")
        self.assertIn("remain after teardown", report["error_detail"])
        self.assertNotIn("expected-namespace", result.stdout)

    def test_cli_success_reports_digest_of_bytes_read(self) -> None:
        raw = json.dumps(valid_manifest()).encode("utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(raw)
            result = self.run_cli_path(path)
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["manifest_sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(report["manifest_bytes"], len(raw))

    def test_cli_rejects_mutated_digest(self) -> None:
        raw = json.dumps(valid_manifest()).encode("utf-8")
        pinned = hashlib.sha256(raw).hexdigest()
        tampered = raw.replace(b"sled-run-20260928-alpha", b"sled-run-20260928-omega")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(raw)
            ok = self.run_cli_path(path, extra=["--expected-sha256", pinned])
            path.write_bytes(tampered)
            bad = self.run_cli_path(path, extra=["--expected-sha256", pinned])
            malformed = self.run_cli_path(path, extra=["--expected-sha256", "ABC"])
        self.assertEqual(ok.returncode, 0, ok.stdout)
        self.assert_cli_error(bad, "manifest-digest-mismatch")
        self.assert_cli_error(malformed, "malformed-expected-sha256")

    def test_cli_rejects_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_cli_path(Path(tmp))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn(json.loads(result.stdout)["error_code"],
                      {"manifest-not-regular", "manifest-unavailable"})

    def test_cli_rejects_non_utf8_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(b'{"run_id": "\xff\xfe"}')
            result = self.run_cli_path(path)
        self.assert_cli_error(result, "malformed-json")

    def test_cli_rejects_nan_constant(self) -> None:
        self.assert_raw_json_error('{"value": NaN}')

    def test_cli_rejects_truncated_payload(self) -> None:
        raw = json.dumps(valid_manifest())
        self.assert_raw_json_error(raw[: len(raw) // 2])

    def test_cli_help_exits_zero(self) -> None:
        result = subprocess.run([sys.executable, str(VALIDATOR), "--help"],
                                cwd=ROOT, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--expected-sha256", result.stdout)


class DescriptorReaderTests(unittest.TestCase):
    """Security invariants of the single-descriptor bounded reader."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.validator = load_validator()

    def test_ceiling_is_512_kib(self) -> None:
        self.assertEqual(self.validator.MAX_MANIFEST_BYTES, 524_288)

    def test_accepts_exactly_the_ceiling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(b" " * 524_288)
            self.assertEqual(len(self.validator._read_manifest(path)), 524_288)

    def test_rejects_one_byte_over_the_ceiling_with_size_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(b" " * 524_289)
            with self.assertRaises(self.validator.EvidenceSizeError) as raised:
                self.validator._read_manifest(path)
        self.assertEqual(raised.exception.code, "manifest-too-large")
        self.assertIsInstance(raised.exception, self.validator.EvidenceValidationError)

    def test_growth_after_fstat_is_bounded_by_read_ceiling(self) -> None:
        # fstat reports a tiny file; the stream then yields more than the
        # ceiling. The reader must stop at MAX+1 bytes and reject.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(b" " * 16)
            real_fstat = os.fstat
            requested: list[int] = []

            def small_fstat(fd: int):
                result = real_fstat(fd)
                return types.SimpleNamespace(st_dev=result.st_dev, st_ino=result.st_ino,
                                             st_mode=result.st_mode, st_size=16)

            def endless_read(fd: int, size: int) -> bytes:
                requested.append(size)
                return b" " * size

            with mock.patch.object(self.validator.os, "fstat", side_effect=small_fstat), \
                    mock.patch.object(self.validator.os, "read", side_effect=endless_read):
                with self.assertRaises(self.validator.EvidenceSizeError):
                    self.validator._read_manifest(path)
        self.assertEqual(sum(requested), 524_289)

    def test_symlink_is_refused_without_reading_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target.json"
            target.write_text(json.dumps(valid_manifest()), encoding="utf-8")
            link = Path(tmp) / "evidence.json"
            link.symlink_to(target)
            real_read = os.read
            with mock.patch.object(self.validator.os, "read", side_effect=real_read) as reads:
                with self.assertRaises((OSError, self.validator.EvidenceValidationError)):
                    self.validator._read_manifest(link)
            self.assertEqual(reads.call_count, 0)

    def test_open_requests_nofollow_and_nonblock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_text("{}", encoding="utf-8")
            real_open = os.open
            with mock.patch.object(self.validator.os, "open", side_effect=real_open) as opened:
                self.validator._read_manifest(path)
        flags = opened.call_args.args[1]
        self.assertTrue(flags & os.O_NOFOLLOW)
        self.assertTrue(flags & os.O_NONBLOCK)
        self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)

    def test_symlink_rejected_by_inode_check_when_nofollow_absent(self) -> None:
        # Portable fallback: without O_NOFOLLOW, lstat names the link and
        # fstat names its target, so the (dev, ino) comparison rejects it.
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target.json"
            target.write_text("{}", encoding="utf-8")
            link = Path(tmp) / "evidence.json"
            link.symlink_to(target)
            fake_os = types.SimpleNamespace(**{name: getattr(os, name) for name in dir(os)
                                               if not name.startswith("__") and name != "O_NOFOLLOW"})
            with mock.patch.object(self.validator, "os", fake_os):
                with self.assertRaises(self.validator.EvidenceValidationError) as raised:
                    self.validator._read_manifest(link)
        self.assertEqual(raised.exception.code, "manifest-path-raced")

    def test_descriptor_closed_on_every_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ok = Path(tmp) / "ok.json"
            ok.write_text("{}", encoding="utf-8")
            big = Path(tmp) / "big.json"
            big.write_bytes(b" " * 524_289)
            real_close = os.close
            for path in (ok, big, Path("/dev/null")):
                with self.subTest(path=path.name), \
                        mock.patch.object(self.validator.os, "close", side_effect=real_close) as closed:
                    try:
                        self.validator._read_manifest(path)
                    except self.validator.EvidenceValidationError:
                        pass
                    self.assertEqual(closed.call_count, 1)

    def test_digest_is_computed_over_bytes_actually_read(self) -> None:
        # The file is swapped for different content after the read; the
        # report must describe what was parsed, not what is now on disk.
        raw = json.dumps(valid_manifest()).encode("utf-8")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            path.write_bytes(raw)
            real_reader = self.validator._read_manifest

            def read_then_swap(p):
                data = real_reader(p)
                Path(p).write_bytes(b"{}")
                return data

            with mock.patch.object(self.validator, "_read_manifest", side_effect=read_then_swap):
                report = self.validator.verify_file(path, expected_commit=TARGET_COMMIT, now=NOW)
        self.assertEqual(report["manifest_sha256"], hashlib.sha256(raw).hexdigest())

    def test_deep_nesting_beyond_interpreter_limit_is_malformed_json(self) -> None:
        with self.assertRaises(self.validator.EvidenceValidationError) as raised:
            self.validator._parse_manifest(("[" * 200_000 + "]" * 200_000).encode())
        self.assertEqual(raised.exception.code, "malformed-json")

    def test_duplicate_key_is_not_masked_as_malformed_json(self) -> None:
        with self.assertRaises(self.validator.EvidenceValidationError) as raised:
            self.validator._parse_manifest(b'{"a": {"b": 1, "b": 2}}')
        self.assertEqual(raised.exception.code, "duplicate-json-key")


class TamperAndTriageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.validator = load_validator()

    def validate(self, manifest: object) -> dict[str, object]:
        return self.validator.validate_manifest(
            manifest, expected_commit=TARGET_COMMIT, now=NOW, max_age_seconds=3600
        )

    def assert_code(self, manifest: object, code: str) -> None:
        with self.assertRaises(self.validator.EvidenceValidationError) as raised:
            self.validate(manifest)
        self.assertEqual(raised.exception.code, code)

    def test_missing_stage_in_before_snapshot(self) -> None:
        manifest = valid_manifest()
        del manifest["before"]["planes"]["spire_svid"]  # type: ignore[index]
        self.assert_code(manifest, "plane-set-mismatch")

    def test_missing_stage_in_expected_preinventory(self) -> None:
        manifest = valid_manifest()
        del manifest["fixture"]["expected_preinventory"]["openbao"]  # type: ignore[index]
        self.assert_code(manifest, "plane-set-mismatch")

    def test_reordered_checkpoints(self) -> None:
        manifest = valid_manifest()
        before = manifest["before"]["observed_at"]  # type: ignore[index]
        manifest["before"]["observed_at"] = manifest["after"]["observed_at"]  # type: ignore[index]
        manifest["after"]["observed_at"] = before  # type: ignore[index]
        self.assert_code(manifest, "timestamp-order")

    def test_extra_resource_not_in_expected_preinventory(self) -> None:
        manifest = valid_manifest()
        extra = resource("openbao")
        extra["resource_id"] = "unexpected-openbao"
        manifest["before"]["planes"]["openbao"]["resources"].append(extra)  # type: ignore[index]
        self.assert_code(manifest, "preinventory-mismatch")

    def test_sentinel_sharing_fixture_tenant(self) -> None:
        manifest = valid_manifest()
        manifest["sentinel_fixture"]["tenant_id"] = "tenant-alpha"  # type: ignore[index]
        self.assert_code(manifest, "sentinel-ownership-mismatch")

    def test_non_synthetic_fixture_tenant_kind(self) -> None:
        manifest = valid_manifest()
        manifest["fixture"]["tenant_kind"] = "customer"  # type: ignore[index]
        self.assert_code(manifest, "non-synthetic-fixture")

    def test_every_raised_code_has_triage_detail(self) -> None:
        source = VALIDATOR.read_text(encoding="utf-8")
        raised = set(re.findall(r'_fail\("([a-z0-9-]+)"\)', source)) | {"manifest-too-large",
                                                                          "manifest-unavailable"}
        self.assertTrue(raised)
        self.assertEqual(raised - set(self.validator.ERROR_CATALOG), set())
        for code in raised:
            detail = self.validator.describe_error(code)
            self.assertNotEqual(detail["error_category"], "unknown", code)
            self.assertTrue(detail["error_detail"], code)

    def test_structural_fuzzing_raises_only_typed_errors(self) -> None:
        rng = random.Random(20260928)
        junk = [None, True, 0, -1, 1.5, "", "x" * 300, [], {}, [None], {"k": None},
                "2026-09-28T02:20:00Z", "UNVERIFIED", "synthetic"]

        def paths(node, prefix=()):
            yield prefix
            if isinstance(node, dict):
                for key, value in node.items():
                    yield from paths(value, prefix + (key,))
            elif isinstance(node, list):
                for index, value in enumerate(node):
                    yield from paths(value, prefix + (index,))

        all_paths = [p for p in paths(valid_manifest()) if p]
        for iteration in range(1500):
            manifest = valid_manifest()
            for _ in range(rng.randint(1, 3)):
                path = rng.choice(all_paths)
                parent = manifest
                try:
                    for key in path[:-1]:
                        parent = parent[key]
                    action = rng.random()
                    if action < 0.2 and isinstance(parent, dict):
                        parent.pop(path[-1], None)
                    else:
                        parent[path[-1]] = copy.deepcopy(rng.choice(junk))
                except (KeyError, IndexError, TypeError):
                    continue
            with self.subTest(iteration=iteration):
                try:
                    self.validate(manifest)
                except self.validator.EvidenceValidationError as error:
                    self.assertIn(error.code, self.validator.ERROR_CATALOG)

    def test_byte_fuzzing_cli_never_tracebacks(self) -> None:
        rng = random.Random(4242)
        raw = bytearray(json.dumps(valid_manifest()).encode("utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "evidence.json"
            for iteration in range(400):
                mutated = bytearray(raw)
                for _ in range(rng.randint(1, 8)):
                    mutated[rng.randrange(len(mutated))] = rng.randrange(256)
                path.write_bytes(bytes(mutated))
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    code = self.validator.main([str(path), "--expected-commit", TARGET_COMMIT,
                                                "--now", NOW])
                with self.subTest(iteration=iteration):
                    self.assertIn(code, (0, 2))
                    report = json.loads(out.getvalue())
                    self.assertEqual(report["valid"], code == 0)


if __name__ == "__main__":
    unittest.main()
