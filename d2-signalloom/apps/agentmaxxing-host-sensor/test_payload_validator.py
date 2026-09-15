# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Unit tests for Zero-Customer-Payload Validator and SLDP Pseudonym Primitive.
"""
from __future__ import annotations

import ctypes
from pathlib import Path
import sys
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .payload_validator import (
        CredentialProvider,
        DetectionReport,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
        sanitized_error_boundary,
        scrub_buffer,
        shannon_entropy,
        validate_zero_customer_payload,
    )
    from .pseudonym import (
        HEX_LEN,
        MIN_ROOT_KEY_BYTES,
        KeyRing,
        RootKeyTooShortError,
        TenantRequiredError,
        ValueRequiredError,
        is_pseudonym,
    )
except (ImportError, ValueError):
    from payload_validator import (
        CredentialProvider,
        DetectionReport,
        ZeroPayloadSecurityException,
        ZeroPayloadValidator,
        sanitized_error_boundary,
        scrub_buffer,
        shannon_entropy,
        validate_zero_customer_payload,
    )
    from pseudonym import (
        HEX_LEN,
        MIN_ROOT_KEY_BYTES,
        KeyRing,
        RootKeyTooShortError,
        TenantRequiredError,
        ValueRequiredError,
        is_pseudonym,
    )


class PseudonymPrimitiveTests(unittest.TestCase):
    """Test cryptographic correctness and fail-closed invariants of SLDP Pseudonym."""

    def setUp(self) -> None:
        self.root_key = b"12345678901234567890123456789012"
        self.keyring = KeyRing(self.root_key, epoch=1)

    def test_pseudonym_matches_go_test_vector(self) -> None:
        """Verify Python HKDF and HMAC-SHA256 match Go implementation bit-for-bit."""
        p = self.keyring.pseudonym("tenant-test", "my-secret-token")
        expected = "660120720c6726b30f58ea21f3b0f61601f457c9a165c429705bf7c10f5a183e"
        self.assertEqual(p, expected)
        self.assertTrue(is_pseudonym(p))
        self.assertEqual(len(p), HEX_LEN)

    def test_pseudonym_fail_closed_on_short_root_key(self) -> None:
        """Reject under-length root key material."""
        with self.assertRaises(RootKeyTooShortError):
            KeyRing(b"short-key", epoch=1)

    def test_pseudonym_fail_closed_on_empty_tenant_or_value(self) -> None:
        """Reject empty tenant or empty input value."""
        with self.assertRaises(TenantRequiredError):
            self.keyring.pseudonym("", "value")
        with self.assertRaises(ValueRequiredError):
            self.keyring.pseudonym("tenant-1", "")

    def test_tenant_key_caching(self) -> None:
        """Verify tenant key memoisation."""
        self.assertFalse(self.keyring.is_tenant_key_cached("tenant-cached"))
        self.keyring.pseudonym("tenant-cached", "secret-val")
        self.assertTrue(self.keyring.is_tenant_key_cached("tenant-cached"))

    def test_domain_and_epoch_separation(self) -> None:
        """Verify different epochs produce orthogonal pseudonyms for identical values."""
        ring_epoch1 = KeyRing(self.root_key, epoch=1)
        ring_epoch2 = KeyRing(self.root_key, epoch=2)
        p1 = ring_epoch1.pseudonym("tenant-1", "secret")
        p2 = ring_epoch2.pseudonym("tenant-1", "secret")
        self.assertNotEqual(p1, p2)


class PayloadValidatorTests(unittest.TestCase):
    """Test ZeroPayloadValidator shape detection, error boundary, and memory scrubbing."""

    def setUp(self) -> None:
        self.root_key = b"12345678901234567890123456789012"
        self.keyring = KeyRing(self.root_key, epoch=1)
        self.validator = ZeroPayloadValidator(keyring=self.keyring, default_tenant_id="test-tenant")

    def test_detect_anthropic_shapes_zero_retention(self) -> None:
        """Detect Anthropic token shape, emit HMAC fingerprint, and retain zero secret bytes."""
        secret = "sk-ant-api03-abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        report = self.validator.scan_string(f"Bearer {secret}")
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["anthropic"], 1)
        self.assertGreaterEqual(len(report.fingerprints), 1)

        # Assert zero secret retention
        serialized = repr(report) + str(report.to_dict())
        self.assertNotIn(secret, serialized)
        self.assertNotIn("abcdef1234567890", serialized)

    def test_detect_openai_shapes_zero_retention(self) -> None:
        """Detect OpenAI token shape with zero value retention."""
        secret = "sk-proj-0123456789abcdef0123456789abcdef0123456789abcdef"
        report = self.validator.scan_string(f"openai_key = '{secret}'")
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["openai"], 1)
        self.assertNotIn(secret, str(report.to_dict()))

    def test_detect_aws_shapes_zero_retention(self) -> None:
        """Detect AWS Access Key and Secret Key shapes."""
        aws_akid = "AKIAIOSFODNN7EXAMPLE"
        aws_secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        text = f"aws_access_key_id={aws_akid} aws_secret_access_key={aws_secret}"
        report = self.validator.scan_string(text)
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["aws"], 1)
        self.assertNotIn(aws_akid, str(report.to_dict()))
        self.assertNotIn(aws_secret, str(report.to_dict()))

    def test_detect_generic_bearer_and_cmdline_secrets(self) -> None:
        """Detect generic Bearer and command line argument secrets."""
        text = "--token=SECRET_BEARER_TOKEN_9876543210"
        report = self.validator.scan_string(text)
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["generic_bearer"], 1)
        self.assertNotIn("SECRET_BEARER_TOKEN_9876543210", str(report.to_dict()))

    def test_detect_code_diff_and_prompt_markers(self) -> None:
        """Detect source code diffs and prompt structures."""
        diff_text = "diff --git a/main.py b/main.py\n@@ -1,3 +1,4 @@\n+print('hello')\n"
        report = self.validator.scan_string(diff_text)
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["prompt_code"], 1)

        prompt_text = "<system_prompt>You are an expert autonomous coding agent.</system_prompt>"
        report2 = self.validator.scan_string(prompt_text)
        self.assertTrue(report2.detected)
        self.assertGreaterEqual(report2.provider_counts["prompt_code"], 1)

    def test_detect_process_memory_elf_header(self) -> None:
        """Detect raw ELF memory dump headers."""
        elf_bytes = b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"
        report = self.validator.scan_bytes(elf_bytes)
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["process_memory"], 1)

    def test_high_entropy_detection_heuristic(self) -> None:
        """Detect high-entropy unclassified secret strings."""
        high_entropy_str = "8f3a9B2c7E1d5F0g8H3j2K9m4N7p1Q5r8T2v"
        self.assertGreater(shannon_entropy(high_entropy_str), 3.9)
        report = self.validator.scan_string(high_entropy_str)
        self.assertTrue(report.detected)
        self.assertGreaterEqual(report.provider_counts["high_entropy"], 1)

    def test_memory_scrubbing_wipes_transient_buffer(self) -> None:
        """Prove that scrub_buffer zeroes the memory buffer."""
        secret_bytes = bytearray(b"SUPER_SECRET_TRANSIENT_CREDENTIAL_12345")
        length = len(secret_bytes)

        # Confirm non-zero initially
        self.assertNotEqual(secret_bytes, bytearray(length))

        # Scrub
        scrub_buffer(secret_bytes)

        # Assert all bytes in buffer are now zero (0x00)
        self.assertEqual(secret_bytes, bytearray(length))
        for b in secret_bytes:
            self.assertEqual(b, 0)

    def test_panic_error_boundary_sanitizes_exceptions(self) -> None:
        """Assert that panic/error boundary never carries input fragments in error messages."""
        secret_fragment = "SENSITIVE_SECRET_TOKEN_9999"

        @sanitized_error_boundary
        def faulty_detector(input_data: str) -> None:
            # Simulate an internal detector failure with input in trace
            raise RuntimeError(f"internal parser exploded on: {input_data}")

        with self.assertRaises(ZeroPayloadSecurityException) as ctx:
            faulty_detector(f"some text with {secret_fragment}")

        err_msg = str(ctx.exception)
        # Verify secret fragment is absent from error message
        self.assertNotIn(secret_fragment, err_msg)
        self.assertIn("Zero-Customer-Payload detector fault", err_msg)

    def test_pre_export_gate_rejects_dirty_events(self) -> None:
        """Assert pre-export gate blocks dirty events before export."""
        dirty_event = {
            "schema_version": "1.0.0",
            "session_id": "sess-test",
            "sequence": 1,
            "observed_at": "2026-09-13T12:00:00Z",
            "source": "host-sensor-v1",
            "evidence_type": "process",
            "observation_state": "observed",
            "integrity_state": "not-integrity-verified",
            "agent_id": "agent-1",
            "host_id": "host-1",
            "attributes": {
                "health_state": "running",
                "cpu_time_ms": 10,
                "resident_memory_bytes": 100,
                "exit_code": None,
                "restart_count": 0,
                "injected_token": "sk-ant-api03-1234567890abcdef1234567890abcdef1234567890",
            },
        }

        with self.assertRaises(ZeroPayloadSecurityException) as ctx:
            self.validator.validate_event(dirty_event)

        self.assertIn("Zero-Customer-Payload violation", str(ctx.exception))
        # Ensure secret value is absent from exception string
        self.assertNotIn("sk-ant-api03-1234567890abcdef", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
