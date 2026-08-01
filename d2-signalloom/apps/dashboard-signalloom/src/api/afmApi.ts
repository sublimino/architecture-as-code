const AFM = '/afm'
const FETCH_TIMEOUT_MS = 15_000

export interface ClusterMeta { id: string; name: string }
export interface Subject { name: string; kind: string; namespace?: string }
export interface RoleRule { verbs: string[]; apiGroups: string[]; resources: string[] }
export interface Role { name: string; scope: string; namespace?: string; rules: RoleRule[] }
export interface Binding { name: string; scope: string; namespace?: string; roleRef: string; subjects: Subject[] }
export interface RBACData { subjects: Subject[]; roles: Role[]; bindings: Binding[] }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(item => typeof item === 'string')
}

function hasOptionalNamespace(value: Record<string, unknown>): value is Record<string, string | undefined> {
  return !('namespace' in value) || typeof value.namespace === 'string'
}

function isSubject(value: unknown): value is Subject {
  if (!isRecord(value) || typeof value.name !== 'string' || typeof value.kind !== 'string') {
    return false
  }
  return hasOptionalNamespace(value)
}

function isRoleRule(value: unknown): value is RoleRule {
  if (!isRecord(value)) {
    return false
  }
  return isStringArray(value.verbs) && isStringArray(value.apiGroups) && isStringArray(value.resources)
}

function isRole(value: unknown): value is Role {
  if (!isRecord(value) || typeof value.name !== 'string' || typeof value.scope !== 'string') {
    return false
  }
  if (!hasOptionalNamespace(value) || !Array.isArray(value.rules) || !value.rules.every(isRoleRule)) {
    return false
  }
  return value.scope === 'Cluster' || value.scope === 'Namespace'
}

function isBinding(value: unknown): value is Binding {
  if (!isRecord(value) || typeof value.name !== 'string' || typeof value.scope !== 'string' || typeof value.roleRef !== 'string') {
    return false
  }
  if (!hasOptionalNamespace(value) || !Array.isArray(value.subjects) || !value.subjects.every(isSubject)) {
    return false
  }
  return value.scope === 'Cluster' || value.scope === 'Namespace'
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

export function isClusterMetaArray(value: unknown): value is ClusterMeta[] {
  return Array.isArray(value) && value.every(item => {
    if (!isRecord(item)) {
      return false
    }
    return typeof item.id === 'string' && typeof item.name === 'string'
  })
}

export function isRbacData(value: unknown): value is RBACData {
  if (!isRecord(value)) {
    return false
  }
  return Array.isArray(value.subjects)
    && value.subjects.every(isSubject)
    && Array.isArray(value.roles)
    && value.roles.every(isRole)
    && Array.isArray(value.bindings)
    && value.bindings.every(isBinding)
}

export function deriveNamespaces(rbac: RBACData): string[] {
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
