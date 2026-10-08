import axios from 'axios'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''

// ==============================================================================
// Types & Interfaces
// ==============================================================================

export type UserRole = 'admin' | 'editor' | 'viewer'
export type UserStatus = 'active' | 'invited' | 'suspended' | 'deactivated'

export interface PlatformUser {
  id: string
  tenant_id: string
  email: string
  display_name: string
  role: UserRole
  status: UserStatus
  is_superadmin: boolean
  avatar_url?: string | null
  department?: string | null
  title?: string | null
  last_login_at?: string | null
  created_at: string
  updated_at?: string | null
}

export interface UsersListResponse {
  users: PlatformUser[]
  total: number
}

export interface InviteUserRequest {
  email: string
  display_name?: string
  role?: UserRole
  tenant_id?: string | null
  is_superadmin?: boolean
  department?: string | null
  title?: string | null
  avatar_url?: string | null
}

export interface UpdateUserRequest {
  email?: string | null
  display_name?: string | null
  role?: UserRole | null
  status?: UserStatus | null
  tenant_id?: string | null
  is_superadmin?: boolean | null
  department?: string | null
  title?: string | null
  avatar_url?: string | null
}

export interface ListUsersParams {
  tenant_id?: string | null
  role?: UserRole | string | null
  status?: UserStatus | string | null
  search?: string | null
}

// ==============================================================================
// Error Handling & Normalization
// ==============================================================================

export class UsersApiError extends Error {
  status?: number
  code?: string
  detail?: string

  constructor(message: string, status?: number, code?: string, detail?: string) {
    super(message)
    this.name = 'UsersApiError'
    this.status = status
    this.code = code
    this.detail = detail
  }
}

interface AxiosLikeError {
  response?: {
    status?: number
    data?: unknown
  }
  status?: number
  message?: string
  isAxiosError?: boolean
}

function isAxiosLike(err: unknown): err is AxiosLikeError {
  if (axios.isAxiosError(err)) return true
  if (err && typeof err === 'object' && ('response' in err || 'isAxiosError' in err)) {
    return true
  }
  return false
}

export function normalizeUsersApiError(err: unknown, defaultAction = 'perform operation'): UsersApiError {
  if (err instanceof UsersApiError) {
    return err
  }

  if (isAxiosLike(err)) {
    const status = err.response?.status ?? err.status
    const data = err.response?.data as
      | {
          error?: string | { code?: string; message?: string }
          message?: string
          detail?: string | Array<{ msg?: string }>
        }
      | undefined

    let message: string | undefined
    let code: string | undefined
    let detail: string | undefined

    if (typeof data?.error === 'object' && data.error !== null) {
      if (typeof data.error.message === 'string') {
        message = data.error.message
      }
      if (typeof data.error.code === 'string') {
        code = data.error.code
      }
    } else if (typeof data?.error === 'string') {
      code = data.error
      if (typeof data?.message === 'string') {
        message = data.message
      } else {
        message = data.error
      }
    }

    if (!message && data?.message && typeof data.message === 'string') {
      message = data.message
    }

    if (typeof data?.detail === 'string') {
      detail = data.detail
      if (!message) {
        message = data.detail
      }
    } else if (Array.isArray(data?.detail) && data.detail[0]?.msg) {
      detail = data.detail[0].msg
      if (!message) {
        message = data.detail[0].msg
      }
    }

    // Specific status code friendly fallback messages if server didn't provide a custom message
    if (!message) {
      if (status === 403) {
        message = 'Forbidden: Superadmin or administrative privileges required'
      } else if (status === 400) {
        message = 'Bad Request: Invalid user payload or operation not permitted'
      } else if (status === 401) {
        message = 'Unauthorized: Authentication token is missing or expired'
      } else if (status === 404) {
        message = 'User not found'
      } else if (status === 409) {
        message = 'Conflict: User with this email already exists'
      } else if (err.message) {
        message = `Failed to ${defaultAction}: ${err.message}`
      } else {
        message = `Failed to ${defaultAction}`
      }
    }

    return new UsersApiError(message, status, code, detail)
  }

  if (err instanceof Error) {
    return new UsersApiError(err.message)
  }

  return new UsersApiError(`Failed to ${defaultAction}: Unknown error`)
}

// ==============================================================================
// Query Key Factory
// ==============================================================================

export const USERS_QUERY_KEY = (
  tenantId?: string | null,
  filters?: ListUsersParams,
): readonly unknown[] => {
  const base: unknown[] = ['adminUsers', tenantId ?? 'all']
  if (filters && Object.keys(filters).length > 0) {
    base.push(filters)
  }
  return base as readonly unknown[]
}

// ==============================================================================
// Raw API Client Methods
// ==============================================================================

/**
 * List directory platform users from GET /api/v1/admin/users
 */
export async function listUsers(
  paramsOrTenantId?: ListUsersParams | string | null,
  token?: string | null,
  signal?: AbortSignal,
): Promise<UsersListResponse> {
  const params: ListUsersParams =
    typeof paramsOrTenantId === 'string'
      ? { tenant_id: paramsOrTenantId }
      : paramsOrTenantId ?? {}

  const searchParams = new URLSearchParams()
  if (params.tenant_id) {
    searchParams.append('tenant_id', params.tenant_id)
  }
  if (params.search) {
    searchParams.append('search', params.search)
  }
  if (params.role) {
    searchParams.append('role', params.role)
  }
  if (params.status) {
    searchParams.append('status', params.status)
  }

  const qs = searchParams.toString() ? `?${searchParams.toString()}` : ''
  const url = `${BASE}/api/v1/admin/users${qs}`

  try {
    const headers: Record<string, string> = {}
    if (token) {
      headers.Authorization = `Bearer ${token}`
    }

    const response = await axios.get<UsersListResponse>(url, {
      headers,
      signal,
    })

    return response.data
  } catch (err) {
    if (axios.isCancel(err) || (err instanceof Error && err.name === 'AbortError')) {
      throw err
    }
    throw normalizeUsersApiError(err, 'list users')
  }
}

/**
 * Invite or provision a platform user via POST /api/v1/admin/users/invite
 */
export async function inviteUser(
  payload: InviteUserRequest,
  token?: string | null,
  signal?: AbortSignal,
): Promise<PlatformUser> {
  const url = `${BASE}/api/v1/admin/users/invite`
  try {
    const headers: Record<string, string> = {}
    if (token) {
      headers.Authorization = `Bearer ${token}`
    }

    const response = await axios.post<PlatformUser>(url, payload, {
      headers,
      signal,
    })

    return response.data
  } catch (err) {
    if (axios.isCancel(err) || (err instanceof Error && err.name === 'AbortError')) {
      throw err
    }
    throw normalizeUsersApiError(err, 'invite user')
  }
}

/**
 * Update role, status, or attributes of an existing user via PATCH /api/v1/admin/users/{user_id}
 */
export async function updateUser(
  userId: string,
  payload: UpdateUserRequest,
  token?: string | null,
  signal?: AbortSignal,
): Promise<PlatformUser> {
  const url = `${BASE}/api/v1/admin/users/${encodeURIComponent(userId)}`
  try {
    const headers: Record<string, string> = {}
    if (token) {
      headers.Authorization = `Bearer ${token}`
    }

    const response = await axios.patch<PlatformUser>(url, payload, {
      headers,
      signal,
    })

    return response.data
  } catch (err) {
    if (axios.isCancel(err) || (err instanceof Error && err.name === 'AbortError')) {
      throw err
    }
    throw normalizeUsersApiError(err, 'update user')
  }
}

/**
 * Deactivate / soft-delete a platform user via DELETE /api/v1/admin/users/{user_id}
 */
export async function deactivateUser(
  userId: string,
  token?: string | null,
  signal?: AbortSignal,
): Promise<PlatformUser> {
  const url = `${BASE}/api/v1/admin/users/${encodeURIComponent(userId)}`
  try {
    const headers: Record<string, string> = {}
    if (token) {
      headers.Authorization = `Bearer ${token}`
    }

    const response = await axios.delete<PlatformUser>(url, {
      headers,
      signal,
    })

    return response.data
  } catch (err) {
    if (axios.isCancel(err) || (err instanceof Error && err.name === 'AbortError')) {
      throw err
    }
    throw normalizeUsersApiError(err, 'deactivate user')
  }
}

export const deleteUser = deactivateUser

export const usersApi = {
  listUsers,
  inviteUser,
  updateUser,
  deactivateUser,
  deleteUser,
}

// ==============================================================================
// React Query Hooks
// ==============================================================================

export interface UseUsersOptions {
  token?: string | null
  enabled?: boolean
  staleTime?: number
  refetchOnWindowFocus?: boolean
}

/**
 * React Query hook to list platform users with optional tenant, search, role, and status filters.
 */
export function useUsers(
  params?: ListUsersParams | string | null,
  tokenOrOptions?: string | null | UseUsersOptions,
  options?: UseUsersOptions,
) {
  const token =
    typeof tokenOrOptions === 'string' || tokenOrOptions === null
      ? tokenOrOptions
      : tokenOrOptions?.token

  const opts =
    typeof tokenOrOptions === 'object' && tokenOrOptions !== null
      ? tokenOrOptions
      : options ?? {}

  const normalizedParams: ListUsersParams =
    typeof params === 'string' ? { tenant_id: params } : params ?? {}

  const tenantId = normalizedParams.tenant_id

  return useQuery<UsersListResponse, UsersApiError>({
    queryKey: USERS_QUERY_KEY(tenantId, normalizedParams),
    queryFn: ({ signal }) => listUsers(normalizedParams, token ?? opts.token, signal),
    enabled: opts.enabled ?? true,
    staleTime: opts.staleTime,
    refetchOnWindowFocus: opts.refetchOnWindowFocus,
  })
}

export interface UseInviteUserVariables {
  payload: InviteUserRequest
  token?: string | null
}

/**
 * React Query mutation hook to invite a new platform user and invalidate users cache.
 */
export function useInviteUser(options?: {
  token?: string | null
  onSuccess?: (data: PlatformUser, variables: InviteUserRequest | UseInviteUserVariables) => void
  onError?: (error: UsersApiError, variables: InviteUserRequest | UseInviteUserVariables) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<PlatformUser, UsersApiError, InviteUserRequest | UseInviteUserVariables>({
    mutationFn: async (variables) => {
      if ('payload' in variables && typeof (variables as UseInviteUserVariables).payload === 'object') {
        const withPayload = variables as UseInviteUserVariables
        return inviteUser(withPayload.payload, withPayload.token ?? options?.token)
      }
      return inviteUser(variables as InviteUserRequest, options?.token)
    },
    onSuccess: (data, variables) => {
      queryClient.invalidateQueries({ queryKey: ['adminUsers'] })
      queryClient.invalidateQueries({ queryKey: ['users'] })
      options?.onSuccess?.(data, variables)
    },
    onError: (error, variables) => {
      options?.onError?.(error, variables)
    },
  })
}

export interface UpdateUserVariables {
  userId: string
  payload: UpdateUserRequest
  token?: string | null
}

/**
 * React Query mutation hook to update a platform user and invalidate users cache.
 */
export function useUpdateUser(options?: {
  token?: string | null
  onSuccess?: (data: PlatformUser, variables: UpdateUserVariables) => void
  onError?: (error: UsersApiError, variables: UpdateUserVariables) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<PlatformUser, UsersApiError, UpdateUserVariables>({
    mutationFn: async ({ userId, payload, token }) => {
      return updateUser(userId, payload, token ?? options?.token)
    },
    onSuccess: (data, variables) => {
      queryClient.invalidateQueries({ queryKey: ['adminUsers'] })
      queryClient.invalidateQueries({ queryKey: ['users'] })
      options?.onSuccess?.(data, variables)
    },
    onError: (error, variables) => {
      options?.onError?.(error, variables)
    },
  })
}

export interface DeactivateUserVariables {
  userId: string
  token?: string | null
}

/**
 * React Query mutation hook to deactivate/delete a platform user and invalidate users cache.
 */
export function useDeactivateUser(options?: {
  token?: string | null
  onSuccess?: (data: PlatformUser, variables: string | DeactivateUserVariables) => void
  onError?: (error: UsersApiError, variables: string | DeactivateUserVariables) => void
}) {
  const queryClient = useQueryClient()

  return useMutation<PlatformUser, UsersApiError, string | DeactivateUserVariables>({
    mutationFn: async (variables) => {
      const userId = typeof variables === 'string' ? variables : variables.userId
      const token = typeof variables === 'string' ? options?.token : (variables.token ?? options?.token)
      return deactivateUser(userId, token)
    },
    onSuccess: (data, variables) => {
      queryClient.invalidateQueries({ queryKey: ['adminUsers'] })
      queryClient.invalidateQueries({ queryKey: ['users'] })
      options?.onSuccess?.(data, variables)
    },
    onError: (error, variables) => {
      options?.onError?.(error, variables)
    },
  })
}

// Aliases for compatibility
export const useUsersQuery = useUsers
export const useInviteUserMutation = useInviteUser
export const useUpdateUserMutation = useUpdateUser
export const useDeactivateUserMutation = useDeactivateUser
export const useDeleteUser = useDeactivateUser
export const useDeleteUserMutation = useDeactivateUser
