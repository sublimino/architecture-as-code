/**
 * A controllable IntersectionObserver for jsdom.
 *
 * WHY THIS EXISTS AND WHY IT THROWS. jsdom implements no IntersectionObserver
 * at all, and src/test-setup.ts does not stub one (unlike ResizeObserver,
 * which React Flow forced). Any component that guards its observer with
 * `typeof IntersectionObserver === 'undefined'` — as PageToc must, so it
 * degrades rather than crashes — will therefore take the early return under
 * test and do nothing. A scrollspy test written against that silently asserts
 * an initial state forever and passes for as long as the feature is dead.
 *
 * So `latest()` and `only()` THROW when no observer was constructed, rather
 * than returning undefined and letting the test limp on. The check "did the
 * component actually observe anything" is the load-bearing assertion here; the
 * rest is arranging what it sees.
 *
 * Nothing here simulates layout. `fire()` takes the intersection facts the
 * test wants to assert about and hands them to the callback directly, which is
 * the only honest option in an environment with no viewport and no geometry.
 */

/** The subset of IntersectionObserverEntry a scrollspy can legitimately read. */
export type ObserverRecord = { target: Element; isIntersecting: boolean }

export class MockIntersectionObserver {
  static instances: MockIntersectionObserver[] = []

  /** Every element still under observation, in the order `observe` saw them. */
  readonly targets: Element[] = []
  disconnectCount = 0

  readonly root: Element | Document | null
  readonly rootMargin: string
  readonly thresholds: readonly number[]

  private readonly callback: IntersectionObserverCallback

  constructor(callback: IntersectionObserverCallback, options?: IntersectionObserverInit) {
    this.callback = callback
    this.root = (options?.root as Element | Document | null) ?? null
    this.rootMargin = options?.rootMargin ?? '0px'
    const threshold = options?.threshold ?? 0
    this.thresholds = Array.isArray(threshold) ? threshold : [threshold]
    MockIntersectionObserver.instances.push(this)
  }

  observe(element: Element): void {
    this.targets.push(element)
  }

  unobserve(element: Element): void {
    const index = this.targets.indexOf(element)
    if (index >= 0) this.targets.splice(index, 1)
  }

  disconnect(): void {
    this.disconnectCount += 1
    this.targets.length = 0
  }

  takeRecords(): IntersectionObserverEntry[] {
    return []
  }

  /** Deliver a batch of intersection changes, exactly as the browser would. */
  fire(records: ObserverRecord[]): void {
    this.callback(records as unknown as IntersectionObserverEntry[], this as unknown as IntersectionObserver)
  }
}

export type MockObserverHandle = {
  /** The most recently constructed observer. Throws if the component built none. */
  latest(): MockIntersectionObserver
  /** The single observer, asserting there is exactly one. Throws otherwise. */
  only(): MockIntersectionObserver
  /** How many observers have been constructed since install. */
  count(): number
  restore(): void
}

export function installMockIntersectionObserver(): MockObserverHandle {
  MockIntersectionObserver.instances = []
  const key = 'IntersectionObserver'
  const had = key in globalThis
  const original = Reflect.get(globalThis, key) as unknown
  Reflect.set(globalThis, key, MockIntersectionObserver)

  return {
    latest() {
      const { instances } = MockIntersectionObserver
      if (instances.length === 0) {
        throw new Error(
          'No IntersectionObserver was constructed. The component under test either never ' +
            'mounted its scrollspy effect or took its "no IntersectionObserver" early return — ' +
            'either way the assertion that follows would have been measuring nothing.',
        )
      }
      return instances[instances.length - 1]
    },
    only() {
      const { instances } = MockIntersectionObserver
      if (instances.length !== 1) {
        throw new Error(`Expected exactly one IntersectionObserver, got ${instances.length}.`)
      }
      return instances[0]
    },
    count() {
      return MockIntersectionObserver.instances.length
    },
    restore() {
      MockIntersectionObserver.instances = []
      if (had) Reflect.set(globalThis, key, original)
      else Reflect.deleteProperty(globalThis, key)
    },
  }
}
