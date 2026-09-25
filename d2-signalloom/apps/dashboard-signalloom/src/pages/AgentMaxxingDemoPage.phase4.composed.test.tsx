/**
 * AMXD-P4-GOV — Phase 4 composed-page integration assertions.
 *
 * Why this file exists, stated plainly so a later reader does not delete it as duplication:
 *
 * AMXD-P4-1 built the Stage 4 Adversarial Simulation panel. AMXD-P4-2 built the Stage 5
 * Attributable Revocation panel. Both shipped green suites. Neither suite could see the
 * seam between them, because each renders its own component in isolation:
 *
 *   - P4-1's restore test exercises Stage 4 ALONE. It cannot show that the estate is
 *     still clean after a run that continued into Stage 5 and then reset.
 *   - P4-2's 403 test drives a transport IT constructs, returning the body ITS author
 *     expected. It cannot show what the deployed backend actually returns.
 *
 * Every assertion below is about the JOIN or about measured live behaviour, not about a
 * component. A test that renders a single component cannot replace one of these.
 *
 * Follows the AMXD-P2-GOV precedent in AgentMaxxingDemoPage.composed.test.tsx.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import AgentMaxxingDemoPage from './AgentMaxxingDemoPage'
import { RevocationPanel } from '../components/demos/RevocationPanel'
import { createLiveBridge, type LiveTransport } from '../components/demos/bridge'
import { REVOCATION_RACE_PRESET } from '../components/demos/scenarios'
import { installMemoryStorage } from '../test-utils/memoryStorage'

const mockUser = vi.hoisted(() => ({ current: undefined as Record<string, unknown> | undefined }))
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: Boolean(mockUser.current),
    isLoading: false,
    getAccessTokenSilently: async () => '',
    user: mockUser.current,
  }),
}))

let store: Storage

beforeEach(() => {
  mockUser.current = { email: 'governor@control-plane.io', sub: 'oidc|p4gov' }
  store = installMemoryStorage()
})

/** Full byte-for-byte snapshot of every key the console can see. */
function snapshotEstate(s: Storage): string {
  const entries: Array<[string, string]> = []
  for (let i = 0; i < s.length; i += 1) {
    const k = s.key(i)
    if (k !== null) entries.push([k, s.getItem(k) ?? ''])
  }
  entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
  return JSON.stringify(entries)
}

/**
 * The stepper enforces AMXD-P1-1's disabled-during-async-transition contract, so a burst
 * of clicks is swallowed: the second lands while the first is still in flight and the
 * button is disabled. Each step must wait for its own panel to mount before the next
 * click, which is exactly what a human operator does and what AMXD-P2-GOV's suite does.
 */
const STAGE_PANEL_TESTID = [
  'token-issue-panel',
  'enrollment-panel',
  'stage-panel-confinement_streaming',
  'adversarial-simulation-panel',
  'revocation-panel',
] as const

/**
 * Demo state outlives a single render within a file: the console's bridge keeps its own
 * in-memory estate, so a page mounted after a prior test has already walked to Stage 5
 * comes up on Stage 5, not Stage 1. Every page test therefore starts from the console's
 * own documented idempotent operation — Reset Estate — rather than assuming a fresh
 * mount is a fresh estate. Assuming otherwise is precisely the order-dependence that
 * makes a state-machine suite flaky.
 */
async function ensureStage1(): Promise<void> {
  if (screen.queryByTestId('token-issue-panel')) return
  await act(async () => {
    fireEvent.click(screen.getByTestId('stepper-reset-button'))
  })
  await waitFor(() => {
    expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()
  })
}

async function advanceTo(stageNumber: 2 | 3 | 4 | 5): Promise<void> {
  await ensureStage1()
  for (let s = 2; s <= stageNumber; s += 1) {
    await waitFor(() => {
      expect(screen.getByTestId('stepper-advance-button')).not.toBeDisabled()
    })
    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => {
      expect(screen.getByTestId(STAGE_PANEL_TESTID[s - 1])).toBeInTheDocument()
    })
  }
}

describe('AMXD Phase 4 — estate survives a FULL Stage 4 -> Stage 5 -> Reset run', () => {
  /**
   * AMXD-P4-1's own restore test proves Stage 4 restores Stage 4. This proves the estate
   * is byte-identical after the run ALSO passed through Stage 5's revocation dispatch —
   * a stage P4-1's test never reaches, touching demo-session state P4-1 never accounted
   * for. The governor brief names exactly this gap.
   */
  it('leaves the estate byte-for-byte identical after tamper -> restore -> revoke -> reset', async () => {
    render(<AgentMaxxingDemoPage />)

    // Snapshot the baseline AFTER normalising to Stage 1, so `before` is the estate a
    // demo operator actually starts from, not whatever a prior test left behind.
    await ensureStage1()
    const before = snapshotEstate(store)

    // Stage 1 -> Stage 4.
    await advanceTo(4)

    // Inject all three AMXD-P4-1 controls, then restore all three.
    for (const kind of ['hash-mismatch', 'symlink-escape', 'oversized-write']) {
      await act(async () => {
        fireEvent.click(screen.getByTestId(`inject-${kind}-btn`))
      })
      await waitFor(() => {
        expect(screen.getByTestId(`containment-alert-${kind}`)).toBeInTheDocument()
      })
    }
    for (const kind of ['hash-mismatch', 'symlink-escape', 'oversized-write']) {
      await act(async () => {
        fireEvent.click(screen.getByTestId(`restore-${kind}-btn`))
      })
    }

    // Stage 4 -> Stage 5, and exercise the post-revocation upload attempt. Advancing the
    // stepper settles the revocation itself (see the RESIDUAL DEFECT block below), so the
    // reachable operator action at this stage is the upload attempt, not the dispatch.
    await advanceTo(5)
    await waitFor(() => {
      expect(screen.getByTestId('revocation-timeline')).toBeInTheDocument()
    })
    await act(async () => {
      fireEvent.click(screen.getByTestId('upload-attempt-trigger-btn'))
    })

    // Falsification guard. Without this the comparison below could pass vacuously —
    // empty-before, empty-after proves nothing about restore. Assert the run actually
    // DIRTIED the estate first, so the byte-for-byte equality has something to be about.
    const dirty = snapshotEstate(store)
    expect(dirty).not.toBe(before)

    // Reset Estate.
    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-reset-button'))
    })
    await waitFor(() => {
      expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()
    })

    // The whole point: not "roughly clean", byte-identical.
    expect(snapshotEstate(store)).toBe(before)
  })

  /**
   * The destructive-interaction check the brief asks for: a Reset Estate fired while a
   * revocation has already been dispatched must not leave the console on a revoked
   * stage, and must not strand revocation state in storage.
   */
  it('a reset mid-revocation returns to Stage 1 and strands no amxd.demo. key', async () => {
    render(<AgentMaxxingDemoPage />)

    await advanceTo(5)
    await act(async () => {
      fireEvent.click(screen.getByTestId('upload-attempt-trigger-btn'))
    })

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-reset-button'))
    })
    await waitFor(() => {
      expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()
    })

    const stranded: string[] = []
    for (let i = 0; i < store.length; i += 1) {
      const k = store.key(i)
      if (k && k.startsWith('amxd.demo.')) stranded.push(k)
    }
    expect(stranded).toEqual([])
  })
})

describe('AMXD Phase 4 — the two panels compose without collision', () => {
  /**
   * Structural fact the brief assumed otherwise: AgentMaxxingDemoPage renders Stage 4
   * and Stage 5 in MUTUALLY EXCLUSIVE branches (`activeViewStage === ...`). They are
   * never in the DOM together, so a shared data-testid could not collide at runtime even
   * if one existed. This pins that property — if a later card co-renders them, the
   * duplicate-id assertion below starts doing real work.
   */
  it('never renders the Stage 4 and Stage 5 panels simultaneously', async () => {
    render(<AgentMaxxingDemoPage />)

    await advanceTo(4)
    expect(screen.queryByTestId('revocation-panel')).not.toBeInTheDocument()

    await advanceTo(5)
    expect(screen.queryByTestId('adversarial-simulation-panel')).not.toBeInTheDocument()
  })

  it('emits no duplicate data-testid in the composed DOM at Stage 4 or Stage 5', async () => {
    const { container } = render(<AgentMaxxingDemoPage />)

    const duplicatesAt = (): string[] => {
      const seen = new Map<string, number>()
      container.querySelectorAll('[data-testid]').forEach((el) => {
        const id = el.getAttribute('data-testid') as string
        if (id === 'streaming-log-line' || id.endsWith('-line')) return
        seen.set(id, (seen.get(id) ?? 0) + 1)
      })
      return Array.from(seen.entries())
        .filter(([, n]) => n > 1)
        .map(([id]) => id)
    }

    await advanceTo(4)
    expect(duplicatesAt()).toEqual([])

    await advanceTo(5)
    expect(duplicatesAt()).toEqual([])
  })
})

describe('AMXD Phase 4 — RESIDUAL DEFECT: the attributable dispatch is unreachable', () => {
  /**
   * The proposal's architectural constitution promises: "Revoking the agent issues an
   * authenticated POST ... with an operator attribution reason; the subsequent upload
   * assertion visibly fails with 403 Forbidden and updates the timeline with an immutable
   * red badge."
   *
   * AMXD-P4-2's own suite proves the panel CAN do that — it renders the panel directly,
   * with no payload, so `revocationSettled` is false and the form is present. The composed
   * page reaches Stage 5 only through the stepper, which settles the revocation stage and
   * feeds the result back as `initialPayload`. RevocationPanel gates its whole form on
   * `!revocationSettled` (RevocationPanel.tsx:709), so on the route an operator actually
   * uses, the reason selector and the dispatch button never render — and neither does the
   * denial badge.
   *
   * Neither card's suite could see this: P4-2 never renders the page, and the page's own
   * Phase 2 suite never reaches Stage 5. It is asserted here as CURRENT behaviour so it is
   * pinned rather than described; when it is fixed, this test flips and must be updated.
   */
  it('renders no reason selector and no dispatch button at Stage 5 on the composed page', async () => {
    render(<AgentMaxxingDemoPage />)
    await advanceTo(5)

    expect(screen.getByTestId('revocation-panel')).toBeInTheDocument()
    expect(screen.getByTestId('revocation-timeline')).toBeInTheDocument()

    // THE DEFECT, reproduced: the attributable controls are absent on the composed route.
    expect(screen.queryByTestId('revocation-reason-select')).not.toBeInTheDocument()
    expect(screen.queryByTestId('revocation-dispatch-btn')).not.toBeInTheDocument()
    // And the constitution's "immutable red badge" is not rendered on this path either.
    expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
  })
})

describe('AMXD Phase 4 — RESIDUAL DEFECT: live mode cannot reach 403 agent_revoked', () => {
  /**
   * This is the reproducing test for the defect AMXD-P4-GOV hands to AMXD-P5-GOV.
   *
   * A governor must not assert a defect it cannot demonstrate. AMXD-P4-2's own suite
   * drives a transport that returns `{"error":{"code":"agent_revoked"}}` — the body its
   * author expected. The DEPLOYED backend, measured on kind-osramp against
   * fe-signalloom-api on 2026-09-15, returns something else entirely for the exact
   * request the panel makes:
   *
   *   POST /v1/external-agents/evidence-uploads   (RevocationPanel.tsx:256)
   *   Authorization: Bearer <Dex operator id_token>
   *   -> HTTP 403
   *      {"error":{"code":"insufficient_scope",
   *                "message":"Host credential has scope 'None', required 'audit-upload-only'"}}
   *
   * Cause, traced rather than guessed: that route is gated by
   * `authenticated_host_credential` (host_credential.py:345), which calls
   * `verify_host_credential(..., required_scope=AUDIT_UPLOAD_SCOPE, check_revocation=True)`.
   * The SCOPE gate precedes the revocation check, and `_check_agent_revocation` — the
   * sole raiser of `agent_revoked` (host_credential.py:209,225) — is reached only from
   * host_credential.py:323, i.e. only once a host-credential JWT has already passed the
   * scope gate. `RevocationPanel` sends `hostCredentialToken || token`, and
   * `hostCredentialToken` is a prop NO caller ever supplies, so live mode always sends
   * the operator token and always stops at the scope gate.
   *
   * The body below is the VERBATIM measured response, not a guess. This test asserts the
   * CURRENT behaviour deliberately: `confirmed` is false and no agent_revoked badge
   * renders. When the credential bootstrap lands, this test flips and must be updated —
   * which is the point: the defect is pinned, not described.
   */
  const MEASURED_LIVE_403_BODY = {
    error: {
      code: 'insufficient_scope',
      message: "Host credential has scope 'None', required 'audit-upload-only'",
    },
  } as const

  function transportReturningMeasuredBody(): LiveTransport {
    return {
      fetch: vi.fn(
        async () =>
          new Response(JSON.stringify({ status: 'revoked', host_id: 'h', count: 1 }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          }),
      ),
      req: vi.fn(async () => {
        throw Object.assign(new Error('Forbidden'), {
          status: 403,
          response: { status: 403, data: MEASURED_LIVE_403_BODY },
        })
      }),
    }
  }

  it('does not confirm denial when the deployed backend answers insufficient_scope', async () => {
    const user = userEvent.setup()
    const transport = transportReturningMeasuredBody()
    const bridge = createLiveBridge({ preset: REVOCATION_RACE_PRESET, transport })

    render(
      <RevocationPanel
        bridge={bridge}
        preset={REVOCATION_RACE_PRESET}
        transport={transport}
        token="dex-operator-id-token"
      />,
    )

    await user.selectOptions(
      screen.getByTestId('revocation-reason-select'),
      'credential-compromise',
    )
    await act(async () => {
      fireEvent.click(screen.getByTestId('revocation-dispatch-btn'))
    })

    // The measured code is neither `agent_revoked` nor one of the four documented
    // binding-mismatch codes, so the panel can claim neither outcome.
    await waitFor(() => {
      expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
    })
    expect(screen.queryByTestId('revocation-binding-mismatch-warning')).not.toBeInTheDocument()
  })

  it('the measured code is outside both sets the panel knows how to classify', () => {
    const BINDING_MISMATCH_CODES = [
      'tenant_key_binding_mismatch',
      'tenant_agent_binding_mismatch',
      'tenant_host_binding_mismatch',
      'cross_tenant_forbidden',
    ]
    const measured = MEASURED_LIVE_403_BODY.error.code

    expect(measured).not.toBe('agent_revoked')
    expect(BINDING_MISMATCH_CODES).not.toContain(measured)
  })
})
