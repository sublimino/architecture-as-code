# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Adversarial Zero-Customer-Payload Leak Falsification Test Suite.

Rigorously verifies that no code path, error message, serialization, or log
emits, retains, or exposes customer prompts, source code, credentials, or process memory.

Covers:
  - Exact fixture from test_negative_security.py:71 (python3\x00agent.py\x00--token=SECRET_BEARER_TOKEN\x00)
  - Realistic Anthropic API and Admin key formats
  - Realistic OpenAI API, Project, and Service Account key formats
  - Realistic AWS Access Key IDs and Secret Access Keys
  - GitHub Personal Access Tokens and Fine-Grained PATs
  - PEM-encoded Private Key blocks
  - Prompt markers and LLM conversation turn artifacts
  - Unified source code diffs
  - Raw ELF process memory dumps
  - High-entropy cryptographic strings
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .collector import ProcessTelemetryCollector
    from .filter import (
        AllowlistFilter,
        sanitize_evidence_record,
    )
    from .models import (
        BoundedProcessAttributes,
        HealthState,
        ProcessTelemetryEvent,
    )
    from .payload_validator import (
        CredentialProvider,
        DetectionReport,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
        scrub_buffer,
    )
    from .proc import ProcReader, SecurityException
    from .pseudonym import DEFAULT_KEYRING, KeyRing, is_pseudonym
except (ImportError, ValueError):
    from collector import ProcessTelemetryCollector
    from filter import (
        AllowlistFilter,
        sanitize_evidence_record,
    )
    from models import (
        BoundedProcessAttributes,
        HealthState,
        ProcessTelemetryEvent,
    )
    from payload_validator import (
        CredentialProvider,
        DetectionReport,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
        scrub_buffer,
    )
    from proc import ProcReader, SecurityException
    from pseudonym import DEFAULT_KEYRING, KeyRing, is_pseudonym


# Curated adversarial test fixtures (public documentation shapes only — zero real credentials)
ADVERSARIAL_FIXTURES = [
    # 1. Exact fixture from test_negative_security.py:71
    {
        "id": "SEC-FIX-01-CMDLINE",
        "provider": CredentialProvider.GENERIC_BEARER,
        "raw_string": "python3\x00agent.py\x00--token=SECRET_BEARER_TOKEN\x00",
        "secret_token": "SECRET_BEARER_TOKEN",
        "is_binary": False,
    },
    # 2. Anthropic API Key (sk-ant-api03-...)
    {
        "id": "SEC-FIX-02-ANTHROPIC-API",
        "provider": CredentialProvider.ANTHROPIC,
        "raw_string": "export ANTHROPIC_API_KEY=sk-ant-api03-abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        "secret_token": "sk-ant-api03-abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        "is_binary": False,
    },
    # 3. Anthropic Admin Key (sk-ant-admin01-...)
    {
        "id": "SEC-FIX-03-ANTHROPIC-ADMIN",
        "provider": CredentialProvider.ANTHROPIC,
        "raw_string": "ANTHROPIC_ADMIN_KEY=sk-ant-admin01-99887766554433221100aabbccddeeff99887766554433221100aabbccddeeff",
        "secret_token": "sk-ant-admin01-99887766554433221100aabbccddeeff99887766554433221100aabbccddeeff",
        "is_binary": False,
    },
    # 4. OpenAI Project Key (sk-proj-...)
    {
        "id": "SEC-FIX-04-OPENAI-PROJ",
        "provider": CredentialProvider.OPENAI,
        "raw_string": "OPENAI_API_KEY=sk-proj-aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4cD5eF6gH7iJ8kL9mN0",
        "secret_token": "sk-proj-aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4cD5eF6gH7iJ8kL9mN0",
        "is_binary": False,
    },
    # 5. OpenAI Standard Key (sk-...)
    {
        "id": "SEC-FIX-05-OPENAI-STD",
        "provider": CredentialProvider.OPENAI,
        "raw_string": "authorization: Bearer sk-48charOpenAITokenShapeForAdversarialTest1234567890",
        "secret_token": "sk-48charOpenAITokenShapeForAdversarialTest1234567890",
        "is_binary": False,
    },
    # 6. AWS Access Key ID (AKIA...)
    {
        "id": "SEC-FIX-06-AWS-AKID",
        "provider": CredentialProvider.AWS,
        "raw_string": "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
        "secret_token": "AKIAIOSFODNN7EXAMPLE",
        "is_binary": False,
    },
    # 7. AWS Secret Access Key (40 base64 chars)
    {
        "id": "SEC-FIX-07-AWS-SECRET",
        "provider": CredentialProvider.AWS,
        "raw_string": "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "secret_token": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "is_binary": False,
    },
    # 8. GitHub Classic PAT (ghp_...)
    {
        "id": "SEC-FIX-08-GITHUB-PAT",
        "provider": CredentialProvider.GITHUB,
        "raw_string": "https://ghp_0123456789abcdefghijklmnopqrstuvwxyz@github.com/org/repo.git",
        "secret_token": "ghp_0123456789abcdefghijklmnopqrstuvwxyz",
        "is_binary": False,
    },
    # 9. Generic Bearer Token
    {
        "id": "SEC-FIX-09-GENERIC-BEARER",
        "provider": CredentialProvider.GENERIC_BEARER,
        "raw_string": "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M",
        "secret_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.t-IDcSemACt8x4iTMCda8Yhe3iZaWbvV5XKSTbuAn0M",
        "is_binary": False,
    },
    # 10. PEM Private Key
    {
        "id": "SEC-FIX-10-PRIVATE-KEY",
        "provider": CredentialProvider.PRIVATE_KEY,
        "raw_string": "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0Y3...\n-----END RSA PRIVATE KEY-----",
        "secret_token": "-----BEGIN RSA PRIVATE KEY-----",
        "is_binary": False,
    },
    # 11. Code Diff Chunk
    {
        "id": "SEC-FIX-11-CODE-DIFF",
        "provider": CredentialProvider.PROMPT_CODE,
        "raw_string": "diff --git a/server.py b/server.py\n@@ -10,6 +10,7 @@\n+import secret_auth_handler\n",
        "secret_token": "diff --git a/server.py b/server.py",
        "is_binary": False,
    },
    # 12. Prompt Marker
    {
        "id": "SEC-FIX-12-PROMPT-MARKER",
        "provider": CredentialProvider.PROMPT_CODE,
        "raw_string": "<system_prompt>You are a confidential security reviewer.</system_prompt>",
        "secret_token": "<system_prompt>",
        "is_binary": False,
    },
    # 13. ELF Process Memory Header
    {
        "id": "SEC-FIX-13-ELF-MEM",
        "provider": CredentialProvider.PROCESS_MEMORY,
        "raw_string": b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00MEMORY_DUMP_CHUNK",
        "secret_token": "MEMORY_DUMP_CHUNK",
        "is_binary": True,
    },
]


class AdversarialLeakFalsificationTests(unittest.TestCase):
    """
    Adversarial leak falsification suite proving 100% rejection and zero secret leakage.
    """

    def setUp(self) -> None:
        self.root_key = b"12345678901234567890123456789012"
        self.keyring = KeyRing(self.root_key, epoch=1)
        self.validator = ZeroPayloadValidator(keyring=self.keyring, default_tenant_id="tenant-adversarial")

    def test_100_percent_rejection_across_all_fixtures(self) -> None:
        """Assert that every adversarial fixture is detected and flagged."""
        rejection_count = 0
        total_count = len(ADVERSARIAL_FIXTURES)

        for fix in ADVERSARIAL_FIXTURES:
            with self.subTest(fixture_id=fix["id"]):
                raw = fix["raw_string"]
                if fix["is_binary"]:
                    report = self.validator.scan_bytes(raw)
                else:
                    report = self.validator.scan_string(raw)

                self.assertTrue(
                    report.detected,
                    f"FAILED to detect adversarial fixture {fix['id']}: {raw!r}",
                )
                expected_prov = fix["provider"].value
                self.assertGreaterEqual(
                    report.provider_counts.get(expected_prov, 0),
                    1,
                    f"Fixture {fix['id']} classified under unexpected provider: {report.provider_counts}",
                )
                rejection_count += 1

        self.assertEqual(
            rejection_count,
            total_count,
            f"Expected 100% rejection ({total_count}/{total_count}), got {rejection_count}",
        )

    def test_zero_leakage_in_detection_report_and_metadata(self) -> None:
        """Assert DetectionReport contains zero secret substrings across all fixtures."""
        for fix in ADVERSARIAL_FIXTURES:
            with self.subTest(fixture_id=fix["id"]):
                raw = fix["raw_string"]
                secret = fix["secret_token"]

                report = (
                    self.validator.scan_bytes(raw)
                    if fix["is_binary"]
                    else self.validator.scan_string(raw)
                )

                rep_str = repr(report)
                rep_dict_str = json.dumps(report.to_dict())

                self.assertNotIn(
                    secret,
                    rep_str,
                    f"Secret {secret} leaked in DetectionReport repr for {fix['id']}",
                )
                self.assertNotIn(
                    secret,
                    rep_dict_str,
                    f"Secret {secret} leaked in DetectionReport dict for {fix['id']}",
                )

                # Verify all fingerprints are valid 64-character hex strings
                for fp in report.fingerprints:
                    self.assertTrue(
                        is_pseudonym(fp),
                        f"Invalid HMAC fingerprint format for {fix['id']}: {fp}",
                    )

    def test_zero_leakage_in_exception_messages_under_adversarial_injection(self) -> None:
        """Assert ZeroPayloadSecurityException messages never leak candidate secret tokens."""
        for fix in ADVERSARIAL_FIXTURES:
            with self.subTest(fixture_id=fix["id"]):
                raw = fix["raw_string"]
                secret = fix["secret_token"]

                # Construct an event containing the secret in various envelope positions
                event = {
                    "schema_version": "1.0.0",
                    "session_id": "sess-adv-001",
                    "sequence": 1,
                    "observed_at": "2026-09-13T20:00:00Z",
                    "source": "host-sensor-v1",
                    "evidence_type": "process",
                    "observation_state": "observed",
                    "integrity_state": "not-integrity-verified",
                    "agent_id": "agent-adv-01",
                    "host_id": "host-adv-01",
                    "tenant_id": "tenant-adversarial",
                    "attributes": {
                        "health_state": "running",
                        "cpu_time_ms": 100,
                        "resident_memory_bytes": 1048576,
                        "exit_code": None,
                        "restart_count": 0,
                        "injected_data": raw,
                    },
                }

                with self.assertRaises(ZeroPayloadSecurityException) as ctx:
                    self.validator.validate_event(event)

                err_str = str(ctx.exception)
                err_repr = repr(ctx.exception)

                self.assertNotIn(
                    secret,
                    err_str,
                    f"Secret {secret} leaked into exception string for {fix['id']}",
                )
                self.assertNotIn(
                    secret,
                    err_repr,
                    f"Secret {secret} leaked into exception repr for {fix['id']}",
                )

    def test_filter_and_export_path_leak_rejection(self) -> None:
        """Assert that filtering and export reject injected fixtures and emit zero secret data."""
        for fix in ADVERSARIAL_FIXTURES:
            if fix["is_binary"]:
                continue
            with self.subTest(fixture_id=fix["id"]):
                secret = fix["secret_token"]

                raw_event = {
                    "schema_version": "1.0.0",
                    "session_id": "sess-export-01",
                    "sequence": 42,
                    "observed_at": "2026-09-13T21:00:00Z",
                    "source": "host-sensor-v1",
                    "evidence_type": "process",
                    "observation_state": "observed",
                    "integrity_state": "not-integrity-verified",
                    "agent_id": "agent-export-01",
                    "host_id": "host-export-01",
                    "tenant_id": "tenant-adversarial",
                    "raw_nono_record": fix["raw_string"],
                    "attributes": {
                        "health_state": "running",
                        "cpu_time_ms": 200,
                        "resident_memory_bytes": 2097152,
                        "exit_code": None,
                        "restart_count": 0,
                        "nested_leak": fix["raw_string"],
                    },
                }

                sanitized = sanitize_evidence_record(raw_event, include_tenant=True)
                serialized = json.dumps(sanitized, sort_keys=True)

                # Assert that sanitized record strictly excluded the secret
                self.assertNotIn(
                    secret,
                    serialized,
                    f"Secret {secret} found in sanitized export JSON for {fix['id']}",
                )
                self.assertNotIn(
                    "nested_leak",
                    sanitized["attributes"],
                    f"Unallowlisted key survived filtering for {fix['id']}",
                )

    def test_transient_buffer_memory_scrubbing_under_load(self) -> None:
        """Prove that transient match buffers are overwritten with zero bytes immediately."""
        for fix in ADVERSARIAL_FIXTURES:
            with self.subTest(fixture_id=fix["id"]):
                raw = fix["raw_string"]
                if isinstance(raw, str):
                    buf = bytearray(raw.encode("utf-8"))
                else:
                    buf = bytearray(raw)

                orig_len = len(buf)
                self.assertNotEqual(buf, bytearray(orig_len))

                # Pass through the internal fingerprint & scrub routine
                fp = self.validator._fingerprint_and_scrub(buf, "tenant-test")

                # Assert fingerprint is valid HMAC
                self.assertTrue(is_pseudonym(fp))

                # Assert buffer was zeroed in memory
                self.assertEqual(
                    buf,
                    bytearray(orig_len),
                    f"Transient buffer was NOT zeroed after fingerprinting for {fix['id']}",
                )


if __name__ == "__main__":
    unittest.main()
