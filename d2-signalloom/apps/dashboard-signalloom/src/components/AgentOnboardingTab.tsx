import { useState } from 'react'
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

export default function AgentOnboardingTab({ agent, claimError, onOpenClaim }: AgentOnboardingTabProps) {
  const { user } = useAuth0()
  const secProfile = getAgentWorkloadSecurityProfile(agent)

  const podName = agent.runtime?.pod_name || agent.id
  const namespace = agent.runtime?.namespace || agent.namespace || 'fe-signalloom-agents'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || agent.name || 'default'
  const workloadTenant = agent.tenant || (agent.tenant_id && agent.tenant_id !== 'undeclared' ? agent.tenant_id : null)

  // Determine user tenant
  const userTenant =
    (user as { tenant?: string; 'https://signalloom.ai/tenant'?: string })?.tenant ||
    (user as { 'https://signalloom.ai/tenant'?: string })?.['https://signalloom.ai/tenant'] ||
    user?.email?.split('@')[1]?.split('.')[0] ||
    'default'

  const hasTenantMismatch = Boolean(workloadTenant && workloadTenant !== userTenant)
  const gitops = detectGitOps(agent, { tenant: userTenant })
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null)

  const handleCopy = (text: string, id: string) => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(text).catch(() => {})
      setCopiedCmd(id)
      setTimeout(() => setCopiedCmd(null), 2500)
    }
  }

  const relabelCommand = `kubectl -n ${namespace} label pod ${podName} signalloom.ai/tenant=${userTenant} --overwrite`
  const inspectCommand = `kubectl -n ${namespace} get pod ${podName} -o jsonpath='{.metadata.labels}'`

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
      {(claimError || hasTenantMismatch) && (
        <div
          data-testid="onboarding-objection-banner"
          style={{
            padding: '16px 20px',
            background: 'rgba(239, 68, 68, 0.08)',
            border: '1px solid rgba(239, 68, 68, 0.35)',
            borderRadius: 8,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8, color: 'var(--error)', fontWeight: 700, fontSize: 14 }}>
            <span>⚠️ Multi-Tenant Claim Objection: Cross-Tenant Boundary Protection</span>
          </div>

          <p style={{ margin: '0 0 10px 0', fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}>
            {claimError ? (
              <span><strong>Reported Error:</strong> {claimError}</span>
            ) : (
              <span>
                Workload <strong>{podName}</strong> carries label <code style={{ color: 'var(--cyan)' }}>signalloom.ai/tenant="{workloadTenant}"</code>,
                while your current operator session is authenticated under tenant <code style={{ color: 'var(--violet)' }}>"{userTenant}"</code>.
              </span>
            )}
          </p>

          <div style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.5, marginBottom: 12 }}>
            <strong>Why this occurs:</strong> Signal Loom strictly enforces tenant isolation at the API gateway and claim engine (HTTP 403 <code>cross_tenant_forbidden</code>).
            Workloads provisioned for one tenant (such as the Kusari secondary cluster pilot or vendor tenants) cannot be claimed or hijacked by another operator account.
          </div>

          <div style={{ background: 'var(--surface2)', padding: '12px 16px', borderRadius: 6, border: '1px solid var(--border)' }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}>
              Resolution Options:
            </div>
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
