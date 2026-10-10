import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { OpenFeature, type Client } from '@openfeature/web-sdk'
import { OpenFeatureProvider as OpenFeatureSDKProvider } from '@openfeature/react-sdk'
import { SignalLoomFeatureProvider } from './SignalLoomFeatureProvider'
import { fetchFeatures } from '../api/featuresApi'
import {
  DEFAULT_SYSTEM_FLAGS,
  type FeatureFlagDetail,
  type FeaturesResponse,
} from '../types/features'
import { getTenantIdFromToken } from '../auth/tenant'
import { useAuth0 } from '../auth/oidc'

// ─── Types & Context ────────────────────────────────────────────────────────

export interface FeatureFlagContextValue {
  flags: Record<string, boolean>
  details: Record<string, FeatureFlagDetail>
  isLoading: boolean
  isFetching: boolean
  error: Error | null
  tenantId: string | null
  refetch: () => Promise<void>
  setFlagOverride: (flagKey: string, value: boolean) => void
  isReady: boolean
}

const DEFAULT_DETAILS: Record<string, FeatureFlagDetail> = Object.fromEntries(
  Object.entries(DEFAULT_SYSTEM_FLAGS).map(([key, enabled]) => [
    key,
    { enabled, config: {} },
  ]),
)

export const FeatureFlagContext = createContext<FeatureFlagContextValue>({
  flags: { ...DEFAULT_SYSTEM_FLAGS },
  details: { ...DEFAULT_DETAILS },
  isLoading: false,
  isFetching: false,
  error: null,
  tenantId: null,
  refetch: async () => {},
  setFlagOverride: () => {},
  isReady: true,
})

export function useFeatureFlagContext(): FeatureFlagContextValue {
  return useContext(FeatureFlagContext)
}

// ─── Cache Layer (60-second stale time) ─────────────────────────────────────

interface CacheEntry {
  response: FeaturesResponse
  timestamp: number
}

const flagCache = new Map<string, CacheEntry>()
export const DEFAULT_STALE_TIME_MS = 60_000 // 60 seconds

export function clearFeatureFlagCache(tenantId?: string): void {
  if (tenantId) {
    flagCache.delete(tenantId)
  } else {
    flagCache.clear()
  }
}

// ─── Provider Props ─────────────────────────────────────────────────────────

export interface FeatureFlagProviderProps {
  children: ReactNode
  initialFlags?: Record<string, boolean>
  tenantId?: string | null
  staleTimeMs?: number
  disableAutoFetch?: boolean
  customProvider?: SignalLoomFeatureProvider
  client?: Client
}

/**
 * FeatureFlagProvider
 *
 * Integrates OpenFeature with Signal Loom. Fetches tenant-scoped feature flags from
 * /api/v1/features on mount and on tenant switch, caches evaluation with a 60-second
 * stale time, and provides OpenFeature react-sdk context to all descendant components.
 */
export function FeatureFlagProvider({
  children,
  initialFlags,
  tenantId: explicitTenantId,
  staleTimeMs = DEFAULT_STALE_TIME_MS,
  disableAutoFetch = false,
  customProvider,
  client: explicitClient,
}: FeatureFlagProviderProps): React.JSX.Element {
  // Safe auth resolution (works whether AuthProvider is present or in headless tests)
  let auth: ReturnType<typeof useAuth0> | null = null
  try {
    auth = useAuth0()
  } catch {
    auth = null
  }

  const [token, setToken] = useState<string | null>(null)
  const [inferredTenantId, setInferredTenantId] = useState<string | null>(null)

  // Initialize custom OpenFeature Web provider instance
  const providerRef = useRef<SignalLoomFeatureProvider>(
    customProvider ?? new SignalLoomFeatureProvider(initialFlags),
  )
  const provider = providerRef.current

  // Bind provider to OpenFeature client
  const clientRef = useRef<Client>(
    explicitClient ??
      (() => {
        OpenFeature.setProvider(provider)
        return OpenFeature.getClient()
      })(),
  )
  const client = clientRef.current

  const [flags, setFlags] = useState<Record<string, boolean>>({
    ...DEFAULT_SYSTEM_FLAGS,
    ...(initialFlags ?? {}),
  })
  const [details, setDetails] = useState<Record<string, FeatureFlagDetail>>({
    ...DEFAULT_DETAILS,
  })
  const [isLoading, setIsLoading] = useState<boolean>(!disableAutoFetch)
  const [isFetching, setIsFetching] = useState<boolean>(false)
  const [error, setError] = useState<Error | null>(null)
  const [isReady, setIsReady] = useState<boolean>(true)

  // Resolve token and tenant from auth only if explicitTenantId is not passed
  useEffect(() => {
    let mounted = true
    if (explicitTenantId) {
      return
    }

    if (auth?.getAccessTokenSilently) {
      auth
        .getAccessTokenSilently()
        .then((jwt) => {
          if (!mounted) return
          setToken(jwt)
          const extractedTenant = getTenantIdFromToken(jwt)
          if (extractedTenant) {
            setInferredTenantId(extractedTenant)
          }
        })
        .catch(() => {
          if (!mounted) return
          setToken(null)
        })
    }

    return () => {
      mounted = false
    }
  }, [auth, explicitTenantId])

  const targetTenant = explicitTenantId ?? inferredTenantId
  const activeTenantKey = targetTenant ?? 'default'

  // Fetch flags implementation
  const performFetch = useCallback(
    async (forceFresh = false) => {
      if (disableAutoFetch) {
        setIsLoading(false)
        return
      }

      const now = Date.now()
      const cached = flagCache.get(activeTenantKey)

      if (!forceFresh && cached && now - cached.timestamp < staleTimeMs) {
        setFlags(cached.response.flags)
        if (cached.response.details) {
          setDetails(cached.response.details)
        }
        provider.setFlags(cached.response.flags)
        setIsLoading(false)
        return
      }

      setIsFetching(true)
      try {
        const data = await fetchFeatures(token, targetTenant)
        if (data.tenant_id !== 'fallback') {
          flagCache.set(activeTenantKey, {
            response: data,
            timestamp: Date.now(),
          })
        }

        setFlags(data.flags)
        if (data.details) {
          setDetails(data.details)
        }
        provider.setFlags(data.flags)
        setError(null)
        setIsReady(true)
      } catch (err) {
        const errorObj = err instanceof Error ? err : new Error(String(err))
        setError(errorObj)
        provider.setError(errorObj.message)
        // Fall back gracefully to system defaults without breaking UI
        provider.setFlags(DEFAULT_SYSTEM_FLAGS)
      } finally {
        setIsLoading(false)
        setIsFetching(false)
      }
    },
    [activeTenantKey, disableAutoFetch, provider, staleTimeMs, targetTenant, token],
  )

  // Fetch on mount or when active tenant / token changes
  useEffect(() => {
    let mounted = true
    if (disableAutoFetch) {
      setIsLoading(false)
      return
    }

    // If authenticated via Auth0 but token is still resolving, defer fetch
    if (auth?.isAuthenticated && !token) {
      return
    }

    setIsLoading(true)

    performFetch(Boolean(token)).finally(() => {
      if (mounted) {
        setIsLoading(false)
      }
    })

    return () => {
      mounted = false
    }
  }, [auth?.isAuthenticated, disableAutoFetch, performFetch, token])

  const refetch = useCallback(async () => {
    await performFetch(true)
  }, [performFetch])

  const setFlagOverride = useCallback(
    (flagKey: string, value: boolean) => {
      setFlags((prev) => {
        const next = { ...prev, [flagKey]: value }
        provider.setFlags(next)
        return next
      })
    },
    [provider],
  )

  const contextValue = useMemo<FeatureFlagContextValue>(
    () => ({
      flags,
      details,
      isLoading,
      isFetching,
      error,
      tenantId: targetTenant,
      refetch,
      setFlagOverride,
      isReady,
    }),
    [
      flags,
      details,
      isLoading,
      isFetching,
      error,
      targetTenant,
      refetch,
      setFlagOverride,
      isReady,
    ],
  )

  return (
    <FeatureFlagContext.Provider value={contextValue}>
      <OpenFeatureSDKProvider client={client}>
        {children}
      </OpenFeatureSDKProvider>
    </FeatureFlagContext.Provider>
  )
}
