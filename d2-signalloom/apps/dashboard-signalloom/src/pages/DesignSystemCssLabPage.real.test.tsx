import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { installMemoryStorage } from '../test-utils/memoryStorage'
import DesignSystemCssLabPage from './DesignSystemCssLabPage'
import { MemoryRouter, useLocation } from 'react-router-dom'
import { CurrencyContext } from '../money/CurrencyContext'
import { FIXTURE_CURRENCY_CONTEXT_VALUE } from './design-system/fixtureCurrency'

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="parent-location">{location.pathname}</output>
}

describe('DesignSystemCssLabPage real gallery portal', () => {
  beforeEach(() => {
    installMemoryStorage()
  })

  it('mounts the expanded gallery and contains its table-of-contents navigation', async () => {
    const demandLivePreferences = vi.fn()
    render(<CurrencyContext.Provider value={{ ...FIXTURE_CURRENCY_CONTEXT_VALUE, ensureLoaded: demandLivePreferences }}><MemoryRouter initialEntries={['/design-system/css']}><DesignSystemCssLabPage /><LocationProbe /></MemoryRouter></CurrencyContext.Provider>)
    const frame = screen.getByTitle('CSS Lab component preview') as HTMLIFrameElement
    const preview = within(frame.contentDocument!.body)

    await waitFor(() => expect(preview.getByRole('heading', {
      level: 1,
      name: 'Design System & Component Library',
    })).toBeInTheDocument())
    expect(preview.getByTestId('ds-section-core-examples')).toBeInTheDocument()
    expect(preview.getByTestId('ds-section-workflow-examples')).toBeInTheDocument()

    const tokensLink = frame.contentDocument!.querySelector<HTMLAnchorElement>('a[href="#tokens"]')
    expect(tokensLink).not.toBeNull()
    expect(frame.contentDocument!.getElementById('tokens')).not.toBeNull()
    expect(fireEvent.click(tokensLink!)).toBe(false)
    const specimenLink = frame.contentDocument!.querySelector<HTMLAnchorElement>('a[href^="/agents/"]')
    expect(specimenLink).not.toBeNull()
    fireEvent.click(specimenLink!)
    fireEvent.click(preview.getByRole('button', { name: /complete setup/i }))
    expect(screen.getByTestId('parent-location')).toHaveTextContent('/design-system/css')
    expect(demandLivePreferences).not.toHaveBeenCalled()
  // The real gallery renders the full specimen inventory alongside the iframe;
  // allow the complete-suite worker pool time to perform its accessibility queries.
  }, 15_000)
})
