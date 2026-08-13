/**
 * The one boundary the cluster-free harness is allowed to replace.
 *
 * SuperCredInstructorPanel pulls exactly one thing out of the auth module —
 * `getAccessTokenSilently` — and puts the result in an `Authorization` header.
 * The real implementation is react-oidc-context talking to Dex, which needs a
 * cluster, an issuer, a redirect and a browser session; none of that has any
 * bearing on whether a log streams.
 *
 * Everything ELSE in the harness is the real thing: the real
 * SuperCredInstructorPanel, the real StreamingLogBlock, the real
 * api/demoRunner.ts client, the real poll loop, the real offset bookkeeping and
 * the real theme tokens. Stubbing the panel or the log block would make the
 * harness prove nothing — it would be testing a copy of the code that broke.
 *
 * server.ts ignores the token's value; it exists so the request the panel sends
 * is the request it really sends.
 */
/**
 * ─── The identity trap, and why this is a module constant ──────────────────
 *
 * SuperCredInstructorPanel's boot effect lists `getAccessTokenSilently` in its
 * dependency array, and so — transitively, via loadStatus and finishRun — does
 * its 500ms poll effect. That is correct code against the real hook, because
 * react-oidc-context hands back a memoised context value whose function
 * identity is stable across renders.
 *
 * A stub that returns a fresh object literal is NOT stable, and the result is
 * spectacular: every render re-runs the boot effect, which re-fetches /steps
 * and /status, which sets state, which renders — an unbounded request loop that
 * also tears down and re-arms the poll interval before its 500ms can elapse, so
 * the run's status is never re-read and the panel sits on `running` forever.
 *
 * Observed exactly that while building this harness: hundreds of
 * GET /demo-api/steps in a few seconds and a phase that never finished. It
 * presented as "the harness server is broken" — the server was fine.
 *
 * So the value is created ONCE, here, at module scope. Frozen, so a future
 * edit cannot reintroduce per-render mutation by accident.
 */
const AUTH = Object.freeze({
  getAccessTokenSilently: async (): Promise<string> => 'harness-token',
  loginWithRedirect: async (): Promise<void> => {},
  isAuthenticated: true,
})

export function useAuth0() {
  return AUTH
}
