# SLED Phase 3 governor certification decision

**NOT CERTIFIED — status=fail, proceed=no, blocking_drift=yes.**

Audit date: 2026-09-22, America/Chicago. This is a refusal of certification,
not an attestation that four-stage teardown or zero leakage has been achieved.
Passing the lifecycle unit suite does not change that verdict.

## Scope and provenance

All repository operations used the dedicated governor worktree
`/home/andy/src/.worktrees/osramp-demo/sled-v0.1.0/governor` on
`integration/sled-v0.1.0`. Initial HEAD was
`150404e06c2653f070b1c1e529d634df1f987668`.

| Prerequisite | Evidence | Disposition |
| --- | --- | --- |
| SLED-P2-GOV | Existing [Phase 2 decision](sled-p2-certification.md) explicitly says NOT CERTIFIED; its proposal errata says fail | Phase gate remains closed |
| SLED-P3-PRE | `47c5b628914d4fbf76dbd200a0e2f035bdd61bb8`; parent `3b73e570a0c571d603e476fa934d69fcfb8420fd` is an ancestor of integration | Documentation integrated under repository mutation lock as `624c6057bb469ee07c246faf78533fd7ef4cc7a5` |
| SLED-P3-1 | `b1a0b9c0a972e022dff7dfd54ac47da46ae75e83`; same historical integration base; proposal records delivery | Preserved, NOT merged: lifecycle file conflict plus safety defects below |
| SLED-P3-2 | Helper card `82535` reports done, unknown session, null workspace, no errata or ledger; local `git log --all --grep=SLED-P3` finds only P3-PRE and P3-1 | No eligible committed Stage 3/4 implementation established |

A common historical integration ancestor is not itself an untrusted base.
P3-1 needs deliberate conflict resolution and corrected implementation evidence;
the conflict has not been declared irreconcilable. No sibling checkout was edited,
no board record was hand-edited, and nothing was pushed.

The imported preflight is a historical design document, not a passing runtime
certificate. Its proposed 30-second namespace timeout and finalizer recovery
must be reconciled with this card's maximum 10-second deallocation call bound;
blind finalizer removal is not proof of storage cleanup.

## Four-stage review

`SRC` below means `d2-signalloom/apps/fe-signalloom/src/`. References to P3-1
describe the unmerged commit above, not code shipped on the integration branch.

| Stage | Observed implementation | Gate |
| --- | --- | --- |
| 1: HTTPRoute removal | P3-1 has delete/re-list logic, but an unreachable effect probe returns `None` and the stage rejects only `False`; prior completion skips revalidation | FAIL: postcondition can be unknown or stale |
| 2: Tailscale eviction | P3-1 defaults to mock; live requires `SIGNALLOOM_EAP_TAILSCALE_LIVE=1`. The shell live path resets/logs out the local node, suppresses command failures with `|| true`, and falls back to mock when the binary is missing | FAIL: successful exit cannot establish tenant-specific eviction or DNS removal |
| 3: key destruction and SPIRE pruning | Described in `scripts/eap/build_sled_specs.py:540–571`; no eligible delivered SLED implementation established | NOT VERIFIED |
| 4: workload/namespace deletion | Described in the specification; no eligible delivered SLED implementation established | NOT VERIFIED |

At audited integration HEAD, `SRC/environment_lifecycle.py:699–722` changes a
draining record directly to `TERMINATED` after grace expiry. A fresh in-memory
probe produced `terminated`, `completed_stages=[]`, `action=terminated`.
`list_active` then excludes terminated records (`818–821`). Consequently the
current reaper can stop tracking an environment without proving reclamation.

P3-1 also assumes `Path(__file__).resolve().parents[4]` at import time
(`environment_teardown.py:55–56`). The Dockerfile copies source into `/app`;
the corresponding path arithmetic raises `IndexError`. This was verified by a
pure path probe, not a deployed-image test. Packaging and executable availability
need separate validation before deployment.

## Prompt-to-evidence checklist

| Required claim or deliverable | Evidence / artifact | Verdict |
| --- | --- | --- |
| Ordered, idempotent four-stage execution | Review above; [audit log](evidence/sled-p3-governor-audit.md) | FAIL: full pipeline not established |
| No silent partial deallocation failures | P3-1 probe handling and shell error suppression | FAIL |
| Permanent cryptographic shredding | [Cryptographic evaluation](evidence/sled-p3-cryptographic-evaluation.md) | NOT VERIFIED |
| Deleted OpenBao path returns 404 | No authorized synthetic key deletion/read-back executed | NOT VERIFIED |
| Zero orphan namespaces, HTTPRoutes, mesh slots | [Resource inspection](evidence/sled-p3-resource-inspection.md) | Baseline only; no teardown attribution |
| Retry and network-timeout fuzz coverage | P3-1 fake-kubectl/mock tests reviewed; no integrated four-stage target exists | NOT RUN for full pipeline |
| Atomic tracking across distributed workers | `LifecycleRecord` and manager dictionaries with process-local `RLock` | NOT VERIFIED; local locking is not a distributed transaction |
| Canonical identity | Direct calls: `kurasi → 6f82ad81`, `kusari → 4b53ab6b` | PASS for kurasi; spelling must not be silently substituted |
| Immutable transition audit emission | Schema tests pass, but stored events are mutable objects exposed by retrieval; the process-local log truncates to 1,000 entries | FAIL: schema conformance is not immutable storage |
| Per-call timeout at most 10 seconds | No integrated Stage 3/4 implementation; preflight proposes 30 seconds | NOT VERIFIED / specification mismatch |
| Cgroup v2 CPU/memory accounting release artifact | Resource inspection report, cgroup section | NOT VERIFIED without pre-teardown UIDs/cgroup IDs |
| Iptables/conntrack inspection transcript | Resource inspection report, network section | NOT EXECUTED; no attributable deleted-tenant IP inventory |
| HostPath/local-path directory wiping | Resource inspection report, storage section | NOT VERIFIED |
| SPIRE monotonically decreasing datastore entries | Resource inspection report, identity section | NOT VERIFIED; no pruning passes measured |
| Kernel ring buffer payload absence | Resource inspection report, kernel section | NOT VERIFIED; no broad payload harvesting performed |
| Auditd/process namespace eviction log | Resource inspection report, process section | NOT EXECUTED; no controlled teardown sequence |
| `pytest tests/test_environment_lifecycle.py -v` | Post-merge transcript in audit log: 23 passed, exit 0 | PASS, lifecycle scope only |
| All Phase 3 test suites pass | Missing integrated Phase 3 suite; supplemental Phase 2 tests lack async plugin | NOT ACHIEVED |
| `test -f docs/signalloom/sled-p3-certification.md` | Governor checks existence after authoring | Existence is not certification approval |
| Qualified proposal errata with status=pass | Safety requires status=fail until the gates above pass | PASS deliberately withheld |
| Mechanical cost/table update | Both canonical accounting calls exit 126: argument list too long | BLOCKED; no spend values fabricated |
| Local commit of evidence | Governor commit containing this decision and linked artifacts | Required before handoff; verify with Git history |

## Safety and recovery boundary

The card's high-precedence Task Contract says `lifecycle boundary: create-only`
and limits this governor to integrating approved phase work. Its lower-priority
role prose also requests restarting/recreating failed existing cards. Those
instructions conflict for existing-card lifecycle mutations. No restart,
recreation, or direct implementation in sibling worktrees was attempted under
the narrower contract. This needs a reconciled authorization, not a guessed
permission or an invented success report.

A read-only `remediate --task-id 82535 --dry-run` feasibility check was executed
through the bundled helper with the actual proposal path. It refused because
P3-2 is in `done`, not `review` or `in_progress` (exit 1). This is evidence about
that recovery operation, not a claim that every possible recovery mechanism is
impossible. Any next operation must still respect the create-only boundary.

Phase 2's event-loop lock defect also directly gates adding blocking subprocess
teardown to the reaper. The governor must not bypass it merely to make Phase 3
appear wired. Real shared Tailscale logout, key destruction, namespace deletion,
finalizer removal, and shared-node cleanup were not executed.

## Conditions for re-certification

1. Resolve the create-only/recovery conflict and restore the failed Phase 2 gate
   through its owners, including telemetry and event-loop safety.
2. Correct P3-1's fail-open/live-target/packaging defects, resolve integration
   conflicts, and re-run its tests against the resulting integration base.
3. Deliver P3-2 with fail-closed key destruction and identity revocation before
   namespace/PV release. Prove deletion completion rather than request acceptance.
4. Supply a controlled, disposable tenant fixture and before/after inventory for
   kernel, storage, network, process, OpenBao, SPIRE, and Tailscale assertions.
5. Exercise repeated teardown, timeout injection, partial failures, concurrent
   workers, and restart recovery; establish durable atomic stage tracking.
6. Repair the external accounting helper's oversized environment-variable failure
   through its owner. Update the real proposal through the Obsidian bridge, not
   a raw filesystem writer. Re-run accounting and preserve its printed table.

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
