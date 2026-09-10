import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import ProviderConfigureStep from './ProviderConfigureStep'
import type { ConnectorProvider } from '../../types/connectors'

function makeProvider(docs_link: string): ConnectorProvider {
  return {
    provider_id: 'test-provider',
    display_name: 'Test Provider',
    wizard_config: {
      help_text: 'Configure test provider.',
      docs_link,
      permissions: ['read:users'],
      fields: [],
    },
  }
}

describe('ProviderConfigureStep docs_link safety', () => {
  it('renders relative documentation link as router Link', () => {
    render(
      <MemoryRouter>
        <ProviderConfigureStep
          provider={makeProvider('/help/connectors/entra')}
          submitting={false}
          onSubmit={vi.fn()}
          onBack={vi.fn()}
          onSkipProvider={vi.fn()}
        />
      </MemoryRouter>,
    )
    const link = screen.getByRole('link', { name: 'View setup docs' })
    expect(link).toHaveAttribute('href', '/help/connectors/entra')
  })

  it('renders https documentation link with external attributes', () => {
    render(
      <MemoryRouter>
        <ProviderConfigureStep
          provider={makeProvider('https://learn.microsoft.com/entra')}
          submitting={false}
          onSubmit={vi.fn()}
          onBack={vi.fn()}
          onSkipProvider={vi.fn()}
        />
      </MemoryRouter>,
    )
    const link = screen.getByRole('link', { name: 'View setup docs' })
    expect(link).toHaveAttribute('href', 'https://learn.microsoft.com/entra')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noreferrer')
  })

  it('suppresses unsafe javascript: URI schemes', () => {
    render(
      <MemoryRouter>
        <ProviderConfigureStep
          provider={makeProvider('javascript:alert(1)')}
          submitting={false}
          onSubmit={vi.fn()}
          onBack={vi.fn()}
          onSkipProvider={vi.fn()}
        />
      </MemoryRouter>,
    )
    expect(screen.queryByRole('link', { name: 'View setup docs' })).toBeNull()
  })
})
