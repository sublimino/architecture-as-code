import { describe, it, expect, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useOnboardingWizard } from './useOnboardingWizard'
import type { TenantConnector } from '../types/connectors'

const TENANT = 'tenant-abc'

// Node 22+'s built-in global `localStorage` (enabled without a valid
// `--localstorage-file`) shadows jsdom's implementation with a broken stub
// missing `.clear()`. Replace it with a real in-memory Storage for this
// suite so persistence behavior can actually be exercised.
class MemoryStorage implements Storage {
  private store = new Map<string, string>()
  get length() { return this.store.size }
  clear() { this.store.clear() }
  getItem(key: string) { return this.store.has(key) ? this.store.get(key)! : null }
  key(index: number) { return Array.from(this.store.keys())[index] ?? null }
  removeItem(key: string) { this.store.delete(key) }
  setItem(key: string, value: string) { this.store.set(key, String(value)) }
}

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
  beforeEach(() => {
    Object.defineProperty(window, 'localStorage', {
      value: new MemoryStorage(),
      configurable: true,
      writable: true,
    })
  })

  it('starts on the select-providers step with no persisted state', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, []))
    expect(result.current.currentStep).toEqual({ kind: 'select-providers' })
    expect(result.current.selectedProviderIds).toEqual([])
  })

  it('adds a configure step per selected provider and advances through them', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, []))

    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.toggleProvider('okta'))

    expect(result.current.steps).toEqual([
      { kind: 'select-providers' },
      { kind: 'configure', providerId: 'ad_entra' },
      { kind: 'configure', providerId: 'okta' },
      { kind: 'summary' },
    ])

    act(() => result.current.goNext())
    expect(result.current.currentStep).toEqual({ kind: 'configure', providerId: 'ad_entra' })
  })

  it('removes a provider configure step once it is marked connected', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, []))

    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.toggleProvider('okta'))
    act(() => result.current.goNext()) // -> configure ad_entra

    act(() => result.current.setProviderStatus('ad_entra', { status: 'connected' }))

    // ad_entra's configure step is gone; index 1 now lands on okta's step.
    expect(result.current.steps).toEqual([
      { kind: 'select-providers' },
      { kind: 'configure', providerId: 'okta' },
      { kind: 'summary' },
    ])
    expect(result.current.currentStep).toEqual({ kind: 'configure', providerId: 'okta' })
  })

  it('reconciles already-connected connectors without requiring re-selection', () => {
    const { result } = renderHook(() =>
      useOnboardingWizard(TENANT, [connector({ provider_id: 'ad_entra', status: 'connected' })]),
    )

    expect(result.current.selectedProviderIds).toContain('ad_entra')
    expect(result.current.providerRunState.ad_entra).toEqual({ status: 'connected' })
    // No configure step is generated for an already-connected provider.
    expect(result.current.steps).toEqual([
      { kind: 'select-providers' },
      { kind: 'summary' },
    ])
  })

  // ---- Resume flow -------------------------------------------------------

  it('persists progress so a fresh mount (simulating reload) resumes at the same step', () => {
    const first = renderHook(() => useOnboardingWizard(TENANT, []))

    act(() => first.result.current.toggleProvider('ad_entra'))
    act(() => first.result.current.toggleProvider('okta'))
    act(() => first.result.current.goNext())
    act(() => first.result.current.setProviderStatus('ad_entra', { status: 'error', error: 'bad creds' }))
    first.unmount()

    const second = renderHook(() => useOnboardingWizard(TENANT, []))

    expect(second.result.current.selectedProviderIds).toEqual(['ad_entra', 'okta'])
    expect(second.result.current.currentStep).toEqual({ kind: 'configure', providerId: 'ad_entra' })
    expect(second.result.current.providerRunState.ad_entra).toEqual({ status: 'error', error: 'bad creds' })
  })

  it('scopes persisted state by tenant — a different tenant starts fresh', () => {
    const first = renderHook(() => useOnboardingWizard(TENANT, []))
    act(() => first.result.current.toggleProvider('ad_entra'))
    first.unmount()

    const other = renderHook(() => useOnboardingWizard('tenant-xyz', []))
    expect(other.result.current.selectedProviderIds).toEqual([])
  })

  it('reset clears persisted state and in-memory selections', () => {
    const { result } = renderHook(() => useOnboardingWizard(TENANT, []))
    act(() => result.current.toggleProvider('ad_entra'))
    act(() => result.current.reset())

    expect(result.current.selectedProviderIds).toEqual([])
    expect(result.current.currentStep).toEqual({ kind: 'select-providers' })

    const resumed = renderHook(() => useOnboardingWizard(TENANT, []))
    expect(resumed.result.current.selectedProviderIds).toEqual([])
  })
})
