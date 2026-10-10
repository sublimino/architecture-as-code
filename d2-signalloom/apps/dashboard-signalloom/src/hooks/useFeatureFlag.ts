import { useContext, useMemo } from 'react'
import { useBooleanFlagValue } from '@openfeature/react-sdk'
import { FeatureFlagContext } from '../providers/FeatureFlagProvider'
import { DEFAULT_SYSTEM_FLAGS } from '../types/features'

export interface UseFeatureFlagResult {
  isEnabled: boolean
  enabled: boolean
  isLoading: boolean
  error: Error | null
  [Symbol.iterator](): Iterator<boolean>
}

/**
 * useFeatureFlag
 *
 * Hook for evaluating feature flags with OpenFeature React SDK.
 * Returns reactive boolean evaluation along with loading and error states.
 *
 * Usage examples:
 *   const { isEnabled, isLoading } = useFeatureFlag('demos_fleet')
 *   const [enabled, loading] = useFeatureFlag('supercred')
 *   const { enabled } = useFeatureFlag('audit', true)
 */
export function useFeatureFlag(
  flagKey: string,
  defaultValue = false,
): UseFeatureFlagResult {
  const ctx = useContext(FeatureFlagContext)

  // Determine fallback default value
  const systemDefault =
    flagKey in DEFAULT_SYSTEM_FLAGS ? DEFAULT_SYSTEM_FLAGS[flagKey] : defaultValue

  // Read evaluation from OpenFeature React SDK to maintain subscription to events
  let sdkValue: boolean | null = null
  let sdkError: Error | null = null

  try {
    sdkValue = useBooleanFlagValue(flagKey, systemDefault)
  } catch (err) {
    sdkError = err instanceof Error ? err : new Error(String(err))
    sdkValue = null
  }

  // Authoritative resolution:
  // When wrapped in FeatureFlagProvider, context provides instantaneous, layout-stable flags
  // while OpenFeature event subscriptions ensure reactive updates across the component tree.
  let enabled = systemDefault
  if (ctx && flagKey in ctx.flags) {
    enabled = Boolean(ctx.flags[flagKey])
  } else if (sdkValue !== null) {
    enabled = Boolean(sdkValue)
  }

  const isLoading = ctx ? ctx.isLoading : false
  const error = ctx ? ctx.error : sdkError

  return useMemo<UseFeatureFlagResult>(() => {
    return {
      isEnabled: enabled,
      enabled,
      isLoading,
      error,
      *[Symbol.iterator]() {
        yield enabled
        yield isLoading
      },
    }
  }, [enabled, isLoading, error])
}
