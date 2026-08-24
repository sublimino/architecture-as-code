// How a demo run is PRESENTED — shared by every panel that drives the demo
// runner.
//
// These four rules were private to SuperCredInstructorPanel. Signal Fusion
// needs all four, and the honest alternative to extracting them was a second
// copy in SignalFusionPage: two status-colour maps, two tail windows, two
// opinions about what a 401 from the runner means. Both panels talk to the SAME
// runner through the same shapes (`DemoRunView`, `DemoRunnerStatus`), so a
// divergence here is not a difference of style — it is one demo telling the
// instructor the run timed out in amber while the other calls the same run red.
//
// Presentation only. Nothing here fetches, polls or decides; the transport
// lives in api/demoRunner.ts and the effect machinery lives in the panels,
// which is why this module is a plain .ts with its own unit test rather than
// something reachable only by rendering a component.

import { colors } from '../styles/tokens'
import { stripAnsi } from './StreamingLogBlock'
import type { DemoRunView } from '../api/demoRunner'

/**
 * The colour each terminal state is painted in.
 *
 * `timed_out` and `cancelled` are amber rather than red on purpose: neither is
 * a script failure, and painting them red sends an instructor hunting for a
 * defect in a demo that was simply interrupted. Neither is teal either — a run
 * that stopped early did not do what it said it would.
 *
 * Every value is a `var(--token)`: src/styles/cssVarUsage.test.ts rejects bare
 * hex in inline styles, and a hex would be wrong in two of the three themes.
 */
export const RUN_STATUS_COLORS: Record<string, string> = {
  running: colors.cyanLoom,
  succeeded: colors.tealLoom,
  failed: colors.red,
  timed_out: colors.amber,
  cancelled: colors.amber,
}

/**
 * The colour for a status word, muted when the status is unknown or absent.
 *
 * Muted is the only honest answer for a state this build has never heard of:
 * it says "no opinion" rather than claiming the run passed or failed. Callers
 * that need a different fallback (a BORDER, where muted is too loud) read
 * `RUN_STATUS_COLORS` directly.
 */
export function runStatusTone(status: string | undefined | null): string {
  return (status && RUN_STATUS_COLORS[status]) || 'var(--muted)'
}

/**
 * When a run began, in epoch ms, or undefined if the runner did not say.
 *
 * Read from the runner's own stamp rather than from a component's mount, so a
 * run adopted from another browser — or from before this page load, which is
 * routine when the instructor refreshes mid-act — shows its true age instead of
 * restarting the clock at zero and understating how long the audience has been
 * waiting.
 *
 * Undefined rather than `Date.now()` for an unusable stamp: PixelLoader reads
 * undefined as "start at mount", which understates the age but invents nothing.
 * Passing `NaN` through would render "NaNs" on stage.
 */
export function runStartedAt(run: DemoRunView | null | undefined): number | undefined {
  if (!run?.started_at) return undefined
  const ms = Date.parse(run.started_at)
  return Number.isNaN(ms) ? undefined : ms
}

/** Lines of output kept on screen when a run fails. */
export const LOG_TAIL_LINES = 12

/**
 * The last few meaningful lines of a log — the ones that explain a failure.
 *
 * `stripAnsi` is imported from the streaming block rather than re-implemented,
 * because two copies of that regex is two places for the runner's colour
 * convention to drift out of agreement with the display. Blank lines are
 * dropped before the window is applied: they are the runner's spacing, and
 * spending a twelve-line budget on them is how a failure shows four lines.
 */
export function logTail(log: string, maxLines: number = LOG_TAIL_LINES): string {
  return stripAnsi(log)
    .split('\n')
    .filter(line => line.trim() !== '')
    .slice(-maxLines)
    .join('\n')
}

/**
 * What a failed runner call actually means, in the instructor's terms.
 *
 * A failed status call has three very different causes, and reporting all of
 * them as "not reachable" sends the instructor to debug the network when the
 * actual answer is "sign in again".
 *
 * The 401 case is not hypothetical and not rare. Dex runs `storage: memory`, so
 * it regenerates its signing keys on every restart — and it restarts whenever
 * the published origin changes, which is exactly what `make public` does. Any
 * browser tab open across that boundary holds a token signed by keys that no
 * longer exist, so the API rejects it. The demo runner is perfectly healthy;
 * the session is stale. Telling the instructor it is "not reachable" during a
 * live demo is the worst possible moment to be wrong about which.
 *
 * The status codes are matched on word boundaries so "1401" and "4030" — a
 * port, an upstream code, a byte count — cannot route to the wrong advice.
 */
export function describeRunnerError(runnerError: string): string {
  if (/\b401\b|invalid_token|token is invalid/i.test(runnerError)) {
    return 'Your session is no longer valid, so the demo runner rejected the request '
      + '(the demo runner itself is fine). This happens when Dex restarts — publishing '
      + 'or tearing down a public URL does exactly that. Sign out and back in, then retry.'
  }
  if (/\b403\b|superadmin_required|forbidden/i.test(runnerError)) {
    return 'You are signed in, but this account is not a superadmin, so the run controls '
      + 'are refused by the server.'
  }
  return `The demo runner is not reachable (${runnerError}).`
}
