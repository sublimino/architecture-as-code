import { describe, expect, it, vi, beforeEach } from 'vitest'
import axios from 'axios'
import { fetchFeatures, FEATURE_FLAGS_QUERY_KEY } from './featuresApi'

vi.mock('axios')

describe('featuresApi', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('generates consistent query keys for tenant scoping', () => {
    expect(FEATURE_FLAGS_QUERY_KEY('tenant-abc')).toEqual(['featureFlags', 'tenant-abc'])
    expect(FEATURE_FLAGS_QUERY_KEY(null)).toEqual(['featureFlags', 'current'])
  })

  it('fetches feature flags successfully with auth bearer token', async () => {
    const mockData = {
      tenant_id: 'tenant-123',
      flags: {
        core_governance: true,
        demos_fleet: true,
      },
      details: {
        demos_fleet: { enabled: true, config: {} },
      },
    }

    vi.mocked(axios.get).mockResolvedValueOnce({ data: mockData })

    const result = await fetchFeatures('mock-token-xyz', 'tenant-123')

    expect(axios.get).toHaveBeenCalledWith(
      '/api/v1/features?tenant_id=tenant-123',
      expect.objectContaining({
        headers: {
          Authorization: 'Bearer mock-token-xyz',
        },
      }),
    )
    expect(result).toEqual(mockData)
  })

  it('handles query without explicit tenant override', async () => {
    const mockData = {
      tenant_id: 'tenant-default',
      flags: { core_governance: true },
    }

    vi.mocked(axios.get).mockResolvedValueOnce({ data: mockData })

    const result = await fetchFeatures('mock-token')

    expect(axios.get).toHaveBeenCalledWith(
      '/api/v1/features',
      expect.objectContaining({
        headers: {
          Authorization: 'Bearer mock-token',
        },
      }),
    )
    expect(result).toEqual(mockData)
  })

  it('rejects on network or server failure instead of inventing the tenant flags', async () => {
    // A failed request is an error. Returning DEFAULT_SYSTEM_FLAGS stamped with
    // the tenant's id made it indistinguishable from a real answer, so the
    // provider cached it as that tenant's flags for the whole stale window.
    vi.mocked(axios.get).mockRejectedValueOnce(new Error('Request failed with status code 502'))

    await expect(fetchFeatures('mock-token', 'tenant-err')).rejects.toThrow('status code 502')
  })

  it('fetches admin features for a specific tenant', async () => {
    const mockAdminData = {
      tenant_id: 'tenant-kusari',
      flags: { page_discovery: true, demos_fleet: false },
      details: {},
    }
    vi.mocked(axios.get).mockResolvedValueOnce({ data: mockAdminData })

    const { fetchAdminFeatures } = await import('./featuresApi')
    const result = await fetchAdminFeatures('mock-superadmin-token', 'tenant-kusari')

    expect(axios.get).toHaveBeenCalledWith(
      '/api/v1/admin/features?tenant_id=tenant-kusari',
      expect.objectContaining({
        headers: { Authorization: 'Bearer mock-superadmin-token' },
      }),
    )
    expect(result).toEqual(mockAdminData)
  })

  it('fetches feature presets catalogue', async () => {
    const mockPresets = {
      presets: [
        { id: 'eap_pilot', name: 'EAP Pilot', description: 'desc', flags: {} },
      ],
    }
    vi.mocked(axios.get).mockResolvedValueOnce({ data: mockPresets })

    const { fetchFeaturePresets } = await import('./featuresApi')
    const result = await fetchFeaturePresets('mock-token')

    expect(axios.get).toHaveBeenCalledWith(
      '/api/v1/admin/features/presets',
      expect.objectContaining({
        headers: { Authorization: 'Bearer mock-token' },
      }),
    )
    expect(result).toEqual(mockPresets)
  })

  it('updates tenant features with batch payload', async () => {
    const mockUpdated = {
      tenant_id: 'tenant-kusari',
      flags: { page_agentmaxxing: true },
      details: {},
    }
    vi.mocked(axios.put).mockResolvedValueOnce({ data: mockUpdated })

    const { updateTenantFeatures } = await import('./featuresApi')
    const result = await updateTenantFeatures(
      { tenant_id: 'tenant-kusari', preset: 'eap_pilot' },
      'mock-superadmin-token',
    )

    expect(axios.put).toHaveBeenCalledWith(
      '/api/v1/admin/features',
      { tenant_id: 'tenant-kusari', preset: 'eap_pilot' },
      expect.objectContaining({
        headers: { Authorization: 'Bearer mock-superadmin-token' },
      }),
    )
    expect(result).toEqual(mockUpdated)
  })

  it('detects and prevents 401s: useAdminFeatures and useFeaturePresets must not fire unauthenticated requests when token is absent or null', async () => {
    const { QueryClient, QueryClientProvider } = await import('@tanstack/react-query')
    const { renderHook } = await import('@testing-library/react')
    const React = await import('react')
    const { useAdminFeatures, useFeaturePresets } = await import('./featuresApi')

    const queryClient = new QueryClient({
      defaultOptions: {
        queries: { retry: false },
      },
    })
    const wrapper = ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children)

    // Render hooks with null token (as happens on initial page mount before getAccessTokenSilently resolves)
    renderHook(() => useAdminFeatures('kusari', null), { wrapper })
    renderHook(() => useFeaturePresets(null), { wrapper })

    // Must NOT fire unauthenticated requests to protected admin endpoints!
    expect(axios.get).not.toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/admin/features'),
      expect.anything(),
    )
  })

  it('rejects fetchAdminFeatures and fetchFeaturePresets when token is missing', async () => {
    const { fetchAdminFeatures, fetchFeaturePresets } = await import('./featuresApi')

    await expect(fetchAdminFeatures(null, 'kusari')).rejects.toThrow(
      'Authentication token is required to fetch admin features',
    )
    await expect(fetchFeaturePresets(undefined)).rejects.toThrow(
      'Authentication token is required to fetch feature presets',
    )
  })
})


