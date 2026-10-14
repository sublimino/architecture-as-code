import { describe, expect, it, vi, beforeEach } from 'vitest'
import axios from 'axios'
import { fetchFeatures, FEATURE_FLAGS_QUERY_KEY } from './featuresApi'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

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

  it('falls back to DEFAULT_SYSTEM_FLAGS on network or server failure', async () => {
    vi.mocked(axios.get).mockRejectedValueOnce(new Error('500 Internal Server Error'))

    const result = await fetchFeatures('mock-token', 'tenant-err')

    expect(result.tenant_id).toBe('tenant-err')
    expect(result.flags).toEqual(DEFAULT_SYSTEM_FLAGS)
    expect(result.flags.core_governance).toBe(true)
    expect(result.flags.demos_fleet).toBe(false)
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
})

