# AMXO-P1-3 contract validation evidence

Recorded 2026-09-13, Europe/London. **PASS for the versioned contract freeze,
qualified below; not runtime or partner acceptance.** See
[prompt-to-artifact proof](amxo-p1-3-proof.md) and
[architecture contract](contracts/README.md).

## Recovery and scope

The previous prerequisite failure is preserved in commit `12dc22d3`. Andrew
reported Governor recovery; independent ancestry checks confirmed integration
`155a9f16`, P1-1 `36339823`, and P1-2 `aca5f51e` are ancestors of this task's
starting HEAD `b552e95a`. No worker merge or base substitution was performed.

The implementation publishes OpenAPI 3.1, six closed Draft 2020-12 schemas,
protobuf source, Go structs/oracles, pure Pydantic validation, generated
TypeScript unions, signed vectors, and documentation. No live endpoint,
database migration, deployment, or customer telemetry collection was added.

## Exact requested commands

| Command | Actual outcome | Interpretation |
| --- | --- | --- |
| `make demo-signalloom-api-test TIER=contract` | exit 0; 56 passed | Existing backend consumer contract regression; not alone P1-3 coverage. |
| `bun test d2-signalloom/apps/dashboard-signalloom/src/api/` | failed; `vi.hoisted`, `vi.stubGlobal`, `vi.unstubAllGlobals` unavailable | Native Bun runner is incompatible with existing Vitest tests. Unrelated API tests were not rewritten to accommodate it. |
| `go test -v ./d2-signalloom/apps/signal-ingest/collectors/agentnono/...` | exit 1; directory prefix does not contain main module or selected dependencies | Repository has nested Go modules, not a root module/workspace. No root workspace was introduced. |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_api_compat.py -k test_contracts` | exit 0; 4 passed, 82 deselected | Added real positive/negative API-plane request/response model fixtures to this required entry point. Initially selected zero tests, now covered. |
| `bats test/signalloom/contract-conformance.bats || true` | nine `ok`, no skips | Also rerun without `|| true`: exit 0, nine passed. |
| `kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode AMXO doctor` | Before publication: exit 0, `ALL CHECKS HEALTHY`. After required proposal publication: nonzero, sole exception DOC-3 principal proposal dirty. | Required proposal write conflicts with generic principal-clean gate. Worker cannot commit, revert, or stash the proposal; Governor/principal reconciliation remains necessary. |

## Independent final validation

All commands below were independently rerun after final implementation fixes.
Go used `CGO_ENABLED=0`, `GOCACHE=/tmp/opencode/go-cache`, and
`GOMODCACHE=/tmp/opencode/amxo-modcache`. Default host caches were permission
denied; dedicated caches avoided changing permissions or repository dependencies.

| Working directory | Command | Result |
| --- | --- | --- |
| Repository | `pytest -q d2-signalloom/apps/fe-signalloom/src/tests/test_api_compat.py d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_contract.py` | 113 passed; 86 compatibility cases plus 27 external-contract cases. |
| `d2-signalloom/apps/signal-ingest` | `go test -count=1 ./collectors/agentnono/... ./identity/...` | Both packages passed uncached. |
| Same Go module | `go vet ./collectors/agentnono/...` | exit 0. |
| Dashboard application | `bun run test --run src/api/ src/types/externalAgent.contract.test.ts` | 29 files, 555 tests passed. |
| Dashboard application | `bun run typecheck` | exit 0, including compiler-enforced negative integrity-result cases. |
| Repository | `bats test/signalloom/contract-conformance.bats` | Nine passed, zero skipped. |
| Docs application | `ASTRO_TELEMETRY_DISABLED=1 bun run build` | exit 0; Astro checker: zero errors, zero warnings; static output built. Bundler emitted its existing chunk-size advisory. |

BATS invokes actual Buf compilation of the protobuf, resolves OpenAPI ownership
and references, checks frozen policy constants, and runs the type generator in
non-mutating `--check` mode. Python validates shared fixtures against both JSON
Schema and Pydantic, plus lexical and cross-field invariants. Go independently
verifies real Ed25519 vectors and original local signed chains, rather than
accepting a fixture's claimed state.

## Security regressions proved

- Valid host signature and binding accepted; changed digest, signature, key,
  agent/host binding, tenant injection, and sequence mutations rejected.
- Host assertions cannot claim `signal-ingest` source or server integrity.
- Missing required zero-valued fields, null scalars, duplicate keys, escaped
  duplicate keys, and case-variant Go JSON field aliases rejected recursively.
- Safe integers, bounded decimal `mtime_ns`, strict timestamp grammar,
  canonical base64url, and deterministic reordered-key signing vectors tested.
- Evidence discriminator and observation-state coupling checked across schemas,
  Pydantic, Go input validation, and generated TypeScript.
- A genuinely re-signed event with a missing previous digest is rejected as a
  discontinuous original chain; empty, over-cap and non-finalized local sessions
  never produce `integrity-verified`.
- Server integrity state/reason/digest combinations are constrained; generated
  TypeScript rejects the formerly accepted contradictory verified result.
- Existing collector/verifier and SPIFFE identity-package regressions pass;
  legacy verifier and HTTP composition roots are unchanged.

## Review and limitations

Independent review initially rejected multiple revisions despite green tests.
Concrete reproducers drove fixes. The final reviewer reran the signed alias
exploit, missing-chain-link test, Python identifier negatives, and a real
TypeScript compiler check, then approved the scoped freeze. `roborev` was not
available; no roborev pass is claimed.

A QATester attempted local static browser verification. Browser execution was
blocked by sandbox permissions/missing bundled Chromium; no screenshot or
visual acceptance is claimed. This does not replace the successful Astro build.
No Linux host sandbox was launched and no Landlock compatibility claim is made.

### Explicit architecture qualifications

1. Upload acceptance proves **host-signature provenance**, not original raw
   nono-chain integrity. Raw records are prohibited from export. Original-chain
   verification is an explicitly local Go operation with trusted inputs and
   finalized state; an inbound chain reference remains untrusted. Future work
   must not promote the upload acknowledgement into an original-chain proof.
2. Enrollment binds a pre-provisioned mTLS identity and Ed25519 audit key and
   activates audit-upload-only authorization; this freeze does not issue or
   deliver certificate/private-key material. Runtime provisioning, atomic token
   consumption, revocation, durable replay, and retention/deletion remain later
   phase implementations, not accomplishments of this card.
3. Shared Makefile and route wiring remain Governor-owned. The existing
   `demo-agentmaxxing-contract-test` runs P1-1 only. Governor must add the P1-3
   BATS/Python/Go/Vitest gates; it must not credit that old aggregate as P1-3.
4. Protobuf source compiles; generated runtime Go protobuf bindings and a live
   protobuf transport are not delivered. JSON is the canonical signed wire;
   protobuf's documented mapping is not signed as ProtoJSON.
5. The exact supplied proposal path is a regular file, not a vault symlink.
   The same-titled Obsidian note has different sections and no required P1-3
   row. Only the explicitly named proposal Appendix/Result may be updated;
   no substitute vault section, prior errata, or other row is changed.

Integration merge and phase acceptance remain exclusively Governor-owned.

## Publication and final closeout gate

Implementation commit: `64a3e300ce67ad261ef0713a82cfd822c6b52a52`.
Read-back confirmed exactly one qualified AMXO-P1-3 success errata inside the
specified proposal Appendix, with both timestamps and the implementation SHA;
only this card's decomposition Result was updated. Proposal is excluded from
the implementation commit and the isolated worktree is clean after committing.

The post-publication doctor reports exactly one exception:
`PRINCIPAL CHECKOUT DIRTY (DOC-3)` for the required proposal update. This is an
external closeout gate, not a contract-test failure. The objective's demand for
a green doctor cannot be achieved simultaneously with publishing the required
proposal update and the prohibition on committing that proposal. No principal
cleanup or runtime-state mutation was attempted. The implementation is a
qualified success; overall gate reconciliation remains pending.
