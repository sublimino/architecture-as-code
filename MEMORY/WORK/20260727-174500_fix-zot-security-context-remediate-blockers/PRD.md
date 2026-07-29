---
task: Fix Zot security context and remediate blockers
slug: 20260727-174500_fix-zot-security-context-remediate-blockers
effort: advanced
phase: complete
progress: 16/24
mode: interactive
started: 2026-07-27T17:45:00+01:00
updated: 2026-07-27T18:00:00+01:00
---

## Context

Andrew requested an immediate surgical repair of the local Zot registry security-context failure, followed by parallel remediation of any independently fixable blockers. The deployment must retain least privilege, preserve the local-only registry boundary, and avoid production, hosted, or destructive changes. Runtime evidence must distinguish a verified local result from static validation.

### Risks

- Changing `runAsNonRoot` or using a privileged init container would mask the host-path defect and weaken the intended security posture.
- Phase 3 evidence gaps cannot be truthfully closed without a real healthy runtime stack and generated candidate artifacts.

## Criteria

- [ ] ISC-1: Zot failure evidence is reproduced or precisely located.
- [ ] ISC-2: Zot manifest ownership settings are documented before modification.
- [ ] ISC-3: Host-path preparation code is inspected for ownership behavior.
- [ ] ISC-4: Init-container user identity matches writable volume ownership.
- [ ] ISC-5: Init-container privilege escalation remains disabled after repair.
- [ ] ISC-6: Init-container Linux capabilities remain fully dropped after repair.
- [ ] ISC-7: Zot application container remains configured non-root after repair.
- [ ] ISC-8: Zot application filesystem remains read-only after repair.
- [ ] ISC-9: Local registry host-path remains scoped to local mode.
- [ ] ISC-10: Zot manifest syntax validates after the targeted change.
- [ ] ISC-11: Existing Zot-focused static tests pass after repair.
- [ ] ISC-12: Local cluster startup creates the cache directory correctly.
- [ ] ISC-13: Runtime Zot pod reaches Ready state when cluster available.
- [ ] ISC-14: Registry endpoint responds successfully when cluster available.
- [ ] ISC-15: Signal Loom images publish after registry readiness.
- [ ] ISC-16: Flux reconciliation is attempted only after image publication.
- [ ] ISC-17: Runtime evidence records unavailable prerequisites without fabrication.
- [ ] ISC-18: Phase-two runtime blocker status is updated with evidence.
- [ ] ISC-19: Same-namespace NetworkPolicy weakness is independently assessed.
- [ ] ISC-20: Supply-chain evidence gaps are independently inventoried.
- [ ] ISC-21: Browser OIDC scope remains deferred unless explicitly implemented.
- [ ] ISC-22: Hosted provisioning remains excluded from local remediation.
- [ ] ISC-23: Independent remediation agents return concrete findings.
- [ ] ISC-24: Next safe remediation step is prioritized with rationale.

## Decisions

- Diagnose the registry failure before changing a non-root security control.
- Retain Zot's non-root pod identity; prepare cache ownership externally before Kind starts.
- Record NetworkPolicy narrowing as deferred follow-up, not an unverified concurrent change.

## Verification

- Zot cache is now UID/GID `65532`, mode `0750`; Zot was restarted and reached Ready.
- `scripts/create-kind-cluster.sh` now prepares ownership and mode inside the Kind control-plane before Zot deploys.
- `env LC_ALL=C LANG=C bats test/zot-cache.bats` passed 3/3.
- `git diff --check` and `bash -n scripts/create-kind-cluster.sh` passed.
- `make demo-signalloom-test-1` passed static, API, fake-integration, Flux, Gateway, probe, and Dex checks.
- TEST-1 remains non-zero because the pre-existing persistence NetworkPolicy negative fails and the shared Gateway/Olly runtime slices are absent; this is logged and not attributed to Zot.
- `docs/signalloom/networkpolicy-remediation-backlog.md` records the bounded NetworkPolicy follow-up.
- CodeReview capability was invoked but roborev is unavailable in this environment.
