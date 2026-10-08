import React, { useState, useMemo } from 'react'
import type { PlatformUser, UserRole, UserStatus } from '../../api/usersApi'
import ConfirmDialog from '../../components/ConfirmDialog'
import EmptyState from '../../components/EmptyState'

export interface UserTableProps {
  users: PlatformUser[]
  isLoading?: boolean
  onEditUser?: (user: PlatformUser) => void
  onDeactivateUser?: (user: PlatformUser) => void
  onStatusChange?: (user: PlatformUser, newStatus: UserStatus) => Promise<void> | void
  currentUserEmail?: string | null
  isSuperadmin?: boolean
  pageSize?: number
  testId?: string
}

type SortField = 'name' | 'email' | 'tenant' | 'role' | 'status' | 'created'
type SortOrder = 'asc' | 'desc'

// ==============================================================================
// Role & Status Badge Helpers
// ==============================================================================

export function RoleBadge({ role, isSuperadmin }: { role: UserRole | string; isSuperadmin?: boolean }) {
  const normalizedRole = role?.toLowerCase()

  let bg = 'rgba(148, 163, 184, 0.12)'
  let border = 'rgba(148, 163, 184, 0.25)'
  let color = 'var(--muted)'
  let label = 'Viewer'

  if (normalizedRole === 'admin') {
    bg = 'rgba(139, 92, 246, 0.15)'
    border = 'rgba(139, 92, 246, 0.35)'
    color = 'var(--violet)'
    label = 'Admin'
  } else if (normalizedRole === 'editor') {
    bg = 'rgba(6, 182, 212, 0.15)'
    border = 'rgba(6, 182, 212, 0.35)'
    color = 'var(--cyan)'
    label = 'Editor'
  } else if (normalizedRole === 'viewer') {
    bg = 'rgba(148, 163, 184, 0.12)'
    border = 'rgba(148, 163, 184, 0.25)'
    color = 'var(--muted)'
    label = 'Viewer'
  }

  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
      <span
        className="tag"
        data-testid={`role-badge-${normalizedRole}`}
        style={{
          background: bg,
          borderColor: border,
          color,
          fontSize: 11,
          fontWeight: 600,
          textTransform: 'uppercase',
          letterSpacing: '0.05em',
        }}
      >
        {label}
      </span>
      {isSuperadmin && (
        <span
          className="tag"
          data-testid="superadmin-badge"
          style={{
            background: 'linear-gradient(135deg, rgba(139, 92, 246, 0.2), rgba(245, 158, 11, 0.2))',
            borderColor: 'rgba(245, 158, 11, 0.4)',
            color: 'var(--amber)',
            fontSize: 10.5,
            fontWeight: 700,
            textTransform: 'uppercase',
            letterSpacing: '0.06em',
          }}
          title="Platform Superadmin: global cross-tenant administrative authority"
        >
          ★ Superadmin
        </span>
      )}
    </div>
  )
}

export function StatusIndicator({ status }: { status: UserStatus | string }) {
  const normalized = status?.toLowerCase()
  let dotColor = 'var(--teal)'
  let label = 'Active'
  let bg = 'rgba(16, 185, 129, 0.12)'
  let border = 'rgba(16, 185, 129, 0.25)'

  if (normalized === 'suspended') {
    dotColor = 'var(--error)'
    label = 'Suspended'
    bg = 'rgba(220, 38, 38, 0.12)'
    border = 'rgba(220, 38, 38, 0.25)'
  } else if (normalized === 'invited') {
    dotColor = 'var(--amber)'
    label = 'Invited'
    bg = 'rgba(245, 158, 11, 0.12)'
    border = 'rgba(245, 158, 11, 0.25)'
  } else if (normalized === 'deactivated') {
    dotColor = 'var(--slate-gray)'
    label = 'Deactivated'
    bg = 'rgba(71, 85, 105, 0.15)'
    border = 'rgba(71, 85, 105, 0.3)'
  }

  return (
    <span
      className="tag"
      data-testid={`status-badge-${normalized}`}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 6,
        background: bg,
        borderColor: border,
        color: dotColor,
        fontSize: 11,
        fontWeight: 600,
      }}
    >
      <span
        aria-hidden="true"
        data-testid={`status-dot-${normalized}`}
        style={{
          width: 7,
          height: 7,
          borderRadius: '50%',
          backgroundColor: dotColor,
          boxShadow: `0 0 6px ${dotColor}`,
          flexShrink: 0,
        }}
      />
      {label}
    </span>
  )
}

function formatDate(dateStr?: string | null): string {
  if (!dateStr) return '—'
  try {
    const d = new Date(dateStr)
    if (isNaN(d.getTime())) return dateStr
    return d.toISOString().split('T')[0]
  } catch {
    return dateStr
  }
}

function getInitials(name?: string, email?: string): string {
  const source = name?.trim() || email?.trim() || '?'
  const parts = source.split(/\s+|@|\./).filter(Boolean)
  if (parts.length >= 2) {
    return (parts[0][0] + parts[1][0]).toUpperCase()
  }
  return source.slice(0, 2).toUpperCase()
}

// ==============================================================================
// Main UserTable Component
// ==============================================================================

export default function UserTable({
  users,
  isLoading = false,
  onEditUser,
  onDeactivateUser,
  onStatusChange,
  currentUserEmail,
  isSuperadmin: _isSuperadmin = false,
  pageSize = 10,
  testId = 'user-table',
}: UserTableProps) {
  const [sortField, setSortField] = useState<SortField>('created')
  const [sortOrder, setSortOrder] = useState<SortOrder>('desc')
  const [currentPage, setCurrentPage] = useState(1)
  const [rowsPerPage, setRowsPerPage] = useState(pageSize)

  // Suspension confirmation dialog state
  const [pendingSuspensionUser, setPendingSuspensionUser] = useState<PlatformUser | null>(null)
  const [isMutatingStatus, setIsMutatingStatus] = useState(false)

  // Sorting handler
  const handleSort = (field: SortField) => {
    if (sortField === field) {
      setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc')
    } else {
      setSortField(field)
      setSortOrder('asc')
    }
  }

  // Sorted data
  const sortedUsers = useMemo(() => {
    const list = [...users]
    list.sort((a, b) => {
      let comparison = 0
      switch (sortField) {
        case 'name':
          comparison = (a.display_name || '').localeCompare(b.display_name || '')
          break
        case 'email':
          comparison = (a.email || '').localeCompare(b.email || '')
          break
        case 'tenant':
          comparison = (a.tenant_id || '').localeCompare(b.tenant_id || '')
          break
        case 'role':
          comparison = (a.role || '').localeCompare(b.role || '')
          break
        case 'status':
          comparison = (a.status || '').localeCompare(b.status || '')
          break
        case 'created':
        default:
          comparison = new Date(a.created_at || 0).getTime() - new Date(b.created_at || 0).getTime()
          break
      }
      return sortOrder === 'asc' ? comparison : -comparison
    })
    return list
  }, [users, sortField, sortOrder])

  // Pagination slicing
  const totalUsers = sortedUsers.length
  const totalPages = Math.max(1, Math.ceil(totalUsers / rowsPerPage))
  const safeCurrentPage = Math.min(currentPage, totalPages)
  const startIndex = (safeCurrentPage - 1) * rowsPerPage
  const paginatedUsers = sortedUsers.slice(startIndex, startIndex + rowsPerPage)

  // Status toggle handler
  const handleToggleClick = (user: PlatformUser) => {
    if (user.status === 'active') {
      // Suspending requires explicit safety confirmation prompt
      setPendingSuspensionUser(user)
    } else {
      // Activating from suspended or invited
      void executeStatusChange(user, 'active')
    }
  }

  const executeStatusChange = async (user: PlatformUser, newStatus: UserStatus) => {
    if (!onStatusChange) return
    setIsMutatingStatus(true)
    try {
      await onStatusChange(user, newStatus)
    } finally {
      setIsMutatingStatus(false)
      setPendingSuspensionUser(null)
    }
  }

  const handleConfirmSuspension = async () => {
    if (pendingSuspensionUser) {
      await executeStatusChange(pendingSuspensionUser, 'suspended')
    }
  }

  const handleCancelSuspension = () => {
    setPendingSuspensionUser(null)
  }

  return (
    <div data-testid={testId} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* Table Container */}
      <div
        className="card"
        style={{
          padding: 0,
          overflow: 'hidden',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius)',
          background: 'var(--surface)',
        }}
      >
        <div style={{ overflowX: 'auto', width: '100%' }}>
          <table
            role="table"
            style={{
              width: '100%',
              borderCollapse: 'collapse',
              textAlign: 'left',
              fontSize: 13,
            }}
          >
            <caption className="sr-only">Directory Platform Users</caption>
            <thead>
              <tr
                style={{
                  borderBottom: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--muted)',
                  fontSize: 11,
                  fontWeight: 700,
                  textTransform: 'uppercase',
                  letterSpacing: '0.06em',
                }}
              >
                <th
                  scope="col"
                  onClick={() => handleSort('name')}
                  aria-sort={sortField === 'name' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 180,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>User</span>
                    {sortField === 'name' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  onClick={() => handleSort('email')}
                  aria-sort={sortField === 'email' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 200,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>Email</span>
                    {sortField === 'email' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  onClick={() => handleSort('tenant')}
                  aria-sort={sortField === 'tenant' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 120,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>Tenant</span>
                    {sortField === 'tenant' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  onClick={() => handleSort('role')}
                  aria-sort={sortField === 'role' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 140,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>Role</span>
                    {sortField === 'role' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  onClick={() => handleSort('status')}
                  aria-sort={sortField === 'status' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 120,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>Status</span>
                    {sortField === 'status' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  onClick={() => handleSort('created')}
                  aria-sort={sortField === 'created' ? (sortOrder === 'asc' ? 'ascending' : 'descending') : 'none'}
                  style={{
                    padding: '12px 16px',
                    cursor: 'pointer',
                    userSelect: 'none',
                    minWidth: 120,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span>Created</span>
                    {sortField === 'created' && (
                      <span aria-hidden="true">{sortOrder === 'asc' ? '▲' : '▼'}</span>
                    )}
                  </div>
                </th>
                <th
                  scope="col"
                  style={{
                    padding: '12px 16px',
                    textAlign: 'right',
                    minWidth: 160,
                  }}
                >
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              {isLoading ? (
                // Loading Skeletons
                Array.from({ length: 5 }).map((_, idx) => (
                  <tr
                    key={`skeleton-${idx}`}
                    data-testid="user-table-skeleton-row"
                    style={{
                      borderBottom: '1px solid var(--border)',
                      height: 54,
                    }}
                  >
                    <td colSpan={7} style={{ padding: '16px' }}>
                      <div
                        style={{
                          height: 16,
                          background: 'linear-gradient(90deg, var(--surface2) 25%, var(--border-subtle) 50%, var(--surface2) 75%)',
                          backgroundSize: '200% 100%',
                          borderRadius: 4,
                          animation: 'fadeIn 1s infinite alternate',
                        }}
                      />
                    </td>
                  </tr>
                ))
              ) : paginatedUsers.length === 0 ? (
                <tr>
                  <td colSpan={7} style={{ padding: '32px 16px', textAlign: 'center' }}>
                    <EmptyState kicker="No users found" body="No platform users match the current filter criteria." />
                  </td>
                </tr>
              ) : (
                paginatedUsers.map((user) => {
                  const isSelf = currentUserEmail && user.email?.toLowerCase() === currentUserEmail.toLowerCase()
                  const isActive = user.status === 'active'
                  const isSuspended = user.status === 'suspended'

                  return (
                    <tr
                      key={user.id}
                      data-testid={`user-row-${user.id}`}
                      style={{
                        borderBottom: '1px solid var(--border)',
                        transition: 'background 0.15s ease',
                      }}
                    >
                      {/* Name + Avatar */}
                      <td style={{ padding: '12px 16px' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                          <div
                            aria-hidden="true"
                            style={{
                              width: 32,
                              height: 32,
                              borderRadius: '50%',
                              background: 'var(--surface2)',
                              border: '1px solid var(--border-subtle)',
                              color: 'var(--cyan)',
                              display: 'flex',
                              alignItems: 'center',
                              justifyContent: 'center',
                              fontSize: 11,
                              fontWeight: 700,
                              flexShrink: 0,
                            }}
                          >
                            {getInitials(user.display_name, user.email)}
                          </div>
                          <div style={{ display: 'flex', flexDirection: 'column' }}>
                            <span style={{ fontWeight: 600, color: 'var(--text)' }}>
                              {user.display_name || user.email.split('@')[0]}
                            </span>
                            {user.title && (
                              <span style={{ fontSize: 11, color: 'var(--muted)' }}>
                                {user.title}
                              </span>
                            )}
                          </div>
                        </div>
                      </td>

                      {/* Email */}
                      <td style={{ padding: '12px 16px' }}>
                        <span className="mono" style={{ fontSize: 12.5, color: 'var(--muted)' }}>
                          {user.email}
                        </span>
                      </td>

                      {/* Tenant */}
                      <td style={{ padding: '12px 16px' }}>
                        <span
                          className="tag mono"
                          style={{
                            background: 'var(--surface2)',
                            borderColor: 'var(--border-subtle)',
                            color: 'var(--text)',
                            fontSize: 11,
                          }}
                        >
                          {user.tenant_id}
                        </span>
                      </td>

                      {/* Role */}
                      <td style={{ padding: '12px 16px' }}>
                        <RoleBadge role={user.role} isSuperadmin={user.is_superadmin} />
                      </td>

                      {/* Status */}
                      <td style={{ padding: '12px 16px' }}>
                        <StatusIndicator status={user.status} />
                      </td>

                      {/* Created */}
                      <td style={{ padding: '12px 16px' }}>
                        <span style={{ fontSize: 12, color: 'var(--muted)' }}>
                          {formatDate(user.created_at)}
                        </span>
                      </td>

                      {/* Actions */}
                      <td style={{ padding: '12px 16px', textAlign: 'right' }}>
                        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, justifyContent: 'flex-end' }}>
                          {/* Status Toggle Button */}
                          <button
                            type="button"
                            className={`btn ${isActive ? 'btn-secondary' : 'btn-primary'}`}
                            onClick={() => handleToggleClick(user)}
                            disabled={isMutatingStatus || Boolean(isSelf)}
                            aria-label={`${isActive ? 'Suspend' : 'Activate'} user ${user.display_name || user.email}`}
                            data-testid={`toggle-status-btn-${user.id}`}
                            style={{
                              fontSize: 12,
                              padding: '4px 10px',
                              height: 28,
                            }}
                            title={
                              isSelf
                                ? 'You cannot suspend your own active account'
                                : isActive
                                  ? 'Suspend this user account'
                                  : 'Activate this user account'
                            }
                          >
                            {isActive ? 'Suspend' : isSuspended ? 'Activate' : 'Enable'}
                          </button>

                          {/* Edit Action Button */}
                          {onEditUser && (
                            <button
                              type="button"
                              className="btn btn-secondary"
                              onClick={() => onEditUser(user)}
                              aria-label={`Edit user ${user.display_name || user.email}`}
                              data-testid={`edit-user-btn-${user.id}`}
                              style={{
                                fontSize: 12,
                                padding: '4px 10px',
                                height: 28,
                              }}
                            >
                              Edit
                            </button>
                          )}

                          {/* Deactivate / Delete Action Button */}
                          {onDeactivateUser && (
                            <button
                              type="button"
                              className="btn btn-secondary"
                              onClick={() => onDeactivateUser(user)}
                              disabled={Boolean(isSelf)}
                              aria-label={`Deactivate user ${user.display_name || user.email}`}
                              data-testid={`deactivate-user-btn-${user.id}`}
                              style={{
                                fontSize: 12,
                                padding: '4px 10px',
                                height: 28,
                                color: 'var(--error)',
                              }}
                            >
                              Delete
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination Footer */}
        {!isLoading && totalUsers > 0 && (
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '12px 16px',
              borderTop: '1px solid var(--border)',
              background: 'var(--surface2)',
              fontSize: 12,
              color: 'var(--muted)',
              flexWrap: 'wrap',
              gap: 12,
            }}
          >
            {/* Rows Per Page Selector & Summary */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <span>
                Showing <strong style={{ color: 'var(--text)' }}>{Math.min(totalUsers, startIndex + 1)}</strong> to{' '}
                <strong style={{ color: 'var(--text)' }}>{Math.min(totalUsers, startIndex + rowsPerPage)}</strong> of{' '}
                <strong style={{ color: 'var(--text)' }}>{totalUsers}</strong> users
              </span>
              <label style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                <span>Rows:</span>
                <select
                  value={rowsPerPage}
                  onChange={(e) => {
                    setRowsPerPage(Number(e.target.value))
                    setCurrentPage(1)
                  }}
                  data-testid="page-size-select"
                  aria-label="Rows per page"
                  style={{
                    padding: '2px 6px',
                    fontSize: 12,
                    height: 26,
                  }}
                >
                  <option value={10}>10</option>
                  <option value={25}>25</option>
                  <option value={50}>50</option>
                </select>
              </label>
            </div>

            {/* Pagination Controls */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span data-testid="pagination-page-indicator">
                Page {safeCurrentPage} of {totalPages}
              </span>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setCurrentPage((p) => Math.max(1, p - 1))}
                disabled={safeCurrentPage <= 1}
                aria-label="Previous page"
                data-testid="pagination-prev-btn"
                style={{ padding: '3px 8px', height: 26, fontSize: 12 }}
              >
                Previous
              </button>
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setCurrentPage((p) => Math.min(totalPages, p + 1))}
                disabled={safeCurrentPage >= totalPages}
                aria-label="Next page"
                data-testid="pagination-next-btn"
                style={{ padding: '3px 8px', height: 26, fontSize: 12 }}
              >
                Next
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Suspension Confirmation Dialog */}
      {pendingSuspensionUser && (
        <ConfirmDialog
          title="Confirm User Suspension"
          body={`Are you sure you want to suspend "${pendingSuspensionUser.display_name || pendingSuspensionUser.email}" (${pendingSuspensionUser.email})? They will immediately lose access to all tenant resources and API capabilities.`}
          confirmLabel="Suspend User"
          loading={isMutatingStatus}
          onConfirm={handleConfirmSuspension}
          onCancel={handleCancelSuspension}
        />
      )}
    </div>
  )
}
