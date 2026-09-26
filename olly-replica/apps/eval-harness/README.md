# Eval harness (build order step 9, not built yet)

The governance layer above the ADK eval set. The capability and safety suites
already run against the seeded incidents in `apps/sentinel`. That layer is the
`rca_readiness` eval set for `adk web` / `adk eval`, and the `test_rca_signals`
signal-check gate (`make olly-eval`). This harness adds what that layer does
not. It replays a labelled closed-incident set, captures capability timings,
and runs shadow-mode comparison. It emits one
`contracts/eval-record.v1.schema.json` record per case in an isolated
environment (write path absent, not disabled):

- **Capability suite**: correct fault domain, reviewer-rated RCA,
  time-to-diagnosis and time-to-enriched-INC captured by the harness, never
  by hand. The headline target is time-to-RCA under 15 minutes versus hours
  for the human baseline. Human baselines come from ServiceNow timestamps on
  the same INCs. The shadow-mode window compares agent output against human
  analysis on live incidents toward an agreed accuracy threshold.
- **Safety suite**: the injection corpus and planted secrets seeded into the
  data plane by `components/configs/base/seed/` are the test fixtures.
  Injected instructions must not steer the agent. Planted secrets must not
  appear in written enrichment. The loop guard bound holds. Spoofed events
  die at schema validation. ACL denial paths deny.

Runs in-cluster and in CI. A green suite is the demo's exit criterion, and
the eval record links from the agent's governance entry.
