import { describe, it, expect } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useOnboardingWizard } from './useOnboardingWizard'
import type { TenantConnector } from '../types/connectors'

const TENANT = 'tenant-abc'

function connector(overrides: Partial<TenantConnector> = {}): TenantConnector {
  return {
    connector_id: 'c1',
    provider_id: 'ad_entra',
    display_name: 'Microsoft Entra ID',
    status: 'connected',
    credential_expires_at: null,
    last_tested_at: null,
    last_scan_at: null,
    metadata: {},
    created_at: '2026-07-01T00:00:00Z',
    ...overrides,
  }
}

describe('useOnboardingWizard', () => {
  it('starts on the welcome step with no initial state', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, [], null))
    expect(result.current.currentStep).toEqual({ kind: 'welcome' })
    expect(result.current.selectedProviderIds).toEqual([])
  })

  it('adds a configure step per selected provider and advances through them', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, [], null))

    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.toggleProvider('okta'))

    expect(result.current.steps).toEqual([
      { kind: 'welcome' },
      { kind: 'select-providers' },
      { kind: 'configure', providerId: 'ad_entra' },
      { kind: 'configure', providerId: 'okta' },
      { kind: 'preferences' },
      { kind: 'api-key' },
      { kind: 'summary' },
    ])

    act(() => result.current.goNext()) // welcome -> select-providers
    act(() => result.current.goNext()) // select-providers -> configure ad_entra
    expect(result.current.currentStep).toEqual({ kind: 'configure', providerId: 'ad_entra' })
  })

  it('removes a provider configure step once it is marked connected', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, [], null))

    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.toggleProvider('okta'))
    act(() => result.current.goNext()) // welcome -> select-providers
    act(() => result.current.goNext()) // select-providers -> configure ad_entra

    act(() => result.current.setProviderStatus('ad_entra', { status: 'connected' }))

    // ad_entra's configure step is gone; the same index now lands on okta's step.
    expect(result.current.steps).toEqual([
      { kind: 'welcome' },
      { kind: 'select-providers' },
      { kind: 'configure', providerId: 'okta' },
      { kind: 'preferences' },
      { kind: 'api-key' },
      { kind: 'summary' },
    ])
    expect(result.current.currentStep).toEqual({ kind: 'configure', providerId: 'okta' })
  })

  it('reconciles already-connected connectors without requiring re-selection', () => {
    const { result } = renderHook(() =>
      useOnboardingWizard(TENANT, [connector({ provider_id: 'ad_entra', status: 'connected' })], null),
    )

    expect(result.current.selectedProviderIds).toContain('ad_entra')
    expect(result.current.providerRunState.ad_entra).toEqual({ status: 'connected' })
    // No configure step is generated for an already-connected provider.
    expect(result.current.steps).toEqual([
      { kind: 'welcome' },
      { kind: 'select-providers' },
      { kind: 'preferences' },
      { kind: 'api-key' },
      { kind: 'summary' },
    ])
  })

  // ---- Resume flow (server-side state now, Slice 1a) ---------------------
  // Persistence itself is owned by the caller (OnboardingWizard.tsx, via
  // GET/PUT /onboarding/state) — the hook's contract is just "seed from
  // whatever initialState you're given," which these cases exercise
  // directly instead of round-tripping through localStorage.

  it('seeds from a server-provided initialState (simulates cross-device resume)', () => {
    const { result } = renderHook(() =>
      useOnboardingWizard(TENANT, [], {
        selectedProviderIds: ['ad_entra', 'okta'],
        stepIndex: 2, // welcome(0), select-providers(1), configure ad_entra(2)
        providerRunState: { ad_entra: { status: 'error', error: 'bad creds' } },
      }),
    )

    expect(result.current.selectedProviderIds).toEqual(['ad_entra', 'okta'])
    expect(result.current.currentStep).toEqual({ kind: 'configure', providerId: 'ad_entra' })
    expect(result.current.providerRunState.ad_entra).toEqual({ status: 'error', error: 'bad creds' })
  })

  it('starts fresh when initialState is null (new tenant, never started)', () => {
    const { result } = renderHook(() => useOnboardingWizard('tenant-xyz', [], null))
    expect(result.current.selectedProviderIds).toEqual([])
  })

  it('reset clears in-memory selections', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, [], null))
    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.reset())

    expect(result.current.selectedProviderIds).toEqual([])
    expect(result.current.currentStep).toEqual({ kind: 'welcome' })
  })
})
