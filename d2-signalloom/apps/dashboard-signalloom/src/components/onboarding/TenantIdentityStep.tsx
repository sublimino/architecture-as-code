import React, { useState } from 'react'
import ValidationErrorBanner from './ValidationErrorBanner'

export interface TenantProfileData {
  organizationName: string
  workspaceId: string
  adminEmail: string
  environment: 'production' | 'staging' | 'evaluation'
  description?: string
}

interface TenantIdentityStepProps {
  initialValues?: Partial<TenantProfileData>
  onNext: (data: TenantProfileData) => void
  onSkip: () => void
}

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const SLUG_REGEX = /^[a-z0-9-_]+$/i

export default function TenantIdentityStep({
  initialValues,
  onNext,
  onSkip,
}: TenantIdentityStepProps) {
  const [organizationName, setOrganizationName] = useState(initialValues?.organizationName ?? 'Acme Corporation')
  const [workspaceId, setWorkspaceId] = useState(initialValues?.workspaceId ?? 'acme-primary')
  const [adminEmail, setAdminEmail] = useState(initialValues?.adminEmail ?? 'operator@acme.corp')
  const [environment, setEnvironment] = useState<TenantProfileData['environment']>(
    initialValues?.environment ?? 'production',
  )
  const [description, setDescription] = useState(
    initialValues?.description ?? 'Enterprise autonomous agent governance, runtime confinement, and tamper-evident audit.',
  )
  const [errors, setErrors] = useState<string[]>([])

  const handleOrgNameChange = (val: string) => {
    setOrganizationName(val)
    // Auto-generate workspace slug if it matches default or was empty
    if (!initialValues?.workspaceId || workspaceId === 'acme-primary') {
      const slug = val
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/(^-|-$)+/g, '')
      if (slug) {
        setWorkspaceId(`${slug}-primary`)
      }
    }
  }

  const validate = (): boolean => {
    const errs: string[] = []
    if (!organizationName.trim()) {
      errs.push('Organization Name is required.')
    }
    if (!workspaceId.trim()) {
      errs.push('Workspace Identifier is required.')
    } else if (!SLUG_REGEX.test(workspaceId)) {
      errs.push('Workspace Identifier must contain only letters, numbers, hyphens, or underscores.')
    }
    if (!adminEmail.trim()) {
      errs.push('Primary Operator Email is required.')
    } else if (!EMAIL_REGEX.test(adminEmail.trim())) {
      errs.push('Please enter a valid email address for the Primary Operator.')
    }

    setErrors(errs)
    return errs.length === 0
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (validate()) {
      onNext({
        organizationName: organizationName.trim(),
        workspaceId: workspaceId.trim(),
        adminEmail: adminEmail.trim(),
        environment,
        description: description.trim(),
      })
    }
  }

  return (
    <div style={{ maxWidth: 680, margin: '0 auto' }}>
      <div style={{ marginBottom: 24 }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>
          Tenant &amp; Workspace Identity
        </h1>
        <p style={{ color: 'var(--muted)', fontSize: 14, lineHeight: 1.6 }}>
          Set up your organization profile and target workspace boundaries. This initializes your
          multi-tenant isolation partition and designates the primary platform operator.
        </p>
      </div>

      <ValidationErrorBanner errors={errors} onDismiss={() => setErrors([])} />

      <form noValidate onSubmit={handleSubmit} className="card" style={{ padding: '24px 28px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          {/* Organization Name */}
          <div>
            <label
              htmlFor="organization-name"
              style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
            >
              Organization / Tenant Name <span style={{ color: 'var(--error)' }}>*</span>
            </label>
            <input
              id="organization-name"
              data-testid="input-organization-name"
              type="text"
              value={organizationName}
              onChange={(e) => handleOrgNameChange(e.target.value)}
              placeholder="e.g. Acme Corporation"
              style={{
                width: '100%',
                padding: '10px 14px',
                borderRadius: 6,
                border: '1px solid var(--border)',
                background: 'var(--bg)',
                color: 'var(--text)',
                fontSize: 14,
                boxSizing: 'border-box',
              }}
            />
            <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              The legal entity or department operating this Signal Loom cluster.
            </span>
          </div>

          {/* Workspace ID */}
          <div>
            <label
              htmlFor="workspace-id"
              style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
            >
              Workspace Identifier (Slug) <span style={{ color: 'var(--error)' }}>*</span>
            </label>
            <input
              id="workspace-id"
              data-testid="input-workspace-id"
              type="text"
              value={workspaceId}
              onChange={(e) => setWorkspaceId(e.target.value)}
              placeholder="e.g. acme-primary"
              style={{
                width: '100%',
                padding: '10px 14px',
                borderRadius: 6,
                border: '1px solid var(--border)',
                background: 'var(--bg)',
                color: 'var(--text)',
                fontSize: 14,
                fontFamily: 'monospace',
                boxSizing: 'border-box',
              }}
            />
            <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Unique partition key used in SPIFFE trust domains and policy scopes.
            </span>
          </div>

          {/* Admin Email */}
          <div>
            <label
              htmlFor="admin-email"
              style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
            >
              Primary Operator Email <span style={{ color: 'var(--error)' }}>*</span>
            </label>
            <input
              id="admin-email"
              data-testid="input-admin-email"
              type="email"
              value={adminEmail}
              onChange={(e) => setAdminEmail(e.target.value)}
              placeholder="e.g. operator@acme.corp"
              style={{
                width: '100%',
                padding: '10px 14px',
                borderRadius: 6,
                border: '1px solid var(--border)',
                background: 'var(--bg)',
                color: 'var(--text)',
                fontSize: 14,
                boxSizing: 'border-box',
              }}
            />
            <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Receives critical security alerts, policy violation digests, and audit attestation summaries.
            </span>
          </div>

          {/* Environment */}
          <div>
            <label
              style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 8 }}
            >
              Governance Environment Target
            </label>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 10 }}>
              {[
                { id: 'production', label: 'Production', desc: 'Strict Zero-Trust isolation' },
                { id: 'staging', label: 'Staging / Demo', desc: 'Pre-release testing & preview' },
                { id: 'evaluation', label: 'Evaluation Sandbox', desc: 'Ephemeral evaluation cluster' },
              ].map((env) => (
                <label
                  key={env.id}
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    padding: '12px 14px',
                    borderRadius: 6,
                    border: environment === env.id ? '1px solid var(--cyan)' : '1px solid var(--border)',
                    background: environment === env.id ? 'rgba(6, 182, 212, 0.08)' : 'var(--bg)',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                    <input
                      type="radio"
                      name="environment"
                      value={env.id}
                      checked={environment === env.id}
                      onChange={() => setEnvironment(env.id as TenantProfileData['environment'])}
                      style={{ accentColor: 'var(--cyan)' }}
                    />
                    <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>{env.label}</span>
                  </div>
                  <span style={{ fontSize: 11, color: 'var(--muted)', paddingLeft: 22 }}>{env.desc}</span>
                </label>
              ))}
            </div>
          </div>

          {/* Description */}
          <div>
            <label
              htmlFor="description"
              style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
            >
              Governance Scope / Description (Optional)
            </label>
            <textarea
              id="description"
              data-testid="input-description"
              rows={2}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="e.g. Governing autonomous AI agents across Kubernetes clusters"
              style={{
                width: '100%',
                padding: '10px 14px',
                borderRadius: 6,
                border: '1px solid var(--border)',
                background: 'var(--bg)',
                color: 'var(--text)',
                fontSize: 13,
                resize: 'vertical',
                boxSizing: 'border-box',
              }}
            />
          </div>
        </div>

        {/* Action buttons */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 28, paddingTop: 18, borderTop: '1px solid var(--border)' }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={onSkip}
            style={{ fontSize: 13 }}
          >
            Skip for now
          </button>
          <button
            type="submit"
            className="btn btn-primary"
            data-testid="next-step-button"
            style={{ fontSize: 14, padding: '8px 20px' }}
          >
            Next: Identity Providers →
          </button>
        </div>
      </form>
    </div>
  )
}
