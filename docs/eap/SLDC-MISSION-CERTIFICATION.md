# SLDC Mission Certification - SLDC-P5-GOV

**Verdict: NOT CERTIFIED (`status=fail`).** The Kusari EAP mission is not ready for production pilot delivery. This document records why, with evidence, and the sign-off blocks stay unsigned until a green certificate exists.

- **Candidate merge:** `governor/sldc-p5-gov-candidate` @ `5b61552d9a9013f806c3d2b93432fb24734a8ac8`. It holds `feat/sldc-p5-1` (`aed71e97`) and `feat/sldc-p5-2` (`5664f7bd`), merged `--no-ff --no-gpg-sign` on `integration/sldc-v0.1.0` @ `c75d26235974cfecde89ed856f653e70c83b7b90`.
- **Integration branch not advanced.** The merge boundary makes merging conditional on three green runs, and none was achieved.
- **Date:** 2026-09-30

## 1. Gate results

| Gate | Command | Result |
| :--- | :------ | :----- |
| Merge | `git merge --no-commit --no-ff feat/sldc-p5-1 feat/sldc-p5-2` | **PASS**: clean, 0 conflicts |
| Hermetic P5 suites | `bats test/evidence-bundle-integrity.bats`; `bash test/e2e-mutation-proof.sh` | **PASS**: 37/37; 21/21 mutations |
| 3 consecutive live runs | `scripts/final-governor-certification.sh` | **FAIL**: run 1 red, 2 passed / 3 failed / 0 skipped, 180 s |
| Reproducibility | two earlier independent live runs, same tree | **FAIL, identically**: Steps 2, 4, 5 red each time |
| Forensic bundle | `scripts/package-eap-evidence.sh <live run>` | **REFUSED**: 5 contract violations (step2/4/5 artifacts absent) |
| Global invariants | H1, GitOps suppression, `4b53ab6b`, eBPF streaming | **UNCONFIRMED**: Steps 4-5 never reached a freeze |
| Shared Pattern 5 (anon → 401) | `pytest src/tests/test_eap_default_deny.py` | **FAIL**: 7 inventory guards red, telemetry routes mounted without `authenticated_principal` |
| Flaky-run rejection (mutation) | `bats test/final-mission-governor.bats` | **PASS**: 8/8; run-2 failure halts, run 3 never executes |
| Human sign-off | four approvers | **NOT OBTAINED** |

The failure is persistent, not flaky. Three runs across about 11 minutes failed at the same three steps with the same cause. That makes it a card hard blocker ("persistent non-reproducibility"), not a teardown or timing problem.

## 2. Step-by-step (live, `kind-osramp` + `kind-signalloom-hub`)

| Step | Result | Cause |
| :--- | :----- | :---- |
| 1 Deploy (Flux) | ok | - |
| 2 Tenant claim (`kusari` / `4b53ab6b`) | **not ok** | No registry claim row for the tenant. P5-PRE B1 / autoclaim binding is unresolved. |
| 3 Provoke `/act/read-passwd` | ok | P5-1 delivered the `/act/*` routes (B6 closed) |
| 4 In-sentinel eBPF detect | **not ok** | The `stun-sentinel` ServiceAccount cannot list pods (`kubectl auth can-i` → `no`). The correlator's pod index is empty, so `openat` events never resolve to the pod (P5-PRE B5). |
| 5 Freeze / 0 mCPU / reconcile disabled / 0 restarts | **not ok** | Depends on Step 4; no freeze is ever issued |

Residual state after all runs: `agent-kusari` is Running with 0 restarts and no `kustomize.toolkit.fluxcd.io/reconcile` annotation. No cgroup was frozen by these runs.

## 3. KPI compliance

| KPI (proposal) | Target | Measured |
| :------------- | :----- | :------- |
| Containment latency | < 50 ms | **not measurable**: no containment occurred |
| Container restarts | 0 | 0 (the pod was never frozen, so this is vacuous) |
| `reconcile_failed` errors | 0 | not asserted: Step 5 not reached |
| CPU flatline | 0.000 mCPU | **not measurable** |

No KPI is claimed. A restart count of 0 on a pod that was never frozen proves nothing about H1.

## 4. Blockers to clear before re-running this gate

These are feature, RBAC or cluster changes owned by implementation cards or by Andy. They are outside this card's scope ("writing feature or test implementation code directly").

1. **B5**: grant `stun-sentinel` pods get/list/watch. Without it, Step 4 cannot pass.
2. **B1 / autoclaim**: bind the `kusari` tenant claim so Step 2 finds its row (proposal Appendix K1).
3. **B7 (security, Shared Pattern 5)**: put `/api[/v1]/telemetry/agents[/{pod}]` behind `authenticated_principal`. This is an anonymous read bypass and a card hard blocker on its own.
4. **B2 / B3 / B4**: SPIRE entries Job, the legacy reconciler `PodRunning` gate and HTTP gate fail-closed, and the names in `swarm-fleet-acceptance.bats`. Note that deploying the new sentinel thaws the three deliberately frozen demo agents unless their owners are annotated first.
5. P5-2 contract collision: P5-1 writes `preflight-manifest.json.txt`; the packager requires `preflight-manifest.json`.

Re-run: `scripts/final-governor-certification.sh`. Exit 0 is impossible without sign-off (§6). The gate reaches `awaiting-signoff` only after 3 green runs and a verified bundle.

## 5. Evidence checksums

| File | sha256 |
| :--- | :----- |
| `ci-evidence/final-mission-certification.json` | see commit, since the file is regenerated per run |
| `ci-evidence/final-e2e-consecutive-runs.log` | `c7caf9d6a89e01f7fbaf8a82074f3b45b764dcebb817dacc3562f2a52f1fc821` |
| `ci-evidence/final-bundle-audit.txt` | `3ab0f3e33fb13f9281e53fb1c20c946d97194cd364ee44c339b3d50d8a7fc6cf` |
| Certificate digest (`runs + bundle + head`) | `0e2e8ce7c808d654ee65cbe96dda3599ee62f64c2f6710606edbfbbdf600f785` |
| `ci-evidence/kusari-eap-certified-bundle.tar.gz` | **not produced**: no green run to package |

Per-run artifacts: `ci-evidence/final-e2e-runs/run-1/`, `prior-run-{1,2}.tap`.

## 6. Multi-party sign-off

Sign-off happens only against a certificate with `status=awaiting-signoff`. Each approver signs the digest file with their own key:

```bash
ssh-keygen -Y sign -f ~/.ssh/id_ed25519 -n sldc-mission-cert < ci-evidence/final-mission-certification.digest > <name>.sig
scripts/final-governor-certification.sh --signoff signoff.json   # verifies every signature with ssh-keygen -Y verify
```

No agent may fill these blocks. The current certificate is `status=fail`, so the gate refuses sign-off (tested: "a red certificate cannot be signed into a pass").

| Approver | Role | Decision | Key fingerprint | Signature file | Date |
| :------- | :--- | :------- | :-------------- | :------------- | :--- |
| Andrew Martin | CTO | _unsigned_ | | | |
| John Kjell | Principal Security Consultant | _unsigned_ | | | |
| Francesco Beltramini | Specialist Solutions Architect | _unsigned_ | | | |
| Wendy Overton | _(role to confirm)_ | _unsigned_ | | | |
