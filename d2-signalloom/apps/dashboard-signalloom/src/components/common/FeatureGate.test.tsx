import React from 'react'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { FeatureGate } from './FeatureGate'
import {
  FeatureFlagProvider,
  useFeatureFlagContext,
  clearFeatureFlagCache,
} from '../../providers/FeatureFlagProvider'

function Wrapper({
  initialFlags,
  children,
}: {
  initialFlags: Record<string, boolean>
  children: React.ReactNode
}) {
  return (
    <FeatureFlagProvider initialFlags={initialFlags} disableAutoFetch={true}>
      {children}
    </FeatureFlagProvider>
  )
}

function CrashingChild(): React.JSX.Element {
  throw new Error('Explosive component crash')
}

describe('FeatureGate', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearFeatureFlagCache()
  })

  it('renders children when the target flag is enabled', () => {
    render(
      <Wrapper initialFlags={{ demos_fleet: true }}>
        <FeatureGate flag="demos_fleet">
          <div data-testid="gated-content">Fleet Demo Active</div>
        </FeatureGate>
      </Wrapper>,
    )

    expect(screen.getByTestId('gated-content')).toBeTruthy()
    expect(screen.getByText('Fleet Demo Active')).toBeTruthy()
  })

  it('renders fallback when the target flag is disabled', () => {
    render(
      <Wrapper initialFlags={{ demos_fleet: false }}>
        <FeatureGate
          flag="demos_fleet"
          fallback={<div data-testid="fallback-content">Upgrade Required</div>}
        >
          <div data-testid="gated-content">Fleet Demo Active</div>
        </FeatureGate>
      </Wrapper>,
    )

    expect(screen.queryByTestId('gated-content')).toBeNull()
    expect(screen.getByTestId('fallback-content')).toBeTruthy()
    expect(screen.getByText('Upgrade Required')).toBeTruthy()
  })

  it('renders null when the target flag is disabled and no fallback is provided', () => {
    const { container } = render(
      <Wrapper initialFlags={{ demos_fleet: false }}>
        <FeatureGate flag="demos_fleet">
          <div data-testid="gated-content">Fleet Demo Active</div>
        </FeatureGate>
      </Wrapper>,
    )

    expect(screen.queryByTestId('gated-content')).toBeNull()
    expect(container.innerHTML).toBe('')
  })

  it('renders loadingFallback during loading state to prevent layout shifts', () => {
    // Render with a provider that is currently loading
    function LoadingProvider({ children }: { children: React.ReactNode }) {
      return (
        <FeatureFlagProvider
          initialFlags={{ supercred: false }}
          disableAutoFetch={false}
          tenantId="tenant-slow"
        >
          {children}
        </FeatureFlagProvider>
      )
    }

    render(
      <LoadingProvider>
        <FeatureGate
          flag="supercred"
          loadingFallback={<div data-testid="skeleton-loader">Loading skeleton...</div>}
          fallback={<div data-testid="fallback">Disabled</div>}
        >
          <div data-testid="protected">SuperCred Active</div>
        </FeatureGate>
      </LoadingProvider>,
    )

    expect(screen.getByTestId('skeleton-loader')).toBeTruthy()
    expect(screen.queryByTestId('protected')).toBeNull()
  })

  it('supports inverted gating (invert=true)', () => {
    render(
      <Wrapper initialFlags={{ supercred: false }}>
        <FeatureGate
          flag="supercred"
          invert={true}
          fallback={<div data-testid="fallback">SuperCred is Enabled</div>}
        >
          <div data-testid="unlocked-standard">Standard Console View</div>
        </FeatureGate>
      </Wrapper>,
    )

    expect(screen.getByTestId('unlocked-standard')).toBeTruthy()
    expect(screen.queryByTestId('fallback')).toBeNull()
  })

  it('catches runtime child crashes in FeatureGateErrorBoundary and displays fallback', () => {
    // Suppress expected console.error during error boundary test
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    render(
      <Wrapper initialFlags={{ core_governance: true }}>
        <FeatureGate
          flag="core_governance"
          fallback={<div data-testid="error-fallback">Safe Error Recovery</div>}
        >
          <CrashingChild />
        </FeatureGate>
      </Wrapper>,
    )

    expect(screen.getByTestId('error-fallback')).toBeTruthy()
    expect(screen.getByText('Safe Error Recovery')).toBeTruthy()

    consoleSpy.mockRestore()
  })

  it('updates reactively when underlying flag changes', () => {
    function ToggleController() {
      const { setFlagOverride } = useFeatureFlagContext()
      return (
        <div>
          <button
            type="button"
            data-testid="toggle-flag"
            onClick={() => setFlagOverride('supercred', true)}
          >
            Enable SuperCred
          </button>
          <FeatureGate
            flag="supercred"
            fallback={<div data-testid="fallback-state">Locked</div>}
          >
            <div data-testid="active-state">Unlocked</div>
          </FeatureGate>
        </div>
      )
    }

    render(
      <FeatureFlagProvider
        initialFlags={{ supercred: false }}
        disableAutoFetch={true}
      >
        <ToggleController />
      </FeatureFlagProvider>,
    )

    expect(screen.getByTestId('fallback-state')).toBeTruthy()
    expect(screen.queryByTestId('active-state')).toBeNull()

    act(() => {
      screen.getByTestId('toggle-flag').click()
    })

    expect(screen.queryByTestId('fallback-state')).toBeNull()
    expect(screen.getByTestId('active-state')).toBeTruthy()
  })
})
