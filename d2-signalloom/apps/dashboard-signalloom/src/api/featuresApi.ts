import axios from 'axios'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type {
  FeaturesResponse,
  PresetsResponse,
  UpdateSingleFeaturePayload,
  UpdateTenantFeaturesPayload,
} from '../types/features'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

const BASE = import.meta.env.VITE_API_BASE_URL ?? ''

export const FEATURE_FLAGS_QUERY_KEY = (tenantId?: string | null): [string, string] => [
  'featureFlags',
  tenantId ?? 'current',
]

export const ADMIN_FEATURES_QUERY_KEY = (tenantId?: string | null): [string, string] => [
  'adminFeatures',
  tenantId ?? 'all',
]

export const FEATURE_PRESETS_QUERY_KEY = (): [string] => ['featurePresets']

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

/**
 * Superadmin fetch for tenant feature flags and configurations from /api/v1/admin/features.
 */
export async function fetchAdminFeatures(
  token?: string | null,
  tenantId?: string | null,
  signal?: AbortSignal,
): Promise<FeaturesResponse> {
  const qs = tenantId && tenantId !== 'all' ? `?tenant_id=${encodeURIComponent(tenantId)}` : ''
  const url = `${BASE}/api/v1/admin/features${qs}`

  const headers: Record<string, string> = {}
  if (token) {
    headers.Authorization = `Bearer ${token}`
  }

  const response = await axios.get<FeaturesResponse>(url, {
    headers,
    signal,
  })

  return response.data
}

/**
 * Fetch catalogued feature presets from /api/v1/admin/features/presets.
 */
export async function fetchFeaturePresets(
  token?: string | null,
  signal?: AbortSignal,
): Promise<PresetsResponse> {
  const url = `${BASE}/api/v1/admin/features/presets`

  const headers: Record<string, string> = {}
  if (token) {
    headers.Authorization = `Bearer ${token}`
  }

  const response = await axios.get<PresetsResponse>(url, {
    headers,
    signal,
  })

  return response.data
}

/**
 * Superadmin batch update or preset application for tenant feature flags.
 */
export async function updateTenantFeatures(
  payload: UpdateTenantFeaturesPayload,
  token?: string | null,
): Promise<FeaturesResponse> {
  const url = `${BASE}/api/v1/admin/features`

  const headers: Record<string, string> = {}
  if (token) {
    headers.Authorization = `Bearer ${token}`
  }

  const response = await axios.put<FeaturesResponse>(url, payload, { headers })
  return response.data
}

/**
 * Superadmin update for an individual feature flag on a tenant.
 */
export async function updateSingleFeature(
  tenantId: string,
  flagKey: string,
  payload: UpdateSingleFeaturePayload,
  token?: string | null,
): Promise<FeaturesResponse> {
  const url = `${BASE}/api/v1/admin/features/${encodeURIComponent(flagKey)}?tenant_id=${encodeURIComponent(tenantId)}`

  const headers: Record<string, string> = {}
  if (token) {
    headers.Authorization = `Bearer ${token}`
  }

  const response = await axios.put<FeaturesResponse>(url, payload, { headers })
  return response.data
}

// ─── React Query Hooks ─────────────────────────────────────────────────────────

export function useAdminFeatures(tenantId?: string | null, token?: string | null) {
  return useQuery<FeaturesResponse, Error>({
    queryKey: ADMIN_FEATURES_QUERY_KEY(tenantId),
    queryFn: ({ signal }) => fetchAdminFeatures(token, tenantId, signal),
    staleTime: 30_000,
  })
}

export function useFeaturePresets(token?: string | null) {
  return useQuery<PresetsResponse, Error>({
    queryKey: FEATURE_PRESETS_QUERY_KEY(),
    queryFn: ({ signal }) => fetchFeaturePresets(token, signal),
    staleTime: 60_000,
  })
}

export function useUpdateTenantFeatures(options?: {
  token?: string | null
  onSuccess?: (data: FeaturesResponse) => void
  onError?: (error: Error) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<FeaturesResponse, Error, UpdateTenantFeaturesPayload>({
    mutationFn: (payload) => updateTenantFeatures(payload, options?.token),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['adminFeatures'] })
      queryClient.invalidateQueries({ queryKey: ['featureFlags'] })
      options?.onSuccess?.(data)
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}

export function useUpdateSingleFeature(options?: {
  token?: string | null
  onSuccess?: (data: FeaturesResponse) => void
  onError?: (error: Error) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<
    FeaturesResponse,
    Error,
    { tenantId: string; flagKey: string; payload: UpdateSingleFeaturePayload }
  >({
    mutationFn: ({ tenantId, flagKey, payload }) =>
      updateSingleFeature(tenantId, flagKey, payload, options?.token),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['adminFeatures'] })
      queryClient.invalidateQueries({ queryKey: ['featureFlags'] })
      options?.onSuccess?.(data)
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}
