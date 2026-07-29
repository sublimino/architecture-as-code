// Runtime demo-data mode.
//
// When ON, the api client (client.ts) short-circuits to local fixtures instead
// of issuing HTTP calls, so every screen renders even while the backend API is
// still in development. Backed by localStorage so a single build demos both
// modes; the corner DemoToggle widget flips it.
//
// This mirrors the build-time VITE_CONNECTORS_API_MODE mock/live pattern in
// connectorsClient.ts, but as a RUNTIME toggle so no rebuild is needed.

const KEY = 'sl_demo_mode'

// SL_ENV controls the estate-wide environment tier. In demo mode, the toggle
// defaults ON so every screen renders immediately with fixture data. In
// ci/uat/prod the toggle is hidden and demo mode is always off.
const SL_ENV = ((import.meta.env.VITE_SL_ENV as string) ?? 'demo').toLowerCase()
export const isProductionEnv = ['uat', 'prod'].includes(SL_ENV)
export const showDemoToggle = ['demo', 'dev'].includes(SL_ENV)

type Listener = (on: boolean) => void
const listeners = new Set<Listener>()

// In-memory source of truth, seeded from localStorage on load and synced back
// best-effort. Keeping the live value in memory means the toggle works even
// where localStorage is unavailable (SSR, some test runners) — localStorage is
// only for persistence across a reload.
function readPersisted(): boolean {
  // In production environments, demo mode is always off regardless of localStorage.
  if (isProductionEnv) return false
  try {
    const stored = localStorage.getItem(KEY)
    // If never toggled and SL_ENV is 'demo', default ON so the UI renders immediately.
    if (stored === null) return SL_ENV === 'demo'
    return stored === 'true'
  } catch {
    return SL_ENV === 'demo'
  }
}

let current = readPersisted()

export function isDemoMode(): boolean {
  return current
}

export function setDemoMode(on: boolean): void {
  current = on
  try {
    localStorage.setItem(KEY, on ? 'true' : 'false')
  } catch {
    /* ignore — storage unavailable; in-memory value still holds */
  }
  listeners.forEach((l) => l(on))
}

export function toggleDemoMode(): boolean {
  const next = !isDemoMode()
  setDemoMode(next)
  return next
}

export function subscribeDemoMode(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
