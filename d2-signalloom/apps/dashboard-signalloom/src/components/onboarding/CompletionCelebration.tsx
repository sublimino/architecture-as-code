import React from 'react'
import type { TenantProfileData } from './TenantIdentityStep'
import type { IdpConfigData } from './IdpLinkageStep'
import type { ContainmentPolicyData } from './ContainmentPolicyConsentStep'

interface CompletionCelebrationProps {
  tenantProfile: Partial<TenantProfileData>
  idpConfig: Partial<IdpConfigData>
  containmentPolicy: Partial<ContainmentPolicyData>
  onContinue: () => void
}

export default function CompletionCelebration({
  tenantProfile,
  idpConfig,
  containmentPolicy,
  onContinue,
}: CompletionCelebrationProps) {
  return (
    <div
      data-testid="completion-celebration"
      style={{
        maxWidth: 680,
        margin: '0 auto',
        textAlign: 'center',
        padding: '32px 20px',
      }}
    >
      {/* Celebratory Icon */}
      <div
        style={{
          width: 72,
          height: 72,
          borderRadius: '50%',
          background: 'rgba(16, 185, 129, 0.16)',
          border: '2px solid var(--teal, #10B981)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          margin: '0 auto 20px',
          boxShadow: '0 0 24px rgba(16, 185, 129, 0.25)',
        }}
      >
        <svg
          width="36"
          height="36"
          viewBox="0 0 24 24"
          fill="none"
          stroke="var(--teal, #10B981)"
          strokeWidth="2.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d="M20 6 9 17l-5-5" />
        </svg>
      </div>

      <h1
        style={{
          fontSize: 28,
          fontWeight: 700,
          color: 'var(--text)',
          marginBottom: 10,
          letterSpacing: '-0.02em',
        }}
      >
        Onboarding Completed!
      </h1>

      <p
        style={{
          color: 'var(--muted)',
          fontSize: 15,
          lineHeight: 1.6,
          maxWidth: 520,
          margin: '0 auto 28px',
        }}
      >
        Your Signal Loom workspace is initialized and secured. You are ready to deploy, monitor, and
        govern autonomous agent fleets under zero-trust runtime policy.
      </p>

      {/* Summary Review Card */}
      <div
        className="card"
        style={{
          textAlign: 'left',
          padding: '20px 24px',
          marginBottom: 28,
        }}
      >
        <h3
          style={{
            fontSize: 13,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
            color: 'var(--cyan)',
            margin: '0 0 16px',
          }}
        >
          Active Environment Configuration
        </h3>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 16 }}>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', marginBottom: 2 }}>
              Organization
            </div>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
              {tenantProfile.organizationName || 'Acme Corporation'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>
              {tenantProfile.workspaceId || 'acme-primary'}
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', marginBottom: 2 }}>
              Identity Provider
            </div>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
              {idpConfig.providerName || 'Dex OIDC (In-Cluster)'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--teal)' }}>
              ✓ Federating SPIFFE Trust
            </div>
          </div>

          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', marginBottom: 2 }}>
              Containment Profile
            </div>
            <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--cyan)' }}>
              {containmentPolicy.policyTier === 'standard-baseline'
                ? 'Standard Baseline'
                : containmentPolicy.policyTier === 'custom'
                ? 'Custom Policy'
                : 'Strict Sandboxed (nono)'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--teal)' }}>
              ✓ Sub-second Halt Enabled
            </div>
          </div>
        </div>
      </div>

      {/* CTA Button */}
      <button
        type="button"
        className="btn btn-primary"
        data-testid="goto-dashboard-button"
        onClick={onContinue}
        style={{
          fontSize: 15,
          fontWeight: 600,
          padding: '12px 32px',
          background: 'linear-gradient(90deg, var(--cyan), var(--violet, #8B5CF6))',
          boxShadow: '0 2px 12px rgba(6, 182, 212, 0.3)',
          cursor: 'pointer',
        }}
      >
        Go to Overview Dashboard →
      </button>
    </div>
  )
}
