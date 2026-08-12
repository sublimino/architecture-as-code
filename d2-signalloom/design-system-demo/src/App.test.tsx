import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it } from 'vitest'
import App from './App'
import { PreferencesProvider } from './state/preferences'

function renderRoute(route: string) {
  return render(<MemoryRouter initialEntries={[route]} future={{ v7_startTransition: true, v7_relativeSplatPath: true }}><PreferencesProvider><App /></PreferencesProvider></MemoryRouter>)
}

describe('route shell', () => {
  afterEach(cleanup)

  it.each([
    ['/agents', 'Agent health'],
    ['/compliance', 'Controls & evidence'],
    ['/audit', 'Activity history'],
    ['/topology', 'Trust topology'],
    ['/settings', 'Workspace settings'],
  ])('renders %s as %s', async (route, heading) => {
    renderRoute(route)
    expect(await screen.findByRole('heading', { level: 1, name: heading })).toBeVisible()
  })

  it('keeps a specialist route directly reachable while hidden from navigation', async () => {
    renderRoute('/rbac-analysis')
    expect(await screen.findByRole('heading', { level: 1, name: 'Permission findings' })).toBeVisible()
    expect(screen.queryByRole('link', { name: /Permission findings/ })).not.toBeInTheDocument()
  })

  it('gives unknown routes a useful recovery destination', async () => {
    renderRoute('/outside-the-demo')
    expect(await screen.findByRole('heading', { level: 1, name: 'This path is outside the demo.' })).toBeVisible()
    expect(screen.getByRole('link', { name: 'Return to overview' })).toHaveAttribute('href', '/')
  })
})
