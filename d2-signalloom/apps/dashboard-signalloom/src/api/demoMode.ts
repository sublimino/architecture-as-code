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

type Listener = (on: boolean) => void
const listeners = new Set<Listener>()

// In-memory source of truth, seeded from localStorage on load and synced back
// best-effort. Keeping the live value in memory means the toggle works even
// where localStorage is unavailable (SSR, some test runners) — localStorage is
// only for persistence across a reload.
function readPersisted(): boolean {
  try {
    return localStorage.getItem(KEY) === 'true'
  } catch {
    return false
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
