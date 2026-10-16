import { describe, it, expect, vi, beforeEach } from 'vitest'
import { installStaleChunkReload, STALE_CHUNK_RELOAD_KEY } from './staleChunkReload'

function fakeWindow(online = true) {
  const target = new EventTarget()
  const store = new Map<string, string>()
  const win = {
    addEventListener: target.addEventListener.bind(target),
    dispatchEvent: target.dispatchEvent.bind(target),
    location: { reload: vi.fn() },
    navigator: { onLine: online },
    sessionStorage: {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
      removeItem: (k: string) => void store.delete(k),
    },
  }
  return { win, store }
}

function preloadError(): Event {
  return new Event('vite:preloadError', { cancelable: true })
}

function chunkRejection(): Event {
  const e = new Event('unhandledrejection')
  Object.assign(e, { reason: new Error('Failed to fetch dynamically imported module: /assets/x.js') })
  return e
}

describe('installStaleChunkReload', () => {
  let ctx: ReturnType<typeof fakeWindow>
  beforeEach(() => {
    ctx = fakeWindow()
  })

  it('reloads once on a stale chunk and swallows that one error', () => {
    installStaleChunkReload(ctx.win as unknown as Window, () => 1000)
    const e = preloadError()
    ctx.win.dispatchEvent(e)
    expect(ctx.win.location.reload).toHaveBeenCalledTimes(1)
    expect(e.defaultPrevented).toBe(true)
  })

  it('reloads at most once per error burst: one listener, one key, no stacked reloads', () => {
    installStaleChunkReload(ctx.win as unknown as Window, () => 1000)
    ctx.win.dispatchEvent(preloadError())
    ctx.win.dispatchEvent(chunkRejection())
    ctx.win.dispatchEvent(preloadError())
    expect(ctx.win.location.reload).toHaveBeenCalledTimes(1)
    expect([...ctx.store.keys()]).toEqual([STALE_CHUNK_RELOAD_KEY])
  })

  it('after one attempted reload lets the error reach the error boundary', () => {
    // Simulates the page that came back from the reload with the key still set.
    ctx.store.set(STALE_CHUNK_RELOAD_KEY, '1000')
    installStaleChunkReload(ctx.win as unknown as Window, () => 20_000)
    const e = preloadError()
    ctx.win.dispatchEvent(e)
    expect(ctx.win.location.reload).not.toHaveBeenCalled()
    expect(e.defaultPrevented).toBe(false)
  })

  it('never reloads while offline', () => {
    const offline = fakeWindow(false)
    installStaleChunkReload(offline.win as unknown as Window, () => 1000)
    const e = preloadError()
    offline.win.dispatchEvent(e)
    expect(offline.win.location.reload).not.toHaveBeenCalled()
    expect(e.defaultPrevented).toBe(false)
  })
})
