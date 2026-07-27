import { useCallback, useEffect, useMemo, useState } from 'react'
import type { TenantConnector } from '../types/connectors'

export type ProviderRunStatus = 'idle' | 'submitting' | 'connected' | 'error'

export interface ProviderRunState {
  status: ProviderRunStatus
  error?: string
}

export type WizardStep =
  | { kind: 'select-providers' }
  | { kind: 'configure'; providerId: string }
  | { kind: 'summary' }

interface PersistedState {
  selectedProviderIds: string[]
  stepIndex: number
  providerRunState: Record<string, ProviderRunState>
}

function storageKey(tenantId: string | null): string {
  return `sl_onboarding_wizard_v1:${tenantId ?? 'anonymous'}`
}

function loadPersisted(tenantId: string | null): PersistedState | null {
  try {
    const raw = window.localStorage.getItem(storageKey(tenantId))
    if (!raw) return null
    return JSON.parse(raw) as PersistedState
  } catch {
    return null
  }
}

function savePersisted(tenantId: string | null, state: PersistedState): void {
  try {
    window.localStorage.setItem(storageKey(tenantId), JSON.stringify(state))
  } catch {
    // Storage unavailable (private mode / quota) — resume just won't work; non-fatal.
  }
}

// Resumable wizard progress. Persists to localStorage (namespaced by tenant)
// so a user can skip and come back — real cross-device persistence would
// need a backend endpoint, which is out of scope for this ticket (dashboard/**
// only); noted in the PR for Stream A.
export function useOnboardingWizard(tenantId: string | null, alreadyConnected: TenantConnector[]) {
  const persisted = useMemo(() => loadPersisted(tenantId), [tenantId])

  const [selectedProviderIds, setSelectedProviderIds] = useState<string[]>(
    persisted?.selectedProviderIds ?? [],
  )
  const [stepIndex, setStepIndex] = useState<number>(persisted?.stepIndex ?? 0)
  const [providerRunState, setProviderRunState] = useState<Record<string, ProviderRunState>>(
    persisted?.providerRunState ?? {},
  )

  // Reconcile with connectors that already exist server-side (prior session,
  // or another tab). Runs whenever the loaded connector list changes.
  useEffect(() => {
    if (alreadyConnected.length === 0) return

    setSelectedProviderIds((prev) => {
      const merged = new Set(prev)
      let changed = false
      for (const c of alreadyConnected) {
        if (c.status === 'connected' && !merged.has(c.provider_id)) {
          merged.add(c.provider_id)
          changed = true
        }
      }
      return changed ? Array.from(merged) : prev
    })

    setProviderRunState((prev) => {
      const next = { ...prev }
      let changed = false
      for (const c of alreadyConnected) {
        if (c.status === 'connected' && next[c.provider_id]?.status !== 'connected') {
          next[c.provider_id] = { status: 'connected' }
          changed = true
        }
      }
      return changed ? next : prev
    })
  }, [alreadyConnected])

  useEffect(() => {
    savePersisted(tenantId, { selectedProviderIds, stepIndex, providerRunState })
  }, [tenantId, selectedProviderIds, stepIndex, providerRunState])

  const steps: WizardStep[] = useMemo(
    () => [
      { kind: 'select-providers' },
      ...selectedProviderIds
        .filter((id) => providerRunState[id]?.status !== 'connected')
        .map((id): WizardStep => ({ kind: 'configure', providerId: id })),
      { kind: 'summary' },
    ],
    [selectedProviderIds, providerRunState],
  )

  const clampedIndex = Math.min(stepIndex, steps.length - 1)
  const currentStep = steps[clampedIndex]

  const toggleProvider = useCallback((providerId: string) => {
    setSelectedProviderIds((prev) =>
      prev.includes(providerId) ? prev.filter((id) => id !== providerId) : [...prev, providerId],
    )
  }, [])

  const goNext = useCallback(() => {
    setStepIndex((i) => Math.min(i + 1, steps.length - 1))
  }, [steps.length])

  const goBack = useCallback(() => {
    setStepIndex((i) => Math.max(i - 1, 0))
  }, [])

  const goToStep = useCallback(
    (index: number) => {
      setStepIndex(Math.max(0, Math.min(index, steps.length - 1)))
    },
    [steps.length],
  )

  const setProviderStatus = useCallback((providerId: string, next: ProviderRunState) => {
    setProviderRunState((prev) => ({ ...prev, [providerId]: next }))
  }, [])

  const reset = useCallback(() => {
    setSelectedProviderIds([])
    setStepIndex(0)
    setProviderRunState({})
    try {
      window.localStorage.removeItem(storageKey(tenantId))
    } catch {
      // ignore
    }
  }, [tenantId])

  return {
    steps,
    currentStep,
    stepIndex: clampedIndex,
    selectedProviderIds,
    providerRunState,
    toggleProvider,
    goNext,
    goBack,
    goToStep,
    setProviderStatus,
    reset,
  }
}
