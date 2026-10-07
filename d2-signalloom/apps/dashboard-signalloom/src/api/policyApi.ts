/**
 * policyApi: the multilayer policy engine's review surface.
 *
 * Four reads and one write, all under `/api/signals/policy/*` through the
 * gateway, plus the local fixture set the Signals page renders in demo mode.
 *
 * Why this module carries its own fixtures rather than registering routes in
 * `fakeData.ts`: the policy routes are tenant-scoped, window-parameterised and
 * stateful (a review posted once must still be there on the next poll). The
 * shared fake-route table resolves a method and a path to a constant body and
 * has nowhere to keep that state, so a review would vanish on the next 10
 * second refresh and the page would look broken in the exact mode it exists to
 * make presentable. `signalFusionDemo.ts`, `distanceLatencyDemo.ts` and
 * `afmDemoFixtures.ts` are the precedent for a module-local demo source.
 *
 * The fixtures are deliberately thin: pseudonymous actors, projected one-line
 * descriptions, label chips. No raw payload ever enters this module, in demo
 * mode or live, because the page must never be able to render one.
 */
import { req } from './client'
import { isDemoMode } from './demoMode'
import type { SignalLayer } from './weaveApi'

// ─── Domain Types ────────────────────────────────────────────────────────────

/** The review windows the page offers, ascending. */
export const POLICY_WINDOWS = ['5m', '10m', '30m', '90m'] as const
export type PolicyWindow = (typeof POLICY_WINDOWS)[number]

/** Rate buckets the `/rates` endpoint supports. */
export type RateBucket = '1m' | '5m'

/** The three verdicts a human reviewer can record. */
export type ReviewVerdict = 'true_positive' | 'false_positive' | 'needs_info'

/** How long a note must be before the review control will submit it. */
export const REVIEW_NOTE_MIN_LENGTH = 10

export const VERDICT_LABELS: Record<ReviewVerdict, string> = {
  true_positive: 'True positive',
  false_positive: 'False positive',
  needs_info: 'Needs info',
}

/** Enforcement posture a rule was evaluated under. */
export type PolicyMode = 'enforce' | 'monitor' | 'dry_run' | string

export type PolicySeverity = 'critical' | 'high' | 'medium' | 'low' | 'info' | string

export interface PolicyFinding {
  id: string
  timestamp: string
  tenant_id: string
  actor: string
  layer: SignalLayer | string
  source_observation_id: string
  rule_id: string
  bundle_id: string
  bundle_version: string
  severity: PolicySeverity
  mode: PolicyMode
  labels?: Record<string, string> | null
}

export interface DecisionReview {
  id: string
  decision_id?: string
  verdict: ReviewVerdict
  note: string
  reviewer: string
  reviewed_at: string
}

export interface PolicyDecision {
  id: string
  timestamp: string
  tenant_id: string
  actor: string
  window_id: string
  rule_id: string
  bundle_id: string
  bundle_version: string
  severity: PolicySeverity
  mode: PolicyMode
  count: number
  finding_ids: string[]
  review: DecisionReview | null
}

export interface IngestRateBucket {
  bucket_start: string
  layer: SignalLayer | string
  source: string
  count: number
}

export interface ReviewRequest {
  verdict: ReviewVerdict
  note: string
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Coerce a list-shaped response to an actual array.
 *
 * Same defence, and the same reason, as `asList` in weaveApi.ts: `req<T[]>` is
 * a cast and not a check, and a Go service marshalling a nil slice emits
 * `null`, which reaches component state and throws on `.length`. Anything that
 * is not an array becomes an empty array, which is the truthful reading of
 * "no items".
 */
const asList = <T>(value: T[] | null | undefined): T[] => (Array.isArray(value) ? value : [])

/** True when the error text means the gateway or the engine behind it is down. */
export function isPolicyConnectionError(msg: string): boolean {
  return /Network Error|ERR_CONNECTION_REFUSED|ECONNREFUSED|upstream_unavailable|status code 502|status code 503/i.test(
    msg,
  )
}

/** Milliseconds covered by a window label. */
export function windowMs(window: PolicyWindow): number {
  return parseInt(window, 10) * 60_000
}

/**
 * The message a failed review deserves.
 *
 * 409 and 403 are the two the page has to get right: a 409 means someone (or
 * this operator, twice) already recorded the identical verdict, which is not a
 * fault and must not read like one; a 403 means the key is read-only, and the
 * operator needs to be told that rather than shown a retry button that cannot
 * ever work.
 */
export function reviewErrorMessage(err: unknown): string {
  const status = (err as { response?: { status?: number } })?.response?.status
  const data = (err as { response?: { data?: unknown } })?.response?.data as
    | { error?: { code?: string; message?: string } | string; message?: string }
    | undefined
  if (status === 409) return 'That review is already recorded for this decision.'
  if (status === 403) return 'Your key cannot review decisions. Ask an operator with review rights.'
  if (status === 404) return 'The policy engine no longer knows this decision for your tenant.'
  if (status === 502 || status === 503) return 'The policy engine is unreachable from the portal right now.'
  if (typeof data?.error === 'object' && data.error?.message) return data.error.message
  if (typeof data?.error === 'string') return data.error
  if (typeof data?.message === 'string') return data.message
  return err instanceof Error ? err.message : 'Review failed.'
}

function listQuery(params: { window: PolicyWindow; tenant?: string; limit?: number }): string {
  const q = new URLSearchParams()
  q.set('window', params.window)
  if (params.tenant) q.set('tenant', params.tenant)
  if (params.limit !== undefined) q.set('limit', String(params.limit))
  return q.toString()
}

// ─── Demo fixtures ───────────────────────────────────────────────────────────

const DEMO_NOW = () => Date.now()

interface DemoSeed {
  offsetMin: number
  layer: SignalLayer
  source: string
  actor: string
  rule_id: string
  severity: PolicySeverity
  mode: PolicyMode
  labels: Record<string, string>
}

/**
 * Seeds for the demo set, ordered newest first, with ages chosen so that each
 * window boundary genuinely changes what the page shows: two inside 5m, two
 * more by 10m, three more by 30m, the rest by 90m.
 */
const DEMO_SEEDS: DemoSeed[] = [
  { offsetMin: 1, layer: 'network_egress', source: 'ebpf-socket-sentinel', actor: 'actor-7f3a', rule_id: 'egress.unapproved_destination', severity: 'high', mode: 'enforce', labels: { destination: 'api.unknown-llm.example', verdict: 'deny' } },
  { offsetMin: 3, layer: 'cloud_control_plane', source: 'aws-cloudtrail', actor: 'actor-2c91', rule_id: 'cloudaudit.iam_policy_widened', severity: 'critical', mode: 'enforce', labels: { region: 'eu-west-2', principal_type: 'assumed_role' } },
  { offsetMin: 7, layer: 'identity_authorization', source: 'openbao-audit', actor: 'actor-7f3a', rule_id: 'identity.token_used_outside_binding', severity: 'high', mode: 'monitor', labels: { binding: 'tenant-demo', outcome: 'allowed' } },
  { offsetMin: 9, layer: 'application_saas', source: 'saas-connector', actor: 'actor-b418', rule_id: 'saas.bulk_export', severity: 'medium', mode: 'monitor', labels: { object_count: '1420' } },
  { offsetMin: 14, layer: 'endpoint_host', source: 'sentinel-ebpf', actor: 'actor-2c91', rule_id: 'host.sensitive_file_access', severity: 'high', mode: 'enforce', labels: { path_prefix: '/etc', outcome: 'blocked' } },
  { offsetMin: 21, layer: 'behavioural', source: 'behaviour-model', actor: 'actor-b418', rule_id: 'behaviour.rate_anomaly', severity: 'medium', mode: 'dry_run', labels: { sigma: '4.2' } },
  { offsetMin: 27, layer: 'network_egress', source: 'ebpf-socket-sentinel', actor: 'actor-d0e5', rule_id: 'egress.unapproved_destination', severity: 'high', mode: 'enforce', labels: { destination: 'paste.example.net', verdict: 'deny' } },
  { offsetMin: 41, layer: 'cloud_control_plane', source: 'aws-cloudtrail', actor: 'actor-d0e5', rule_id: 'cloudaudit.key_material_read', severity: 'critical', mode: 'enforce', labels: { region: 'us-east-1' } },
  { offsetMin: 58, layer: 'identity_authorization', source: 'openbao-audit', actor: 'actor-b418', rule_id: 'identity.credential_reuse', severity: 'low', mode: 'monitor', labels: { reuse_count: '3' } },
  { offsetMin: 76, layer: 'application_saas', source: 'saas-connector', actor: 'actor-7f3a', rule_id: 'saas.share_link_public', severity: 'medium', mode: 'monitor', labels: { scope: 'anyone_with_link' } },
]

const DEMO_BUNDLE = { bundle_id: 'slaws-baseline', bundle_version: '0.4.2' }

function demoFinding(seed: DemoSeed, index: number, now: number): PolicyFinding {
  const ts = new Date(now - seed.offsetMin * 60_000).toISOString()
  return {
    id: `fnd-demo-${index}`,
    timestamp: ts,
    tenant_id: 'tenant-demo',
    actor: seed.actor,
    layer: seed.layer,
    source_observation_id: `obs-demo-${index}`,
    rule_id: seed.rule_id,
    ...DEMO_BUNDLE,
    severity: seed.severity,
    mode: seed.mode,
    labels: { source: seed.source, ...seed.labels },
  }
}

/**
 * Reviews recorded while in demo mode, keyed by decision id.
 *
 * Module-level so a verdict survives the 10 second refetch. Lost on reload,
 * which is the right lifetime for a demo.
 */
const demoReviews = new Map<string, DecisionReview>()

/** Reset the demo review ledger. Exported for tests. */
export function resetDemoReviews(): void {
  demoReviews.clear()
}

function demoFindingsFor(window: PolicyWindow, now: number): PolicyFinding[] {
  const limit = windowMs(window)
  return DEMO_SEEDS.map((seed, i) => demoFinding(seed, i, now)).filter(
    (f) => now - Date.parse(f.timestamp) <= limit,
  )
}

function demoDecisionsFor(window: PolicyWindow, now: number): PolicyDecision[] {
  const findings = demoFindingsFor(window, now)
  // One decision per rule and actor pair, which is how the engine aggregates a
  // window: the count is what makes a decision reviewable rather than a single
  // finding being re-judged over and over.
  const groups = new Map<string, PolicyFinding[]>()
  for (const f of findings) {
    const key = `${f.rule_id}|${f.actor}`
    const existing = groups.get(key) ?? []
    existing.push(f)
    groups.set(key, existing)
  }
  const prereviewed: Record<string, { verdict: ReviewVerdict; note: string }> = {
    'saas.bulk_export|actor-b418': {
      verdict: 'false_positive',
      note: 'Scheduled nightly export, owner confirmed in change record CHG-2291.',
    },
  }
  return [...groups.entries()].map(([key, group], i) => {
    const head = group[0]
    const id = `dec-demo-${i}`
    const seeded = prereviewed[key]
    const stored = demoReviews.get(id)
    const review: DecisionReview | null =
      stored ??
      (seeded
        ? {
            id: `rev-seed-${i}`,
            decision_id: id,
            verdict: seeded.verdict,
            note: seeded.note,
            reviewer: 'demo-user@signalloom.local',
            reviewed_at: new Date(now - 4 * 60_000).toISOString(),
          }
        : null)
    return {
      id,
      timestamp: head.timestamp,
      tenant_id: head.tenant_id,
      actor: head.actor,
      window_id: `win-${window}-${i}`,
      rule_id: head.rule_id,
      ...DEMO_BUNDLE,
      severity: head.severity,
      mode: head.mode,
      count: group.length,
      finding_ids: group.map((f) => f.id),
      review,
    }
  })
}

function demoRatesFor(window: PolicyWindow, bucket: RateBucket, now: number): IngestRateBucket[] {
  const bucketMs = bucket === '1m' ? 60_000 : 5 * 60_000
  const buckets = Math.max(1, Math.round(windowMs(window) / bucketMs))
  const out: IngestRateBucket[] = []
  for (let b = buckets - 1; b >= 0; b -= 1) {
    const start = new Date(now - b * bucketMs)
    start.setSeconds(0, 0)
    const iso = start.toISOString()
    for (const seed of DEMO_SEEDS) {
      // Deterministic, not random: a demo that renders a different chart on
      // every poll reads as instability rather than as live data.
      const base = (seed.rule_id.length + b * 3 + seed.layer.length) % 5
      if (base === 0) continue
      out.push({ bucket_start: iso, layer: seed.layer, source: seed.source, count: base })
    }
  }
  return out
}

// ─── Client ──────────────────────────────────────────────────────────────────

export const policyApi = {
  getFindings: async (
    token: string,
    params: { window: PolicyWindow; tenant?: string; limit?: number },
  ): Promise<PolicyFinding[]> => {
    if (isDemoMode()) return demoFindingsFor(params.window, DEMO_NOW())
    return asList(
      await req<PolicyFinding[] | null>(`/signals/policy/findings?${listQuery(params)}`, token),
    )
  },

  getDecisions: async (
    token: string,
    params: { window: PolicyWindow; tenant?: string; limit?: number },
  ): Promise<PolicyDecision[]> => {
    if (isDemoMode()) return demoDecisionsFor(params.window, DEMO_NOW())
    return asList(
      await req<PolicyDecision[] | null>(`/signals/policy/decisions?${listQuery(params)}`, token),
    )
  },

  getRates: async (
    token: string,
    params: { window: PolicyWindow; bucket: RateBucket },
  ): Promise<IngestRateBucket[]> => {
    if (isDemoMode()) return demoRatesFor(params.window, params.bucket, DEMO_NOW())
    const q = new URLSearchParams({ window: params.window, bucket: params.bucket })
    return asList(await req<IngestRateBucket[] | null>(`/signals/policy/rates?${q.toString()}`, token))
  },

  reviewDecision: async (
    token: string,
    decisionId: string,
    body: ReviewRequest,
  ): Promise<DecisionReview> => {
    if (isDemoMode()) {
      const review: DecisionReview = {
        id: `rev-demo-${demoReviews.size + 1}`,
        decision_id: decisionId,
        verdict: body.verdict,
        note: body.note,
        reviewer: 'demo-user@signalloom.local',
        reviewed_at: new Date(DEMO_NOW()).toISOString(),
      }
      demoReviews.set(decisionId, review)
      return review
    }
    return req<DecisionReview>(
      `/signals/policy/decisions/${encodeURIComponent(decisionId)}/review`,
      token,
      { method: 'POST', data: body },
    )
  },
}
