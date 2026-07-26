# Phase 3 hardening test errata

<!-- machine-tag: SIGNALLOOM-P3-HARDENING-TESTS-2026-07-26T06:30:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: local-fixture-and-harness-only -->

This repository-local errata records the test translation for the Phase 3
bounded Bao/SPIRE identity design. It does not modify `board.json`, the
Obsidian proposal (`docs/plans/d2-bao-integration.md`), another worktree, a
Kind cluster, or any external system.

| Trace ID | Contract | Harness assertion | Intended regression outcome |
| --- | --- | --- | --- |
| `P3-IDENTITY-ACCEPT-001` | Authorised job completes and logs its success marker. | Fake `kubectl` returns Complete and `bounded Bao/SPIRE proof passed`. | Pass. |
| `P3-IDENTITY-NEG-001` | Unauthorised service account must not complete. | Fake negative job reports Complete. | Fail: `negative Bao/SPIRE identity unexpectedly succeeded`. |
| `P3-IDENTITY-NEG-002` | Unauthorised job must enter Failed. | Fake negative job never reaches Failed. | Fail. |
| `P3-IDENTITY-EVIDENCE-001` | Positive completion needs a proof marker. | Fake positive logs omit its marker. | Fail: missing positive marker. |
| `P3-IDENTITY-EVIDENCE-002` | Negative failure needs a denial marker. | Fake negative logs omit its marker. | Fail: missing denial marker. |

Run the deterministic evidence suite with:

```sh
env LC_ALL=C LANG=C make test-bao-spire-proof-harness
```

The suite deliberately replaces only `kubectl` through a temporary `PATH`; it
does not create, reconcile, delete, or query a real cluster. Consequently it
qualifies the control-flow assertions only. Real Kind acceptance remains
blocked until the existing Bao/Flux readiness blockers are repaired; it must
then be run separately against a disposable local cluster.

## Local evidence

<!-- machine-tag: SIGNALLOOM-P3-HARDENING-EVIDENCE-2026-07-26T06:31:00+01:00 -->

The following commands ran from the Kanban runtime worktree and exited zero:

```text
env LC_ALL=C LANG=C make test-bao-spire-proof-harness
# 1..5: expected acceptance plus four deliberately violated outcomes detected
env LC_ALL=C LANG=C make -C d2-signalloom bao-test-config
env LC_ALL=C LANG=C make -C d2-signalloom test
# 1..9 existing deterministic static assertions
bash -n scripts/bao-spire-proof.sh
```

`test/bao-spire-proof.bats` is the durable fixture artifact: every negative
case changes exactly one fake-kubectl outcome, asserts non-zero exit status,
and, where the production script emits a diagnostic, asserts that diagnostic.
No runtime readiness, network-policy enforcement, or application request is
claimed by this local harness.
