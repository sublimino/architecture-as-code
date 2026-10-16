import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import CompletionCelebration from './CompletionCelebration'

const base = {
  tenantProfile: { organizationName: 'Org', workspaceId: 'ws' },
  containmentPolicy: {},
  onContinue: () => {},
}

describe('CompletionCelebration identity provider summary', () => {
  it('claims a verified connection only when the server verified it', () => {
    render(<CompletionCelebration {...base} idpConfig={{ providerId: 'okta', providerName: 'Okta', connectionTested: true }} />)
    expect(screen.getByTestId('completion-idp-status')).toHaveTextContent('Connection verified')
  })

  it('says the connection is not verified, and claims no trust federation, when it was never checked', () => {
    render(<CompletionCelebration {...base} idpConfig={{ providerId: 'claude', providerName: 'Anthropic Claude' }} />)
    expect(screen.getByTestId('completion-idp-status')).toHaveTextContent('Connection not verified')
    expect(screen.queryByText(/Federating SPIFFE Trust/)).not.toBeInTheDocument()
  })

  it('does not claim a containment halt is enabled, because no API persists the policy', () => {
    render(<CompletionCelebration {...base} idpConfig={{}} />)
    expect(screen.getByTestId('completion-containment-status')).toHaveTextContent('not yet enforced by the server')
    expect(screen.queryByText(/Sub-second Halt Enabled/)).not.toBeInTheDocument()
  })
})
