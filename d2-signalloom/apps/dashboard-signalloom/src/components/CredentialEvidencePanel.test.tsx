import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { CredentialEvidencePanel } from './CredentialEvidencePanel'
import { EVIDENCE_ENDPOINT, evidenceSummary, normaliseState, parseEvidence } from '../api/credentialEvidence'
import { DEMO_API } from '../api/demoRunner'

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

// One command per step made whichever command was chosen the definition of the
// step. Step 6 is the proof: a stun is a REVOCATION (the mechanism), a stun
// annotation (corroboration) and a NetworkPolicy (containment), and the single
// command on offer was the NetworkPolicy — the weakest of the three.
describe('a step whose verdict rests on several commands can show all of them', () => {
  const stunStep = step({
    step: 6,
    label: 'Platform Response',
    state: 'observed',
    command: 'bao kv get kv/signalloom/cardvault-agent',
    detail: 'No value found',
    summary: 'Agent has been stunned — its OpenBao secret and JWT role are both gone',
    proofs: [
      { label: 'Credential revocation', command: 'bao kv get kv/signalloom/cardvault-agent', detail: 'No value found' },
      { label: 'Stun annotation (corroboration)', command: 'kubectl get pod -o jsonpath=stunned-at', detail: 'state=stunned' },
      { label: 'Network isolation', command: 'kubectl get networkpolicy -o name', detail: 'networkpolicy/stun-cardvault-agent' },
    ],
  })

  it('renders one tab per proof inside the step console', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([stunStep])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-6')).toBeInTheDocument())
    await user.click(screen.getByTestId('evidence-disclose-6'))
    expect(screen.getAllByRole('tab')).toHaveLength(3)
    expect(screen.getByTestId('evidence-console-6-tab-0')).toHaveTextContent('Credential revocation')
  })

  it('opens on the revocation — the mechanism, not the corroboration', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([stunStep])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-6')).toBeInTheDocument())
    await user.click(screen.getByTestId('evidence-disclose-6'))
    expect(screen.getByTestId('evidence-console-6-panel')).toHaveTextContent('bao kv get kv/signalloom/cardvault-agent')
  })

  it('reaches every proof, including ones the old single-command shape could not carry', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([stunStep])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-6')).toBeInTheDocument())
    await user.click(screen.getByTestId('evidence-disclose-6'))
    await user.click(screen.getByTestId('evidence-console-6-tab-1'))
    expect(screen.getByTestId('evidence-console-6-panel')).toHaveTextContent('stunned-at')
    await user.click(screen.getByTestId('evidence-console-6-tab-2'))
    expect(screen.getByTestId('evidence-console-6-panel')).toHaveTextContent('networkpolicy/stun-cardvault-agent')
  })

  it('says how many checks are behind a step before it is opened', async () => {
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([stunStep])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-6')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-disclose-6')).toHaveTextContent('3 checks')
  })

  it('leaves a single-proof step free of tabs', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([step()])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    await user.click(screen.getByTestId('evidence-disclose-1'))
    expect(screen.queryByRole('tab')).not.toBeInTheDocument()
    expect(screen.getByTestId('evidence-console-1')).toHaveTextContent('signalloom.ai/supercred=true')
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

  // The API and the UI must not disagree about the shape. A runner image built
  // before `proofs` existed still sends command/detail only, and the card has to
  // keep showing the command that decided the step rather than an empty console.
  it('normalises a single-command step into one labelled proof', () => {
    const parsed = parseEvidence(payload([step()]))
    expect(parsed.steps[0].proofs).toHaveLength(1)
    expect(parsed.steps[0].proofs[0].command).toBe(parsed.steps[0].command)
    expect(parsed.steps[0].proofs[0].detail).toBe('true')
    expect(parsed.steps[0].proofs[0].label).toBe('Agent Deployment')
  })

  it('keeps every proof a multi-proof step sent, in order', () => {
    const parsed = parseEvidence(payload([step({
      proofs: [
        { label: 'Credential revocation', command: 'bao kv get x', detail: 'gone' },
        { label: 'Network isolation', command: 'kubectl get netpol', detail: 'none' },
      ],
    })]))
    expect(parsed.steps[0].proofs.map((p) => p.label)).toEqual(['Credential revocation', 'Network isolation'])
  })

  it('drops a proof with no command instead of rendering an empty tab', () => {
    const parsed = parseEvidence(payload([step({
      proofs: [{ label: 'nothing', detail: 'x' }, { label: 'real', command: 'kubectl get pod', detail: 'y' }],
    })]))
    expect(parsed.steps[0].proofs).toHaveLength(1)
    expect(parsed.steps[0].proofs[0].label).toBe('real')
  })

  it('falls back to the step command when the proofs array is junk', () => {
    const parsed = parseEvidence(payload([step({ proofs: 'not-an-array' })]))
    expect(parsed.steps[0].proofs).toHaveLength(1)
    expect(parsed.steps[0].proofs[0].command).toContain('kubectl -n fe-signalloom-agents')
  })

  it('counts states independently so unavailable is never scored as progress', () => {
    const s = evidenceSummary([
      { step: 1, label: '', state: 'observed', command: '', detail: '', summary: '', proofs: [] },
      { step: 2, label: '', state: 'unavailable', command: '', detail: '', summary: '', proofs: [] },
      { step: 3, label: '', state: 'absent', command: '', detail: '', summary: '', proofs: [] },
    ])
    expect(s).toEqual({ observed: 1, absent: 1, unavailable: 1, total: 3 })
  })
})

// The defect these exist to prevent.
//
// Every test above injects `fetcher` and asserts on the RESPONSE. None of them
// looked at the REQUEST, and that is exactly how this component shipped calling
// `/api/demo/supercred/evidence` with no Authorization header while every other
// module in src/api attached one. The endpoint sits behind `authenticated_tenant`,
// so the live call returned 401 and the card read "No evidence has been collected
// yet." — indistinguishable, to a viewer, from an empty cluster.
//
// The injection seam that makes the component testable is the seam that hid the
// bug. So: assert the request, not just the reply.
describe('the evidence request is authenticated', () => {
  it('sends the bearer token the endpoint requires', async () => {
    const fetcher = fetcherFor(payload([step()]))
    render(
      <CredentialEvidencePanel
        fetcher={fetcher as unknown as typeof fetch}
        getToken={async () => 'test-token'}
      />,
    )
    await waitFor(() => expect(fetcher).toHaveBeenCalled())
    const [, init] = fetcher.mock.calls[0]
    expect((init as RequestInit).headers).toMatchObject({
      Accept: 'application/json',
      Authorization: 'Bearer test-token',
    })
  })

  it('re-authenticates on Re-check rather than replaying a stale header', async () => {
    const fetcher = fetcherFor(payload([step()]))
    let issued = 0
    render(
      <CredentialEvidencePanel
        fetcher={fetcher as unknown as typeof fetch}
        getToken={async () => `token-${++issued}`}
      />,
    )
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(1))
    await userEvent.click(screen.getByTestId('evidence-refresh'))
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2))
    expect((fetcher.mock.calls[1][1] as RequestInit).headers).toMatchObject({
      Authorization: 'Bearer token-2',
    })
  })

  it('still issues the request when no token can be obtained, so the 401 is visible', async () => {
    // Silently skipping the request would leave the card empty, which is the one
    // rendering this component must never produce for a state it did not observe.
    const fetcher = fetcherFor({}, false, 401)
    render(
      <CredentialEvidencePanel
        fetcher={fetcher as unknown as typeof fetch}
        getToken={async () => {
          throw new Error('token refresh failed')
        }}
      />,
    )
    await waitFor(() => expect(fetcher).toHaveBeenCalled())
    expect((fetcher.mock.calls[0][1] as RequestInit).headers).not.toHaveProperty('Authorization')
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('HTTP 401')
  })

  it('names an unaccepted session instead of implying the chain is absent', async () => {
    const fetcher = fetcherFor({}, false, 401)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('did not accept this session')
    expect(screen.queryByTestId('evidence-step-1')).not.toBeInTheDocument()
  })
})

// Which prefix the evidence request uses is not cosmetic — it decides which POD
// answers it. nginx sends /demo-api/ to supercred-demo-runner (kubectl, repo
// scripts, cluster RBAC) and /api/ to fe-signalloom-api, which has none of them.
// The demo_runner router is mounted in BOTH, so the wrong prefix is accepted
// rather than 404'd and then dies with `IndexError: 4` deep in the handler. The
// browser sees a bare HTTP 500 and the card renders empty.
describe('the evidence request reaches the pod that can answer it', () => {
  it('is routed through the demo-runner prefix, not the generic API prefix', () => {
    expect(EVIDENCE_ENDPOINT).toBe('/demo-api/evidence')
    expect(EVIDENCE_ENDPOINT.startsWith(DEMO_API)).toBe(true)
    // The spelling that reaches fe-signalloom-api and 500s.
    expect(EVIDENCE_ENDPOINT).not.toContain('/api/demo/supercred')
  })

  it('asks for exactly that path at runtime', async () => {
    const fetcher = fetcherFor(payload([step()]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} getToken={async () => 't'} />)
    await waitFor(() => expect(fetcher).toHaveBeenCalled())
    expect(fetcher.mock.calls[0][0]).toBe('/demo-api/evidence')
  })
})

// "Evidence unavailable (HTTP 500)" and "Evidence unavailable (HTTP 401)" were
// the same sentence with a different number. One means the platform is broken,
// the other means it would not let you look. An operator standing in front of an
// audience has to tell them apart without reading the status code.
describe('a failure says what kind of failure it was', () => {
  const failing = (status: number) => fetcherFor({}, false, status)

  it('names a platform fault for a 500, and does not blame the session', async () => {
    render(<CredentialEvidencePanel fetcher={failing(500) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    const err = screen.getByTestId('evidence-error')
    expect(err).toHaveTextContent('platform failed while collecting evidence')
    expect(err).toHaveTextContent('HTTP 500')
    expect(err).not.toHaveTextContent('did not accept this session')
  })

  it('names a rejected session for a 401, and does not blame the platform', async () => {
    render(<CredentialEvidencePanel fetcher={failing(401) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    const err = screen.getByTestId('evidence-error')
    expect(err).toHaveTextContent('did not accept this session')
    expect(err).not.toHaveTextContent('platform failed')
  })

  it('distinguishes a timeout and a routing fault from both', async () => {
    const { unmount } = render(<CredentialEvidencePanel fetcher={failing(504) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toHaveTextContent('timed out'))
    unmount()
    render(<CredentialEvidencePanel fetcher={failing(404) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toHaveTextContent('could not be reached'))
  })

  it('still insists a failure is not a verdict on the chain, whatever the status', async () => {
    for (const status of [401, 404, 500, 504]) {
      const { unmount } = render(<CredentialEvidencePanel fetcher={failing(status) as unknown as typeof fetch} />)
      await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
      expect(screen.getByTestId('evidence-error')).toHaveTextContent('not the same as the chain being absent')
      unmount()
    }
  })

  it('the headline stops claiming a clean empty state once a check has failed', async () => {
    render(<CredentialEvidencePanel fetcher={failing(500) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    const line = screen.getByTestId('evidence-headline')
    // "No evidence has been collected yet" describes a fresh card, not a broken probe.
    expect(line).not.toHaveTextContent('No evidence has been collected yet')
    expect(line).toHaveTextContent('the check itself failed')
  })
})

describe('the commands toggle is honest about having nothing to show', () => {
  it('is disabled while the chain is empty', async () => {
    render(<CredentialEvidencePanel fetcher={fetcherFor({}, false, 500) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-toggle-commands')).toBeDisabled()
  })

  it('is enabled as soon as there are rows whose commands it can reveal', async () => {
    render(<CredentialEvidencePanel fetcher={fetcherFor(payload([step()])) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-toggle-commands')).toBeEnabled()
  })
})

// Four defects found by review of the first pass at this card, each one a place
// where the UI still said something it had not earned.
describe('the card does not overclaim while it is empty', () => {
  it('distinguishes a refused session from a rejected one', async () => {
    render(<CredentialEvidencePanel fetcher={fetcherFor({}, false, 403) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('not permitted')
    expect(screen.getByTestId('evidence-error')).toHaveTextContent('HTTP 403')
  })

  it('never renders two different faults with identical text', async () => {
    // The guard against someone re-collapsing the taxonomy later.
    const seen = new Map<number, string>()
    for (const status of [401, 403, 404, 500, 504]) {
      const { unmount } = render(<CredentialEvidencePanel fetcher={fetcherFor({}, false, status) as unknown as typeof fetch} />)
      await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
      seen.set(status, screen.getByTestId('evidence-error').textContent ?? '')
      unmount()
    }
    expect(new Set(seen.values()).size).toBe(seen.size)
  })

  it('says it is checking rather than claiming a clean empty chain mid-flight', async () => {
    let release: (v: unknown) => void = () => {}
    const pending = new Promise((r) => { release = r })
    const fetcher = vi.fn().mockReturnValue(pending)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-headline')).toHaveTextContent('Checking the credential chain'))
    expect(screen.getByTestId('evidence-headline')).not.toHaveTextContent('No evidence has been collected yet')
    release({ ok: true, status: 200, json: async () => payload([step()]) })
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
  })

  it('does not claim "every row below" when there are no rows below', async () => {
    const { container } = render(<CredentialEvidencePanel fetcher={fetcherFor({}, false, 500) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    expect(container.textContent).not.toMatch(/Every row below was decided/i)
  })

  it('counts the first probe up rather than just asserting it is checking', async () => {
    // The headline already said "Checking the credential chain…" and then said
    // it forever, indistinguishable at second 2 and second 90.
    let release: (v: unknown) => void = () => {}
    const pending = new Promise((r) => { release = r })
    const fetcher = vi.fn().mockReturnValue(pending)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)

    const loader = await screen.findByTestId('evidence-headline-loader')
    expect(within(loader).getByTestId('evidence-headline-loader-elapsed')).toHaveTextContent(/s$/)
    // Same sentence, same element — the loader carries it rather than replacing it.
    expect(screen.getByTestId('evidence-headline')).toHaveTextContent('Checking the credential chain')

    release({ ok: true, status: 200, json: async () => payload([step()]) })
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    expect(screen.queryByTestId('evidence-headline-loader')).not.toBeInTheDocument()
  })

  it('counts a re-check up inside the button and keeps the button named', async () => {
    let release: (v: unknown) => void = () => {}
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step()]) } as unknown as Response)
      .mockReturnValueOnce(new Promise((r) => { release = r }))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    const idleWidth = (screen.getByTestId('evidence-refresh') as HTMLButtonElement).style.minWidth
    await userEvent.click(screen.getByTestId('evidence-refresh'))

    expect(await screen.findByTestId('evidence-recheck-loader')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /checking/i })).toBeDisabled()
    // The header must not shuffle mid-demo, so the box is reserved up front.
    expect((screen.getByTestId('evidence-refresh') as HTMLButtonElement).style.minWidth).toBe(idleWidth)
    expect(idleWidth).not.toBe('')

    release({ ok: true, status: 200, json: async () => payload([step()]) })
    await waitFor(() => expect(screen.queryByTestId('evidence-recheck-loader')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: /re-check/i })).toBeEnabled()
  })

  it('stops offering to hide commands once a failed re-check has emptied the chain', async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step()]) } as unknown as Response)
      .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) } as unknown as Response)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())
    await userEvent.click(screen.getByTestId('evidence-toggle-commands'))
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Hide commands')
    await userEvent.click(screen.getByTestId('evidence-refresh'))
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())
    // Nothing left to hide — offering it is a lie about what the button does.
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Show commands')
    expect(screen.getByTestId('evidence-toggle-commands')).toBeDisabled()
  })
})

// A control that looks like it works and does not is the exact failure this
// whole card exists to prevent, and the proof disclosure had one.
//
// The panel held the row state twice: a per-row `open` map and a global
// `showAllCommands` flag, combined as `showAllCommands || open[step]`. While the
// global flag was set, the `||` re-asserted "open" on every render no matter what
// the row map said, so after "Show commands" a row's own "Hide proof" wrote
// `open[step] = false` and changed nothing on screen. The row control was dead
// for as long as the global one was on.
//
// The fix is a single source of truth: the per-row map. The global button SEEDS
// it — open every row, or close every row — and then gets out of the way. No
// derived value may contradict a click.
describe('the global commands toggle seeds the rows rather than overriding them', () => {
  const twoSteps = () => payload([step(), step({ step: 2, label: 'SPIFFE Identity' })])
  const threeSteps = () => payload([step(), step({ step: 2 }), step({ step: 3 })])

  it('lets a row be hidden again after "Show commands" opened them all', async () => {
    // The reported defect, verbatim.
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(threeSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    expect(screen.getByTestId('evidence-console-2')).toBeInTheDocument()

    await user.click(screen.getByTestId('evidence-disclose-2'))

    expect(screen.queryByTestId('evidence-console-2')).not.toBeInTheDocument()
    // And only that row: hiding one proof is not hiding the walkthrough.
    expect(screen.getByTestId('evidence-console-1')).toBeInTheDocument()
    expect(screen.getByTestId('evidence-console-3')).toBeInTheDocument()
  })

  it('offers to hide the row it just closed, rather than reporting it still open', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(twoSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    expect(screen.getByTestId('evidence-disclose-1')).toHaveTextContent('Hide proof')
    await user.click(screen.getByTestId('evidence-disclose-1'))
    // The label is the tell: it read "Hide proof" over a closed console.
    expect(screen.getByTestId('evidence-disclose-1')).toHaveTextContent('How do we know?')
  })

  it('closes every row on "Hide commands"', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(threeSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    await user.click(screen.getByTestId('evidence-toggle-commands'))

    expect(screen.queryByTestId('evidence-console-1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('evidence-console-2')).not.toBeInTheDocument()
    expect(screen.queryByTestId('evidence-console-3')).not.toBeInTheDocument()
  })

  it('leaves each row working on its own after "Hide commands"', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(twoSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    await user.click(screen.getByTestId('evidence-toggle-commands'))
    await user.click(screen.getByTestId('evidence-disclose-2'))

    expect(screen.getByTestId('evidence-console-2')).toBeInTheDocument()
    expect(screen.queryByTestId('evidence-console-1')).not.toBeInTheDocument()
  })

  it('collapses a hand-opened row in one press, because that is what the label promises', async () => {
    // "Hide commands" appears as soon as ANY console is showing, so the label
    // always describes what the press does. A button reading "Show commands"
    // over five open rows would visibly do nothing when pressed — the same class
    // of dead control this fix exists to remove.
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(twoSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Show commands')
    await user.click(screen.getByTestId('evidence-disclose-1'))
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Hide commands')

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    expect(screen.queryByTestId('evidence-console-1')).not.toBeInTheDocument()
  })

  it('stops offering to hide once the last row has been hand-closed', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(twoSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    await user.click(screen.getByTestId('evidence-disclose-1'))
    // One still open, so there is still something to hide.
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Hide commands')
    await user.click(screen.getByTestId('evidence-disclose-2'))
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Show commands')
  })

  it('re-opens every row when pressed again after the rows were hand-closed', async () => {
    const user = userEvent.setup()
    render(<CredentialEvidencePanel fetcher={fetcherFor(twoSteps()) as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-toggle-commands'))
    await user.click(screen.getByTestId('evidence-disclose-1'))
    await user.click(screen.getByTestId('evidence-disclose-2'))
    await user.click(screen.getByTestId('evidence-toggle-commands'))

    expect(screen.getByTestId('evidence-console-1')).toBeInTheDocument()
    expect(screen.getByTestId('evidence-console-2')).toBeInTheDocument()
  })
})

// A Re-check replaces the steps. It does not replace the reader.
describe('a re-check keeps the rows the engineer opened', () => {
  it('leaves an open console open across a successful re-check', async () => {
    // Step 1 is step 1 before and after: the same six probes are re-run, and an
    // engineer watching one of them wants the NEW output in the place they were
    // already looking. Collapsing it mid-inspection is its own annoyance.
    const user = userEvent.setup()
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step(), step({ step: 2 })]) } as unknown as Response)
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step({ detail: 'second run' }), step({ step: 2 })]) } as unknown as Response)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-disclose-1'))
    await user.click(screen.getByTestId('evidence-refresh'))
    await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2))

    const console_ = await screen.findByTestId('evidence-console-1')
    expect(console_).toHaveTextContent('second run')
    expect(screen.queryByTestId('evidence-console-2')).not.toBeInTheDocument()
  })

  it('does not offer to hide a row that the re-check no longer returns', async () => {
    // The remembered state of a vanished step must not speak for rows on screen —
    // that is the same "a stale flag outranks what is rendered" fault, one level up.
    const user = userEvent.setup()
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step(), step({ step: 2 })]) } as unknown as Response)
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => payload([step()]) } as unknown as Response)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.click(screen.getByTestId('evidence-disclose-2'))
    await user.click(screen.getByTestId('evidence-refresh'))
    await waitFor(() => expect(screen.queryByTestId('evidence-step-2')).not.toBeInTheDocument())

    expect(screen.queryByTestId('evidence-console-2')).not.toBeInTheDocument()
    expect(screen.getByTestId('evidence-toggle-commands')).toHaveTextContent('Show commands')
  })
})

// The three badges are the whole epistemic claim of this card, and the
// dangerous confusion is "unverified" reading as "absent" — a probe that could
// not run reported as a probe that found nothing. The rows say WHICH state each
// step is in; only the hint says what the states mean, so it is load-bearing.
describe('the card explains its own vocabulary', () => {
  it('spells out the unverified/not-present distinction behind a keyboard-reachable "?"', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor(payload([step()]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    const hint = screen.getByRole('button', { name: 'What the three evidence badges mean' })
    hint.focus()
    expect(document.activeElement).toBe(hint)

    await user.hover(hint)
    const tooltip = await screen.findByRole('tooltip')
    // Naming all three is the point; naming two of them is the bug.
    expect(tooltip.textContent).toMatch(/observed/i)
    expect(tooltip.textContent).toMatch(/not present/i)
    expect(tooltip.textContent).toMatch(/unverified/i)
    // And it must say the two are not the same thing, not merely list them.
    expect(tooltip.textContent).toMatch(/not the same as absent/i)
  })

  it('explains the proof disclosure once, covering the per-row "How do we know?"', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor(payload([step()]))
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-step-1')).toBeInTheDocument())

    await user.hover(screen.getByTestId('evidence-commands-help'))
    const tooltip = await screen.findByRole('tooltip')
    expect(tooltip.textContent).toMatch(/How do we know\?/)
    expect(tooltip.textContent).toMatch(/command/i)
  })

  it('keeps explaining the badges when the probe failed and no rows rendered', async () => {
    const user = userEvent.setup()
    const fetcher = fetcherFor({}, false, 500)
    render(<CredentialEvidencePanel fetcher={fetcher as unknown as typeof fetch} />)
    await waitFor(() => expect(screen.getByTestId('evidence-error')).toBeInTheDocument())

    // An empty card is exactly when a viewer most needs to know that "nothing
    // shown" is not "nothing there".
    await user.hover(screen.getByTestId('evidence-states-help'))
    expect(await screen.findByRole('tooltip')).toHaveTextContent('nothing was proved either way')
  })
})
