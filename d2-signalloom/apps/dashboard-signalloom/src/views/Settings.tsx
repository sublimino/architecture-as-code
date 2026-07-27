import { useState, useEffect, useCallback } from 'react'
import type { ReactNode } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import type { TenantSettingsResponse, FrameworkResponse, NHIScan } from '../types/api'
import ErrorState from '../components/ErrorState'
import ApiKeyRotateModal from '../components/ApiKeyRotateModal'
import { useAppContext } from '../App'

const POLL_MS = 15 * 60 * 1000

function Field({ label, value, mono }: { label: string; value: string | number | null | undefined; mono?: boolean }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
      <span style={{ fontSize: 14, fontWeight: 500, color: value != null ? 'var(--text)' : 'var(--muted)', fontFamily: mono ? 'monospace' : undefined }}>
        {value ?? '—'}
      </span>
    </div>
  )
}

function FrameworkToggle({ active, onToggle }: { active: boolean; onToggle: () => void }) {
  return (
    <button
      role="switch"
      aria-checked={active}
      onClick={onToggle}
      style={{
        flexShrink: 0,
        width: 44,
        height: 24,
        borderRadius: 12,
        padding: 0,
        border: 'none',
        cursor: 'pointer',
        background: active ? '#06B6D4' : '#475569',
        transition: 'background 0.2s ease',
        position: 'relative',
      }}
    >
      <span
        style={{
          position: 'absolute',
          top: 3,
          left: active ? 23 : 3,
          width: 18,
          height: 18,
          borderRadius: '50%',
          background: 'white',
          transition: 'left 0.2s ease',
          boxShadow: '0 1px 3px rgba(0,0,0,0.3)',
        }}
      />
    </button>
  )
}

function SectionCard({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <h2 style={{ fontSize: 11, fontWeight: 700, marginBottom: 16, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{title}</h2>
      {children}
    </div>
  )
}

function ApiKeyStatus({ status }: { status: string | null | undefined }) {
  const statusMap: Record<string, { color: string; label: string }> = {
    active: { color: '#10B981', label: 'Active' },
    revoked: { color: '#DC2626', label: 'Revoked' },
    expired: { color: '#D97706', label: 'Expired' },
  }
  const info = status ? (statusMap[status] ?? { color: '#94A3B8', label: status }) : { color: '#94A3B8', label: '—' }
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
      <span style={{ width: 8, height: 8, borderRadius: '50%', background: info.color }} />
      <span style={{ color: info.color, fontWeight: 600 }}>{info.label}</span>
    </span>
  )
}

export default function Settings() {
  const { getAccessTokenSilently, user } = useAuth0()
  const { apiKeyReveal } = useAppContext()
  const [settings, setSettings] = useState<TenantSettingsResponse | null>(null)
  const [frameworks, setFrameworks] = useState<FrameworkResponse[]>([])
  const [lastScan, setLastScan] = useState<NHIScan | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedFrameworks, setSelectedFrameworks] = useState<string[]>([])
  const [toastError, setToastError] = useState<string | null>(null)
  const [rotateModalOpen, setRotateModalOpen] = useState(false)

  const load = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently()
      const [settingsRes, frameworksRes, scansRes] = await Promise.allSettled([
        api.settings(token),
        api.compliance.frameworks(token),
        api.nhi.scans(token),
      ])
      if (settingsRes.status === 'fulfilled') {
        setSettings(settingsRes.value)
        setSelectedFrameworks(settingsRes.value.selected_frameworks ?? [])
      }
      if (frameworksRes.status === 'fulfilled') setFrameworks(frameworksRes.value)
      if (scansRes.status === 'fulfilled') {
        const scans = scansRes.value.scans
        if (scans.length) {
          const sorted = [...scans].sort((a, b) =>
            new Date(b.started_at ?? 0).getTime() - new Date(a.started_at ?? 0).getTime()
          )
          setLastScan(sorted[0])
        }
      }
      if (settingsRes.status === 'rejected') {
        const msg = settingsRes.reason instanceof Error ? settingsRes.reason.message : ''
        if (msg.includes('401') || msg.includes('403')) setError('Your session has expired. Please sign in again.')
        else setError('Something went wrong loading this view. Please try refreshing.')
      } else {
        setError(null)
      }
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    load()
    const t = setInterval(load, POLL_MS)
    return () => clearInterval(t)
  }, [load])

  if (loading) return <div style={{ color: 'var(--muted)', textAlign: 'center', padding: 64 }}>Loading…</div>
  if (error) return <ErrorState message={error} onRetry={load} />

  function fmtTs(iso: string | null) {
    if (!iso) return null
    return new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })
  }

  const scanStatusColor: Record<string, string> = {
    completed: '#10B981', running: '#06B6D4', failed: '#DC2626',
  }

  return (
    <div style={{ maxWidth: 720, paddingBottom: 32 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 24 }}>Settings</h1>

      {/* Organization */}
      <SectionCard title="Organisation">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <Field label="Organisation Name" value={settings?.org_name || 'Unnamed'} />
          <Field label="Tenant ID" value={settings?.tenant_id} mono />
          <Field label="Plan Tier" value={settings?.plan_tier} />
          <Field label="Billing Tier" value={settings?.billing_tier} />
          <Field label="Enrolled Agents" value={settings?.agent_count} />
        </div>
      </SectionCard>

      {/* API Access */}
      <SectionCard title="API Access">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 16 }}>
          <div>
            <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>API Key Status</div>
            <ApiKeyStatus status={settings?.api_key_status} />
          </div>
        </div>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 12 }}>
          API keys grant programmatic access to the Signal Loom agent registry. Keys are scoped to your tenant.
        </p>
        <button
          className="btn btn-secondary"
          style={{ fontSize: 12, padding: '6px 14px' }}
          onClick={() => setRotateModalOpen(true)}
        >
          Rotate API Key
        </button>
        {rotateModalOpen && settings && (
          <ApiKeyRotateModal
            currentPrefixHint={apiKeyReveal?.prefix_hint ?? 'sl_live_'}
            doRotate={async () => {
              const token = await getAccessTokenSilently()
              return api.apiKeys.rotate(token, settings.tenant_id)
            }}
            onClose={() => setRotateModalOpen(false)}
          />
        )}
      </SectionCard>

      {/* Compliance Frameworks */}
      <SectionCard title="Compliance Frameworks">
        {toastError && (
          <div style={{ marginBottom: 12, padding: '8px 12px', background: 'rgba(220,38,38,0.08)', border: '1px solid rgba(220,38,38,0.25)', borderRadius: 6, fontSize: 12, color: '#DC2626', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            {toastError}
            <button onClick={() => setToastError(null)} style={{ background: 'none', border: 'none', color: '#DC2626', cursor: 'pointer', marginLeft: 8, fontSize: 14, lineHeight: 1 }}>✕</button>
          </div>
        )}
        {frameworks.length === 0 ? (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No frameworks available for this plan tier.</p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {frameworks.map(fw => {
              const active = selectedFrameworks.includes(fw.id)
              return (
                <div
                  key={fw.id}
                  style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 14px', background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}
                >
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>{fw.name}</div>
                    <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                      {[fw.version && `v${fw.version}`, fw.regulatory_body, `${fw.control_count} controls`].filter(Boolean).join(' · ')}
                    </div>
                  </div>
                  <FrameworkToggle
                    active={active}
                    onToggle={async () => {
                      const prev = selectedFrameworks
                      const next = active
                        ? prev.filter(id => id !== fw.id)
                        : [...prev, fw.id]
                      setSelectedFrameworks(next)
                      setToastError(null)
                      try {
                        const token = await getAccessTokenSilently()
                        const updated = await api.patchFrameworks(token, next)
                        setSelectedFrameworks(updated.selected_frameworks ?? next)
                      } catch {
                        setSelectedFrameworks(prev)
                        setToastError('Failed to update framework selection. Please try again.')
                      }
                    }}
                  />
                </div>
              )
            })}
          </div>
        )}
      </SectionCard>

      {/* NHI Discovery */}
      <SectionCard title="NHI Discovery">
        {lastScan ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 6 }}>Last Scan</div>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
                <span style={{ width: 8, height: 8, borderRadius: '50%', background: scanStatusColor[lastScan.status] ?? '#94A3B8' }} />
                <span style={{ color: scanStatusColor[lastScan.status] ?? '#94A3B8', fontWeight: 600, textTransform: 'capitalize' }}>{lastScan.status}</span>
              </span>
            </div>
            <Field label="Scan Source" value={lastScan.scan_source} />
            <Field label="Started" value={fmtTs(lastScan.started_at)} />
            <Field label="Completed" value={fmtTs(lastScan.completed_at)} />
            <Field label="Entries Scanned" value={lastScan.total_entries_scanned} />
            <Field label="Service Accounts Found" value={lastScan.service_accounts_found} />
            {lastScan.total_at_risk != null && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>At Risk</div>
                <span style={{ fontSize: 14, fontWeight: 700, color: lastScan.total_at_risk > 0 ? '#DC2626' : '#10B981' }}>
                  {lastScan.total_at_risk}
                </span>
              </div>
            )}
          </div>
        ) : (
          <p style={{ fontSize: 13, color: 'var(--muted)' }}>No scans recorded. Connect an identity provider to begin discovering non-human identities in your environment.</p>
        )}
        <div style={{ marginTop: 14, display: 'flex', gap: 16 }}>
          <a href="/onboarding" style={{ fontSize: 12, color: 'var(--cyan)', textDecoration: 'none' }}>
            Connect a provider →
          </a>
          <a href="/agents?tab=discovered" style={{ fontSize: 12, color: 'var(--cyan)', textDecoration: 'none' }}>
            View discovered accounts →
          </a>
        </div>
      </SectionCard>

      {/* Account */}
      <SectionCard title="Account">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
          <Field label="Email" value={user?.email} />
          <Field label="Name" value={user?.name} />
        </div>
      </SectionCard>

      <p style={{ marginTop: 4, color: 'var(--muted)', fontSize: 12, textAlign: 'center' }}>
        For billing or plan changes contact{' '}
        <a href="mailto:support@signal-loom.ai" style={{ color: 'var(--cyan)', textDecoration: 'none' }}>support@signal-loom.ai</a>.
      </p>
    </div>
  )
}
