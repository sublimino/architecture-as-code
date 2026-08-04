const AFM = '/afm'
const FETCH_TIMEOUT_MS = 15_000

export interface ClusterMeta { id: string; name: string }
export interface Subject { name: string; kind: string; namespace?: string }
export interface RoleRule { verbs: string[]; apiGroups: string[]; resources: string[] }
export interface Role { name: string; scope: string; namespace?: string; rules: RoleRule[] }
export interface Binding { name: string; scope: string; namespace?: string; roleRef: string; subjects: Subject[] }
export interface RBACData { subjects: Subject[]; roles: Role[]; bindings: Binding[]; namespaces?: string[] }

/**
 * AFM signals "absent" with an explicit `null`, not by omitting the key:
 * cluster-scoped roles, bindings and subjects all arrive as
 * `{..., "namespace": null}`, and bindings carry `"roleRefKind": null`.
 *
 * So these are PARSERS, not boolean type guards. They normalise the wire shape
 * into the strict interfaces above — null and missing both become absent — and
 * they tolerate extra keys AFM sends that we do not model (`annotations`,
 * `roleRefKind`). They reject only on a genuine contract break: a non-object, a
 * missing name, or a scope that is neither Cluster nor Namespace. That split
 * matters for a security tool — being lax about null-vs-absent is right,
 * silently dropping a role from an RBAC export is not.
 */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Absent, null and empty string all mean "no value". */
function asOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function asOptionalNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asBoolean(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback
}

/** Absent or null becomes an empty list; non-string members are dropped. */
function asStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function asScope(value: unknown): 'Cluster' | 'Namespace' | null {
  return value === 'Cluster' || value === 'Namespace' ? value : null
}

function parseSubject(value: unknown): Subject | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const kind = asOptionalString(value.kind)
  if (name === undefined || kind === undefined) return null

  const subject: Subject = { name, kind }
  const namespace = asOptionalString(value.namespace)
  if (namespace !== undefined) subject.namespace = namespace
  return subject
}

function parseRule(value: unknown): RoleRule {
  if (!isRecord(value)) return { verbs: [], apiGroups: [''], resources: [] }
  // Mirrors scripts/rbac-to-afm.py: a missing apiGroups means the core group,
  // whereas an explicitly empty one stays empty.
  const apiGroups = value.apiGroups === undefined || value.apiGroups === null
    ? ['']
    : asStringArray(value.apiGroups)
  return { verbs: asStringArray(value.verbs), apiGroups, resources: asStringArray(value.resources) }
}

function parseRole(value: unknown): Role | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const scope = asScope(value.scope)
  if (name === undefined || scope === null) return null

  // Aggregated ClusterRoles (admin, edit, view) carry `rules: null`.
  const role: Role = { name, scope, rules: (Array.isArray(value.rules) ? value.rules : []).map(parseRule) }
  const namespace = asOptionalString(value.namespace)
  if (namespace !== undefined) role.namespace = namespace
  return role
}

function parseBinding(value: unknown): Binding | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const scope = asScope(value.scope)
  if (name === undefined || scope === null) return null

  const subjects = (Array.isArray(value.subjects) ? value.subjects : [])
    .map(parseSubject)
    .filter((subject): subject is Subject => subject !== null)
  const binding: Binding = { name, scope, roleRef: asOptionalString(value.roleRef) ?? '', subjects }
  const namespace = asOptionalString(value.namespace)
  if (namespace !== undefined) binding.namespace = namespace
  return binding
}

function parseAll<T>(values: unknown[], parse: (value: unknown) => T | null, label: string): T[] {
  return values.map((value, index) => {
    const parsed = parse(value)
    if (parsed === null) {
      throw new Error(`AFM returned an unusable ${label} at index ${index}: ${JSON.stringify(value)?.slice(0, 200)}`)
    }
    return parsed
  })
}

async function fetchAfmResponse(path: string): Promise<Response> {
  const url = `${AFM}${path}`
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS)

  try {
    return await fetch(url, { signal: controller.signal })
  } finally {
    clearTimeout(timeout)
  }
}

export async function fetchJson<T>(path: string): Promise<T | null> {
  const url = `${AFM}${path}`

  try {
    const res = await fetchAfmResponse(path)
    if (!res.ok) {
      console.warn(`[afm] ${url} → ${res.status}`)
      return null
    }
    return await res.json() as T
  } catch (error) {
    console.error(`[afm] ${url} failed:`, error)
    return null
  }
}

export async function fetchJsonOrThrow(path: string): Promise<unknown> {
  const url = `${AFM}${path}`
  const res = await fetchAfmResponse(path)

  if (!res.ok) {
    throw new Error(`AFM request failed for ${url} with status ${res.status}.`)
  }

  try {
    return await res.json()
  } catch (error) {
    const detail = error instanceof Error ? error.message : 'Unknown JSON parse error'
    throw new Error(`AFM returned invalid JSON for ${url}: ${detail}`)
  }
}

export async function fetchOk(path: string): Promise<boolean> {
  try {
    const res = await fetchAfmResponse(path)
    return res.ok
  } catch (error) {
    console.error(`[afm] ${AFM}${path} failed:`, error)
    return false
  }
}

/**
 * `name` is optional on the wire — fall back to the id rather than rejecting
 * the whole cluster list, which would break the panel before it reaches RBAC.
 */
export function parseClusterList(value: unknown): ClusterMeta[] {
  if (!Array.isArray(value)) {
    throw new Error('AFM returned a non-array cluster list for /afm/clusters.')
  }
  return value.map((item, index) => {
    const id = isRecord(item) ? asOptionalString(item.id) : undefined
    if (id === undefined) {
      throw new Error(`AFM returned a cluster without an id at index ${index}.`)
    }
    return { id, name: (isRecord(item) ? asOptionalString(item.name) : undefined) ?? id }
  })
}

export function parseRbacData(value: unknown): RBACData {
  if (!isRecord(value)) {
    throw new Error('AFM returned a non-object RBAC payload.')
  }
  for (const key of ['subjects', 'roles', 'bindings'] as const) {
    if (!Array.isArray(value[key])) {
      throw new Error(`AFM returned an RBAC payload whose "${key}" is not an array.`)
    }
  }

  const rbac: RBACData = {
    subjects: parseAll(value.subjects as unknown[], parseSubject, 'subject'),
    roles: parseAll(value.roles as unknown[], parseRole, 'role'),
    bindings: parseAll(value.bindings as unknown[], parseBinding, 'binding'),
  }
  // AFM reports its own namespace list alongside the items. It is empty on the
  // sample clusters, so it is a preference, not a replacement — see
  // deriveNamespaces.
  const reported = asStringArray(value.namespaces)
  if (reported.length > 0) rbac.namespaces = reported
  return rbac
}

/**
 * Prefers AFM's own `namespaces` list when it is non-empty, otherwise derives
 * the set from the items. Nulls are skipped either way: `asOptionalString`
 * has already dropped them at the parse boundary, and the truthiness checks
 * below are a second line of defence for data built in-process.
 */
export function deriveNamespaces(rbac: RBACData): string[] {
  if (rbac.namespaces && rbac.namespaces.length > 0) {
    return Array.from(new Set(rbac.namespaces)).sort()
  }

  const namespaces = new Set<string>()

  rbac.roles.forEach(role => {
    if (role.namespace) {
      namespaces.add(role.namespace)
    }
  })
  rbac.bindings.forEach(binding => {
    if (binding.namespace) {
      namespaces.add(binding.namespace)
    }
  })
  rbac.subjects.forEach(subject => {
    if (subject.namespace) {
      namespaces.add(subject.namespace)
    }
  })

  return Array.from(namespaces).sort()
}

/**
 * ── Escalation analysis (collusion / privilege-escalation runs) ───────────
 *
 * AFM's engine wire format is snake_case (FastAPI/pydantic), unlike the RBAC
 * import/export shapes above which mirror Kubernetes' own camelCase field
 * names. These parsers translate at the boundary so the rest of the app
 * never sees a snake_case key. They are lenient in the same spirit as
 * parseRbacData above: tolerate unmodelled fields, reject only when a value
 * this page actually renders is unusable.
 */

export type JobStatus = 'queued' | 'running' | 'done' | 'failed' | 'interrupted'
export type TriggerSource = 'manual' | 'webhook' | 'api' | 'scheduled'

export interface JobRecord {
  id: string
  clusterId: string
  status: JobStatus
  triggerSource: TriggerSource
  createdAt: string
  startedAt?: string
  finishedAt?: string
  error?: string
}

export interface Permission { verb: string; resource: string; namespace: string }

export interface EscalationRisk {
  score?: number
  level?: string
  likelihood?: number
  impact?: number
  reason?: string
  autoPatchRecommended?: boolean
}

export interface SingleEscalation {
  subject: string
  escalationType: string
  scope: string
  gainedPermission: Permission
  risk: EscalationRisk | null
}

export interface CollaboratorGain { subject: string; permission: Permission }

export interface GroupEscalation {
  group: string[]
  primaryActor: string
  scope: string
  primaryGain: Permission
  collaboratorGains: CollaboratorGain[]
  risk: EscalationRisk | null
}

export interface AnalysisResult {
  schemaVersion: string
  subjects: string[]
  singleEscalations: SingleEscalation[]
  groupEscalations: GroupEscalation[]
}

export interface SharedRoleEntry {
  role: string
  sharedBy: number
  privilegedSubjects: string[]
}

export interface Guard {
  name: string
  kind: 'single' | 'group'
  escalationIndex: number
  participants: string[]
  wouldBlock: boolean
}

export interface GuardsResult { jobId: string; guards: Guard[] }

export interface AnalysisStatusInfo {
  hasRunning: boolean
  lastCompletedJobId: string | null
  latestDoneAt: string | null
  latestFailedAt: string | null
}

function parsePermission(value: unknown): Permission {
  if (!isRecord(value)) return { verb: '', resource: '', namespace: '' }
  return {
    verb: asOptionalString(value.verb) ?? '',
    resource: asOptionalString(value.resource) ?? '',
    namespace: asOptionalString(value.namespace) ?? '',
  }
}

function parseRisk(value: unknown): EscalationRisk | null {
  if (!isRecord(value)) return null
  return {
    score: asOptionalNumber(value.score),
    level: asOptionalString(value.level),
    likelihood: asOptionalNumber(value.likelihood),
    impact: asOptionalNumber(value.impact),
    reason: asOptionalString(value.reason),
    autoPatchRecommended: typeof value.auto_patch_recommended === 'boolean' ? value.auto_patch_recommended : undefined,
  }
}

function parseSingleEscalation(value: unknown): SingleEscalation | null {
  if (!isRecord(value)) return null
  const subject = asOptionalString(value.subject)
  const escalationType = asOptionalString(value.escalation_type)
  if (subject === undefined || escalationType === undefined) return null
  return {
    subject,
    escalationType,
    scope: asOptionalString(value.scope) ?? 'unknown',
    gainedPermission: parsePermission(value.gained_permission),
    risk: parseRisk(value.risk),
  }
}

function parseGroupEscalation(value: unknown): GroupEscalation | null {
  if (!isRecord(value)) return null
  const primaryActor = asOptionalString(value.primary_actor)
  if (primaryActor === undefined) return null
  const collaboratorGains = (Array.isArray(value.collaborator_gains) ? value.collaborator_gains : [])
    .filter(isRecord)
    .map((gain): CollaboratorGain => ({
      subject: asOptionalString(gain.subject) ?? '',
      permission: parsePermission(gain.permission),
    }))
  return {
    group: asStringArray(value.group),
    primaryActor,
    scope: asOptionalString(value.scope) ?? 'unknown',
    primaryGain: parsePermission(value.primary_gain),
    collaboratorGains,
    risk: parseRisk(value.risk),
  }
}

/**
 * AFM returns a JSON `null` body for `/analysis/latest` when no run has
 * completed yet for that cluster — that is a legitimate "no data" state, not
 * an error, so it round-trips to `null` rather than throwing.
 */
export function parseAnalysisResult(value: unknown): AnalysisResult | null {
  if (value === null) return null
  if (!isRecord(value)) {
    throw new Error('AFM returned a non-object analysis result.')
  }
  const metadata = isRecord(value.metadata) ? value.metadata : {}
  return {
    schemaVersion: asOptionalString(value.schema_version) ?? 'unknown',
    subjects: asStringArray(metadata.subjects),
    singleEscalations: (Array.isArray(value.single_escalations) ? value.single_escalations : [])
      .map(parseSingleEscalation)
      .filter((entry): entry is SingleEscalation => entry !== null),
    groupEscalations: (Array.isArray(value.group_escalations) ? value.group_escalations : [])
      .map(parseGroupEscalation)
      .filter((entry): entry is GroupEscalation => entry !== null),
  }
}

const JOB_STATUSES: JobStatus[] = ['queued', 'running', 'done', 'failed', 'interrupted']
const TRIGGER_SOURCES: TriggerSource[] = ['manual', 'webhook', 'api', 'scheduled']

function parseJobStatus(value: unknown): JobStatus {
  return typeof value === 'string' && (JOB_STATUSES as string[]).includes(value) ? (value as JobStatus) : 'failed'
}

function parseTriggerSource(value: unknown): TriggerSource {
  return typeof value === 'string' && (TRIGGER_SOURCES as string[]).includes(value) ? (value as TriggerSource) : 'api'
}

function parseJobRecord(value: unknown): JobRecord | null {
  if (!isRecord(value)) return null
  const id = asOptionalString(value.id)
  const clusterId = asOptionalString(value.cluster_id)
  const createdAt = asOptionalString(value.created_at)
  if (id === undefined || clusterId === undefined || createdAt === undefined) return null
  return {
    id,
    clusterId,
    status: parseJobStatus(value.status),
    triggerSource: parseTriggerSource(value.trigger_source),
    createdAt,
    startedAt: asOptionalString(value.started_at),
    finishedAt: asOptionalString(value.finished_at),
    error: asOptionalString(value.error),
  }
}

/** Malformed entries are dropped, not fatal — one bad job record should not blank the whole run selector. */
export function parseJobList(value: unknown): JobRecord[] {
  if (!Array.isArray(value)) {
    throw new Error('AFM returned a non-array job list.')
  }
  return value.map(parseJobRecord).filter((job): job is JobRecord => job !== null)
}

export function parseSharedRoles(value: unknown): SharedRoleEntry[] {
  if (!isRecord(value) || !Array.isArray(value.results)) {
    throw new Error('AFM returned a non-object shared-roles payload.')
  }
  return value.results.filter(isRecord).map((entry): SharedRoleEntry => ({
    role: asOptionalString(entry.role) ?? 'unknown',
    sharedBy: asStringArray(entry.all_subjects).length,
    privilegedSubjects: asStringArray(entry.privileged_subjects),
  }))
}

export function parseGuardsResult(value: unknown): GuardsResult {
  if (!isRecord(value) || !Array.isArray(value.guards)) {
    throw new Error('AFM returned a non-object guards payload.')
  }
  const guards = value.guards.filter(isRecord).map((guard): Guard => ({
    name: asOptionalString(guard.name) ?? 'unnamed-guard',
    kind: guard.kind === 'group' ? 'group' : 'single',
    escalationIndex: typeof guard.escalation_index === 'number' ? guard.escalation_index : -1,
    participants: asStringArray(guard.participants),
    wouldBlock: asBoolean(guard.would_block, false),
  }))
  return { jobId: asOptionalString(value.job_id) ?? '', guards }
}

export function parseAnalysisStatus(value: unknown): AnalysisStatusInfo {
  if (!isRecord(value)) {
    throw new Error('AFM returned a non-object analysis-status payload.')
  }
  return {
    hasRunning: asBoolean(value.has_running, false),
    lastCompletedJobId: asOptionalString(value.last_completed_job_id) ?? null,
    latestDoneAt: asOptionalString(value.latest_done_at) ?? null,
    latestFailedAt: asOptionalString(value.latest_failed_at) ?? null,
  }
}

/** Most recent runs for one cluster — the source list for the run-selector dropdown. */
/** POST a cluster import payload to AFM. Throws on non-2xx or network error. */
export async function postClusterImport(payload: unknown): Promise<void> {
  const url = `${AFM}/clusters/import`
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS)

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })

    if (!res.ok) {
      throw new Error(`AFM import failed for ${url} with status ${res.status}.`)
    }
  } finally {
    clearTimeout(timeout)
  }
}

export async function fetchClusterJobs(clusterId: string, limit = 25): Promise<JobRecord[]> {
  return parseJobList(await fetchJsonOrThrow(`/clusters/${encodeURIComponent(clusterId)}/jobs?limit=${limit}`))
}

/** The cluster's most recently completed escalation analysis, or null if none has run yet. */
export async function fetchAnalysisResult(clusterId: string): Promise<AnalysisResult | null> {
  return parseAnalysisResult(await fetchJsonOrThrow(`/clusters/${encodeURIComponent(clusterId)}/analysis/latest`))
}

/** A specific historical run's result — this is what powers the run drill-down, not just "latest". */
export async function fetchJobResult(jobId: string): Promise<AnalysisResult | null> {
  return parseAnalysisResult(await fetchJsonOrThrow(`/jobs/${encodeURIComponent(jobId)}/result`))
}

export async function fetchSharedRoles(clusterId: string): Promise<SharedRoleEntry[]> {
  return parseSharedRoles(await fetchJsonOrThrow(`/clusters/${encodeURIComponent(clusterId)}/analysis/shared_roles`))
}

export async function fetchGuards(clusterId: string): Promise<GuardsResult> {
  return parseGuardsResult(await fetchJsonOrThrow(`/clusters/${encodeURIComponent(clusterId)}/analysis/guards`))
}

export async function fetchAnalysisStatus(clusterId: string): Promise<AnalysisStatusInfo> {
  return parseAnalysisStatus(await fetchJsonOrThrow(`/clusters/${encodeURIComponent(clusterId)}/analysis/status`))
}
