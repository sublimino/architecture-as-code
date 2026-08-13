import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { ProofConsole, type Proof } from './ProofConsole'

// A verdict that rests on three commands has to be able to SHOW three commands.
// Step 6 of the credential lifecycle is the case that forced this: the platform
// response is a revocation, an annotation and a NetworkPolicy, and with room for
// one command the console showed the NetworkPolicy — the weakest of the three —
// and that silently became the definition of "stunned".

const proof = (over: Partial<Proof> = {}): Proof => ({
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

// ── Incremental output ───────────────────────────────────────────────────────
//
// `stream` is additive and every one of these starts from the same place: a
// proof that does not set it must render byte-for-byte what it rendered before
// the prop existed. CredentialEvidencePanel renders one of these per lifecycle
// step and knows nothing about streaming; if it has to change, the prop is
// wrong.

describe('a proof that does not declare a stream is unchanged', () => {
  it('grows no status row and no live region', () => {
    render(<ProofConsole proofs={[proof()]} testId="c" />)
    expect(screen.queryByTestId('c-stream')).not.toBeInTheDocument()
    expect(screen.queryByTestId('c-stream-announce')).not.toBeInTheDocument()
    expect(screen.getByTestId('c')).toHaveTextContent('No value found')
  })

  it('still calls empty output "(no output)" — a finished command that printed nothing', () => {
    render(<ProofConsole proofs={[proof({ detail: '' })]} testId="c" />)
    expect(screen.getByTestId('c-detail')).toHaveTextContent('(no output)')
  })
})

describe('a streaming proof says so, and does not pass off a partial answer as a whole one', () => {
  it('shows the wait treatment while output is arriving', () => {
    render(<ProofConsole proofs={[proof({ stream: 'streaming' })]} testId="c" />)
    expect(screen.getByTestId('c-stream')).toHaveAttribute('data-stream', 'streaming')
    // The house indicator, which counts elapsed seconds — the figure is what
    // separates a slow stream from a dead one.
    expect(screen.getByTestId('c-stream-wait')).toBeInTheDocument()
  })

  it('renders nothing-yet as nothing, never as "(no output)"', () => {
    // "(no output)" is a verdict about a finished command. Printing it over an
    // open stream states a conclusion the console does not have yet, and it is
    // the specific way a half-collected proof reads as a complete one.
    render(<ProofConsole proofs={[proof({ detail: '', stream: 'streaming' })]} testId="c" />)
    expect(screen.getByTestId('c-detail').textContent).toBe('')
  })

  it('states completion in a word rather than by the indicator vanishing', () => {
    render(<ProofConsole proofs={[proof({ stream: 'complete' })]} testId="c" />)
    expect(screen.getByTestId('c-stream')).toHaveAttribute('data-stream', 'complete')
    expect(screen.getByTestId('c-stream')).toHaveTextContent('Complete')
    expect(screen.queryByTestId('c-stream-wait')).not.toBeInTheDocument()
  })

  it('states a stall in words and colour, not colour alone', () => {
    render(
      <ProofConsole
        proofs={[proof({ stream: 'stalled', streamNote: 'Runner stopped answering after 45s.' })]}
        testId="c"
      />,
    )
    // A red dot is invisible to a good share of any room and to every printout,
    // so the word carries the meaning and the colour only reinforces it.
    expect(screen.getByTestId('c-stream')).toHaveTextContent('Stopped')
    expect(screen.getByTestId('c-stream-note')).toHaveTextContent('Runner stopped answering after 45s.')
  })

  it('drops the note on phases where it would be a non-sequitur', () => {
    render(<ProofConsole proofs={[proof({ stream: 'complete', streamNote: 'ignored' })]} testId="c" />)
    expect(screen.queryByTestId('c-stream-note')).not.toBeInTheDocument()
  })

  it('tracks the selected tab, so switching proofs switches phase too', async () => {
    render(
      <ProofConsole
        proofs={[proof({ stream: 'complete' }), proof({ label: 'Egress', command: 'nc -z', stream: 'streaming' })]}
        testId="c"
      />,
    )
    expect(screen.getByTestId('c-stream')).toHaveAttribute('data-stream', 'complete')
    await userEvent.click(screen.getByTestId('c-tab-1'))
    expect(screen.getByTestId('c-stream')).toHaveAttribute('data-stream', 'streaming')
  })
})

describe('the log body is never a live region', () => {
  it('announces nothing at all unless asked', () => {
    // The default matters more than the feature. A caller who adds streaming
    // without thinking about screen readers must add zero regions, not a bad
    // one — which is why `announce` is off rather than on.
    render(<ProofConsole proofs={[proof({ stream: 'streaming' })]} testId="c" />)
    expect(screen.queryByTestId('c-stream-announce')).not.toBeInTheDocument()
    expect(screen.getByTestId('c').querySelector('[aria-live]')).toBeNull()
  })

  it('announces the phase from a region beside the output, not around it', () => {
    render(<ProofConsole proofs={[proof({ stream: 'streaming' })]} testId="c" announce />)
    const region = screen.getByTestId('c-stream-announce')
    expect(region).toHaveAttribute('role', 'status')
    expect(region).toHaveAttribute('aria-live', 'polite')

    // The two things that make it safe. The body is outside it, so an
    // appending log is not read out chunk by chunk; and the status row is
    // outside it too, because PixelLoader rewrites its elapsed figure ten times
    // a second and a region around that announces ten times a second.
    expect(screen.getByTestId('c-detail').closest('[aria-live]')).toBeNull()
    expect(screen.getByTestId('c-stream').closest('[aria-live]')).toBeNull()
  })

  it('says which phase it is in, in each phase', () => {
    const { rerender } = render(<ProofConsole proofs={[proof({ stream: 'streaming' })]} testId="c" announce />)
    expect(screen.getByTestId('c-stream-announce')).toHaveTextContent(/still arriving/i)

    rerender(<ProofConsole proofs={[proof({ stream: 'complete' })]} testId="c" announce />)
    expect(screen.getByTestId('c-stream-announce')).toHaveTextContent(/complete/i)

    rerender(<ProofConsole proofs={[proof({ stream: 'stalled' })]} testId="c" announce />)
    // "Incomplete" is the word that matters here: a stalled stream that
    // announces only "stopped" leaves the listener thinking it finished.
    expect(screen.getByTestId('c-stream-announce')).toHaveTextContent(/incomplete/i)
  })

  it('adds no region to a static proof even when announce is on', () => {
    render(<ProofConsole proofs={[proof()]} testId="c" announce />)
    expect(screen.queryByTestId('c-stream-announce')).not.toBeInTheDocument()
  })
})
