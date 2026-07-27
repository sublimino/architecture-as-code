import { useState, useEffect, useRef, useCallback } from 'react'

const REFRESH_MS = 15 * 60 * 1000
const RETRY_MS = 60 * 1000

export interface AutoRefreshState {
  lastUpdated: Date | null
  isRefreshing: boolean
  error: string | null
}

export function useAutoRefresh(
  refresh: () => Promise<void>,
  intervalMs = REFRESH_MS,
): AutoRefreshState {
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null)
  const [isRefreshing, setIsRefreshing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const retryRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const refreshRef = useRef(refresh)
  refreshRef.current = refresh

  const run = useCallback(async () => {
    setIsRefreshing(true)
    try {
      await refreshRef.current()
      setLastUpdated(new Date())
      setError(null)
      if (retryRef.current) {
        clearTimeout(retryRef.current)
        retryRef.current = null
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Refresh failed')
      if (!retryRef.current) {
        retryRef.current = setTimeout(() => {
          retryRef.current = null
          run()
        }, RETRY_MS)
      }
    } finally {
      setIsRefreshing(false)
    }
  }, [])

  useEffect(() => {
    const t = setInterval(run, intervalMs)
    return () => {
      clearInterval(t)
      if (retryRef.current) clearTimeout(retryRef.current)
    }
  }, [run, intervalMs])

  return { lastUpdated, isRefreshing, error }
}

export function useLastUpdatedText(lastUpdated: Date | null, error: string | null): string {
  const [, setTick] = useState(0)

  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 30_000)
    return () => clearInterval(t)
  }, [])

  if (error) return 'Last refresh failed — retrying in 1 min'
  if (!lastUpdated) return 'Auto-refreshes every 15 min'

  const diffMin = Math.floor((Date.now() - lastUpdated.getTime()) / 60_000)
  if (diffMin === 0) return 'Updated just now · Auto-refreshes every 15 min'
  return `Updated ${diffMin} min ago · Auto-refreshes every 15 min`
}
