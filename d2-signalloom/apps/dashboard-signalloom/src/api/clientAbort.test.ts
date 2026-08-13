/**
 * Cancellation of an in-flight request.
 *
 * Until this existed there was no way for a caller to stop a request it no
 * longer had a use for, and demo mode — the tier this product actually ships
 * in, where `isDemoMode()` defaults ON (see demoMode.ts) — settles every
 * fixture through a 120ms `setTimeout` that nothing could clear. A page that
 * unmounted inside that window left a timer holding a reference to a callback
 * that would set React state on a tree that no longer existed.
 *
 * In the browser that is a navigate-away writing to an unmounted component.
 * Under the test runner it is worse, and it is the reason this file exists: the
 * timer outlives the jsdom environment, `window` is gone by the time React's
 * `dispatchSetState` reads it, and the whole suite exits non-zero with every
 * one of its 1611 tests passing. That failure mode gates ~25 minutes of cluster
 * work in both CI lanes, so the timer being genuinely CLEARED — not merely
 * ignored when it fires — is the property under test.
 *
 * `vi.getTimerCount()` is what makes that assertable. Checking only that the
 * promise rejects would pass an implementation that abandoned the timer and let
 * it fire into nothing, which is precisely the bug.
 */
import { describe, it, expect, afterEach, vi } from 'vitest'
import { api } from './client'
import { isDemoMode } from './demoMode'

afterEach(() => {
  vi.useRealTimers()
})

describe('request cancellation', () => {
  // Guards the premise of every test below. If the default tier ever stops
  // being demo, these are asserting against the axios path instead and the
  // fixture-timer property they exist for would silently stop being covered.
  it('runs against the demo fixture path by default', () => {
    expect(isDemoMode()).toBe(true)
  })

  it('clears the fixture timer when aborted, leaving nothing to fire later', async () => {
    vi.useFakeTimers()
    const controller = new AbortController()

    const pending = api.health.crypto('test-token', controller.signal)
    expect(vi.getTimerCount()).toBe(1)

    controller.abort()
    await expect(pending).rejects.toThrow(/abort/i)

    // The point of the whole change: no timer survives the caller.
    expect(vi.getTimerCount()).toBe(0)
  })

  it('rejects a request aborted before it was ever issued', async () => {
    const controller = new AbortController()
    controller.abort()

    await expect(api.health.crypto('test-token', controller.signal)).rejects.toThrow(/abort/i)
  })

  it('names the rejection AbortError so callers can tell it from a service failure', async () => {
    const controller = new AbortController()
    const pending = api.health.crypto('test-token', controller.signal)
    controller.abort()

    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
  })

  it('still settles a request nobody aborted', async () => {
    const res = await api.health.crypto('test-token')

    expect(Array.isArray(res.proofs)).toBe(true)
  })

  it('still settles when a signal is supplied and never fired', async () => {
    const controller = new AbortController()

    const res = await api.health.crypto('test-token', controller.signal)

    expect(Array.isArray(res.proofs)).toBe(true)
    expect(controller.signal.aborted).toBe(false)
  })
})
