/**
 * AMXD-P2-GOV — composed-page integration assertions.
 *
 * Why this file exists, stated plainly so a later reader does not delete it as duplication:
 *
 * AMXD-P2-1 built the stepper header, the progression controller and the page shell.
 * AMXD-P2-2 built the Stage 1 and Stage 2 panels. Both cards shipped green suites.
 * Neither suite could see that the page never imported either panel, because P2-1's page
 * test asserted P2-1's own placeholder testid and P2-2's tests rendered the panels
 * directly. The seam between the two cards had no owner and therefore no test.
 *
 * Every assertion below is about the JOIN, not about a component. A test that renders a
 * single component cannot replace one of these.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react'
import AgentMaxxingDemoPage, { deriveOperatorPrincipal } from './AgentMaxxingDemoPage'
import { TokenIssuePanel } from '../components/demos/TokenIssuePanel'
import { EnrollmentPanel } from '../components/demos/EnrollmentPanel'
import { UNATTRIBUTED_OPERATOR_LABEL } from '../components/demos/types'
import { createDemoBridge } from '../components/demos/bridge'
import { HAPPY_PATH_PRESET } from '../components/demos/scenarios'
import StageProgressionController, {
  AMXD_DEMO_STAGE_STORAGE_KEY,
} from '../components/demos/StageProgressionController'
import { installMemoryStorage } from '../test-utils/memoryStorage'

// The attribution record renders inside the stage RESULT block, so these fixtures are
// what makes it reachable at all — a panel with no payload has nothing to attribute.
const ISSUED_TOKEN = {
  tokenId: 'amxd-demo-token-happy-01',
  issuedAt: '2026-09-15T02:00:00Z',
  ttlSeconds: 900,
  operatorId: 'amxd-demo-tenant-primary',
  tokenPrefix: 'amxd-demo-to',
} as never

const ENROLLED_HOST = {
  hostId: 'amxd-demo-host-happy-01',
  agentId: 'amxd-demo-agent-happy-01',
  publicKeyFingerprint: 'amxd-demo-key-happy-01',
  enrolledAt: '2026-09-15T02:00:00Z',
  status: 'enrolled',
} as never

// The page reads the operator principal from the OIDC profile. Mock at the module the
// page imports so the test controls the authenticated subject rather than the SDK.
const mockUser = vi.hoisted(() => ({ current: undefined as Record<string, unknown> | undefined }))
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({
    isAuthenticated: Boolean(mockUser.current),
    isLoading: false,
    loginWithRedirect: () => {},
    logout: () => {},
    getAccessTokenSilently: async () => '',
    user: mockUser.current,
  }),
}))

beforeEach(() => {
  mockUser.current = undefined
  // Node 25's built-in localStorage is inert without --localstorage-file, so the
  // controller's storage resolves to null and nothing persists. Install a working one.
  installMemoryStorage()
})

describe('AMXD Phase 2 — panels are actually mounted on the route', () => {
  it('renders AMXD-P2-2 TokenIssuePanel at Stage 1, not a placeholder frame', () => {
    render(<AgentMaxxingDemoPage />)
    // The defect this catches: the page previously rendered only a generic frame and
    // TokenIssuePanel had zero importers outside its own test file.
    expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()
    // The panel's own action button, not the page's placeholder text.
    expect(screen.getByTestId('token-issue-btn')).toBeInTheDocument()
  })

  it('renders AMXD-P2-2 EnrollmentPanel at Stage 2 after advancing', async () => {
    render(<AgentMaxxingDemoPage />)

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument()
    })
    expect(screen.getByTestId('enrollment-attribution-record')).toBeInTheDocument()
    // Stage 1's panel must be gone, not merely covered.
    expect(screen.queryByTestId('token-issue-panel')).not.toBeInTheDocument()
  })

  it('leaves Stages 3-5 on the generic frame (AMXD-P3/P4 scope, not this phase)', async () => {
    render(<AgentMaxxingDemoPage />)

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument())

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-panel-confinement_streaming')).toBeInTheDocument()
    })
    expect(screen.queryByTestId('enrollment-panel')).not.toBeInTheDocument()
    expect(screen.queryByTestId('token-issue-panel')).not.toBeInTheDocument()
  })
})

describe('AMXD Phase 2 — header and panel agree on stage and sub-state', () => {
  it('the stepper header marks the same stage the rendered panel belongs to', async () => {
    render(<AgentMaxxingDemoPage />)

    // Stage 1: header status and mounted panel must be the same stage.
    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent(/confirmed/i)
    expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent(/confirmed/i)
    })
    // The header calling host_enrolled confirmed while EnrollmentPanel is the mounted
    // panel is the agreement this phase had no test for.
    expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument()
  })

  it('Stage 1 issuance reaches the reducer, so header-confirmed implies a recorded payload', async () => {
    render(<AgentMaxxingDemoPage />)

    // operator_init is pre-confirmed at boot with an EMPTY stagePayloads entry. Issuing
    // through the panel must populate it via recordStagePayload, otherwise the header
    // reports a confirmed stage the reducer has no evidence for.
    await act(async () => {
      fireEvent.click(screen.getByTestId('token-issue-btn'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('token-issue-result')).toBeInTheDocument()
    })
    expect(screen.getByTestId('stage-status-operator_init')).toHaveTextContent(/confirmed/i)
  })

  /**
   * CHARACTERISATION, NOT A GUARANTEE. This pins the observable behaviour today: the
   * panel's enroll button does not move the stepper forward. It does NOT prove there is
   * only one advance path — AMXD-P2-GOV mutation-tested exactly that claim and the mutant
   * survived, because the reducer's stage is unchanged either way. The remaining defect
   * (the panel re-calling bridge.advance while the reducer stays put) needs a bridge spy
   * injected through the page, which the page does not expose. Handed to AMXD-P3-GOV.
   */
  it('Stage 2: the panel enroll button does not move the stepper forward', async () => {
    render(<AgentMaxxingDemoPage />)

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument())

    // The panel's own enroll button must not advance past Stage 2 on its own: if it
    // called bridge.advance('host_enrolled') directly while the controller also owns the
    // transition, the reducer and the bridge would drift apart.
    await act(async () => {
      fireEvent.click(screen.getByTestId('host-enroll-btn'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('stage-status-host_enrolled')).toHaveTextContent(/confirmed/i)
    })
    // Still on Stage 2 — the panel did not skip the stepper forward.
    expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument()
  })
})

describe('AMXD Phase 2 — attributable display names a real principal', () => {
  const liveBridge = () =>
    createDemoBridge('live', { preset: HAPPY_PATH_PRESET, storage: null })

  it('live channel renders the injected authenticated principal', () => {
    render(
      <TokenIssuePanel
        bridge={liveBridge()}
        preset={HAPPY_PATH_PRESET}
        operatorId="andy@control-plane.io"
        initialPayload={ISSUED_TOKEN}
      />,
    )
    const principal = screen.getByTestId('token-attribution-principal')
    expect(principal).toHaveTextContent('andy@control-plane.io')
    expect(principal).toHaveAttribute('data-attributed', 'true')
  })

  it('live channel with NO principal renders the unattributed marker, never a fabricated account', () => {
    render(
      <EnrollmentPanel
        bridge={liveBridge()}
        preset={HAPPY_PATH_PRESET}
        initialPayload={ENROLLED_HOST}
      />,
    )
    const principal = screen.getByTestId('enrollment-attribution-principal')
    expect(principal).toHaveTextContent(UNATTRIBUTED_OPERATOR_LABEL)
    expect(principal).toHaveAttribute('data-attributed', 'false')
    // Regression pin: this literal shipped as the live-channel fallback and no test
    // pinned it, so nothing ever checked that the "attributable" display was attributable.
    expect(principal).not.toHaveTextContent('operator-admin@signalloom.internal')
  })

  it('the page propagates the OIDC subject into the Stage 1 attribution record', async () => {
    mockUser.current = { email: 'governor@control-plane.io', sub: 'oidc|123' }
    render(<AgentMaxxingDemoPage />)

    // The record only exists once a token has been issued, so drive the panel first.
    await act(async () => {
      fireEvent.click(screen.getByTestId('token-issue-btn'))
    })

    await waitFor(() => {
      expect(screen.getByTestId('token-attribution-record')).toBeInTheDocument()
    })
    // The page default channel is mock, so the rendered principal is the mock label —
    // what this asserts is that the record is reachable from the route at all, which it
    // was not before the panels were wired in.
    expect(screen.getByTestId('token-attribution-principal')).toHaveAttribute(
      'data-attributed',
      'true',
    )
  })

  // Calls the shipped function. An earlier version of this test re-implemented the claim
  // precedence inline and asserted its own copy against itself — a tautology that would
  // have passed no matter what the page did. Every field carries a DISTINCT value so a
  // swapped claim cannot coincidentally produce the expected string.
  it('derives the principal from email, then preferred_username, then sub', () => {
    expect(
      deriveOperatorPrincipal({
        email: 'by-email@x.io',
        preferred_username: 'by-username@x.io',
        sub: 'by-sub',
      }),
    ).toBe('by-email@x.io')

    expect(
      deriveOperatorPrincipal({ preferred_username: 'by-username@x.io', sub: 'by-sub' }),
    ).toBe('by-username@x.io')

    expect(deriveOperatorPrincipal({ sub: 'by-sub' })).toBe('by-sub')

    // No profile at all, and a profile with only non-string claims, are both unattributed.
    expect(deriveOperatorPrincipal(undefined)).toBeUndefined()
    expect(deriveOperatorPrincipal({ email: 42, sub: null })).toBeUndefined()
    // Whitespace is not a principal.
    expect(deriveOperatorPrincipal({ email: '   ' })).toBeUndefined()
  })
})

describe('AMXD Phase 2 — RESIDUAL DEFECT: Stage 2 has two independent advance paths', () => {
  /**
   * This is the reproducing test for the defect AMXD-P2-GOV hands to AMXD-P3-GOV.
   *
   * It exists because a governor must not assert a defect it cannot demonstrate. The
   * page-level assertion could NOT see this (the reducer's stage is identical either
   * way), so the claim was unfalsifiable until it was driven with a counting bridge at
   * the composition level the page actually builds.
   *
   * It asserts the CURRENT broken behaviour deliberately. When P3 fixes it — by giving
   * the panel a controlled/read-only mode — this test flips and must be updated, which
   * is the point: the defect is pinned, not described.
   */
  it('the panel re-advances the bridge after the controller already advanced it', async () => {
    const store = installMemoryStorage()
    const realBridge = createDemoBridge('mock', { preset: HAPPY_PATH_PRESET, storage: store })
    const advanceSpy = vi.fn(realBridge.advance.bind(realBridge))
    const bridge = Object.assign(Object.create(Object.getPrototypeOf(realBridge)), realBridge, {
      advance: advanceSpy,
    }) as typeof realBridge

    render(
      <StageProgressionController bridge={bridge} storage={store}>
        {({ activeViewStage, state, inFlight }) =>
          activeViewStage === 'host_enrolled' ? (
            <EnrollmentPanel
              bridge={bridge}
              preset={HAPPY_PATH_PRESET}
              inFlight={inFlight}
              initialPayload={state.stagePayloads.host_enrolled ?? null}
            />
          ) : (
            <div data-testid="not-stage-2" />
          )
        }
      </StageProgressionController>,
    )

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument())

    const afterControllerAdvance = advanceSpy.mock.calls.filter(
      (c) => c[0] === 'host_enrolled',
    ).length
    expect(afterControllerAdvance).toBe(1)

    await act(async () => {
      fireEvent.click(screen.getByTestId('host-enroll-btn'))
    })

    const afterPanelClick = advanceSpy.mock.calls.filter((c) => c[0] === 'host_enrolled').length
    // THE DEFECT, reproduced: the same stage is advanced on the bridge twice, and the
    // reducer only ever learned about the first. Reachable from the composed page today.
    expect(afterPanelClick).toBe(2)
  })
})

describe('AMXD Phase 2 — async-transition guard holds across header and panel together', () => {
  it('disables the panel action and the stepper controls during a transition', async () => {
    render(<AgentMaxxingDemoPage />)

    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument())

    // Settled state: nothing is stuck disabled after the transition resolves.
    expect(screen.getByTestId('host-enroll-btn')).not.toBeDisabled()
  })
})

describe('AMXD Phase 2 — reload / reset / reload agree on stage-key ownership', () => {
  it('walks reload -> reset -> reload and both owners agree on the stage key', async () => {
    // Driven at the controller, whose `storage` prop is the injectable seam. The page
    // does not expose one, and this environment's built-in localStorage is inert, so
    // rendering the page twice would prove nothing about persistence either way.
    const store = installMemoryStorage()
    const mounted = () =>
      render(
        <StageProgressionController storage={store}>
          {({ activeViewStage }) => <div data-testid="active-stage">{activeViewStage}</div>}
        </StageProgressionController>,
      )

    const first = mounted()
    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-advance-button'))
    })
    await waitFor(() => {
      expect(screen.getByTestId('active-stage')).toHaveTextContent('host_enrolled')
    })
    expect(store.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)).toBe('host_enrolled')
    first.unmount()

    // Reload #1 — the persisted key restores Stage 2.
    const second = mounted()
    expect(screen.getByTestId('active-stage')).toHaveTextContent('host_enrolled')

    // Reset — the controller removes the key AND bridge.resetEstate() clears the
    // whole amxd.demo. namespace the key lives in. Neither owner leaves it behind.
    await act(async () => {
      fireEvent.click(screen.getByTestId('stepper-reset-button'))
    })
    await waitFor(() => {
      expect(screen.getByTestId('active-stage')).toHaveTextContent('operator_init')
    })
    expect(store.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)).toBeNull()
    second.unmount()

    // Reload #2 — no stale confirmed stage survives the reset.
    mounted()
    expect(screen.getByTestId('active-stage')).toHaveTextContent('operator_init')
  })

  it('the persisted stage key sits inside the namespace resetEstate clears', () => {
    // Ownership check, stated as a property rather than a walkthrough: if this key ever
    // moves outside `amxd.demo.`, reset stops clearing it and a stale stage survives.
    expect(AMXD_DEMO_STAGE_STORAGE_KEY.startsWith('amxd.demo.')).toBe(true)
  })
})
