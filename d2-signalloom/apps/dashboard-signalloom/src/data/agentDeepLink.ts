import type { AgentResponse } from '../types/api'

export type DeepLinkKind = 'agent' | 'selector' | 'instance'

export interface AgentNavigationTarget {
  kind: DeepLinkKind
  agentId?: string
  selector?: string
  instanceUid?: string
  tab?: string
  label?: string
}

export interface DeepLinkOptions {
  tab?: string
  instance?: string
  highlight?: string
  hash?: string
  queryParam?: 'search' | 'selector'
  availableAgents?: AgentResponse[]
}

export interface DeepLinkResult {
  pathname: string
  search: string
  hash: string
  href: string
  isDirectDossier: boolean
  isFilteredInventory: boolean
  resolvedId?: string
  instanceUid?: string
}

/**
 * Normalizes common selector prefix variants to canonical lowercase forms.
 */
export function normalizeSelectorPrefix(prefix: string): string {
  const p = (prefix || '').trim().toLowerCase()
  if (p === 'serviceaccount') return 'sa'
  if (p === 'namespace') return 'ns'
  if (p === 'uuid') return 'id'
  if (p === 'pod_uid') return 'instance'
  if (p === 'pod') return 'instance'
  return p
}

/**
 * Formats a raw selector string into a concise, human-readable display label.
 * e.g. "k8s:sa:agent-trust-planner" -> "sa: agent-trust-planner"
 * e.g. "id:UUID-23-1245-124" -> "id: UUID-23-1245-124"
 * e.g. "spiffe://.../agent/planner" -> "spiffe: planner"
 */
export function formatSelectorLabel(selector: string): string {
  const s = (selector || '').trim()
  if (!s) return ''

  if (s.startsWith('spiffe://')) {
    const parts = s.split('/')
    const last = parts[parts.length - 1]
    return last ? `spiffe: ${last}` : s
  }

  if (s.toLowerCase().startsWith('k8s:')) {
    const sub = s.slice(4) // e.g. "sa:planner" or "ns:acme"
    const colon = sub.indexOf(':')
    if (colon > 0) {
      const prefix = sub.slice(0, colon)
      const val = sub.slice(colon + 1)
      return `${prefix}: ${val}`
    }
    return sub
  }

  const colonIdx = s.indexOf(':')
  if (colonIdx > 0 && !s.includes('://')) {
    const prefix = s.slice(0, colonIdx)
    const val = s.slice(colonIdx + 1)
    return `${prefix}: ${val}`
  }

  return s
}

/**
 * Resolves a raw string into an AgentNavigationTarget.
 * If availableAgents is provided, checks whether the input matches a registered agent ID,
 * name, service account, or SPIFFE ID.
 */
export function resolveDeepLinkTarget(
  rawInput: string,
  availableAgents?: AgentResponse[],
): AgentNavigationTarget {
  const trimmed = (rawInput || '').trim()
  if (!trimmed) {
    return { kind: 'selector', selector: '' }
  }

  const colonIdx = trimmed.indexOf(':')
  const prefix = colonIdx > 0 ? trimmed.slice(0, colonIdx).toLowerCase() : ''
  const val = colonIdx > 0 ? trimmed.slice(colonIdx + 1).trim() : trimmed

  // Explicit ID or UUID
  if (prefix === 'id' || prefix === 'uuid') {
    return { kind: 'agent', agentId: val, label: val }
  }

  // Explicit Pod or Instance
  if (prefix === 'instance' || prefix === 'pod' || prefix === 'pod_uid') {
    // If we have available agents, see if any has this pod_uid
    if (availableAgents && availableAgents.length > 0) {
      const match = availableAgents.find(
        (a) =>
          a.runtime?.pod_uid === val ||
          a.runtime?.pod_name === val ||
          a.pod_uid === val,
      )
      if (match) {
        return {
          kind: 'agent',
          agentId: match.id,
          instanceUid: val,
          label: match.name || match.id,
        }
      }
    }
    return { kind: 'instance', instanceUid: val, selector: trimmed, label: val }
  }

  // If availableAgents is provided, test if rawInput or val matches an agent directly
  if (availableAgents && availableAgents.length > 0) {
    // Exact ID or bare ID without tenant prefix
    const agentById = availableAgents.find(
      (a) =>
        a.id === trimmed ||
        a.id === val ||
        a.id.replace(/^[^:]+:/, '') === trimmed ||
        a.id.replace(/^[^:]+:/, '') === val,
    )
    if (agentById) {
      return { kind: 'agent', agentId: agentById.id, label: agentById.name || agentById.id }
    }

    // Match by service account if prefix is sa or k8s:sa
    if (prefix === 'sa' || prefix === 'serviceaccount' || trimmed.toLowerCase().startsWith('k8s:sa:')) {
      const saVal = trimmed.toLowerCase().startsWith('k8s:sa:') ? trimmed.slice(7).trim() : val
      const agentBySa = availableAgents.filter(
        (a) =>
          (a.service_account && a.service_account.toLowerCase() === saVal.toLowerCase()) ||
          (a.runtime?.service_account && a.runtime.service_account.toLowerCase() === saVal.toLowerCase()),
      )
      if (agentBySa.length === 1) {
        return { kind: 'agent', agentId: agentBySa[0].id, label: agentBySa[0].name || agentBySa[0].id }
      }
    }

    // Match by name
    const agentByName = availableAgents.find(
      (a) => a.name && a.name.toLowerCase() === trimmed.toLowerCase(),
    )
    if (agentByName) {
      return { kind: 'agent', agentId: agentByName.id, label: agentByName.name }
    }
  }

  // Common agent ID prefixes (e.g. "agent-", "kagent-", UUID, or tenant-prefixed IDs)
  if (
    trimmed.startsWith('agent-') ||
    trimmed.startsWith('kagent-') ||
    val.startsWith('agent-') ||
    val.startsWith('kagent-') ||
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trimmed) ||
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(val)
  ) {
    return { kind: 'agent', agentId: trimmed, label: trimmed }
  }

  // Fallback: general query selector
  return { kind: 'selector', selector: trimmed, label: formatSelectorLabel(trimmed) }
}

/**
 * Builds a DeepLinkResult from a string or structured AgentNavigationTarget.
 */
export function buildAgentDeepLink(
  target: string | AgentNavigationTarget,
  options?: DeepLinkOptions,
): DeepLinkResult {
  const resolvedTarget: AgentNavigationTarget =
    typeof target === 'string'
      ? resolveDeepLinkTarget(target, options?.availableAgents)
      : target

  const tab = options?.tab || resolvedTarget.tab || 'overview'
  const instanceUid = options?.instance || resolvedTarget.instanceUid
  const hash = options?.hash ? (options.hash.startsWith('#') ? options.hash : `#${options.hash}`) : ''

  // Case 1: Direct Agent Dossier
  if (resolvedTarget.kind === 'agent' && resolvedTarget.agentId) {
    const rawId = resolvedTarget.agentId.replace(/^(id|uuid):/i, '')
    const pathname = `/agents/${encodeURIComponent(rawId)}`
    const searchParams = new URLSearchParams()
    if (tab) searchParams.set('tab', tab)
    if (instanceUid) searchParams.set('instance', instanceUid)
    if (options?.highlight) searchParams.set('highlight', options.highlight)

    const search = searchParams.toString() ? `?${searchParams.toString()}` : ''
    return {
      pathname,
      search,
      hash,
      href: `${pathname}${search}${hash}`,
      isDirectDossier: true,
      isFilteredInventory: false,
      resolvedId: rawId,
      instanceUid,
    }
  }

  // Case 2: Filtered Inventory via Selector / Search
  const selector = resolvedTarget.selector || (typeof target === 'string' ? target : '')
  const pathname = '/agents'
  const searchParams = new URLSearchParams()
  const isStructured = /[:=,]/.test(selector)
  const defaultParam = isStructured ? 'selector' : 'search'
  const paramKey = options?.queryParam || defaultParam
  if (selector) searchParams.set(paramKey, selector)
  if (instanceUid) searchParams.set('instance', instanceUid)
  if (options?.highlight) searchParams.set('highlight', options.highlight)

  const search = searchParams.toString() ? `?${searchParams.toString()}` : ''
  return {
    pathname,
    search,
    hash,
    href: `${pathname}${search}${hash}`,
    isDirectDossier: false,
    isFilteredInventory: true,
    instanceUid,
  }
}
