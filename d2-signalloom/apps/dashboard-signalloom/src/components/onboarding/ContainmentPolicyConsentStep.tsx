import React, { useState } from 'react'
import ValidationErrorBanner from './ValidationErrorBanner'
import type { TenantProfileData } from './TenantIdentityStep'
import type { IdpConfigData } from './IdpLinkageStep'

export interface ContainmentPolicyData {
  policyTier: 'strict-sandboxed' | 'standard-baseline' | 'custom'
  zeroTrustIdentity: boolean
  autonomousContainment: boolean
  auditTrailRetention: boolean
}

interface ContainmentPolicyConsentStepProps {
  tenantProfile: Partial<TenantProfileData>
  idpConfig: Partial<IdpConfigData>
  initialValues?: Partial<ContainmentPolicyData>
  submitting?: boolean
  onSubmit: (policy: ContainmentPolicyData) => void
  onBack: () => void
  onSkip: () => void
}

export default function ContainmentPolicyConsentStep({
  tenantProfile,
  idpConfig,
  initialValues,
  submitting = false,
  onSubmit,
  onBack,
  onSkip,
}: ContainmentPolicyConsentStepProps) {
  const [policyTier, setPolicyTier] = useState<ContainmentPolicyData['policyTier']>(
    initialValues?.policyTier ?? 'strict-sandboxed',
  )
  const [zeroTrustIdentity, setZeroTrustIdentity] = useState(
    initialValues?.zeroTrustIdentity ?? true,
  )
  const [autonomousContainment, setAutonomousContainment] = useState(
    initialValues?.autonomousContainment ?? true,
  )
  const [auditTrailRetention, setAuditTrailRetention] = useState(
    initialValues?.auditTrailRetention ?? true,
  )
  const [errors, setErrors] = useState<string[]>([])

  const validate = (): boolean => {
    const errs: string[] = []
    if (!zeroTrustIdentity) {
      errs.push('Zero-Trust Workload Identity consent is required for autonomous agent security.')
    }
    if (!autonomousContainment) {
      errs.push('Autonomous Runtime Containment authorization is required for safe agent execution.')
    }
    if (!auditTrailRetention) {
      errs.push('Tamper-Evident Audit Trail retention consent is required for enterprise compliance.')
    }

    setErrors(errs)
    return errs.length === 0
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (validate()) {
      onSubmit({
        policyTier,
        zeroTrustIdentity,
        autonomousContainment,
        auditTrailRetention,
      })
    }
  }

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>
          Containment Policy &amp; Security Consent
        </h1>
        <p style={{ color: 'var(--muted)', fontSize: 14, lineHeight: 1.6 }}>
          Select your runtime confinement profile and authorize zero-trust policy enforcement.
          Signal Loom will protect your environment through kernel-level isolation, sub-second execution halt,
          and cryptographic audit session verification.
        </p>
      </div>

      <ValidationErrorBanner errors={errors} onDismiss={() => setErrors([])} />

      <form noValidate onSubmit={handleSubmit}>
        {/* Policy Tier Selection */}
        <div style={{ marginBottom: 24 }}>
          <label style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 10 }}>
            Security Containment Profile
          </label>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 12 }}>
            {[
              {
                id: 'strict-sandboxed',
                name: 'Strict Sandboxed & Hash-Chained Audit (Recommended)',
                badge: 'Recommended · Zero-Trust',
                desc: 'Applies Linux Landlock LSM unprivileged sandboxing (nono), SPIFFE detached signatures, and real-time Tetragon eBPF telemetry with sub-second execution halt.',
              },
              {
                id: 'standard-baseline',
                name: 'Standard Containerized Baseline',
                badge: 'Container Isolation',
                desc: 'Container cgroup and namespace confinement with continuous network policy filtering and eBPF audit flow inspection.',
              },
              {
                id: 'custom',
                name: 'Custom Enterprise Policy Suite',
                badge: 'Custom Governance',
                desc: 'Operator-tailored security rules, manual approval thresholds, and custom external policy engine integration.',
              },
            ].map((tier) => {
              const isSelected = policyTier === tier.id
              return (
                <label
                  key={tier.id}
                  style={{
                    display: 'flex',
                    alignItems: 'flex-start',
                    gap: 12,
                    padding: '16px 18px',
                    borderRadius: 8,
                    border: isSelected ? '2px solid var(--cyan)' : '1px solid var(--border)',
                    background: isSelected ? 'rgba(6, 182, 212, 0.08)' : 'var(--surface)',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                  }}
                >
                  <input
                    type="radio"
                    name="policyTier"
                    value={tier.id}
                    checked={isSelected}
                    onChange={() => setPolicyTier(tier.id as ContainmentPolicyData['policyTier'])}
                    style={{ marginTop: 3, accentColor: 'var(--cyan)' }}
                  />
                  <div style={{ flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 4 }}>
                      <span style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>
                        {tier.name}
                      </span>
                      <span
                        className="tag"
                        style={{
                          background: isSelected ? 'rgba(6, 182, 212, 0.16)' : 'var(--border)',
                          color: isSelected ? 'var(--cyan)' : 'var(--muted)',
                          fontSize: 11,
                        }}
                      >
                        {tier.badge}
                      </span>
                    </div>
                    <p style={{ fontSize: 12, color: 'var(--muted)', margin: 0, lineHeight: 1.5 }}>
                      {tier.desc}
                    </p>
                  </div>
                </label>
              )
            })}
          </div>
        </div>

        {/* Security Consent Invariants */}
        <div className="card" style={{ padding: '20px 24px', marginBottom: 24 }}>
          <h3 style={{ fontSize: 14, fontWeight: 700, color: 'var(--text)', margin: '0 0 14px' }}>
            Enterprise Zero-Trust Governance Consent
          </h3>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            <label
              style={{
                display: 'flex',
                alignItems: 'flex-start',
                gap: 10,
                fontSize: 13,
                color: 'var(--text)',
                cursor: 'pointer',
              }}
            >
              <input
                type="checkbox"
                data-testid="consent-zero-trust"
                checked={zeroTrustIdentity}
                onChange={(e) => setZeroTrustIdentity(e.target.checked)}
                style={{ marginTop: 2, accentColor: 'var(--teal)' }}
              />
              <div>
                <strong>Zero-Trust Workload Identity:</strong> Enforce SPIFFE cryptographic SVID verification
                for all running and scheduled agent processes before granting ingress or tool access.
              </div>
            </label>

            <label
              style={{
                display: 'flex',
                alignItems: 'flex-start',
                gap: 10,
                fontSize: 13,
                color: 'var(--text)',
                cursor: 'pointer',
              }}
            >
              <input
                type="checkbox"
                data-testid="consent-autonomous-containment"
                checked={autonomousContainment}
                onChange={(e) => setAutonomousContainment(e.target.checked)}
                style={{ marginTop: 2, accentColor: 'var(--teal)' }}
              />
              <div>
                <strong>Sub-Second Autonomous Containment:</strong> Authorize Signal Loom to immediately freeze
                cgroups and drop network flows upon detecting policy breaches or anomalous privilege escalation.
              </div>
            </label>

            <label
              style={{
                display: 'flex',
                alignItems: 'flex-start',
                gap: 10,
                fontSize: 13,
                color: 'var(--text)',
                cursor: 'pointer',
              }}
            >
              <input
                type="checkbox"
                data-testid="consent-audit-trail"
                checked={auditTrailRetention}
                onChange={(e) => setAuditTrailRetention(e.target.checked)}
                style={{ marginTop: 2, accentColor: 'var(--teal)' }}
              />
              <div>
                <strong>Tamper-Evident Audit Logging:</strong> Record immutable, hash-chained audit sessions and
                compliance events for SOC 2, EU AI Act, and cryptographic non-repudiation.
              </div>
            </label>
          </div>
        </div>

        {/* Configuration Review Summary */}
        <div
          style={{
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
            padding: '16px 20px',
            marginBottom: 24,
          }}
        >
          <div style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--muted)', marginBottom: 10 }}>
            Configuration Review
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 14, fontSize: 13 }}>
            <div>
              <span style={{ color: 'var(--muted)', display: 'block', fontSize: 11 }}>Organization</span>
              <strong style={{ color: 'var(--text)' }}>{tenantProfile.organizationName || 'Acme Corporation'}</strong>
              <div style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>
                {tenantProfile.workspaceId || 'acme-primary'}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)', display: 'block', fontSize: 11 }}>Identity Provider</span>
              <strong style={{ color: 'var(--text)' }}>{idpConfig.providerName || 'Dex OIDC'}</strong>
              <div style={{ fontSize: 11, color: 'var(--muted)', wordBreak: 'break-all' }}>
                {idpConfig.issuerUrl || 'https://dex.inf-signalloom...'}
              </div>
            </div>
            <div>
              <span style={{ color: 'var(--muted)', display: 'block', fontSize: 11 }}>Policy Tier</span>
              <strong style={{ color: 'var(--cyan)' }}>
                {policyTier === 'strict-sandboxed' ? 'Strict Sandboxed (nono)' : policyTier === 'standard-baseline' ? 'Standard Baseline' : 'Custom Policy'}
              </strong>
              <div style={{ fontSize: 11, color: 'var(--teal)' }}>
                Zero-Trust Consented
              </div>
            </div>
          </div>
        </div>

        {/* Action Buttons */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 24 }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={onBack}
            disabled={submitting}
            data-testid="back-step-button"
            style={{ fontSize: 13 }}
          >
            ← Back
          </button>
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <button
              type="button"
              className="btn btn-secondary"
              onClick={onSkip}
              disabled={submitting}
              style={{ fontSize: 13 }}
            >
              Skip for now
            </button>
            <button
              type="submit"
              className="btn btn-primary"
              data-testid="complete-onboarding-button"
              disabled={submitting}
              style={{
                fontSize: 14,
                padding: '8px 24px',
                background: 'linear-gradient(90deg, var(--cyan), var(--violet, #8B5CF6))',
                fontWeight: 600,
              }}
            >
              {submitting ? 'Completing Setup…' : 'Complete Onboarding ✓'}
            </button>
          </div>
        </div>
      </form>
    </div>
  )
}
