import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react'
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
  Object.defineProperty(window, 'innerWidth', { value: 1024, configurable: true })
  Object.defineProperty(window, 'innerHeight', { value: 768, configurable: true })
})

afterEach(() => {
  cleanup()
  document.querySelectorAll('[data-testid="qa-sidebar-footer"]').forEach((footer) => footer.parentElement?.remove())
})

describe('FloatingConfigControls', () => {
  function installSidebarFooter(top: number): HTMLElement {
    const sidebar = document.createElement('nav')
    sidebar.setAttribute('aria-label', 'Primary navigation')
    const content = document.createElement('div')
    const footer = document.createElement('div')
    footer.setAttribute('data-testid', 'qa-sidebar-footer')
    footer.getBoundingClientRect = () => ({
      x: 0,
      y: top,
      top,
      right: 268,
      bottom: window.innerHeight,
      left: 0,
      width: 268,
      height: window.innerHeight - top,
      toJSON: () => ({}),
    })
    sidebar.append(content, footer)
    document.body.appendChild(sidebar)
    return sidebar
  }

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

  it.each([320, 390])('keeps controls in one wrapping viewport-bounded toolbar at %ipx', (viewportWidth) => {
    Object.defineProperty(window, 'innerWidth', { value: viewportWidth, configurable: true })

    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const toolbar = screen.getByTestId('floating-config-controls')
    expect(toolbar.style.position).toBe('fixed')
    expect(toolbar.style.right).toBe('16px')
    expect(toolbar.style.maxWidth).toBe('calc(100vw - 32px)')
    expect(toolbar.style.display).toBe('flex')
    expect(toolbar.style.flexWrap).toBe('wrap')
    expect(toolbar.style.gap).toBe('8px')

    for (const testId of ['width-toggle', 'theme-toggle', 'demo-toggle', 'config-collapse-toggle']) {
      const control = within(toolbar).getByTestId(testId)
      expect(control).toBeEnabled()
      expect(control.style.position).toBe('static')
      expect(control.style.right).toBe('')
      expect(control.style.bottom).toBe('')
    }
  })

  it.each([
    [320, false],
    [320, true],
    [390, false],
    [390, true],
  ])('docks above the sidebar footer at %ipx when collapsed is %s', (viewportWidth, collapsed) => {
    Object.defineProperty(window, 'innerWidth', { value: viewportWidth, configurable: true })
    Object.defineProperty(window, 'innerHeight', { value: 900, configurable: true })
    installSidebarFooter(804)

    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls initialCollapsed={collapsed} />
      </MemoryRouter>
    )

    expect(screen.getByTestId('floating-config-controls').style.bottom).toBe('112px')
  })

  it('keeps the default narrow offset when no sidebar footer is present', () => {
    Object.defineProperty(window, 'innerWidth', { value: 390, configurable: true })

    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    expect(screen.getByTestId('floating-config-controls').style.bottom).toBe('16px')
  })

  it('uses the larger footer clearance when a drawer is also active', () => {
    Object.defineProperty(window, 'innerWidth', { value: 390, configurable: true })
    Object.defineProperty(window, 'innerHeight', { value: 900, configurable: true })
    installSidebarFooter(804)

    render(
      <MemoryRouter initialEntries={['/agents?drawer=agent-sir-lancelot']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    expect(screen.getByTestId('floating-config-controls').style.bottom).toBe('112px')
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
    expect(collapsedBtn.style.position).toBe('static')
    expect(screen.getByTestId('floating-config-controls').style.right).toBe('16px')
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

    const toolbar = screen.getByTestId('floating-config-controls')
    expect(toolbar.style.bottom).toBe('70px')
    const widthToggle = screen.getByTestId('width-toggle')
    expect(widthToggle.style.bottom).toBe('')
  })

  it('docks at bottom: 16px when no drawer is present', () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <FloatingConfigControls />
      </MemoryRouter>
    )

    const toolbar = screen.getByTestId('floating-config-controls')
    expect(toolbar.style.bottom).toBe('16px')
    const widthToggle = screen.getByTestId('width-toggle')
    expect(widthToggle.style.bottom).toBe('')
  })
})
