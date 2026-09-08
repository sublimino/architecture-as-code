import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentDeepLink from './AgentDeepLink'

describe('AgentDeepLink Component', () => {
  it('renders a direct dossier link with default link variant inside router', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink target="agent-triage" dataTestId="triage-link" />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('triage-link')
    expect(el).toBeInTheDocument()
    expect(el.tagName).toBe('A')
    expect(el).toHaveAttribute('href', '/agents/agent-triage?tab=overview')
    expect(el).toHaveTextContent('agent-triage')
  })

  it('renders a selector route for structured selectors', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink target="k8s:sa:planner" variant="chip" dataTestId="planner-chip" />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('planner-chip')
    expect(el).toHaveAttribute('href', '/agents?selector=k8s%3Asa%3Aplanner')
    expect(el).toHaveTextContent('sa: planner')
  })

  it('renders badge variant with custom label and icon', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink
          target="agent-inventory"
          variant="badge"
          label="Inventory Service"
          showIcon={true}
          dataTestId="inventory-badge"
        />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('inventory-badge')
    expect(el).toHaveTextContent('Inventory Service')
    expect(screen.getByTestId('external-nav-glyph')).toBeInTheDocument()
    expect(screen.getByTestId('external-nav-glyph')).toHaveTextContent('↗')
  })

  it('renders custom children when provided', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink target="agent-triage">
          <span data-testid="custom-child">Custom Content</span>
        </AgentDeepLink>
      </MemoryRouter>,
    )
    expect(screen.getByTestId('custom-child')).toBeInTheDocument()
  })

  it('attaches instanceUid query parameter to target', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink
          target="agent-triage"
          instanceUid="uid-pod-999"
          dataTestId="instance-link"
        />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('instance-link')
    expect(el).toHaveAttribute('href', '/agents/agent-triage?tab=overview&instance=uid-pod-999')
  })

  it('renders fallback <a> tag outside React Router context without throwing', () => {
    render(
      <AgentDeepLink target="k8s:ns:payments" variant="pill" dataTestId="payments-pill" />,
    )
    const el = screen.getByTestId('payments-pill')
    expect(el.tagName).toBe('A')
    expect(el).toHaveAttribute('href', '/agents?selector=k8s%3Ans%3Apayments')
  })

  it('handles custom onClick callback while allowing normal navigation', () => {
    const handleClick = vi.fn()
    render(
      <MemoryRouter>
        <AgentDeepLink
          target="agent-triage"
          onClick={handleClick}
          dataTestId="clickable-link"
        />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('clickable-link')
    fireEvent.click(el)
    expect(handleClick).toHaveBeenCalledTimes(1)
  })

  it('renders subtle variant with muted styling', () => {
    render(
      <MemoryRouter>
        <AgentDeepLink
          target="agent-triage"
          variant="subtle"
          dataTestId="subtle-link"
        />
      </MemoryRouter>,
    )
    const el = screen.getByTestId('subtle-link')
    expect(el).toBeInTheDocument()
  })
})
