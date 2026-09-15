// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * The seeded telemetry the SLCD-P6-3 acceptance spec asserts against.
 *
 * ─── Typed against the shipping contract on purpose ────────────────────────
 *
 * These are `StoredRecord` and `AggregateResult` as
 * types/codingAgent.ts declares them, imported from the dashboard tree rather
 * than restated here. A fixture with its own private shape is the documented
 * failure mode for this card: the spec would keep passing against a wire
 * contract the backend no longer speaks, which is worse than no spec at all
 * because it reads as coverage.
 *
 * Note the limit honestly: `bunx playwright test` TRANSPILES rather than
 * typechecks, so this binding bites under `tsc`/an editor and not at run time.
 * The run-time half of the same guarantee is that the harness serves these
 * objects verbatim and the spec asserts the rendered DOM against the SAME
 * literals — so a field the component stops reading turns a DOM assertion red.
 *
 * ─── Why the expected strings are literals and not computations ────────────
 *
 * `elapsed_s: 754` is asserted in the spec as the literal `"12m 34s"`, not as
 * `formatElapsed(754)`. Re-deriving the expectation with the component's own
 * helper would make the assertion a tautology — it would agree with any
 * formatter, including a broken one. The arithmetic is done once, by hand,
 * here in a comment: 754 = 12 x 60 + 34.
 */
import type {
  AggregateResult,
  StoredRecord,
  ToolCounts,
} from '../../../d2-signalloom/apps/dashboard-signalloom/src/types/codingAgent'

/** The fixed-arity tool vector, all zeroes. Non-zero entries are set per record. */
export function zeroToolCounts(): ToolCounts {
  return {
    view_file: 0,
    write_to_file: 0,
    replace_file_content: 0,
    run_command: 0,
    grep_search: 0,
    find_by_name: 0,
    list_dir: 0,
    read_url_content: 0,
    search_web: 0,
    invoke_subagent: 0,
    send_message: 0,
    manage_task: 0,
    ask_question: 0,
    other_count: 0,
  }
}

/**
 * CodingAgentCard derives its test id from the first eight characters of the
 * session id. Every session id below is chosen so those eight characters are
 * unmistakable in a failure message AND are not a prefix of any other — a
 * `^=` selector over shared prefixes matches child ids too, which is a trap
 * this suite has hit before.
 */
export function cardTestId(record: StoredRecord): string {
  return `coding-agent-card-${record.event.session_id.slice(0, 8)}`
}

const TENANT_A = 'tenant-acme'
const TENANT_B = 'tenant-globex'

export const TENANTS = { a: TENANT_A, b: TENANT_B } as const

/**
 * A VERIFIED detection: `harness` is a member of the closed enum in
 * types/codingAgent.ts, so CodingAgentCard renders its name, its icon and its
 * accent from the known-harness tables rather than the `unknown` fallback.
 *
 * Its metadata is the subject of the API-to-DOM mapping assertions, so every
 * field below is distinctive: a spec that asserted `role: implementation`
 * against a card that had swapped role and shortcode would still pass if both
 * were plausible. `elapsed_s` 754 renders as "12m 34s"; the tool vector's three
 * non-zero entries sum to 15, which the histogram header must report.
 */
export const ACME_CLAUDE: StoredRecord = {
  event: {
    schema_version: '1.0.0',
    harness: 'claude',
    session_id: 'aaaa1111-2222-4333-8444-555566667777',
    timestamp: '2026-09-15T09:00:00Z',
    observed_at: '2026-09-15T09:00:00.031Z',
    tenant_id: TENANT_A,
    agent_id: 'spiffe://cluster.local/ns/fe-signalloom/sa/claude-workstation-1',
    host_id: 'acme-dev-01.internal',
    process: {
      pid: 104231,
      ppid: 104200,
      comm: 'claude',
      rss_bytes: 184549376,
      cpu_ticks: 48210,
    },
    kanban: {
      task_id: 'SLCD-P6-3',
      shortcode: '4d5c9',
      role: 'implementation',
      elapsed_s: 754, // 12 x 60 + 34 -> "12m 34s"
    },
    metrics: {
      step_count: 21,
      tokens_in: 125000,
      tokens_out: 4200,
      tool_counts: {
        ...zeroToolCounts(),
        view_file: 9,
        run_command: 4,
        grep_search: 2, // 9 + 4 + 2 = 15 calls
      },
    },
    network: {
      inference_endpoint: 'api.anthropic.com',
      egress_bytes: 45000,
    },
  },
  observed_at: '2026-09-15T09:00:00.031Z',
  clock_skew_ms: 31,
  deduplication_key: 'aaaa1111-2026-09-15T09:00:00Z',
  ingested_at: '2026-09-15T09:00:00.062Z',
  tenant_id: TENANT_A,
  subject: 'spiffe://cluster.local/ns/fe-signalloom/sa/claude-workstation-1',
}

/**
 * An UNKNOWN classification: the sensor saw a process it could not attribute
 * to any harness in the closed enum.
 *
 * This is the state the card's `unknown` entries in HARNESS_ICONS and
 * HARNESS_COLORS exist for, and nothing exercised it in a browser before this
 * spec. It is a separate record rather than a mutated copy of ACME_CLAUDE so a
 * future edit to one cannot silently change the other.
 */
export const ACME_UNKNOWN: StoredRecord = {
  event: {
    schema_version: '1.0.0',
    harness: 'unknown',
    session_id: 'bbbb2222-3333-4444-8555-666677778888',
    timestamp: '2026-09-15T09:01:00Z',
    observed_at: '2026-09-15T09:01:00.014Z',
    tenant_id: TENANT_A,
    host_id: 'acme-dev-02.internal',
    process: {
      pid: 220145,
      ppid: 1,
      comm: 'node',
      rss_bytes: 52428800,
      cpu_ticks: 990,
    },
    kanban: {
      task_id: 'UNATTRIBUTED',
      shortcode: 'none',
      role: 'research',
      elapsed_s: 45, // -> "45s"
    },
    metrics: {
      step_count: 2,
      tokens_in: 0,
      tokens_out: 0,
      tool_counts: { ...zeroToolCounts(), other_count: 3 },
    },
    network: {
      inference_endpoint: '',
      egress_bytes: 0,
    },
  },
  observed_at: '2026-09-15T09:01:00.014Z',
  clock_skew_ms: 14,
  deduplication_key: 'bbbb2222-2026-09-15T09:01:00Z',
  ingested_at: '2026-09-15T09:01:00.029Z',
  tenant_id: TENANT_A,
  subject: 'spiffe://cluster.local/ns/fe-signalloom/sa/unattributed',
}

/**
 * Tenant B's only record. Its session-id prefix `cccc3333` is what the
 * isolation assertions look for in — and require the absence of from — each
 * tenant's DOM.
 */
export const GLOBEX_CODEX: StoredRecord = {
  event: {
    schema_version: '1.0.0',
    harness: 'codex',
    session_id: 'cccc3333-4444-4555-8666-777788889999',
    timestamp: '2026-09-15T09:02:00Z',
    observed_at: '2026-09-15T09:02:00.008Z',
    tenant_id: TENANT_B,
    host_id: 'globex-dev-09.internal',
    process: {
      pid: 771002,
      ppid: 770900,
      comm: 'codex',
      rss_bytes: 268435456,
      cpu_ticks: 12010,
    },
    kanban: {
      task_id: 'GLBX-P1-1',
      shortcode: 'g1x77',
      role: 'testing',
      elapsed_s: 93, // -> "1m 33s"
    },
    metrics: {
      step_count: 7,
      tokens_in: 8100,
      tokens_out: 990,
      tool_counts: { ...zeroToolCounts(), write_to_file: 5, list_dir: 1 },
    },
    network: {
      inference_endpoint: 'api.openai.com',
      egress_bytes: 12000,
    },
  },
  observed_at: '2026-09-15T09:02:00.008Z',
  clock_skew_ms: 8,
  deduplication_key: 'cccc3333-2026-09-15T09:02:00Z',
  ingested_at: '2026-09-15T09:02:00.019Z',
  tenant_id: TENANT_B,
  subject: 'spiffe://cluster.local/ns/fe-signalloom/sa/codex-workstation-9',
}

/**
 * An aggregate the server was willing to compute: cohort of 5, at the k floor.
 *
 * `group_size` is deliberately NOT 2 — that is the number of records tenant A
 * holds, and a card that silently fell back to a client-side count would then
 * be indistinguishable from one reading the server's figure. P5-GOV's
 * regression was exactly that substitution.
 */
export const SERVED_AGGREGATE: AggregateResult = {
  group_size: 5,
  total_events: 5,
  total_tokens_in: 400000,
  total_tokens_out: 21000,
  total_step_count: 88,
  total_elapsed_s: 4200,
  tool_counts: { ...zeroToolCounts(), view_file: 30, run_command: 12 },
  harness_distribution: {
    claude: 3,
    antigravity: 0,
    codex: 1,
    cpai: 0,
    opencode: 0,
    hermes: 0,
    aider: 0,
    unknown: 1,
  },
  avg_clock_skew_ms: 17.5,
}

/** Convenience state for `bun harness/coding-agents-server.ts --seed`. */
export const DEMO_SEED: Record<
  string,
  { records: StoredRecord[]; aggregate: AggregateResult | null; listStatus: number }
> = {
  [TENANT_A]: { records: [ACME_CLAUDE, ACME_UNKNOWN], aggregate: SERVED_AGGREGATE, listStatus: 200 },
  [TENANT_B]: { records: [GLOBEX_CODEX], aggregate: null, listStatus: 200 },
}
