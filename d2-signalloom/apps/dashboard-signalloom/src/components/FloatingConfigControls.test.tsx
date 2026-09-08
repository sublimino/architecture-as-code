import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import FloatingConfigControls, {
  CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY,
} from './FloatingConfigControls'

function installLocalStorage(): Storage {
  const store = new Map<string, string>()
  const mock: Storage = {
    getItem: (key) => (store.has(key) ? (store.get(key) as string) : null),
    setItem: (key, value) => void store.set(key, String(value)),
    removeItem: (key) => void store.delete(key),
    clear: () => store.clear(),
    key: (index) => Array.from(store.keys())[index] ?? null,
    get length() {
      return store.size
    },
  }
  Object.defineProperty(window, 'localStorage', { value: mock, configurable: true, writable: true })
  return mock
}

let localStorageMock: Storage

beforeEach(() => {
  localStorageMock = installLocalStorage()
})

afterEach(() => {
  cleanup()
})

describe('FloatingConfigControls', () => {
  it('renders expanded by default with all configuration options and collapse button', () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    expect(screen.getByTestId('width-toggle')).toBeInTheDocument()
    expect(screen.getByTestId('theme-toggle')).toBeInTheDocument()
    // Collapse toggle button is present
    const toggleBtn = screen.getByTestId('config-collapse-toggle')
    expect(toggleBtn).toBeInTheDocument()
    expect(toggleBtn).toHaveTextContent('Hide')
    expect(toggleBtn.getAttribute('aria-expanded')).toBe('true')
  })

  it('collapses all configuration options on click and updates localStorage', () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const toggleBtn = screen.getByTestId('config-collapse-toggle')
    fireEvent.click(toggleBtn)

    // Toggles should now be unmounted
    expect(screen.queryByTestId('width-toggle')).not.toBeInTheDocument()
    expect(screen.queryByTestId('theme-toggle')).not.toBeInTheDocument()

    // Collapse toggle button now shows collapsed state
    const collapsedBtn = screen.getByTestId('config-collapse-toggle')
    expect(collapsedBtn).toHaveTextContent('Config')
    expect(collapsedBtn.getAttribute('aria-expanded')).toBe('false')
    expect(collapsedBtn.style.right).toBe('16px')
    expect(localStorageMock.getItem(CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY)).toBe('true')
  })

  it('expands options when clicked in collapsed state', () => {
    localStorageMock.setItem(CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY, 'true')

    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const collapsedBtn = screen.getByTestId('config-collapse-toggle')
    expect(collapsedBtn).toHaveTextContent('Config')
    expect(screen.queryByTestId('width-toggle')).not.toBeInTheDocument()

    // Expand
    fireEvent.click(collapsedBtn)

    expect(screen.getByTestId('width-toggle')).toBeInTheDocument()
    expect(screen.getByTestId('theme-toggle')).toBeInTheDocument()
    expect(screen.getByTestId('config-collapse-toggle')).toHaveTextContent('Hide')
    expect(localStorageMock.getItem(CONFIG_CONTROLS_COLLAPSED_STORAGE_KEY)).toBe('false')
  })

  it('docks at bottom: 70px when drawer is active in URL query params', () => {
    render(
      <MemoryRouter initialEntries={['/agents?drawer=agent-sir-lancelot']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const toggleBtn = screen.getByTestId('config-collapse-toggle')
    expect(toggleBtn.style.bottom).toBe('70px')
    const widthToggle = screen.getByTestId('width-toggle')
    expect(widthToggle.style.bottom).toBe('70px')
  })

  it('docks at bottom: 16px when no drawer is present', () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const toggleBtn = screen.getByTestId('config-collapse-toggle')
    expect(toggleBtn.style.bottom).toBe('16px')
    const widthToggle = screen.getByTestId('width-toggle')
    expect(widthToggle.style.bottom).toBe('16px')
  })
})
