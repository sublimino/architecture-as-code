/**
 * The load-times preference store.
 *
 * Two properties carry most of the weight here and both are about what happens
 * when the stored value is not one of the three. The module seeds itself at
 * import time from localStorage, which is a surface nothing validates: a value
 * written by a future build, a hand-edited key, a half-cleared origin. Every
 * one of those has to land on `all`, because a fourth value would reach
 * PixelLoader as a mode no branch there accounts for.
 *
 * Seeding happens at import, so the tests that exercise it use resetModules
 * plus a dynamic import rather than calling a setter. Stubbing localStorage and
 * then reading an already-imported module would only ever test the setter.
 *
 * ONE THING TO KNOW BEFORE EDITING. This test suite installs its own
 * localStorage and does not lean on the environment's, because there is not
 * one. Under this runner `globalThis.localStorage` is a bare object with no
 * getItem, no setItem and no clear, so every call on it throws TypeError. That
 * is not a defect to route around; it is the "storage unavailable" case the
 * module is written for, arriving by default, and it is the reason the module
 * keeps an in-memory source of truth instead of reading storage on every get.
 * It also means the rest of the suite (PixelLoader, Settings, DesignSystemPage)
 * runs against a genuinely unpersisted store, which is the strictest place for
 * "absent value falls back to all" to be exercised.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  DEFAULT_LOAD_TIMES,
  LOAD_TIMES_OPTIONS,
  LOAD_TIMES_SETTINGS,
  LONG_WAIT_MS,
  getLoadTimes,
  isLoadTimesSetting,
  setLoadTimes,
  subscribeLoadTimes,
  type LoadTimesSetting,
} from './loadTimes'

const KEY = 'sl_load_times'

function swapStorage(replacement: PropertyDescriptor): () => void {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, ...replacement })
  return () => {
    if (original) Object.defineProperty(globalThis, 'localStorage', original)
    else Reflect.deleteProperty(globalThis, 'localStorage')
  }
}

/**
 * A working in-memory Storage, since the environment supplies none.
 *
 * Named `install…` rather than `use…`: eslint-plugin-react-hooks treats any
 * `useX` as a hook and rejects it inside the loops below.
 */
function installStorage(): { store: Map<string, string>; restore: () => void } {
  const store = new Map<string, string>()
  const restore = swapStorage({
    value: {
      getItem: (k: string) => (store.has(k) ? store.get(k)! : null),
      setItem: (k: string, v: string) => void store.set(k, String(v)),
      removeItem: (k: string) => void store.delete(k),
      clear: () => store.clear(),
    },
    writable: true,
  })
  return { store, restore }
}

/** Storage that is present but refuses to be touched, as in a locked-down embed. */
function breakStorage(): () => void {
  return swapStorage({
    get() {
      throw new Error('SecurityError: storage is not available in this context')
    },
  })
}

/**
 * Import a fresh copy of the module, so its import-time seed runs again
 * against whatever localStorage currently says.
 */
async function freshModule() {
  vi.resetModules()
  return import('./loadTimes')
}

describe('loadTimes — the setting itself', () => {
  let storage: ReturnType<typeof installStorage>

  beforeEach(() => {
    storage = installStorage()
    setLoadTimes(DEFAULT_LOAD_TIMES)
  })

  afterEach(() => {
    setLoadTimes(DEFAULT_LOAD_TIMES)
    storage.restore()
  })

  it('offers exactly three values', () => {
    expect([...LOAD_TIMES_SETTINGS]).toEqual(['all', 'long', 'none'])
  })

  it('defaults to all', () => {
    // Andy's requirement, and the value every fallback below converges on.
    expect(DEFAULT_LOAD_TIMES).toBe('all')
  })

  it('recognises the three values and nothing else', () => {
    for (const value of LOAD_TIMES_SETTINGS) expect(isLoadTimesSetting(value)).toBe(true)
    for (const value of ['', 'ALL', 'always', 'true', null, undefined, 0, {}]) {
      expect(isLoadTimesSetting(value)).toBe(false)
    }
  })

  it('puts the long threshold above the flow limit and well below the attention cliff', () => {
    // The number is a judgement, not an arbitrary constant, so what is pinned
    // is the reasoning: above Nielsen's 1.0s flow limit (or a brief wait
    // flashes a figure nobody wanted), and far enough under the 10s attention
    // limit that the figure is on screen while the decision to keep waiting is
    // still being made. Anything in that band is defensible; 2000 is the pick.
    expect(LONG_WAIT_MS).toBeGreaterThan(1_000)
    expect(LONG_WAIT_MS).toBeLessThan(5_000)
  })

  it('describes every value exactly once, in offer order', () => {
    // The Settings control and the design-system gallery both render this, so
    // a missing entry is a control with a blank option rather than a crash.
    expect(LOAD_TIMES_OPTIONS.map((o) => o.value)).toEqual([...LOAD_TIMES_SETTINGS])
    for (const option of LOAD_TIMES_OPTIONS) {
      expect(option.label.length).toBeGreaterThan(0)
      expect(option.hint.length).toBeGreaterThan(0)
    }
  })

  it('states the actual threshold in the copy rather than a hardcoded number', () => {
    const long = LOAD_TIMES_OPTIONS.find((o) => o.value === 'long')
    expect(long?.hint).toContain(`${(LONG_WAIT_MS / 1000).toFixed(1)} seconds`)
  })

  it('sets, reads back and persists', () => {
    setLoadTimes('long')
    expect(getLoadTimes()).toBe('long')
    expect(storage.store.get(KEY)).toBe('long')

    setLoadTimes('none')
    expect(getLoadTimes()).toBe('none')
    expect(storage.store.get(KEY)).toBe('none')
  })

  it('coerces a bad value at the setter rather than storing it', () => {
    // The call site is a <select>, whose value is a string. One bad cast there
    // must not poison the store for every later reader.
    setLoadTimes('sometimes' as LoadTimesSetting)
    expect(getLoadTimes()).toBe('all')
    expect(storage.store.get(KEY)).not.toBe('sometimes')
  })

  it('notifies subscribers with the new value', () => {
    const seen: LoadTimesSetting[] = []
    const stop = subscribeLoadTimes((s) => seen.push(s))
    setLoadTimes('none')
    setLoadTimes('long')
    stop()
    setLoadTimes('all')
    expect(seen).toEqual(['none', 'long'])
  })

  it('does not notify when the value has not actually changed', () => {
    // Every loader on the page is a subscriber. A no-op select change must not
    // re-render all of them.
    setLoadTimes('none')
    const listener = vi.fn()
    const stop = subscribeLoadTimes(listener)
    setLoadTimes('none')
    expect(listener).not.toHaveBeenCalled()
    stop()
  })
})

describe('loadTimes — seeding from storage', () => {
  let restore: (() => void) | null = null

  afterEach(() => {
    restore?.()
    restore = null
    vi.resetModules()
  })

  it('is all when nothing has ever been stored', async () => {
    ;({ restore } = installStorage())
    const mod = await freshModule()
    expect(mod.getLoadTimes()).toBe('all')
  })

  it('reads back each of the three values', async () => {
    for (const value of LOAD_TIMES_SETTINGS) {
      const storage = installStorage()
      storage.store.set(KEY, value)
      const mod = await freshModule()
      expect(mod.getLoadTimes()).toBe(value)
      storage.restore()
    }
  })

  it('falls back to all for a value it does not recognise', async () => {
    for (const junk of ['', 'ALL', 'always', 'true', '{"mode":"all"}']) {
      const storage = installStorage()
      storage.store.set(KEY, junk)
      const mod = await freshModule()
      expect(mod.getLoadTimes()).toBe('all')
      storage.restore()
    }
  })
})

describe('loadTimes — storage unavailable', () => {
  let restore: (() => void) | null = null

  afterEach(() => {
    restore?.()
    restore = null
    vi.resetModules()
  })

  it('seeds to the default instead of throwing at import', async () => {
    restore = breakStorage()
    const mod = await freshModule()
    expect(mod.getLoadTimes()).toBe('all')
  })

  it('still holds the value in memory when it cannot be written', async () => {
    // The setting has to work in a context with no storage — it just does not
    // survive a reload there. Losing the write must not lose the session.
    const mod = await freshModule()
    restore = breakStorage()
    expect(() => mod.setLoadTimes('none')).not.toThrow()
    expect(mod.getLoadTimes()).toBe('none')
  })

  it('still notifies subscribers when the write fails', async () => {
    const mod = await freshModule()
    restore = breakStorage()
    const listener = vi.fn()
    const stop = mod.subscribeLoadTimes(listener)
    mod.setLoadTimes('long')
    expect(listener).toHaveBeenCalledWith('long')
    stop()
  })
})
