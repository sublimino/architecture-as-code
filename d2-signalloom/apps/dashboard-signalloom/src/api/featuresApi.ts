import axios from 'axios'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type {
  FeaturePreset,
  FeaturesResponse,
  PresetsResponse,
  UpdateSingleFeaturePayload,
  UpdateTenantFeaturesPayload,
} from '../types/features'

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
 *
 * Rejects on any failure. It used to resolve with DEFAULT_SYSTEM_FLAGS stamped
 * with the tenant's id, which the provider could not tell apart from a real
 * answer and cached as that tenant's flags; the server is the only authority
 * on them, so a failed request is reported as one (FeatureFlagProvider retries).
 */
export async function fetchFeatures(
  token?: string | null,
  tenantId?: string | null,
  signal?: AbortSignal,
): Promise<FeaturesResponse> {
  const qs = tenantId ? `?tenant_id=${encodeURIComponent(tenantId)}` : ''
  const url = `${BASE}/api/v1/features${qs}`

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
 * Superadmin fetch for tenant feature flags and configurations from /api/v1/admin/features.
 */
export async function fetchAdminFeatures(
  token?: string | null,
  tenantId?: string | null,
  signal?: AbortSignal,
): Promise<FeaturesResponse> {
  if (!token) {
    throw new Error('Authentication token is required to fetch admin features')
  }
  const qs = tenantId && tenantId !== 'all' ? `?tenant_id=${encodeURIComponent(tenantId)}` : ''
  const url = `${BASE}/api/v1/admin/features${qs}`

  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
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
  if (!token) {
    throw new Error('Authentication token is required to fetch feature presets')
  }
  const url = `${BASE}/api/v1/admin/features/presets`

  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
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

export interface CreateAccountTypePayload {
  id: string
  name: string
  flags: Record<string, boolean>
}

/**
 * Superadmin creation of a custom account type (/api/v1/admin/account-types).
 */
export async function createAccountType(
  payload: CreateAccountTypePayload,
  token?: string | null,
): Promise<FeaturePreset> {
  const url = `${BASE}/api/v1/admin/account-types`
  const headers: Record<string, string> = {}
  if (token) headers.Authorization = `Bearer ${token}`
  const response = await axios.post<FeaturePreset>(url, payload, { headers })
  return response.data
}

/**
 * Superadmin rename of a custom account type. 403 if `id` names a built-in type.
 */
export async function renameAccountType(
  id: string,
  name: string,
  token?: string | null,
): Promise<FeaturePreset> {
  const url = `${BASE}/api/v1/admin/account-types/${encodeURIComponent(id)}`
  const headers: Record<string, string> = {}
  if (token) headers.Authorization = `Bearer ${token}`
  const response = await axios.patch<FeaturePreset>(url, { name }, { headers })
  return response.data
}

/**
 * Superadmin deletion of a custom account type. 403 if `id` names a built-in type.
 */
export async function deleteAccountType(id: string, token?: string | null): Promise<void> {
  const url = `${BASE}/api/v1/admin/account-types/${encodeURIComponent(id)}`
  const headers: Record<string, string> = {}
  if (token) headers.Authorization = `Bearer ${token}`
  await axios.delete(url, { headers })
}

// ─── React Query Hooks ─────────────────────────────────────────────────────────

const adminFeaturesKey = (tenantId?: string | null, token?: string | null) =>
  [...ADMIN_FEATURES_QUERY_KEY(tenantId), token ?? 'no-token'] as const

/**
 * The newer of two admin feature states for one tenant, by server version.
 * Replies to concurrent requests (toggles, refetches) arrive in any order; a
 * reply with a lower version than the state already held is older and is
 * dropped, so the page never steps back to it. A state without a version (a
 * server that predates migration 077) is taken as is.
 */
export function newerFeatures(
  held: FeaturesResponse | undefined,
  incoming: FeaturesResponse,
): FeaturesResponse {
  if (held?.version !== undefined && incoming.version !== undefined && held.version > incoming.version) {
    return held
  }
  return incoming
}

export function useAdminFeatures(
  tenantId?: string | null,
  token?: string | null,
  options?: { enabled?: boolean },
) {
  const queryClient = useQueryClient()
  const isEnabled = options?.enabled !== undefined ? options.enabled : Boolean(token)
  const queryKey = adminFeaturesKey(tenantId, token)

  return useQuery<FeaturesResponse, Error>({
    queryKey,
    queryFn: async ({ signal }) =>
      newerFeatures(
        queryClient.getQueryData<FeaturesResponse>(queryKey),
        await fetchAdminFeatures(token, tenantId, signal),
      ),
    enabled: isEnabled,
    staleTime: 30_000,
  })
}

/** Offer a mutation's reply to the admin features cache; it wins only if newer. */
function offerAdminFeatures(
  queryClient: ReturnType<typeof useQueryClient>,
  tenantId: string,
  token: string | null | undefined,
  data: FeaturesResponse,
): void {
  if (data?.version === undefined) {
    queryClient.invalidateQueries({ queryKey: ['adminFeatures'] })
    return
  }
  queryClient.setQueryData<FeaturesResponse>(adminFeaturesKey(tenantId, token), (held) =>
    newerFeatures(held, data),
  )
}

export function useFeaturePresets(
  token?: string | null,
  options?: { enabled?: boolean },
) {
  const isEnabled = options?.enabled !== undefined ? options.enabled : Boolean(token)

  return useQuery<PresetsResponse, Error>({
    queryKey: [...FEATURE_PRESETS_QUERY_KEY(), token ?? 'no-token'],
    queryFn: ({ signal }) => fetchFeaturePresets(token, signal),
    enabled: isEnabled,
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
    onSuccess: (data, payload) => {
      offerAdminFeatures(queryClient, payload.tenant_id, options?.token, data)
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
    onSuccess: (data, { tenantId }) => {
      // The reply is the state this toggle committed, at its version: no
      // refetch, which could land before or after another toggle's reply.
      offerAdminFeatures(queryClient, tenantId, options?.token, data)
      queryClient.invalidateQueries({ queryKey: ['featureFlags'] })
      options?.onSuccess?.(data)
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}

export function useCreateAccountType(options?: {
  token?: string | null
  onSuccess?: (data: FeaturePreset) => void
  onError?: (error: Error) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<FeaturePreset, Error, CreateAccountTypePayload>({
    mutationFn: (payload) => createAccountType(payload, options?.token),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: FEATURE_PRESETS_QUERY_KEY() })
      options?.onSuccess?.(data)
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}

export function useRenameAccountType(options?: {
  token?: string | null
  onSuccess?: (data: FeaturePreset) => void
  onError?: (error: Error) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<FeaturePreset, Error, { id: string; name: string }>({
    mutationFn: ({ id, name }) => renameAccountType(id, name, options?.token),
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: FEATURE_PRESETS_QUERY_KEY() })
      options?.onSuccess?.(data)
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}

export function useDeleteAccountType(options?: {
  token?: string | null
  onSuccess?: () => void
  onError?: (error: Error) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<void, Error, { id: string }>({
    mutationFn: ({ id }) => deleteAccountType(id, options?.token),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: FEATURE_PRESETS_QUERY_KEY() })
      options?.onSuccess?.()
    },
    onError: (err) => {
      options?.onError?.(err)
    },
  })
}
