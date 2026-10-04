// Superadmin visibility mode.
//
// The server decides. `GET /api/v1/me` reports the same verdict
// `require_superadmin` applies, computed from the validated token against the
// API_SUPERADMIN_EMAILS / API_SUPERADMIN_SUBJECTS allow-lists, and
// useServerSuperadmin() below follows it.
//
// isSuperadminEligible() remains as the PRE-FLIGHT answer only: it matches the
// demo user's OIDC claims in the browser, which is what this file did
// exclusively before, and is used for the first render while /api/v1/me is in
// flight. It is not authority. Once the allow-lists name anyone other than the
// demo user, the name match and the server disagree, and the server wins.
//
// Superadmin here is still a VISIBILITY control: it decides which links the
// sidebar renders and which routes redirect. Every mutating capability is gated
// again server-side (superadmin.py require_superadmin, /api/v1/auth/check in
// front of /fleet-api/, and the operator proxy in fleet_operator.py), so a
// client that lied to itself about this flag gains nothing.

import { useCallback, useEffect, useState } from 'react'

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

/** What `GET /api/v1/me` answers. */
export interface MeResponse {
  subject: string
  tenant: string
  email: string | null
  superadmin: boolean
}

export async function fetchMe(token: string): Promise<MeResponse> {
  const res = await fetch('/api/v1/me', {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  })
  if (!res.ok) throw new Error(`/api/v1/me ${res.status}`)
  return (await res.json()) as MeResponse
}

/**
 * The server's superadmin verdict, with the client-side name match as the
 * pre-flight answer only.
 *
 * `resolved` says which of the two is being reported, so a caller that must not
 * act on a guess can wait. A failed request does NOT promote: it leaves the
 * pre-flight answer in place and leaves `resolved` false, because an
 * unreachable identity route is not evidence of elevation.
 */
export function useServerSuperadmin(
  user: Record<string, unknown> | null | undefined,
  getToken: (() => Promise<string>) | null | undefined,
): { superadmin: boolean; resolved: boolean } {
  const preflight = isSuperadminEligible(user)
  const [server, setServer] = useState<boolean | null>(null)

  useEffect(() => {
    if (!getToken) {
      setServer(null)
      return
    }
    let live = true
    Promise.resolve()
      .then(() => getToken())
      .then((token) => (token ? fetchMe(token) : null))
      .then((me) => {
        if (live) setServer(me ? me.superadmin === true : null)
      })
      .catch(() => {
        if (live) setServer(null)
      })
    return () => {
      live = false
    }
  }, [getToken])

  return server === null
    ? { superadmin: preflight, resolved: false }
    : { superadmin: server, resolved: true }
}

export function readSuperadmin(): boolean {
  try {
    return localStorage.getItem(SUPERADMIN_STORAGE_KEY) === 'true'
  } catch {
    // Storage unavailable (private mode, some test runners): default off.
    return false
  }
}

export function writeSuperadmin(on: boolean): void {
  try {
    localStorage.setItem(SUPERADMIN_STORAGE_KEY, on ? 'true' : 'false')
  } catch {
    /* ignore: storage unavailable; the in-memory React state still holds */
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
