# KTEST Phase 2 — Pre-Flight Record

Card `KTEST-P2-PRE`. Read-only audit of the Phase 2 baseline, harness, and card
specs. No Phase 2 deliverable was implemented.

- Base ref: `refs/heads/integration/ktest-p2-v0.1.0` = `0a61c33c6487a0c2e454017091fae527c5f00f09`
- HEAD at audit: `0a61c33c6487a0c2e454017091fae527c5f00f09` (detached, identical to the ref tip)
- `git merge-base --is-ancestor <ref> HEAD` → exit `0`
- Worktree clean at start and at commit (`git status --porcelain` empty)
- Cluster: kind `osramp`, `osramp-control-plane` Ready, v1.36.1

## Verdict

**Phase 2 may proceed.** The declared required test is green. Three findings
change what the Phase 2 cards should actually do, and one of them means the
Phase 2 security deliverable is currently graded by assertions that cannot fail.

## 1. Required test — green

`bash scripts/kagent-test.sh` → exit `0`, 34/34 assertions:

| Suite | Result |
|---|---|
| `d2-signalloom/test/kagent-contract.bats` | 5/5 |
| `test/kagent-install.bats` | 7/7 |
| `test/kagent-agents.bats` | 10/10 |
| `test/kagent-credentials.bats` | 3/3 |
| `test/kagent-demo-harness.bats` | 3/3 |
| `test/kagent-adversarial.bats` | 6/6 |

Readiness probes for this card's four stated objectives all pass: `kagent-controller`,
`kagent-postgres`, `kagent-tool-server` and `kagent-ui` each report a ready replica;
namespace `fe-signalloom-agents` exists carrying `signalloom.ai/purpose=agent-inventory`;
ModelConfig `anthropic-claude` has provider `Anthropic`; 8 Agent CRs are present.

## 2. The adversarial RBAC suite passes vacuously — highest severity

`test/kagent-adversarial.bats` returns **6/6 ok** when `NS` is rewritten to
`namespace-that-does-not-exist`. All four `can-i` denial tests go green against
ServiceAccounts that do not exist.

```
$ sed 's/NS="fe-signalloom-agents"/NS="namespace-that-does-not-exist"/' \
    test/kagent-adversarial.bats > /tmp/mutated-adversarial.bats
$ bats /tmp/mutated-adversarial.bats
1..6
ok 1 kagent-adversarial: read-only reader SA is denied creating pods in any namespace
ok 2 kagent-adversarial: read-only reader SA is denied deleting namespaces
ok 3 kagent-adversarial: commit-summariser SA is denied reading secrets outside its scope
ok 4 kagent-adversarial: security-analyst SA is denied modifying cluster RBAC bindings
...
mutated_rc=0
```

Two independent causes:

1. `kubectl auth can-i` answers `no` with exit 1 for a **nonexistent** subject
   exactly as for a genuinely denied one. Measured against the live cluster:
   a misspelled SA (`THIS-SA-DOES-NOT-EXIST`) returns `no`, status 1 — byte-identical
   to the real denial.
2. The assertion `[ "$status" -eq 1 ] || [ "$output" = "no" ]` accepts exit 1 from
   any cause. An unreachable API server also exits 1 (measured).

Tests 5 and 6 are namespace-independent (memory limit, NetworkPolicy) and are unaffected.

`scripts/check-vacuous-assertions.sh` passes clean over these files — this is the
"ninth way" its own output warns about. Fix shape: assert the subject exists
before asserting it is denied, and require the literal `no` on stdout rather than
accepting any non-zero exit.

## 3. The Phase 2 harness asserts `.spec`, never `.status` or behaviour

All 10 assertions in `test/kagent-agents.bats` read `.spec.declarative.*` — what
was applied, not what the controller made of it. No Agent CR in
`fe-signalloom-agents` carries any `.status` block, and the controller log is two
static lines with no per-object reconcile output. Nothing in the Phase 2 test
surface distinguishes "YAML applied" from "agent working".

This bears directly on `KTEST-P2-GOV`, whose spec says *certify MCP tool
execution*. No test executes a tool; the closest assertion
(`test/kagent-agents.bats:35`) is a substring match on a CR field.

Related dangling reference: `MCPServer/kagent-tool-server` is **NotFound** in
`fe-signalloom-agents`, yet `kagent-k8s-reader/agent.yaml` and
`kagent-security-analyst` both declare tools referencing it.
`test/kagent-agents.bats:70`, named "MCPServer resources are created for all
agents", iterates only five tool names and excludes `kagent-tool-server`.

## 4. Suite registration — pre-existing red, not caused by Phase 2

`d2-signalloom/test/bats-registry-coverage.bats` test 10 fails: 14 repo-root
suites are never invoked by `scripts/ci/vm-pipeline.sh`. Nine of the fourteen
already existed at `d662f365^`, so the oracle was red before the KTEST line was
cut; the salvage commit added five more.

`test/kagent-infra.bats` is the sharper case — it is invoked by **nothing**
(absent from `vm-pipeline.sh` and from `scripts/kagent-test.sh`) and is **4/4 red**.
Its subject `scripts/kagent-infra.sh` diverges from the contract the test states:
it ignores `KAGENT_INFRA_MANIFEST_DIR` entirely and hardcodes
`d2-signalloom/infra/kagent/{crds,local}`; `down` deletes the whole `kagent`
namespace rather than only the configured manifest directory; `status` runs no
`rollout status`; an unknown verb exits 1 where the test requires 2.

Not remediated here: the script belongs to Phase 1 (`e87889dd`), and registering
14 suites into shared CI is a cross-cutting change this card does not own. Adding
`test/kagent-infra.bats` to `scripts/kagent-test.sh` was considered and rejected —
it would turn this card's required test red over a defect Phase 2 did not cause.

## 5. Harness hygiene — latent

`scripts/kagent-test.sh` hardcodes the **principal checkout** in the PATH it
exports, at lines 5 and 69:

```
export PATH=/home/andy/src/cp/osramp-demo/scripts/bin:/usr/local/bin:/usr/bin:...
```

Every worktree run resolves the `fn`/`hermes`/`npx` stubs from the principal
checkout rather than `$REPO_ROOT/scripts/bin`. Harmless today (both copies are
identical) but the principal checkout is currently dirty with five modified
kagent deliverable files. `scripts/kagent-demo.sh` and
`scripts/kagent-harness-exec.sh` carry the same hardcode. Fix is
`$REPO_ROOT/scripts/bin`.

The embedded python fallback runner in `run_bats()` never executes `teardown()`
(measured). None of the six suites currently define one, so it is latent. The
fallback does correctly propagate a non-zero exit for failing assertions — a
laundering hypothesis was tested against three failure shapes and refuted.

## Spec reconciliation — what each Phase 2 card actually has left

Every artifact the Phase 2 cards were told to author already exists, introduced
by `d662f36585bab37da5b7bf89c4f609c3b48bcac1` ("salvage phase 1-7 deliverables
onto the integration line"). The decomposition was written from the KAGENT phase
plan rather than from the state of this base ref.

| Card | Spec clause | State |
|---|---|---|
| P2-1 | `kagent-k8s-reader/agent.yaml` exists | satisfied |
| P2-1 | `<= 30 lines` | satisfied — 26 lines |
| P2-1 | `signalloom.ai/agent` label | satisfied |
| P2-1 | ModelConfig reference | satisfied — `anthropic-claude` |
| P2-2 | `serviceaccount.yaml` | satisfied |
| P2-2 | read-only `ClusterRole` | satisfied — `rbac.yaml` |
| P2-2 | remote `MCPServer` reference to `kagent-tool-server` | reference present, **referent NotFound** |
| P2-2 | OpenBao paths | satisfied — `openbao-secret-paths.yaml` has `kagent-k8s-reader.json` |
| P2-3 | negative write/delete bounds | present but **vacuous** (see §2) |
| P2-3 | **positive read** bound | **absent** — no positive `can-i` probe exists for this SA |
| P2-3 | in `test/kagent-agents.bats` | **wrong file** — that file has 0 `can-i` probes; all 4 are in `kagent-adversarial.bats` |
| P2-GOV | run the two named suites | satisfied — both exist and pass |
| P2-GOV | verify memory footprint | satisfied — asserted twice |
| P2-GOV | certify MCP tool execution | **unmet** — no test executes a tool |

## Recommended disambiguation before Phase 2 dispatches

1. **P2-1** — restate as *verify and conform*, not *author*. Its measurable
   clauses already pass; the card should assert them and stop.
2. **P2-2** — the only outstanding work is the dangling
   `MCPServer/kagent-tool-server` referent. Either create the object or amend
   the two Agent CRs, and extend `test/kagent-agents.bats:70` to cover it.
3. **P2-3** — real work remains and it is larger than the spec implies: add the
   missing positive-read probe, and repair the four vacuous negative probes so
   they fail when the subject is absent. Resolve the file-location conflict:
   either move the probes into `test/kagent-agents.bats` as the spec says, or
   amend the spec to name `test/kagent-adversarial.bats`.
4. **P2-GOV** — its "certify MCP tool execution" clause cannot be met by the
   current harness. Either add a live tool-invocation probe or drop the clause
   explicitly rather than certifying it on a substring match.
5. **Out of this phase's scope** — `test/kagent-infra.bats` (red, unregistered)
   and the 14-suite CI registration gap need an owner.
