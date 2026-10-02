/**
 * credential_state.status "unknown": a stun or revoked lifecycle with no
 * evidence that bao and spire revoked anything. It must read as neither
 * active nor revoked.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import CredentialStateNotice from './CredentialStateNotice'
import AgentAccessTab from './AgentAccessTab'
import { claimedDossierAgentFixture } from '../api/fakeData'

describe('credential_state unknown', () => {
  it('CredentialStateNotice says unknown, not active and not revoked', () => {
    render(<CredentialStateNotice credentialState={{ status: 'unknown', reason: 'egress' }} agentName="x" />)
    const text = document.body.textContent ?? ''
    expect(text).not.toMatch(/Credentials active|REVOKED/)
    expect(screen.getByTestId('credential-state-unknown')).toHaveTextContent('Credential state unknown')
  })

  it('AgentAccessTab does not show a revoked CRL for an unknown credential state', () => {
    render(
      <MemoryRouter>
        <AgentAccessTab agent={{
          ...claimedDossierAgentFixture,
          lifecycle_state: 'stunned',
          credential_state: { status: 'unknown' },
          operational_state: {
            runtime_status: 'stopped',
            containment: { process_freeze: 'requested', network_isolation: 'requested', credential_revocation: 'unknown', credential_source: 'unavailable' },
          },
        }} />
      </MemoryRouter>,
    )
    expect(screen.getByTestId('access-spiffe-crl-badge')).not.toHaveTextContent('CRL: REVOKED')
    expect(document.body.textContent ?? '').not.toMatch(/Credentials active/)
  })
})
