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
  /**
   * True once the server (or its cache) has answered for the active tenant.
   * While false, `flags` are client defaults and say nothing about what the
   * tenant has enabled; with `error` set that means the fetch failed.
   */
  isResolved: boolean
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
  isResolved: true,
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
  /**
   * Delay before each retry of a failed fetch; its length is the retry count.
   * Bounded on purpose: after the last attempt the failure is surfaced as
   * `error` and the user retries from the gate's error state.
   */
  retryDelaysMs?: readonly number[]
}

export const DEFAULT_RETRY_DELAYS_MS: readonly number[] = [500, 1500]

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
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
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

  // Resolve token from auth, and infer tenant from auth only if explicitTenantId is not passed
  useEffect(() => {
    let mounted = true

    if (!auth?.isAuthenticated) {
      setToken(null)
      setInferredTenantId(null)
      return
    }

    if (auth?.getAccessTokenSilently) {
      auth
        .getAccessTokenSilently()
        .then((jwt) => {
          if (!mounted) return
          setToken(jwt)
          if (!explicitTenantId) {
            const extractedTenant = getTenantIdFromToken(jwt)
            if (extractedTenant) {
              setInferredTenantId(extractedTenant)
            }
          }
        })
        .catch(() => {
          if (!mounted) return
          setToken(null)
        })
    } else {
      setToken(null)
    }

    return () => {
      mounted = false
    }
  }, [auth?.isAuthenticated, auth?.getAccessTokenSilently, explicitTenantId])

  const targetTenant = explicitTenantId ?? inferredTenantId
  const activeTenantKey = targetTenant ?? 'default'

  // Which tenant's flags came from the server (or its cache). Until it equals
  // activeTenantKey the flags in state are client defaults, not an answer.
  const [resolvedTenantKey, setResolvedTenantKey] = useState<string | null>(null)
  const resolvedTenantKeyRef = useRef<string | null>(null)
  resolvedTenantKeyRef.current = resolvedTenantKey
  const isResolved = disableAutoFetch || resolvedTenantKey === activeTenantKey

  // Read through a ref so an inline array literal does not change
  // performFetch's identity (and re-trigger the fetch effect) on every render.
  const retryDelaysRef = useRef<readonly number[]>(retryDelaysMs)
  retryDelaysRef.current = retryDelaysMs
  const fetchGenerationRef = useRef(0)
  const mountedRef = useRef(true)
  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

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
        fetchGenerationRef.current += 1 // supersede any in-flight fetch
        setFlags(cached.response.flags)
        if (cached.response.details) {
          setDetails(cached.response.details)
        }
        provider.setFlags(cached.response.flags)
        setResolvedTenantKey(activeTenantKey)
        setError(null)
        setIsLoading(false)
        setIsFetching(false)
        return
      }

      // A newer fetch (tenant/token change, manual retry) or an unmount makes
      // this one stale: it must neither keep retrying nor write its result.
      const generation = ++fetchGenerationRef.current
      const isCurrent = () => mountedRef.current && generation === fetchGenerationRef.current

      setIsFetching(true)
      try {
        let data: FeaturesResponse | null = null
        let lastError: unknown = null
        const delays = retryDelaysRef.current
        for (let attempt = 0; attempt <= delays.length; attempt += 1) {
          if (attempt > 0) {
            await new Promise((resolve) => setTimeout(resolve, delays[attempt - 1]))
            if (!isCurrent()) return
          }
          try {
            data = await fetchFeatures(token, targetTenant)
            break
          } catch (err) {
            lastError = err
          }
        }
        if (!isCurrent()) return

        if (data) {
          // Only a real server answer is ever cached.
          flagCache.set(activeTenantKey, {
            response: data,
            timestamp: Date.now(),
          })
          setFlags(data.flags)
          if (data.details) {
            setDetails(data.details)
          }
          provider.setFlags(data.flags)
          setResolvedTenantKey(activeTenantKey)
          setError(null)
          setIsReady(true)
        } else {
          const errorObj =
            lastError instanceof Error ? lastError : new Error(String(lastError))
          setError(errorObj)
          provider.setError(errorObj.message)
          // Never resolved for this tenant: the OpenFeature provider has nothing
          // better than the system defaults. Once resolved, a failed refetch
          // keeps the last server answer rather than clobbering it.
          if (resolvedTenantKeyRef.current !== activeTenantKey) {
            provider.setFlags(DEFAULT_SYSTEM_FLAGS)
          }
        }
      } finally {
        if (isCurrent()) {
          setIsLoading(false)
          setIsFetching(false)
        }
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

    // Defer fetch while OIDC auth state is still loading
    if (auth?.isLoading) {
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
  }, [auth?.isAuthenticated, auth?.isLoading, disableAutoFetch, performFetch, token])

  const refetch = useCallback(async () => {
    // A retry from the unresolved state goes back to "resolving", so gates show
    // their loader rather than a stale error while it runs. A background
    // refetch of resolved flags leaves the page alone.
    if (!isResolved) setIsLoading(true)
    await performFetch(true)
  }, [isResolved, performFetch])

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
      isResolved,
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
      isResolved,
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
