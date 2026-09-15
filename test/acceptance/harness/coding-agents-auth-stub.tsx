// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

/**
 * The one boundary the cluster-free coding-agent harness is allowed to replace.
 *
 * CodingAgentsTab pulls exactly one thing out of the auth module —
 * `getAccessTokenSilently` — and hands the result to `api.codingAgents.list()`
 * and `.aggregate()`, which put it in an `Authorization: Bearer` header. The
 * real implementation is react-oidc-context talking to Dex, which needs a
 * cluster, an issuer, a redirect and a browser session; none of that has any
 * bearing on whether a detected agent renders.
 *
 * Everything ELSE is the shipping code: the real CodingAgentsTab, the real
 * CodingAgentCard, the real EmptyState / LoadingState, the real api/client.ts
 * including its `/api` prefixing and its in-flight GET coalescing, and the real
 * 2500ms poll from api/pollInterval.ts. Stubbing any of those would make the
 * harness prove nothing — it would be testing a copy of the code under test,
 * which is precisely what the existing vitest suite already does with
 * `vi.mock('../api/client')`.
 *
 * ─── Why the token carries a tenant ────────────────────────────────────────
 *
 * The cross-tenant isolation assertion is the whole reason this stub is not a
 * copy of harness/auth-stub.tsx. P5-1 proves tenant scoping at the API layer,
 * and an API-layer test structurally cannot see a CLIENT-side state-sharing
 * bug — a module-scope cache, a shared localStorage key, a stale `records`
 * array surviving a context switch. Proving that needs two browsers whose only
 * difference is the identity in the header, and a server that answers each one
 * differently. So the token is `harness-token:<tenant>` and the tenant comes
 * from the page URL.
 *
 * ─── The identity trap, and why this is a module constant ──────────────────
 *
 * CodingAgentsTab's `fetchTelemetry` is a `useCallback` whose dependency array
 * is `[getAccessTokenSilently]`, and its boot/poll effect depends on
 * `fetchTelemetry`. That is correct code against the real hook, because
 * react-oidc-context hands back a memoised context value whose function
 * identity is stable across renders.
 *
 * A stub that returns a fresh object literal per call is NOT stable, and the
 * result is an unbounded request loop that also tears down and re-arms the
 * 2500ms interval before it can ever elapse. harness/auth-stub.tsx records the
 * same failure being observed for real against SuperCredInstructorPanel:
 * hundreds of requests in a few seconds, presenting as "the harness server is
 * broken" when the server was fine.
 *
 * So the value is created ONCE, here, at module scope, and frozen so a future
 * edit cannot reintroduce per-render mutation by accident.
 */

/**
 * Read at module scope, not per call.
 *
 * `location.search` is fixed for the lifetime of a document, so there is
 * nothing to re-read — and reading it inside the function would not change the
 * identity problem above, it would only hide it.
 */
function tenantFromUrl(): string {
  try {
    return new URLSearchParams(window.location.search).get('tenant') ?? 'tenant-unset'
  } catch {
    return 'tenant-unset'
  }
}

const TENANT = tenantFromUrl()

/** Exported so the entry point can label the page with the identity in play. */
export const HARNESS_TENANT = TENANT

const TOKEN = `harness-token:${TENANT}`

const AUTH = Object.freeze({
  getAccessTokenSilently: async (): Promise<string> => TOKEN,
  loginWithRedirect: async (): Promise<void> => {},
  isAuthenticated: true,
})

export function useAuth0() {
  return AUTH
}
