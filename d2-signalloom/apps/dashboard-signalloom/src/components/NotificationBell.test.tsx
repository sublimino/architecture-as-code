import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { createPortal } from 'react-dom'
import { NotificationBell, computeNotificationPanelPosition } from './NotificationBell'
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

  it('scopes iframe dismissal events to the rendered owner document', () => {
    const frame = document.createElement('iframe')
    document.body.appendChild(frame)
    const frameDocument = frame.contentDocument!
    const mount = frameDocument.createElement('div')
    frameDocument.body.appendChild(mount)

    const { unmount } = render(createPortal(
      <MemoryRouter>
        <NotificationBell warnings={[]} unreadWarnings={[]} unreadCount={0} />
      </MemoryRouter>,
      mount,
    ))
    const bell = frameDocument.querySelector<HTMLElement>('[data-testid="tenant-warnings-bell"]')!

    fireEvent.click(bell)
    expect(frameDocument.querySelector('[data-testid="tenant-warnings-panel"]')).not.toBeNull()

    fireEvent.keyDown(document, { key: 'Escape' })
    expect(frameDocument.querySelector('[data-testid="tenant-warnings-panel"]')).not.toBeNull()

    fireEvent.mouseDown(frameDocument.body)
    expect(frameDocument.querySelector('[data-testid="tenant-warnings-panel"]')).toBeNull()

    fireEvent.click(bell)
    fireEvent.keyDown(frameDocument, { key: 'Escape' })
    expect(frameDocument.querySelector('[data-testid="tenant-warnings-panel"]')).toBeNull()
    expect(frameDocument.activeElement).toBe(bell)

    unmount()
    frame.remove()
  })

  it('portals the open panel to the owner document body with a fixed position, escaping any clipping ancestor', () => {
    render(
      <MemoryRouter>
        <NotificationBell warnings={sampleWarnings} unreadWarnings={sampleWarnings} unreadCount={2} />
      </MemoryRouter>,
    )

    fireEvent.click(screen.getByTestId('tenant-warnings-bell'))
    const panel = screen.getByTestId('tenant-warnings-panel')

    // Portalled straight onto <body>, not nested inside the bell's relatively-positioned wrapper.
    expect(panel.parentElement).toBe(document.body)
    expect(panel.style.position).toBe('fixed')
  })

  it('escapes a sidebar-style overflow:hidden ancestor instead of being clipped', () => {
    render(
      <div style={{ overflow: 'hidden', width: 240, height: 400 }} data-testid="sidebar-clip">
        <MemoryRouter>
          <NotificationBell
            warnings={sampleWarnings}
            unreadWarnings={sampleWarnings}
            unreadCount={2}
            placement="top"
          />
        </MemoryRouter>
      </div>,
    )

    fireEvent.click(screen.getByTestId('tenant-warnings-bell'))
    const panel = screen.getByTestId('tenant-warnings-panel')
    const clipAncestor = screen.getByTestId('sidebar-clip')

    // The panel must not be a descendant of the overflow:hidden sidebar nav, or the
    // browser will clip it exactly as seen in the reported bug (panel cut off at ~140px).
    expect(clipAncestor.contains(panel)).toBe(false)
    expect(panel.parentElement).toBe(document.body)
    expect(panel.style.position).toBe('fixed')
  })

  it('does not close the panel when clicking inside the portalled content', () => {
    render(
      <MemoryRouter>
        <NotificationBell warnings={[]} unreadWarnings={[]} unreadCount={0} />
      </MemoryRouter>,
    )

    fireEvent.click(screen.getByTestId('tenant-warnings-bell'))
    expect(screen.getByTestId('tenant-warnings-panel')).toBeInTheDocument()

    fireEvent.mouseDown(screen.getByTestId('tenant-warnings-empty'))
    expect(screen.getByTestId('tenant-warnings-panel')).toBeInTheDocument()
  })

  it('closes the panel on an outside click even though the panel is portalled outside the container', () => {
    render(
      <div>
        <MemoryRouter>
          <NotificationBell warnings={[]} unreadWarnings={[]} unreadCount={0} />
        </MemoryRouter>
        <div data-testid="outside-element">outside</div>
      </div>,
    )

    fireEvent.click(screen.getByTestId('tenant-warnings-bell'))
    expect(screen.getByTestId('tenant-warnings-panel')).toBeInTheDocument()

    fireEvent.mouseDown(screen.getByTestId('outside-element'))
    expect(screen.queryByTestId('tenant-warnings-panel')).not.toBeInTheDocument()
  })
})

describe('computeNotificationPanelPosition', () => {
  const viewport = { width: 1024, height: 768 }

  it('positions the panel below and right-aligned to the anchor for bottom placement', () => {
    const anchor = { top: 100, left: 900, width: 32, height: 32 }
    const panel = { width: 380, height: 300 }
    const result = computeNotificationPanelPosition(anchor, panel, viewport, 'bottom')
    expect(result.top).toBe(100 + 32 + 8)
    expect(result.left).toBe(900 + 32 - 380)
  })

  it('positions the panel above and left-aligned to the anchor for top placement', () => {
    const anchor = { top: 700, left: 20, width: 32, height: 32 }
    const panel = { width: 380, height: 300 }
    const result = computeNotificationPanelPosition(anchor, panel, viewport, 'top')
    expect(result.top).toBe(700 - 8 - 300)
    expect(result.left).toBe(20)
  })

  it('clamps the panel inside the viewport when the naive position would overflow the right edge', () => {
    const anchor = { top: 10, left: 1000, width: 32, height: 32 }
    const panel = { width: 380, height: 300 }
    const result = computeNotificationPanelPosition(anchor, panel, viewport, 'bottom')
    expect(result.left).toBeLessThanOrEqual(viewport.width - panel.width - 8)
    expect(result.left).toBeGreaterThanOrEqual(8)
  })

  it('clamps the panel inside the viewport when the naive position would overflow the top edge', () => {
    const anchor = { top: 20, left: 20, width: 32, height: 32 }
    const panel = { width: 380, height: 300 }
    const result = computeNotificationPanelPosition(anchor, panel, viewport, 'top')
    expect(result.top).toBeGreaterThanOrEqual(8)
  })
})
