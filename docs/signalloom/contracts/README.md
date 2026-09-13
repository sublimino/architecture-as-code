# Signal Loom external-agent contracts

This directory is the documentation entry point for the frozen P1 external-agent
wire contract. It describes a contract boundary, not deployed routes. Runtime
enrolment, credential delivery, persistence, and endpoint implementation belong
to later cards.

## Architecture and service ownership

| Boundary | Owner | P1 responsibility |
| :--- | :--- | :--- |
| Host sensor and sandbox | AgentMaxxing Platform Engineering | Run nono `0.73.0`, apply the frozen host policy, create allowlisted evidence, retain raw nono events locally, and sign the host assertion envelope. |
| Registration plane | FastAPI registration plane | Define token-bound registration of an existing mTLS identity and Ed25519 audit key. It does not issue credential material. |
| Upload integrity plane | Go `signal-ingest/collectors/agentnono` | Validate the closed upload shape, trusted agent/host/key binding, canonical digest, replay key, and host Ed25519 signature. It alone verifies a raw original nono chain from trusted local input. |
| Read plane | FastAPI read plane | Define tenant-scoped projections that preserve host provenance and pair evidence with separate server-acceptance metadata. |
| Revocation plane | FastAPI authorisation/registration plane | Define independent audit-only revocation without rewriting or deleting evidence. |
| Retention and deletion | ControlPlane Signal Loom Operations | Own the frozen 30-day evidence retention and seven-day deletion deadline. |
| Test aggregation | Signal Loom governor | Wire later card suites into shared Make targets. The current `demo-agentmaxxing-contract-test` target covers the prior P1-1 operator-lifecycle suite only. |

The operation-owner names above come from the final OpenAPI contract. They are
design ownership labels; their presence does not mean that the operations are
implemented.

## Trust boundaries

The contract separates three facts that must never be collapsed:

1. **Host provenance:** the upload verifier confirms an Ed25519 signature over
   canonical host assertions using a pre-registered host binding.
2. **Server acceptance:** the server records whether that signed upload was
   accepted or was an idempotent replay. Acceptance metadata is stored beside,
   not inside, the host evidence.
3. **Original-chain integrity:** only the Go `agentnono` verifier can derive this
   from trusted raw local nono events. An inbound `original_chain_reference` is
   an untrusted host claim and has no `authority` or `state` field.

Upload verification proves only host Ed25519 provenance for the exported,
allowlisted assertions. It does not prove the original nono chain, host
trustworthiness, completeness, compliance, or production acceptance.

## Threat model

| Threat | Contract control | Residual boundary |
| :--- | :--- | :--- |
| Cross-tenant upload or replay | Tenant scope comes from the authenticated principal; replay identity is scoped by trusted tenant and key. | Runtime authentication and durable replay storage are later work. |
| Key substitution | `key_id`, `agent_id`, and `host_id` must match the trusted pre-registration; mTLS binds the uploader to that registration. | Key provisioning and rotation are not implemented by this freeze. |
| Payload mutation | `replay_key` and `payload_sha256` must equal the SHA-256 digest of the canonical signing bytes; Ed25519 verifies those bytes. | A valid host key can still sign incomplete observations. |
| Replay ambiguity | Persist replay state under `(trusted tenant, trusted key_id, upload_id)` with the canonical digest. The same digest is idempotent; a different digest for the same scoped upload is a conflict. | The P1 Go helper validates a supplied replay result; it does not implement storage. |
| Forged chain result | Uploads can carry only `original_chain_reference`; server integrity authority and state are prohibited inbound. | Original-chain verification requires trusted collector-local events. |
| Sensitive-data leakage | Closed per-type attributes are constructed afresh; unknown fields and raw nono records are not exported. | Host policy enforcement remains a host responsibility. |
| Parser ambiguity | Unknown, duplicate, missing, trailing, non-ASCII, and non-canonical numeric forms are rejected. | Implementors must use the executable oracle, not ordinary JSON equivalence. |

## Privacy boundary

Raw original nono records never cross the host boundary. Commands, paths, URLs,
raw errors, file contents, process-memory contents, streamed payload digests or
contents, and network payload contents are also prohibited. Artifact paths are
represented only by opaque `hmac-sha256:` identifiers under the two approved
hashable root IDs.

The exported `source` remains the host-observed value (`nono-0.73.0` or
`host-sensor-v1`). The server must not replace it with `signal-ingest` or use it
to claim local chain integrity. Server facts such as `accepted_at`,
`replay_result`, `host_signature_state`, and `original_chain_state` live in the
separate `acceptance` object.

## Compatibility and signing

P1 freezes `schema_version` `1.0.0`, host assertion format
`signalloom-host-assertions-v1`, Ed25519, and the canonical JSON rules. Every
object is closed. Additive fields therefore require a new compatible contract
version rather than being silently accepted by a 1.0.0 reader.

The host signs the canonical signing document defined by Go
`CanonicalSigningBytes`; it does not sign the received JSON bytes verbatim. The
signature is an unpadded canonical base64url encoding of exactly 64 Ed25519
signature bytes. `payload_sha256` and `replay_key` are lowercase SHA-256 hex of
the canonical signing document. See the
[external-agent wire reference](../../../d2-signalloom/apps/docs-signalloom/src/content/docs/reference/external-agent-wire-contracts.md)
for the exact fields and lexical constraints.

## Authoritative wire locations

| Purpose | Authoritative location |
| :--- | :--- |
| HTTP operation contract | `d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml` |
| Go wire structs and verification oracle | `d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.go` |
| Protobuf mapping | `d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.proto` |
| Contract vectors and Go tests | `d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract_test.go` and `fixtures/contracts/` |
| Six authoritative JSON Schemas | `d2-signalloom/apps/signal-ingest/collectors/agentnono/contracts/` |
| Frozen host policy | `docs/signalloom/agentmaxxing-host-policy.md` |
| P1-2 governance record | `docs/signalloom/amxo-p1-2-evidence.md` and `docs/signalloom/amxo-p1-2-proof.md` |
| Documentation schema catalogue | [`external-agent.v1.schema.json`](external-agent.v1.schema.json) |

The catalogue contains relative `$ref` links only. It does not copy or replace
the six collector-owned schemas.

## Independent checks

Run each check from the repository root unless the command contains a subshell:

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
(cd d2-signalloom/apps/docs-signalloom && \
  ASTRO_TELEMETRY_DISABLED=1 bun run build)
```

Do not substitute `go test ./d2-signalloom/...` at the repository root: the root
is not the `signal-ingest` Go module. Do not substitute Bun's native
`bun test` runner for the dashboard command: this test is a Vitest suite and the
package script supplies that runner. These are independent checks; one passing
command is not evidence that the others passed. The existing root Make target
does not aggregate this P1-3 suite, so no universal green target is claimed.
