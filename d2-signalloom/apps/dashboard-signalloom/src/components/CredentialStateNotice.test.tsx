/**
 * The stun has to be legible to a normal authenticated user, not decoded from
 * a lifecycle enum. These tests hold that line.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import CredentialStateNotice from './CredentialStateNotice'
import type { AgentCredentialState } from '../types/api'

const REVOKED: AgentCredentialState = {
  status: 'revoked',
  reason: 'compliance-failure: securityContext not set',
  revoked_at: '2026-08-02T10:05:00Z',
  revoked_by: 'signal-loom-platform',
}

describe('CredentialStateNotice — nothing to say', () => {
  it('renders nothing when the platform has no credential state for the agent', () => {
    const { container } = render(<CredentialStateNotice credentialState={null} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('renders nothing when the field is absent entirely', () => {
    const { container } = render(<CredentialStateNotice credentialState={undefined} />)
    expect(container).toBeEmptyDOMElement()
  })
})

describe('CredentialStateNotice — credentials intact', () => {
  it('says so, so the column is not silently empty for healthy agents', () => {
    render(<CredentialStateNotice credentialState={{ status: 'active' }} />)
    expect(screen.getByText('Credentials active')).toBeInTheDocument()
  })

  it('does not raise the revoked treatment', () => {
    render(<CredentialStateNotice credentialState={{ status: 'active' }} />)
    expect(screen.queryByTestId('credential-state-revoked')).not.toBeInTheDocument()
  })
})

describe.each(['inline', 'panel'] as const)('CredentialStateNotice — revoked (%s)', (variant) => {
  function renderRevoked(state: AgentCredentialState = REVOKED) {
    return render(
      <CredentialStateNotice credentialState={state} agentName="Cardvault Agent" variant={variant} />,
    )
  }

  it('names the state in words, not just a status token', () => {
    renderRevoked()
    expect(screen.getByText(/STUNNED — CREDENTIALS REVOKED/)).toBeInTheDocument()
  })

  it('says WHY the credentials were revoked', () => {
    renderRevoked()
    expect(
      screen.getByText(/compliance-failure: securityContext not set/),
    ).toBeInTheDocument()
  })

  it('shows when the revocation happened', () => {
    renderRevoked()
    // Rendered in en-GB; assert on the date parts rather than a locale string.
    expect(screen.getByText(/02 Aug 2026/)).toBeInTheDocument()
  })

  it('announces itself — it appears with no user action on the audience window', () => {
    renderRevoked()
    const notice = screen.getByTestId('credential-state-revoked')
    expect(notice).toHaveAttribute('role', 'status')
    expect(notice).toHaveAttribute('aria-live', 'polite')
  })

  it('carries meaning in text, so colour is never the only signal', () => {
    renderRevoked()
    expect(screen.getByTestId('credential-state-revoked').textContent).toMatch(
      /CREDENTIALS REVOKED/,
    )
  })

  it('still renders when the cluster reported no reason', () => {
    renderRevoked({ status: 'revoked', revoked_at: REVOKED.revoked_at })
    expect(screen.getByText(/STUNNED — CREDENTIALS REVOKED/)).toBeInTheDocument()
  })

  it('survives an unparseable timestamp rather than rendering "Invalid Date"', () => {
    renderRevoked({ status: 'revoked', reason: 'x', revoked_at: 'not-a-date' })
    expect(screen.getByTestId('credential-state-revoked').textContent).not.toMatch(/Invalid Date/)
  })
})

describe('CredentialStateNotice — panel wording', () => {
  it('names the agent so a screenshot identifies its own subject', () => {
    render(
      <CredentialStateNotice credentialState={REVOKED} agentName="Cardvault Agent" variant="panel" />,
    )
    expect(screen.getByText('Cardvault Agent')).toBeInTheDocument()
  })

  it('states the consequence, not just the event', () => {
    render(
      <CredentialStateNotice credentialState={REVOKED} agentName="Cardvault Agent" variant="panel" />,
    )
    expect(screen.getByText(/can no longer authenticate to the\s+platform/)).toBeInTheDocument()
  })

  it('attributes the revocation', () => {
    render(
      <CredentialStateNotice credentialState={REVOKED} agentName="Cardvault Agent" variant="panel" />,
    )
    expect(screen.getByText(/signal-loom-platform/)).toBeInTheDocument()
  })

  it('reads sensibly with no agent name to hand', () => {
    render(<CredentialStateNotice credentialState={REVOKED} variant="panel" />)
    expect(screen.getByText(/This agent/)).toBeInTheDocument()
  })
})

describe('CredentialStateNotice — accessible colour', () => {
  // The dead-token trap this codebase has hit before: var(--card) is declared
  // nowhere and renders invisible under Light. styles/cssVarUsage.test.ts scans
  // for that globally; this pins the specific tokens this component may use.
  const ALLOWED = ['--error', '--text', '--muted']

  it('uses only tokens that are declared in every theme', () => {
    const { container } = render(
      <CredentialStateNotice credentialState={REVOKED} agentName="A" variant="panel" />,
    )
    const used = [...container.innerHTML.matchAll(/var\(\s*(--[a-zA-Z0-9-]+)/g)].map((m) => m[1])
    expect([...new Set(used)].sort()).toEqual(expect.arrayContaining([]))
    for (const token of used) expect(ALLOWED).toContain(token)
  })

  it('never fills with amber — black-on-amber is 4.06:1 here and fails AA', () => {
    const { container } = render(
      <CredentialStateNotice credentialState={REVOKED} agentName="A" variant="panel" />,
    )
    expect(container.innerHTML).not.toMatch(/--amber/)
    expect(container.innerHTML).not.toMatch(/--warning/)
  })
})
