import React, { useState, useId, useMemo, useRef, useEffect } from 'react'
import {
  useUpdateUser,
  type PlatformUser,
  type UserRole,
  type UserStatus,
  type UpdateUserRequest,
  type UsersApiError,
} from '../../api/usersApi'
import { useFocusTrap } from './useFocusTrap'

export interface EditUserModalProps {
  user: PlatformUser | null
  isOpen?: boolean
  onClose: () => void
  onSuccess?: (user: PlatformUser) => void
  token?: string | null
  isSuperadmin?: boolean
  availableTenants?: string[]
  returnFocusRef?: React.RefObject<HTMLElement | null> | null
  testId?: string
}

export default function EditUserModal({
  user,
  isOpen = true,
  onClose,
  onSuccess,
  token,
  isSuperadmin = false,
  availableTenants = [],
  returnFocusRef,
  testId = 'edit-user-modal',
}: EditUserModalProps) {
  const titleId = useId()
  const descriptionId = useId()
  const nameInputId = useId()
  const roleSelectId = useId()
  const statusSelectId = useId()
  const tenantInputId = useId()
  const superadminCheckId = useId()
  const confirmCheckId = useId()
  const titleFieldId = useId()
  const deptFieldId = useId()

  const initialFocusRef = useRef<HTMLInputElement | null>(null)

  // Form State
  const [displayName, setDisplayName] = useState(user?.display_name || '')
  const [role, setRole] = useState<UserRole>(user?.role || 'viewer')
  const [status, setStatus] = useState<UserStatus>(user?.status || 'active')
  const [tenantId, setTenantId] = useState(user?.tenant_id || '')
  const [isSuperadminFlag, setIsSuperadminFlag] = useState(Boolean(user?.is_superadmin))
  const [title, setTitle] = useState(user?.title || '')
  const [department, setDepartment] = useState(user?.department || '')

  // Reset form whenever user prop changes
  useEffect(() => {
    if (user) {
      setDisplayName(user.display_name || '')
      setRole(user.role || 'viewer')
      setStatus(user.status || 'active')
      setTenantId(user.tenant_id || '')
      setIsSuperadminFlag(Boolean(user.is_superadmin))
      setTitle(user.title || '')
      setDepartment(user.department || '')
      setConfirmedSensitiveChange(false)
      setServerError(null)
    }
  }, [user])

  // Sensitive change confirmation state
  const [confirmedSensitiveChange, setConfirmedSensitiveChange] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Check whether impactful changes were made (role, status, superadmin status)
  const isRoleChanged = Boolean(user && role !== user.role)
  const isStatusChanged = Boolean(user && status !== user.status)
  const isSuperadminChanged = Boolean(user && isSuperadminFlag !== Boolean(user.is_superadmin))
  const hasImpactfulChange = isRoleChanged || isStatusChanged || isSuperadminChanged

  const isDirty = useMemo(() => {
    if (!user) return false
    return (
      displayName !== (user.display_name || '') ||
      role !== user.role ||
      status !== user.status ||
      tenantId !== user.tenant_id ||
      isSuperadminFlag !== Boolean(user.is_superadmin) ||
      title !== (user.title || '') ||
      department !== (user.department || '')
    )
  }, [user, displayName, role, status, tenantId, isSuperadminFlag, title, department])

  // Submit button enabled condition
  const canSubmit = isDirty && (!hasImpactfulChange || confirmedSensitiveChange) && !isSubmitting

  // Safe close with dirty confirmation
  const handleSafeClose = () => {
    if (isDirty) {
      const confirmDiscard = window.confirm('You have unsaved changes. Are you sure you want to discard your edits?')
      if (!confirmDiscard) return
    }
    onClose()
  }

  // Accessibility focus trap
  const { containerRef, handleKeyDown } = useFocusTrap<HTMLDivElement>({
    isOpen: Boolean(isOpen && user),
    onClose: handleSafeClose,
    initialFocusRef,
    returnFocusRef,
    closeOnEscape: true,
  })

  // Mutation hook
  const updateMutation = useUpdateUser({
    token,
    onSuccess: (updatedUser) => {
      setIsSubmitting(false)
      onSuccess?.(updatedUser)
      onClose()
    },
    onError: (err: UsersApiError) => {
      setIsSubmitting(false)
      setServerError(err.message || 'Failed to update user profile')
    },
  })

  // Submit Handler
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!user || !canSubmit) return

    setIsSubmitting(true)
    setServerError(null)

    const payload: UpdateUserRequest = {
      display_name: displayName.trim() || null,
      role,
      status,
      tenant_id: isSuperadmin ? (tenantId.trim() || user.tenant_id) : undefined,
      is_superadmin: isSuperadmin ? isSuperadminFlag : undefined,
      title: title.trim() || null,
      department: department.trim() || null,
    }

    try {
      await updateMutation.mutateAsync({
        userId: user.id,
        payload,
        token,
      })
    } catch {
      // Handled in onError callback
    }
  }

  if (!isOpen || !user) return null

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
      aria-describedby={descriptionId}
      data-testid={testId}
      onKeyDown={handleKeyDown}
      onClick={(e) => {
        if (e.target === e.currentTarget) {
          handleSafeClose()
        }
      }}
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0, 0, 0, 0.65)',
        backdropFilter: 'blur(8px)',
        zIndex: 2000,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 16,
      }}
    >
      <div
        ref={containerRef}
        tabIndex={-1}
        className="card slide-up"
        style={{
          width: '100%',
          maxWidth: 540,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius)',
          padding: 24,
          boxShadow: '0 20px 40px rgba(0, 0, 0, 0.5)',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
          outline: 'none',
        }}
      >
        {/* Modal Header */}
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <h2 id={titleId} style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
                Edit Operator Profile
              </h2>
              {user.is_superadmin && (
                <span
                  className="tag"
                  style={{
                    background: 'rgba(139, 92, 246, 0.15)',
                    borderColor: 'rgba(139, 92, 246, 0.35)',
                    color: 'var(--violet)',
                    fontSize: 10,
                    fontWeight: 700,
                  }}
                >
                  Superadmin
                </span>
              )}
            </div>
            <p id={descriptionId} style={{ fontSize: 12.5, color: 'var(--muted)', marginTop: 4, margin: 0 }}>
              Update permissions, account status, and tenant scoping for <strong style={{ color: 'var(--text)' }}>{user.email}</strong>.
            </p>
          </div>
          <button
            type="button"
            data-testid="edit-close-btn"
            onClick={handleSafeClose}
            aria-label="Close edit modal"
            style={{
              background: 'transparent',
              border: 'none',
              color: 'var(--muted)',
              cursor: 'pointer',
              fontSize: 16,
              padding: 4,
              lineHeight: 1,
            }}
          >
            ✕
          </button>
        </div>

        {/* Server Error Alert Banner */}
        {serverError && (
          <div
            role="alert"
            data-testid="edit-error-banner"
            style={{
              padding: '10px 14px',
              borderRadius: 'var(--radius)',
              background: 'rgba(220, 38, 38, 0.12)',
              border: '1px solid rgba(220, 38, 38, 0.3)',
              color: 'var(--error)',
              fontSize: 12.5,
              fontWeight: 500,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
            }}
          >
            <span>{serverError}</span>
            <button
              type="button"
              onClick={() => setServerError(null)}
              aria-label="Dismiss error"
              style={{
                background: 'none',
                border: 'none',
                color: 'var(--error)',
                cursor: 'pointer',
                fontSize: 13,
                padding: 2,
              }}
            >
              ✕
            </button>
          </div>
        )}

        {/* Edit Form */}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          {/* Read-Only Email & ID Display */}
          <div
            style={{
              padding: '10px 14px',
              borderRadius: 'var(--radius)',
              background: 'var(--surface2)',
              border: '1px solid var(--border-subtle)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              fontSize: 12,
            }}
          >
            <div>
              <span style={{ color: 'var(--muted)', display: 'block', fontSize: 11, fontWeight: 600 }}>
                Operator Email
              </span>
              <span data-testid="edit-email-display" className="mono" style={{ color: 'var(--text)', fontWeight: 600 }}>
                {user.email}
              </span>
            </div>
            <div style={{ textAlign: 'right' }}>
              <span style={{ color: 'var(--muted)', display: 'block', fontSize: 11, fontWeight: 600 }}>
                User ID
              </span>
              <span className="mono" style={{ color: 'var(--dim)', fontSize: 11 }}>
                {user.id}
              </span>
            </div>
          </div>

          {/* Display Name */}
          <div>
            <label
              htmlFor={nameInputId}
              style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
            >
              Full Name / Display Name
            </label>
            <input
              ref={initialFocusRef}
              id={nameInputId}
              type="text"
              data-testid="edit-display-name-input"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="e.g. Jane Doe"
              style={{
                width: '100%',
                padding: '8px 12px',
                borderRadius: 'var(--radius)',
                border: '1px solid var(--border)',
                background: 'var(--surface2)',
                color: 'var(--text)',
                fontSize: 13,
                boxSizing: 'border-box',
              }}
            />
          </div>

          {/* Role & Status in 2-column grid */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            {/* Role Dropdown */}
            <div>
              <label
                htmlFor={roleSelectId}
                style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
              >
                Platform Role <span style={{ color: 'var(--error)' }}>*</span>
              </label>
              <select
                id={roleSelectId}
                data-testid="edit-role-select"
                value={role}
                onChange={(e) => setRole(e.target.value as UserRole)}
                aria-label="Select user platform role"
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 'var(--radius)',
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              >
                <option value="viewer">Viewer</option>
                <option value="editor">Editor</option>
                <option value="admin">Admin</option>
              </select>
            </div>

            {/* Status Dropdown */}
            <div>
              <label
                htmlFor={statusSelectId}
                style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
              >
                Account Status <span style={{ color: 'var(--error)' }}>*</span>
              </label>
              <select
                id={statusSelectId}
                data-testid="edit-status-select"
                value={status}
                onChange={(e) => setStatus(e.target.value as UserStatus)}
                aria-label="Select user account status"
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 'var(--radius)',
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              >
                <option value="active">Active</option>
                <option value="suspended">Suspended</option>
                <option value="invited">Invited</option>
                <option value="deactivated">Deactivated</option>
              </select>
            </div>
          </div>

          {/* Superadmin Tenant Selector & Superadmin Privileges (Strictly Superadmins) */}
          {isSuperadmin && (
            <div
              data-testid="edit-superadmin-section"
              style={{
                padding: '12px 14px',
                borderRadius: 'var(--radius)',
                background: 'rgba(139, 92, 246, 0.08)',
                border: '1px solid rgba(139, 92, 246, 0.25)',
                display: 'flex',
                flexDirection: 'column',
                gap: 10,
              }}
            >
              <div>
                <label
                  htmlFor={tenantInputId}
                  style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--violet)', marginBottom: 4 }}
                >
                  Tenant Scoping (Superadmin)
                </label>
                {availableTenants.length > 0 ? (
                  <select
                    id={tenantInputId}
                    data-testid="edit-tenant-select"
                    value={tenantId}
                    onChange={(e) => setTenantId(e.target.value)}
                    aria-label="Select tenant assignment"
                    style={{
                      width: '100%',
                      padding: '8px 12px',
                      borderRadius: 'var(--radius)',
                      border: '1px solid var(--border)',
                      background: 'var(--surface2)',
                      color: 'var(--text)',
                      fontSize: 13,
                      boxSizing: 'border-box',
                    }}
                  >
                    {availableTenants.map((t) => (
                      <option key={t} value={t}>
                        {t}
                      </option>
                    ))}
                  </select>
                ) : (
                  <input
                    id={tenantInputId}
                    type="text"
                    data-testid="edit-tenant-input"
                    value={tenantId}
                    onChange={(e) => setTenantId(e.target.value)}
                    placeholder="tenant-acme"
                    aria-label="Tenant ID"
                    style={{
                      width: '100%',
                      padding: '8px 12px',
                      borderRadius: 'var(--radius)',
                      border: '1px solid var(--border)',
                      background: 'var(--surface2)',
                      color: 'var(--text)',
                      fontSize: 13,
                      boxSizing: 'border-box',
                    }}
                  />
                )}
              </div>

              {/* Superadmin Checkbox */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 4 }}>
                <input
                  id={superadminCheckId}
                  type="checkbox"
                  data-testid="edit-superadmin-checkbox"
                  checked={isSuperadminFlag}
                  onChange={(e) => setIsSuperadminFlag(e.target.checked)}
                  style={{ width: 16, height: 16, cursor: 'pointer' }}
                />
                <label
                  htmlFor={superadminCheckId}
                  style={{ fontSize: 12, color: 'var(--text)', cursor: 'pointer', fontWeight: 500 }}
                >
                  Grant Global Superadmin Authority across all tenants
                </label>
              </div>
            </div>
          )}

          {/* Secondary fields (Title & Department) in 2-column layout */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div>
              <label
                htmlFor={titleFieldId}
                style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
              >
                Job Title
              </label>
              <input
                id={titleFieldId}
                type="text"
                data-testid="edit-title-input"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="e.g. Lead SRE"
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 'var(--radius)',
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              />
            </div>
            <div>
              <label
                htmlFor={deptFieldId}
                style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
              >
                Department
              </label>
              <input
                id={deptFieldId}
                type="text"
                data-testid="edit-department-input"
                value={department}
                onChange={(e) => setDepartment(e.target.value)}
                placeholder="e.g. Security Ops"
                style={{
                  width: '100%',
                  padding: '8px 12px',
                  borderRadius: 'var(--radius)',
                  border: '1px solid var(--border)',
                  background: 'var(--surface2)',
                  color: 'var(--text)',
                  fontSize: 13,
                  boxSizing: 'border-box',
                }}
              />
            </div>
          </div>

          {/* Sensitive / Impactful Change Confirmation Callout */}
          {hasImpactfulChange && (
            <div
              data-testid="edit-confirmation-callout"
              style={{
                padding: '12px 14px',
                borderRadius: 'var(--radius)',
                background: 'rgba(217, 119, 6, 0.12)',
                border: '1px solid rgba(217, 119, 6, 0.35)',
                color: 'var(--amber)',
                fontSize: 12,
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
              }}
            >
              <div style={{ fontWeight: 600 }}>
                ⚠️ Privilege or Status Modification Notice
              </div>
              <p style={{ margin: 0, color: 'var(--text)', fontSize: 12, lineHeight: 1.4 }}>
                {isRoleChanged && (
                  <span>Role changing from <strong>{user.role}</strong> to <strong>{role}</strong>. </span>
                )}
                {isStatusChanged && (
                  <span>Status changing from <strong>{user.status}</strong> to <strong>{status}</strong>. </span>
                )}
                {isSuperadminChanged && (
                  <span>Superadmin privilege is being <strong>{isSuperadminFlag ? 'granted' : 'revoked'}</strong>. </span>
                )}
              </p>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 4 }}>
                <input
                  id={confirmCheckId}
                  type="checkbox"
                  data-testid="edit-confirm-checkbox"
                  checked={confirmedSensitiveChange}
                  onChange={(e) => setConfirmedSensitiveChange(e.target.checked)}
                  style={{ width: 16, height: 16, cursor: 'pointer' }}
                />
                <label
                  htmlFor={confirmCheckId}
                  style={{ color: 'var(--text)', cursor: 'pointer', fontWeight: 600, fontSize: 11.5 }}
                >
                  I confirm these privilege and account status changes
                </label>
              </div>
            </div>
          )}

          {/* Form Action Buttons */}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, marginTop: 8 }}>
            <button
              type="button"
              data-testid="edit-cancel-btn"
              onClick={handleSafeClose}
              disabled={isSubmitting}
              className="btn btn-secondary"
              style={{
                padding: '8px 16px',
                fontSize: 13,
                cursor: isSubmitting ? 'not-allowed' : 'pointer',
              }}
            >
              Cancel
            </button>
            <button
              type="submit"
              data-testid="edit-submit-btn"
              disabled={!canSubmit}
              className="btn btn-primary"
              style={{
                padding: '8px 18px',
                fontSize: 13,
                fontWeight: 600,
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                cursor: !canSubmit ? 'not-allowed' : 'pointer',
                opacity: !canSubmit ? 0.6 : 1,
              }}
            >
              {isSubmitting && (
                <span
                  data-testid="edit-submit-spinner"
                  aria-hidden="true"
                  style={{ display: 'inline-block', animation: 'spin 1s linear infinite' }}
                >
                  ⏳
                </span>
              )}
              {isSubmitting ? 'Saving Changes…' : 'Save Changes'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
