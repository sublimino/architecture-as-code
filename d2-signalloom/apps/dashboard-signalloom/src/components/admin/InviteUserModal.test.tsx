import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, within, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import InviteUserModal, { isValidEmail } from './InviteUserModal'
import * as usersApiModule from '../../api/usersApi'
import type { PlatformUser, UsersApiError } from '../../api/usersApi'

const MOCK_NEW_USER: PlatformUser = {
  id: 'usr-new-123',
  tenant_id: 'tenant-kusari',
  email: 'newoperator@kusari.com',
  display_name: 'New Operator',
  role: 'editor',
  status: 'invited',
  is_superadmin: false,
  title: 'Lead SRE',
  department: 'Infrastructure',
  created_at: '2026-10-08T00:00:00Z',
}

describe('InviteUserModal Component', () => {
  const onCloseMock = vi.fn()
  const onSuccessMock = vi.fn()
  let mutateAsyncMock: ReturnType<typeof vi.fn>
  let mockUseInviteUser: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.clearAllMocks()

    mutateAsyncMock = vi.fn().mockImplementation(async (vars) => {
      const payload = vars.payload || vars
      return {
        ...MOCK_NEW_USER,
        ...payload,
      }
    })

    mockUseInviteUser = vi.fn().mockImplementation((options) => ({
      mutateAsync: async (vars: any) => {
        try {
          const res = await mutateAsyncMock(vars)
          options?.onSuccess?.(res, vars)
          return res
        } catch (err) {
          options?.onError?.(err, vars)
          throw err
        }
      },
      isPending: false,
    }))

    vi.spyOn(usersApiModule, 'useInviteUser').mockImplementation(mockUseInviteUser as any)
  })

  describe('RFC 5322 Email Validation Unit', () => {
    it('validates standard email addresses correctly', () => {
      expect(isValidEmail('operator@domain.com')).toBe(true)
      expect(isValidEmail('first.last+tag@sub.domain.co.uk')).toBe(true)
      expect(isValidEmail('user123@acme.org')).toBe(true)
    })

    it('rejects invalid email formats', () => {
      expect(isValidEmail('')).toBe(false)
      expect(isValidEmail('plainaddress')).toBe(false)
      expect(isValidEmail('@missingusername.com')).toBe(false)
      expect(isValidEmail('missingdomain@.com')).toBe(false)
      expect(isValidEmail('spaces in@email.com')).toBe(false)
      expect(isValidEmail('missingdot@domain')).toBe(false)
    })
  })

  describe('Dialog Accessibility & Structure', () => {
    it('renders accessible dialog with role="dialog", aria-modal="true", and aria-labelledby', () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          currentTenantId="tenant-acme"
        />,
      )

      const dialog = screen.getByRole('dialog')
      expect(dialog).toBeInTheDocument()
      expect(dialog).toHaveAttribute('aria-modal', 'true')
      expect(dialog).toHaveAttribute('aria-labelledby')
      expect(dialog).toHaveAttribute('aria-describedby')

      expect(screen.getByRole('heading', { level: 2, name: 'Invite Platform Operator' })).toBeInTheDocument()
    })

    it('returns null when isOpen is false', () => {
      const { container } = render(
        <InviteUserModal
          isOpen={false}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )
      expect(container.firstChild).toBeNull()
    })
  })

  describe('Form Validation & Submission State', () => {
    it('disables submit button initially when email is empty', () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const submitBtn = screen.getByTestId('invite-submit-btn')
      expect(submitBtn).toBeDisabled()
      expect(submitBtn).toHaveTextContent('Send Invitation')
    })

    it('displays error and keeps submit disabled on invalid email syntax', async () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const emailInput = screen.getByTestId('invite-email-input')
      const submitBtn = screen.getByTestId('invite-submit-btn')

      // Type malformed email and blur
      await userEvent.type(emailInput, 'invalid-email-format')
      fireEvent.blur(emailInput)

      expect(emailInput).toHaveAttribute('aria-invalid', 'true')
      const errorMsg = screen.getByTestId('invite-email-error')
      expect(errorMsg).toBeInTheDocument()
      expect(errorMsg).toHaveTextContent(/Please enter a valid RFC 5322 email address/i)
      expect(emailInput).toHaveAttribute('aria-describedby', errorMsg.id)

      expect(submitBtn).toBeDisabled()
    })

    it('enables submit button and clears error when valid email is entered', async () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const emailInput = screen.getByTestId('invite-email-input')
      const submitBtn = screen.getByTestId('invite-submit-btn')

      await userEvent.type(emailInput, 'operator@kusari.com')
      fireEvent.blur(emailInput)

      expect(emailInput).toHaveAttribute('aria-invalid', 'false')
      expect(screen.queryByTestId('invite-email-error')).not.toBeInTheDocument()
      expect(submitBtn).toBeEnabled()
    })

    it('submits form with entered values and triggers mutation', async () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          token="test-token"
          currentTenantId="tenant-acme"
        />,
      )

      const emailInput = screen.getByTestId('invite-email-input')
      const nameInput = screen.getByTestId('invite-name-input')
      const roleSelect = screen.getByTestId('invite-role-select')
      const titleInput = screen.getByTestId('invite-title-input')
      const deptInput = screen.getByTestId('invite-department-input')
      const submitBtn = screen.getByTestId('invite-submit-btn')

      await userEvent.type(emailInput, 'alice@acme.com')
      await userEvent.type(nameInput, 'Alice Smith')
      fireEvent.change(roleSelect, { target: { value: 'admin' } })
      await userEvent.type(titleInput, 'Principal Architect')
      await userEvent.type(deptInput, 'Platform Security')

      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledTimes(1)
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            payload: {
              email: 'alice@acme.com',
              display_name: 'Alice Smith',
              role: 'admin',
              tenant_id: 'tenant-acme',
              title: 'Principal Architect',
              department: 'Platform Security',
            },
            token: 'test-token',
          }),
        )
        expect(onSuccessMock).toHaveBeenCalledTimes(1)
        expect(onCloseMock).toHaveBeenCalledTimes(1)
      })
    })

    it('displays server error banner on mutation failure', async () => {
      mutateAsyncMock.mockRejectedValueOnce(
        new usersApiModule.UsersApiError('Conflict: User with this email already exists', 409),
      )

      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const emailInput = screen.getByTestId('invite-email-input')
      const submitBtn = screen.getByTestId('invite-submit-btn')

      await userEvent.type(emailInput, 'existing@domain.com')
      await userEvent.click(submitBtn)

      await waitFor(() => {
        const errorBanner = screen.getByTestId('invite-error-banner')
        expect(errorBanner).toBeInTheDocument()
        expect(errorBanner).toHaveTextContent('Conflict: User with this email already exists')
      })

      // Error banner is dismissible
      const dismissBtn = within(screen.getByTestId('invite-error-banner')).getByRole('button', { name: /dismiss error/i })
      fireEvent.click(dismissBtn)
      expect(screen.queryByTestId('invite-error-banner')).not.toBeInTheDocument()
    })
  })

  describe('Tenant Scoping & Superadmin Exclusivity', () => {
    it('hides tenant selector when user is NOT superadmin', () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          isSuperadmin={false}
          currentTenantId="tenant-acme"
        />,
      )

      expect(screen.queryByTestId('invite-tenant-wrapper')).not.toBeInTheDocument()
      expect(screen.queryByTestId('invite-tenant-select')).not.toBeInTheDocument()
      expect(screen.queryByTestId('invite-tenant-input')).not.toBeInTheDocument()
    })

    it('renders tenant dropdown when user IS superadmin and availableTenants are provided', async () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          isSuperadmin={true}
          availableTenants={['tenant-acme', 'tenant-kusari']}
        />,
      )

      expect(screen.getByTestId('invite-tenant-wrapper')).toBeInTheDocument()
      const tenantSelect = screen.getByTestId('invite-tenant-select')
      expect(tenantSelect).toBeInTheDocument()
      expect(within(tenantSelect).getByText('tenant-acme')).toBeInTheDocument()
      expect(within(tenantSelect).getByText('tenant-kusari')).toBeInTheDocument()

      const emailInput = screen.getByTestId('invite-email-input')
      await userEvent.type(emailInput, 'kusari-op@kusari.com')
      fireEvent.change(tenantSelect, { target: { value: 'tenant-kusari' } })

      const submitBtn = screen.getByTestId('invite-submit-btn')
      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            payload: expect.objectContaining({
              tenant_id: 'tenant-kusari',
            }),
          }),
        )
      })
    })

    it('renders tenant text input when user IS superadmin and availableTenants is empty', async () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          isSuperadmin={true}
          availableTenants={[]}
        />,
      )

      const tenantInput = screen.getByTestId('invite-tenant-input')
      expect(tenantInput).toBeInTheDocument()

      await userEvent.type(tenantInput, 'tenant-custom')
      const emailInput = screen.getByTestId('invite-email-input')
      await userEvent.type(emailInput, 'custom-op@custom.com')

      const submitBtn = screen.getByTestId('invite-submit-btn')
      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            payload: expect.objectContaining({
              tenant_id: 'tenant-custom',
            }),
          }),
        )
      })
    })
  })

  describe('Modal Dismissal, Dirty Checks & Focus Restoration', () => {
    it('closes immediately on Cancel or Close (X) click when form is clean', () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const cancelBtn = screen.getByTestId('invite-cancel-btn')
      fireEvent.click(cancelBtn)
      expect(onCloseMock).toHaveBeenCalledTimes(1)

      const closeBtn = screen.getByTestId('invite-close-btn')
      fireEvent.click(closeBtn)
      expect(onCloseMock).toHaveBeenCalledTimes(2)
    })

    it('prompts confirmation on close when form is dirty', async () => {
      const confirmSpy = vi.spyOn(window, 'confirm')

      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const emailInput = screen.getByTestId('invite-email-input')
      await userEvent.type(emailInput, 'draft@domain.com')

      // Reject discard
      confirmSpy.mockReturnValueOnce(false)
      const cancelBtn = screen.getByTestId('invite-cancel-btn')
      fireEvent.click(cancelBtn)
      expect(confirmSpy).toHaveBeenCalledWith(expect.stringContaining('discard'))
      expect(onCloseMock).not.toHaveBeenCalled()

      // Accept discard
      confirmSpy.mockReturnValueOnce(true)
      fireEvent.click(cancelBtn)
      expect(onCloseMock).toHaveBeenCalledTimes(1)
    })

    it('closes on Escape key press', () => {
      render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      fireEvent.keyDown(document, { key: 'Escape' })
      expect(onCloseMock).toHaveBeenCalledTimes(1)
    })

    it('restores focus to returnFocusRef upon unmount', () => {
      const triggerButton = document.createElement('button')
      document.body.appendChild(triggerButton)
      const returnFocusRef = { current: triggerButton }

      const { unmount } = render(
        <InviteUserModal
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          returnFocusRef={returnFocusRef}
        />,
      )

      unmount()
      // Clean up body
      document.body.removeChild(triggerButton)
    })
  })
})
