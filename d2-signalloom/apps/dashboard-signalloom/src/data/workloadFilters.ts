import type { AgentResponse, DiscoveryWorkload } from '../types/api'
import { detectGitOps } from '../utils/gitops'

/**
 * Checks whether an entity (AgentResponse, DiscoveryWorkload, or raw K8s object)
 * carries GitOps labels or annotations from Flux, ArgoCD, or GitOps tooling.
 */
export function hasGitOpsMetadata(entity: unknown): boolean {
  if (!entity || typeof entity !== 'object') return false

  // 0. Reusable GitOps detection engine
  if (detectGitOps(entity).isGitOps) {
    return true
  }

  const e = entity as Record<string, any>

  // 1. Direct boolean flags
  if (e.is_gitops_managed === true || e.gitops_managed === true || e.gitops === true) {
    return true
  }

  // 2. Gather all label/annotation candidate dictionaries
  const dicts: Record<string, any>[] = []

  if (e.labels && typeof e.labels === 'object') dicts.push(e.labels)
  if (e.annotations && typeof e.annotations === 'object') dicts.push(e.annotations)

  if (e.metadata && typeof e.metadata === 'object') {
    dicts.push(e.metadata)
    if (e.metadata.labels && typeof e.metadata.labels === 'object') dicts.push(e.metadata.labels)
    if (e.metadata.annotations && typeof e.metadata.annotations === 'object') dicts.push(e.metadata.annotations)
  }

  if (e.runtime && typeof e.runtime === 'object') {
    if (e.runtime.labels && typeof e.runtime.labels === 'object') dicts.push(e.runtime.labels)
    if (e.runtime.annotations && typeof e.runtime.annotations === 'object') dicts.push(e.runtime.annotations)
    if (e.runtime.metadata && typeof e.runtime.metadata === 'object') dicts.push(e.runtime.metadata)
  }

  const gitopsKeyPatterns = [
    /toolkit\.fluxcd\.io/i,
    /fluxcd\.io/i,
    /argocd\.argoproj\.io/i,
    /argoproj\.io/i,
    /gitops/i,
  ]

  for (const dict of dicts) {
    for (const [key, val] of Object.entries(dict)) {
      const k = String(key).toLowerCase()
      const v = typeof val === 'string' ? val.toLowerCase() : String(val)

      // Key matches fluxcd, argocd, argoproj, or gitops
      if (gitopsKeyPatterns.some((pattern) => pattern.test(k))) {
        return true
      }

      // Check managed-by
      if (k === 'app.kubernetes.io/managed-by' || k === 'managed-by' || k === 'managed_by') {
        if (v.includes('flux') || v.includes('argo') || v.includes('gitops')) {
          return true
        }
      }

      // Check key "gitops" with truthy string
      if (k === 'gitops' && (v === 'true' || v === 'enabled' || v === 'yes' || v === '1')) {
        return true
      }
    }
  }

  // 3. Check selectors (e.g. in identity.selectors)
  const selectors = e.identity?.selectors || e.selectors
  if (Array.isArray(selectors)) {
    for (const sel of selectors) {
      if (typeof sel === 'string') {
        const s = sel.toLowerCase()
        if (gitopsKeyPatterns.some((p) => p.test(s))) return true
        if (
          s.includes('managed-by=flux') ||
          s.includes('managed-by:flux') ||
          s.includes('managed-by=argocd') ||
          s.includes('managed-by:argocd') ||
          s.includes('managed-by=argo') ||
          s.includes('managed-by:argo') ||
          s.includes('gitops')
        ) {
          return true
        }
      }
    }
  }

  return false
}

/**
 * Gets the workload's effective tenant name or ID.
 * Returns null if undeclared or missing.
 */
export function getWorkloadTenant(agent: Partial<AgentResponse> | null | undefined): string | null {
  if (!agent) return null
  if (agent.tenant && agent.tenant.trim() && agent.tenant !== 'undeclared') {
    return agent.tenant.trim()
  }
  if (agent.tenant_id && agent.tenant_id.trim() && agent.tenant_id !== 'undeclared') {
    return agent.tenant_id.trim()
  }
  return null
}

/**
 * Checks whether an agent's tenant does not match the active session's tenant.
 * If sessionTenant is unknown or empty, returns false.
 * If workload has no tenant / undeclared, or different tenant, returns true.
 */
export function isAgentTenantMismatch(
  agent: Partial<AgentResponse> | null | undefined,
  sessionTenant?: string | null
): boolean {
  if (!sessionTenant || !sessionTenant.trim()) return false
  const workloadTenant = getWorkloadTenant(agent)
  return workloadTenant !== sessionTenant.trim()
}

/**
 * Safely reads a value from localStorage or sessionStorage in browser or test environments.
 */
export function getSafeStorageItem(key: string): string | null {
  try {
    if (typeof window !== 'undefined' && window.localStorage && typeof window.localStorage.getItem === 'function') {
      const item = window.localStorage.getItem(key)
      if (item) return item
    }
  } catch {}
  try {
    if (typeof window !== 'undefined' && window.sessionStorage && typeof window.sessionStorage.getItem === 'function') {
      const item = window.sessionStorage.getItem(key)
      if (item) return item
    }
  } catch {}
  return null
}
