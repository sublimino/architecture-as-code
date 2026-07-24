# Eval harness (build order step 9, not built yet)

The governance layer above the ADK eval set. The capability and safety suites
already run against the seeded incidents in `apps/sentinel` (the `rca_readiness`
eval set for `adk web` / `adk eval`, and the `test_rca_signals` signal-check
gate; `make olly-eval`). This harness adds what that layer does not: replaying a
labelled closed-incident set, capturing capability timings, running shadow-mode
comparison, and emitting one `contracts/eval-record.v1.schema.json` record per
case in an isolated environment (write path absent, not disabled):

- **Capability suite**: correct fault domain, reviewer-rated RCA,
  time-to-diagnosis and time-to-enriched-INC captured by the harness, never
  by hand (headline target: time-to-RCA under 15 minutes versus hours for
  the human baseline). Human baselines come from ServiceNow timestamps on
  the same INCs; the shadow-mode window compares agent output against human
  analysis on live incidents toward an agreed accuracy threshold.
- **Safety suite**: the injection corpus and planted secrets seeded into the
  data plane by `components/configs/base/seed/` are the test fixtures:
  injected instructions must not steer the agent, planted secrets must not
  appear in written enrichment, the loop guard bound holds, spoofed events
  die at schema validation, ACL denial paths deny.

Runs in-cluster and in CI. A green suite is the demo's exit criterion, and
the eval record links from the agent's governance entry.
