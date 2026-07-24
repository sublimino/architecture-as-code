# Contracts

Versioned JSON Schemas for every payload that crosses a boundary in the Olly
Sentinel replica (design doc §1.3 and §5). The stubs, the
MCP server, the agent, and the eval harness all import these; drift between
a producer and a consumer fails CI rather than surfacing at demo time.

| Schema | Boundary it pins |
| --- | --- |
| `eligible-event.v1.schema.json` | What Olly consumes from the NOI Event Queue (`netcool.io.events`) and the IO-Declined topic. Keyed by correlation-ID (never an INC number). A message that does not validate is dropped and counted, never forwarded (the spoofed-event control from the threat model). |
| `rca-enrichment.v1.schema.json` | The enrichment payload Olly publishes to the Kafka response topic; the IO Mapping Service consumes it and updates the ServiceNow ticket under its own identity. Olly does not write to ServiceNow directly; Phase 1 is read-only. Evidence entries name the EEMS read-only scope each MCP query ran under. |
| `action-proposal.v1.schema.json` | Later-phase only ("currently no actions will be taken"): the TROUBLESHOOT / REMEDIATE component decision as a closed action enum, never free text. The model proposes, a human approves, a deterministic executor acts. |
| `eval-record.v1.schema.json` | One record per replayed incident from the eval harness: capability timings (sub-15-minute time-to-RCA target), safety verdicts, and the shadow-mode agent-versus-human comparison. Never hand-collected. |
| `dashboard-pane.v1.schema.json` | The Eye in the Sky pane payload: agent lifecycle states (received, in-progress, awaiting-approval + approver, completed, failed) with per-stage timelines, keyed by correlation-ID, provenance-labelled, agent entries visually distinct from human ones. |
| `agent-card.olly-sentinel.v1.json` | The A2A AgentCard, not a schema but a committed instance: the deterministic declaration of the agent's identity, skills, capabilities, and auth requirements (EEMS bearer, read-only scopes). Served verbatim at `/.well-known/agent-card.json` by the sentinel; served == committed is CI-asserted, so agent identity drift fails like payload drift. |

Versioning: schemas are immutable once merged. A breaking change is a new
`v2` file next to the `v1`, consumers migrate explicitly. The `schema_version`
field inside each payload names the version it was produced under.
