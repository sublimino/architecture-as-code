import React from 'react'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useFeatureFlag } from './useFeatureFlag'
import {
  FeatureFlagProvider,
  useFeatureFlagContext,
  clearFeatureFlagCache,
} from '../providers/FeatureFlagProvider'
import * as featuresApi from '../api/featuresApi'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

function wrapperWithFlags(initialFlags: Record<string, boolean>) {
  return function ProviderWrapper({ children }: { children: React.ReactNode }) {
    return (
      <FeatureFlagProvider initialFlags={initialFlags} disableAutoFetch={true}>
        {children}
      </FeatureFlagProvider>
    )
  }
}

describe('useFeatureFlag', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    clearFeatureFlagCache()
  })

  it('evaluates enabled flags correctly as true', () => {
    const { result } = renderHook(() => useFeatureFlag('core_governance'), {
      wrapper: wrapperWithFlags({ core_governance: true }),
    })

    expect(result.current.enabled).toBe(true)
    expect(result.current.isEnabled).toBe(true)
    expect(result.current.isLoading).toBe(false)
    expect(result.current.error).toBeNull()
  })

  it('evaluates disabled flags correctly as false', () => {
    const { result } = renderHook(() => useFeatureFlag('demos_fleet'), {
      wrapper: wrapperWithFlags({ demos_fleet: false }),
    })

    expect(result.current.enabled).toBe(false)
    expect(result.current.isEnabled).toBe(false)
    expect(result.current.isLoading).toBe(false)
  })

  it('uses defaultValue for unknown flag keys', () => {
    const { result: defaultFalse } = renderHook(
      () => useFeatureFlag('unknown_flag', false),
      {
        wrapper: wrapperWithFlags({}),
      },
    )
    expect(defaultFalse.current.enabled).toBe(false)

    const { result: defaultTrue } = renderHook(
      () => useFeatureFlag('unknown_flag_2', true),
      {
        wrapper: wrapperWithFlags({}),
      },
    )
    expect(defaultTrue.current.enabled).toBe(true)
  })

  it('supports tuple destructuring [enabled, isLoading]', () => {
    const { result } = renderHook(() => useFeatureFlag('audit'), {
      wrapper: wrapperWithFlags({ audit: true }),
    })

    const [enabled, isLoading] = result.current
    expect(enabled).toBe(true)
    expect(isLoading).toBe(false)
  })

  it('reacts dynamically to flag updates', () => {
    function HookConsumer() {
      const flag = useFeatureFlag('demos_fleet')
      const ctx = useFeatureFlagContext()
      return { flag, ctx }
    }

    const { result } = renderHook(() => HookConsumer(), {
      wrapper: ({ children }) => (
        <FeatureFlagProvider
          initialFlags={{ demos_fleet: false }}
          disableAutoFetch={true}
        >
          {children}
        </FeatureFlagProvider>
      ),
    })

    expect(result.current.flag.enabled).toBe(false)

    act(() => {
      result.current.ctx.setFlagOverride('demos_fleet', true)
    })

    expect(result.current.flag.enabled).toBe(true)
  })

  it('executes safely when rendered outside FeatureFlagProvider', () => {
    // Falls back to system defaults without throwing
    const { result } = renderHook(() => useFeatureFlag('core_governance'))

    expect(result.current.enabled).toBe(true)
    expect(result.current.error).toBeNull()
  })
})
