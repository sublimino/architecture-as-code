import React, { useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { useAuth0 } from '../../auth/oidc'
import { useServerSuperadmin } from '../../auth/superadmin'
import { useAppContext } from '../../App'
import { getTenantIdFromToken } from '../../auth/tenant'
import {
  useAdminFeatures,
  useFeaturePresets,
  useUpdateTenantFeatures,
  useUpdateSingleFeature,
} from '../../api/featuresApi'
import { api } from '../../api/client'
import {
  FEATURE_CATEGORIES,
  DEFAULT_SYSTEM_FLAGS,
  type FeaturePreset,
} from '../../types/features'
import AdminNavTabs from '../../components/admin/AdminNavTabs'
import LoadingState from '../../components/LoadingState'
import ErrorState from '../../components/ErrorState'

export interface FeaturesPageProps {
  testId?: string
  defaultTenant?: string
}

function FlagToggle({
  active,
  disabled,
  onToggle,
  testId,
  label,
}: {
  active: boolean
  disabled?: boolean
  onToggle: () => void
  testId?: string
  label?: string
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-label={label}
      aria-checked={active}
      disabled={disabled}
      data-testid={testId}
      onClick={onToggle}
      style={{
        flexShrink: 0,
        width: 44,
        height: 24,
        borderRadius: 12,
        padding: 0,
        border: 'none',
        cursor: disabled ? 'not-allowed' : 'pointer',
        background: active ? 'var(--teal)' : 'rgba(255, 255, 255, 0.2)',
        transition: 'background 0.2s ease',
        position: 'relative',
        opacity: disabled ? 0.6 : 1,
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

const KNOWN_TENANTS = ['kusari', 'tenant-demo', 'default']

export default function FeaturesPage({
  testId = 'features-page',
  defaultTenant,
}: FeaturesPageProps): React.JSX.Element {
  const { user, getAccessTokenSilently } = useAuth0()
  const { superadmin: contextSuperadmin } = useAppContext()
  const { superadmin: serverSuperadmin } = useServerSuperadmin(user, getAccessTokenSilently)
  const isSuperadmin = serverSuperadmin || contextSuperadmin

  const [token, setToken] = useState<string | null>(null)
  const [selectedTenant, setSelectedTenant] = useState<string>(
    defaultTenant || 'kusari',
  )
  const [primaryTenantInfo, setPrimaryTenantInfo] = useState<{ id: string; org_name: string } | null>(null)
  const [customTenantInput, setCustomTenantInput] = useState<string>('')
  const [searchQuery, setSearchQuery] = useState('')
  const [selectedCategory, setSelectedCategory] = useState<string>('all')
  const [selectedStatus, setSelectedStatus] = useState<string>('all')
  const [actionError, setActionError] = useState<string | null>(null)
  const [successToast, setSuccessToast] = useState<string | null>(null)
  const [applyingPreset, setApplyingPreset] = useState<string | null>(null)
  const [togglingFlag, setTogglingFlag] = useState<string | null>(null)
  const hasInitializedTenantRef = useRef(false)

  // Fetch token and initialize default tenant once from settings/token
  useEffect(() => {
    let mounted = true
    getAccessTokenSilently()
      .then(async (t) => {
        if (!mounted) return
        setToken(t)
        try {
          const settings = await api.settings(t)
          if (mounted && settings?.tenant_id) {
            setPrimaryTenantInfo({ id: settings.tenant_id, org_name: settings.org_name })
            if (!hasInitializedTenantRef.current && !defaultTenant) {
              hasInitializedTenantRef.current = true
              setSelectedTenant(settings.tenant_id)
            }
          }
        } catch {
          if (!hasInitializedTenantRef.current && !defaultTenant) {
            hasInitializedTenantRef.current = true
            const extracted = getTenantIdFromToken(t)
            if (extracted && mounted) {
              setSelectedTenant(extracted)
            }
          }
        }
      })
      .catch(() => {
        if (mounted) setToken(null)
      })
    return () => {
      mounted = false
    }
  }, [getAccessTokenSilently, defaultTenant])

  // Clear toast timer
  useEffect(() => {
    if (successToast) {
      const timer = setTimeout(() => setSuccessToast(null), 4000)
      return () => clearTimeout(timer)
    }
  }, [successToast])

  const tenantOptions = useMemo(() => {
    const list = [...KNOWN_TENANTS]
    if (primaryTenantInfo?.id && !list.includes(primaryTenantInfo.id)) {
      list.unshift(primaryTenantInfo.id)
    }
    return list
  }, [primaryTenantInfo])

  // Queries
  const {
    data: featuresData,
    isLoading: isFeaturesLoading,
    isError: isFeaturesError,
    error: featuresError,
    refetch: refetchFeatures,
  } = useAdminFeatures(selectedTenant, token)

  const { data: presetsData, isLoading: isPresetsLoading } = useFeaturePresets(token)

  // Current flags map (combining default system flags with tenant response)
  const activeFlags = useMemo<Record<string, boolean>>(() => {
    return {
      ...DEFAULT_SYSTEM_FLAGS,
      ...(featuresData?.flags ?? {}),
    }
  }, [featuresData?.flags])

  // Mutations
  const updateTenantMutation = useUpdateTenantFeatures({
    token,
    onSuccess: () => {
      refetchFeatures()
    },
    onError: (err) => {
      setActionError(err.message || 'Failed to update tenant features')
    },
  })

  const updateSingleFeatureMutation = useUpdateSingleFeature({
    token,
    onSuccess: () => {
      refetchFeatures()
    },
    onError: (err) => {
      setActionError(err.message || 'Failed to update feature flag')
    },
  })

  // Apply preset handler
  const handleApplyPreset = useCallback(
    async (presetId: string, presetName: string) => {
      setActionError(null)
      setApplyingPreset(presetId)
      try {
        await updateTenantMutation.mutateAsync({
          tenant_id: selectedTenant,
          preset: presetId,
        })
        setSuccessToast(`Preset "${presetName}" applied successfully to account "${selectedTenant}".`)
      } catch (err: any) {
        setActionError(err?.message || 'Failed to apply preset bundle')
      } finally {
        setApplyingPreset(null)
      }
    },
    [selectedTenant, updateTenantMutation],
  )

  // Single toggle handler
  const handleToggleFlag = useCallback(
    async (flagKey: string, currentVal: boolean) => {
      setActionError(null)
      setTogglingFlag(flagKey)
      try {
        await updateSingleFeatureMutation.mutateAsync({
          tenantId: selectedTenant,
          flagKey,
          payload: { enabled: !currentVal },
        })
        setSuccessToast(`Flag "${flagKey}" set to ${!currentVal ? 'ENABLED' : 'DISABLED'}.`)
      } catch (err: any) {
        setActionError(err?.message || 'Failed to update feature flag')
      } finally {
        setTogglingFlag(null)
      }
    },
    [selectedTenant, updateSingleFeatureMutation],
  )

  // Summary Metrics
  const metrics = useMemo(() => {
    const keys = Object.keys(activeFlags)
    const total = keys.length
    const enabled = keys.filter((k) => activeFlags[k]).length
    const disabled = total - enabled
    return { total, enabled, disabled }
  }, [activeFlags])

  // Presets catalogue (fallback to system default presets if API loading or offline)
  const presets = useMemo<FeaturePreset[]>(() => {
    if (presetsData?.presets && presetsData.presets.length > 0) {
      return presetsData.presets
    }
    return [
      {
        id: 'eap_pilot',
        name: 'EAP Pilot',
        description:
          'Enterprise pilot preset: all core governance, audit, and compliance views active; experimental demo labs, federated services, and topology views suppressed.',
        flags: {
          core_governance: true,
          audit: true,
          compliance: true,
          demos_fleet: false,
          supercred: false,
          rbac_analysis: false,
          collusion_access: false,
          page_discovery: true,
          page_agents: true,
          page_topology: false,
          page_weave: true,
          page_signals: true,
          page_risk: true,
          page_policies: true,
          page_compliance: true,
          page_audit: true,
          page_federated_services: false,
          page_cryptography: true,
          page_credential_inventory: true,
          page_signal_store: false,
          page_feeds: false,
          page_network_tests: false,
          page_agentmaxxing: false,
        },
      },
      {
        id: 'full_demo',
        name: 'Full Platform Demo',
        description: 'All 23 platform capabilities, demo surfaces, and telemetry feeds enabled.',
        flags: {},
      },
      {
        id: 'minimal_governance',
        name: 'Minimal Governance',
        description: 'Minimal boundary view: agents registry, policy compliance, and audit trail only.',
        flags: {},
      },
    ]
  }, [presetsData])

  // Filtered categories and flags
  const filteredCategories = useMemo(() => {
    const query = searchQuery.trim().toLowerCase()

    return FEATURE_CATEGORIES.map((cat) => {
      if (selectedCategory !== 'all' && cat.id !== selectedCategory) {
        return { ...cat, flags: [] }
      }

      const flags = cat.flags.filter((flag) => {
        const isEnabled = Boolean(activeFlags[flag.key])

        if (selectedStatus === 'enabled' && !isEnabled) return false
        if (selectedStatus === 'disabled' && isEnabled) return false

        if (query) {
          const matchKey = flag.key.toLowerCase().includes(query)
          const matchLabel = flag.label.toLowerCase().includes(query)
          const matchDesc = flag.description.toLowerCase().includes(query)
          const matchRoute = flag.route?.toLowerCase().includes(query) ?? false
          if (!matchKey && !matchLabel && !matchDesc && !matchRoute) {
            return false
          }
        }

        return true
      })

      return { ...cat, flags }
    }).filter((cat) => cat.flags.length > 0)
  }, [activeFlags, searchQuery, selectedCategory, selectedStatus])

  const hasActiveFilters =
    Boolean(searchQuery.trim()) ||
    selectedCategory !== 'all' ||
    selectedStatus !== 'all'

  const handleClearFilters = () => {
    setSearchQuery('')
    setSelectedCategory('all')
    setSelectedStatus('all')
  }

  const handleCustomTenantSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (customTenantInput.trim()) {
      setSelectedTenant(customTenantInput.trim())
      setCustomTenantInput('')
    }
  }

  return (
    <div data-testid={testId} style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      {/* Breadcrumb Navigation */}
      <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--muted)' }}>
        <span>Signal Loom</span>
        <span aria-hidden="true">/</span>
        <span>Admin</span>
        <span aria-hidden="true">/</span>
        <span style={{ color: 'var(--text)', fontWeight: 600 }}>Feature Flags</span>
      </nav>

      {/* Header & Primary Actions */}
      <div
        style={{
          display: 'flex',
          alignItems: 'flex-start',
          justifyContent: 'space-between',
          flexWrap: 'wrap',
          gap: 16,
        }}
      >
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 4 }}>
            <h1 style={{ fontSize: 24, fontWeight: 700, letterSpacing: '-0.02em', color: 'var(--text)' }}>
              Feature Flags & Presets
            </h1>
            {isSuperadmin && (
              <span
                className="tag"
                data-testid="superadmin-scope-pill"
                style={{
                  background: 'rgba(139, 92, 246, 0.15)',
                  borderColor: 'rgba(139, 92, 246, 0.35)',
                  color: 'var(--violet)',
                  fontSize: 10.5,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                }}
              >
                Global Superadmin
              </span>
            )}
          </div>
          <p style={{ fontSize: 13, color: 'var(--muted)', maxWidth: 640 }}>
            Configure granular platform capabilities, route access, and enterprise preset bundles per tenant account.
          </p>
        </div>

        {/* Tenant Selector Controls */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <label htmlFor="admin-tenant-select" style={{ fontSize: 12, fontWeight: 600, color: 'var(--muted)' }}>
              Account Scope:
            </label>
            <select
              id="admin-tenant-select"
              data-testid="admin-tenant-select"
              value={tenantOptions.includes(selectedTenant) ? selectedTenant : 'custom'}
              onChange={(e) => {
                if (e.target.value !== 'custom') {
                  setSelectedTenant(e.target.value)
                }
              }}
              style={{
                padding: '6px 12px',
                fontSize: 13,
                fontWeight: 600,
                background: 'var(--surface)',
                border: '1px solid var(--border)',
                borderRadius: 'var(--radius)',
                color: 'var(--text)',
                cursor: 'pointer',
              }}
            >
              {tenantOptions.map((t) => {
                const isPrimary = primaryTenantInfo?.id === t
                const label = isPrimary && primaryTenantInfo?.org_name
                  ? `${primaryTenantInfo.org_name} (${t})`
                  : t
                return (
                  <option key={t} value={t}>
                    {label}
                  </option>
                )
              })}
              {!tenantOptions.includes(selectedTenant) && (
                <option value="custom">Custom: {selectedTenant}</option>
              )}
            </select>
          </div>

          <form onSubmit={handleCustomTenantSubmit} style={{ display: 'flex', gap: 6 }}>
            <input
              type="text"
              placeholder="Other tenant ID..."
              value={customTenantInput}
              onChange={(e) => setCustomTenantInput(e.target.value)}
              data-testid="custom-tenant-input"
              aria-label="Target Tenant ID"
              style={{
                padding: '6px 10px',
                fontSize: 12,
                background: 'var(--surface)',
                border: '1px solid var(--border)',
                borderRadius: 'var(--radius)',
                color: 'var(--text)',
                width: 140,
              }}
            />
            <button
              type="submit"
              className="btn btn-secondary"
              data-testid="switch-tenant-btn"
              style={{ padding: '6px 12px', fontSize: 12 }}
            >
              Switch
            </button>
          </form>
        </div>
      </div>

      {/* Admin Sub-navigation Tabs */}
      <AdminNavTabs />

      {/* Main Content Area with Loading & Error States */}
      {isFeaturesLoading && !featuresData ? (
        <div className="card" style={{ padding: 48, textAlign: 'center' }}>
          <LoadingState status="loading" label="feature flags" />
        </div>
      ) : isFeaturesError && !featuresData ? (
        <div className="card" style={{ padding: 24, textAlign: 'center' }}>
          <ErrorState
            message={featuresError?.message || 'Unable to retrieve feature flag states from server.'}
            onRetry={() => refetchFeatures()}
          />
        </div>
      ) : (
        <>
          {/* Preset Bundles Section */}
          <div
            className="card"
            data-testid="preset-bundles-card"
        style={{
          padding: '18px 20px',
          background: 'linear-gradient(180deg, rgba(20, 184, 166, 0.06) 0%, var(--surface) 100%)',
          border: '1px solid rgba(20, 184, 166, 0.25)',
          borderRadius: 'var(--radius)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12, marginBottom: 14 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <h2 style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>
                Enterprise Preset Bundles
              </h2>
              <span
                className="tag"
                style={{
                  background: 'rgba(20, 184, 166, 0.15)',
                  color: 'var(--teal)',
                  borderColor: 'rgba(20, 184, 166, 0.3)',
                  fontSize: 10,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                }}
              >
                Target: {selectedTenant}
              </span>
            </div>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', marginTop: 2 }}>
              One-click preset composition for rapid onboarding, enterprise pilots, and compliance assessments.
            </p>
          </div>
        </div>

        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))',
            gap: 12,
          }}
        >
          {presets.map((preset) => {
            const isEap = preset.id === 'eap_pilot'
            const isApplying = applyingPreset === preset.id

            return (
              <div
                key={preset.id}
                data-testid={`preset-card-${preset.id}`}
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  justifyContent: 'space-between',
                  padding: '14px 16px',
                  background: isEap ? 'color-mix(in srgb, var(--teal) 8%, transparent)' : 'var(--surface2)',
                  border: `1px solid ${isEap ? 'color-mix(in srgb, var(--teal) 40%, transparent)' : 'var(--border)'}`,
                  borderRadius: 'var(--radius)',
                }}
              >
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                    <span style={{ fontSize: 14, fontWeight: 700, color: isEap ? 'var(--teal)' : 'var(--text)' }}>
                      {preset.name}
                    </span>
                    {isEap && (
                      <span
                        style={{
                          fontSize: 9.5,
                          fontWeight: 700,
                          padding: '2px 6px',
                          borderRadius: 4,
                          background: 'var(--teal)',
                          color: 'var(--on-accent)',
                          textTransform: 'uppercase',
                          letterSpacing: '0.04em',
                        }}
                      >
                        Recommended for EAP
                      </span>
                    )}
                  </div>
                  <p style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.45, marginBottom: 12 }}>
                    {preset.description}
                  </p>
                </div>

                <button
                  type="button"
                  className={isEap ? 'btn btn-primary' : 'btn btn-secondary'}
                  data-testid={`apply-preset-${preset.id}`}
                  disabled={Boolean(applyingPreset) || isPresetsLoading}
                  onClick={() => handleApplyPreset(preset.id, preset.name)}
                  style={{
                    width: '100%',
                    padding: '8px 12px',
                    fontSize: 12,
                    fontWeight: 600,
                    cursor: applyingPreset ? 'not-allowed' : 'pointer',
                  }}
                >
                  {isApplying ? 'Applying Preset...' : `Apply ${preset.name}`}
                </button>
              </div>
            )
          })}
        </div>
      </div>

      {/* Summary KPI Cards */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
          gap: 12,
        }}
      >
        <div className="card" data-testid="kpi-total-flags" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--muted)' }}>Configured Flags</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', marginTop: 4 }}>
            {metrics.total}
          </div>
        </div>
        <div className="card" data-testid="kpi-enabled-flags" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--teal)' }}>Active / Enabled</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--teal)', marginTop: 4 }}>
            {metrics.enabled}
          </div>
        </div>
        <div className="card" data-testid="kpi-disabled-flags" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--muted)' }}>Gated / Disabled</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--muted)', marginTop: 4 }}>
            {metrics.disabled}
          </div>
        </div>
        <div className="card" data-testid="kpi-account-scope" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--violet)' }}>
            {primaryTenantInfo?.id === selectedTenant ? 'Primary Account Scope' : 'Active Account'}
          </span>
          <div className="number" style={{ fontSize: 18, fontWeight: 700, color: 'var(--violet)', marginTop: 4, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {selectedTenant}
          </div>
          {primaryTenantInfo?.id === selectedTenant && primaryTenantInfo.org_name && (
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {primaryTenantInfo.org_name}
            </div>
          )}
        </div>
      </div>

      {/* Toast & Error Alerts */}
      {successToast && (
        <div
          role="status"
          aria-live="polite"
          data-testid="success-toast"
          className="fade-in"
          style={{
            padding: '10px 16px',
            background: 'rgba(16, 185, 129, 0.12)',
            border: '1px solid rgba(16, 185, 129, 0.3)',
            borderRadius: 'var(--radius)',
            color: 'var(--teal)',
            fontSize: 13,
            fontWeight: 500,
          }}
        >
          {successToast}
        </div>
      )}

      {actionError && (
        <div
          role="alert"
          data-testid="action-error-banner"
          style={{
            padding: '10px 16px',
            background: 'rgba(239, 68, 68, 0.1)',
            border: '1px solid rgba(239, 68, 68, 0.3)',
            borderRadius: 'var(--radius)',
            color: 'var(--error)',
            fontSize: 13,
            fontWeight: 500,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <span>{actionError}</span>
          <button
            type="button"
            onClick={() => setActionError(null)}
            style={{ background: 'none', border: 'none', color: 'inherit', cursor: 'pointer', fontSize: 16 }}
            aria-label="Dismiss error"
          >
            ×
          </button>
        </div>
      )}

      {/* Search & Filter Toolbar */}
      <div
        className="card"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          padding: '12px 16px',
          flexWrap: 'wrap',
          background: 'var(--surface)',
        }}
      >
        <div style={{ flex: '1 1 240px', minWidth: 200 }}>
          <input
            type="search"
            placeholder="Search flags by name, key, or route..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            data-testid="feature-search-input"
            aria-label="Search feature flags"
            style={{
              width: '100%',
              padding: '8px 12px',
              fontSize: 13,
              background: 'var(--surface2)',
              border: '1px solid var(--border)',
              borderRadius: 'var(--radius)',
              color: 'var(--text)',
            }}
          />
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <label htmlFor="filter-category" style={{ fontSize: 12, color: 'var(--muted)' }}>
            Category:
          </label>
          <select
            id="filter-category"
            data-testid="filter-category-select"
            value={selectedCategory}
            onChange={(e) => setSelectedCategory(e.target.value)}
            style={{
              padding: '6px 10px',
              fontSize: 12,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 'var(--radius)',
              color: 'var(--text)',
            }}
          >
            <option value="all">All Categories</option>
            {FEATURE_CATEGORIES.map((cat) => (
              <option key={cat.id} value={cat.id}>
                {cat.title}
              </option>
            ))}
          </select>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <label htmlFor="filter-status" style={{ fontSize: 12, color: 'var(--muted)' }}>
            Status:
          </label>
          <select
            id="filter-status"
            data-testid="filter-status-select"
            value={selectedStatus}
            onChange={(e) => setSelectedStatus(e.target.value)}
            style={{
              padding: '6px 10px',
              fontSize: 12,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 'var(--radius)',
              color: 'var(--text)',
            }}
          >
            <option value="all">All Statuses</option>
            <option value="enabled">Enabled Only</option>
            <option value="disabled">Disabled Only</option>
          </select>
        </div>

        {hasActiveFilters && (
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleClearFilters}
            data-testid="clear-filters-btn"
            style={{ padding: '6px 12px', fontSize: 12 }}
          >
            Clear Filters
          </button>
        )}
      </div>

      {/* Feature Flag Category Sections */}
      {filteredCategories.length === 0 && !isFeaturesLoading && (
        <div
          className="card"
          data-testid="no-matching-flags"
          style={{
            padding: '32px 20px',
            textAlign: 'center',
            color: 'var(--muted)',
            background: 'var(--surface)',
          }}
        >
          <p style={{ fontSize: 14, fontWeight: 500 }}>No feature flags match your search filters.</p>
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleClearFilters}
            style={{ marginTop: 12, fontSize: 12 }}
          >
            Reset Filters
          </button>
        </div>
      )}

      {filteredCategories.map((category) => (
        <div key={category.id} data-testid={`category-group-${category.id}`} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div style={{ borderBottom: '1px solid var(--border)', paddingBottom: 6 }}>
            <h2 style={{ fontSize: 15, fontWeight: 700, color: 'var(--text)' }}>
              {category.title}
            </h2>
            <p style={{ fontSize: 12, color: 'var(--muted)' }}>
              {category.description}
            </p>
          </div>

          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))',
              gap: 12,
            }}
          >
            {category.flags.map((flag) => {
              const isEnabled = Boolean(activeFlags[flag.key])
              const isToggling = togglingFlag === flag.key

              return (
                <div
                  key={flag.key}
                  data-testid={`flag-card-${flag.key}`}
                  className="card"
                  style={{
                    padding: '14px 16px',
                    display: 'flex',
                    flexDirection: 'column',
                    justifyContent: 'space-between',
                    gap: 12,
                    background: 'var(--surface)',
                    border: `1px solid ${isEnabled ? 'rgba(20, 184, 166, 0.25)' : 'var(--border)'}`,
                  }}
                >
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 4 }}>
                      <span style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--text)' }}>
                        {flag.label}
                      </span>
                      <span
                        data-testid={`flag-status-pill-${flag.key}`}
                        style={{
                          fontSize: 10,
                          fontWeight: 700,
                          padding: '2px 6px',
                          borderRadius: 4,
                          background: isEnabled ? 'rgba(20, 184, 166, 0.15)' : 'rgba(255, 255, 255, 0.05)',
                          color: isEnabled ? 'var(--teal)' : 'var(--muted)',
                          border: `1px solid ${isEnabled ? 'rgba(20, 184, 166, 0.35)' : 'var(--border)'}`,
                          textTransform: 'uppercase',
                        }}
                      >
                        {isEnabled ? 'Enabled' : 'Disabled'}
                      </span>
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
                      <code
                        data-testid={`flag-key-${flag.key}`}
                        style={{
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: 'var(--muted)',
                          background: 'rgba(255, 255, 255, 0.04)',
                          padding: '2px 4px',
                          borderRadius: 3,
                        }}
                      >
                        {flag.key}
                      </code>
                      {flag.route && (
                        <span
                          style={{
                            fontSize: 10.5,
                            color: 'var(--teal)',
                            background: 'rgba(20, 184, 166, 0.08)',
                            padding: '1px 5px',
                            borderRadius: 3,
                          }}
                        >
                          {flag.route}
                        </span>
                      )}
                    </div>

                    <p style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.45 }}>
                      {flag.description}
                    </p>
                  </div>

                  <div
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      borderTop: '1px solid rgba(255, 255, 255, 0.05)',
                      paddingTop: 8,
                      marginTop: 4,
                    }}
                  >
                    <span style={{ fontSize: 11.5, color: isEnabled ? 'var(--teal)' : 'var(--muted)', fontWeight: 500 }}>
                      {isToggling ? 'Updating...' : isEnabled ? 'Route Accessible' : 'Route Restricted (404)'}
                    </span>

                    <FlagToggle
                      active={isEnabled}
                      disabled={isToggling}
                      onToggle={() => handleToggleFlag(flag.key, isEnabled)}
                      testId={`flag-toggle-${flag.key}`}
                      label={`Toggle ${flag.label}`}
                    />
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      ))}
      </>
      )}
    </div>
  )
}
