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
  useCreateAccountType,
  useRenameAccountType,
  useDeleteAccountType,
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
import ConfirmDialog from '../../components/ConfirmDialog'
import { ACCOUNT_TYPES } from '../../types/accountTypes'

/** Every page the registry can gate, in Feature Flags page order. */
const GATED_PAGES = FEATURE_CATEGORIES.flatMap((c) => c.flags)

/** Labels of the pages a flag set enables. */
function enabledPages(flags: Record<string, boolean>): string[] {
  return GATED_PAGES.filter((p) => flags[p.key]).map((p) => p.label)
}

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
  const { user, getAccessTokenSilently, token: auth0Token } = useAuth0()
  const { superadmin: contextSuperadmin } = useAppContext()
  const { superadmin: serverSuperadmin } = useServerSuperadmin(user, getAccessTokenSilently)
  const isSuperadmin = serverSuperadmin || contextSuperadmin

  const [token, setToken] = useState<string | null>(auth0Token || null)

  const derivedInitialTenant = useMemo(() => {
    if (defaultTenant) return defaultTenant
    if (auth0Token) {
      const fromToken = getTenantIdFromToken(auth0Token)
      if (fromToken) return fromToken
    }
    const profileTenant =
      (user as any)?.['https://signalloom.ai/tenant_id'] ||
      (user as any)?.tenant_id ||
      (user as any)?.tenantId
    if (profileTenant) return profileTenant
    return 'kusari'
  }, [defaultTenant, auth0Token, user])

  const [selectedTenant, setSelectedTenant] = useState<string>(derivedInitialTenant)
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

  // Custom account types: create, rename, delete. Superadmin-only (the
  // server enforces it; the controls below are disabled rather than hidden,
  // matching the account-type Apply control's pattern).
  const [newTypeId, setNewTypeId] = useState('')
  const [newTypeName, setNewTypeName] = useState('')
  const [newTypeFlags, setNewTypeFlags] = useState<Record<string, boolean>>(
    () => Object.fromEntries(Object.keys(DEFAULT_SYSTEM_FLAGS).map((k) => [k, false])),
  )
  const [renamingTypeId, setRenamingTypeId] = useState<string | null>(null)
  const [renameValue, setRenameValue] = useState('')
  const [deletingTypeId, setDeletingTypeId] = useState<string | null>(null)
  const [createTypeError, setCreateTypeError] = useState<string | null>(null)

  const createAccountTypeMutation = useCreateAccountType({
    token,
    onSuccess: () => {
      setNewTypeId('')
      setNewTypeName('')
      setNewTypeFlags(Object.fromEntries(Object.keys(DEFAULT_SYSTEM_FLAGS).map((k) => [k, false])))
      setCreateTypeError(null)
      setSuccessToast('Custom account type created.')
    },
    onError: (err) => setCreateTypeError(err.message || 'Failed to create custom account type'),
  })

  const renameAccountTypeMutation = useRenameAccountType({
    token,
    onSuccess: () => {
      setRenamingTypeId(null)
      setSuccessToast('Custom account type renamed.')
    },
    onError: (err) => setActionError(err.message || 'Failed to rename custom account type'),
  })

  const deleteAccountTypeMutation = useDeleteAccountType({
    token,
    onSuccess: () => {
      setDeletingTypeId(null)
      setSuccessToast('Custom account type deleted.')
    },
    onError: (err) => setActionError(err.message || 'Failed to delete custom account type'),
  })

  const handleCreateAccountType = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault()
      setCreateTypeError(null)
      createAccountTypeMutation.mutate({ id: newTypeId.trim(), name: newTypeName.trim(), flags: newTypeFlags })
    },
    [createAccountTypeMutation, newTypeId, newTypeName, newTypeFlags],
  )

  // Account type selection. The selected card defaults to the tenant's recorded
  // type, but only while its flags still match it: a customised tenant has no
  // card checked, so the page never claims a type the flags no longer match.
  const [selectedType, setSelectedType] = useState<string | null>(null)
  const [pendingPreset, setPendingPreset] = useState<FeaturePreset | null>(null)
  const accountTypeState = featuresData?.account_type
  const currentTypeId = accountTypeState && !accountTypeState.customised ? accountTypeState.id : null
  const checkedTypeId = selectedType ?? currentTypeId

  useEffect(() => {
    setSelectedType(null)
  }, [selectedTenant])

  // Applies after the confirm step: it replaces every flag the preset sets,
  // which changes what the tenant's users can see.
  const handleConfirmPreset = useCallback(async () => {
    const preset = pendingPreset
    if (!preset) return
    setActionError(null)
    setApplyingPreset(preset.id)
    try {
      await updateTenantMutation.mutateAsync({
        tenant_id: selectedTenant,
        preset: preset.id,
      })
      setSuccessToast(`Account type "${preset.name}" applied to "${selectedTenant}".`)
      setSelectedType(null)
    } catch (err: any) {
      setActionError(err?.message || 'Failed to apply account type')
    } finally {
      setApplyingPreset(null)
      setPendingPreset(null)
    }
  }, [pendingPreset, selectedTenant, updateTenantMutation])

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

  // Preset catalogue from the server, falling back to the built-in account types
  // when it is unavailable. Account types get the selector; anything else is a
  // bundle offered below it.
  const { accountTypes, bundles, customTypes } = useMemo(() => {
    const catalogue: FeaturePreset[] = presetsData?.presets?.length ? presetsData.presets : ACCOUNT_TYPES
    const types = catalogue.filter((p) => p.kind === 'account_type')
    return {
      accountTypes: types.length > 0 ? types : ACCOUNT_TYPES,
      bundles: catalogue.filter((p) => p.kind === 'bundle'),
      customTypes: catalogue.filter((p) => p.kind === 'custom'),
    }
  }, [presetsData])

  // Assignable types: built-ins plus every superadmin-defined custom type,
  // in the one selector -- a custom type is tenant-assignable exactly like a
  // built-in one.
  const assignableTypes = useMemo(() => [...accountTypes, ...customTypes], [accountTypes, customTypes])
  const selectedPreset = assignableTypes.find((t) => t.id === checkedTypeId) ?? null

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
      {(isFeaturesLoading || !token) && !featuresData ? (
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
          {/* Account Type Section */}
          <div className="card" data-testid="account-type-card" style={{ padding: '18px 20px', background: 'var(--surface)' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 12, marginBottom: 14 }}>
              <div>
                <h2 id="account-type-heading" style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)' }}>
                  Account type
                </h2>
                <p style={{ fontSize: 12.5, color: 'var(--muted)', marginTop: 2 }}>
                  An account type is a fixed set of feature flags. Applying one replaces every flag for this tenant.
                </p>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontSize: 12, color: 'var(--muted)' }}>Current for {selectedTenant}:</span>
                <span
                  className="tag"
                  data-testid="account-type-current"
                  style={{
                    fontWeight: 700,
                    color: accountTypeState?.customised ? 'var(--amber)' : 'var(--teal)',
                    borderColor: accountTypeState?.customised ? 'var(--amber)' : 'var(--teal)',
                  }}
                >
                  {accountTypeState?.label ?? 'Unknown'}
                </span>
              </div>
            </div>

            <div
              role="radiogroup"
              aria-labelledby="account-type-heading"
              style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12 }}
            >
              {assignableTypes.map((type) => {
                const checked = checkedTypeId === type.id
                const pages = enabledPages(type.flags)
                return (
                  <button
                    key={type.id}
                    type="button"
                    role="radio"
                    aria-checked={checked}
                    data-testid={`account-type-option-${type.id}`}
                    onClick={() => setSelectedType(type.id)}
                    style={{
                      display: 'flex',
                      flexDirection: 'column',
                      gap: 6,
                      textAlign: 'left',
                      padding: '14px 16px',
                      cursor: 'pointer',
                      color: 'var(--text)',
                      background: checked ? 'var(--surface2)' : 'var(--surface)',
                      border: `${checked ? 2 : 1}px solid ${checked ? 'var(--teal)' : 'var(--border)'}`,
                      borderRadius: 'var(--radius)',
                    }}
                  >
                    <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
                      <span style={{ fontSize: 14, fontWeight: 700 }}>{type.name}</span>
                      {type.status === 'draft' && (
                        <span className="tag" data-testid={`account-type-draft-${type.id}`} title="Exact contents pending confirmation">
                          Draft
                        </span>
                      )}
                    </span>
                    <span style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.45 }}>{type.description}</span>
                    <span data-testid={`account-type-pages-${type.id}`} style={{ fontSize: 11.5, color: 'var(--text)', lineHeight: 1.45 }}>
                      <strong>{pages.length} of {GATED_PAGES.length} pages:</strong>{' '}
                      <span style={{ color: 'var(--muted)' }}>{pages.join(', ') || 'none'}</span>
                    </span>
                  </button>
                )
              })}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 12, marginTop: 14 }}>
              {!isSuperadmin && (
                <span data-testid="account-type-superadmin-note" style={{ fontSize: 12, color: 'var(--muted)' }}>
                  Only a superadmin can change a tenant's account type.
                </span>
              )}
              <button
                type="button"
                className="btn btn-primary"
                data-testid="account-type-apply"
                disabled={!isSuperadmin || !selectedPreset || selectedPreset.id === currentTypeId || Boolean(applyingPreset) || isPresetsLoading}
                onClick={() => selectedPreset && setPendingPreset(selectedPreset)}
              >
                {applyingPreset ? 'Applying…' : 'Apply account type'}
              </button>
            </div>

            {bundles.length > 0 && (
              <div style={{ marginTop: 18, borderTop: '1px solid var(--border)', paddingTop: 12 }}>
                <h3 style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', marginBottom: 8 }}>Other preset bundles</h3>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12 }}>
                  {bundles.map((bundle) => (
                    <div
                      key={bundle.id}
                      data-testid={`preset-card-${bundle.id}`}
                      style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '12px 14px', background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 'var(--radius)' }}
                    >
                      <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)' }}>{bundle.name}</span>
                      <span style={{ fontSize: 12, color: 'var(--muted)', lineHeight: 1.45 }}>{bundle.description}</span>
                      <button
                        type="button"
                        className="btn btn-secondary"
                        data-testid={`apply-preset-${bundle.id}`}
                        disabled={!isSuperadmin || Boolean(applyingPreset) || isPresetsLoading}
                        onClick={() => setPendingPreset(bundle)}
                      >
                        Apply {bundle.name}
                      </button>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>

          {/* Custom account types: create, rename, delete. Superadmin-only. */}
          <div className="card" data-testid="custom-account-types-card" style={{ padding: '18px 20px', background: 'var(--surface)' }}>
            <h2 style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)', marginBottom: 2 }}>
              Custom account types
            </h2>
            <p style={{ fontSize: 12.5, color: 'var(--muted)', marginBottom: 14 }}>
              Define a named, exact flag set a superadmin can assign to any tenant, just like EAP View, EAP Full or
              Full. Built-in types cannot be renamed or deleted.
            </p>

            {customTypes.length > 0 && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginBottom: 16 }}>
                {customTypes.map((type) => (
                  <div
                    key={type.id}
                    data-testid={`custom-account-type-row-${type.id}`}
                    style={{
                      display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
                      padding: '10px 12px', background: 'var(--surface2)', border: '1px solid var(--border)',
                      borderRadius: 'var(--radius)',
                    }}
                  >
                    {renamingTypeId === type.id ? (
                      <form
                        style={{ display: 'flex', gap: 8, flex: 1 }}
                        onSubmit={(e) => {
                          e.preventDefault()
                          renameAccountTypeMutation.mutate({ id: type.id, name: renameValue.trim() })
                        }}
                      >
                        <input
                          value={renameValue}
                          onChange={(e) => setRenameValue(e.target.value)}
                          data-testid={`rename-account-type-input-${type.id}`}
                          aria-label={`New name for ${type.name}`}
                          style={{ flex: 1, padding: '6px 10px', fontSize: 13, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--radius)', color: 'var(--text)' }}
                        />
                        <button type="submit" className="btn btn-primary" data-testid={`rename-account-type-save-${type.id}`} style={{ padding: '6px 12px', fontSize: 12 }}>
                          Save
                        </button>
                        <button type="button" className="btn btn-secondary" onClick={() => setRenamingTypeId(null)} style={{ padding: '6px 12px', fontSize: 12 }}>
                          Cancel
                        </button>
                      </form>
                    ) : (
                      <>
                        <div>
                          <span style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--text)' }}>{type.name}</span>
                          <code style={{ marginLeft: 8, fontSize: 11, color: 'var(--muted)' }}>{type.id}</code>
                        </div>
                        <div style={{ display: 'flex', gap: 8 }}>
                          <button
                            type="button"
                            className="btn btn-secondary"
                            data-testid={`rename-account-type-${type.id}`}
                            disabled={!isSuperadmin}
                            onClick={() => {
                              setRenamingTypeId(type.id)
                              setRenameValue(type.name)
                            }}
                            style={{ padding: '6px 12px', fontSize: 12 }}
                          >
                            Rename
                          </button>
                          <button
                            type="button"
                            className="btn btn-secondary"
                            data-testid={`delete-account-type-${type.id}`}
                            disabled={!isSuperadmin}
                            onClick={() => setDeletingTypeId(type.id)}
                            style={{ padding: '6px 12px', fontSize: 12, color: 'var(--error)' }}
                          >
                            Delete
                          </button>
                        </div>
                      </>
                    )}
                  </div>
                ))}
              </div>
            )}

            <form onSubmit={handleCreateAccountType} style={{ borderTop: '1px solid var(--border)', paddingTop: 14 }}>
              <h3 style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', marginBottom: 10 }}>Create a custom account type</h3>
              <div style={{ display: 'flex', gap: 10, marginBottom: 10, flexWrap: 'wrap' }}>
                <input
                  value={newTypeId}
                  onChange={(e) => setNewTypeId(e.target.value)}
                  placeholder="id (e.g. eu_regulated)"
                  data-testid="new-account-type-id"
                  aria-label="New account type id"
                  disabled={!isSuperadmin}
                  style={{ flex: '1 1 200px', padding: '8px 12px', fontSize: 13, background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 'var(--radius)', color: 'var(--text)' }}
                />
                <input
                  value={newTypeName}
                  onChange={(e) => setNewTypeName(e.target.value)}
                  placeholder="Display name"
                  data-testid="new-account-type-name"
                  aria-label="New account type name"
                  disabled={!isSuperadmin}
                  style={{ flex: '1 1 200px', padding: '8px 12px', fontSize: 13, background: 'var(--surface2)', border: '1px solid var(--border)', borderRadius: 'var(--radius)', color: 'var(--text)' }}
                />
              </div>
              <div
                data-testid="new-account-type-flags"
                style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))', gap: 6, marginBottom: 12 }}
              >
                {Object.keys(DEFAULT_SYSTEM_FLAGS).map((flagKey) => (
                  <label key={flagKey} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--text)' }}>
                    <input
                      type="checkbox"
                      checked={Boolean(newTypeFlags[flagKey])}
                      disabled={!isSuperadmin}
                      data-testid={`new-account-type-flag-${flagKey}`}
                      onChange={(e) => setNewTypeFlags((prev) => ({ ...prev, [flagKey]: e.target.checked }))}
                    />
                    {flagKey}
                  </label>
                ))}
              </div>
              {createTypeError && (
                <div role="alert" data-testid="create-account-type-error" style={{ marginBottom: 10, fontSize: 12.5, color: 'var(--error)' }}>
                  {createTypeError}
                </div>
              )}
              {!isSuperadmin && (
                <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 10 }}>
                  Only a superadmin can create a custom account type.
                </p>
              )}
              <button
                type="submit"
                className="btn btn-primary"
                data-testid="create-account-type-submit"
                disabled={!isSuperadmin || !newTypeId.trim() || !newTypeName.trim() || createAccountTypeMutation.isPending}
              >
                {createAccountTypeMutation.isPending ? 'Creating…' : 'Create account type'}
              </button>
            </form>
          </div>

          {deletingTypeId && (
            <ConfirmDialog
              title={`Delete custom account type "${deletingTypeId}"?`}
              body="Tenants currently assigned this type keep their flags; the type simply stops existing to apply again."
              confirmLabel="Delete"
              loading={deleteAccountTypeMutation.isPending}
              onConfirm={() => deleteAccountTypeMutation.mutate({ id: deletingTypeId })}
              onCancel={() => setDeletingTypeId(null)}
            />
          )}

          {pendingPreset && (
            <ConfirmDialog
              title={`Apply ${pendingPreset.name} to ${selectedTenant}?`}
              body={`This replaces every feature flag for ${selectedTenant} and changes what its users can see. It enables ${enabledPages(pendingPreset.flags).length} of ${GATED_PAGES.length} pages: ${enabledPages(pendingPreset.flags).join(', ') || 'none'}.`}
              confirmLabel="Apply account type"
              loading={Boolean(applyingPreset)}
              onConfirm={handleConfirmPreset}
              onCancel={() => setPendingPreset(null)}
            />
          )}

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
