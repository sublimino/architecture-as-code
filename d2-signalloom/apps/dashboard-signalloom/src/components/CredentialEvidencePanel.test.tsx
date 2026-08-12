import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { CredentialEvidencePanel } from './CredentialEvidencePanel'
import { evidenceSummary, normaliseState, parseEvidence } from '../api/credentialEvidence'

// The card this replaces derived six steps from `!!agent.id` and printed
// hardcoded timestamps, so it showed everything completed the moment an agent
// existed. These tests exist to make that class of claim impossible: nothing may
// render as progress without a probe behind it, and a failure to look must never
// look like a successful look.

const step = (over: Partial<Record<string, unknown>> = {}) => ({
  step: 1,
  label: 'Agent Deployment',
  state: 'observed',
  command: "kubectl -n fe-signalloom-agents get pod -l signalloom.ai/supercred=true",
  detail: 'true',
  summary: 'Agent pod is running and ready',
  ...over,
})

const payload = (steps: unknown[]) => ({
  generated_at: '2026-08-12T00:00:00Z',
  source: 'supercred-evidence.sh',
  steps,
})

const fetcherFor = (body: unknown, ok = true, status = 200) =>
  vi.fn().mockResolvedValue({ ok, status, json: async () => body } as unknown as Response)

describe('the lifecycle only shows what was observed', () => {
  it('renders one row per step with its observed state', async () => {
    const fetcher = fetcherFor(payload([step(), step({ step: 2, label: 'SPIFFE Identity', state: 'absent' })]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)

    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-state-1')).toHaveTextContent('observed')
    expect(screen.getByTestId('evidence-state-2')).toHaveTextContent('not present')
  })

  it('never labels anything "completed"', async () => {
    const fetcher = fetcherFor(payload([step(), step({ step: 2, state: 'absent' }), step({ step: 3, state: 'unavailable' })]))
    const { container } = render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    expect(container.textContent).not.toMatch(/completed/i)
  })

  it('distinguishes "we could not check" from "it is not there"', async () => {
    const fetcher = fetcherFor(payload([step({ state: 'unavailable', summary: 'Cannot reach a cluster' })]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-state-1')).toBeInTheDocument())
    // "unverified", not "not present" — the two must never collapse.
    expect(screen.getByTestId('evidence-state-1')).toHaveTextContent('unverified')
    expect(screen.getByTestId('evidence-state-1')).not.toHaveTextContent('not present')
  })
})

describe('the debugger console', () => {
  it('reveals the literal command and raw output on demand', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor(payload([step()]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    expect(screen.queryByTestId('evidence-console-1')).not.toBeInTheDocument()
    await user.click(screen.getByTestId('evidence-disclose-1'))

    const console_ = screen.getByTestId('evidence-console-1')
    // Verbatim and un-truncated: a debugger has to be able to paste and rerun it.
    expect(console_).toHaveTextContent('kubectl -n fe-signalloom-agents get pod -l signalloom.ai/supercred=true')
    expect(console_).toHaveTextContent('true')
  })

  it('opens every console at once for a technical walkthrough', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor(payload([step(), step({ step: 2 })]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    expect(screen.getByTestId('evidence-console-1')).toBeInTheDocument()
    expect(screen.getByTestId('evidence-console-2')).toBeInTheDocument()
  })

  it('shows a placeholder rather than an empty console when a probe printed nothing', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor(payload([step({ detail: '' })]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    await user.click(screen.getByTestId('evidence-disclose-1'))
    expect(screen.getByTestId('evidence-console-1')).toHaveTextContent('(no output)')
  })
})

describe('the executive headline', () => {
  it('counts only what was actually confirmed, and says what was not checked', async () => {
    const fetcher = fetcherFor(payload([
      step(), step({ step: 2 }),
      step({ step: 3, state: 'absent' }),
      step({ step: 4, state: 'unavailable' }),
    ]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-headline')).toBeInTheDocument())
    const text = screen.getByTestId('evidence-headline').textContent ?? ''
    expect(text).toContain('2 of 4')
    expect(text).toContain('1 could not be checked')
  })

  it('does not claim confirmation when nothing could be checked', async () => {
    const fetcher = fetcherFor(payload([step({ state: 'unavailable' }), step({ step: 2, state: 'unavailable' })]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-headline')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-headline')).toHaveTextContent('Nothing could be checked')
  })
})

describe('failure is loud', () => {
  it('shows an alert and NO steps when the endpoint errors', async () => {
    const fetcher = fetcherFor({}, false, 502)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    // An empty lifecycle would read identically to "nothing is deployed".
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('HTTP 502')
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('not the same as the chain being absent')
    expect(screen.queryByTestId('evidence-step-1')).not.toBeInTheDocument()
  })

  it('reports a thrown request error rather than rendering a blank chain', async () => {
    const fetcher = vi.fn().mockRejectedValue(new Error('network down'))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('network down')
  })
})

describe('parsing refuses to invent progress', () => {
  it('maps any unknown state to unavailable, never to observed', () => {
    expect(normaliseState('completed')).toBe('unavailable')
    expect(normaliseState(undefined)).toBe('unavailable')
    expect(normaliseState('observed')).toBe('observed')
    expect(normaliseState('absent')).toBe('absent')
  })

  it('survives a malformed payload without fabricating fields', () => {
    const parsed = parseEvidence({ steps: [{}, { state: 'observed' }] })
    expect(parsed.steps).toHaveLength(2)
    expect(parsed.steps[0].state).toBe('unavailable')
    expect(parsed.steps[0].command).toBe('')
    expect(parsed.source).toBe('unknown')
  })

  it('counts states independently so unavailable is never scored as progress', () => {
    const s = evidenceSummary([
      { step: 1, label: '', state: 'observed', command: '', detail: '', summary: '' },
      { step: 2, label: '', state: 'unavailable', command: '', detail: '', summary: '' },
      { step: 3, label: '', state: 'absent', command: '', detail: '', summary: '' },
    ])
    expect(s).toEqual({ observed: 1, absent: 1, unavailable: 1, total: 3 })
  })
})
