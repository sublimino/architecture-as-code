import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { EnrollmentPanel } from './EnrollmentPanel'
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
      hostId: 'amxd-demo-host-happy-01',
      agentId: 'amxd-demo-agent-happy-01',
      publicKeyFingerprint: 'amxd-demo-key-happy-01',
      enrolledAt: '2026-09-15T02:00:00Z',
      status: 'enrolled',
      key_algorithm: 'Ed25519',
      revocation_endpoint: '/v1/external-agents/amxd-demo-agent-happy-01/revocations',
    })),
    fetch: vi.fn(async () => new Response(JSON.stringify({}), { status: 200 })),
  }
}

function failureTransport(errorMessage = 'Host enrollment rejected'): LiveTransport {
  return {
    req: vi.fn(async () => {
      throw Object.assign(new Error(errorMessage), { status: 400 })
    }),
    fetch: vi.fn(async () => new Response(JSON.stringify({ error: errorMessage }), { status: 400 })),
  }
}

describe('EnrollmentPanel (Stage 2: Host Ed25519 Enrollment)', () => {
  let mockBridge: MockDemoBridge
  let liveBridge: LiveDemoBridge

  beforeEach(() => {
    mockBridge = createMockBridge({ preset: HAPPY_PATH_PRESET, latencyMs: 0 })
    liveBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: happyTransport(),
    })
  })

  it('renders initial stage 2 layout with primary button and target endpoint', () => {
    render(<EnrollmentPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

    expect(screen.getByTestId('enrollment-panel')).toBeInTheDocument()
    expect(screen.getByTestId('host-enroll-btn')).toBeInTheDocument()
    expect(screen.getByTestId('host-enroll-btn')).toHaveTextContent('Enroll Host')
    expect(screen.getByTestId('enrollment-channel-badge')).toHaveTextContent('Mock fixture')
    expect(screen.getByText('POST /api/v1/external-agents/enroll')).toBeInTheDocument()
  })

  it('enrolls host and renders Ed25519 key algorithm badge and revocation endpoint', async () => {
    const user = userEvent.setup()
    render(<EnrollmentPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

    await user.click(screen.getByTestId('host-enroll-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('enrollment-result')).toBeInTheDocument()
    })

    // Ed25519 badge verification
    const algoBadge = screen.getByTestId('key-algorithm-badge')
    expect(algoBadge).toBeInTheDocument()
    expect(algoBadge).toHaveTextContent('Ed25519')

    // Read-only revocation endpoint verification
    const revEndpoint = screen.getByTestId('revocation-endpoint')
    expect(revEndpoint).toBeInTheDocument()
    expect(revEndpoint).toHaveTextContent(
      '/v1/external-agents/amxd-demo-agent-happy-01/revocations'
    )
    expect(revEndpoint).toHaveAttribute('aria-readonly', 'true')
    expect(revEndpoint.tagName.toLowerCase()).not.toBe('input')

    // Attributable enrollment record
    const attr = screen.getByTestId('enrollment-attribution-record')
    expect(attr).toBeInTheDocument()
    expect(attr).toHaveTextContent('Mock Operator')
    expect(attr).toHaveTextContent('amxd-demo-tenant-primary')
    expect(attr).toHaveTextContent('amxd-demo-host-happy-01')
    expect(attr).toHaveTextContent('amxd-demo-agent-happy-01')
  })

  it('enforces double-click protection and disables button during async transition', async () => {
    let resolveAdvance: () => void = () => {}
    const delayedAdvance = vi.fn(
      () =>
        new Promise<any>((resolve) => {
          resolveAdvance = () =>
            resolve({
              channelKind: 'mock',
              status: 'ok',
              stage: 'host_enrolled',
              payload: {
                hostId: 'host-01',
                agentId: 'agent-01',
                publicKeyFingerprint: 'key-01',
                enrolledAt: '2026-09-15T02:00:00Z',
                status: 'enrolled',
              },
              declaredHttpStatus: 201,
              fixtureId: 'f-2',
            })
        })
    )
    const customBridge = {
      ...mockBridge,
      advance: delayedAdvance,
    }

    const { rerender } = render(
      <EnrollmentPanel bridge={customBridge as unknown as MockDemoBridge} />
    )
    const btn = screen.getByTestId('host-enroll-btn')

    await act(async () => {
      btn.click()
    })

    expect(btn).toBeDisabled()
    expect(btn).toHaveTextContent('Enrolling Host...')

    // Second click ignored
    await act(async () => {
      btn.click()
    })

    expect(delayedAdvance).toHaveBeenCalledTimes(1)

    await act(async () => {
      resolveAdvance()
    })

    await waitFor(() => {
      expect(screen.getByTestId('enrollment-result')).toBeInTheDocument()
    })

    rerender(
      <EnrollmentPanel
        bridge={customBridge as unknown as MockDemoBridge}
        inFlight={true}
      />
    )
    expect(screen.getByTestId('host-enroll-btn')).toBeDisabled()
  })

  it('renders real backend error on live enrollment failure', async () => {
    const errorBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: failureTransport('Host public key already bound to another tenant'),
    })

    const user = userEvent.setup()
    render(<EnrollmentPanel bridge={errorBridge} preset={HAPPY_PATH_PRESET} />)

    await user.click(screen.getByTestId('host-enroll-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('enrollment-error')).toBeInTheDocument()
    })
    expect(screen.getByTestId('enrollment-error')).toHaveTextContent(
      'Host public key already bound to another tenant'
    )
  })

  it('renders structurally identical output for mock and live channels on Happy Path preset', async () => {
    const user = userEvent.setup()

    // Render mock panel
    const { container: mockContainer, unmount: unmountMock } = render(
      <EnrollmentPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />
    )
    await user.click(screen.getByTestId('host-enroll-btn'))
    await waitFor(() => expect(screen.getByTestId('enrollment-result')).toBeInTheDocument())

    const mockTestIds = extractTestIds(mockContainer)
    unmountMock()

    // Render live panel
    const { container: liveContainer } = render(
      <EnrollmentPanel bridge={liveBridge} preset={HAPPY_PATH_PRESET} />
    )
    await user.click(screen.getByTestId('host-enroll-btn'))
    await waitFor(() => expect(screen.getByTestId('enrollment-result')).toBeInTheDocument())

    const liveTestIds = extractTestIds(liveContainer)

    expect(mockTestIds).toEqual(liveTestIds)
  })
})

function extractTestIds(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll('[data-testid]'))
    .map((el) => el.getAttribute('data-testid') || '')
    .filter(Boolean)
    .sort()
}
