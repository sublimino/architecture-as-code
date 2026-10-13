import React from 'react'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, act } from '@testing-library/react'
import {
  FeatureFlagProvider,
  useFeatureFlagContext,
  clearFeatureFlagCache,
} from './FeatureFlagProvider'
import * as featuresApi from '../api/featuresApi'
import * as oidc from '../auth/oidc'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

function ConsumerComponent(): React.JSX.Element {
  const { flags, isLoading, tenantId, setFlagOverride, refetch } =
    useFeatureFlagContext()

  return (
    <div>
      <div data-testid="loading">{isLoading ? 'loading' : 'ready'}</div>
      <div data-testid="tenant">{tenantId ?? 'none'}</div>
      <div data-testid="demos_fleet">{flags.demos_fleet ? 'enabled' : 'disabled'}</div>
      <div data-testid="core_governance">
        {flags.core_governance ? 'enabled' : 'disabled'}
      </div>
      <button
        type="button"
        onClick={() => setFlagOverride('demos_fleet', true)}
        data-testid="toggle-btn"
      >
        Toggle
      </button>
      <button type="button" onClick={() => refetch()} data-testid="refetch-btn">
        Refetch
      </button>
    </div>
  )
}

describe('FeatureFlagProvider', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    clearFeatureFlagCache()
  })

  it('renders children with default system flags initially', async () => {
    vi.spyOn(featuresApi, 'fetchFeatures').mockResolvedValue({
      tenant_id: 'tenant-1',
      flags: { ...DEFAULT_SYSTEM_FLAGS },
    })

    render(
      <FeatureFlagProvider tenantId="tenant-1">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('loading').textContent).toBe('ready')
    })

    expect(screen.getByTestId('core_governance').textContent).toBe('enabled')
    expect(screen.getByTestId('demos_fleet').textContent).toBe('disabled')
    expect(screen.getByTestId('tenant').textContent).toBe('tenant-1')
  })

  it('fetches and applies active flags for the specified tenant', async () => {
    vi.spyOn(featuresApi, 'fetchFeatures').mockResolvedValue({
      tenant_id: 'tenant-2',
      flags: {
        ...DEFAULT_SYSTEM_FLAGS,
        demos_fleet: true,
      },
    })

    render(
      <FeatureFlagProvider tenantId="tenant-2">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('demos_fleet').textContent).toBe('enabled')
    })

    expect(featuresApi.fetchFeatures).toHaveBeenCalledWith(null, 'tenant-2')
  })

  it('refetches and updates flags when tenantId prop changes', async () => {
    const fetchSpy = vi.spyOn(featuresApi, 'fetchFeatures')

    fetchSpy.mockResolvedValueOnce({
      tenant_id: 'tenant-a',
      flags: { ...DEFAULT_SYSTEM_FLAGS, demos_fleet: false },
    })

    const { rerender } = render(
      <FeatureFlagProvider tenantId="tenant-a">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('tenant').textContent).toBe('tenant-a')
      expect(screen.getByTestId('demos_fleet').textContent).toBe('disabled')
    })

    fetchSpy.mockResolvedValueOnce({
      tenant_id: 'tenant-b',
      flags: { ...DEFAULT_SYSTEM_FLAGS, demos_fleet: true },
    })

    rerender(
      <FeatureFlagProvider tenantId="tenant-b">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('tenant').textContent).toBe('tenant-b')
      expect(screen.getByTestId('demos_fleet').textContent).toBe('enabled')
    })

    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it('serves cached flag results within stale time window', async () => {
    const fetchSpy = vi.spyOn(featuresApi, 'fetchFeatures')
    fetchSpy.mockResolvedValue({
      tenant_id: 'tenant-cached',
      flags: { ...DEFAULT_SYSTEM_FLAGS, demos_fleet: true },
    })

    const { unmount } = render(
      <FeatureFlagProvider tenantId="tenant-cached" staleTimeMs={60_000}>
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('demos_fleet').textContent).toBe('enabled')
    })
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    unmount()

    // Remount with same tenant immediately
    render(
      <FeatureFlagProvider tenantId="tenant-cached" staleTimeMs={60_000}>
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('demos_fleet').textContent).toBe('enabled')
    })
    // Second render reuses cache, no second API call
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('supports manual flag override via setFlagOverride', async () => {
    vi.spyOn(featuresApi, 'fetchFeatures').mockResolvedValue({
      tenant_id: 'tenant-override',
      flags: { ...DEFAULT_SYSTEM_FLAGS, demos_fleet: false },
    })

    render(
      <FeatureFlagProvider tenantId="tenant-override">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('demos_fleet').textContent).toBe('disabled')
    })

    act(() => {
      screen.getByTestId('toggle-btn').click()
    })

    expect(screen.getByTestId('demos_fleet').textContent).toBe('enabled')
  })

  it('handles backend API failure gracefully by defaulting flags without crashing', async () => {
    vi.spyOn(featuresApi, 'fetchFeatures').mockRejectedValue(
      new Error('500 Server Error'),
    )

    render(
      <FeatureFlagProvider tenantId="tenant-error">
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('loading').textContent).toBe('ready')
    })

    // UI remains stable with default system flags
    expect(screen.getByTestId('core_governance').textContent).toBe('enabled')
    expect(screen.getByTestId('demos_fleet').textContent).toBe('disabled')
  })

  it('does not call getAccessTokenSilently when auth.isAuthenticated is false', async () => {
    const getAccessTokenSilently = vi.fn().mockRejectedValue(new Error('Token expired'))
    vi.spyOn(oidc, 'useAuth0').mockReturnValue({
      isAuthenticated: false,
      isLoading: false,
      loginWithRedirect: vi.fn(),
      logout: vi.fn(),
      getAccessTokenSilently,
      user: undefined,
    })
    vi.spyOn(featuresApi, 'fetchFeatures').mockResolvedValue({
      tenant_id: 'default',
      flags: { ...DEFAULT_SYSTEM_FLAGS },
    })

    render(
      <FeatureFlagProvider>
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('loading').textContent).toBe('ready')
    })

    expect(getAccessTokenSilently).not.toHaveBeenCalled()
  })

  it('defers feature flag fetch while auth.isLoading is true', async () => {
    const fetchSpy = vi.spyOn(featuresApi, 'fetchFeatures').mockResolvedValue({
      tenant_id: 'default',
      flags: { ...DEFAULT_SYSTEM_FLAGS },
    })
    const useAuth0Spy = vi.spyOn(oidc, 'useAuth0').mockReturnValue({
      isAuthenticated: false,
      isLoading: true,
      loginWithRedirect: vi.fn(),
      logout: vi.fn(),
      getAccessTokenSilently: vi.fn().mockResolvedValue(''),
      user: undefined,
    })

    const { rerender } = render(
      <FeatureFlagProvider>
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    expect(fetchSpy).not.toHaveBeenCalled()

    useAuth0Spy.mockReturnValue({
      isAuthenticated: false,
      isLoading: false,
      loginWithRedirect: vi.fn(),
      logout: vi.fn(),
      getAccessTokenSilently: vi.fn().mockResolvedValue(''),
      user: undefined,
    })

    rerender(
      <FeatureFlagProvider>
        <ConsumerComponent />
      </FeatureFlagProvider>,
    )

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledTimes(1)
    })
  })
})
