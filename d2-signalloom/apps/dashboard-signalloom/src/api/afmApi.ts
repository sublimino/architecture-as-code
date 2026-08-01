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
