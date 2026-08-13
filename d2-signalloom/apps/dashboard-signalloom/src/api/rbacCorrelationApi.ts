/**
 * Client for the intermediate `/api/rbac/*` correlation endpoints backed by
 * `rbac_correlation.py` (fe-signalloom API) — distinct from `afmApi.ts`,
 * which wraps the direct `/afm/*` proxy to KubeSec-AFM itself.
 *
 * AFM exposes cluster RBAC, escalation analysis, conformance and shared-role
 * findings as four separate endpoints, and the RBAC Explorer used to fetch
 * all four client-side and stitch them together against an assumed wire
 * shape that was never checked against a live cluster. Verified against the
 * running `osramp` KinD cluster (see docs/signalloom/rbac-live-wiring.md),
 * that assumption was wrong: AFM's escalation list is keyed
 * `single_escalations`/`group_escalations` (not `escalation_paths`, which
 * does not exist), conformance nests the role identity under `role`, and
 * shared-role findings carry `all_subjects`/`privileged_subjects` rather than
 * a `shared_by` count or a `risk` field. That correlation now happens once,
 * server-side, behind tenant auth (see rbac_correlation.py's module
 * docstring) — this module is a thin, typed client over the result.
 *
 * Unlike `afmApi.ts`'s unauthenticated `/afm/*` calls, every request here
 * requires a bearer token, matching the rest of `/api/*` (see fe-signalloom's
 * README: "Every endpoint requires a Dex RS256 JWT").
 */

const BASE = '/api/rbac'
const FETCH_TIMEOUT_MS = 20_000

export interface ClusterMeta { id: string; name: string }
export interface RoleRule { verbs: string[]; apiGroups: string[]; resources: string[] }

export interface RbacSubject {
  name: string
  kind: string
  namespace?: string
  isAdmin: boolean
  isEscalationActor: boolean
}

export interface RbacRole {
  name: string
  scope: string
  namespace?: string
  rules: RoleRule[]
  conformanceIssueCount: number
  sharedByCount: number
  hasPrivilegedSharing: boolean
}

export interface RbacBinding {
  name: string
  scope: string
  namespace?: string
  roleRef: string
  subjects: RbacSubject[]
}

export interface EscalationFinding {
  kind: 'single' | 'group'
  subject: string
  subjectDisplay?: string
  escalationType?: string
  riskLevel?: string
  riskScore?: number
  summary?: string
}

export interface ConformanceFinding {
  roleName?: string
  roleScope?: string
  roleNamespace?: string
  severity?: string
  reason?: string
}

export interface SharedRoleFinding {
  roleName: string
  roleScope: string
  roleNamespace?: string
  sharedBy: number
  subjects: string[]
  privilegedSubjectCount: number
}

export interface CorrelatedRbac {
  cluster: ClusterMeta
  namespaces: string[]
  subjects: RbacSubject[]
  roles: RbacRole[]
  bindings: RbacBinding[]
  escalations: EscalationFinding[]
  conformance: ConformanceFinding[]
  sharedRoles: SharedRoleFinding[]
  adminCount: number
  nonAdminCount: number
}

// ─── Null-tolerant wire parsing (mirrors afmApi.ts) ─────────────────────────

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function asStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function asBoolean(value: unknown): boolean {
  return value === true
}

function asNumber(value: unknown): number {
  return typeof value === 'number' ? value : 0
}

function parseRule(value: unknown): RoleRule {
  if (!isRecord(value)) return { verbs: [], apiGroups: [], resources: [] }
  return { verbs: asStringArray(value.verbs), apiGroups: asStringArray(value.apiGroups), resources: asStringArray(value.resources) }
}

function parseSubject(value: unknown): RbacSubject | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const kind = asOptionalString(value.kind)
  if (name === undefined || kind === undefined) return null
  return {
    name,
    kind,
    namespace: asOptionalString(value.namespace),
    isAdmin: asBoolean(value.is_admin),
    isEscalationActor: asBoolean(value.is_escalation_actor),
  }
}

function parseRole(value: unknown): RbacRole | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const scope = asOptionalString(value.scope)
  if (name === undefined || scope === undefined) return null
  return {
    name,
    scope,
    namespace: asOptionalString(value.namespace),
    rules: Array.isArray(value.rules) ? value.rules.map(parseRule) : [],
    conformanceIssueCount: asNumber(value.conformance_issue_count),
    sharedByCount: asNumber(value.shared_by_count),
    hasPrivilegedSharing: asBoolean(value.has_privileged_sharing),
  }
}

function parseBinding(value: unknown): RbacBinding | null {
  if (!isRecord(value)) return null
  const name = asOptionalString(value.name)
  const scope = asOptionalString(value.scope)
  if (name === undefined || scope === undefined) return null
  const subjects = Array.isArray(value.subjects)
    ? value.subjects.map(parseSubject).filter((s): s is RbacSubject => s !== null)
    : []
  return {
    name,
    scope,
    namespace: asOptionalString(value.namespace),
    roleRef: asOptionalString(value.role_ref) ?? '',
    subjects,
  }
}

function parseEscalation(value: unknown): EscalationFinding | null {
  if (!isRecord(value)) return null
  const kind = value.kind === 'group' ? 'group' : value.kind === 'single' ? 'single' : null
  const subject = asOptionalString(value.subject)
  if (kind === null || subject === undefined) return null
  return {
    kind,
    subject,
    subjectDisplay: asOptionalString(value.subject_display),
    escalationType: asOptionalString(value.escalation_type),
    riskLevel: asOptionalString(value.risk_level),
    riskScore: typeof value.risk_score === 'number' ? value.risk_score : undefined,
    summary: asOptionalString(value.summary),
  }
}

function parseConformance(value: unknown): ConformanceFinding | null {
  if (!isRecord(value)) return null
  return {
    roleName: asOptionalString(value.role_name),
    roleScope: asOptionalString(value.role_scope),
    roleNamespace: asOptionalString(value.role_namespace),
    severity: asOptionalString(value.severity),
    reason: asOptionalString(value.reason),
  }
}

function parseSharedRole(value: unknown): SharedRoleFinding | null {
  if (!isRecord(value)) return null
  const roleName = asOptionalString(value.role_name)
  const roleScope = asOptionalString(value.role_scope)
  if (roleName === undefined || roleScope === undefined) return null
  return {
    roleName,
    roleScope,
    roleNamespace: asOptionalString(value.role_namespace),
    sharedBy: asNumber(value.shared_by),
    subjects: asStringArray(value.subjects),
    privilegedSubjectCount: asNumber(value.privileged_subject_count),
  }
}

export function parseCorrelatedRbac(value: unknown): CorrelatedRbac {
  if (!isRecord(value)) {
    throw new Error('RBAC correlation endpoint returned a non-object payload.')
  }
  const cluster = isRecord(value.cluster)
    ? { id: asOptionalString(value.cluster.id) ?? '', name: asOptionalString(value.cluster.name) ?? '' }
    : { id: '', name: '' }

  return {
    cluster,
    namespaces: asStringArray(value.namespaces),
    subjects: Array.isArray(value.subjects) ? value.subjects.map(parseSubject).filter((s): s is RbacSubject => s !== null) : [],
    roles: Array.isArray(value.roles) ? value.roles.map(parseRole).filter((r): r is RbacRole => r !== null) : [],
    bindings: Array.isArray(value.bindings) ? value.bindings.map(parseBinding).filter((b): b is RbacBinding => b !== null) : [],
    escalations: Array.isArray(value.escalations) ? value.escalations.map(parseEscalation).filter((e): e is EscalationFinding => e !== null) : [],
    conformance: Array.isArray(value.conformance) ? value.conformance.map(parseConformance).filter((c): c is ConformanceFinding => c !== null) : [],
    sharedRoles: Array.isArray(value.shared_roles) ? value.shared_roles.map(parseSharedRole).filter((s): s is SharedRoleFinding => s !== null) : [],
    adminCount: asNumber(value.admin_count),
    nonAdminCount: asNumber(value.non_admin_count),
  }
}

export function parseClusterMetaList(value: unknown): ClusterMeta[] {
  if (!Array.isArray(value)) {
    throw new Error('RBAC correlation endpoint returned a non-array cluster list.')
  }
  return value
    .filter(isRecord)
    .map(item => ({ id: asOptionalString(item.id) ?? '', name: asOptionalString(item.name) ?? asOptionalString(item.id) ?? '' }))
    .filter(cluster => cluster.id !== '')
}

/**
 * Thrown when the backend that should answer /api/rbac/* is not there.
 *
 * Two distinct absences produce this, and the message says which:
 *
 * - KubeSec-AFM is not deployed. The fe-signalloom API is up and detects this
 *   itself (rbac_correlation.py's _afm_failure), returning 503 with code
 *   `afm_not_deployed` and a message naming the remedy. This class carries
 *   that message through rather than re-deriving it from a status code.
 * - The fe-signalloom API itself is absent or /api/ is not proxied. Then
 *   nothing answers as the API, the SPA catch-all serves index.html with
 *   200 OK, and res.json() throws "Unexpected token '<'" — the same trap
 *   FleetUnreachableError exists for. Content-type is the discriminator: a
 *   200 that is not JSON is not an answer from this API.
 */
export class RbacUnreachableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'RbacUnreachableError'
  }
}

/** Error codes rbac_correlation.py raises whose message is already actionable. */
const BACKEND_ABSENT_CODES = new Set(['afm_not_deployed', 'afm_unreachable'])

function notTheApiError(): RbacUnreachableError {
  return new RbacUnreachableError(
    'The Signal Loom API did not respond — the request was answered by the dashboard ' +
      'itself, which means fe-signalloom is not deployed or /api/ is not proxied. ' +
      'Run `make demo-signalloom-up` to deploy it.',
  )
}

async function authedGet(path: string, token: string): Promise<unknown> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS)
  const url = `${BASE}${path}`

  try {
    const res = await fetch(url, { signal: controller.signal, headers: { Authorization: `Bearer ${token}` } })
    if (!res.ok) {
      let detail = ''
      try {
        const body: unknown = await res.json()
        if (isRecord(body) && isRecord(body.error) && typeof body.error.message === 'string') {
          const message = body.error.message
          // The API already classified this and wrote an actionable sentence.
          // Prefixing it with the URL and status buries the useful half under
          // transport trivia the reader cannot act on, so surface it alone.
          if (typeof body.error.code === 'string' && BACKEND_ABSENT_CODES.has(body.error.code)) {
            throw new RbacUnreachableError(message)
          }
          detail = ` ${message}`
        }
      } catch (error) {
        if (error instanceof RbacUnreachableError) throw error
        /* body wasn't JSON — fall back to the bare status */
      }
      throw new Error(`RBAC correlation request failed for ${url} with status ${res.status}.${detail}`)
    }

    // `res.ok` is TRUE for the SPA fallback: with no API behind /api/, nginx's
    // catch-all returns the dashboard shell with 200 OK, and the parse error
    // that follows names the symptom while hiding the cause.
    //
    // Diagnosed on an EXPLICITLY non-JSON content-type, plus a failed parse as
    // the backstop. Asserting the header must say JSON would reject a valid
    // response that simply omits it; the header is evidence when present, and
    // the parse is the evidence when it is not. nginx labels the shell
    // text/html, so the real failure is caught either way.
    const contentType = res.headers.get('content-type')
    if (contentType !== null && !contentType.includes('json')) {
      throw notTheApiError()
    }
    try {
      return await res.json()
    } catch (error) {
      if (error instanceof SyntaxError) throw notTheApiError()
      throw error
    }
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      throw new Error(`RBAC correlation request to ${url} timed out after ${FETCH_TIMEOUT_MS / 1000} seconds.`)
    }
    throw error
  } finally {
    clearTimeout(timeout)
  }
}

export async function fetchRbacClusters(token: string): Promise<ClusterMeta[]> {
  return parseClusterMetaList(await authedGet('/clusters', token))
}

export async function fetchCorrelatedRbac(token: string, clusterId: string): Promise<CorrelatedRbac> {
  return parseCorrelatedRbac(await authedGet(`/clusters/${encodeURIComponent(clusterId)}/correlated`, token))
}
