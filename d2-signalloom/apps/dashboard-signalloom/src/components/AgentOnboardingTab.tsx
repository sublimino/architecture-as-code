import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import type { AgentResponse } from '../types/api'
import { getAgentWorkloadSecurityProfile } from './agents/ClaimModal'
import { colors } from '../styles/tokens'
import { useAuth0 } from '../auth/oidc'
import { detectGitOps } from '../utils/gitops'

export interface AgentOnboardingTabProps {
  agent: AgentResponse
  claimError?: string | null
  onOpenClaim?: () => void
}

export type ClaimObjectionType =
  | 'missing_model'
  | 'missing_tenant'
  | 'cross_tenant'
  | 'model_mismatch'
  | 'service_account_mismatch'
  | 'already_claimed'
  | 'generic'

function extractWorkloadName(podName: string): string {
  const match = podName.match(/^(.+?)(?:-[0-9a-f]{8,10}-[0-9a-z]{5}|-[0-9a-f]{8,10})$/)
  if (match) return match[1]
  const singleSuffix = podName.match(/^(.+?)-[0-9a-z]{5}$/)
  if (singleSuffix) return singleSuffix[1]
  return podName
}

export default function AgentOnboardingTab({ agent, claimError, onOpenClaim }: AgentOnboardingTabProps) {
  const { user } = useAuth0()
  const [searchParams] = useSearchParams()
  const errorFromQuery = searchParams.get('claim_error') || searchParams.get('error')
  const effectiveError = claimError || errorFromQuery || null

  const secProfile = getAgentWorkloadSecurityProfile(agent)

  const podName = agent.runtime?.pod_name || agent.id
  const namespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || agent.name || 'default'
  const workloadTenant = agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : null)
  const declaredModel = agent.runtime?.model || (agent as any).model || null
  const deploymentName = agent.runtime?.workload_name || extractWorkloadName(agent.name || podName)

  // Determine user tenant
  const userTenant =
    (user as { tenant?: string; 'https://signalloom.ai/tenant'?: string })?.tenant ||
    (user as { 'https://signalloom.ai/tenant'?: string })?.['https://signalloom.ai/tenant'] ||
    user?.email?.split('@')[1]?.split('.')[0] ||
    'default'

  const hasTenantMismatch = Boolean(workloadTenant && workloadTenant !== userTenant)
  const isMissingModelError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('no signalloom.ai/model') ||
      effectiveError.toLowerCase().includes('workload_model_undeclared') ||
      effectiveError.toLowerCase().includes('refusing to record an invented model')
    )
  )
  const isMissingTenantError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('no signalloom.ai/tenant') ||
      effectiveError.toLowerCase().includes('workload_tenant_undeclared')
    )
  )
  const isModelMismatchError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('model_mismatch') ||
      (effectiveError.toLowerCase().includes('declares model') && effectiveError.toLowerCase().includes('not'))
    )
  )
  const isServiceAccountMismatchError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('service_account_mismatch') ||
      effectiveError.toLowerCase().includes('serviceaccount')
    )
  )
  const isAlreadyClaimedError = Boolean(
    effectiveError && (
      effectiveError.toLowerCase().includes('already claimed') ||
      effectiveError.toLowerCase().includes('duplicate_claim') ||
      effectiveError.toLowerCase().includes('409') ||
      effectiveError.toLowerCase().includes('conflict')
    )
  )
  const isCrossTenantError = Boolean(
    hasTenantMismatch ||
    (effectiveError && (
      effectiveError.toLowerCase().includes('belongs to another tenant') ||
      effectiveError.toLowerCase().includes('cross_tenant_forbidden')
    ))
  )

  const objectionType: ClaimObjectionType | null = isMissingModelError
    ? 'missing_model'
    : isMissingTenantError
    ? 'missing_tenant'
    : isModelMismatchError
    ? 'model_mismatch'
    : isServiceAccountMismatchError
    ? 'service_account_mismatch'
    : isAlreadyClaimedError
    ? 'already_claimed'
    : isCrossTenantError
    ? 'cross_tenant'
    : effectiveError
    ? 'generic'
    : null

  const gitops = detectGitOps(agent, { tenant: userTenant })
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null)

  const handleCopy = (text: string, id: string) => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(text).catch(() => {})
      setCopiedCmd(id)
      setTimeout(() => setCopiedCmd(null), 2500)
    }
  }

  const defaultRecommendedModel = 'claude-3-5-sonnet'
  const relabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/tenant=${userTenant} --overwrite`
  const modelLabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/model=${defaultRecommendedModel} --overwrite`
  const deploymentModelPatchCommand = `kubectl -n ${namespace} patch deployment ${deploymentName} -p '{"spec":{"template":{"metadata":{"labels":{"signalloom.ai/model":"${defaultRecommendedModel}"}}}}}'`
  const deploymentTenantPatchCommand = `kubectl -n ${namespace} patch deployment ${deploymentName} -p '{"spec":{"template":{"metadata":{"labels":{"signalloom.ai/tenant":"${userTenant}"}}}}}'`
  const inspectCommand = `kubectl -n ${namespace} get pod ${podName} -o jsonpath='{.metadata.labels}'`
  const inspectPodYamlCommand = `kubectl -n ${namespace} get pod ${podName} -o yaml`

  const modelYamlPatch = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${deploymentName}
  namespace: ${namespace}
spec:
  template:
    metadata:
      labels:
        signalloom.ai/model: "${defaultRecommendedModel}"`

  const tenantYamlPatch = `apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${deploymentName}
  namespace: ${namespace}
spec:
  template:
    metadata:
      labels:
        signalloom.ai/tenant: "${userTenant}"`

  return (
    <div
      data-testid="agent-onboarding-tab"
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 20,
      }}
    >
      {/* ─── Hero / Status Banner ──────────────────────────────────────────────── */}
      <div
        className="card"
        style={{
          padding: '20px 24px',
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          gap: 16,
          flexWrap: 'wrap',
        }}
      >
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6, flexWrap: 'wrap' }}>
            <h3 style={{ margin: 0, fontSize: 18, color: 'var(--text)' }}>
              Workload Onboarding & Governance Guide
            </h3>
            <span
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 4,
                fontSize: 11,
                fontWeight: 600,
                padding: '2px 8px',
                borderRadius: 4,
                background: secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.15)' : 'rgba(56, 189, 248, 0.15)',
                color: secProfile.profile === 'nono-sandboxed' ? colors.tealLoom : colors.cyanLoom,
                border: `1px solid ${secProfile.profile === 'nono-sandboxed' ? 'rgba(34, 197, 94, 0.3)' : 'rgba(56, 189, 248, 0.3)'}`,
              }}
            >
              {secProfile.label}
            </span>
            <span
              style={{
                fontSize: 11,
                fontWeight: 600,
                padding: '2px 8px',
                borderRadius: 4,
                background: 'rgba(217, 119, 6, 0.15)',
                color: 'var(--amber)',
                border: '1px solid rgba(217, 119, 6, 0.3)',
              }}
            >
              Discovered Workload
            </span>
          </div>
          <p style={{ margin: 0, fontSize: 13, color: 'var(--muted)', lineHeight: 1.5, maxWidth: 680 }}>
            This autonomous agent was discovered in namespace <code style={{ color: 'var(--cyan)' }}>{namespace}</code>.
            Follow the pre-flight checks below to claim this workload into continuous cryptographic governance,
            CEL compliance scanning, and token budget enforcement.
          </p>
        </div>

        {onOpenClaim && (
          <button
            type="button"
            className="btn btn-primary"
            data-testid="onboarding-open-claim-btn"
            onClick={onOpenClaim}
            style={{
              padding: '10px 20px',
              fontSize: 13,
              fontWeight: 600,
              whiteSpace: 'nowrap',
              display: 'inline-flex',
              alignItems: 'center',
              gap: 8,
            }}
          >
            Claim Agent Workload
          </button>
        )}
      </div>

      {/* ─── Active Error or Pre-emptive Objection Alert ──────────────────────── */}
      {objectionType !== null && (
        <div
          data-testid="onboarding-objection-banner"
          style={{
            padding: '16px 20px',
            background: 'rgba(239, 68, 68, 0.08)',
            border: '1px solid rgba(239, 68, 68, 0.35)',
            borderRadius: 8,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 8, flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, color: 'var(--error)', fontWeight: 700, fontSize: 14 }}>
              <span>
                {objectionType === 'missing_model'
                  ? '⚠️ Workload Model Objection: Missing AI Model Declaration (signalloom.ai/model)'
                  : objectionType === 'missing_tenant'
                  ? '⚠️ Tenancy Objection: Undeclared Workload Tenant (signalloom.ai/tenant)'
                  : objectionType === 'cross_tenant'
                  ? '⚠️ Multi-Tenant Claim Objection: Cross-Tenant Boundary Protection'
                  : objectionType === 'model_mismatch'
                  ? '⚠️ Model Mismatch Objection: Asserted Model Divergence'
                  : objectionType === 'service_account_mismatch'
                  ? '⚠️ Identity Objection: SPIFFE ServiceAccount Mismatch'
                  : objectionType === 'already_claimed'
                  ? 'ℹ️ Workload Objection: Workload Already Claimed'
                  : '⚠️ Workload Claim Objection: Pre-Flight Verification Refusal'}
              </span>
            </div>
            <span
              style={{
                fontSize: 10,
                fontWeight: 700,
                padding: '2px 8px',
                borderRadius: 4,
                background: 'rgba(239, 68, 68, 0.15)',
                color: 'var(--error)',
                border: '1px solid rgba(239, 68, 68, 0.35)',
                textTransform: 'uppercase',
                letterSpacing: '0.04em',
              }}
            >
              {objectionType === 'missing_model'
                ? 'Model Required'
                : objectionType === 'missing_tenant'
                ? 'Tenant Required'
                : objectionType === 'cross_tenant'
                ? 'Boundary Violation'
                : objectionType === 'model_mismatch'
                ? 'Model Mismatch'
                : objectionType === 'service_account_mismatch'
                ? 'Identity Mismatch'
                : objectionType === 'already_claimed'
                ? 'Already Governed'
                : 'Refusal'}
            </span>
          </div>

          <p style={{ margin: '0 0 10px 0', fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}>
            {effectiveError ? (
              <span><strong>Reported Error:</strong> {effectiveError}</span>
            ) : objectionType === 'cross_tenant' ? (
              <span>
                Workload <strong>{podName}</strong> carries label <code style={{ color: 'var(--cyan)' }}>signalloom.ai/tenant="{workloadTenant}"</code>,
                while your current operator session is authenticated under tenant <code style={{ color: 'var(--violet)' }}>"{userTenant}"</code>.
              </span>
            ) : (
              <span>Workload <strong>{podName}</strong> requires configuration alignment before governance admission.</span>
            )}
          </p>

          <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5, marginBottom: 12 }}>
            <strong>Why this occurs:</strong>{' '}
            {objectionType === 'missing_model'
              ? 'Signal Loom strictly mandates that every governed agent declares an approved AI foundation model via the signalloom.ai/model label or annotation (HTTP 422 workload_model_undeclared). Without an explicit model identifier, token cost accounting, rate limiting, and model-specific compliance policies cannot be established. Refusing to record an invented model guarantees cryptographic attestation integrity.'
              : objectionType === 'missing_tenant'
              ? 'Signal Loom requires explicit tenant ownership before enrolling workloads into governance (HTTP 403 workload_tenant_undeclared). When allow_undeclared_tenant_claims is false, unassigned workloads cannot be claimed without an explicit signalloom.ai/tenant label.'
              : objectionType === 'cross_tenant'
              ? 'Signal Loom strictly enforces tenant isolation at the API gateway and claim engine (HTTP 403 cross_tenant_forbidden). Workloads provisioned for one tenant (such as vendor pilots) or platform-owned internal components (controlplane workloads like agent-cardvault, swarm-governor, or triage-ci-worker) cannot be claimed by other tenant operator accounts.'
              : objectionType === 'model_mismatch'
              ? 'Signal Loom validates that the model asserted in the claim request matches the workload runtime label signalloom.ai/model (HTTP 422 model_mismatch). Claiming an arbitrary or spoofed model is refused.'
              : objectionType === 'service_account_mismatch'
              ? 'The running pod ServiceAccount and namespace do not match the SPIFFE identity registered for this agent (HTTP 403 service_account_mismatch).'
              : objectionType === 'already_claimed'
              ? 'Workload has already been claimed by another tenant or operator (HTTP 409 Conflict). An agent cannot be concurrently governed across multiple tenants.'
              : 'The claim engine refused the claim request during pre-flight policy evaluation.'}
          </div>

          <div style={{ background: 'var(--surface2)', padding: '12px 16px', borderRadius: 6, border: '1px solid var(--border)' }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}>
              Resolution Options:
            </div>

            {objectionType === 'missing_model' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Option 1: Add Model Label to Pod (Immediate Hotfix):</strong>
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {modelLabelCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(modelLabelCommand, 'model-label')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'model-label' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
                <li style={{ marginTop: 8 }}>
                  <strong>Option 2: Patch Workload Deployment (Persistent):</strong>
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {deploymentModelPatchCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(deploymentModelPatchCommand, 'model-patch')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'model-patch' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
                <li style={{ marginTop: 8 }}>
                  <strong>Option 3: Declarative Kustomize / GitOps Patch:</strong>
                  <div style={{ marginTop: 6, display: 'flex', flexDirection: 'column', gap: 4 }}>
                    <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                      <button
                        type="button"
                        className="btn btn-secondary"
                        onClick={() => handleCopy(modelYamlPatch, 'model-yaml')}
                        style={{ fontSize: 11, padding: '3px 8px' }}
                      >
                        {copiedCmd === 'model-yaml' ? 'Copied! ✓' : 'Copy YAML'}
                      </button>
                    </div>
                    <pre style={{ margin: 0, padding: '8px 12px', background: 'var(--surface)', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, fontFamily: 'monospace', overflowX: 'auto' }}>
                      {modelYamlPatch}
                    </pre>
                  </div>
                </li>
              </ol>
            )}

            {objectionType === 'missing_tenant' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Option 1: Add Tenant Label to Pod:</strong>
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {relabelCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(relabelCommand, 'relabel')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'relabel' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
                <li style={{ marginTop: 8 }}>
                  <strong>Option 2: Patch Workload Deployment:</strong>
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {deploymentTenantPatchCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(deploymentTenantPatchCommand, 'tenant-patch')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'tenant-patch' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
                <li style={{ marginTop: 8 }}>
                  <strong>Option 3: Declarative Kustomize / GitOps Patch:</strong>
                  <div style={{ marginTop: 6, display: 'flex', flexDirection: 'column', gap: 4 }}>
                    <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
                      <button
                        type="button"
                        className="btn btn-secondary"
                        onClick={() => handleCopy(tenantYamlPatch, 'tenant-yaml')}
                        style={{ fontSize: 11, padding: '3px 8px' }}
                      >
                        {copiedCmd === 'tenant-yaml' ? 'Copied! ✓' : 'Copy YAML'}
                      </button>
                    </div>
                    <pre style={{ margin: 0, padding: '8px 12px', background: 'var(--surface)', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, fontFamily: 'monospace', overflowX: 'auto' }}>
                      {tenantYamlPatch}
                    </pre>
                  </div>
                </li>
              </ol>
            )}

            {objectionType === 'cross_tenant' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Switch Tenant Session:</strong> Log in with credentials belonging to tenant <code style={{ color: 'var(--cyan)' }}>{workloadTenant || 'kusari'}</code>.
                </li>
                <li>
                  <strong>Update Cluster Pod Label:</strong> If this pod belongs to your tenant, update its Kubernetes label:
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {relabelCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(relabelCommand, 'relabel')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'relabel' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
              </ol>
            )}

            {objectionType === 'model_mismatch' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Claim with Declared Model:</strong> Re-open the claim dialog and select the declared model <code style={{ color: 'var(--cyan)' }}>{declaredModel || 'declared'}</code>.
                </li>
                <li>
                  <strong>Update Cluster Model Label:</strong> Update the pod's label to match your asserted model:
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {modelLabelCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(modelLabelCommand, 'model-label')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'model-label' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
              </ol>
            )}

            {objectionType === 'service_account_mismatch' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Align ServiceAccount:</strong> Ensure the deployment pod template specifies <code style={{ color: 'var(--cyan)' }}>serviceAccountName: {serviceAccount}</code> in namespace <code style={{ color: 'var(--cyan)' }}>{namespace}</code> to match SPIFFE SVID mapping.
                </li>
                <li>
                  <strong>Inspect Live Pod:</strong>
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {inspectCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(inspectCommand, 'inspect')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'inspect' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
              </ol>
            )}

            {objectionType === 'already_claimed' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Review Existing Agent Dossier:</strong> This workload is already governed. Check the <a href={`/agents/${agent.id}?tab=overview`} style={{ color: 'var(--cyan)' }}>dossier overview</a> to inspect active ownership and telemetry.
                </li>
                <li>
                  <strong>Contact Workspace Administrator:</strong> If this workload needs to be reassigned, request claim release from the current tenant owner.
                </li>
              </ol>
            )}

            {objectionType === 'generic' && (
              <ol style={{ margin: 0, paddingLeft: 20, fontSize: 12, color: 'var(--muted)', lineHeight: 1.6 }}>
                <li>
                  <strong>Inspect Pod Manifest:</strong> Review workload labels and annotations in Kubernetes:
                  <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                    <code style={{ background: 'var(--surface)', padding: '6px 10px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1, overflowX: 'auto' }}>
                      {inspectPodYamlCommand}
                    </code>
                    <button
                      type="button"
                      className="btn btn-secondary"
                      onClick={() => handleCopy(inspectPodYamlCommand, 'inspect-yaml')}
                      style={{ fontSize: 11, padding: '4px 10px', whiteSpace: 'nowrap' }}
                    >
                      {copiedCmd === 'inspect-yaml' ? 'Copied! ✓' : 'Copy'}
                    </button>
                  </div>
                </li>
              </ol>
            )}
          </div>
        </div>
      )}

      {/* ─── GitOps Management & Remediation Card ────────────────────────────── */}
      {gitops.isGitOps && (
        <div
          className="card"
          data-testid="onboarding-gitops-notice"
          style={{
            padding: '16px 20px',
            background: 'rgba(234, 179, 8, 0.08)',
            border: '1px solid rgba(234, 179, 8, 0.35)',
            borderRadius: 8,
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ fontSize: 16 }}>⚡</span>
              <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--text)' }}>
                GitOps Reconciliation Active: Git-First Remediation Required
              </span>
            </div>
            <span
              data-testid="gitops-engine-badge"
              style={{
                fontSize: 11,
                fontWeight: 700,
                padding: '3px 10px',
                borderRadius: 4,
                background: 'rgba(56, 189, 248, 0.15)',
                color: colors.cyanLoom,
                border: '1px solid rgba(56, 189, 248, 0.35)',
                textTransform: 'uppercase',
                letterSpacing: '0.03em',
              }}
            >
              {gitops.engine === 'flux'
                ? 'Flux GitOps Managed'
                : gitops.engine === 'argo'
                ? 'ArgoCD Managed'
                : 'GitOps Managed'}
            </span>
          </div>

          <p
            data-testid="gitops-recommendation"
            style={{ margin: 0, fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}
          >
            {gitops.recommendation}
          </p>

          {gitops.commitSha && (
            <div style={{ fontSize: 11, color: 'var(--muted)', display: 'flex', gap: 6, alignItems: 'center' }}>
              <span>Observed Commit:</span>
              <code style={{ color: 'var(--cyan)', background: 'var(--surface2)', padding: '2px 6px', borderRadius: 3 }}>
                {gitops.commitSha.slice(0, 8)}
              </code>
            </div>
          )}

          {gitops.patchYaml && (
            <div style={{ marginTop: 4 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
                <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>
                  Declarative Remediation Patch (Kustomization / Git Manifest):
                </span>
                <button
                  type="button"
                  className="btn btn-secondary"
                  data-testid="onboarding-copy-gitops-patch-btn"
                  onClick={() => handleCopy(gitops.patchYaml!, 'gitops-patch')}
                  style={{ fontSize: 11, padding: '3px 10px' }}
                >
                  {copiedCmd === 'gitops-patch' ? 'Copied! ✓' : 'Copy YAML Patch'}
                </button>
              </div>
              <pre
                data-testid="onboarding-gitops-patch"
                style={{
                  background: 'var(--surface2)',
                  padding: '10px 14px',
                  borderRadius: 6,
                  border: '1px solid var(--border)',
                  color: 'var(--cyan)',
                  fontSize: 12,
                  fontFamily: 'monospace',
                  margin: 0,
                  whiteSpace: 'pre-wrap',
                  overflowX: 'auto',
                }}
              >
                {gitops.patchYaml}
              </pre>
            </div>
          )}
        </div>
      )}

      {/* ─── Pre-flight Diagnostics Matrix ───────────────────────────────────── */}
      <div>
        <h4 style={{ margin: '0 0 12px 0', fontSize: 14, color: 'var(--text)', fontWeight: 600 }}>
          Pre-Flight Verification Matrix
        </h4>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
            gap: 14,
          }}
        >
          {/* Diagnostic 1: Tenant Boundary */}
          <div
            className="card"
            data-testid="onboarding-diag-tenant"
            style={{
              padding: 16,
              background: 'var(--surface)',
              border: `1px solid ${hasTenantMismatch ? 'rgba(239, 68, 68, 0.4)' : 'var(--border)'}`,
              borderRadius: 6,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                Tenant Boundary
              </span>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: hasTenantMismatch ? 'rgba(239, 68, 68, 0.15)' : 'rgba(34, 197, 94, 0.15)',
                  color: hasTenantMismatch ? 'var(--error)' : 'var(--teal)',
                }}
              >
                {hasTenantMismatch ? 'MISMATCH' : 'VERIFIED'}
              </span>
            </div>
            <div style={{ fontSize: 13, color: 'var(--text)', fontWeight: 600, marginBottom: 4 }}>
              {workloadTenant ? `Tenant: ${workloadTenant}` : 'Undeclared (Eligible)'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              Claimant session: <code style={{ color: 'var(--text)' }}>{userTenant}</code>.
              {hasTenantMismatch && ' Refusal expected unless re-labelled or session switched.'}
            </div>
          </div>

          {/* Diagnostic 2: AI Model Attribution */}
          <div
            className="card"
            data-testid="onboarding-diag-model"
            style={{
              padding: 16,
              background: 'var(--surface)',
              border: `1px solid ${!declaredModel ? 'rgba(239, 68, 68, 0.4)' : 'var(--border)'}`,
              borderRadius: 6,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                AI Model Attribution
              </span>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: !declaredModel ? 'rgba(239, 68, 68, 0.15)' : 'rgba(34, 197, 94, 0.15)',
                  color: !declaredModel ? 'var(--error)' : 'var(--teal)',
                }}
              >
                {!declaredModel ? 'UNDECLARED' : 'VERIFIED'}
              </span>
            </div>
            <div style={{ fontSize: 13, color: 'var(--text)', fontWeight: 600, marginBottom: 4 }}>
              {declaredModel ? `Model: ${declaredModel}` : 'Missing signalloom.ai/model'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              {declaredModel
                ? 'Cryptographic token budget and CEL risk gating enabled.'
                : 'Refusal expected: model attribution is mandatory before governance.'}
            </div>
          </div>

          {/* Diagnostic 2: SPIFFE Identity */}
          <div
            className="card"
            data-testid="onboarding-diag-spiffe"
            style={{
              padding: 16,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 6,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                SPIFFE Attestation
              </span>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: 'rgba(34, 197, 94, 0.15)',
                  color: 'var(--teal)',
                }}
              >
                READY
              </span>
            </div>
            <div style={{ fontSize: 12, color: 'var(--cyan)', fontFamily: 'monospace', marginBottom: 4, overflow: 'hidden', textOverflow: 'ellipsis' }}>
              spiffe://cluster.local/ns/{namespace}/sa/{serviceAccount}
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              SPIRE workload API will mint X.509 SVID once enrolled into governance.
            </div>
          </div>

          {/* Diagnostic 3: In-Kernel Sensor */}
          <div
            className="card"
            data-testid="onboarding-diag-sensor"
            style={{
              padding: 16,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 6,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                Observability Sentinel
              </span>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: 'rgba(34, 197, 94, 0.15)',
                  color: 'var(--teal)',
                }}
              >
                ATTACHED
              </span>
            </div>
            <div style={{ fontSize: 13, color: 'var(--text)', fontWeight: 600, marginBottom: 4 }}>
              signalloom-warden eBPF
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              Tracing network egress, socket connects, and syscall events across container cgroup.
            </div>
          </div>

          {/* Diagnostic 4: Policy Engine */}
          <div
            className="card"
            data-testid="onboarding-diag-policy"
            style={{
              padding: 16,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 6,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase' }}>
                CEL Compliance Gate
              </span>
              <span
                style={{
                  fontSize: 10,
                  fontWeight: 700,
                  padding: '2px 6px',
                  borderRadius: 3,
                  background: 'rgba(34, 197, 94, 0.15)',
                  color: 'var(--teal)',
                }}
              >
                ENGAGED
              </span>
            </div>
            <div style={{ fontSize: 13, color: 'var(--text)', fontWeight: 600, marginBottom: 4 }}>
              CIS K8s + EU AI Act
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', lineHeight: 1.4 }}>
              Active CEL admission webhooks and continuous posture evaluation awaiting claim.
            </div>
          </div>
        </div>
      </div>

      {/* ─── Step-by-Step Onboarding Runbook ─────────────────────────────────── */}
      <div
        className="card"
        style={{
          padding: '20px 24px',
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
        }}
      >
        <h4 style={{ margin: '0 0 16px 0', fontSize: 14, color: 'var(--text)', fontWeight: 600 }}>
          3-Step Workload Claim & Onboarding Procedure
        </h4>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {/* Step 1 */}
          <div style={{ display: 'flex', gap: 14 }}>
            <div
              style={{
                width: 28,
                height: 28,
                borderRadius: '50%',
                background: 'rgba(6, 182, 212, 0.15)',
                color: 'var(--cyan)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontWeight: 700,
                fontSize: 12,
                flexShrink: 0,
              }}
            >
              1
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
                Verify Tenant and Workload Identification
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5 }}>
                Ensure the target pod carries the expected <code>signalloom.ai/agent</code> and <code>signalloom.ai/tenant</code> labels.
                Inspect live cluster state with:
                <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8 }}>
                  <code style={{ background: 'var(--surface2)', padding: '4px 8px', borderRadius: 4, color: 'var(--cyan)', fontSize: 11, flex: 1 }}>
                    {inspectCommand}
                  </code>
                  <button
                    type="button"
                    className="btn btn-secondary"
                    onClick={() => handleCopy(inspectCommand, 'inspect')}
                    style={{ fontSize: 11, padding: '3px 8px' }}
                  >
                    {copiedCmd === 'inspect' ? 'Copied! ✓' : 'Copy'}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* Step 2 */}
          <div style={{ display: 'flex', gap: 14 }}>
            <div
              style={{
                width: 28,
                height: 28,
                borderRadius: '50%',
                background: 'rgba(6, 182, 212, 0.15)',
                color: 'var(--cyan)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontWeight: 700,
                fontSize: 12,
                flexShrink: 0,
              }}
            >
              2
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
                Configure Model & Token Budget Allocation
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5 }}>
                Click <strong>Claim Agent Workload</strong> to open the configuration dialog. Assign the appropriate token limit
                (default 250,000 tokens) to prevent out-of-control inference loops. The dialog includes real-time pre-flight verification
                to catch objections before submission.
              </div>
            </div>
          </div>

          {/* Step 3 */}
          <div style={{ display: 'flex', gap: 14 }}>
            <div
              style={{
                width: 28,
                height: 28,
                borderRadius: '50%',
                background: 'rgba(6, 182, 212, 0.15)',
                color: 'var(--cyan)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontWeight: 700,
                fontSize: 12,
                flexShrink: 0,
              }}
            >
              3
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
                Continuous Governance & Telemetry Attestation
              </div>
              <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5 }}>
                Once claimed, the agent state transitions from <em>Discovered</em> to <em>Governed</em>.
                Signal Loom immediately generates compliance proofs, evaluates admission and runtime policies,
                and streams real-time syscall anomalies to The Weave.
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
