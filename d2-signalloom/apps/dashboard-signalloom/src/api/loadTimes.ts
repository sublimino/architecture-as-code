// Runtime preference: does a loader show how long it has been waiting?
//
// Every waiting indicator in this app is a PixelLoader — directly in the
// instructor panel, and through LoadingState on twenty-odd pages. Each one
// renders three things: a cycling mark, a LABEL naming what is running, and a
// live elapsed figure. This setting governs the figure and nothing else. The
// label is never conditional. An unlabelled spinner is the failure mode the
// loader was built to escape, so "wording next to the spinner, always" is a
// product invariant rather than a default, and it is asserted in
// PixelLoader.test.tsx rather than left to this comment.
//
// Shape is deliberately the same as demoMode.ts: an in-memory source of truth
// seeded from localStorage, synced back best-effort, with a listener set so a
// change takes effect without a reload. Keeping the live value in memory means
// the setting still works where storage is unavailable (private-mode quotas,
// some test runners) — localStorage is only for persistence across a reload.
//
// One thing this deliberately does NOT copy from demoMode: its
// `isProductionEnv` override. Demo mode has to be forced off in uat/prod
// because it swaps real data for fixtures, which is a correctness and safety
// concern. This is a display preference on a figure that is already on screen
// in demo; there is nothing to protect a production tenant from, and silently
// ignoring an operator's stored choice because of the deploy tier would be a
// worse surprise than any it prevents. It applies in every environment.

import { useSyncExternalStore } from 'react'

const KEY = 'sl_load_times'

/**
 * `all`  — always show the elapsed figure.
 * `long` — show it only once the wait passes LONG_WAIT_MS.
 * `none` — never show it. The label still shows.
 */
export type LoadTimesSetting = 'all' | 'long' | 'none'

export const LOAD_TIMES_SETTINGS = ['all', 'long', 'none'] as const satisfies readonly LoadTimesSetting[]

/** Absent, unparseable, or written by an older build: fall back to this. */
export const DEFAULT_LOAD_TIMES: LoadTimesSetting = 'all'

/**
 * The boundary between "a wait" and "a wait worth reporting", in ms.
 *
 * 2000, and the number is a judgement about human attention rather than about
 * this codebase. Nielsen's response-time limits (Miller 1968, Card 1991,
 * restated in Usability Engineering 1993) are the standard three: 0.1s reads
 * as instantaneous, 1.0s is the ceiling for uninterrupted flow of thought, and
 * 10s is where attention is lost entirely. Below 1.0s the user has not
 * registered a wait at all, so a figure counting it is answering a question
 * nobody asked; a 200ms fetch that flashes "0.2s" and vanishes is pure noise,
 * and worse than noise on a page with several loaders, because the flicker
 * draws the eye to whichever one happened to be slowest.
 *
 * So the threshold has to sit above 1.0s. It should not sit far above it: the
 * value of the figure is that it distinguishes a slow step from a hung one,
 * and that judgement starts the moment the wait becomes conscious. 2.0s is one
 * full second past the flow limit — long enough that the user has certainly
 * noticed, short enough that the figure is on screen well before the 10s
 * attention cliff, with time in hand to decide whether to keep waiting.
 *
 * It is also a clean number against a loader that renders tenths: the figure
 * appears reading "2.0s" and counts up from there, rather than materialising
 * mid-decimal at some value that looks like a rounding artifact.
 *
 * Exported, and referenced everywhere the number is needed: the component that
 * enforces it, the Settings copy that explains it, the design-system specimen
 * that demonstrates it, and the tests. Change it here and all four follow.
 */
export const LONG_WAIT_MS = 2_000

/**
 * The option copy, in the order it should be offered, owned here so the
 * Settings control and the design-system gallery cannot describe the same
 * setting two different ways. `hint` explains what the value does, in one
 * line, without assuming the reader has seen the other two.
 */
export const LOAD_TIMES_OPTIONS: readonly {
  value: LoadTimesSetting
  label: string
  hint: string
}[] = [
  { value: 'all', label: 'All', hint: 'Every loader counts up, however brief the wait.' },
  {
    value: 'long',
    label: 'Long waits only',
    hint: `The figure appears once a wait passes ${(LONG_WAIT_MS / 1000).toFixed(1)} seconds, so a brief flash stays quiet.`,
  },
  { value: 'none', label: 'None', hint: 'No elapsed figure anywhere.' },
]

export function isLoadTimesSetting(value: unknown): value is LoadTimesSetting {
  return typeof value === 'string' && (LOAD_TIMES_SETTINGS as readonly string[]).includes(value)
}

type Listener = (setting: LoadTimesSetting) => void
const listeners = new Set<Listener>()

function readPersisted(): LoadTimesSetting {
  try {
    const stored = localStorage.getItem(KEY)
    // Never set, or set to something this build does not recognise. The second
    // case is the one worth handling explicitly: a value written by a future
    // build, or a hand-edited key, must not leave the loader in a fourth state
    // that no branch below accounts for.
    return isLoadTimesSetting(stored) ? stored : DEFAULT_LOAD_TIMES
  } catch {
    return DEFAULT_LOAD_TIMES
  }
}

let current = readPersisted()

export function getLoadTimes(): LoadTimesSetting {
  return current
}

export function setLoadTimes(setting: LoadTimesSetting): void {
  // Guard rather than trust: this is reached from a <select> whose value is a
  // string, and one bad cast at the call site would otherwise poison both the
  // in-memory value and the stored one.
  const next = isLoadTimesSetting(setting) ? setting : DEFAULT_LOAD_TIMES
  if (next === current) return
  current = next
  try {
    localStorage.setItem(KEY, next)
  } catch {
    /* ignore — storage unavailable; in-memory value still holds */
  }
  listeners.forEach((l) => l(next))
}

export function subscribeLoadTimes(listener: Listener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

/**
 * The setting, live.
 *
 * useSyncExternalStore rather than the `useState` + `useEffect(subscribe)` pair
 * DemoToggle uses, because this one has many more subscribers than that one
 * button: every loader on the page reads it, so the window between first render
 * and the subscribe effect is a window in which a change is silently missed by
 * whichever loaders had not mounted yet. This is the primitive React added for
 * exactly this store shape and it closes that window by construction.
 *
 * The subscribe callback has to be referentially stable or React resubscribes
 * on every render; `subscribeLoadTimes` is a module-level function, so it is.
 */
export function useLoadTimes(): LoadTimesSetting {
  return useSyncExternalStore(subscribeLoadTimes, getLoadTimes, getLoadTimes)
}
