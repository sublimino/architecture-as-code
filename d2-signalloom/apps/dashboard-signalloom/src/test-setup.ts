import '@testing-library/jest-dom'
import { beforeEach, vi } from 'vitest'
import { resetFakeData } from './api/fakeData'

// jsdom implements no layout engine and none of the observer APIs that a
// canvas-style graph library needs to size itself. React Flow (Agent Trust
// Topology) constructs a ResizeObserver on mount and reads DOMMatrix while
// projecting the viewport; without these it throws before rendering a single
// node. These are the stubs React Flow's own testing guide prescribes.
//
// Everything they stub is measurement, not behaviour: the components still
// mount, render their real DOM, and respond to real events. What tests cannot
// assert under them is anything derived from element geometry — which is why
// the topology's layout maths lives in trustGeometry.ts as pure functions and
// is tested directly there rather than through the renderer.
class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}

if (!globalThis.ResizeObserver) {
  globalThis.ResizeObserver = ResizeObserverStub as unknown as typeof ResizeObserver
}

if (!globalThis.DOMMatrixReadOnly) {
  class DOMMatrixReadOnlyStub {
    m22 = 1
  }
  globalThis.DOMMatrixReadOnly = DOMMatrixReadOnlyStub as unknown as typeof DOMMatrixReadOnly
}

// React Flow measures every node once on mount and hides anything it measures
// as zero-sized. jsdom reports zero for everything, so without this the nodes
// render into the DOM and are then marked invisible, and no query can see them.
if (!Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight')?.get) {
  Object.defineProperties(HTMLElement.prototype, {
    offsetHeight: { get() { return parseFloat(this.style.height) || 48 } },
    offsetWidth: { get() { return parseFloat(this.style.width) || 156 } },
  })
}

if (!globalThis.matchMedia) {
  globalThis.matchMedia = ((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })) as unknown as typeof globalThis.matchMedia
}

beforeEach(() => {
  resetFakeData()
})
