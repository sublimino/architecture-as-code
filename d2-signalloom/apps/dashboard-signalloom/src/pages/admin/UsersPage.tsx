import React, { useState, useEffect, useMemo, useCallback } from 'react'
import { useAuth0 } from '../../auth/oidc'
import { useServerSuperadmin } from '../../auth/superadmin'
import { useAppContext } from '../../App'
import {
  useUsers,
  useUpdateUser,
  useDeactivateUser,
  type PlatformUser,
  type UserRole,
  type UserStatus,
  type UsersApiError,
} from '../../api/usersApi'
import UserTable from './UserTable'
import InviteUserModal from '../../components/admin/InviteUserModal'
import EditUserModal from '../../components/admin/EditUserModal'
import LoadingState, { loadPhase } from '../../components/LoadingState'
import ErrorState from '../../components/ErrorState'
import EmptyState from '../../components/EmptyState'

export interface UsersPageProps {
  onInviteUser?: () => void
  onEditUser?: (user: PlatformUser) => void
  testId?: string
}

export default function UsersPage({
  onInviteUser,
  onEditUser,
  testId = 'users-page',
}: UsersPageProps) {
  const { user, getAccessTokenSilently } = useAuth0()
  const { superadmin: contextSuperadmin } = useAppContext()
  const { superadmin: serverSuperadmin } = useServerSuperadmin(user, getAccessTokenSilently)
  const isSuperadmin = serverSuperadmin || contextSuperadmin

  const [token, setToken] = useState<string | null>(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [selectedTenant, setSelectedTenant] = useState<string>('all')
  const [selectedRole, setSelectedRole] = useState<string>('all')
  const [selectedStatus, setSelectedStatus] = useState<string>('all')
  const [actionError, setActionError] = useState<string | null>(null)
  const [successToast, setSuccessToast] = useState<string | null>(null)
  const [inviteModalOpen, setInviteModalOpen] = useState(false)
  const [editingUser, setEditingUser] = useState<PlatformUser | null>(null)

  // Fetch token
  useEffect(() => {
    let mounted = true
    getAccessTokenSilently()
      .then((t) => {
        if (mounted) setToken(t)
      })
      .catch(() => {
        if (mounted) setToken(null)
      })
    return () => {
      mounted = false
    }
  }, [getAccessTokenSilently])

  // Build query params
  const queryParams = useMemo(() => {
    return {
      tenant_id: isSuperadmin && selectedTenant !== 'all' ? selectedTenant : null,
      search: searchQuery.trim() || null,
      role: selectedRole !== 'all' ? selectedRole : null,
      status: selectedStatus !== 'all' ? selectedStatus : null,
    }
  }, [isSuperadmin, selectedTenant, searchQuery, selectedRole, selectedStatus])

  // React Query hook
  const {
    data,
    isLoading: isFetching,
    isError,
    error,
    refetch,
  } = useUsers(queryParams, token, {
    enabled: true,
    refetchOnWindowFocus: true,
  })

  const users = useMemo(() => data?.users ?? [], [data])

  // Mutations
  const updateUserMutation = useUpdateUser({
    token,
    onSuccess: (updatedUser) => {
      setSuccessToast(`User "${updatedUser.display_name || updatedUser.email}" updated successfully.`)
      setActionError(null)
    },
    onError: (err: UsersApiError) => {
      setActionError(err.message || 'Failed to update user')
    },
  })

  const deactivateUserMutation = useDeactivateUser({
    token,
    onSuccess: (deactivatedUser) => {
      setSuccessToast(`User "${deactivatedUser.display_name || deactivatedUser.email}" deactivated successfully.`)
      setActionError(null)
    },
    onError: (err: UsersApiError) => {
      setActionError(err.message || 'Failed to deactivate user')
    },
  })

  // Status toggle handler
  const handleStatusChange = useCallback(
    async (targetUser: PlatformUser, newStatus: UserStatus) => {
      setActionError(null)
      try {
        await updateUserMutation.mutateAsync({
          userId: targetUser.id,
          payload: { status: newStatus },
        })
      } catch (err) {
        // error handled in onError hook
      }
    },
    [updateUserMutation],
  )

  // Deactivate handler
  const handleDeactivateUser = useCallback(
    async (targetUser: PlatformUser) => {
      if (window.confirm(`Are you sure you want to deactivate ${targetUser.display_name || targetUser.email}?`)) {
        try {
          await deactivateUserMutation.mutateAsync(targetUser.id)
        } catch {
          // error handled in onError hook
        }
      }
    },
    [deactivateUserMutation],
  )

  // Discovered tenant IDs for superadmin dropdown filter
  const tenantOptions = useMemo(() => {
    const tenants = new Set<string>()
    users.forEach((u) => {
      if (u.tenant_id) tenants.add(u.tenant_id)
    })
    return Array.from(tenants).sort()
  }, [users])

  // Summary Metrics
  const metrics = useMemo(() => {
    const total = users.length
    const active = users.filter((u) => u.status === 'active').length
    const suspended = users.filter((u) => u.status === 'suspended').length
    const admins = users.filter((u) => u.role === 'admin' || u.is_superadmin).length
    return { total, active, suspended, admins }
  }, [users])

  const hasActiveFilters =
    Boolean(searchQuery.trim()) ||
    (isSuperadmin && selectedTenant !== 'all') ||
    selectedRole !== 'all' ||
    selectedStatus !== 'all'

  const handleClearFilters = () => {
    setSearchQuery('')
    setSelectedTenant('all')
    setSelectedRole('all')
    setSelectedStatus('all')
  }

  // Clear toast timer
  useEffect(() => {
    if (successToast) {
      const timer = setTimeout(() => setSuccessToast(null), 4000)
      return () => clearTimeout(timer)
    }
  }, [successToast])

  const handleOpenInvite = () => {
    if (onInviteUser) {
      onInviteUser()
    } else {
      setInviteModalOpen(true)
    }
  }

  const handleOpenEdit = (targetUser: PlatformUser) => {
    if (onEditUser) {
      onEditUser(targetUser)
    } else {
      setEditingUser(targetUser)
    }
  }

  return (
    <div data-testid={testId} style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      {/* Breadcrumb Navigation */}
      <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--muted)' }}>
        <span>Signal Loom</span>
        <span aria-hidden="true">/</span>
        <span style={{ color: 'var(--text)', fontWeight: 600 }}>User Administration</span>
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
              User Administration
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
            Manage platform users, roles, tenant assignments, and administrative privilege across Signal Loom.
          </p>
        </div>

        {/* Primary Action Button */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <button
            type="button"
            className="btn btn-primary"
            onClick={handleOpenInvite}
            data-testid="invite-user-btn"
            aria-label="Invite new user"
            style={{
              padding: '8px 16px',
              fontSize: 13,
              fontWeight: 600,
            }}
          >
            <svg
              aria-hidden="true"
              viewBox="0 0 24 24"
              width="14"
              height="14"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <line x1="12" y1="5" x2="12" y2="19" />
              <line x1="5" y1="12" x2="19" y2="12" />
            </svg>
            <span>Invite User</span>
          </button>
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
        <div className="card" data-testid="kpi-total-users" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--muted)' }}>Total Users</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', marginTop: 4 }}>
            {metrics.total}
          </div>
        </div>
        <div className="card" data-testid="kpi-active-users" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--teal)' }}>Active Accounts</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--teal)', marginTop: 4 }}>
            {metrics.active}
          </div>
        </div>
        <div className="card" data-testid="kpi-suspended-users" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--error)' }}>Suspended</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--error)', marginTop: 4 }}>
            {metrics.suspended}
          </div>
        </div>
        <div className="card" data-testid="kpi-admin-users" style={{ padding: '14px 18px', background: 'var(--surface)' }}>
          <span className="kicker" style={{ color: 'var(--violet)' }}>Administrators</span>
          <div className="number" style={{ fontSize: 22, fontWeight: 700, color: 'var(--violet)', marginTop: 4 }}>
            {metrics.admins}
          </div>
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
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
          }}
        >
          <span>{successToast}</span>
          <button
            type="button"
            onClick={() => setSuccessToast(null)}
            aria-label="Dismiss toast"
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--teal)',
              fontSize: 14,
              cursor: 'pointer',
              padding: 4,
            }}
          >
            ✕
          </button>
        </div>
      )}

      {actionError && (
        <div
          role="alert"
          data-testid="action-error-banner"
          className="fade-in"
          style={{
            padding: '10px 16px',
            background: 'rgba(220, 38, 38, 0.12)',
            border: '1px solid rgba(220, 38, 38, 0.3)',
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
            aria-label="Dismiss error"
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--error)',
              fontSize: 14,
              cursor: 'pointer',
              padding: 4,
            }}
          >
            ✕
          </button>
        </div>
      )}

      {/* Filter Controls Toolbar */}
      <div
        className="card"
        style={{
          padding: '14px 18px',
          background: 'var(--surface)',
          display: 'flex',
          flexWrap: 'wrap',
          gap: 12,
          alignItems: 'center',
          justifyContent: 'space-between',
        }}
      >
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center', flex: 1 }}>
          {/* Search Input */}
          <div style={{ position: 'relative', minWidth: 240, maxWidth: 360, flex: 1 }}>
            <span
              aria-hidden="true"
              style={{
                position: 'absolute',
                left: 10,
                top: '50%',
                transform: 'translateY(-50%)',
                color: 'var(--muted)',
                fontSize: 12,
                pointerEvents: 'none',
              }}
            >
              🔍
            </span>
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search users by name, email, or role..."
              aria-label="Search users"
              data-testid="user-search-input"
              style={{
                width: '100%',
                paddingLeft: 30,
                paddingRight: searchQuery ? 28 : 10,
                height: 34,
                fontSize: 13,
              }}
            />
            {searchQuery && (
              <button
                type="button"
                onClick={() => setSearchQuery('')}
                aria-label="Clear search input"
                data-testid="clear-search-btn"
                style={{
                  position: 'absolute',
                  right: 8,
                  top: '50%',
                  transform: 'translateY(-50%)',
                  background: 'none',
                  border: 'none',
                  color: 'var(--muted)',
                  cursor: 'pointer',
                  padding: 2,
                }}
              >
                ✕
              </button>
            )}
          </div>

          {/* Tenant Dropdown Filter - STRICTLY Rendered ONLY for Superadmins */}
          {isSuperadmin && (
            <div data-testid="tenant-filter-wrapper" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <label htmlFor="tenant-filter-select" style={{ fontSize: 12, color: 'var(--muted)' }}>
                Tenant:
              </label>
              <select
                id="tenant-filter-select"
                value={selectedTenant}
                onChange={(e) => setSelectedTenant(e.target.value)}
                aria-label="Filter by tenant"
                data-testid="tenant-filter-select"
                style={{ height: 34, fontSize: 13, minWidth: 130 }}
              >
                <option value="all">All Tenants</option>
                {tenantOptions.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Role Filter Dropdown */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <label htmlFor="role-filter-select" style={{ fontSize: 12, color: 'var(--muted)' }}>
              Role:
            </label>
            <select
              id="role-filter-select"
              value={selectedRole}
              onChange={(e) => setSelectedRole(e.target.value)}
              aria-label="Filter by role"
              data-testid="role-filter-select"
              style={{ height: 34, fontSize: 13, minWidth: 110 }}
            >
              <option value="all">All Roles</option>
              <option value="admin">Admin</option>
              <option value="editor">Editor</option>
              <option value="viewer">Viewer</option>
            </select>
          </div>

          {/* Status Filter Dropdown */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <label htmlFor="status-filter-select" style={{ fontSize: 12, color: 'var(--muted)' }}>
              Status:
            </label>
            <select
              id="status-filter-select"
              value={selectedStatus}
              onChange={(e) => setSelectedStatus(e.target.value)}
              aria-label="Filter by status"
              data-testid="status-filter-select"
              style={{ height: 34, fontSize: 13, minWidth: 120 }}
            >
              <option value="all">All Statuses</option>
              <option value="active">Active</option>
              <option value="suspended">Suspended</option>
              <option value="invited">Invited</option>
              <option value="deactivated">Deactivated</option>
            </select>
          </div>
        </div>

        {/* Clear Filters Button */}
        {hasActiveFilters && (
          <button
            type="button"
            className="btn btn-secondary"
            onClick={handleClearFilters}
            data-testid="clear-filters-btn"
            style={{ fontSize: 12, height: 34, padding: '0 12px' }}
          >
            Clear Filters
          </button>
        )}
      </div>

      {/* Main Content Area */}
      {isError ? (
        <div className="card" style={{ padding: 24, textAlign: 'center' }}>
          <ErrorState
            message={error?.message || 'Failed to load directory platform users.'}
            onRetry={() => void refetch()}
          />
        </div>
      ) : (
        <UserTable
          users={users}
          isLoading={isFetching}
          onEditUser={handleOpenEdit}
          onDeactivateUser={handleDeactivateUser}
          onStatusChange={handleStatusChange}
          currentUserEmail={user?.email as string | undefined}
          isSuperadmin={Boolean(isSuperadmin)}
          testId="admin-user-table"
        />
      )}

      {/* Invite User Modal */}
      {inviteModalOpen && (
        <InviteUserModal
          isOpen={inviteModalOpen}
          onClose={() => setInviteModalOpen(false)}
          onSuccess={(newUser) => {
            setInviteModalOpen(false)
            setSuccessToast(`Invitation dispatched to ${newUser.email}`)
          }}
          token={token}
          isSuperadmin={Boolean(isSuperadmin)}
          availableTenants={tenantOptions}
          currentTenantId={users[0]?.tenant_id || undefined}
        />
      )}

      {/* Edit User Modal */}
      {editingUser && (
        <EditUserModal
          user={editingUser}
          isOpen={Boolean(editingUser)}
          onClose={() => setEditingUser(null)}
          onSuccess={(updatedUser) => {
            setEditingUser(null)
            setSuccessToast(`User "${updatedUser.display_name || updatedUser.email}" updated successfully.`)
          }}
          token={token}
          isSuperadmin={Boolean(isSuperadmin)}
          availableTenants={tenantOptions}
        />
      )}
    </div>
  )
}
