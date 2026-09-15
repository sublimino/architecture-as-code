# SLCD-P1-2 — Zero-Customer-Payload Validator & Adversarial Leak Falsification Suite

> **Purpose.** Formulate a strict zero-customer-payload validator and its adversarial leak-falsification test suite. A detector that stores the matched value to prove the match creates the exposure it was built to find, in a telemetry store with a longer retention window than the original process memory it copied from. This document establishes the shape-only detection architecture, the SLDP-derived keyed HMAC fingerprinting contract, the panic/error boundary proof, the memory-scrubbing guarantees, and the adversarial leak-falsification test evidence.
>
> | | |
> |---|---|
> | Card | SLCD-P1-2 (implementation) |
> | Date | 2026-09-15 |
> | Status | Complete |
> | Target Components | `d2-signalloom/apps/agentmaxxing-host-sensor/`, `d2-signalloom/apps/signal-ingest/` |
> | Invariant | Absolute Zero-Customer-Payload Privacy Boundary |

---

## 1. Executive Summary & Architectural Invariant

Signal Loom host detective sensors operate under an absolute **Zero-Customer-Payload** privacy boundary:
- **No customer prompts, user messages, assistant thinking/responses, or LLM turn markers** may ever be collected, stored, or emitted.
- **No proprietary source code, file contents, git diffs, or structured patches** may ever enter telemetry streams.
- **No API keys, session tokens, passwords, private keys, or command-line credentials** may ever be harvested, retained, or logged.
- **No raw process memory, heap dumps, stack traces, or `/proc/<pid>/mem` content** may ever be inspected or extracted.

A fundamental flaw in conventional secret scanners is that they capture, log, or store candidate secret strings to prove the detection or to report the offending snippet. When telemetry is exported to a central store, this converts an ephemeral in-memory credential into a persisted, multi-tenant risk with a long retention window.

**The SLCD-P1-2 Architecture solves this by construction:**
1. **Shape-and-Structural Detection Only**: Detects credentials and payloads by structural properties (known token prefixes, entropy thresholds, character-class distributions, and protocol headers).
2. **Zero Value Retention**: The matched secret substring is NEVER stored in the report, NEVER logged, and NEVER included in error messages.
3. **Keyed HMAC-SHA256 Fingerprinting via SLDP**: Produces a deterministic, tenant-and-epoch-scoped pseudonym using the SLDP pseudonym primitive (`signalloom/identity/alias-pseudonym/v1`), allowing fleet-wide deduplication and classification without exposing key material, prefixes, or suffixes.
4. **Immediate Memory Scrubbing**: Transient buffers holding candidate tokens are explicitly overwritten with `0x00` in-place immediately upon classification, eliminating reliance on non-deterministic garbage collection.
5. **Sanitized Panic/Error Boundaries**: Detector operations are wrapped in error boundaries asserted never to leak input substrings into exception messages.
6. **Pre-Export Gating**: The validator sits ahead of `collector.py` and `filter.py` serialization paths, terminating export before any record reaches network or storage sinks.

---

## 2. Shape-Only Detector Specification

The validator classifies candidate streams across distinct provider shapes without retaining the matched text:

| Provider Category | Structural Signature & Format | Action & Classification |
|---|---|---|
| **Anthropic** | `sk-ant-(?:api03\|admin01\|sid01)-[A-Za-z0-9_-]{32,}`<br>`sk-ant-[A-Za-z0-9_-]{32,}` | Classify as `anthropic`, derive SLDP HMAC, scrub buffer, count match. |
| **OpenAI** | `sk-(?:proj\|admin\|svcacct)-[A-Za-z0-9_-]{32,}`<br>`sk-[A-Za-z0-9]{32,}` | Classify as `openai`, derive SLDP HMAC, scrub buffer, count match. |
| **AWS** | `\b(?:A3T[A-Z0-9]\|AKIA\|AGPA\|AIDA\|AROA\|AIPA\|ANPA\|ANVA\|ASIA)[A-Z0-9]{16}\b`<br>`aws_secret_access_key\s*[=:]\s*['\"]?([A-Za-z0-9/+=]{20,})['\"]?` | Classify as `aws`, derive SLDP HMAC, scrub buffer, count match. |
| **Generic Bearer** | `\bBearer\s+([A-Za-z0-9_\-\.]{20,})\b`<br>`--(?:token\|api-key\|password\|secret)[=:\s]+([A-Za-z0-9_\-\.]{12,})` | Classify as `generic_bearer`, derive SLDP HMAC, scrub buffer, count match. |
| **GitHub** | `\b(?:ghp\|gho\|ghu\|ghs\|ghr)_[A-Za-z0-9]{36}\b`<br>`\bgithub_pat_[A-Za-z0-9_]{82}\b` | Classify as `github`, derive SLDP HMAC, scrub buffer, count match. |
| **Private Keys** | `-----BEGIN (?:RSA \|EC \|OPENSSH \|DSA \|PGP )?PRIVATE KEY-----` | Classify as `private_key`, derive SLDP HMAC, scrub buffer, count match. |
| **Prompt & Code** | `diff --git a/.+ b/`<br>`@@ -[0-9]+,[0-9]+ \+[0-9]+,[0-9]+ @@`<br>`<system_prompt>\|<USER_REQUEST>` | Classify as `prompt_code`, derive SLDP HMAC, scrub buffer, count match. |
| **Process Memory** | `\x7fELF` magic bytes, null-separated cmdline argument streams | Classify as `process_memory`, derive SLDP HMAC, scrub buffer, count match. |
| **High Entropy** | Shannon entropy $H(X) \ge 3.9$ bits/char on character runs $\ge 24$ chars | Classify as `high_entropy`, derive SLDP HMAC, scrub buffer, count match. |

### Detection Report Schema
When a detection occurs, the emitted `DetectionReport` contains ONLY:
```json
{
  "detected": true,
  "provider_counts": {
    "anthropic": 1,
    "aws": 0,
    "generic_bearer": 1
  },
  "fingerprints": [
    "660120720c6726b30f58ea21f3b0f61601f457c9a165c429705bf7c10f5a183e"
  ],
  "reasons": [
    "anthropic_token_shape",
    "bearer_token_shape"
  ]
}
```
**Zero customer payload, token prefixes, suffixes, or secret characters exist in this structure.**

---

## 3. Cryptographic SLDP Pseudonym Primitive Integration

The Python implementation in `pseudonym.py` implements the exact cryptographic contract defined in Go (`d2-signalloom/apps/signal-ingest/pseudonym/pseudonym.go`):

1. **Domain Separation**:
   $$\text{Domain} = \text{"signalloom/identity/alias-pseudonym/v1"}$$
2. **HKDF Key Derivation (RFC 5869)**:
   $$\text{Info} = \text{len}(\text{Domain})_{32\text{BE}} \parallel \text{Domain} \parallel \text{Epoch}_{32\text{BE}} \parallel \text{len}(\text{TenantID})_{32\text{BE}} \parallel \text{TenantID}$$
   $$K_{\text{tenant}} = \text{HKDF-SHA256}(\text{RootKey}, \text{Salt}=0^{32}, \text{Info}, L=32)$$
3. **HMAC Pseudonym Calculation**:
   $$\text{Pseudonym} = \text{hex}(\text{HMAC-SHA256}(K_{\text{tenant}}, \text{Value}))$$

### Cross-Language Verification
Both Python and Go implementations evaluate to identical 64-character lowercase hex hashes for identical inputs:
- Root Key: `b"12345678901234567890123456789012"`
- Epoch: `1`
- Tenant ID: `"tenant-test"`
- Input Value: `"my-secret-token"`
- **Derived Pseudonym**: `660120720c6726b30f58ea21f3b0f61601f457c9a165c429705bf7c10f5a183e` (verified in `pseudonym_test.go` and `test_payload_validator.py`).

---

## 4. Memory Scrubbing & Error Boundary Guarantees

### Memory Scrubbing
Python strings are immutable, but candidate byte streams and match buffers are represented as mutable `bytearray` or `memoryview` objects. Immediately after the HMAC calculation completes, `scrub_buffer(buf)` overwrites every byte with `0x00`:
```python
def scrub_buffer(buf: Union[bytearray, memoryview, ctypes.Array, Any]) -> None:
    if isinstance(buf, bytearray):
        for i in range(len(buf)):
            buf[i] = 0
    elif isinstance(buf, memoryview) and not buf.readonly:
        buf[:] = b"\x00" * len(buf)
```
Verified in `test_memory_scrubbing_wipes_transient_buffer`: post-scrub buffer contains $100\%$ zero bytes.

### Panic / Error Boundary
All detector entry points are wrapped with `@sanitized_error_boundary`. Any unhandled regex failure, decoding fault, or runtime exception is intercepted and re-raised as a constant `ZeroPayloadSecurityException`:
```python
raise ZeroPayloadSecurityException(
    "Zero-Customer-Payload detector fault: internal Exception during validation boundary check"
) from None
```
Verified in `test_panic_error_boundary_sanitizes_exceptions`: no substring or slice of the injected data is present in `str(exception)` or `repr(exception)`.

---

## 5. Pre-Export Gate Integration

The validator is wired into the host sensor's export path ahead of serialization:
- `filter.py`: `AllowlistFilter.filter_event(...)` executes `DEFAULT_VALIDATOR.validate_event(filtered_event)` before returning. Any unapproved payload or credential shape raises `ZeroPayloadSecurityException`, preventing export.
- `collector.py`: `ProcessTelemetryCollector.collect_event(...)` executes `validate_zero_customer_payload(event)` immediately upon construction before returning the record to callers or persistence stores.

---

## 6. Adversarial Leak-Falsification Test Coverage

The test suite in `test_leak_falsification.py` executes 13 curated adversarial fixtures across 5 categories:

| Fixture ID | Category / Target | Raw Injected Shape | Result | Leakage |
|---|---|---|---|---|
| `SEC-FIX-01-CMDLINE` | Cmdline args (test_negative_security:71) | `python3\x00agent.py\x00--token=SECRET_BEARER_TOKEN\x00` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-02-ANTHROPIC-API` | Anthropic API Token | `export ANTHROPIC_API_KEY=sk-ant-api03-...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-03-ANTHROPIC-ADMIN` | Anthropic Admin Token | `ANTHROPIC_ADMIN_KEY=sk-ant-admin01-...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-04-OPENAI-PROJ` | OpenAI Project Token | `OPENAI_API_KEY=sk-proj-...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-05-OPENAI-STD` | OpenAI Standard Bearer | `Bearer sk-48charOpenAITokenShape...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-06-AWS-AKID` | AWS Access Key ID | `AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-07-AWS-SECRET` | AWS Secret Access Key | `aws_secret_access_key = wJalrXUtnFEMI...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-08-GITHUB-PAT` | GitHub Personal Token | `https://ghp_0123456789abcdef...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-09-GENERIC-BEARER` | JWT / Bearer Token | `Authorization: Bearer eyJhbGciOi...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-10-PRIVATE-KEY` | PEM Private Key | `-----BEGIN RSA PRIVATE KEY-----...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-11-CODE-DIFF` | Unified Code Diff | `diff --git a/server.py b/server.py...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-12-PROMPT-MARKER` | LLM Prompt Structure | `<system_prompt>You are a confidential...` | **REJECTED** | 0% (Clean) |
| `SEC-FIX-13-ELF-MEM` | Raw ELF Process Memory | `\x7fELF\x02\x01\x01...` | **REJECTED** | 0% (Clean) |

### Test Summary
- **100% Rejection Rate**: All 13/13 fixtures successfully identified and rejected.
- **Zero Leakage**: Zero secret substrings present in JSON exports, DetectionReports, exception strings, or logger outputs.
- **Memory Scrubbing**: Transient buffers verified $100\%$ zeroed after classification.

---

## 7. Verification Evidence

### Required Test Commands & Results

1. **Verify Deliverable Documentation**:
   ```bash
   test -f docs/signalloom/slcd-p1-2-validator.md
   # Result: PASS (exit 0)
   ```

2. **Run All Host Sensor Unit & Leak Tests**:
   ```bash
   cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py'
   # Result: Ran 61 tests in 0.694s - OK (exit 0)
   ```

3. **Run Negative Security & Adversarial Leak Tests**:
   ```bash
   cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_negative_security test_leak_falsification test_payload_validator -v
   # Result: Ran 26 tests - OK (exit 0)
   ```

4. **Run Go Pseudonym Tests**:
   ```bash
   cd d2-signalloom/apps/signal-ingest && GOCACHE=/tmp/gocache go test ./pseudonym/... -v
   # Result: PASS - 3/3 tests passed (exit 0)
   ```
