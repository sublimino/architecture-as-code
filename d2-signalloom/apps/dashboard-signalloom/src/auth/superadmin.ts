// Superadmin visibility mode.
//
// TEMPORARY STAND-IN: the dashboard has no user-authentication table and no RBAC
// model yet, so "who may switch superadmin on" is decided here by matching the
// demo user's OIDC claims. When the user-authentication / RBAC table lands,
// replace the body of isSuperadminEligible() with the role lookup — this file is
// the single place that has to change.
//
// Superadmin is a VISIBILITY control, not an authorization control: it only
// decides which links the sidebar renders. Every route stays registered in
// App.tsx and remains reachable by direct URL.

import { useCallback, useState } from 'react'

export const SUPERADMIN_STORAGE_KEY = 'signalloom.superadmin'

const DEMO_EMAIL = 'demo-user@signalloom.local'
const DEMO_USERNAME = 'demo-user'

// The OIDC profile is a loose claim bag (oidc-client-ts IdTokenClaims), so read
// claims defensively rather than trusting the declared shape.
function claim(user: Record<string, unknown>, key: string): string | undefined {
  const value = user[key]
  return typeof value === 'string' ? value : undefined
}

export function isSuperadminEligible(user?: Record<string, unknown> | null): boolean {
  if (!user) return false
  return (
    claim(user, 'email') === DEMO_EMAIL ||
    claim(user, 'preferred_username') === DEMO_USERNAME ||
    claim(user, 'name') === DEMO_USERNAME
  )
}

export function readSuperadmin(): boolean {
  try {
    return localStorage.getItem(SUPERADMIN_STORAGE_KEY) === 'true'
  } catch {
    // Storage unavailable (private mode, some test runners) — default off.
    return false
  }
}

export function writeSuperadmin(on: boolean): void {
  try {
    localStorage.setItem(SUPERADMIN_STORAGE_KEY, on ? 'true' : 'false')
  } catch {
    /* ignore — storage unavailable; the in-memory React state still holds */
  }
}

// Superadmin state for AppContext: default OFF, seeded from localStorage on
// mount and written back on every change so it survives a reload.
export function useSuperadmin(): [boolean, (on: boolean) => void] {
  const [superadmin, setSuperadminState] = useState(readSuperadmin)
  const setSuperadmin = useCallback((on: boolean) => {
    setSuperadminState(on)
    writeSuperadmin(on)
  }, [])
  return [superadmin, setSuperadmin]
}
