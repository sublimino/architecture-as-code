import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { ProofConsole } from './ProofConsole'

// A verdict that rests on three commands has to be able to SHOW three commands.
// Step 6 of the credential lifecycle is the case that forced this: the platform
// response is a revocation, an annotation and a NetworkPolicy, and with room for
// one command the console showed the NetworkPolicy — the weakest of the three —
// and that silently became the definition of "stunned".

const proof = (over: Partial<{ label: string; command: string; detail: string }> = {}) => ({
  label: 'Credential revocation',
  command: 'kubectl -n inf-bao exec deployment/openbao -- bao kv get kv/signalloom/cardvault-agent',
  detail: 'No value found',
  ...over,
})

describe('a single proof renders without tab furniture', () => {
  it('shows the command and its output with no tablist', () => {
    render(<ProofConsole proofs={[proof()]} testId="c" />)
    expect(screen.getByTestId('c')).toHaveTextContent('bao kv get kv/signalloom/cardvault-agent')
    expect(screen.getByTestId('c')).toHaveTextContent('No value found')
    expect(screen.queryByRole('tablist')).not.toBeInTheDocument()
  })

  it('says a probe printed nothing rather than rendering an empty box', () => {
    render(<ProofConsole proofs={[proof({ detail: '' })]} testId="c" />)
    expect(screen.getByTestId('c')).toHaveTextContent('(no output)')
  })

  it('preserves a multi-line command verbatim, so it can still be pasted', () => {
    const command = 'kubectl -n inf-bao exec deployment/openbao -- bao kv get kv/x\nkubectl -n inf-bao exec deployment/openbao -- bao read auth/jwt/role/y'
    render(<ProofConsole proofs={[proof({ command })]} testId="c" />)
    expect(screen.getByTestId('c-panel').textContent).toContain(command)
  })
})

describe('several proofs render as tabs', () => {
  const three = [
    proof(),
    proof({ label: 'Stun annotation (corroboration)', command: 'kubectl get pod -o jsonpath=annotations', detail: 'state=stunned' }),
    proof({ label: 'Network isolation', command: 'kubectl get networkpolicy -o name', detail: '(no isolating NetworkPolicy)' }),
  ]

  it('offers one tab per proof and opens on the primary one', () => {
    render(<ProofConsole proofs={three} testId="c" />)
    expect(screen.getAllByRole('tab')).toHaveLength(3)
    expect(screen.getByTestId('c-tab-0')).toHaveAttribute('aria-selected', 'true')
    // The mechanism, not a corroborating detail, is what greets the reader.
    expect(screen.getByTestId('c-panel')).toHaveTextContent('bao kv get')
  })

  it('switches the console to the selected proof', async () => {
    render(<ProofConsole proofs={three} testId="c" />)
    await userEvent.click(screen.getByTestId('c-tab-2'))
    expect(screen.getByTestId('c-panel')).toHaveTextContent('kubectl get networkpolicy -o name')
    expect(screen.getByTestId('c-panel')).toHaveTextContent('(no isolating NetworkPolicy)')
    expect(screen.getByTestId('c-tab-2')).toHaveAttribute('aria-selected', 'true')
  })

  it('shows every command across its tabs, none of them dropped', async () => {
    render(<ProofConsole proofs={three} testId="c" />)
    for (const [i, p] of three.entries()) {
      await userEvent.click(screen.getByTestId(`c-tab-${i}`))
      expect(screen.getByTestId('c-panel')).toHaveTextContent(p.command)
    }
  })

  it('labels an unnamed proof rather than rendering a nameless tab', () => {
    render(<ProofConsole proofs={[proof({ label: '' }), proof({ label: '', command: 'x' })]} testId="c" />)
    expect(screen.getByTestId('c-tab-0')).toHaveTextContent('Proof 1')
  })

  it('falls back to the primary proof when a re-check shortens the list', () => {
    // A stale index would render an empty console, which reads exactly like a
    // probe that returned nothing — the confusion this whole card exists to end.
    const { rerender } = render(<ProofConsole proofs={three} testId="c" />)
    rerender(<ProofConsole proofs={three} testId="c" />)
    rerender(<ProofConsole proofs={[three[0]]} testId="c" />)
    expect(screen.getByTestId('c-panel')).toHaveTextContent('bao kv get')
  })
})

describe('an empty proof list is stated, not hidden', () => {
  it('says nothing was recorded rather than showing a blank console', () => {
    render(<ProofConsole proofs={[]} testId="c" />)
    expect(screen.getByTestId('c')).toHaveTextContent('no proof was recorded')
  })
})
