# SLED-P3-GOV multi-stage hygiene audit log

Date: 2026-09-22, America/Chicago. Status: **fail / not certified**.
Audited implementation: `150404e06c2653f070b1c1e529d634df1f987668`;
documentation-only integration: `624c6057bb469ee07c246faf78533fd7ef4cc7a5`.

## Governance observations

- Board progress: 15 done, one in progress (P3-GOV), one backlog (P4-GOV).
- Doctor: seven zero-output done cards; oscillation findings for P2-GOV/P4-GOV.
- The real proposal, read through `obsidian-read`, records P2-GOV as fail.
- P3-2 helper card (`82535`): done, session unknown, workspacePath null, errata
  null, ledger null. A done label is not proof of delivery.
- P3-PRE was merged under the canonical SHA-256(repository identity) mutation
  lock. Its historical base is an ancestor of integration. P3-1 remains preserved
  as a local commit and was not merged or executed against live resources.

Recovery feasibility was checked without mutation:

```text
kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode SLED remediate --task-id 82535 --proposal '<actual vault proposal path>' --dry-run
kanban-check: remediate: task 82535 (P3-2) is in 'done', not 'review' or 'in_progress' — refusing
REMEDIATION_DRY_RUN_EXIT=1
```

The actual proposal path was `/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (2026-Q3).md`.
This rejects the attempted dry-run operation; it does not prove every recovery
mechanism unavailable. Existing-card restart/recreation still conflicts with
the card's higher-precedence create-only boundary.

## Required test transcript

Working directory:
`/home/andy/src/.worktrees/osramp-demo/sled-v0.1.0/governor/d2-signalloom/apps/fe-signalloom/src`

Command: `pytest tests/test_environment_lifecycle.py -v`

Captured post-merge output (warning path abbreviated; test outcomes unchanged):

```text
platform linux -- Python 3.14.4, pytest-9.1.1, pluggy-1.6.0
plugins: anyio-4.14.2
collected 23 items
test_lifecycle_registration_defaults PASSED
test_lifecycle_state_transitions PASSED
test_heartbeat_lease_extension_and_ceiling PASSED
test_activity_touch_resets_idle PASSED
test_evaluate_reaping_ttl_expiration PASSED
test_evaluate_reaping_idle_timeout PASSED
test_evaluate_reaping_grace_period_to_terminated PASSED
test_evaluate_reaping_empty_registry PASSED
test_evaluate_reaping_fully_active_fleet PASSED
test_evaluate_reaping_large_fleet_sub_millisecond_benchmark PASSED
test_evaluate_reaping_priority_queue_ordering PASSED
test_evaluate_reaping_exception_isolation_and_dlq PASSED
test_adaptive_polling_interval_scheduler PASSED
test_memory_watchdog_rss_monitoring PASSED
test_administrative_pause_and_resume_controls PASSED
test_reaper_daemon_start_stop_graceful_cancellation[asyncio] PASSED
test_concurrent_api_requests_and_reaping_pass PASSED
test_nanosecond_precision_timestamps_and_audit_schema PASSED
test_mass_reaping_alert_notification_dispatch PASSED
test_lock_timeout_handling PASSED
test_rapid_clock_skew_resilience PASSED
test_api_lifecycle_full_flow PASSED
test_api_reaper_admin_and_diagnostic_endpoints PASSED
StarletteDeprecationWarning: Using httpx with starlette.testclient is deprecated
23 passed, 1 warning in 1.12s
REQUIRED_TEST_EXIT=0
```

This is 100% of the named lifecycle suite, **not** 100% of Phase 3 coverage.

## Supplemental gate transcript

Command:
`pytest tests/test_environment_lifecycle.py tests/test_sled_p2_certification.py -q`

```text
async def functions are not natively supported.
You need to install a suitable plugin for your async framework
PytestUnknownMarkWarning: Unknown pytest.mark.asyncio
8 failed, 27 passed, 5 xfailed, 11 warnings in 2.87s
COMBINED_TEST_EXIT=1
```

The eight failures are execution-environment failures for async probes, not eight
newly demonstrated product defects. The existing five expected failures remain
unresolved defect markers. Neither failures nor expected failures are counted as
passing certification evidence. No test was weakened or skipped to produce green.

## Direct, non-destructive defect probes

Using a fresh `LifecycleManager`, register `kurasi`, transition to `DRAINING`,
and evaluate at `grace_period_expires_at + timedelta(seconds=1)`:

```text
termination_probe terminated completed_stages= [] action= terminated
```

This probe changes only a new process-local registry; it creates no Kubernetes,
Tailscale, SPIRE, or OpenBao resource. The result falsifies the claim that current
logical termination is gated on four completed teardown stages.

Pure path probe of `PurePosixPath('/app/environment_teardown.py').parents[4]`:

```text
container_path_probe=IndexError
```

This substantiates the proposed module's path-depth assumption; it is not a
substitute for rebuilding and booting the deployment image.

## Coverage audit

P3-1's proposed `tests/test_environment_teardown.py` exercises a fake kubectl
and mock Tailscale execution (lines 39–112); its live-mode spy (255–265) tests
environment propagation, not actual mesh eviction. Its unreachable-probe test
(209–210) does not reject stage success when the helper returns `None`. Retry
tests accept previously recorded stage skips (322–327), without route-recreation
verification. These are source-review findings; this governor did not run that
unmerged suite. No integrated four-stage fuzz target exists in the audited tree,
so the requested full-pipeline timeout fuzz test is **not run**.

## Mechanical accounting transcript

The exact prescribed operation was attempted with the bundled helper:

```text
kanban-check.sh cost --repo /home/andy/src/cp/osramp-demo --shortcode SLED --proposal '/home/andy/src/cp/osramp-demo/docs/Proposal — Signal Loom EAP Lifecycle, Heartbeat & Auto-Reaping Daemon (2026-Q3).md' --update-table --apply
kanban-check.sh: line 3014: /home/linuxbrew/.linuxbrew/bin/python3: Argument list too long
COST_EXIT=126
```

A read-only retry (`cost --repo /home/andy/src/cp/osramp-demo --shortcode SLED
--json`) failed identically, exit 126. The helper exports board-card data into
the Python child's environment at that location. It produced no Phase Spend and
Token Use table; costs, tokens, elapsed metrics, and AI URIs are **unavailable**,
not zero. No manual estimate replaces mechanical accounting.

The helper's later update implementation directly opens the proposal for writing
(`kanban-check.sh:3597`), which is also incompatible with the required Obsidian
bridge writer. A repaired flow must use a non-vault staging document and apply
verified resulting table changes through the bridge. This audit did not patch
shared tooling or create a new transport.
