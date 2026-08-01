// Test-only Storage shim.
//
// Node 25 ships a built-in `localStorage` global (the experimental Web Storage
// API). It is installed before the jsdom test environment runs, shadows jsdom's
// own `window.localStorage`, and is inert without `--localstorage-file` — it has
// no getItem/setItem/clear at all. Any test that exercises localStorage-backed
// state therefore has to install a working Storage first.
//
// Call installMemoryStorage() in beforeEach; each call also gives the test a
// clean, empty store.

class MemoryStorage implements Storage {
  private store = new Map<string, string>()

  get length(): number {
    return this.store.size
  }

  clear(): void {
    this.store.clear()
  }

  getItem(key: string): string | null {
    return this.store.has(key) ? (this.store.get(key) as string) : null
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null
  }

  removeItem(key: string): void {
    this.store.delete(key)
  }

  setItem(key: string, value: string): void {
    this.store.set(key, String(value))
  }
}

export function installMemoryStorage(): Storage {
  const storage = new MemoryStorage()
  const descriptor: PropertyDescriptor = {
    value: storage,
    writable: true,
    configurable: true,
    enumerable: true,
  }
  Object.defineProperty(globalThis, 'localStorage', descriptor)
  if (typeof window !== 'undefined' && (window as unknown) !== (globalThis as unknown)) {
    Object.defineProperty(window, 'localStorage', descriptor)
  }
  return storage
}
