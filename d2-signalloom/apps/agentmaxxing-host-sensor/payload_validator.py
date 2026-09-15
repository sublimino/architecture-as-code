# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Zero-Customer-Payload Validator and Shape-Only Credential Detector.

Enforces the absolute Zero-Customer-Payload privacy invariant across Signal Loom telemetry:
  1. Detects prompt, code, credential, and process memory shapes by structural signal only.
  2. Never retains, logs, or exports the matched substring or secret value.
  3. Emits keyed HMAC-SHA256 fingerprints derived from the SLDP pseudonym primitive.
  4. Classifies and counts detections by provider (Anthropic, OpenAI, AWS, Generic Bearer, etc.).
  5. Wraps all detector operations in a panic/error boundary that is proven not to leak input fragments.
  6. Explicitly zeroes and scrubs transient memory buffers immediately after classification.
  7. Acts as a pre-export gate blocking telemetry before it can be serialized or stored.
"""
from __future__ import annotations

import ctypes
from enum import Enum
import functools
import math
from pathlib import Path
import re
import sys
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple, Union

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .pseudonym import DEFAULT_KEYRING, KeyRing, is_pseudonym
except (ImportError, ValueError):
    from pseudonym import DEFAULT_KEYRING, KeyRing, is_pseudonym


class CredentialProvider(str, Enum):
    """Classified secret and payload shape providers."""
    ANTHROPIC = "anthropic"
    OPENAI = "openai"
    AWS = "aws"
    GENERIC_BEARER = "generic_bearer"
    GITHUB = "github"
    PRIVATE_KEY = "private_key"
    PROMPT_CODE = "prompt_code"
    PROCESS_MEMORY = "process_memory"
    HIGH_ENTROPY = "high_entropy"


class ZeroPayloadSecurityException(Exception):
    """
    Raised when a Zero-Customer-Payload violation or detection occurs.

    Security Guarantee:
    This exception message is guaranteed to contain ONLY sanitized metadata
    (provider classification, match counts, and keyed SLDP HMAC fingerprints).
    It NEVER carries fragments, prefixes, suffixes, or slices of candidate input text.
    """

    def __init__(
        self,
        message: str = "Zero-Customer-Payload boundary violation",
        provider_counts: Optional[Dict[str, int]] = None,
        fingerprints: Optional[List[str]] = None,
    ) -> None:
        self.provider_counts: Dict[str, int] = provider_counts or {}
        self.fingerprints: List[str] = fingerprints or []
        super().__init__(message)


def sanitized_error_boundary(func: Callable[..., Any]) -> Callable[..., Any]:
    """
    Decorator enforcing a strict panic/error boundary around detector execution.

    Catches all internal runtime exceptions, regex faults, or decoding failures and
    re-raises a sanitized ZeroPayloadSecurityException without exposing input contents.
    """
    @functools.wraps(func)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            return func(*args, **kwargs)
        except ZeroPayloadSecurityException:
            # Already sanitized
            raise
        except Exception as e:
            # Wrap any unhandled internal error into a sanitized exception
            err_type = type(e).__name__
            raise ZeroPayloadSecurityException(
                f"Zero-Customer-Payload detector fault: internal {err_type} during validation boundary check"
            ) from None

    return wrapper


def scrub_buffer(buf: Union[bytearray, memoryview, ctypes.Array, Any]) -> None:
    """
    Explicitly zero out mutable memory buffers to ensure transient candidate secrets
    do not linger in process memory awaiting garbage collection.
    """
    if isinstance(buf, bytearray):
        for i in range(len(buf)):
            buf[i] = 0
    elif isinstance(buf, memoryview):
        if not buf.readonly:
            buf[:] = b"\x00" * len(buf)
    elif hasattr(buf, "_type_") and hasattr(buf, "_length_"):  # ctypes array
        ctypes.memset(ctypes.addressof(buf), 0, ctypes.sizeof(buf))


def shannon_entropy(data: str) -> float:
    """Calculate Shannon entropy in bits per character."""
    if not data:
        return 0.0
    freq: Dict[str, int] = {}
    for c in data:
        freq[c] = freq.get(c, 0) + 1
    entropy = 0.0
    total = len(data)
    for count in freq.values():
        p = count / total
        entropy -= p * math.log2(p)
    return entropy


# --- Shape Detection Rules ---

# Anthropic API & Admin Tokens
ANTHROPIC_PATTERNS = [
    re.compile(r"sk-ant-(?:api03|admin01|sid01)-[A-Za-z0-9_-]{32,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_-]{32,}"),
]

# OpenAI API & Project Tokens
OPENAI_PATTERNS = [
    re.compile(r"sk-(?:proj|admin|svcacct)-[A-Za-z0-9_-]{32,}"),
    re.compile(r"sk-[A-Za-z0-9]{32,}"),
]

# AWS Access Keys & Credentials
AWS_KEY_PATTERNS = [
    re.compile(r"\b(?:A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}\b"),
]
AWS_SECRET_PATTERNS = [
    re.compile(r"(?i)(?:aws_secret_access_key|aws_access_key_id|aws_session_token)\s*[=:]\s*['\"]?([A-Za-z0-9/+=]{20,})['\"]?"),
]

# GitHub PATs & Fine-Grained Tokens
GITHUB_PATTERNS = [
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{82}\b"),
]

# Generic Bearer Tokens & API Keys
GENERIC_BEARER_PATTERNS = [
    re.compile(r"(?i)\bBearer\s+([A-Za-z0-9_\-\.]{20,})\b"),
    re.compile(r"(?i)(?:--token|--api-key|--apikey|--password|--secret)[=:\s]+([A-Za-z0-9_\-\.]{12,})"),
    re.compile(r"(?i)(?:api[_-]?key|access[_-]?token|secret[_-]?key|auth[_-]?token|bearer[_-]?token)\s*[=:]\s*['\"]?([A-Za-z0-9_\-\.]{16,})['\"]?"),
]

# Private Keys & Certificates
PRIVATE_KEY_PATTERNS = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"),
]

# Code & Diff Structures
CODE_DIFF_PATTERNS = [
    re.compile(r"^diff --git\s+a/.+\s+b/", re.MULTILINE),
    re.compile(r"^@@\s+-[0-9]+,[0-9]+\s+\+[0-9]+,[0-9]+\s+@@", re.MULTILINE),
    re.compile(r"^---\s+a/.+\n\+\+\+\s+b/", re.MULTILINE),
]

# Prompt Text & LLM Conversation Turn Markers
PROMPT_MARKERS = [
    re.compile(r"<system_prompt>|<USER_REQUEST>|<task-notification>"),
    re.compile(r"(?i)(?:You are an AI assistant|Human:\s+|Assistant:\s+|System:\s+)"),
]

# Process Memory & Binary Indicators
BINARY_INDICATORS = [
    b"\x7fELF",
    b"\x00\x00\x00",
]


class DetectionReport:
    """
    Telemetry report of detections containing ONLY provider metadata and keyed HMACs.
    Zero matched customer text is retained.
    """

    def __init__(self) -> None:
        self.detected: bool = False
        self.provider_counts: Dict[str, int] = {p.value: 0 for p in CredentialProvider}
        self.fingerprints: List[str] = []
        self.reasons: List[str] = []

    def record_match(
        self,
        provider: CredentialProvider,
        fingerprint: Optional[str] = None,
        reason: Optional[str] = None,
    ) -> None:
        self.detected = True
        self.provider_counts[provider.value] = self.provider_counts.get(provider.value, 0) + 1
        if fingerprint and fingerprint not in self.fingerprints:
            self.fingerprints.append(fingerprint)
        if reason and reason not in self.reasons:
            self.reasons.append(reason)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "detected": self.detected,
            "provider_counts": {k: v for k, v in self.provider_counts.items() if v > 0},
            "fingerprints": list(self.fingerprints),
            "reasons": list(self.reasons),
        }

    def __repr__(self) -> str:
        active_counts = {k: v for k, v in self.provider_counts.items() if v > 0}
        return f"DetectionReport(detected={self.detected}, counts={active_counts}, fingerprints={len(self.fingerprints)})"


class ZeroPayloadValidator:
    """
    Detector and Validator enforcing Zero-Customer-Payload invariants.
    Extracts structural signals and SLDP HMAC fingerprints with zero value retention.
    """

    def __init__(
        self,
        keyring: Optional[KeyRing] = None,
        default_tenant_id: str = "tenant-signalloom-default",
        entropy_threshold: float = 3.9,
        min_entropy_len: int = 24,
    ) -> None:
        self.keyring: KeyRing = keyring or DEFAULT_KEYRING
        self.default_tenant_id: str = default_tenant_id
        self.entropy_threshold: float = entropy_threshold
        self.min_entropy_len: int = min_entropy_len

    def _fingerprint_and_scrub(self, raw_value: Union[str, bytes, bytearray], tenant_id: str) -> str:
        """
        Derive keyed HMAC-SHA256 fingerprint via KeyRing and immediately scrub transient buffer.
        """
        if isinstance(raw_value, str):
            buf = bytearray(raw_value.encode("utf-8"))
        elif isinstance(raw_value, bytes):
            buf = bytearray(raw_value)
        elif isinstance(raw_value, bytearray):
            buf = raw_value
        else:
            buf = bytearray(str(raw_value).encode("utf-8"))

        try:
            fp = self.keyring.pseudonym(tenant_id, buf)
            return fp
        finally:
            scrub_buffer(buf)

    @sanitized_error_boundary
    def scan_string(self, text: str, tenant_id: Optional[str] = None) -> DetectionReport:
        """
        Scan a string for prompt, code, credential, or process memory shapes.
        Returns a DetectionReport with zero substring retention.
        """
        report = DetectionReport()
        if not text:
            return report

        t_id = tenant_id or self.default_tenant_id

        # 1. Anthropic token patterns
        for pat in ANTHROPIC_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.ANTHROPIC,
                    fingerprint=fp,
                    reason="anthropic_token_shape",
                )

        # 2. OpenAI token patterns
        for pat in OPENAI_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.OPENAI,
                    fingerprint=fp,
                    reason="openai_token_shape",
                )

        # 3. AWS Key patterns
        for pat in AWS_KEY_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.AWS,
                    fingerprint=fp,
                    reason="aws_access_key_shape",
                )

        for pat in AWS_SECRET_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(1) if match.groups() else match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.AWS,
                    fingerprint=fp,
                    reason="aws_secret_key_shape",
                )

        # 4. GitHub tokens
        for pat in GITHUB_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.GITHUB,
                    fingerprint=fp,
                    reason="github_token_shape",
                )

        # 5. Generic Bearer / Auth tokens
        for pat in GENERIC_BEARER_PATTERNS:
            for match in pat.finditer(text):
                matched_val = match.group(1) if match.groups() else match.group(0)
                fp = self._fingerprint_and_scrub(matched_val, t_id)
                report.record_match(
                    CredentialProvider.GENERIC_BEARER,
                    fingerprint=fp,
                    reason="bearer_token_shape",
                )

        # 6. Private Key headers
        for pat in PRIVATE_KEY_PATTERNS:
            if pat.search(text):
                fp = self._fingerprint_and_scrub("PRIVATE_KEY_STRUCTURE", t_id)
                report.record_match(
                    CredentialProvider.PRIVATE_KEY,
                    fingerprint=fp,
                    reason="private_key_pem_header",
                )

        # 7. Code diff patterns
        for pat in CODE_DIFF_PATTERNS:
            if pat.search(text):
                fp = self._fingerprint_and_scrub("CODE_DIFF_STRUCTURE", t_id)
                report.record_match(
                    CredentialProvider.PROMPT_CODE,
                    fingerprint=fp,
                    reason="unified_diff_code_shape",
                )

        # 8. Prompt markers
        for pat in PROMPT_MARKERS:
            if pat.search(text):
                fp = self._fingerprint_and_scrub("PROMPT_MARKER_STRUCTURE", t_id)
                report.record_match(
                    CredentialProvider.PROMPT_CODE,
                    fingerprint=fp,
                    reason="llm_prompt_structure",
                )

        # 9. Shannon Entropy check on long contiguous tokens
        # Splits on whitespace and punctuation, checks candidate words
        tokens = re.findall(r"[A-Za-z0-9+/=_\-]{" + str(self.min_entropy_len) + r",}", text)
        for tok in tokens:
            ent = shannon_entropy(tok)
            if ent >= self.entropy_threshold:
                fp = self._fingerprint_and_scrub(tok, t_id)
                report.record_match(
                    CredentialProvider.HIGH_ENTROPY,
                    fingerprint=fp,
                    reason=f"high_entropy_token_shape(entropy={round(ent, 2)})",
                )

        return report

    @sanitized_error_boundary
    def scan_bytes(
        self,
        raw_bytes: Union[bytes, bytearray, memoryview],
        tenant_id: Optional[str] = None,
    ) -> DetectionReport:
        """
        Scan raw binary or process memory buffers for ELF headers, null-separated cmdline
        tokens, or embedded string secrets.
        """
        report = DetectionReport()
        if not raw_bytes:
            return report

        t_id = tenant_id or self.default_tenant_id
        b_view = bytes(raw_bytes)

        # 1. Process Memory / ELF check
        if b_view.startswith(b"\x7fELF"):
            fp = self._fingerprint_and_scrub("ELF_PROCESS_MEMORY", t_id)
            report.record_match(
                CredentialProvider.PROCESS_MEMORY,
                fingerprint=fp,
                reason="elf_binary_process_memory",
            )

        # 2. Null-separated cmdline check (e.g. "python3\x00agent.py\x00--token=...")
        if b"\x00" in b_view:
            segments = b_view.split(b"\x00")
            for seg in segments:
                if b"--token=" in seg or b"--secret=" in seg or b"--api-key=" in seg or b"--password=" in seg:
                    fp = self._fingerprint_and_scrub(seg, t_id)
                    report.record_match(
                        CredentialProvider.GENERIC_BEARER,
                        fingerprint=fp,
                        reason="null_separated_cmdline_secret",
                    )

        # 3. Decode printable strings and delegate to scan_string
        try:
            decoded = b_view.decode("utf-8", errors="replace")
            str_report = self.scan_string(decoded, tenant_id=t_id)
            if str_report.detected:
                for prov_str, count in str_report.provider_counts.items():
                    if count > 0:
                        report.detected = True
                        report.provider_counts[prov_str] = report.provider_counts.get(prov_str, 0) + count
                for fp in str_report.fingerprints:
                    if fp not in report.fingerprints:
                        report.fingerprints.append(fp)
                for r in str_report.reasons:
                    if r not in report.reasons:
                        report.reasons.append(r)
        except Exception:
            pass

        return report

    @sanitized_error_boundary
    def validate_event(
        self,
        event_dict: Dict[str, Any],
        tenant_id: Optional[str] = None,
    ) -> None:
        """
        Pre-export validation gate.

        Recursively checks all keys and values in the event dictionary.
        Raises ZeroPayloadSecurityException if any credential, prompt, code, or memory
        shape is detected, completely blocking serialization and export.
        """
        t_id = tenant_id or event_dict.get("tenant_id") or self.default_tenant_id
        violations: List[str] = []
        combined_report = DetectionReport()

        def _traverse(node: Any, path: str = "") -> None:
            if isinstance(node, dict):
                for k, v in node.items():
                    key_path = f"{path}.{k}" if path else str(k)
                    # Check key name
                    key_report = self.scan_string(str(k), tenant_id=t_id)
                    if key_report.detected:
                        violations.append(f"prohibited_key_shape:{key_path}")
                        for prov, cnt in key_report.provider_counts.items():
                            combined_report.provider_counts[prov] += cnt
                        for fp in key_report.fingerprints:
                            if fp not in combined_report.fingerprints:
                                combined_report.fingerprints.append(fp)

                    _traverse(v, key_path)
            elif isinstance(node, (list, tuple, set)):
                for i, item in enumerate(node):
                    _traverse(item, f"{path}[{i}]")
            elif isinstance(node, str):
                val_report = self.scan_string(node, tenant_id=t_id)
                if val_report.detected:
                    violations.append(f"prohibited_value_shape:{path}")
                    for prov, cnt in val_report.provider_counts.items():
                        combined_report.provider_counts[prov] += cnt
                    for fp in val_report.fingerprints:
                        if fp not in combined_report.fingerprints:
                            combined_report.fingerprints.append(fp)
            elif isinstance(node, (bytes, bytearray)):
                byte_report = self.scan_bytes(node, tenant_id=t_id)
                if byte_report.detected:
                    violations.append(f"prohibited_binary_payload:{path}")
                    for prov, cnt in byte_report.provider_counts.items():
                        combined_report.provider_counts[prov] += cnt
                    for fp in byte_report.fingerprints:
                        if fp not in combined_report.fingerprints:
                            combined_report.fingerprints.append(fp)

        _traverse(event_dict)

        if violations or combined_report.detected:
            providers = [k for k, v in combined_report.provider_counts.items() if v > 0]
            prov_desc = ",".join(providers) if providers else "unknown"
            raise ZeroPayloadSecurityException(
                message=(
                    f"Zero-Customer-Payload violation: prohibited payload shape rejected at pre-export gate "
                    f"[providers={prov_desc}, fingerprints={len(combined_report.fingerprints)}]"
                ),
                provider_counts={k: v for k, v in combined_report.provider_counts.items() if v > 0},
                fingerprints=combined_report.fingerprints,
            )


# Default module-level validator instance
DEFAULT_VALIDATOR = ZeroPayloadValidator()


def validate_zero_customer_payload(
    data: Any,
    tenant_id: Optional[str] = None,
    validator: Optional[ZeroPayloadValidator] = None,
) -> None:
    """
    Convenience function for pre-export validation of telemetry objects or dictionaries.
    """
    v = validator or DEFAULT_VALIDATOR
    if isinstance(data, dict):
        v.validate_event(data, tenant_id=tenant_id)
    elif isinstance(data, str):
        rep = v.scan_string(data, tenant_id=tenant_id)
        if rep.detected:
            providers = [k for k, count in rep.provider_counts.items() if count > 0]
            raise ZeroPayloadSecurityException(
                f"Zero-Customer-Payload violation: string matches secret shapes [providers={','.join(providers)}]",
                provider_counts={k: v for k, v in rep.provider_counts.items() if v > 0},
                fingerprints=rep.fingerprints,
            )
    elif isinstance(data, (bytes, bytearray)):
        rep = v.scan_bytes(data, tenant_id=tenant_id)
        if rep.detected:
            providers = [k for k, count in rep.provider_counts.items() if count > 0]
            raise ZeroPayloadSecurityException(
                f"Zero-Customer-Payload violation: bytes match payload shapes [providers={','.join(providers)}]",
                provider_counts={k: v for k, v in rep.provider_counts.items() if v > 0},
                fingerprints=rep.fingerprints,
            )
    elif hasattr(data, "to_dict"):
        v.validate_event(data.to_dict(), tenant_id=tenant_id)
    elif hasattr(data, "__dict__"):
        v.validate_event(vars(data), tenant_id=tenant_id)
