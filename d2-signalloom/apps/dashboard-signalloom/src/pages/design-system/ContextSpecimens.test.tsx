import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it } from 'vitest'
import { ContextSpecimens } from './ContextSpecimens'

describe('ContextSpecimens', () => {
  it('renders safe signal, admin, and collusion examples from fixed props', () => {
    render(<MemoryRouter><ContextSpecimens /></MemoryRouter>)

    expect(screen.getByTestId('context-specimens')).toBeInTheDocument()
    expect(screen.getByTestId('window-selector')).toBeInTheDocument()
    expect(screen.getByTestId('findings-list')).toBeInTheDocument()
    expect(screen.getByTestId('source-table')).toBeInTheDocument()
    expect(screen.getByTestId('role-badge-admin')).toBeInTheDocument()
    expect(screen.getByTestId('status-badge-active')).toBeInTheDocument()
    expect(screen.getByTestId('context-subject-link')).toHaveAttribute('href', '/agents/agent-ci-runner?tab=overview')
    expect(screen.getByTestId('context-group-members')).toBeInTheDocument()
    expect(screen.getByTestId('context-collaborator-gains')).toBeInTheDocument()
  })
})
