# Resilient waits — consolidation guide

How this repo (and others) should wait for distributed-system state: one
deadline-driven primitive library, one source of truth, vendored where needed.

## The problem this replaces

The audit found ~60 hand-rolled waits across the Makefiles, `scripts/`, and bats
suites. Every one was fixed-interval with no jitter and no exponential backoff;
most `kubectl wait` / `rollout status` calls had **no existence check** and so
error instantly on a cold cluster; the 30-second Zot readiness loop was
copy-pasted ~9× verbatim; several "waits" were bare `sleep N` guesses. Under CPU
or memory pressure these don't wait longer — they fail early.

## The fix — one library, five principles

`scripts/lib/wait.sh` (vendored from `~/.andy_sync/includes/wait.sh`) provides
deadline-driven primitives built on five principles:

1. **Deadline, not attempt-count.** "Slow but eventually" is a PASS. Every wait
   is bounded by wall-clock, not a fragile `N × sleep` budget.
2. **Existence before condition.** Poll `kubectl get` until the object exists,
   then `kubectl wait --for=...` within the remaining budget.
3. **Exponential backoff + jitter.** No synchronised thundering-herd retries.
4. **Per-attempt hang fence.** Each attempt runs under `timeout` so one wedged
   curl/kubectl can't block past the deadline.
5. **Readiness, not wall-clock sleeps.** Probe the real endpoint/condition.

### Verbs

| Verb | Replaces |
|------|----------|
| `wait_reachable <url> [deadline]` | the ~9 copies of the 30s Zot curl loop + PF-curl loops |
| `wait_tcp <host> <port> [deadline]` | `nc -z` / `/dev/tcp` sleep loops |
| `wait_k8s_exists <kind> <name> [-n ns] [deadline]` | bare `kubectl get` existence gates |
| `wait_k8s_ready <kind> <name> [-n ns] [--for cond] [deadline]` | unguarded `kubectl wait` (~21 sites) |
| `wait_flux_ready <kind> <name> [-n ns] [deadline]` | Flux Kustomization/ResourceSet readiness |
| `wait_rollout <deploy> [-n ns] [deadline]` | unguarded `kubectl rollout status` (~7 sites) |
| `wait_pods_ready <selector> [-n ns] [deadline]` | DETIK spins / `kwaitpod` hand-rolls |

### The "slow mode" lever

Every deadline is multiplied by `WAIT_DEADLINE_SCALE` (default 1). On a saturated
production box, run the same suite with `WAIT_DEADLINE_SCALE=10` and it passes
patiently instead of failing — no code changes. Per-call tunables:
`WAIT_SLEEP`, `WAIT_BACKOFF`, `WAIT_JITTER`, `WAIT_ATTEMPT_TIMEOUT`, `WAIT_QUIET`.

## Source of truth and vendoring

- **Source of truth:** `~/.andy_sync/includes/wait.sh` (+ `test/functions/wait.bats`).
  This is where edits happen; it is covered by the andy_sync bats suite.
- **The interactive `try-*` suite** (`~/.andy_sync/includes/function-base-2016.sh`)
  now shares the same resilience patterns — per-attempt hang fence
  (`_TRY_LIMIT_ATTEMPT_TIMEOUT`), require-output (`_TRY_LIMIT_REQUIRE_OUTPUT`),
  and jitter (`_TRY_LIMIT_JITTER`). Use `try-backoff` / `try-timeout` at the
  interactive shell; use `wait.sh` verbs in scripts.
- **Vendored copies** live in each repo that needs them, e.g.
  `osramp-demo/scripts/lib/wait.sh`. They are self-contained (no login-shell
  dependency) so they work in Makefiles, bats, CI, and containers. Refresh with
  `make wait-lib-sync` — never hand-edit the vendored copy.

## How to consume it

- **Shell scripts:** `source "$(dirname "$0")/lib/wait.sh"` then call a verb.
  (Done: `scripts/with-zot-portforward.sh`.)
- **Makefiles:** call the converted scripts, or `source scripts/lib/wait.sh` in a
  recipe and call a verb.
- **bats tests:** `source "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh"` in
  `setup_file`, and replace port-forward-then-curl loops with `wait_reachable`,
  DETIK `verify` races with `wait_pods_ready`, and the three diverged `try-limit`
  copies with the shared engine.

## Migration order (incremental — each step independently testable)

1. **Zot readiness (highest duplication):** convert `with-zot-portforward.sh`
   (done), then `push-local*.sh`, `build-sign-dashboard.sh`, the two Makefile
   `*-images` loops, `admission/vex/revocation-demo.sh`.
2. **Unguarded `kubectl wait` / `rollout status`:** `healthcheck.sh`,
   `demo-lifecycle.sh`, `signalloom-local.sh`, `signalloom-runtime-test.sh`,
   fleet `Makefile`, `cpai-up.sh` → `wait_k8s_ready` / `wait_rollout`.
3. **Namespace/Kustomization pollers:** the triplicated loops in
   `osramp-up.sh` / `olly-up.sh` / `signalloom-up.sh` → `wait_flux_ready`.
4. **bats:** point the three `try-limit` copies and DETIK loops at the shared
   engine; replace the PF-curl and bare-`sleep` gates with `wait_*`.

`wait-reconciled.sh` already embodies principle 2 and can stay, or be reduced to
`wait_flux_ready` calls in a loop.
