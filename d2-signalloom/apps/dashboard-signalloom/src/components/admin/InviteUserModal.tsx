import React, { useState, useId, useMemo, useRef } from 'react'
import {
  useInviteUser,
  type PlatformUser,
  type UserRole,
  type InviteUserRequest,
  type UsersApiError,
} from '../../api/usersApi'
import { useFocusTrap } from './useFocusTrap'

export interface InviteUserModalProps {
  isOpen?: boolean
  onClose: () => void
  onSuccess?: (user: PlatformUser) => void
  token?: string | null
  isSuperadmin?: boolean
  currentTenantId?: string
  availableTenants?: string[]
  returnFocusRef?: React.RefObject<HTMLElement | null> | null
  testId?: string
}

const RFC5322_EMAIL_REGEX =
  /^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/

export function isValidEmail(email: string): boolean {
  if (!email || typeof email !== 'string') return false
  const trimmed = email.trim()
  if (trimmed.length < 5 || trimmed.length > 254) return false
  return RFC5322_EMAIL_REGEX.test(trimmed)
}

export default function InviteUserModal({
  isOpen = true,
  onClose,
  onSuccess,
  token,
  isSuperadmin = false,
  currentTenantId,
  availableTenants = [],
  returnFocusRef,
  testId = 'invite-user-modal',
}: InviteUserModalProps) {
  const titleId = useId()
  const descriptionId = useId()
  const emailInputId = useId()
  const emailErrorId = useId()
  const nameInputId = useId()
  const roleSelectId = useId()
  const tenantInputId = useId()
  const titleFieldId = useId()
  const deptFieldId = useId()

  const emailInputRef = useRef<HTMLInputElement | null>(null)

  // Form State
  const [email, setEmail] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [role, setRole] = useState<UserRole>('viewer')
  const [tenantId, setTenantId] = useState(currentTenantId || (availableTenants[0] ?? ''))
  const [title, setTitle] = useState('')
  const [department, setDepartment] = useState('')

  // Validation & Error state
  const [touchedEmail, setTouchedEmail] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [isSubmitting, setIsSubmitting] = useState(false)

  const isEmailFormatValid = useMemo(() => isValidEmail(email), [email])
  const showEmailError = touchedEmail && email.trim().length > 0 && !isEmailFormatValid
  const showEmailRequiredError = touchedEmail && email.trim().length === 0

  const isFormValid = isEmailFormatValid && email.trim().length > 0
  const isDirty = Boolean(email.trim() || displayName.trim() || title.trim() || department.trim())

  // Safe Close with dirty confirmation
  const handleSafeClose = () => {
    if (isDirty) {
      const confirmDiscard = window.confirm('You have unsaved changes. Are you sure you want to discard this invitation?')
      if (!confirmDiscard) return
    }
    onClose()
  }

  // Accessibility focus trap
  const { containerRef, handleKeyDown } = useFocusTrap<HTMLDivElement>({
    isOpen,
    onClose: handleSafeClose,
    initialFocusRef: emailInputRef,
    returnFocusRef,
    closeOnEscape: true,
  })

  // Mutation hook
  const inviteMutation = useInviteUser({
    token,
    onSuccess: (newUser) => {
      setIsSubmitting(false)
      onSuccess?.(newUser)
      onClose()
    },
    onError: (err: UsersApiError) => {
      setIsSubmitting(false)
      setServerError(err.message || 'Failed to dispatch user invitation')
    },
  })

  // Submit Handler
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setTouchedEmail(true)

    if (!isFormValid || isSubmitting) return

    setIsSubmitting(true)
    setServerError(null)

    const payload: InviteUserRequest = {
      email: email.trim().toLowerCase(),
      display_name: displayName.trim() || undefined,
      role,
      tenant_id: isSuperadmin ? (tenantId.trim() || null) : (currentTenantId || null),
      title: title.trim() || undefined,
      department: department.trim() || undefined,
    }

    try {
      await inviteMutation.mutateAsync({ payload, token })
    } catch {
      // Handled in onError callback
    }
  }

  if (!isOpen) return null

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
            <h2 id={titleId} style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
              Invite Platform Operator
            </h2>
            <p id={descriptionId} style={{ fontSize: 12.5, color: 'var(--muted)', marginTop: 4, margin: 0 }}>
              Provision operator access and dispatch an OIDC credential onboarding invite.
            </p>
          </div>
          <button
            type="button"
            data-testid="invite-close-btn"
            onClick={handleSafeClose}
            aria-label="Close invite modal"
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
            data-testid="invite-error-banner"
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

        {/* Invitation Form */}
        <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          {/* Email Address */}
          <div>
            <label
              htmlFor={emailInputId}
              style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
            >
              Email Address <span style={{ color: 'var(--error)' }}>*</span>
            </label>
            <input
              ref={emailInputRef}
              id={emailInputId}
              type="email"
              data-testid="invite-email-input"
              value={email}
              onChange={(e) => {
                setEmail(e.target.value)
                if (serverError) setServerError(null)
              }}
              onBlur={() => setTouchedEmail(true)}
              placeholder="operator@organization.com"
              required
              aria-required="true"
              aria-invalid={showEmailError || showEmailRequiredError ? 'true' : 'false'}
              aria-describedby={showEmailError || showEmailRequiredError ? emailErrorId : undefined}
              style={{
                width: '100%',
                padding: '8px 12px',
                borderRadius: 'var(--radius)',
                border: `1px solid ${showEmailError || showEmailRequiredError ? 'var(--error)' : 'var(--border)'}`,
                background: 'var(--surface2)',
                color: 'var(--text)',
                fontSize: 13,
                boxSizing: 'border-box',
                outline: 'none',
              }}
            />
            {showEmailError && (
              <div
                id={emailErrorId}
                role="alert"
                data-testid="invite-email-error"
                style={{ color: 'var(--error)', fontSize: 11.5, marginTop: 4, fontWeight: 500 }}
              >
                Please enter a valid RFC 5322 email address (e.g. name@domain.com).
              </div>
            )}
            {showEmailRequiredError && (
              <div
                id={emailErrorId}
                role="alert"
                data-testid="invite-email-required-error"
                style={{ color: 'var(--error)', fontSize: 11.5, marginTop: 4, fontWeight: 500 }}
              >
                Email address is required.
              </div>
            )}
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
              id={nameInputId}
              type="text"
              data-testid="invite-name-input"
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

          {/* Role Selection */}
          <div>
            <label
              htmlFor={roleSelectId}
              style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
            >
              Platform Role <span style={{ color: 'var(--error)' }}>*</span>
            </label>
            <select
              id={roleSelectId}
              data-testid="invite-role-select"
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
              <option value="viewer">Viewer (Read-only telemetry and audit access)</option>
              <option value="editor">Editor (Agent and policy management capabilities)</option>
              <option value="admin">Admin (Full user, key, and tenant administrative privilege)</option>
            </select>
          </div>

          {/* Tenant Selector -- STRICTLY Rendered ONLY for Superadmins */}
          {isSuperadmin && (
            <div data-testid="invite-tenant-wrapper">
              <label
                htmlFor={tenantInputId}
                style={{ display: 'block', fontSize: 12, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}
              >
                Tenant Assignment <span style={{ color: 'var(--violet)', fontSize: 11 }}>(Superadmin Scope)</span>
              </label>
              {availableTenants.length > 0 ? (
                <select
                  id={tenantInputId}
                  data-testid="invite-tenant-select"
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
                  data-testid="invite-tenant-input"
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
                data-testid="invite-title-input"
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
                data-testid="invite-department-input"
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

          {/* Form Action Buttons */}
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 10, marginTop: 8 }}>
            <button
              type="button"
              data-testid="invite-cancel-btn"
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
              data-testid="invite-submit-btn"
              disabled={!isFormValid || isSubmitting}
              className="btn btn-primary"
              style={{
                padding: '8px 18px',
                fontSize: 13,
                fontWeight: 600,
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                cursor: !isFormValid || isSubmitting ? 'not-allowed' : 'pointer',
                opacity: !isFormValid || isSubmitting ? 0.6 : 1,
              }}
            >
              {isSubmitting && (
                <span
                  data-testid="invite-submit-spinner"
                  aria-hidden="true"
                  style={{ display: 'inline-block', animation: 'spin 1s linear infinite' }}
                >
                  ⏳
                </span>
              )}
              {isSubmitting ? 'Sending Invitation…' : 'Send Invitation'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
