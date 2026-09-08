import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom'
import SafeLink from './SafeLink'

describe('SafeLink', () => {
  describe('outside React Router context (standalone fallback)', () => {
    it('renders a standard <a> tag with string href without throwing', () => {
      render(
        <SafeLink to="/agents/agent-1" data-testid="safe-link" title="Agent Dossier">
          Agent Dossier
        </SafeLink>
      )

      const el = screen.getByTestId('safe-link')
      expect(el.tagName.toLowerCase()).toBe('a')
      expect(el).toHaveAttribute('href', '/agents/agent-1')
      expect(el).toHaveAttribute('title', 'Agent Dossier')
      expect(el).toHaveTextContent('Agent Dossier')
    })

    it('translates object to descriptor into an href string', () => {
      render(
        <SafeLink
          to={{ pathname: '/agents', search: '?selector=k8s:sa:planner', hash: '#details' }}
          data-testid="safe-link-obj"
        >
          Planner Selector
        </SafeLink>
      )

      const el = screen.getByTestId('safe-link-obj')
      expect(el).toHaveAttribute('href', '/agents?selector=k8s:sa:planner#details')
    })

    it('forwards custom class, style, and event handlers', () => {
      const handleClick = vi.fn((e) => e.preventDefault())
      const handleMouseEnter = vi.fn()
      const handleMouseLeave = vi.fn()

      render(
        <SafeLink
          to="/test"
          className="custom-class"
          style={{ color: 'rgb(0, 200, 255)' }}
          onClick={handleClick}
          onMouseEnter={handleMouseEnter}
          onMouseLeave={handleMouseLeave}
          data-testid="interactive-link"
        >
          Interactive
        </SafeLink>
      )

      const el = screen.getByTestId('interactive-link')
      expect(el).toHaveClass('custom-class')
      expect(el).toHaveStyle({ color: 'rgb(0, 200, 255)' })

      fireEvent.mouseEnter(el)
      expect(handleMouseEnter).toHaveBeenCalledTimes(1)

      fireEvent.mouseLeave(el)
      expect(handleMouseLeave).toHaveBeenCalledTimes(1)

      fireEvent.click(el)
      expect(handleClick).toHaveBeenCalledTimes(1)
    })
  })

  describe('inside React Router context', () => {
    function LocationWatcher() {
      const location = useLocation()
      return <div data-testid="current-path">{location.pathname + location.search}</div>
    }

    it('renders a router Link and navigates on click', () => {
      render(
        <MemoryRouter initialEntries={['/start']}>
          <SafeLink to="/agents/agent-cardvault" data-testid="router-link">
            CardVault
          </SafeLink>
          <Routes>
            <Route path="*" element={<LocationWatcher />} />
          </Routes>
        </MemoryRouter>
      )

      const el = screen.getByTestId('router-link')
      expect(el.tagName.toLowerCase()).toBe('a')
      expect(el).toHaveAttribute('href', '/agents/agent-cardvault')
      expect(screen.getByTestId('current-path')).toHaveTextContent('/start')

      fireEvent.click(el)
      expect(screen.getByTestId('current-path')).toHaveTextContent('/agents/agent-cardvault')
    })

    it('navigates with query params and handles object `to`', () => {
      render(
        <MemoryRouter initialEntries={['/home']}>
          <SafeLink
            to={{ pathname: '/agents', search: '?selector=k8s:sa:cardvault-agent' }}
            data-testid="router-obj-link"
          >
            Filtered Agents
          </SafeLink>
          <Routes>
            <Route path="*" element={<LocationWatcher />} />
          </Routes>
        </MemoryRouter>
      )

      const el = screen.getByTestId('router-obj-link')
      fireEvent.click(el)
      expect(screen.getByTestId('current-path')).toHaveTextContent('/agents?selector=k8s:sa:cardvault-agent')
    })
  })
})
