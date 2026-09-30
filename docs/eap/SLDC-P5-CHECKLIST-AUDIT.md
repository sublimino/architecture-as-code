# SLDC-P5-PRE - Operational Rollout Pre-Flight Audit (Appendix F.4)

**Card:** SLDC-P5-PRE · **Base:** `integration/sldc-v0.1.0` @ `445dd4cf45db02b59f8922bf3c64e1b1f0b2ef8b` · **Cluster:** `kind-osramp` · **Captured:** 2026-09-30 09:45 +01:00

**Verdict: FAIL - Phase 5 must not start.** Two of six F.4 gates pass (PF-3, PF-4). Four fail (PF-1, PF-2, PF-5, PF-6). Two auxiliary readiness checks that P5-1 depends on also fail: the live sentinel cannot list pods, and the Kusari stub has no `/act` API.

Every result below is reproducible with one read-only command:

```bash
scripts/verify-operational-gates.sh --out ci-evidence/p5-preflight-audit.json   # exit 1 today
bats test/p5-operational-preflight.bats                                          # 24 tier-1 + 1 tier-2 (P5_LIVE=1)
```

## Gate matrix

| Gate | Result | Static (this checkout) | Live (`kind-osramp`) |
| :--- | :--- | :--- | :--- |
| PF-1 Swarm pod annotation | **FAIL** | n/a (runtime state) | `agent-cardvault`, `agent-nono-evidenced` (Deployments) and `agent-sir-lancelot` (**bare Pod - no Deployment exists**) carry no `signalloom.io/stunned` annotation |
| PF-2 SPIRE registration job | **FAIL** | no `spire-register-entries` Job manifest anywhere in the repo | Job absent; `spire-system` SPIRE has `sa/stun-sentinel` (1) but **no `sa/fleet-manager`**; `inf-bao` SPIRE (42 entries) still holds the legacy `sa/signalloom-stun-sentinel` entry and no new ones |
| PF-3 OpenBao JWT glob | PASS | `openbao-supercred-bootstrap.yaml` role `signalloom-cardvault-agent`: `bound_claims_type: glob` | `bao read auth/jwt/role/signalloom-cardvault-agent` → `glob` |
| PF-4 CEL admission whitelist | PASS | `isGovernorOrAdmin` contains `system:serviceaccount:fe-signalloom:supercred-demo-runner` | same, read from the live `ValidatingAdmissionPolicy` |
| PF-5 Owner-record phase gating | **FAIL** | see below | DaemonSet `stun-sentinel` runs `stun-sentinel:latest`, which is the **legacy reconciler** build (738 `stun`/`unstun` events in its log) |
| PF-6 Acceptance DS name | **FAIL** | `test/swarm-fleet-acceptance.bats` references `signalloom-stun-sentinel` 3×, `stun-sentinel` 0× (lines 27, 76, 81) | DaemonSet `stun-sentinel` present |
| AUX-RBAC sentinel informer | **FAIL** | - | `kubectl auth can-i list pods -A --as=system:serviceaccount:fe-signalloom-agents:stun-sentinel` → `no`; the sentinel logs `pods is forbidden` every minute (26 in 10 min) |
| AUX-ACT Kusari `/act` API | **FAIL** | `kusari-agent/main.go` registers only `/quote`, `/{$}`, `/stats`, `/healthz`; `read-passwd` never existed on any ref | `/healthz` → `{"status":"ok"}`; `/act/healthz`, `/act/read-passwd`, `/act/cpu-burn` → 404 |
| AUX-FORENSIC staging dir | PASS | - | `/tmp/sldc-forensics` and `/tmp/kusari-e2e` writable, 216 GB free |
| AUX-KEYS signing keys | PASS | `.keys/cosign.pub`, `witness-pub.pem`, `orbit-approval-pub.pem` parse; `cosign.key` is an encrypted Sigstore key | - |

## Findings in detail

### PF-1 - the failure it guards against has already happened

The deployed legacy reconciler (`d2-signalloom/apps/signalloom-stun-sentinel/main.go`, `reconcile`) **thaws every pod it does not consider stunned**. At `2026-09-30T05:17:15Z`, on start-up, it emitted `unstun` for `agent-cardvault`, `agent-kusari`, `agent-nono-evidenced`, `agent-sir-lancelot` and every other pod in `fe-signalloom-agents`. Adding the annotation now does not re-freeze anything; it only stops a future thaw.

There is also a **key-type mismatch**: `isPodStunned` reads `signalloom.io/stunned` from pod **labels**, not annotations. An annotation on the Deployment, as F.4 literally says, would not be honoured by the running reconciler. The gate needs a ruling on whether the intent is the pod label (what the code reads) or the annotation (what F.4 says). The preflight checks the annotation, as specified, and records the pod label next to it.

`agent-sir-lancelot` is a bare Pod (declared `kind: Pod` in `d2-osramp-fleet/tenants/local/signalloom.yaml:680`), so `deploy/agent-sir-lancelot` named in F.4 does not exist. The preflight falls back to the Pod.

### PF-2 - no registration job; `fleet-manager` has no SVID

The F.4 remediation, "re-run `job/spire-register-entries`", has nothing to re-run: no manifest by that name exists in the repo or the cluster. The only related jobs are `spire-agent-swarm-entries-setup` (28 days old) and `openbao-spire-bootstrap`. Nothing registers `fleet-manager` on either SPIRE server, so any fleet-manager path that needs a SPIFFE JWT-SVID (Shared Pattern 5) cannot authenticate.

### PF-5 - two of four freeze paths are not phase-gated

| Freeze path | File | Gated on `PodRunning`? |
| :--- | :--- | :--- |
| Legacy owner-record reconciler (**the deployed build**) | `signalloom-stun-sentinel/main.go` `reconcile` | **No.** It skips only `Succeeded`/`Failed`, so a stunned replacement pod in `Pending`/`ContainerCreating` is frozen (W6 D3b) |
| New sentinel pre-freeze filter | `stun-sentinel/pkg/filter/exclusion.go` `CheckFreezable` | Yes |
| New sentinel eBPF correlator | `stun-sentinel/pkg/correlator/ebpf_correlator.go` | Yes: `CheckFreezable` precedes `FreezePod` |
| New sentinel HTTP `/stun` | `stun-sentinel/cmd/stun-sentinel/main.go` `exclusionGate` | **Fail-open.** `if phase != ""`: a caller that omits `phase` is frozen without a phase check |

The F.4 target `stun-sentinel/reconciler.go` does not exist. The proposal's P1-2 errata ("Owner-Record phase gating (PF-5)") refers to the correlator path only.

### PF-6

`test/swarm-fleet-acceptance.bats` still asserts DaemonSet `signalloom-stun-sentinel` at lines 27, 76 and 81. The live DaemonSet is `stun-sentinel`, so the suite fails against the cluster it is meant to accept.

### AUX-RBAC - in-sentinel detection is blind

The sentinel's pod informer is denied `list pods` (`pods is forbidden`), so its pod index is empty. Step 4 of P5-1 (In-Sentinel Detect → Freeze) cannot resolve a cgroup to a pod.

### AUX-ACT - the Provoke step has no API

P5-1 step 3 and the card's "failure modes" rely on `POST /act`, `/act/read-passwd`, `/act/cpu-burn` and `/act/healthz` returning `{"status":"ready"}`. None of these routes exist. Two further facts:

- The stub is distroless (`gcr.io/distroless/static-debian12:nonroot`), so the card's own probe, `kubectl exec … -- curl`, cannot run (`exec: "curl": executable file not found`). The preflight uses the API-server pod proxy instead.
- `/healthz` returns `{"status":"ok"}`, not `{"status":"ready"}`.

The only built-in hostile action is the stub writing `/tmp/hostile-test.txt` on every 5th `/quote`.

## What must change before P5-1 / P5-2 (recommendations, not applied)

| # | Blocker | Owner decision / fix |
| :--- | :--- | :--- |
| B1 | PF-1 label-vs-annotation, already-thawed swarm | Rule on key type; decide whether the three agents should be frozen at all now; bare-Pod `agent-sir-lancelot` needs its own entry |
| B2 | PF-2 | Author a `spire-register-entries` Job (stun-sentinel **and** fleet-manager, both trust domains) and retire the legacy `inf-bao` entry |
| B3 | PF-5 | Gate the legacy reconciler's freeze on `PodRunning` (or replace the deployed build with `apps/stun-sentinel`); make the HTTP gate fail closed when `phase` is absent; correct the F.4 file reference |
| B4 | PF-6 | Replace the three `signalloom-stun-sentinel` references in `test/swarm-fleet-acceptance.bats` |
| B5 | AUX-RBAC | Restore a ClusterRole/Binding granting `stun-sentinel` `get/list/watch pods` |
| B6 | AUX-ACT | Implement `/act/healthz`, `/act/read-passwd`, `/act/cpu-burn` in `kusari-agent`, rebuild, `kind load docker-image kusari-agent:local --name osramp` |

## Baseline

`make test-all-offline` was run on the unmodified base (full detail in `ci-evidence/p5-baseline-summary.txt`). **The base is not green, and none of the red is caused by this card**, which adds only scripts, tests and docs.

- **Environmental.** This worktree's `dashboard-signalloom/node_modules` is a runtime symlink into the principal checkout, so `bun install --frozen-lockfile` fails with EEXIST. It was shimmed to a no-op rather than allowed to write into the shared tree. With installs shimmed, stages 1 (Go) and 2 (Vitest) pass.
- **Stage 3 Python: 23 failed / 2289 passed.** The security-relevant cluster is `test_eap_default_deny`. Anonymous `GET /api/telemetry/agents[/{pod_name}]` and `/api/v1/telemetry/agents[/{pod_name}]` answer **200, not 401**. These are the P4-1 cAdvisor routes in `fe-signalloom/src/cadvisor_poller.py:319-379`, and they breach Shared Pattern 5. The remaining failures are tenant-isolation sweep, audit provenance and vocabulary, API-compat and connectors.
- **Stages 4-5: 33 of 39 commands pass.**
  - `test-kpai` 74/76, which was already red at P4-GOV.
  - `bats-registry-coverage`: p1/p2/p3 preflight suites were already unregistered; the frozen `vm-pipeline.sh` is not edited here.
  - `demo-signalloom-test-config`: the same registry guard, plus ROUTELIVE and FLEET-LIVE checks that probe a running portal.
  - `test-deployed-staleness` / `supercred-images-test`: the untracked-artefact fingerprint check.
  - `test-count-floor`: timed out after 900 s.

## Evidence

- `ci-evidence/p5-preflight-audit.json`: machine-readable gate results (schema `sldc-p5-preflight/v1`)
- `ci-evidence/p5-preflight-transcript.txt`: gate transcript
- `ci-evidence/p5-kusari-act-probe.txt`: stub probe log
- `ci-evidence/p5-forensic-staging.txt`: forensic directory check
