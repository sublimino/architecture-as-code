// Recover from stale route chunks after a deploy.
//
// A tab opened before a deploy asks for chunk hashes that no longer exist.
// Vite reports every such failure (preload and the dynamic import itself, see
// __vitePreload) as one `vite:preloadError` event, so one listener covers it.
//
// The rule: reload once per browser session, and only while online. After
// that one attempt, or while offline, do nothing, so the import error reaches
// the route's error boundary instead of looping through reloads.

export const STALE_CHUNK_RELOAD_KEY = 'sl_stale_chunk_reload_at'

export function installStaleChunkReload(win: Window, now: () => number = Date.now): void {
  win.addEventListener('vite:preloadError', (event) => {
    if (!win.navigator.onLine) return
    try {
      if (win.sessionStorage.getItem(STALE_CHUNK_RELOAD_KEY) !== null) return
      win.sessionStorage.setItem(STALE_CHUNK_RELOAD_KEY, String(now()))
    } catch {
      // No storage means no way to bound the reloads: let the error surface.
      return
    }
    event.preventDefault()
    win.location.reload()
  })
}
