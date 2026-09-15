// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * Closed enum of known autonomous coding agent harnesses.
 * Matches backend Go enum in codingagent/telemetry.go and P1-3 wire contract.
 */
export type Harness =
  | 'claude'
  | 'antigravity'
  | 'codex'
  | 'cpai'
  | 'opencode'
  | 'hermes'
  | 'aider'
  | 'unknown'

export const VALID_HARNESSES: readonly Harness[] = [
  'claude',
  'antigravity',
  'codex',
  'cpai',
  'opencode',
  'hermes',
  'aider',
  'unknown',
] as const

/**
 * Standard closed enum of 13 tool categories + other_count.
 */
export type ToolName =
  | 'view_file'
  | 'write_to_file'
  | 'replace_file_content'
  | 'run_command'
  | 'grep_search'
  | 'find_by_name'
  | 'list_dir'
  | 'read_url_content'
  | 'search_web'
  | 'invoke_subagent'
  | 'send_message'
  | 'manage_task'
  | 'ask_question'
  | 'other_count'

export const VALID_TOOL_NAMES: readonly ToolName[] = [
  'view_file',
  'write_to_file',
  'replace_file_content',
  'run_command',
  'grep_search',
  'find_by_name',
  'list_dir',
  'read_url_content',
  'search_web',
  'invoke_subagent',
  'send_message',
  'manage_task',
  'ask_question',
  'other_count',
] as const

/**
 * Process resource and identification metrics from the host OS.
 * Strictly metadata-only: zero commandline arguments or memory payload inspection.
 */
export interface ProcessInfo {
  pid: number
  ppid: number
  comm: string
  rss_bytes: number
  cpu_ticks: number
}

/**
 * Execution metadata from autonomous Kanban runner loops.
 */
export interface KanbanInfo {
  task_id: string
  shortcode: string
  role: string
  elapsed_s: number
}

/**
 * Fixed-arity tool invocation frequency vector.
 */
export interface ToolCounts {
  view_file: number
  write_to_file: number
  replace_file_content: number
  run_command: number
  grep_search: number
  find_by_name: number
  list_dir: number
  read_url_content: number
  search_web: number
  invoke_subagent: number
  send_message: number
  manage_task: number
  ask_question: number
  other_count: number
}

/**
 * Step, token, and tool count metrics.
 */
export interface MetricsInfo {
  step_count: number
  tokens_in: number
  tokens_out: number
  tool_counts: ToolCounts
}

/**
 * Non-intrusive network socket egress metadata.
 */
export interface NetworkInfo {
  inference_endpoint: string
  egress_bytes: number
}

/**
 * Top-level telemetry event emitted by workstation detective host sensors.
 */
export interface CodingAgentTelemetry {
  schema_version: string
  harness: Harness
  session_id: string
  timestamp: string
  observed_at?: string
  tenant_id?: string
  agent_id?: string
  host_id?: string
  process: ProcessInfo
  kanban: KanbanInfo
  metrics: MetricsInfo
  network: NetworkInfo
}

/**
 * Ingestion and storage wrapper stamped by the signal-ingest Go service.
 */
export interface StoredRecord {
  event: CodingAgentTelemetry
  observed_at: string
  clock_skew?: string
  clock_skew_ms: number
  deduplication_key: string
  ingested_at: string
  tenant_id: string
  subject: string
}

/**
 * Summary metrics protected by k-anonymity (k >= 5) to prevent re-identification.
 */
export interface AggregateResult {
  group_size: number
  total_events: number
  total_tokens_in: number
  total_tokens_out: number
  total_step_count: number
  total_elapsed_s: number
  tool_counts: ToolCounts
  harness_distribution: Record<Harness, number>
  avg_clock_skew_ms: number
}

export type OrderingVerdict = 'definite' | 'uncertain'
export type OrderingConfidence = 'monotonic_anchor' | 'skew_exceeded' | 'skew_bounded'

export interface OrderingResult {
  record_a: string
  record_b: string
  verdict: OrderingVerdict
  confidence: OrderingConfidence
  earlier_record: string
  time_delta_ms: number
  skew_bound_ms: number
  explanation: string
}

export interface CodingAgentFilter {
  harness?: string
  task_id?: string
  shortcode?: string
  after?: string
  before?: string
}
