/**
 * The SVID expiry is rendered only from identity.cert_valid_until. It used to
 * be invented as "now + 4h" whenever credential_state was active, so every
 * agent looked like it held a freshly issued SVID.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import AgentIdentityTab from './AgentIdentityTab'
import type { AgentResponse } from '../types/api'
import { claimedDossierAgentFixture } from '../api/fakeData'

function renderTab(a: AgentResponse) {
  return render(<MemoryRouter><AgentIdentityTab agent={a} /></MemoryRouter>)
}

const base: AgentResponse = {
  ...claimedDossierAgentFixture,
  credential_state: { status: 'active' },
  identity: { ...claimedDossierAgentFixture.identity!, cert_valid_from: null, cert_valid_until: null },
}

describe('AgentIdentityTab SVID expiry', () => {
  it('says expiry unknown instead of inventing one for an active credential', () => {
    renderTab(base)
    const text = document.body.textContent ?? ''
    expect(text).not.toMatch(/expires in/i)
    expect(text).toMatch(/expiry unknown/i)
  })

  it('does not present created_at as the SVID validity start', () => {
    renderTab({ ...base, created_at: '2026-07-01T00:00:00Z' })
    expect(document.body.textContent ?? '').not.toMatch(/Valid: \d/)
  })

  it('renders a real expiry from the identity', () => {
    const until = new Date(Date.now() + 2 * 3600000 + 5 * 60000).toISOString()
    renderTab({ ...base, identity: { ...base.identity!, cert_valid_until: until } })
    expect(screen.getByText(/expires in 2h/i)).toBeInTheDocument()
    expect(document.body.textContent ?? '').not.toMatch(/expiry unknown/i)
  })
})
