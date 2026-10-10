import axios from 'axios'
import type { FeaturesResponse } from '../types/features'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

const BASE = import.meta.env.VITE_API_BASE_URL ?? ''

export const FEATURE_FLAGS_QUERY_KEY = (tenantId?: string | null): [string, string] => [
  'featureFlags',
  tenantId ?? 'current',
]

/**
 * Fetch feature flag configuration for the active tenant from /api/v1/features.
 */
export async function fetchFeatures(
  token?: string | null,
  tenantId?: string | null,
  signal?: AbortSignal,
): Promise<FeaturesResponse> {
  const qs = tenantId ? `?tenant_id=${encodeURIComponent(tenantId)}` : ''
  const url = `${BASE}/api/v1/features${qs}`

  try {
    const headers: Record<string, string> = {}
    if (token) {
      headers.Authorization = `Bearer ${token}`
    }

    const response = await axios.get<FeaturesResponse>(url, {
      headers,
      signal,
    })

    return response.data
  } catch (err) {
    if (axios.isCancel(err) || (err instanceof Error && err.name === 'AbortError')) {
      throw err
    }
    // Fall back to default system flags on network or server error
    return {
      tenant_id: tenantId ?? 'fallback',
      flags: { ...DEFAULT_SYSTEM_FLAGS },
    }
  }
}
