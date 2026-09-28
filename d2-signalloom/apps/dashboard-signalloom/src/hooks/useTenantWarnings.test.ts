import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { useTenantWarnings, getTenantWarningsStorageKey } from './useTenantWarnings'
import { api } from '../api/client'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import type { AuditEventResponse, AuditListResponse } from '../types/api'

// Mock useAuth0 from oidc
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue(''),
    isAuthenticated: true,
  }),
}))

function makeJwt(tenantId: string): string {
  const header = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const payload = btoa(
    JSON.stringify({
      sub: `user-${tenantId}`,
      'https://signalloom.ai/tenant_id': tenantId,
      tenant_id: tenantId,
    }),
  )
  return `${header}.${payload}.signature`
}

function makeAuditEvent(id: string, event_type: string, agent_id = 'agent-1'): AuditEventResponse {
  return {
    id,
    timestamp: '2026-09-25T10:00:00Z',
    event_type,
    agent_id,
    agent_name: `Agent ${agent_id}`,
    actor: 'test-operator',
    detail: { reason: 'policy breach' },
  }
}

describe('useTenantWarnings hook', () => {
  const tenantA = 'tenant-alpha'
  const tenantB = 'tenant-beta'
  const tokenA = makeJwt(tenantA)
  const tokenB = makeJwt(tenantB)

  beforeEach(() => {
    installMemoryStorage()
    vi.clearAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('polls api.audit and derives unread notifications for tenant A', async () => {
    const warningsA: AuditEventResponse[] = [
      makeAuditEvent('ev-1', 'policy_violation', 'agent-a1'),
      makeAuditEvent('ev-2', 'containment_action', 'agent-a2'),
      makeAuditEvent('ev-3', 'agent.created', 'agent-a1'), // Non-warning event
    ]

    const auditSpy = vi.spyOn(api, 'audit').mockResolvedValue({
      events: warningsA,
      total: warningsA.length,
      page: 1,
      limit: 50,
      source_health: 'healthy',
    } as AuditListResponse)

    const { result } = renderHook(() =>
      useTenantWarnings({
        token: tokenA,
        pollIntervalMs: 5000,
      }),
    )

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
      expect(result.current.warnings.length).toBe(2)
    })

    expect(auditSpy).toHaveBeenCalledWith(tokenA, { limit: 50 })
    expect(result.current.tenantId).toBe(tenantA)
    expect(result.current.unreadCount).toBe(2)
    expect(result.current.unreadWarnings.map((w) => w.id)).toEqual(['ev-1', 'ev-2'])
  })

  it('updates unread count when subsequent poll returns three warnings', async () => {
    const batch1: AuditEventResponse[] = [
      makeAuditEvent('ev-1', 'policy_violation', 'agent-a1'),
      makeAuditEvent('ev-2', 'containment_action', 'agent-a2'),
    ]

    const batch2: AuditEventResponse[] = [
      makeAuditEvent('ev-1', 'policy_violation', 'agent-a1'),
      makeAuditEvent('ev-2', 'containment_action', 'agent-a2'),
      makeAuditEvent('ev-3', 'agent_expiry', 'agent-a3'),
    ]

    let callCount = 0
    vi.spyOn(api, 'audit').mockImplementation(async () => {
      callCount += 1
      const events = callCount === 1 ? batch1 : batch2
      return {
        events,
        total: events.length,
        page: 1,
        limit: 50,
        source_health: 'healthy',
      } as AuditListResponse
    })

    const { result } = renderHook(() =>
      useTenantWarnings({
        token: tokenA,
        pollIntervalMs: 100,
      }),
    )

    await waitFor(() => {
      expect(result.current.unreadCount).toBe(2)
    })

    // Trigger manual refresh or wait for next poll
    await act(async () => {
      await result.current.refresh()
    })

    expect(result.current.warnings.length).toBe(3)
    expect(result.current.unreadCount).toBe(3)
    expect(result.current.unreadWarnings.map((w) => w.id)).toEqual(['ev-1', 'ev-2', 'ev-3'])
  })

  it('persists read state in localStorage under tenant-scoped key', async () => {
    const warnings: AuditEventResponse[] = [
      makeAuditEvent('ev-10', 'policy_violation', 'agent-a1'),
      makeAuditEvent('ev-20', 'agent_expiry', 'agent-a2'),
    ]

    vi.spyOn(api, 'audit').mockResolvedValue({
      events: warnings,
      total: warnings.length,
      page: 1,
      limit: 50,
      source_health: 'healthy',
    } as AuditListResponse)

    const { result } = renderHook(() =>
      useTenantWarnings({
        token: tokenA,
      }),
    )

    await waitFor(() => {
      expect(result.current.unreadCount).toBe(2)
    })

    // Mark ev-10 as read
    act(() => {
      result.current.markAsRead('ev-10')
    })

    expect(result.current.unreadCount).toBe(1)
    expect(result.current.unreadWarnings.map((w) => w.id)).toEqual(['ev-20'])

    const storageKeyA = getTenantWarningsStorageKey(tenantA)
    const stored = JSON.parse(localStorage.getItem(storageKeyA) || '[]')
    expect(stored).toEqual(['ev-10'])

    // Mark all as read
    act(() => {
      result.current.markAllAsRead()
    })

    expect(result.current.unreadCount).toBe(0)
    expect(result.current.unreadWarnings).toEqual([])
    const storedAll = JSON.parse(localStorage.getItem(storageKeyA) || '[]')
    expect(storedAll).toEqual(expect.arrayContaining(['ev-10', 'ev-20']))
  })

  it('ensures two tenants never share read state in localStorage', async () => {
    const warnings: AuditEventResponse[] = [
      makeAuditEvent('ev-shared-1', 'policy_violation', 'agent-1'),
    ]

    vi.spyOn(api, 'audit').mockResolvedValue({
      events: warnings,
      total: warnings.length,
      page: 1,
      limit: 50,
      source_health: 'healthy',
    } as AuditListResponse)

    // Tenant A reads warning
    const { result: hookA } = renderHook(() =>
      useTenantWarnings({
        token: tokenA,
      }),
    )

    await waitFor(() => {
      expect(hookA.current.unreadCount).toBe(1)
    })

    act(() => {
      hookA.current.markAsRead('ev-shared-1')
    })

    expect(hookA.current.unreadCount).toBe(0)

    // Tenant B logs in on same browser
    const { result: hookB } = renderHook(() =>
      useTenantWarnings({
        token: tokenB,
      }),
    )

    await waitFor(() => {
      expect(hookB.current.tenantId).toBe(tenantB)
    })

    // Tenant B should still have unread count = 1 because storage keys are scoped
    expect(hookB.current.unreadCount).toBe(1)
    expect(hookB.current.unreadWarnings[0].id).toBe('ev-shared-1')

    const keyA = getTenantWarningsStorageKey(tenantA)
    const keyB = getTenantWarningsStorageKey(tenantB)

    expect(localStorage.getItem(keyA)).toContain('ev-shared-1')
    expect(localStorage.getItem(keyB)).toBeNull()
  })
})
