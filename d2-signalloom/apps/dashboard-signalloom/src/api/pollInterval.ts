// Refresh cadence for the surfaces an audience watches during a live demo.
//
// The SuperCred demo is driven from one browser window while an audience
// watches a second one showing ordinary customer-facing pages. Those pages
// only tell the story if they move on their own — nobody is going to hit
// reload in front of a room.
//
// Every constant here is deliberately in ONE module because they are not
// independent: the observation TTL has to sit under the poll interval or the
// poll serves a cached answer and the audience window silently freezes. Keeping
// them apart is what let `TTL_MS = 4000` coexist with a fifteen-minute poll.

/**
 * How often the Agents and Compliance surfaces re-fetch.
 *
 * These pages shipped with `POLL_MS = 15 * 60 * 1000`. Fifteen minutes is a
 * sane cadence for a dashboard someone leaves open all day and a useless one
 * for a demo: the audience window would never visibly update inside a talk.
 *
 * 2500ms matches NetworkTestsPage, the one surface in this codebase that
 * already had to solve "show progress while something is happening".
 */
export const LIVE_POLL_MS = 2500

/**
 * How long a SuperCred observation stays fresh.
 *
 * MUST stay strictly under LIVE_POLL_MS. If the TTL is longer than the poll,
 * every other poll is answered from cache and the audience sees the agent
 * change state a beat late — or, when the two drift into phase, not at all.
 * `pollInterval.test.ts` asserts the inequality so it cannot regress silently.
 *
 * Still long enough to do its original job: a page rendering six panels fires
 * its requests within a few milliseconds of each other, and those all coalesce
 * onto one in-flight refresh rather than fanning out into six proxy calls.
 */
export const OBSERVATION_TTL_MS = 2000

/**
 * Consecutive failures before the observer assumes the proxy is simply absent.
 *
 * Outside a demo cluster /supercred-api does not exist, so a dashboard left
 * open all day must stop probing it every couple of seconds.
 */
export const OBSERVATION_FAILURE_THRESHOLD = 3

/** The longest the observer will ever wait between retries. */
export const OBSERVATION_BACKOFF_CEILING_MS = 60_000

/**
 * How long the current observation stays fresh, given the failure streak.
 *
 * This used to be a cliff: three failures and the retry interval jumped
 * straight to 60s. That is correct for "the proxy isn't there" and badly wrong
 * for "the proxy blinked" — a transient blip mid-demo froze the audience
 * window for a full minute, which is an eternity on stage.
 *
 * Backing off geometrically from the TTL instead keeps both properties. A
 * three-failure blip costs one 4s gap and recovers; a genuinely absent proxy
 * still reaches the same 60s ceiling within a few more attempts, and one
 * success resets the streak to zero.
 */
export function observationStaleAfter(consecutiveFailures: number): number {
  if (consecutiveFailures < OBSERVATION_FAILURE_THRESHOLD) return OBSERVATION_TTL_MS
  const doublings = consecutiveFailures - OBSERVATION_FAILURE_THRESHOLD + 1
  return Math.min(OBSERVATION_TTL_MS * 2 ** doublings, OBSERVATION_BACKOFF_CEILING_MS)
}
