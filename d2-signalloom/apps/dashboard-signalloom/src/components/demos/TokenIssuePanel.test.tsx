import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { TokenIssuePanel } from './TokenIssuePanel'
import {
  createMockBridge,
  createLiveBridge,
  type LiveTransport,
  type MockDemoBridge,
  type LiveDemoBridge,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  type ScenarioPreset,
} from './scenarios'

function happyTransport(): LiveTransport {
  return {
    req: vi.fn(async () => ({
      tokenId: 'amxd-demo-token-happy-01',
      issuedAt: '2026-09-15T02:00:00Z',
      ttlSeconds: 900,
      operatorId: 'amxd-demo-tenant-primary',
      tokenPrefix: 'amxd-demo-to',
      identity_token: 'jwt.live.secret.header.payload.signature',
    })),
    fetch: vi.fn(async () => new Response(JSON.stringify({}), { status: 200 })),
  }
}

function failureTransport(errorMessage = 'Already enrolled'): LiveTransport {
  return {
    req: vi.fn(async () => {
      throw Object.assign(new Error(errorMessage), { status: 409 })
    }),
    fetch: vi.fn(async () => new Response(JSON.stringify({ error: errorMessage }), { status: 409 })),
  }
}

describe('TokenIssuePanel (Stage 1: Token Issue)', () => {
  let mockBridge: MockDemoBridge
  let liveBridge: LiveDemoBridge

  beforeEach(() => {
    mockBridge = createMockBridge({ preset: HAPPY_PATH_PRESET, latencyMs: 0 })
    liveBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: happyTransport(),
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders initial stage 1 layout with primary button and target endpoint', () => {
    render(<TokenIssuePanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

    expect(screen.getByTestId('token-issue-panel')).toBeInTheDocument()
    expect(screen.getByTestId('token-issue-btn')).toBeInTheDocument()
    expect(screen.getByTestId('token-issue-btn')).toHaveTextContent('Issue Token')
    expect(screen.getByTestId('token-channel-badge')).toHaveTextContent('Mock fixture')
    expect(
      screen.getByText('/api/v1/external-agents/registrations/amxd-demo-agent-happy-01/token', {
        exact: false,
      })
    ).toBeInTheDocument()
  })

  it('issues token and renders attributable issuance record and results', async () => {
    const user = userEvent.setup()
    render(<TokenIssuePanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

    const btn = screen.getByTestId('token-issue-btn')
    await user.click(btn)

    await waitFor(() => {
      expect(screen.getByTestId('token-issue-result')).toBeInTheDocument()
    })

    expect(screen.getByTestId('token-attribution-record')).toBeInTheDocument()
    expect(screen.getByTestId('token-attribution-record')).toHaveTextContent('Mock Operator')
    expect(screen.getByTestId('token-attribution-record')).toHaveTextContent(
      'amxd-demo-tenant-primary'
    )
    expect(screen.getByTestId('token-ttl-countdown')).toBeInTheDocument()
  })

  it('enforces double-click protection and disables button during async transition', async () => {
    // Create a bridge with a controllable delay
    let resolveAdvance: () => void = () => {}
    const delayedAdvance = vi.fn(
      () =>
        new Promise<any>((resolve) => {
          resolveAdvance = () =>
            resolve({
              channelKind: 'mock',
              status: 'ok',
              stage: 'operator_init',
              payload: {
                tokenId: 'token-01',
                issuedAt: '2026-09-15T02:00:00Z',
                ttlSeconds: 900,
                operatorId: 'tenant-1',
                tokenPrefix: 'token-01',
              },
              declaredHttpStatus: 201,
              fixtureId: 'f-1',
            })
        })
    )
    const customBridge = {
      ...mockBridge,
      advance: delayedAdvance,
    }

    const { rerender } = render(
      <TokenIssuePanel bridge={customBridge as unknown as MockDemoBridge} />
    )
    const btn = screen.getByTestId('token-issue-btn')

    // First click initiates transition
    await act(async () => {
      btn.click()
    })

    // Button should now be disabled
    expect(btn).toBeDisabled()
    expect(btn).toHaveTextContent('Issuing Token...')

    // Second rapid click while in-flight
    await act(async () => {
      btn.click()
    })

    // Advance called only once
    expect(delayedAdvance).toHaveBeenCalledTimes(1)

    // Complete transition
    await act(async () => {
      resolveAdvance()
    })

    await waitFor(() => {
      expect(screen.getByTestId('token-issue-result')).toBeInTheDocument()
    })

    // Prop-driven inFlight also disables button
    rerender(
      <TokenIssuePanel
        bridge={customBridge as unknown as MockDemoBridge}
        inFlight={true}
      />
    )
    expect(screen.getByTestId('token-issue-btn')).toBeDisabled()
  })

  it('proves "shown once, then gone" contract across unmount and remount', async () => {
    const user = userEvent.setup()
    const { unmount } = render(
      <TokenIssuePanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />
    )

    // Issue token in initial mount
    const btn = screen.getByTestId('token-issue-btn')
    await user.click(btn)

    await waitFor(() => {
      expect(screen.getByTestId('token-secret-container')).toBeInTheDocument()
    })
    expect(screen.getByTestId('token-secret-value')).toHaveTextContent('eyJh-token')

    // Unmount component simulating navigation away
    unmount()

    // Remount component with persisted initialPayload from outer stepper state
    render(
      <TokenIssuePanel
        bridge={mockBridge}
        preset={HAPPY_PATH_PRESET}
        initialPayload={{
          tokenId: 'amxd-demo-token-happy-01',
          issuedAt: '2026-09-15T02:00:00Z',
          ttlSeconds: 900,
          operatorId: 'amxd-demo-tenant-primary',
          tokenPrefix: 'amxd-demo-tok',
        }}
      />
    )

    // Verify token result displays metadata, but raw secret token is GONE
    expect(screen.getByTestId('token-issue-result')).toBeInTheDocument()
    expect(screen.queryByTestId('token-secret-container')).not.toBeInTheDocument()
    expect(querySecretToken(screen)).toBeNull()
    expect(screen.getByTestId('token-secret-gone')).toBeInTheDocument()
    expect(screen.getByTestId('token-secret-gone')).toHaveTextContent(
      'shown once upon issuance and is no longer available'
    )
  })

  it('updates ticking TTL countdown decrements over time', async () => {
    vi.useFakeTimers()
    const now = new Date('2026-09-15T02:00:00Z').getTime()
    vi.setSystemTime(now)

    render(
      <TokenIssuePanel
        bridge={mockBridge}
        preset={HAPPY_PATH_PRESET}
        initialPayload={{
          tokenId: 'amxd-demo-token-happy-01',
          issuedAt: '2026-09-15T02:00:00Z',
          ttlSeconds: 900,
          operatorId: 'amxd-demo-tenant-primary',
          tokenPrefix: 'amxd-demo-tok',
        }}
      />
    )

    const countdown = screen.getByTestId('token-ttl-countdown')
    expect(countdown).toHaveTextContent('15:00')

    // Advance 5 seconds
    act(() => {
      vi.advanceTimersByTime(5000)
    })
    expect(countdown).toHaveTextContent('14:55')

    // Advance to expiration (900 seconds total)
    act(() => {
      vi.advanceTimersByTime(895000)
    })
    expect(countdown).toHaveTextContent('00:00 (Expired)')
  })

  it('renders real backend error on live failure instead of generic error', async () => {
    const errorBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: failureTransport('Host amxd-demo-agent-happy-01 is already enrolled in cluster'),
    })

    const user = userEvent.setup()
    render(<TokenIssuePanel bridge={errorBridge} preset={HAPPY_PATH_PRESET} />)

    await user.click(screen.getByTestId('token-issue-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('token-issue-error')).toBeInTheDocument()
    })
    expect(screen.getByTestId('token-issue-error')).toHaveTextContent(
      'Host amxd-demo-agent-happy-01 is already enrolled in cluster'
    )
  })

  it('renders structurally identical output for mock and live channels on Happy Path preset', async () => {
    const user = userEvent.setup()

    // Render mock panel
    const { container: mockContainer, unmount: unmountMock } = render(
      <TokenIssuePanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />
    )
    await user.click(screen.getByTestId('token-issue-btn'))
    await waitFor(() => expect(screen.getByTestId('token-issue-result')).toBeInTheDocument())

    const mockTestIds = extractTestIds(mockContainer)
    unmountMock()

    // Render live panel
    const { container: liveContainer } = render(
      <TokenIssuePanel bridge={liveBridge} preset={HAPPY_PATH_PRESET} />
    )
    await user.click(screen.getByTestId('token-issue-btn'))
    await waitFor(() => expect(screen.getByTestId('token-issue-result')).toBeInTheDocument())

    const liveTestIds = extractTestIds(liveContainer)

    // Structural equivalence: identical set of testids
    expect(mockTestIds).toEqual(liveTestIds)
  })
})

function querySecretToken(s: typeof screen): HTMLElement | null {
  return s.queryByTestId('token-secret-value')
}

function extractTestIds(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll('[data-testid]'))
    .map((el) => el.getAttribute('data-testid') || '')
    .filter(Boolean)
    .sort()
}
