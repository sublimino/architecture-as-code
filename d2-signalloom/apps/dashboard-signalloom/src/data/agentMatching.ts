import type { AgentResponse } from '../types/api'

/**
 * Correlates a discovered account or workload identifier with an enrolled agent
 * in the Signal Loom registry.
 *
 * Matching strategy:
 * 1. Exact ID match
 * 2. Exact agent name or service account match
 * 3. Normalized prefix strip (e.g. 'svc-billing-sync' matches 'agent-billing-sync' or 'billing-sync')
 * 4. Unique owner email correlation
 */
export function findMatchingAgent(
  account: { account_name: string; id?: string; owner_email?: string | null },
  agents: AgentResponse[]
): AgentResponse | undefined {
  if (!agents || agents.length === 0 || !account) return undefined

  const targetName = (account.account_name || '').trim().toLowerCase()
  const targetId = (account.id || '').trim().toLowerCase()
  const targetOwner = (account.owner_email || '').trim().toLowerCase()

  // 1. Exact ID match
  if (targetId) {
    const byId = agents.find((a) => a.id.toLowerCase() === targetId)
    if (byId) return byId
  }

  // 2. Exact name, ID, or service account match
  const exact = agents.find((a) => {
    if (a.name.toLowerCase() === targetName) return true
    if (a.id.toLowerCase() === targetName) return true
    if (a.service_account && a.service_account.toLowerCase() === targetName) return true
    if (a.runtime?.service_account && a.runtime.service_account.toLowerCase() === targetName) return true
    return false
  })
  if (exact) return exact

  // 3. Normalized prefix strip (e.g. "svc-billing-sync" vs "agent-billing-sync" or "billing-sync")
  const strippedAccount = targetName.replace(/^(svc-|service-|agent-|kagent-)/, '')
  if (strippedAccount.length >= 3) {
    const slugMatch = agents.find((a) => {
      const strippedAgentName = a.name.toLowerCase().replace(/^(svc-|service-|agent-|kagent-)/, '')
      const strippedAgentId = a.id.toLowerCase().replace(/^(svc-|service-|agent-|kagent-)/, '')
      return (
        strippedAgentName === strippedAccount ||
        strippedAgentId === strippedAccount ||
        strippedAgentName.includes(strippedAccount) ||
        strippedAccount.includes(strippedAgentName) ||
        strippedAgentId.includes(strippedAccount) ||
        strippedAccount.includes(strippedAgentId)
      )
    })
    if (slugMatch) return slugMatch
  }

  // 4. Owner email match if unique
  if (targetOwner) {
    const byOwner = agents.filter((a) => a.owner && a.owner.toLowerCase() === targetOwner)
    if (byOwner.length === 1) return byOwner[0]
  }

  return undefined
}
