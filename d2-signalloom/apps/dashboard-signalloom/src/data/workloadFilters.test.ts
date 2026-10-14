import { describe, it, expect } from 'vitest'
import { hasGitOpsMetadata, getWorkloadTenant, isAgentTenantMismatch } from './workloadFilters'
import type { AgentResponse, DiscoveryWorkload } from '../types/api'

describe('workloadFilters', () => {
  describe('hasGitOpsMetadata', () => {
    it('returns false for non-gitops entities', () => {
      expect(hasGitOpsMetadata(null)).toBe(false)
      expect(hasGitOpsMetadata({})).toBe(false)
      expect(hasGitOpsMetadata({ labels: { app: 'invoice-bot' } })).toBe(false)
    })

    it('identifies Flux toolkit labels and annotations', () => {
      expect(hasGitOpsMetadata({ labels: { 'kustomize.toolkit.fluxcd.io/name': 'apps' } })).toBe(true)
      expect(hasGitOpsMetadata({ annotations: { 'kustomize.toolkit.fluxcd.io/reconcile': 'disabled' } })).toBe(true)
      expect(hasGitOpsMetadata({ metadata: { labels: { 'helm.toolkit.fluxcd.io/name': 'ingress' } } })).toBe(true)
      expect(hasGitOpsMetadata({ runtime: { annotations: { 'toolkit.fluxcd.io/role': 'tenant' } } })).toBe(true)
    })

    it('identifies ArgoCD labels and annotations', () => {
      expect(hasGitOpsMetadata({ labels: { 'argocd.argoproj.io/instance': 'guestbook' } })).toBe(true)
      expect(hasGitOpsMetadata({ annotations: { 'argocd.argoproj.io/tracking-id': 'guestbook:apps/Deployment:default/guestbook' } })).toBe(true)
      expect(hasGitOpsMetadata({ metadata: { annotations: { 'argoproj.io/sync-wave': '1' } } })).toBe(true)
    })

    it('identifies managed-by labels', () => {
      expect(hasGitOpsMetadata({ labels: { 'app.kubernetes.io/managed-by': 'flux' } })).toBe(true)
      expect(hasGitOpsMetadata({ labels: { 'app.kubernetes.io/managed-by': 'argocd' } })).toBe(true)
    })

    it('identifies selectors in identity', () => {
      expect(hasGitOpsMetadata({ identity: { selectors: ['k8s:pod-label:kustomize.toolkit.fluxcd.io/name=apps'] } })).toBe(true)
      expect(hasGitOpsMetadata({ identity: { selectors: ['app=cardvault', 'managed-by=flux'] } })).toBe(true)
      expect(hasGitOpsMetadata({ identity: { selectors: ['app=cardvault'] } })).toBe(false)
    })

    it('identifies boolean gitops flags', () => {
      expect(hasGitOpsMetadata({ is_gitops_managed: true })).toBe(true)
      expect(hasGitOpsMetadata({ gitops_managed: true })).toBe(true)
      expect(hasGitOpsMetadata({ gitops: true })).toBe(true)
    })
  })

  describe('getWorkloadTenant', () => {
    it('extracts tenant when declared', () => {
      expect(getWorkloadTenant({ tenant: 'tenant-prod' } as AgentResponse)).toBe('tenant-prod')
      expect(getWorkloadTenant({ tenant: null, tenant_id: 'tenant-alpha' } as AgentResponse)).toBe('tenant-alpha')
      expect(getWorkloadTenant({ tenant: 'tenant-override', tenant_id: 'tenant-base' } as AgentResponse)).toBe('tenant-override')
    })

    it('returns null for undeclared or missing tenant', () => {
      expect(getWorkloadTenant(null)).toBe(null)
      expect(getWorkloadTenant({ tenant: null, tenant_id: 'undeclared' } as AgentResponse)).toBe(null)
      expect(getWorkloadTenant({ tenant: '', tenant_id: '' } as AgentResponse)).toBe(null)
    })
  })

  describe('isAgentTenantMismatch', () => {
    it('returns false when no session tenant is provided', () => {
      expect(isAgentTenantMismatch({ tenant: 'tenant-2' } as AgentResponse, null)).toBe(false)
      expect(isAgentTenantMismatch({ tenant: 'tenant-2' } as AgentResponse, '')).toBe(false)
    })

    it('returns false when workload tenant matches session tenant', () => {
      expect(isAgentTenantMismatch({ tenant: 'tenant-1' } as AgentResponse, 'tenant-1')).toBe(false)
      expect(isAgentTenantMismatch({ tenant: null, tenant_id: 'tenant-1' } as AgentResponse, 'tenant-1')).toBe(false)
    })

    it('returns true when workload tenant differs from session tenant', () => {
      expect(isAgentTenantMismatch({ tenant: 'tenant-2' } as AgentResponse, 'tenant-1')).toBe(true)
      expect(isAgentTenantMismatch({ tenant: null, tenant_id: 'tenant-2' } as AgentResponse, 'tenant-1')).toBe(true)
    })

    it('returns true when workload has undeclared or missing tenant', () => {
      expect(isAgentTenantMismatch({ tenant: null, tenant_id: 'undeclared' } as AgentResponse, 'tenant-1')).toBe(true)
      expect(isAgentTenantMismatch({} as AgentResponse, 'tenant-1')).toBe(true)
    })
  })
})
