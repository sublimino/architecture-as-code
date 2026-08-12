import '@testing-library/jest-dom/vitest'

const storage = new Map<string, string>()
const localStorageMock: Storage = {
  getItem: (key) => storage.get(key) ?? null,
  setItem: (key, value) => void storage.set(key, String(value)),
  removeItem: (key) => void storage.delete(key),
  clear: () => storage.clear(),
  key: (index) => Array.from(storage.keys())[index] ?? null,
  get length() { return storage.size },
}
Object.defineProperty(window, 'localStorage', { value: localStorageMock, configurable: true })

class ResizeObserverMock {
  observe() {}
  unobserve() {}
  disconnect() {}
}

Object.defineProperty(globalThis, 'ResizeObserver', { value: ResizeObserverMock, writable: true })

if (!globalThis.DOMMatrixReadOnly) {
  Object.defineProperty(globalThis, 'DOMMatrixReadOnly', {
    value: class DOMMatrixReadOnlyMock {
      m22 = 1
    },
  })
}

Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: (query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => undefined,
    removeListener: () => undefined,
    addEventListener: () => undefined,
    removeEventListener: () => undefined,
    dispatchEvent: () => false,
  }),
})
