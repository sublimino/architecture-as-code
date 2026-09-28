import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { NotificationBell } from './NotificationBell'
import type { TenantWarning } from '../hooks/useTenantWarnings'

// Mock useAuth0
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue(''),
    isAuthenticated: true,
  }),
}))

describe('NotificationBell component', () => {
  const sampleWarnings: TenantWarning[] = [
    {
      id: 'audit-event-101',
      timestamp: '2026-09-25T10:30:00Z',
      event_type: 'policy_violation',
      agent_id: 'agent-cardvault',
      agent_name: 'Card Vault Agent',
    },
    {
      id: 'audit-event-102',
      timestamp: '2026-09-25T11:00:00Z',
      event_type: 'containment_action',
      agent_id: 'agent-triage',
      agent_name: 'Triage Agent',
    },
  ]

  it('renders bell button with unread count badge', () => {
    render(
      <MemoryRouter>
        <NotificationBell
          warnings={sampleWarnings}
          unreadWarnings={sampleWarnings}
          unreadCount={2}
        />
      </MemoryRouter>,
    )

    const bell = screen.getByTestId('tenant-warnings-bell')
    expect(bell).toBeInTheDocument()

    const countBadge = screen.getByTestId('tenant-warnings-count')
    expect(countBadge).toBeInTheDocument()
    expect(countBadge.textContent).toBe('2')
  })

  it('opens panel on click and renders warning links carrying audit event ID', () => {
    const markAsRead = vi.fn()
    const markAllAsRead = vi.fn()

    render(
      <MemoryRouter>
        <NotificationBell
          warnings={sampleWarnings}
          unreadWarnings={sampleWarnings}
          unreadCount={2}
          onMarkAsRead={markAsRead}
          onMarkAllAsRead={markAllAsRead}
        />
      </MemoryRouter>,
    )

    const bell = screen.getByTestId('tenant-warnings-bell')
    fireEvent.click(bell)

    expect(screen.getByTestId('tenant-warnings-panel')).toBeInTheDocument()

    // Assert row 1
    const row1 = screen.getByTestId('tenant-warning-row-audit-event-101')
    expect(row1).toBeInTheDocument()
    expect(row1.textContent).toContain('Card Vault Agent')
    expect(row1.textContent).toContain('POLICY VIOLATION')

    const link1 = screen.getByTestId('tenant-warning-link-audit-event-101')
    expect(link1).toBeInTheDocument()
    expect(link1.getAttribute('href')).toContain('audit=audit-event-101')
    expect(link1.getAttribute('href')).toContain('/agents/agent-cardvault')

    // Assert row 2
    const row2 = screen.getByTestId('tenant-warning-row-audit-event-102')
    expect(row2).toBeInTheDocument()
    expect(row2.textContent).toContain('Triage Agent')

    const link2 = screen.getByTestId('tenant-warning-link-audit-event-102')
    expect(link2.getAttribute('href')).toContain('audit=audit-event-102')

    // Click mark read
    const markReadBtn = screen.getByTestId('tenant-warning-mark-read-audit-event-101')
    fireEvent.click(markReadBtn)
    expect(markAsRead).toHaveBeenCalledWith('audit-event-101')

    // Click mark all read
    const markAllBtn = screen.getByTestId('tenant-warnings-mark-all')
    fireEvent.click(markAllBtn)
    expect(markAllAsRead).toHaveBeenCalled()
  })

  it('renders empty state when there are zero warnings and hides count badge', () => {
    render(
      <MemoryRouter>
        <NotificationBell warnings={[]} unreadWarnings={[]} unreadCount={0} />
      </MemoryRouter>,
    )

    expect(screen.queryByTestId('tenant-warnings-count')).not.toBeInTheDocument()

    const bell = screen.getByTestId('tenant-warnings-bell')
    fireEvent.click(bell)

    expect(screen.getByTestId('tenant-warnings-empty')).toBeInTheDocument()
    expect(screen.getByTestId('tenant-warnings-empty').textContent).toContain('No active tenant warnings')
  })
})
