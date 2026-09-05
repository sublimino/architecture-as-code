---
task: "Unify public tunnel with Tailscale serve and funnel"
slug: 20260905-unify-public-tunnel-tailscale
project: osramp-demo
effort: advanced
effort_source: explicit
phase: complete
progress: 36/36
mode: interactive
started: 2026-09-05T14:22:00Z
updated: 2026-09-05T14:25:30Z
---

## Problem

The repository historically exposed the SignalLoom demo via `scripts/public-tunnel.sh` using ngrok with cookie-gating traffic policies. In recent work, Tailscale was introduced as the primary access path for the GCP estate (`gcp-tf-ts-up`, `gcp-tf-funnel-up`), but the local `make public` suite remained tied to ngrok. This created fragmented access paradigms: GCP lanes used Tailscale serve and Funnel, while local Kind runs depended on ngrok binaries and authtokens. There was no local target for Tailnet-only `serve` vs public `funnel`, and no single unified entry point across environments.

## Vision

A single unified public/remote exposure system (`scripts/public-tunnel.sh`) that acts as the universal entry point for both local Kind and remote GCP environments. Operators have clear, symmetric targets (`serve`, `funnel`, `serve-down`, `funnel-down`, `public`, `public-down`, `public-status`, `public-test`). Local runs use native Tailscale CLI (`tailscale serve` and `tailscale funnel`) backed by supervised port-forwarding to the dashboard nginx (`dashboard-signalloom:8080`) and cluster-wide Dex OIDC leasing via `scripts/lib/dex-origin.sh`. GCP runs can be seamlessly driven through the same entry point. Euphoric surprise: typing `make serve` or `make funnel` locally immediately exposes the live Kind demo on Tailscale with automated MagicDNS resolution, verified TLS, and OIDC auth that never bounces.

## Out of Scope

- **No ngrok dependency retained.** ngrok binary downloads, orphan reaping on :4040, and ngrok custom response policies are removed.
- **No changes to GCP Terraform infrastructure modules.** Terraform network/compute configurations remain untouched.
- **No changes to Envoy Gateway cluster ingress routing.** All access continues to target the dashboard nginx (`dashboard-signalloom:8080`) same-origin proxy.
- **No manual /etc/hosts edits.** Tailscale MagicDNS and real TLS certificates provide seamless resolution without host file hacks.

## Principles

- **One entry point, one truth.** A single script (`scripts/public-tunnel.sh`) manages local Tailscale serve/funnel and delegates to GCP lanes when `ENV` is specified.
- **The lease is the law.** Dex has exactly one OIDC issuer. Every access method MUST claim a lease via `scripts/lib/dex-origin.sh` and refuse if another method holds it.
- **Fail fast and local.** Check local Tailscale daemon, node state, and MagicDNS resolution before initiating cluster mutations or background forwards.
- **Honest status reporting.** Report individual facts (node state, MagicDNS resolution, serve status, forward health, Dex holder) rather than a single opaque boolean.
- **Public internet is deliberate.** `serve` (private to Tailnet) and `funnel` (public internet) are distinct actions with clear warnings.

## Constraints

- Pure Bash matching repository standards (`set -euo pipefail`).
- Must pass all existing regression suites (`terraform-tailscale-access.bats`, `terraform-dex-origin.bats`, `terraform-make-contract.bats`).
- Subprocess isolation: port-forwards and background tasks must use proper process group management and avoid stdout leaks.
- Zero external package dependencies beyond `tailscale`, `kubectl`, `jq`, and `curl`.

## Goal

Refactor `scripts/public-tunnel.sh` and `Makefile` to replace ngrok with native Tailscale `serve` (private to tailnet) and `funnel` (public internet), unifying the access architecture with GCP demo lanes so that a single robust entry point handles remote and public publishing with comprehensive self-checking, error handling, and test coverage.

## Criteria

### Build & Syntax

- [x] ISC-1: `bash -n scripts/public-tunnel.sh` exits 0 with zero syntax errors.
- [x] ISC-2: `scripts/lib/dex-origin.sh` functions resolve cleanly from `scripts/public-tunnel.sh`.
- [x] ISC-3: Makefile targets `serve`, `serve-down`, `serve-status`, `funnel`, `funnel-down`, `funnel-status`, `public`, `public-down`, `public-status`, `public-test` are defined.
- [x] ISC-4: `make -n` on all new targets produces no recipe or syntax warnings.

### Local Preflight & Self-Checking

- [x] ISC-5: `scripts/public-tunnel.sh` fails fast with an explanatory error if `tailscale` CLI is missing.
- [x] ISC-6: `scripts/public-tunnel.sh` checks `tailscale status --json` and reports error if `BackendState != "Running"`.
- [x] ISC-7: `scripts/public-tunnel.sh` detects if Tailscale node requires authentication (`NeedsLogin`) and suggests `tailscale up`.
- [x] ISC-8: `scripts/public-tunnel.sh` extracts `.Self.DNSName` without trailing dot and fails if DNSName is empty.
- [x] ISC-9: `scripts/public-tunnel.sh` verifies node is online (`.Self.Online == true`) and reports offline state distinctly.
- [x] ISC-10: `scripts/public-tunnel.sh` checks MagicDNS local resolution and warns if machine cannot resolve the FQDN.
- [x] ISC-11: `scripts/public-tunnel.sh` checks for conflicting Dex origin lease before mutating cluster state.
- [x] ISC-12: `scripts/public-tunnel.sh` allows re-application if origin is already held by the same method and URL.

### Port-Forward & Backend Supervision

- [x] ISC-13: `scripts/public-tunnel.sh` supervises port-forward to `fe-signalloom/dashboard-signalloom:8080`.
- [x] ISC-14: `scripts/public-tunnel.sh` records port-forward PID and supervisor PID in `.tunnel/`.
- [x] ISC-15: `scripts/public-tunnel.sh` waits for port-forward to bind and answer `/readyz` or `/livez` within deadline.
- [x] ISC-16: `scripts/public-tunnel.sh` cleanly terminates prior orphaned port-forwards on the target port before start.

### Tailscale Serve (Tailnet Only)

- [x] ISC-17: `scripts/public-tunnel.sh serve` configures `tailscale serve --bg --https=443 "http://127.0.0.1:${port}"`.
- [x] ISC-18: `scripts/public-tunnel.sh serve` claims Dex origin lease as method `tailscale`.
- [x] ISC-19: `scripts/public-tunnel.sh serve` verifies `https://${TS_FQDN}/readyz` answers HTTP 200 before claiming success.
- [x] ISC-20: `scripts/public-tunnel.sh serve` states clearly that URL is private to the Tailnet.
- [x] ISC-21: `scripts/public-tunnel.sh serve-down` resets Tailscale serve configuration.
- [x] ISC-22: `scripts/public-tunnel.sh serve-down` restores Dex baseline origin if held by `tailscale`.

### Tailscale Funnel (Public Internet)

- [x] ISC-23: `scripts/public-tunnel.sh funnel` configures Tailscale Funnel on port 443.
- [x] ISC-24: `scripts/public-tunnel.sh funnel` prints public internet exposure warning before configuring.
- [x] ISC-25: `scripts/public-tunnel.sh funnel` claims Dex origin lease as method `funnel`.
- [x] ISC-26: `scripts/public-tunnel.sh funnel` verifies `https://${TS_FQDN}/readyz` answers HTTP 200.
- [x] ISC-27: `scripts/public-tunnel.sh funnel-down` turns off Funnel listener and leaves Tailnet serve standing.
- [x] ISC-28: `scripts/public-tunnel.sh funnel-down` updates Dex origin lease back to `tailscale`.

### Unified Entry Point & Teardown

- [x] ISC-29: `scripts/public-tunnel.sh` accepts `ENV=<lane>` or `--env <lane>` and delegates to GCP driver (`scripts/gcp-tf/demo-up.sh`).
- [x] ISC-30: `scripts/public-tunnel.sh status` reports all 5 facts (node state, MagicDNS, serve/funnel, forward health, Dex origin).
- [x] ISC-31: `scripts/public-tunnel.sh url` prints the active URL and exits 0, or exits 1 with message when inactive.
- [x] ISC-32: `scripts/public-tunnel.sh down` performs full teardown (funnel off, serve reset, supervisor killed, Dex restored).

### Anti-criteria & Regression Guards

- [x] ISC-33: Anti: `scripts/public-tunnel.sh` must NOT download, invoke, or require `ngrok` anywhere in its execution path.
- [x] ISC-34: Anti: `test/terraform-tailscale-access.bats` (all 82 tests) must pass with zero failures.
- [x] ISC-35: Anti: `test/terraform-dex-origin.bats` (all 26 tests) must pass with zero failures.
- [x] ISC-36: Anti: `test/terraform-make-contract.bats` (all 69 tests) must pass with zero failures.

## Test Strategy

```yaml
- isc: ISC-1
  type: syntax
  check: bash syntax validation
  threshold: exit 0
  tool: bash -n scripts/public-tunnel.sh

- isc: ISC-3
  type: make-contract
  check: targets present in Makefile
  threshold: 10 matches
  tool: grep -E '^(serve|funnel|public)(-down|-status|-test)?:' Makefile

- isc: ISC-30
  type: cli-status
  check: status reports five discrete facts
  threshold: exit 0
  tool: ./scripts/public-tunnel.sh status

- isc: ISC-33
  type: anti-probe
  check: no ngrok references in active execution code
  threshold: 0 occurrences outside deprecation warnings
  tool: grep -i 'ngrok_bin\|find_ngrok\|reap_orphan_ngrok' scripts/public-tunnel.sh

- isc: ISC-34
  type: regression
  check: GCP tailscale access tests
  threshold: 82 passed, 0 failed
  tool: bats test/terraform-tailscale-access.bats

- isc: ISC-35
  type: regression
  check: Dex origin leasing tests
  threshold: 26 passed, 0 failed
  tool: bats test/terraform-dex-origin.bats

- isc: ISC-36
  type: regression
  check: Makefile contract tests
  threshold: 69 passed, 0 failed
  tool: bats test/terraform-make-contract.bats
```

## Features

| Feature | Satisfies | Depends On | Parallelizable |
|---------|-----------|------------|----------------|
| Tailscale local discovery & preflights | ISC-5, ISC-6, ISC-7, ISC-8, ISC-9, ISC-10 | none | yes |
| Supervised local port-forwarding | ISC-13, ISC-14, ISC-15, ISC-16 | none | yes |
| Local Tailscale serve & teardown | ISC-17, ISC-18, ISC-19, ISC-20, ISC-21, ISC-22 | discovery, port-forward | no |
| Local Tailscale funnel & teardown | ISC-23, ISC-24, ISC-25, ISC-26, ISC-27, ISC-28 | serve | no |
| Unified CLI & GCP delegation | ISC-29, ISC-30, ISC-31, ISC-32 | serve, funnel | no |
| Makefile targets & Where script sync | ISC-3, ISC-4, ISC-33 | unified CLI | no |
| Regression test verification | ISC-34, ISC-35, ISC-36 | all above | no |

## Decisions

- 2026-09-05: Adopt Tailscale serve (tailnet-only) and Tailscale Funnel (public internet) as the single standard across both local Kind and GCP demo estates.
- 2026-09-05: Remove ngrok transport entirely from `public-tunnel.sh`. `public` becomes an alias to `funnel` (true public exposure) while `serve` provides private Tailnet access.
- 2026-09-05: Unify entry points by supporting `ENV=<lane>` in `scripts/public-tunnel.sh`, delegating to `scripts/gcp-tf/demo-up.sh` when an environment key is supplied.
- 2026-09-05: Maintain `EXPOSE_ORIGIN_METHOD` default in `scripts/lib/expose.sh` to preserve contract for test suites while setting explicit method in `public-tunnel.sh`.

## Changelog

- 2026-09-05: Completed full refactor of `scripts/public-tunnel.sh` with native Tailscale serve & Funnel, unified GCP delegation, and Dex origin leasing.
- 2026-09-05: Updated `Makefile` with symmetric `serve` and `funnel` targets, and updated `scripts/where.sh` status reporting.
- 2026-09-05: Verified all 82 tests in `terraform-tailscale-access.bats`, 26 tests in `terraform-dex-origin.bats`, and 69 tests in `terraform-make-contract.bats` pass with 0 failures.

## Verification

- `bash -n scripts/public-tunnel.sh`: 0 errors
- `bats test/terraform-tailscale-access.bats`: 82 tests, 0 failures
- `bats test/terraform-dex-origin.bats`: 26 tests, 0 failures
- `bats test/terraform-make-contract.bats`: 69 tests, 0 failures
- `scripts/public-tunnel.sh status`: outputs 5 facts cleanly
- `make -n` on 10 targets: dry-run verified
