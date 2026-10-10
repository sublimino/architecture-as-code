import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import EditUserModal from './EditUserModal'
import * as usersApiModule from '../../api/usersApi'
import type { PlatformUser, UsersApiError } from '../../api/usersApi'

const MOCK_USER: PlatformUser = {
  id: 'usr-edit-456',
  tenant_id: 'tenant-acme',
  email: 'bob@acme.com',
  display_name: 'Bob Operator',
  role: 'editor',
  status: 'active',
  is_superadmin: false,
  title: 'Platform Engineer',
  department: 'Core Infrastructure',
  created_at: '2026-01-10T00:00:00Z',
}

describe('EditUserModal Component', () => {
  const onCloseMock = vi.fn()
  const onSuccessMock = vi.fn()
  let mutateAsyncMock: ReturnType<typeof vi.fn>
  let mockUseUpdateUser: ReturnType<typeof vi.fn>

  beforeEach(() => {
    vi.clearAllMocks()

    mutateAsyncMock = vi.fn().mockImplementation(async (vars) => {
      return {
        ...MOCK_USER,
        ...vars.payload,
      }
    })

    mockUseUpdateUser = vi.fn().mockImplementation((options) => ({
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

    vi.spyOn(usersApiModule, 'useUpdateUser').mockImplementation(mockUseUpdateUser as any)
  })

  describe('Dialog Accessibility & Initialization', () => {
    it('renders accessible dialog with user details pre-populated', () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const dialog = screen.getByRole('dialog')
      expect(dialog).toBeInTheDocument()
      expect(dialog).toHaveAttribute('aria-modal', 'true')
      expect(dialog).toHaveAttribute('aria-labelledby')
      expect(dialog).toHaveAttribute('aria-describedby')

      expect(screen.getByRole('heading', { level: 2, name: 'Edit Operator Profile' })).toBeInTheDocument()
      expect(screen.getByTestId('edit-email-display')).toHaveTextContent('bob@acme.com')
      expect(screen.getByTestId('edit-display-name-input')).toHaveValue('Bob Operator')
      expect(screen.getByTestId('edit-role-select')).toHaveValue('editor')
      expect(screen.getByTestId('edit-status-select')).toHaveValue('active')
      expect(screen.getByTestId('edit-title-input')).toHaveValue('Platform Engineer')
      expect(screen.getByTestId('edit-department-input')).toHaveValue('Core Infrastructure')
    })

    it('returns null when user is null or isOpen is false', () => {
      const { container: c1 } = render(
        <EditUserModal
          user={null}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )
      expect(c1.firstChild).toBeNull()

      const { container: c2 } = render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={false}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )
      expect(c2.firstChild).toBeNull()
    })
  })

  describe('Form Modifications & Sensitive Change Confirmation', () => {
    it('keeps submit button disabled when no changes have been made', () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const submitBtn = screen.getByTestId('edit-submit-btn')
      expect(submitBtn).toBeDisabled()
      expect(submitBtn).toHaveTextContent('Save Changes')
    })

    it('allows simple metadata edits (name/title/dept) without confirmation prompt', async () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          token="test-token"
        />,
      )

      const nameInput = screen.getByTestId('edit-display-name-input')
      await userEvent.clear(nameInput)
      await userEvent.type(nameInput, 'Bob Senior Operator')

      // Confirmation callout should NOT appear for simple metadata edits
      expect(screen.queryByTestId('edit-confirmation-callout')).not.toBeInTheDocument()

      const submitBtn = screen.getByTestId('edit-submit-btn')
      expect(submitBtn).toBeEnabled()

      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            userId: 'usr-edit-456',
            payload: expect.objectContaining({
              display_name: 'Bob Senior Operator',
            }),
            token: 'test-token',
          }),
        )
        expect(onSuccessMock).toHaveBeenCalledTimes(1)
        expect(onCloseMock).toHaveBeenCalledTimes(1)
      })
    })

    it('requires confirmation checkbox when role is modified', async () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const roleSelect = screen.getByTestId('edit-role-select')
      const submitBtn = screen.getByTestId('edit-submit-btn')

      // Change role from editor to admin
      fireEvent.change(roleSelect, { target: { value: 'admin' } })

      // Confirmation callout must appear
      const callout = screen.getByTestId('edit-confirmation-callout')
      expect(callout).toBeInTheDocument()
      expect(callout).toHaveTextContent(/Role changing from editor to admin/i)

      // Submit remains disabled until confirmed
      expect(submitBtn).toBeDisabled()

      // Check confirmation box
      const confirmCheck = screen.getByTestId('edit-confirm-checkbox')
      await userEvent.click(confirmCheck)
      expect(submitBtn).toBeEnabled()

      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            userId: 'usr-edit-456',
            payload: expect.objectContaining({
              role: 'admin',
            }),
          }),
        )
      })
    })

    it('requires confirmation checkbox when status is changed to suspended', async () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const statusSelect = screen.getByTestId('edit-status-select')
      const submitBtn = screen.getByTestId('edit-submit-btn')

      // Change status to suspended
      fireEvent.change(statusSelect, { target: { value: 'suspended' } })

      expect(screen.getByTestId('edit-confirmation-callout')).toHaveTextContent(
        /Status changing from active to suspended/i,
      )
      expect(submitBtn).toBeDisabled()

      // Confirm
      await userEvent.click(screen.getByTestId('edit-confirm-checkbox'))
      expect(submitBtn).toBeEnabled()

      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            payload: expect.objectContaining({
              status: 'suspended',
            }),
          }),
        )
      })
    })

    it('displays server error banner on mutation failure', async () => {
      mutateAsyncMock.mockRejectedValueOnce(
        new usersApiModule.UsersApiError('Unauthorized: Insufficient privileges to promote user', 403),
      )

      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const nameInput = screen.getByTestId('edit-display-name-input')
      await userEvent.type(nameInput, ' New')

      const submitBtn = screen.getByTestId('edit-submit-btn')
      await userEvent.click(submitBtn)

      await waitFor(() => {
        const errorBanner = screen.getByTestId('edit-error-banner')
        expect(errorBanner).toBeInTheDocument()
        expect(errorBanner).toHaveTextContent('Unauthorized: Insufficient privileges to promote user')
      })

      // Error banner is dismissible
      const dismissBtn = within(screen.getByTestId('edit-error-banner')).getByRole('button', { name: /dismiss error/i })
      fireEvent.click(dismissBtn)
      expect(screen.queryByTestId('edit-error-banner')).not.toBeInTheDocument()
    })
  })

  describe('Superadmin Privileges & Tenant Assignment', () => {
    it('hides superadmin section when viewing as normal admin', () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          isSuperadmin={false}
        />,
      )

      expect(screen.queryByTestId('edit-superadmin-section')).not.toBeInTheDocument()
      expect(screen.queryByTestId('edit-tenant-select')).not.toBeInTheDocument()
      expect(screen.queryByTestId('edit-tenant-input')).not.toBeInTheDocument()
      expect(screen.queryByTestId('edit-superadmin-checkbox')).not.toBeInTheDocument()
    })

    it('renders superadmin tenant dropdown and superadmin authority toggle when isSuperadmin=true', async () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
          isSuperadmin={true}
          availableTenants={['tenant-acme', 'tenant-kusari']}
        />,
      )

      expect(screen.getByTestId('edit-superadmin-section')).toBeInTheDocument()
      const tenantSelect = screen.getByTestId('edit-tenant-select')
      expect(tenantSelect).toBeInTheDocument()
      expect(tenantSelect).toHaveValue('tenant-acme')

      const superadminCheckbox = screen.getByTestId('edit-superadmin-checkbox')
      expect(superadminCheckbox).toBeInTheDocument()
      expect(superadminCheckbox).not.toBeChecked()

      // Change tenant and grant superadmin
      fireEvent.change(tenantSelect, { target: { value: 'tenant-kusari' } })
      await userEvent.click(superadminCheckbox)

      // Superadmin change is impactful -> requires confirm
      expect(screen.getByTestId('edit-confirmation-callout')).toBeInTheDocument()
      await userEvent.click(screen.getByTestId('edit-confirm-checkbox'))

      const submitBtn = screen.getByTestId('edit-submit-btn')
      await userEvent.click(submitBtn)

      await waitFor(() => {
        expect(mutateAsyncMock).toHaveBeenCalledWith(
          expect.objectContaining({
            payload: expect.objectContaining({
              tenant_id: 'tenant-kusari',
              is_superadmin: true,
            }),
          }),
        )
      })
    })
  })

  describe('Modal Dismissal & Focus Restoration', () => {
    it('closes on Cancel click when form is clean', () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const cancelBtn = screen.getByTestId('edit-cancel-btn')
      fireEvent.click(cancelBtn)
      expect(onCloseMock).toHaveBeenCalledTimes(1)
    })

    it('prompts confirmation when closing dirty form', async () => {
      const confirmSpy = vi.spyOn(window, 'confirm')

      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      const nameInput = screen.getByTestId('edit-display-name-input')
      await userEvent.type(nameInput, ' Modified')

      // User rejects discard
      confirmSpy.mockReturnValueOnce(false)
      const closeBtn = screen.getByTestId('edit-close-btn')
      fireEvent.click(closeBtn)
      expect(confirmSpy).toHaveBeenCalledWith(expect.stringContaining('discard'))
      expect(onCloseMock).not.toHaveBeenCalled()

      // User confirms discard
      confirmSpy.mockReturnValueOnce(true)
      fireEvent.click(closeBtn)
      expect(onCloseMock).toHaveBeenCalledTimes(1)
    })

    it('closes on Escape key press', () => {
      render(
        <EditUserModal
          user={MOCK_USER}
          isOpen={true}
          onClose={onCloseMock}
          onSuccess={onSuccessMock}
        />,
      )

      fireEvent.keyDown(document, { key: 'Escape' })
      expect(onCloseMock).toHaveBeenCalledTimes(1)
    })
  })
})
