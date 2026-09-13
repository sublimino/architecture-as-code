---
title: External-agent wire contracts
description: Implement the frozen P1 external-agent messages without overstating provenance, integrity, or runtime availability.
---

The external-agent v1 contract is a **P1 freeze**, not a runtime API
announcement. It fixes the interoperable message shapes and ownership
boundaries for later implementation. The OpenAPI file explicitly states that
no runtime routes are implemented here.

## Contract surfaces

The final OpenAPI contract describes five operations:

| Operation | Authentication | Contract owner | Meaning |
| :--- | :--- | :--- | :--- |
| Enrol | Single-use bearer token | FastAPI registration plane | Bind a token-authorised agent-host pair to an existing mTLS identity and Ed25519 audit key. |
| Upload evidence | mTLS | Go signal-ingest integrity plane | Validate shape, trusted binding, canonical digest, replay key, and host signature. |
| List evidence | OIDC | FastAPI read plane | Return tenant-scoped host evidence paired with server acceptance. |
| Read privacy contract | OIDC | FastAPI read plane | Return the frozen P1-2 privacy boundary. |
| Revoke an agent | OIDC | FastAPI authorisation/registration plane | Record independent audit-only revocation without rewriting evidence. |

These operations are specified in
`d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml`.
Runtime enrolment, durable replay handling, credential delivery, endpoint
deployment, and route configuration belong to later cards.

## Enrolment means binding, not issuance

An enrolment request contains the agent and host identifiers, Ed25519 public
audit key, nonce, and a reference to an already provisioned mTLS identity. The
fixed credential values are:

- `credential_kind`: `existing-mtls-identity`
- `credential_scope`: `audit-upload-only`
- `credential_bootstrap`: `pre-provisioned-out-of-band`
- `credential_reference`: a `spiffe://` URI

The `enrollment_state` value `enrolled` means that Signal Loom accepted the
binding between the existing credential, agent-host registration, and audit
key. Signal Loom does not mint, return, or accept private credential material in
this contract. The bearer enrolment token is carried only in `Authorization`,
is bound to a pre-registered agent-host pair, and has single-use atomic
compare-and-set semantics.

## Upload object

An `ExternalUpload` has exactly these fields:

1. `schema_version`
2. `upload_id`
3. `replay_key`
4. `session_id`
5. `sequence_start`
6. `sequence_end`
7. `assertion_envelope`
8. `original_chain_reference`

The `assertion_envelope` has exactly `format`, `algorithm`, `payload_sha256`,
`key_id`, `signature`, and `assertions`. Its fixed values are
`format = "signalloom-host-assertions-v1"` and `algorithm = "Ed25519"`.
`assertions` contains from one to 500 contiguous records and must exactly cover
the inclusive range from `sequence_start` through `sequence_end`.

Each assertion has exactly `schema_version`, `session_id`, `sequence`,
`observed_at`, `source`, `evidence_type`, `observation_state`,
`integrity_state`, `agent_id`, `host_id`, and `attributes`. The source remains
the host source: `nono-0.73.0` or `host-sensor-v1`. The only inbound integrity
value is `not-integrity-verified`.

The attributes are a closed discriminated union:

| `evidence_type` | Exact attribute fields |
| :--- | :--- |
| `process` | `health_state`, `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count` |
| `artifact` | `artifact_id`, `root_id`, `sha256`, `size_bytes`, `mtime_ns` |
| `network` | `destination_id`, `decision` |
| `collection-limit` | `reason_code`, `max_file_size_bytes`, `max_files_per_window`, `max_bytes_per_window`, `window_seconds` |

`collection-limit` requires `observation_state = "unobserved"`. An artifact
`mtime_ns` is **decimal text**, not a JSON number: it accepts canonical unsigned
decimal values from `"0"` through `"18446744073709551615"` without leading
zeroes. Keeping it as a string preserves the full `uint64` range across JSON
implementations.

## Canonical signing bytes

Do not sign the received upload bytes. Construct this signing document:

```json
{
  "assertions": "<assertion_envelope.assertions>",
  "domain": "signalloom.external-agent-upload.v1",
  "original_chain_reference": "<original_chain_reference>",
  "schema_version": "<schema_version>",
  "sequence_end": "<sequence_end>",
  "sequence_start": "<sequence_start>",
  "session_id": "<session_id>",
  "upload_id": "<upload_id>"
}
```

The angle-bracket values above are explanatory placeholders, not literal
strings. Their JSON types remain those defined by the schemas. The signing
document contains exactly those eight fields; it omits `replay_key` and the
envelope's self-describing signature metadata.

Encode the document as UTF-8 JSON using these rules:

- sort every object key lexicographically;
- emit no insignificant whitespace;
- permit only ASCII object keys and ASCII string values;
- encode JSON numbers as canonical base-10 integers;
- reject fractions, exponents, leading zeroes, and negative zero; and
- restrict JSON numeric values to `-9007199254740991..9007199254740991`.

The schemas narrow most numeric fields further: sequence and counter values are
non-negative, while `exit_code` is a nullable signed 32-bit integer. Use Go
`CanonicalSigningBytes` or the checked Python `canonical_signing_bytes` oracle
and the committed `valid-upload.v1.canonical.json` vector to prevent ordinary
JSON-library differences from becoming signature differences.

Compute lowercase hexadecimal SHA-256 over those canonical bytes. Both
`assertion_envelope.payload_sha256` and `replay_key` must equal that digest.
Sign the same canonical bytes with the pre-registered Ed25519 private key and
encode the 64-byte signature as canonical, unpadded base64url.

## Trusted binding and replay identity

The receiver supplies trusted registration context; it does not take tenant
scope from the upload body. The authenticated tenant, registered `key_id`,
registered `agent_id`, registered `host_id`, and Ed25519 public key must agree
with the connection and every assertion.

Durable replay handling must scope an upload by the tuple
`(trusted tenant_id, trusted key_id, upload_id)` and store its canonical digest.
For the same tuple:

- the same digest returns `idempotent-replay`; and
- a different digest returns a conflict.

This scope prevents one tenant or key from consuming another tenant's replay
identity. The P1 Go verifier checks that `replay_key` equals the canonical
digest and can validate an `accepted` or `idempotent-replay` acknowledgement;
it does not claim to implement the durable replay store.

## Three separate integrity statements

### Host signature

`VerifyHostUpload` checks the closed structure, trusted host binding, canonical
digest, replay key, and Ed25519 signature. A successful acknowledgement says:

```text
host_signature_state = host-signature-verified
original_chain_state = original-chain-not-verified
```

This is host provenance for the allowlisted export only.

### Original nono chain

`original_chain_reference` contains only `session_id`, `event_count`, and
`final_digest`. It is untrusted inbound metadata. It cannot contain server
`authority` or `state`, and it cannot establish original-chain integrity.

Raw original nono events never leave the host. The only original-chain verifier
is the local Go helper:

```go
VerifyOriginalChain(verifier, LocalChainInput{
    ExpectedSessionID: sessionID,
    Finalized:         true,
    Events:            trustedRawLocalEvents,
}, now)
```

`LocalChainInput` must be created from trusted collector-local raw events and
must be explicitly finalised. Upload data cannot populate it. Empty,
over-capacity, unfinalised, unavailable, or unverified input produces an
`unavailable` result; continuity or event tampering produces `tampered`; only a
complete successful pass produces `integrity-verified` under authority
`agentnono-go-v1`.

### Server acceptance

Acceptance is a separate server-owned object containing `upload_id`,
`accepted_at`, `replay_result`, `host_signature_state`, and
`original_chain_state`. Evidence pages preserve the original host `source` and
`not-integrity-verified` state, then pair each evidence object with acceptance.
They never nest an `integrity_result` into the evidence page.

## Privacy contract

The producer constructs a fresh object from the closed P1-2 allowlist. It never
exports raw nono records, commands, paths, URLs, raw errors, file contents,
process-memory contents, streamed payload digests or contents, or network
payload contents. `artifact_id` is an opaque `hmac-sha256:` identifier, not a
raw or reversible path. Missing or prohibited observations remain
`unobserved`; integrity never implies completeness or host trust.

See `docs/signalloom/agentmaxxing-host-policy.md` for the frozen host boundary.

## Schema authority

The six JSON Schemas in
`d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts/` are
authoritative:

- `external-agent-enrollment.v1.schema.json`
- `external-agent-evidence.v1.schema.json`
- `external-agent-privacy.v1.schema.json`
- `external-agent-revocation.v1.schema.json`
- `external-agent-server.v1.schema.json`
- `external-agent-upload.v1.schema.json`

They use JSON Schema draft 2020-12. The documentation catalogue at
`docs/signalloom/contracts/external-agent.v1.schema.json` references these files
relatively and contains no copied definitions.

## Verify an implementation

Run the checks independently from the repository root:

```bash
bats test/signalloom/contract-conformance.bats
(cd d2-signalloom/apps/signal-ingest && \
  env GOCACHE="${GOCACHE:-/tmp/gocache}" \
  GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" \
  CGO_ENABLED=0 go test ./collectors/agentnono)
PYTHONPATH=d2-signalloom/apps/fe-signalloom/src \
  python3 -m pytest -q \
  d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_contract.py
(cd d2-signalloom/apps/dashboard-signalloom && \
  bun run test -- --run src/types/externalAgent.contract.test.ts)
BUF_CACHE_DIR=/tmp/opencode/buf-cache buf build \
  d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.proto \
  -o /dev/null
```

The repository root is not the `signal-ingest` Go module, so a root command such
as `go test ./d2-signalloom/apps/signal-ingest/collectors/agentnono/...` is not a
valid substitute. The dashboard contract test imports Vitest; run it through
the package's `bun run test` script, not Bun's native `bun test` runner.

The current `make demo-agentmaxxing-contract-test` target runs only
`test/signalloom/operator-identity.bats`, the prior P1-1 contract. The governor
owns future shared Makefile wiring. Until that wiring lands, no single target
proves the P1-3 Go, Python, TypeScript, Protobuf, schema, and OpenAPI surfaces
green.
