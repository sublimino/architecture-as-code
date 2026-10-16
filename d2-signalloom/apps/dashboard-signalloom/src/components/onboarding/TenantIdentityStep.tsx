import React, { useState } from 'react'
import ValidationErrorBanner from './ValidationErrorBanner'

export interface TenantProfileData {
  organizationName: string
  workspaceId: string
  adminEmail: string
  environment: 'production' | 'staging' | 'evaluation'
  description?: string
  // ── The declared risk profile ──────────────────────────────────────────────
  //
  // Empty string means UNDECLARED, and the wizard sends null for it.  These are
  // the institution's half of the pricing split: the policy pack owns how OFTEN
  // a loss event happens (a property of the control environment), this tenant
  // owns what one COSTS here (a property of the institution).
  //
  // Not asked for: the per-scenario magnitude triples, which carry mandatory
  // provenance prose naming the reference class they were calibrated against.
  // A wizard cannot elicit that, and a fabricated triple is worse than none.
  // Also not asked for: risk_load, the markup on tail risk that produces the
  // carried figure.  The API accepts it, but it is an actuarial parameter, not
  // something an operator can state on day one -- so this form does not pretend
  // to collect it.
  sector?: string
  jurisdiction?: string
  reportingCurrency?: string
  riskAppetiteTolerance?: string
}

/** The currencies the product can actually price a figure in.
 *
 * Must stay in step with SUPPORTED_DISPLAY_CURRENCIES in api_compat.py and
 * SUPPORTED_CURRENCIES in money/currency.ts -- all three are the currency list
 * in risk/fx/rates.yaml, because a currency with no rate renders every figure
 * as Unavailable.  The server rejects anything outside the set, so offering a
 * closed <select> here is what keeps the form from being able to compose a
 * request the API will refuse.
 */
const REPORTING_CURRENCIES = [
  'USD', 'GBP', 'EUR', 'JPY',
  'AED', 'AUD', 'CAD', 'CHF', 'DKK', 'HKD', 'INR', 'NOK', 'SEK', 'SGD', 'ZAR',
] as const

/** Jurisdictions, matched against a scenario's `territories`.
 *
 * '*' is global and is NOT the same as declining to declare: an unstated
 * jurisdiction matches no scoped scenario at all (Scenario.AppliesTo), whereas
 * '*' matches every one.  Saying nothing and saying "everywhere" are different
 * claims and the form has to let an operator make either.
 */
const JURISDICTIONS = [
  { id: '*', label: 'Global / multiple territories' },
  { id: 'UK', label: 'United Kingdom' },
  { id: 'US', label: 'United States' },
  { id: 'EU', label: 'European Union' },
  { id: 'DE', label: 'Germany' },
  { id: 'FR', label: 'France' },
  { id: 'SG', label: 'Singapore' },
  { id: 'AU', label: 'Australia' },
  { id: 'CA', label: 'Canada' },
  { id: 'JP', label: 'Japan' },
] as const

interface TenantIdentityStepProps {
  initialValues?: Partial<TenantProfileData>
  onNext: (data: TenantProfileData) => void
  onSkip: () => void
  skipLabel?: string
}

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const SLUG_REGEX = /^[a-z0-9-_]+$/i

export default function TenantIdentityStep({
  initialValues,
  onNext,
  onSkip,
  skipLabel = 'Skip for now',
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
  const [sector, setSector] = useState(initialValues?.sector ?? '')
  const [jurisdiction, setJurisdiction] = useState(initialValues?.jurisdiction ?? '')
  const [reportingCurrency, setReportingCurrency] = useState(initialValues?.reportingCurrency ?? '')
  const [riskAppetiteTolerance, setRiskAppetiteTolerance] = useState(
    initialValues?.riskAppetiteTolerance ?? '',
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

    // The risk profile is entirely optional -- the whole step is skippable, and
    // declaring nothing is a real state the engine understands. But a tolerance
    // is a MONEY value, and an amount without its denomination is not a
    // quantity: "6000" could be the band or four times it depending on the
    // currency. So the two are validated as a pair rather than separately.
    const tolerance = riskAppetiteTolerance.trim()
    if (tolerance) {
      const parsed = Number(tolerance)
      if (!Number.isFinite(parsed) || parsed <= 0) {
        errs.push('Risk Appetite Tolerance must be a positive number, or left blank.')
      } else if (!reportingCurrency) {
        errs.push(
          'Choose a Reporting Currency for the Risk Appetite Tolerance: an amount ' +
          'without a currency is not an amount.',
        )
      }
    }

    setErrors(errs)
    return errs.length === 0
  }

  /** Blank means UNDECLARED, which the API expects as null rather than ''. */
  const declaredOrNull = (value: string): string | undefined =>
    value.trim() ? value.trim() : undefined

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (validate()) {
      onNext({
        organizationName: organizationName.trim(),
        workspaceId: workspaceId.trim(),
        adminEmail: adminEmail.trim(),
        environment,
        description: description.trim(),
        sector: declaredOrNull(sector),
        jurisdiction: declaredOrNull(jurisdiction),
        reportingCurrency: declaredOrNull(reportingCurrency),
        riskAppetiteTolerance: declaredOrNull(riskAppetiteTolerance),
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

          {/* ── Declared risk profile (all optional) ───────────────────────── */}
          <div style={{ paddingTop: 4, borderTop: '1px solid var(--border)' }}>
            <h2 style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)', margin: '16px 0 6px' }}>
              Risk profile <span style={{ fontWeight: 500, color: 'var(--muted)' }}>(optional)</span>
            </h2>
            <p style={{ color: 'var(--muted)', fontSize: 12, lineHeight: 1.6, marginBottom: 16 }}>
              What a loss event costs <em>here</em>. The policy pack decides how often something
              goes wrong; these decide what it is worth when it does, so the same control can
              warrant enforcement at one institution and only an audit note at another, without
              anyone having an opinion. Leave any of it blank and the platform uses its own
              defaults instead.
            </p>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16 }}>
              {/* Sector */}
              <div>
                <label
                  htmlFor="org-sector"
                  style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                >
                  Sector
                </label>
                <input
                  id="org-sector"
                  data-testid="input-sector"
                  type="text"
                  value={sector}
                  onChange={(e) => setSector(e.target.value)}
                  placeholder="e.g. retail-ecommerce"
                  style={{
                    width: '100%', padding: '10px 14px', borderRadius: 6,
                    border: '1px solid var(--border)', background: 'var(--bg)',
                    color: 'var(--text)', fontSize: 14, boxSizing: 'border-box',
                  }}
                />
                <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  Recorded for reporting. It does not price anything on its own.
                </span>
              </div>

              {/* Jurisdiction */}
              <div>
                <label
                  htmlFor="org-jurisdiction"
                  style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                >
                  Primary jurisdiction
                </label>
                <select
                  id="org-jurisdiction"
                  data-testid="input-jurisdiction"
                  value={jurisdiction}
                  onChange={(e) => setJurisdiction(e.target.value)}
                  style={{
                    width: '100%', padding: '10px 14px', borderRadius: 6,
                    border: '1px solid var(--border)', background: 'var(--bg)',
                    color: 'var(--text)', fontSize: 14, boxSizing: 'border-box',
                  }}
                >
                  <option value="">Not declared</option>
                  {JURISDICTIONS.map((j) => (
                    <option key={j.id} value={j.id}>{j.label}</option>
                  ))}
                </select>
                <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  Regimes scoped to other territories are reported as out of scope. Leaving this
                  undeclared is not the same as choosing Global.
                </span>
              </div>

              {/* Reporting currency */}
              <div>
                <label
                  htmlFor="org-reporting-currency"
                  style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                >
                  Reporting currency
                </label>
                <select
                  id="org-reporting-currency"
                  data-testid="input-reporting-currency"
                  value={reportingCurrency}
                  onChange={(e) => setReportingCurrency(e.target.value)}
                  style={{
                    width: '100%', padding: '10px 14px', borderRadius: 6,
                    border: '1px solid var(--border)', background: 'var(--bg)',
                    color: 'var(--text)', fontSize: 14, boxSizing: 'border-box',
                  }}
                >
                  <option value="">Not declared</option>
                  {REPORTING_CURRENCIES.map((code) => (
                    <option key={code} value={code}>{code}</option>
                  ))}
                </select>
                <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  The denomination every figure in your reports is expressed in.
                </span>
              </div>

              {/* Risk appetite tolerance */}
              <div>
                <label
                  htmlFor="org-risk-appetite"
                  style={{ display: 'block', fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 6 }}
                >
                  Risk appetite tolerance
                </label>
                <input
                  id="org-risk-appetite"
                  data-testid="input-risk-appetite-tolerance"
                  type="number"
                  min="0"
                  step="any"
                  value={riskAppetiteTolerance}
                  onChange={(e) => setRiskAppetiteTolerance(e.target.value)}
                  placeholder="e.g. 25000"
                  style={{
                    width: '100%', padding: '10px 14px', borderRadius: 6,
                    border: '1px solid var(--border)', background: 'var(--bg)',
                    color: 'var(--text)', fontSize: 14, boxSizing: 'border-box',
                  }}
                />
                <span style={{ display: 'block', fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  Annualised loss you will absorb before enforcement is worth its friction. This
                  is the band that turns a number into a verdict.
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* Action buttons */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 28, paddingTop: 18, borderTop: '1px solid var(--border)' }}>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={onSkip}
            data-testid="step-skip-button"
            style={{ fontSize: 13 }}
          >
            {skipLabel}
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
