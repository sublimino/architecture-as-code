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
})
