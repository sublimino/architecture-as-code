import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { api } from '../api/client'
import { useAuth0 } from '../auth/oidc'
import { getTenantIdFromToken } from '../auth/tenant'
import type { AuditEventResponse } from '../types/api'

export const TENANT_WARNING_EVENT_TYPES = [
  'policy_violation',
  'containment_action',
  'agent_expiry',
  'agent.stunned',
  'violation_detected',
  'agent.credential_revoked',
  'external_agent.revoked',
] as const

export type TenantWarningEventType = (typeof TENANT_WARNING_EVENT_TYPES)[number] | string

export interface TenantWarning {
  id: string
  timestamp: string
  event_type: string
  agent_id?: string | null
  agent_name?: string | null
  actor?: string | null
  detail?: Record<string, unknown>
  authorizing_principal_id?: string | null
  executing_actor_id?: string | null
  spiffe_id?: string | null
  attribution_rationale?: string | null
  evidence_ref?: string | null
}

export interface UseTenantWarningsOptions {
  pollIntervalMs?: number
  warningTypes?: readonly string[] | string[]
  enabled?: boolean
  token?: string
}

export interface UseTenantWarningsResult {
  warnings: TenantWarning[]
  unreadWarnings: TenantWarning[]
  unreadCount: number
  readEventIds: Set<string>
  markAsRead: (eventId: string) => void
  markAllAsRead: () => void
  clearReadState: () => void
  refresh: () => Promise<void>
  loading: boolean
  error: string | null
  tenantId: string | null
}

export function getTenantWarningsStorageKey(tenantId: string | null | undefined): string {
  const safeId = tenantId && tenantId.trim() ? tenantId.trim() : 'anonymous'
  return `signal_loom_read_warnings_${safeId}`
}

function loadReadIdsFromStorage(storageKey: string): Set<string> {
  if (typeof window === 'undefined' || !window.localStorage) {
    return new Set()
  }
  try {
    const raw = window.localStorage.getItem(storageKey)
    if (!raw) return new Set()
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      return new Set(parsed.filter((item): item is string => typeof item === 'string'))
    }
    return new Set()
  } catch {
    return new Set()
  }
}

function saveReadIdsToStorage(storageKey: string, ids: Set<string>): void {
  if (typeof window === 'undefined' || !window.localStorage) {
    return
  }
  try {
    window.localStorage.setItem(storageKey, JSON.stringify(Array.from(ids)))
  } catch {
    // Ignore storage quota or access errors
  }
}

export function useTenantWarnings({
  pollIntervalMs = 15_000,
  warningTypes = TENANT_WARNING_EVENT_TYPES,
  enabled = true,
  token: explicitToken,
}: UseTenantWarningsOptions = {}): UseTenantWarningsResult {
  const { getAccessTokenSilently } = useAuth0()
  const [warnings, setWarnings] = useState<TenantWarning[]>([])
  const [readEventIds, setReadEventIds] = useState<Set<string>>(() => new Set())
  const [loading, setLoading] = useState<boolean>(false)
  const [error, setError] = useState<string | null>(null)
  const [resolvedToken, setResolvedToken] = useState<string>(explicitToken ?? '')

  // Resolve current token
  useEffect(() => {
    if (explicitToken !== undefined) {
      setResolvedToken(explicitToken)
      return
    }
    let isSubscribed = true
    getAccessTokenSilently()
      .then((tok) => {
        if (isSubscribed) setResolvedToken(tok ?? '')
      })
      .catch(() => {
        if (isSubscribed) setResolvedToken('')
      })
    return () => {
      isSubscribed = false
    }
  }, [explicitToken, getAccessTokenSilently])

  // Derive tenant ID from active token
  const tenantId = useMemo(() => {
    if (!resolvedToken) return null
    return getTenantIdFromToken(resolvedToken)
  }, [resolvedToken])

  const storageKey = useMemo(() => getTenantWarningsStorageKey(tenantId), [tenantId])

  // Load read state from localStorage when tenant changes
  useEffect(() => {
    setReadEventIds(loadReadIdsFromStorage(storageKey))
  }, [storageKey])

  const warningTypesSet = useMemo(() => new Set(warningTypes), [warningTypes])

  const isMountedRef = useRef(true)
  useEffect(() => {
    isMountedRef.current = true
    return () => {
      isMountedRef.current = false
    }
  }, [])

  const fetchWarnings = useCallback(async () => {
    if (!enabled || !resolvedToken) {
      if (isMountedRef.current) {
        setWarnings([])
        setLoading(false)
      }
      return
    }

    setLoading(true)
    setError(null)

    try {
      const response = await api.audit(resolvedToken, { limit: 50 })
      const auditList: AuditEventResponse[] = response?.events || []

      const matched: TenantWarning[] = auditList
        .filter((ev) => warningTypesSet.has(ev.event_type))
        .map((ev) => ({
          id: ev.id,
          timestamp: ev.timestamp,
          event_type: ev.event_type,
          agent_id: ev.agent_id,
          agent_name: ev.agent_name,
          actor: ev.actor,
          detail: ev.detail,
          authorizing_principal_id: ev.authorizing_principal_id,
          executing_actor_id: ev.executing_actor_id,
          spiffe_id: ev.spiffe_id,
          attribution_rationale: ev.attribution_rationale,
          evidence_ref: ev.evidence_ref,
        }))

      if (isMountedRef.current) {
        setWarnings(matched)
        setError(null)
      }
    } catch (err) {
      if (isMountedRef.current) {
        const msg = err instanceof Error ? err.message : 'Failed to fetch tenant warnings'
        setError(msg)
      }
    } finally {
      if (isMountedRef.current) {
        setLoading(false)
      }
    }
  }, [enabled, resolvedToken, warningTypesSet])

  // Initial fetch and polling timer
  useEffect(() => {
    if (!enabled || !resolvedToken) return

    void fetchWarnings()

    if (pollIntervalMs <= 0) return

    const timer = setInterval(() => {
      void fetchWarnings()
    }, pollIntervalMs)

    return () => clearInterval(timer)
  }, [enabled, resolvedToken, pollIntervalMs, fetchWarnings])

  const markAsRead = useCallback(
    (eventId: string) => {
      setReadEventIds((prev) => {
        if (prev.has(eventId)) return prev
        const next = new Set(prev)
        next.add(eventId)
        saveReadIdsToStorage(storageKey, next)
        return next
      })
    },
    [storageKey],
  )

  const markAllAsRead = useCallback(() => {
    setReadEventIds((prev) => {
      const next = new Set(prev)
      for (const w of warnings) {
        next.add(w.id)
      }
      saveReadIdsToStorage(storageKey, next)
      return next
    })
  }, [storageKey, warnings])

  const clearReadState = useCallback(() => {
    const empty = new Set<string>()
    setReadEventIds(empty)
    saveReadIdsToStorage(storageKey, empty)
  }, [storageKey])

  const unreadWarnings = useMemo(
    () => warnings.filter((w) => !readEventIds.has(w.id)),
    [warnings, readEventIds],
  )

  const unreadCount = unreadWarnings.length

  return {
    warnings,
    unreadWarnings,
    unreadCount,
    readEventIds,
    markAsRead,
    markAllAsRead,
    clearReadState,
    refresh: fetchWarnings,
    loading,
    error,
    tenantId,
  }
}
