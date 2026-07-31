# elk_search_logs MCP server (built: `apps/cmd/elk-search-mcp`)

The first read-only MCP tool of the replica, scope `elk.logs.read`. In the
client estate the agent fans out to seven read-only MCP tools; this proves
the pattern and the remaining tools follow the same one-scope-per-tool
shape.

Controls, enforced in the server and proven by `test/olly.bats` and the
in-build unit tests:

- **Scoped key only**: the pod's init container uses the elastic credential
  once to mint a 7-day API key restricted to `app-logs-*`, `infra-logs-*`,
  `audit-logs-*` (`read` + `view_index_metadata`), handed over on an
  in-memory volume. The server process never sees the superuser credential.
- **Pattern allowlist**: any other index pattern gets a 403 (the suite
  asserts this negatively).
- **Query caps**: `MAX_DOCS` (100) and `MAX_RANGE_MINUTES` (1440) enforced
  server-side regardless of what the caller asks for.
- Queries are keyed by correlation-ID/app_id, never by INC number.
- Every query emits an AUDIT log line (the SIEM-trail stand-in).
- Results are returned as structured fields (timestamp, app, level,
  message): data, never instructions.

API: `POST /tools/elk_search_logs` with
`{"index_pattern", "query", "size?", "time_range_minutes?"}`.

Ships as `olly/elk-mcp` (persisted in the in-cluster Zot registry as
`zot.registry.svc.cluster.local:5000/acme/images/olly/elk-mcp:latest`) via
`make -C olly-replica build`; the image build runs the contracts round-trip
tests, so contract drift fails the build.
