import React, { type ReactNode } from 'react'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import axios from 'axios'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import {
  USERS_QUERY_KEY,
  listUsers,
  inviteUser,
  updateUser,
  deactivateUser,
  deleteUser,
  usersApi,
  useUsers,
  useUsersQuery,
  useInviteUser,
  useInviteUserMutation,
  useUpdateUser,
  useUpdateUserMutation,
  useDeactivateUser,
  useDeactivateUserMutation,
  useDeleteUser,
  useDeleteUserMutation,
  UsersApiError,
  normalizeUsersApiError,
  type PlatformUser,
  type UsersListResponse,
  type InviteUserRequest,
  type UpdateUserRequest,
} from './usersApi'

vi.mock('axios')

const mockUser: PlatformUser = {
  id: 'usr-123',
  tenant_id: 'tenant-alpha',
  email: 'alice@example.com',
  display_name: 'Alice Example',
  role: 'admin',
  status: 'active',
  is_superadmin: false,
  avatar_url: 'https://example.com/avatar.png',
  department: 'Security Engineering',
  title: 'Lead Architect',
  last_login_at: '2026-10-08T00:00:00Z',
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-05T00:00:00Z',
}

const mockListResponse: UsersListResponse = {
  users: [mockUser],
  total: 1,
}

function createQueryClientWrapper(client?: QueryClient) {
  const queryClient =
    client ??
    new QueryClient({
      defaultOptions: {
        queries: {
          retry: false,
          gcTime: 0,
        },
        mutations: {
          retry: false,
          gcTime: 0,
        },
      },
    })
  const wrapper = ({ children }: { children: ReactNode }) => (
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  )
  return { queryClient, wrapper }
}

describe('usersApi', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(axios.isAxiosError).mockImplementation((e: any) => Boolean(e && (e.isAxiosError || e.response)))
  })

  // ============================================================================
  // 1. Query Key Generation
  // ============================================================================
  describe('USERS_QUERY_KEY', () => {
    it('generates consistent query keys for tenant scoping with adminUsers prefix', () => {
      expect(USERS_QUERY_KEY('tenant-abc')).toEqual(['adminUsers', 'tenant-abc'])
      expect(USERS_QUERY_KEY(null)).toEqual(['adminUsers', 'all'])
      expect(USERS_QUERY_KEY(undefined)).toEqual(['adminUsers', 'all'])
    })

    it('includes filters when search/role/status parameters are present', () => {
      const filters = { search: 'alice', role: 'admin' as const, status: 'active' as const }
      expect(USERS_QUERY_KEY('tenant-abc', filters)).toEqual([
        'adminUsers',
        'tenant-abc',
        filters,
      ])
    })
  })

  // ============================================================================
  // 2. listUsers API method
  // ============================================================================
  describe('listUsers', () => {
    it('fetches users list with auth token and tenant_id query parameter', async () => {
      vi.mocked(axios.get).mockResolvedValueOnce({ data: mockListResponse })

      const result = await listUsers({ tenant_id: 'tenant-alpha' }, 'mock-token-123')

      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/admin/users?tenant_id=tenant-alpha',
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token-123',
          },
        }),
      )
      expect(result).toEqual(mockListResponse)
    })

    it('supports calling with a string tenant_id parameter directly', async () => {
      vi.mocked(axios.get).mockResolvedValueOnce({ data: mockListResponse })

      const result = await listUsers('tenant-alpha', 'mock-token-123')

      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/admin/users?tenant_id=tenant-alpha',
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token-123',
          },
        }),
      )
      expect(result).toEqual(mockListResponse)
    })

    it('appends search, role, and status query parameters when provided', async () => {
      vi.mocked(axios.get).mockResolvedValueOnce({ data: mockListResponse })

      const result = await listUsers(
        { tenant_id: 'tenant-beta', search: 'alice', role: 'admin', status: 'active' },
        'mock-token-xyz',
      )

      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/admin/users?tenant_id=tenant-beta&search=alice&role=admin&status=active',
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token-xyz',
          },
        }),
      )
      expect(result).toEqual(mockListResponse)
    })

    it('handles query without explicit tenant parameter', async () => {
      vi.mocked(axios.get).mockResolvedValueOnce({ data: mockListResponse })

      const result = await listUsers(null, 'mock-token-123')

      expect(axios.get).toHaveBeenCalledWith(
        '/api/v1/admin/users',
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token-123',
          },
        }),
      )
      expect(result).toEqual(mockListResponse)
    })

    it('normalizes HTTP 403 Forbidden into UsersApiError', async () => {
      const err = new Error('Request failed with status code 403') as any
      err.isAxiosError = true
      err.response = {
        status: 403,
        data: {
          error: {
            code: 'cross_tenant_forbidden',
            message: 'Superadmin privilege required to query users for other tenants',
          },
        },
      }
      vi.mocked(axios.get).mockRejectedValueOnce(err)

      await expect(listUsers({ tenant_id: 'tenant-forbidden' }, 'token-xyz')).rejects.toThrow(
        UsersApiError,
      )

      vi.mocked(axios.get).mockRejectedValueOnce(err)

      try {
        await listUsers({ tenant_id: 'tenant-forbidden' }, 'token-xyz')
      } catch (caught: any) {
        expect(caught).toBeInstanceOf(UsersApiError)
        expect(caught.status).toBe(403)
        expect(caught.code).toBe('cross_tenant_forbidden')
        expect(caught.message).toBe('Superadmin privilege required to query users for other tenants')
      }
    })

    it('re-throws AbortError without swallowing cancellation', async () => {
      const abortError = new Error('The operation was aborted')
      abortError.name = 'AbortError'
      vi.mocked(axios.get).mockRejectedValueOnce(abortError)

      await expect(listUsers(null, 'token')).rejects.toThrow(abortError)
    })
  })

  // ============================================================================
  // 3. inviteUser API method
  // ============================================================================
  describe('inviteUser', () => {
    it('posts to /api/v1/admin/users/invite and returns invited user', async () => {
      const invitePayload: InviteUserRequest = {
        email: 'bob@example.com',
        display_name: 'Bob Operator',
        role: 'editor',
        tenant_id: 'tenant-alpha',
        department: 'Operations',
      }
      const createdUser: PlatformUser = {
        ...mockUser,
        id: 'usr-456',
        email: 'bob@example.com',
        display_name: 'Bob Operator',
        role: 'editor',
        status: 'invited',
      }

      vi.mocked(axios.post).mockResolvedValueOnce({ data: createdUser })

      const result = await inviteUser(invitePayload, 'mock-token')

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/admin/users/invite',
        invitePayload,
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token',
          },
        }),
      )
      expect(result).toEqual(createdUser)
    })

    it('normalizes HTTP 409 Conflict when user already exists', async () => {
      const err = new Error('Conflict') as any
      err.isAxiosError = true
      err.response = {
        status: 409,
        data: {
          error: {
            code: 'user_already_exists',
            message: "User with email 'bob@example.com' already exists in tenant 'tenant-alpha'",
          },
        },
      }
      vi.mocked(axios.post).mockRejectedValueOnce(err)

      try {
        await inviteUser({ email: 'bob@example.com', display_name: 'Bob' }, 'token')
        expect.unreachable('Should have thrown UsersApiError')
      } catch (caught: any) {
        expect(caught).toBeInstanceOf(UsersApiError)
        expect(caught.status).toBe(409)
        expect(caught.code).toBe('user_already_exists')
        expect(caught.message).toBe("User with email 'bob@example.com' already exists in tenant 'tenant-alpha'")
      }
    })
  })

  // ============================================================================
  // 4. updateUser API method
  // ============================================================================
  describe('updateUser', () => {
    it('patches /api/v1/admin/users/{user_id} and returns updated user', async () => {
      const updatePayload: UpdateUserRequest = {
        role: 'editor',
        status: 'active',
      }
      const updatedUser: PlatformUser = {
        ...mockUser,
        role: 'editor',
        status: 'active',
      }

      vi.mocked(axios.patch).mockResolvedValueOnce({ data: updatedUser })

      const result = await updateUser('usr-123', updatePayload, 'mock-token')

      expect(axios.patch).toHaveBeenCalledWith(
        '/api/v1/admin/users/usr-123',
        updatePayload,
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token',
          },
        }),
      )
      expect(result).toEqual(updatedUser)
    })

    it('normalizes HTTP 400 Bad Request on last superadmin demotion protection', async () => {
      const err = new Error('Bad Request') as any
      err.isAxiosError = true
      err.response = {
        status: 400,
        data: {
          error: {
            code: 'last_superadmin_protected',
            message: 'Cannot demote or deactivate the last platform superadmin',
          },
        },
      }
      vi.mocked(axios.patch).mockRejectedValueOnce(err)

      try {
        await updateUser('usr-super', { is_superadmin: false }, 'token')
        expect.unreachable('Should have thrown UsersApiError')
      } catch (caught: any) {
        expect(caught).toBeInstanceOf(UsersApiError)
        expect(caught.status).toBe(400)
        expect(caught.code).toBe('last_superadmin_protected')
        expect(caught.message).toBe('Cannot demote or deactivate the last platform superadmin')
      }
    })
  })

  // ============================================================================
  // 5. deactivateUser / deleteUser API method
  // ============================================================================
  describe('deactivateUser / deleteUser', () => {
    it('deletes /api/v1/admin/users/{user_id} and returns deactivated user', async () => {
      const deactivatedUser: PlatformUser = {
        ...mockUser,
        status: 'deactivated',
      }

      vi.mocked(axios.delete).mockResolvedValueOnce({ data: deactivatedUser })

      const result = await deactivateUser('usr-123', 'mock-token')

      expect(axios.delete).toHaveBeenCalledWith(
        '/api/v1/admin/users/usr-123',
        expect.objectContaining({
          headers: {
            Authorization: 'Bearer mock-token',
          },
        }),
      )
      expect(result).toEqual(deactivatedUser)
    })

    it('verifies deleteUser is an alias of deactivateUser', () => {
      expect(deleteUser).toBe(deactivateUser)
      expect(usersApi.deactivateUser).toBe(deactivateUser)
      expect(usersApi.deleteUser).toBe(deactivateUser)
    })
  })

  // ============================================================================
  // 6. Error Normalization Logic
  // ============================================================================
  describe('normalizeUsersApiError', () => {
    it('handles object error format { error: { code, message } }', () => {
      const err = new Error('Error') as any
      err.isAxiosError = true
      err.response = {
        status: 403,
        data: { error: { code: 'forbidden', message: 'Custom message' } },
      }

      const normalized = normalizeUsersApiError(err, 'test')
      expect(normalized.status).toBe(403)
      expect(normalized.code).toBe('forbidden')
      expect(normalized.message).toBe('Custom message')
    })

    it('handles string error format { error: "error_code", message: "detail message" }', () => {
      const err = new Error('Error') as any
      err.isAxiosError = true
      err.response = {
        status: 400,
        data: { error: 'invalid_data', message: 'Payload is invalid' },
      }

      const normalized = normalizeUsersApiError(err, 'test')
      expect(normalized.status).toBe(400)
      expect(normalized.code).toBe('invalid_data')
      expect(normalized.message).toBe('Payload is invalid')
    })

    it('handles detail field format { detail: "Detail message" }', () => {
      const err = new Error('Error') as any
      err.isAxiosError = true
      err.response = {
        status: 404,
        data: { detail: 'User usr-999 not found' },
      }

      const normalized = normalizeUsersApiError(err, 'find user')
      expect(normalized.status).toBe(404)
      expect(normalized.detail).toBe('User usr-999 not found')
      expect(normalized.message).toBe('User usr-999 not found')
    })

    it('handles Pydantic array detail [{ msg: "Field required" }]', () => {
      const err = new Error('Error') as any
      err.isAxiosError = true
      err.response = {
        status: 422,
        data: { detail: [{ msg: 'Field required: email' }] },
      }

      const normalized = normalizeUsersApiError(err, 'validate')
      expect(normalized.status).toBe(422)
      expect(normalized.message).toBe('Field required: email')
    })

    it('provides friendly fallbacks for 400 and 403 when no server message exists', () => {
      const err403 = new Error('Forbidden') as any
      err403.isAxiosError = true
      err403.response = { status: 403, data: {} }
      const norm403 = normalizeUsersApiError(err403, 'perform operation')
      expect(norm403.message).toBe('Forbidden: Superadmin or administrative privileges required')

      const err400 = new Error('Bad Request') as any
      err400.isAxiosError = true
      err400.response = { status: 400, data: {} }
      const norm400 = normalizeUsersApiError(err400, 'perform operation')
      expect(norm400.message).toBe('Bad Request: Invalid user payload or operation not permitted')
    })

    it('returns original UsersApiError unchanged', () => {
      const original = new UsersApiError('Already normalized', 500, 'internal')
      expect(normalizeUsersApiError(original)).toBe(original)
    })
  })

  // ============================================================================
  // 7. React Query Hooks & Invalidation
  // ============================================================================
  describe('React Query Hooks (invalidateQueries)', () => {
    it('useUsers / useUsersQuery fetches user list and updates hook state', async () => {
      vi.mocked(axios.get).mockResolvedValueOnce({ data: mockListResponse })
      const { wrapper } = createQueryClientWrapper()

      const { result } = renderHook(
        () => useUsers('tenant-alpha', 'mock-token'),
        { wrapper },
      )

      await waitFor(() => expect(result.current.isSuccess).toBe(true))
      expect(result.current.data).toEqual(mockListResponse)
      expect(result.current.data?.users[0].email).toBe('alice@example.com')
      expect(useUsersQuery).toBe(useUsers)
    })

    it('useInviteUser / useInviteUserMutation triggers mutation and invalidates queries', async () => {
      const createdUser: PlatformUser = { ...mockUser, id: 'usr-new' }
      vi.mocked(axios.post).mockResolvedValueOnce({ data: createdUser })

      const { queryClient, wrapper } = createQueryClientWrapper()
      const invalidateSpy = vi.spyOn(queryClient, 'invalidateQueries')

      const onSuccess = vi.fn()
      const { result } = renderHook(
        () => useInviteUser({ token: 'mock-token', onSuccess }),
        { wrapper },
      )

      await result.current.mutateAsync({
        email: 'new@example.com',
        display_name: 'New User',
      })

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/admin/users/invite',
        { email: 'new@example.com', display_name: 'New User' },
        expect.any(Object),
      )
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['adminUsers'] })
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['users'] })
      expect(onSuccess).toHaveBeenCalledWith(
        createdUser,
        { email: 'new@example.com', display_name: 'New User' },
      )
      expect(useInviteUserMutation).toBe(useInviteUser)
    })

    it('useUpdateUser / useUpdateUserMutation triggers mutation and invalidates queries', async () => {
      const updatedUser: PlatformUser = { ...mockUser, role: 'editor' }
      vi.mocked(axios.patch).mockResolvedValueOnce({ data: updatedUser })

      const { queryClient, wrapper } = createQueryClientWrapper()
      const invalidateSpy = vi.spyOn(queryClient, 'invalidateQueries')

      const onSuccess = vi.fn()
      const { result } = renderHook(
        () => useUpdateUser({ token: 'mock-token', onSuccess }),
        { wrapper },
      )

      await result.current.mutateAsync({
        userId: 'usr-123',
        payload: { role: 'editor' },
      })

      expect(axios.patch).toHaveBeenCalledWith(
        '/api/v1/admin/users/usr-123',
        { role: 'editor' },
        expect.any(Object),
      )
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['adminUsers'] })
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['users'] })
      expect(onSuccess).toHaveBeenCalledWith(
        updatedUser,
        { userId: 'usr-123', payload: { role: 'editor' } },
      )
      expect(useUpdateUserMutation).toBe(useUpdateUser)
    })

    it('useDeactivateUser / useDeactivateUserMutation triggers mutation and invalidates queries', async () => {
      const deactivatedUser: PlatformUser = { ...mockUser, status: 'deactivated' }
      vi.mocked(axios.delete).mockResolvedValueOnce({ data: deactivatedUser })

      const { queryClient, wrapper } = createQueryClientWrapper()
      const invalidateSpy = vi.spyOn(queryClient, 'invalidateQueries')

      const onSuccess = vi.fn()
      const { result } = renderHook(
        () => useDeactivateUser({ token: 'mock-token', onSuccess }),
        { wrapper },
      )

      await result.current.mutateAsync('usr-123')

      expect(axios.delete).toHaveBeenCalledWith(
        '/api/v1/admin/users/usr-123',
        expect.any(Object),
      )
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['adminUsers'] })
      expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['users'] })
      expect(onSuccess).toHaveBeenCalledWith(deactivatedUser, 'usr-123')
      expect(useDeactivateUserMutation).toBe(useDeactivateUser)
      expect(useDeleteUserMutation).toBe(useDeactivateUser)
    })

    it('useDeleteUser alias works identically to useDeactivateUser', () => {
      expect(useDeleteUser).toBe(useDeactivateUser)
    })
  })
})
