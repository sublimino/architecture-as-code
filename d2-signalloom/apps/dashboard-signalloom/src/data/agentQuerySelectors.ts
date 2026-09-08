import type { AgentResponse } from '../types/api'

export type QueryPrefix =
  | 'id'
  | 'uuid'
  | 'name'
  | 'sa'
  | 'serviceaccount'
  | 'spiffe'
  | 'ns'
  | 'namespace'
  | 'pod'
  | 'pod_uid'
  | 'cluster'
  | 'framework'
  | 'model'
  | 'type'
  | 'owner'
  | 'state'
  | 'label'
  | 'k8s'
  | 'raw'

export interface QueryClause {
  prefix: QueryPrefix
  key?: string
  value: string
  raw: string
  isInstanceSelector: boolean
}

export interface ParsedAgentQuery {
  raw: string
  clauses: QueryClause[]
  isStructured: boolean
  hasInstanceSelector: boolean
}

/**
 * Tokenizes and parses a query string into structured query clauses.
 * Supports:
 * - Prefix syntax: `id:UUID-...`, `name:...`, `sa:...`, `spiffe:...`, `ns:...`, `pod:...`
 * - Kubernetes label syntax: `label:app=cardvault`, `app=cardvault`, `k8s:sa:planner`
 * - Multi-term compound clauses separated by whitespace or commas (evaluated with AND)
 * - Plain text fallback for unstructured search queries
 */
export function parseAgentSelectorQuery(input: string): ParsedAgentQuery {
  const trimmed = (input || '').trim()
  if (!trimmed) {
    return { raw: '', clauses: [], isStructured: false, hasInstanceSelector: false }
  }

  // Split on whitespace or commas, keeping quoted tokens if any
  // e.g. "sa:planner ns:acme" or "app=cardvault,tier=backend"
  const tokens: string[] = []
  const regex = /(?:[^\s,"]+|"[^"]*")+/g
  let match: RegExpExecArray | null
  while ((match = regex.exec(trimmed)) !== null) {
    const token = match[0].replace(/^"|"$/g, '').trim()
    if (token) tokens.push(token)
  }

  const clauses: QueryClause[] = []
  let isStructured = false
  let hasInstanceSelector = false

  for (const token of tokens) {
    const colonIdx = token.indexOf(':')
    const eqIdx = token.indexOf('=')

    if (token.toLowerCase().startsWith('k8s:')) {
      // e.g. k8s:sa:planner or k8s:ns:agent-trust or k8s:pod-label:app=cardvault
      clauses.push({
        prefix: 'k8s',
        value: token,
        raw: token,
        isInstanceSelector: true,
      })
      isStructured = true
      hasInstanceSelector = true
      continue
    }

    if (colonIdx > 0 && (eqIdx === -1 || colonIdx < eqIdx)) {
      const prefixCandidate = token.slice(0, colonIdx).toLowerCase()
      const valuePart = token.slice(colonIdx + 1).trim()

      switch (prefixCandidate) {
        case 'id':
        case 'uuid':
          clauses.push({ prefix: 'id', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'name':
          clauses.push({ prefix: 'name', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'sa':
        case 'serviceaccount':
          clauses.push({ prefix: 'sa', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'spiffe':
          clauses.push({ prefix: 'spiffe', value: valuePart, raw: token, isInstanceSelector: true })
          isStructured = true
          hasInstanceSelector = true
          break
        case 'ns':
        case 'namespace':
          clauses.push({ prefix: 'ns', value: valuePart, raw: token, isInstanceSelector: true })
          isStructured = true
          hasInstanceSelector = true
          break
        case 'pod':
        case 'pod_uid':
        case 'poduid':
          clauses.push({ prefix: 'pod', value: valuePart, raw: token, isInstanceSelector: true })
          isStructured = true
          hasInstanceSelector = true
          break
        case 'cluster':
          clauses.push({ prefix: 'cluster', value: valuePart, raw: token, isInstanceSelector: true })
          isStructured = true
          hasInstanceSelector = true
          break
        case 'framework':
          clauses.push({ prefix: 'framework', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'model':
          clauses.push({ prefix: 'model', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'type':
          clauses.push({ prefix: 'type', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'owner':
          clauses.push({ prefix: 'owner', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'state':
        case 'lifecycle':
          clauses.push({ prefix: 'state', value: valuePart, raw: token, isInstanceSelector: false })
          isStructured = true
          break
        case 'label': {
          const lEq = valuePart.indexOf('=')
          const key = lEq > 0 ? valuePart.slice(0, lEq).trim() : undefined
          const val = lEq > 0 ? valuePart.slice(lEq + 1).trim() : valuePart
          clauses.push({ prefix: 'label', key, value: val, raw: token, isInstanceSelector: true })
          isStructured = true
          hasInstanceSelector = true
          break
        }
        default:
          // Unrecognized prefix treated as raw text
          clauses.push({ prefix: 'raw', value: token, raw: token, isInstanceSelector: false })
          break
      }
    } else if (eqIdx > 0) {
      // Key=value syntax without "label:" prefix (e.g. app=cardvault or env=production)
      const key = token.slice(0, eqIdx).trim()
      const val = token.slice(eqIdx + 1).trim()
      clauses.push({ prefix: 'label', key, value: val, raw: token, isInstanceSelector: true })
      isStructured = true
      hasInstanceSelector = true
    } else {
      // Plain keyword query
      clauses.push({ prefix: 'raw', value: token, raw: token, isInstanceSelector: false })
    }
  }

  return {
    raw: trimmed,
    clauses,
    isStructured,
    hasInstanceSelector,
  }
}

/**
 * Matches a single agent against a query clause.
 */
function matchClause(agent: AgentResponse, clause: QueryClause): boolean {
  const val = clause.value.toLowerCase()

  switch (clause.prefix) {
    case 'id':
    case 'uuid': {
      const cleanVal = val.replace(/^(id:|uuid:)/, '')
      return (
        agent.id.toLowerCase() === cleanVal ||
        agent.id.toLowerCase().replace(/^[^:]+:/, '') === cleanVal ||
        agent.id.toLowerCase().includes(cleanVal)
      )
    }
    case 'name':
      return (agent.name || '').toLowerCase().includes(val)
    case 'sa':
    case 'serviceaccount': {
      const directSa = (agent.service_account || '').toLowerCase()
      const runtimeSa = (agent.runtime?.service_account || '').toLowerCase()
      return directSa === val || runtimeSa === val || directSa.includes(val) || runtimeSa.includes(val)
    }
    case 'spiffe': {
      const spiffeId = (agent.identity?.spiffe_id || '').toLowerCase()
      return spiffeId.includes(val)
    }
    case 'ns':
    case 'namespace': {
      const ns = (agent.runtime?.namespace ?? agent.namespace ?? '').toLowerCase()
      return ns === val || ns.includes(val)
    }
    case 'pod':
    case 'pod_uid': {
      const podUid = (agent.pod_uid ?? agent.runtime?.pod_uid ?? '').toLowerCase()
      const podName = (agent.runtime?.pod_name ?? '').toLowerCase()
      return podUid === val || podName === val || podUid.includes(val) || podName.includes(val)
    }
    case 'cluster': {
      const cluster = (agent.runtime?.cluster_id ?? '').toLowerCase()
      return cluster === val || cluster.includes(val)
    }
    case 'framework': {
      const fw = (agent.runtime?.framework ?? agent.framework ?? '').toLowerCase()
      return fw.includes(val)
    }
    case 'model': {
      const m = (agent.model_name ?? agent.runtime?.model ?? '').toLowerCase()
      return m.includes(val)
    }
    case 'type': {
      const t = (agent.type ?? '').toLowerCase()
      return t.includes(val)
    }
    case 'owner': {
      const o = (agent.owner ?? agent.responsibility?.owner_name ?? '').toLowerCase()
      return o.includes(val)
    }
    case 'state': {
      return agent.lifecycle_state.toLowerCase() === val
    }
    case 'label': {
      // Check in identity selectors or metadata
      const selectors = (agent.identity?.selectors || []).map((s) => s.toLowerCase())
      if (clause.key) {
        const fullPair = `${clause.key.toLowerCase()}=${val}`
        const colonPair = `${clause.key.toLowerCase()}:${val}`
        if (selectors.some((s) => s.includes(fullPair) || s.includes(colonPair))) return true
        // Also check runtime properties
        if (clause.key.toLowerCase() === 'app' && (agent.name.toLowerCase().includes(val) || agent.id.toLowerCase().includes(val))) return true
        if (clause.key.toLowerCase() === 'ns' && (agent.runtime?.namespace ?? agent.namespace ?? '').toLowerCase() === val) return true
        if (clause.key.toLowerCase() === 'sa' && (agent.runtime?.service_account ?? agent.service_account ?? '').toLowerCase() === val) return true
        return false
      }
      return selectors.some((s) => s.includes(val))
    }
    case 'k8s': {
      // e.g. k8s:sa:planner or k8s:ns:agent-trust-acme-payments
      const selectors = (agent.identity?.selectors || []).map((s) => s.toLowerCase())
      if (selectors.some((s) => s === val || s.includes(val))) return true
      const sa = (agent.runtime?.service_account ?? agent.service_account ?? '').toLowerCase()
      const ns = (agent.runtime?.namespace ?? agent.namespace ?? '').toLowerCase()
      if (val.startsWith('k8s:sa:') && sa && val.slice(7) === sa) return true
      if (val.startsWith('k8s:ns:') && ns && val.slice(7) === ns) return true
      return false
    }
    case 'raw':
    default: {
      return (
        (agent.name ?? '').toLowerCase().includes(val) ||
        agent.id.toLowerCase().includes(val) ||
        (agent.type ?? '').toLowerCase().includes(val) ||
        (agent.owner ?? '').toLowerCase().includes(val) ||
        (agent.runtime?.namespace ?? agent.namespace ?? '').toLowerCase().includes(val) ||
        (agent.runtime?.framework ?? agent.framework ?? '').toLowerCase().includes(val) ||
        (agent.runtime?.service_account ?? agent.service_account ?? '').toLowerCase().includes(val) ||
        (agent.responsibility?.owner_name ?? '').toLowerCase().includes(val) ||
        (agent.responsibility?.team ?? '').toLowerCase().includes(val) ||
        (agent.identity?.spiffe_id ?? '').toLowerCase().includes(val) ||
        (agent.identity?.selectors ?? []).some((s) => s.toLowerCase().includes(val))
      )
    }
  }
}

/**
 * Evaluates whether an agent matches a query string or parsed query.
 * All clauses are evaluated with AND logic.
 */
export function matchAgentByQuery(
  agent: AgentResponse,
  query: string | ParsedAgentQuery
): boolean {
  if (!agent) return false
  const parsed = typeof query === 'string' ? parseAgentSelectorQuery(query) : query
  if (parsed.clauses.length === 0) return true

  return parsed.clauses.every((clause) => matchClause(agent, clause))
}

export interface AgentResolutionResult {
  matchedAgent?: AgentResponse
  isExactInstance: boolean
  allMatches: AgentResponse[]
  matchedInstanceDetails?: {
    podName?: string | null
    podUid?: string | null
    namespace?: string | null
    serviceAccount?: string | null
    spiffeId?: string | null
  }
}

/**
 * Resolves an agent or specific instance from an array of agents given a selector or query.
 */
export function resolveAgentOrInstance(
  agents: AgentResponse[],
  query: string
): AgentResolutionResult {
  const parsed = parseAgentSelectorQuery(query)
  if (parsed.clauses.length === 0 || agents.length === 0) {
    return { isExactInstance: false, allMatches: [] }
  }

  const matches = agents.filter((a) => matchAgentByQuery(a, parsed))
  if (matches.length === 0) {
    return { isExactInstance: false, allMatches: [] }
  }

  const best = matches[0]
  const isExactInstance =
    parsed.hasInstanceSelector ||
    Boolean(
      best.runtime?.pod_uid ||
      best.pod_uid ||
      (best.runtime?.namespace && parsed.clauses.some((c) => c.prefix === 'ns'))
    )

  return {
    matchedAgent: best,
    isExactInstance,
    allMatches: matches,
    matchedInstanceDetails: {
      podName: best.runtime?.pod_name,
      podUid: best.runtime?.pod_uid ?? best.pod_uid,
      namespace: best.runtime?.namespace ?? best.namespace,
      serviceAccount: best.runtime?.service_account ?? best.service_account,
      spiffeId: best.identity?.spiffe_id,
    },
  }
}
