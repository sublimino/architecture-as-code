// eslint-disable-next-line @typescript-eslint/no-require-imports
const { JSDOM } = require('jsdom') as {
  JSDOM: new (html: string, options: { url: string }) => {
    window: Record<string, unknown>
  }
}

export {}

// `bun test` does not read Vite's jsdom configuration. This preload mirrors the
// browser globals used by Vitest so the card's required direct Bun invocations
// exercise the same DOM-facing component contracts.
const dom = new JSDOM('<!doctype html><html><body></body></html>', {
  url: 'http://localhost/',
})

const browserGlobalNames = [
  'window',
  'document',
  'navigator',
  'location',
  'HTMLElement',
  'Element',
  'Node',
  'Text',
  'Event',
  'CustomEvent',
  'MouseEvent',
  'KeyboardEvent',
  'MutationObserver',
  'getComputedStyle',
] as const

for (const name of browserGlobalNames) {
  Object.defineProperty(globalThis, name, {
    configurable: true,
    writable: true,
    value: dom.window[name],
  })
}

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true
await import('./test-setup')

// Testing Library's automatic cleanup only recognizes Jest/Vitest globals.
// Bun exposes lifecycle hooks through `bun:test`, so register cleanup explicitly
// to keep a multi-file invocation from retaining the previous file's document.
const bunTestModule = 'bun:test'
const [{ afterEach }, { cleanup }] = await Promise.all([
  import(/* @vite-ignore */ bunTestModule) as Promise<{ afterEach: (callback: () => void) => void }>,
  import('@testing-library/react'),
])
afterEach(cleanup)
