import { useCallback, useEffect, useMemo, useState } from 'react'
import type { TenantConnector } from '../types/connectors'

export type ProviderRunStatus = 'idle' | 'submitting' | 'connected' | 'error'

export interface ProviderRunState {
  status: ProviderRunStatus
  error?: string
}

export type WizardStep =
  | { kind: 'welcome' }
  | { kind: 'select-providers' }
  | { kind: 'configure'; providerId: string }
  | { kind: 'preferences' }
  | { kind: 'api-key' }
  | { kind: 'summary' }

export interface WizardPersistedState {
  selectedProviderIds: string[]
  stepIndex: number
  providerRunState: Record<string, ProviderRunState>
}

// Resumable wizard progress. Server-side (Slice 1a, 86cajpvar QA item g) —
// `initialState` is fetched by the caller (OnboardingWizard.tsx, via
// GET /onboarding/state) before this hook mounts, so a user who starts the
// wizard on one device resumes at the same step on another. State updates
// are instant/optimistic (plain useState); the caller is responsible for
// debouncing writes back to PUT /onboarding/state — this hook only owns the
// in-memory state machine, not persistence.
export function useOnboardingWizard(
  tenantId: string | null,
  alreadyConnected: TenantConnector[],
  initialState: WizardPersistedState | null,
) {
  const [selectedProviderIds, setSelectedProviderIds] = useState<string[]>(
    initialState?.selectedProviderIds ?? [],
  )
  const [stepIndex, setStepIndex] = useState<number>(initialState?.stepIndex ?? 0)
  const [providerRunState, setProviderRunState] = useState<Record<string, ProviderRunState>>(
    initialState?.providerRunState ?? {},
  )

  // Reconcile with connectors that already exist server-side (prior session,
  // or another tab/device). Runs whenever the loaded connector list changes.
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

  const steps: WizardStep[] = useMemo(
    () => [
      { kind: 'welcome' },
      { kind: 'select-providers' },
      ...selectedProviderIds
        .filter((id) => providerRunState[id]?.status !== 'connected')
        .map((id): WizardStep => ({ kind: 'configure', providerId: id })),
      { kind: 'preferences' },
      { kind: 'api-key' },
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
  }, [])

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
