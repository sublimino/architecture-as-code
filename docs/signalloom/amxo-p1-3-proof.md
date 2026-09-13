# AMXO-P1-3 delivery proof

Status: **PASS — scoped contract freeze, qualified by the evidence report**.
Observed: 2026-09-13, Europe/London.

## Current prompt-to-artifact acceptance audit

| Requirement | Delivered artifact / evidence |
| --- | --- |
| Versioned enrollment/upload external OpenAPI | `d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml`; per-operation ownership, request/response/error schemas, enrollment/revocation/read/privacy. |
| Go and JSON wire types | `d2-signalloom/apps/signal-ingest/collectors/agentnono/external_contract.go` and `contracts/*.v1.schema.json`. |
| Protobuf wire definitions | `agentnono/external_contract.proto`; actual Buf compilation via root BATS; typed attributes, presence, explicit JSON mapping. |
| Generated dashboard API types | `d2-signalloom/apps/dashboard-signalloom/src/types/externalAgent.ts`; schema-driven generator `fe-signalloom/src/generate_external_agent_types.py --check`; TypeScript compiler negatives. |
| Valid/malformed/tampered fixtures | `agentnono/fixtures/contracts/`; real Ed25519 signing bytes, enrollment/upload/response/privacy/error/revocation cases. |
| Across-service compliance | Go `external_contract_test.go`; Python `test_external_agent_contract.py`; four `test_contracts_external_agent_boundary` cases in required API compatibility test file; dashboard type tests; root conformance BATS. |
| Process and disk bounds/privacy | Closed evidence/privacy schemas; frozen P1-2 constants; safe integers and bounded decimal nanosecond string; no raw payload exports. |
| Ownership/threat assumptions | `docs/signalloom/contracts/README.md`; host assertions vs server acceptance vs local original-chain verification expressly separated. |
| Published JSON schema entry point | `docs/signalloom/contracts/external-agent.v1.schema.json`; six relative authoritative references without duplicated definitions. |
| Docs-signalloom page | `src/content/docs/reference/external-agent-wire-contracts.md`; Astro build succeeds; browser smoke not verified. |
| Existing telemetry and SPIFFE compatibility | Uncached Go collector and identity packages pass; legacy verifier/HTTP composition unchanged. |
| Runtime isolation/identity/determinism steps 8–15 | Repeated invariants implemented as closed lexical/schema boundaries, trusted host/key binding, source isolation, reproducible canonical signatures; not a deployed host sandbox. |
| Requested commands | Exact commands and compatibility qualifications in `amxo-p1-3-evidence.md`; backend 56, focused selector 4, unmasked BATS 9 pass. |
| Independent full regression | API/model 113, dashboard API/type 555, Go collector/identity and vet, Astro build pass. |
| Worktree commit | This proof is delivered in the scoped conventional implementation commit; full SHA recorded in proposal Result and qualified errata after commit. |
| Integration commit | Pending Governor reconciliation; worker must not merge, rebase, push, or create PR. |
| Qualified proposal success record | Publish only the P1-3 block and Result in the explicitly named proposal; not in this Git commit. |

The prior failure below is historical evidence, superseded by Governor recovery
and implementation. Its original files remain available in `12dc22d3`.

## Historical prerequisite gate (superseded)

## Authorized baseline

- Requested worktree: `/home/andy/src/.worktrees/539f5/osramp-demo`.
- Initial sandbox `pwd`: `/home/andy/.cline/worktrees/539f5/osramp-demo`.
- Explicit-workdir Git top-level: `/home/andy/src/.worktrees/539f5/osramp-demo`.
- HEAD and prescribed integration ref: `ebd90f096bfc43bda100463f284941ffaa8caa19`.
- `git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD`: exit 0.
- Initial `git status --short`: empty (clean).

## Blocking prerequisite evidence

The card requires consuming already-merged P1-1 and P1-2, without rebuilding
them. The supplied proposal records these commits and says their Governor
merges are pending. Explicit Git probes confirm neither is in this baseline:

| Probe | Result |
| --- | --- |
| `git cat-file -t 363398237c202bba7abc6bfb493d3fc955acb79b` | `commit`, exit 0 |
| `git merge-base --is-ancestor 363398237c202bba7abc6bfb493d3fc955acb79b HEAD` | exit 1 |
| `git cat-file -t aca5f51efc54095ba108f796f2a517fe5f8bb52d` | `commit`, exit 0 |
| `git merge-base --is-ancestor aca5f51efc54095ba108f796f2a517fe5f8bb52d HEAD` | exit 1 |

These are present commit objects with negative ancestry, not conclusions from
empty file searches. The task's decision policy requires stopping on a material
plan/disk contradiction. Only the Governor may reconcile integration. No ref
was switched, rebased, merged, or cherry-picked to bypass this condition.

## Required checks

| Command | Execution evidence |
| --- | --- |
| `kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode AMXO doctor` | PASS: `ALL CHECKS HEALTHY`; graph, review ledger and filesystem proofs, not dependency ancestry |
| `test -f docs/signalloom/amxo-p1-3-proof.md` | Run during closeout; existence only, not implementation acceptance |
| `make demo-signalloom-api-test TIER=contract` | NOT RUN: stopped at prerequisite gate |
| `bun test d2-signalloom/apps/dashboard-signalloom/src/api/` | NOT RUN: stopped at prerequisite gate |
| `go test -v ./d2-signalloom/apps/signal-ingest/collectors/agentnono/...` | NOT RUN: stopped at prerequisite gate |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_api_compat.py -k test_contracts` | NOT RUN: stopped at prerequisite gate |
| `bats test/signalloom/contract-conformance.bats || true` | NOT RUN: stopped at prerequisite gate; tolerated shell status would not prove conformance |

## Prompt-to-artifact acceptance audit

| Required deliverable | State |
| --- | --- |
| Versioned enrollment/upload OpenAPI in FastAPI contracts directory | NOT DELIVERED |
| Protobuf/JSON, Go structs, session/process/disk schemas in agentnono | NOT DELIVERED |
| Generated dashboard `src/types/externalAgent.ts` | NOT DELIVERED |
| Cross-service valid/malformed/tampered contract fixtures and validation | NOT DELIVERED |
| Backward compatibility and tenant-isolation evidence | NOT VERIFIED |
| Architecture contracts and privacy allowlist in `docs/signalloom/contracts/` | NOT DELIVERED |
| Docs-signalloom external-agent wire contract page | NOT DELIVERED |
| Evidence report and proof | Failure-only records; not acceptance evidence |
| Isolated worktree commit | Failure evidence only; SHA reported at closeout |
| Commit merged onto integration | NOT DONE; Governor-only authority |
| Qualified proposal errata and P1-3 Result cell | Publication blocked as described below |

## Proposal publication discrepancy

The supplied principal-checkout proposal contains `## Appendix`,
`### Spec: Work Decomposition`, P1-3's row, and `### Spec: Errata`.
The card simultaneously declares that this proposal lives in Obsidian.
`obsidian-search --json` resolved the same title to:

`2. Areas/CEO/Innovation Proposals/Proposal — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3).md`

The bridge returned `status: ok`; a successful `obsidian-read --json` returned
the note's content. That note instead has `## Delivery Results` with only
AMXO-P1-1 and `## Spec: Errata` with only P1-1's errata. It has no Appendix,
Work Decomposition table, or P1-3 row. No alternative section or table was
created. No principal-checkout or vault file was modified. Qualified failure
errata is retained in the companion evidence report, pending canonical-location
reconciliation; this is not a claim of publication.

## Required recovery

Governor must reconcile P1-1 and P1-2 onto the prescribed integration branch,
then the runtime must provide an authorized checkout containing those frozen
dependencies. Resolve which proposal surface owns the canonical Appendix
before publishing the failure block and updating only P1-3's Result cell.
Do not treat the generic doctor PASS or existence of this proof as P1-3 PASS.
