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

## Governor partial-integration pass errata

<!-- machine-tag: SIGNALLOOM-P3-PARTIAL-INTEGRATION-PASS-2026-07-26T08:03:00+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: committed-input-recovery-and-static-tests-only -->

The Governor recovered and verified four signed, committed Phase 3 inputs in
the dedicated Governor worktree. P3-1 is `dbe6d31c78a2ed23ddcde88e6b7cc5b2310b7dad`,
P3-2 is `5cc782c94853e85dda2b1ac144536f07861a6904`, P3-3 is
`586668fadf038553624aa135b05ddbd53225ff27` (located through the
`refs/kanban/checkpoints/Yjc5N2M/turn/2` task:b797c evidence ref), and P3-4 is
`bf78420f451cac83cfe73a71844191032c2cc49e`. All four signatures verified
against the repository's trusted signing key.

Each input was merged with `--no-ff` into
`integration/signalloom-d2-v2.0.0`. The P3-3 merge required conflict
resolution only to retain both independent documentation errata sections;
its implementation and test changes were accepted unchanged.

Strict repository validation passed after integration:

- `make signalloom-check`
- `make demo-signalloom-test-config` (12/12)
- `make test-demo-lifecycle` (4/4)
- `bats test/signalloom-flux-integration.bats` (3/3)
- `make test-zot-cache` (3/3)
- `make test-bao-spire-proof-harness` (5/5)
- `make -C d2-signalloom bao-test-config`
- `make -C d2-signalloom test` (12/12)
- `bash -n scripts/bao-spire-proof.sh`
- `git diff --check`

This is a partial integration pass only. It does not approve Phase 3, does
not claim P3-5 runtime proof, and does not convert static or fake-boundary
results into live Kind, Bao/SPIRE, Flux, portal, or hosted evidence. P3-5
must be recreated from the resulting clean integration HEAD.

## Governor verification rerun

<!-- machine-tag: SIGNALLOOM-P3-PARTIAL-INTEGRATION-STRICT-RERUN-2026-07-26T08:29:41+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- integration-sha: e21a9e559107e0f335651e69d2be598c245c08eb -->
<!-- scope: verification-rerun-only -->

The dedicated Governor worktree was clean at `e21a9e559107e0f335651e69d2be598c245c08eb`.
The four qualified inputs remained reachable, signed by the trusted repository
key, and present through the existing no-ff merge commits. Strict validation was
rerun successfully: `make signalloom-check`, `make demo-signalloom-test-config`
(12/12), `make test-demo-lifecycle` (4/4), `bats
test/signalloom-flux-integration.bats` (3/3), `make test-zot-cache` (3/3),
`make test-bao-spire-proof-harness` (5/5), `make -C d2-signalloom
bao-test-config`, `make -C d2-signalloom test` (12/12), `bash -n
scripts/bao-spire-proof.sh`, and `git diff --check`.

This remains a partial integration verification only. It does not approve Phase
3 or claim P3-5 runtime proof; P3-5 must be recreated from this clean
integration SHA.
