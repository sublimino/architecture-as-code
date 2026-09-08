import { describe, it, expect } from 'vitest'
import {
  buildAgentDeepLink,
  formatSelectorLabel,
  normalizeSelectorPrefix,
  resolveDeepLinkTarget,
} from './agentDeepLink'
import type { AgentResponse } from '../types/api'

describe('agentDeepLink helper', () => {
  const mockAgents: AgentResponse[] = [
    {
      id: 'tenant-demo:agent-inventory',
      name: 'Inventory Agent',
      type: 'Signal Loom Built',
      owner: 'demo-user',
      tenant_id: 'tenant-demo',
      lifecycle_state: 'active',
      last_transition_at: null,
      eu_ai_act_risk_class: 'minimal',
      compliance_summary: { total_controls: 10, passing: 10, failing: 0, pending: 0, posture_score: 100 },
      created_at: '2026-06-01T09:00:00Z',
      service_account: 'agent-inventory-sa',
      namespace: 'agent-inventory-ns',
      runtime: {
        cluster_id: 'osramp-control-plane',
        namespace: 'agent-inventory-ns',
        service_account: 'agent-inventory-sa',
        pod_name: 'agent-inventory-77b8-abc',
        pod_uid: 'uid-inventory-pod-123',
      },
    },
    {
      id: 'tenant-demo:agent-triage',
      name: 'Triage Agent',
      type: 'Signal Loom Built',
      owner: 'demo-user',
      tenant_id: 'tenant-demo',
      lifecycle_state: 'active',
      last_transition_at: null,
      eu_ai_act_risk_class: 'high',
      compliance_summary: { total_controls: 12, passing: 8, failing: 2, pending: 2, posture_score: 68 },
      created_at: '2026-06-01T09:00:00Z',
      service_account: 'agent-triage-sa',
      namespace: 'agent-triage-ns',
      runtime: {
        cluster_id: 'osramp-control-plane',
        namespace: 'agent-triage-ns',
        service_account: 'agent-triage-sa',
        pod_name: 'agent-triage-88c9-def',
        pod_uid: 'uid-triage-pod-456',
      },
    },
  ]

  // ─── Direct Dossier Links ──────────────────────────────────────────────────

  describe('direct dossier navigation', () => {
    it('creates a direct dossier link for a bare agent ID', () => {
      const link = buildAgentDeepLink('agent-triage')
      expect(link.isDirectDossier).toBe(true)
      expect(link.isFilteredInventory).toBe(false)
      expect(link.pathname).toBe('/agents/agent-triage')
      expect(link.search).toBe('?tab=overview')
      expect(link.href).toBe('/agents/agent-triage?tab=overview')
    })

    it('normalizes id: and uuid: prefixes into direct dossier routes', () => {
      const link1 = buildAgentDeepLink('id:agent-triage')
      expect(link1.isDirectDossier).toBe(true)
      expect(link1.pathname).toBe('/agents/agent-triage')

      const link2 = buildAgentDeepLink('uuid:550e8400-e29b-41d4-a716-446655440000')
      expect(link2.isDirectDossier).toBe(true)
      expect(link2.pathname).toBe('/agents/550e8400-e29b-41d4-a716-446655440000')
    })

    it('supports custom tab options', () => {
      const link = buildAgentDeepLink('agent-triage', { tab: 'runtime' })
      expect(link.search).toBe('?tab=runtime')
      expect(link.href).toBe('/agents/agent-triage?tab=runtime')
    })

    it('appends instance UID query parameter when provided in options or target', () => {
      const link = buildAgentDeepLink('agent-triage', { instance: 'uid-custom-instance-999' })
      expect(link.search).toBe('?tab=overview&instance=uid-custom-instance-999')
      expect(link.instanceUid).toBe('uid-custom-instance-999')
    })

    it('supports hash anchors and highlight query params', () => {
      const link = buildAgentDeepLink('agent-triage', { hash: 'credentials', highlight: 'token' })
      expect(link.search).toBe('?tab=overview&highlight=token')
      expect(link.hash).toBe('#credentials')
      expect(link.href).toBe('/agents/agent-triage?tab=overview&highlight=token#credentials')
    })
  })

  // ─── Filtered Inventory Selector Links ─────────────────────────────────────

  describe('filtered inventory selector navigation', () => {
    it('creates selector routes for sa: and k8s:sa: selectors', () => {
      const link1 = buildAgentDeepLink('sa:planner')
      expect(link1.isDirectDossier).toBe(false)
      expect(link1.isFilteredInventory).toBe(true)
      expect(link1.pathname).toBe('/agents')
      expect(link1.search).toBe('?selector=sa%3Aplanner')

      const link2 = buildAgentDeepLink('k8s:sa:planner')
      expect(link2.search).toBe('?selector=k8s%3Asa%3Aplanner')
    })

    it('creates selector routes for namespace selectors', () => {
      const link1 = buildAgentDeepLink('ns:payments')
      expect(link1.search).toBe('?selector=ns%3Apayments')

      const link2 = buildAgentDeepLink('k8s:ns:agent-trust-acme-payments')
      expect(link2.search).toBe('?selector=k8s%3Ans%3Aagent-trust-acme-payments')
    })

    it('creates selector routes for cluster, framework, and model', () => {
      const link1 = buildAgentDeepLink('cluster:osramp')
      expect(link1.search).toBe('?selector=cluster%3Aosramp')

      const link2 = buildAgentDeepLink('framework:eu-ai-act')
      expect(link2.search).toBe('?selector=framework%3Aeu-ai-act')

      const link3 = buildAgentDeepLink('model:gpt-4o')
      expect(link3.search).toBe('?selector=model%3Agpt-4o')
    })

    it('creates selector routes for SPIFFE IDs', () => {
      const spiffe = 'spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner'
      const link = buildAgentDeepLink(spiffe)
      expect(link.isDirectDossier).toBe(false)
      expect(link.search).toBe(`?selector=${encodeURIComponent(spiffe)}`)
    })

    it('creates selector routes for Kubernetes label queries', () => {
      const link = buildAgentDeepLink('app=cardvault,tier=backend')
      expect(link.search).toBe('?selector=app%3Dcardvault%2Ctier%3Dbackend')
    })
  })

  // ─── Available Agents Resolution ───────────────────────────────────────────

  describe('resolveDeepLinkTarget with availableAgents', () => {
    it('resolves unique service account to direct agent dossier when availableAgents provided', () => {
      const target = resolveDeepLinkTarget('sa:agent-inventory-sa', mockAgents)
      expect(target.kind).toBe('agent')
      expect(target.agentId).toBe('tenant-demo:agent-inventory')

      const link = buildAgentDeepLink('sa:agent-inventory-sa', { availableAgents: mockAgents })
      expect(link.isDirectDossier).toBe(true)
      expect(link.pathname).toBe('/agents/tenant-demo%3Aagent-inventory')
    })

    it('resolves pod instance to direct agent dossier with instanceUid attached', () => {
      const target = resolveDeepLinkTarget('pod:uid-triage-pod-456', mockAgents)
      expect(target.kind).toBe('agent')
      expect(target.agentId).toBe('tenant-demo:agent-triage')
      expect(target.instanceUid).toBe('uid-triage-pod-456')

      const link = buildAgentDeepLink('pod:uid-triage-pod-456', { availableAgents: mockAgents })
      expect(link.isDirectDossier).toBe(true)
      expect(link.instanceUid).toBe('uid-triage-pod-456')
      expect(link.search).toBe('?tab=overview&instance=uid-triage-pod-456')
    })

    it('falls back to selector when service account matches no registered agent', () => {
      const target = resolveDeepLinkTarget('sa:unknown-sa', mockAgents)
      expect(target.kind).toBe('selector')
      expect(target.selector).toBe('sa:unknown-sa')
    })
  })

  // ─── formatSelectorLabel & normalizeSelectorPrefix ─────────────────────────

  describe('formatSelectorLabel', () => {
    it('formats k8s:sa:planner to sa: planner', () => {
      expect(formatSelectorLabel('k8s:sa:planner')).toBe('sa: planner')
    })

    it('formats k8s:ns:payments to ns: payments', () => {
      expect(formatSelectorLabel('k8s:ns:payments')).toBe('ns: payments')
    })

    it('formats id:UUID-123 to id: UUID-123', () => {
      expect(formatSelectorLabel('id:UUID-123')).toBe('id: UUID-123')
    })

    it('formats SPIFFE URI to spiffe: <tail>', () => {
      expect(formatSelectorLabel('spiffe://signalloom.demo/agent/planner')).toBe('spiffe: planner')
    })

    it('returns empty string for empty input', () => {
      expect(formatSelectorLabel('')).toBe('')
    })
  })

  describe('normalizeSelectorPrefix', () => {
    it('normalizes prefix synonyms', () => {
      expect(normalizeSelectorPrefix('serviceaccount')).toBe('sa')
      expect(normalizeSelectorPrefix('namespace')).toBe('ns')
      expect(normalizeSelectorPrefix('uuid')).toBe('id')
      expect(normalizeSelectorPrefix('pod')).toBe('instance')
      expect(normalizeSelectorPrefix('pod_uid')).toBe('instance')
      expect(normalizeSelectorPrefix('cluster')).toBe('cluster')
    })
  })
})
