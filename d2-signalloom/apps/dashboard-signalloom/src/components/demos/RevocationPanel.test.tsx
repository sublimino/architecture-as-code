import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  RevocationPanel,
  REVOCATION_REASON_OPTIONS,
  extractErrorCode,
} from './RevocationPanel'
import {
  createMockBridge,
  createLiveBridge,
  type LiveTransport,
  type MockDemoBridge,
  type LiveDemoBridge,
} from './bridge'
import {
  REVOCATION_RACE_PRESET,
  HAPPY_PATH_PRESET,
} from './scenarios'

function createMockLiveTransport(options?: {
  fetchStatus?: number
  fetchBody?: unknown
  fetchNetworkError?: Error
  reqStatus?: number
  reqBody?: unknown
  reqErrorCode?: string
}): LiveTransport {
  const fetchMock = vi.fn(async (input: string, init?: RequestInit) => {
    if (options?.fetchNetworkError) {
      throw options.fetchNetworkError
    }
    const status = options?.fetchStatus ?? 200
    const bodyObj = options?.fetchBody ?? {
      status: 'revoked',
      host_id: 'amxd-demo-host-revocation-01',
      count: 1,
    }
    return new Response(JSON.stringify(bodyObj), {
      status,
      headers: { 'Content-Type': 'application/json' },
    })
  })

  const reqMock = vi.fn(async (path: string, token: string, config?: any) => {
    if (options?.reqStatus && options.reqStatus !== 200 && options.reqStatus !== 202) {
      const err: any = new Error(`Request failed with status ${options.reqStatus}`)
      err.status = options.reqStatus
      err.response = {
        status: options.reqStatus,
        data: options.reqBody ?? {
          error: {
            code: options.reqErrorCode ?? 'agent_revoked',
            message: `External agent has been revoked`,
          },
        },
      }
      throw err
    }
    return options?.reqBody ?? { upload_id: 'upload-test-123' }
  })

  return {
    fetch: fetchMock,
    req: reqMock,
  }
}

describe('RevocationPanel (Stage 5: Attributable Revocation & 403 Denial)', () => {
  let mockBridge: MockDemoBridge
  let liveBridge: LiveDemoBridge

  beforeEach(() => {
    mockBridge = createMockBridge({ preset: REVOCATION_RACE_PRESET, latencyMs: 0 })
    liveBridge = createLiveBridge({
      preset: REVOCATION_RACE_PRESET,
      transport: createMockLiveTransport({
        reqStatus: 403,
        reqErrorCode: 'agent_revoked',
      }),
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('extractErrorCode helper parses various error payload shapes', () => {
    expect(extractErrorCode({ error: { code: 'agent_revoked' } })).toBe('agent_revoked')
    expect(extractErrorCode({ error: 'agent_revoked' })).toBe('agent_revoked')
    expect(extractErrorCode({ error_code: 'tenant_key_binding_mismatch' })).toBe(
      'tenant_key_binding_mismatch'
    )
    expect(extractErrorCode({ code: 'cross_tenant_forbidden' })).toBe('cross_tenant_forbidden')
    expect(extractErrorCode({ detail: { code: 'host_revoked' } })).toBe('host_revoked')
    expect(extractErrorCode({ detail: 'agent_revoked' })).toBe('agent_revoked')
    expect(extractErrorCode(null)).toBe('')
    expect(extractErrorCode('plain string')).toBe('')
  })

  it('renders initial stage 5 layout with channel badge, target endpoints, and disabled button', () => {
    render(<RevocationPanel bridge={mockBridge} preset={REVOCATION_RACE_PRESET} />)

    expect(screen.getByTestId('revocation-panel')).toBeInTheDocument()
    expect(screen.getByTestId('revocation-channel-badge')).toHaveTextContent('Mock fixture')
    expect(screen.getByTestId('revocation-target-host')).toHaveTextContent(
      'amxd-demo-host-revocation-01'
    )
    expect(screen.getByTestId('revocation-target-agent')).toHaveTextContent(
      'amxd-demo-agent-revocation-01'
    )
    expect(screen.getByTestId('revocation-reason-select')).toBeInTheDocument()

    const dispatchBtn = screen.getByTestId('revocation-dispatch-btn')
    expect(dispatchBtn).toBeInTheDocument()
    expect(dispatchBtn).toBeDisabled()
    expect(dispatchBtn).toHaveTextContent('Revoke Host Credential')
  })

  it('reason selector renders all 5 ExternalAgentRevocationV1 reason_code options', () => {
    render(<RevocationPanel bridge={mockBridge} preset={REVOCATION_RACE_PRESET} />)

    const select = screen.getByTestId('revocation-reason-select') as HTMLSelectElement
    const optionValues = Array.from(select.options)
      .map((o) => o.value)
      .filter(Boolean)

    const expectedCodes = [
      'operator-request',
      'credential-compromise',
      'host-unenrolled',
      'key-rotation',
      'credential-expired',
    ]

    expect(optionValues).toEqual(expect.arrayContaining(expectedCodes))
    expect(optionValues.length).toBe(5)
  })

  it('enforces reason selection gating and async transition protection', async () => {
    const user = userEvent.setup()
    const { rerender } = render(
      <RevocationPanel bridge={mockBridge} preset={REVOCATION_RACE_PRESET} inFlight={false} />
    )

    const btn = screen.getByTestId('revocation-dispatch-btn')
    expect(btn).toBeDisabled()

    // Select a reason
    const select = screen.getByTestId('revocation-reason-select')
    await user.selectOptions(select, 'credential-compromise')

    expect(btn).not.toBeDisabled()

    // When inFlight is true, button is disabled even with reason selected
    rerender(
      <RevocationPanel bridge={mockBridge} preset={REVOCATION_RACE_PRESET} inFlight={true} />
    )
    expect(screen.getByTestId('revocation-dispatch-btn')).toBeDisabled()
  })

  it('executes mock channel revocation and renders 403 agent_revoked denial badge and timeline', async () => {
    const user = userEvent.setup()
    const onRevocationComplete = vi.fn()
    const onOutcome = vi.fn()

    render(
      <RevocationPanel
        bridge={mockBridge}
        preset={REVOCATION_RACE_PRESET}
        onRevocationComplete={onRevocationComplete}
        onOutcome={onOutcome}
      />
    )

    const select = screen.getByTestId('revocation-reason-select')
    await user.selectOptions(select, 'operator-request')

    const btn = screen.getByTestId('revocation-dispatch-btn')
    await user.click(btn)

    await waitFor(() => {
      expect(screen.getByTestId('revocation-denial-badge')).toBeInTheDocument()
    })

    expect(screen.getByTestId('revocation-denial-badge')).toHaveTextContent(
      '403 FORBIDDEN • agent_revoked'
    )

    // Audit timeline verification
    expect(screen.getByTestId('revocation-timeline')).toBeInTheDocument()
    expect(screen.getByTestId('revocation-timeline-event-revoked')).toBeInTheDocument()
    expect(screen.getByTestId('revocation-timeline-event-denied')).toBeInTheDocument()
    expect(screen.getAllByTestId('timeline-reason-code')[0]).toHaveTextContent('operator-request')

    expect(onRevocationComplete).toHaveBeenCalledWith(
      expect.objectContaining({
        denialConfirmed: true,
        responseStatusCode: 403,
        hostId: 'amxd-demo-host-revocation-01',
      })
    )
  })

  it('executes live channel two-endpoint flow calling bare path fetch then req upload with agent_revoked assertion', async () => {
    const user = userEvent.setup()
    const transport = createMockLiveTransport({
      fetchStatus: 200,
      reqStatus: 403,
      reqErrorCode: 'agent_revoked',
    })

    const onRevocationComplete = vi.fn()

    render(
      <RevocationPanel
        bridge={liveBridge}
        preset={REVOCATION_RACE_PRESET}
        transport={transport}
        token="test-live-bearer-token"
        onRevocationComplete={onRevocationComplete}
      />
    )

    expect(screen.getByTestId('revocation-channel-badge')).toHaveTextContent('Live backend')

    const select = screen.getByTestId('revocation-reason-select')
    await user.selectOptions(select, 'credential-compromise')

    const btn = screen.getByTestId('revocation-dispatch-btn')
    await user.click(btn)

    await waitFor(() => {
      expect(screen.getByTestId('revocation-denial-badge')).toBeInTheDocument()
    })

    // Step 1: verify direct fetch called on bare path /v1/external-agents/hosts/{host_id}/revoke
    expect(transport.fetch).toHaveBeenCalledWith(
      '/v1/external-agents/hosts/amxd-demo-host-revocation-01/revoke',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: 'Bearer test-live-bearer-token',
        }),
        body: expect.stringContaining('"reason_code":"credential-compromise"'),
      })
    )

    // Step 2: verify req called on /v1/external-agents/evidence-uploads with exact binding envelope
    expect(transport.req).toHaveBeenCalledWith(
      '/v1/external-agents/evidence-uploads',
      'test-live-bearer-token',
      expect.objectContaining({
        method: 'POST',
        data: expect.objectContaining({
          assertion_envelope: expect.objectContaining({
            key_id: 'amxd-demo-revocation-race-key',
            assertions: expect.arrayContaining([
              expect.objectContaining({
                agent_id: 'amxd-demo-agent-revocation-01',
                host_id: 'amxd-demo-host-revocation-01',
              }),
            ]),
          }),
          tenant_id: 'amxd-demo-tenant-primary',
        }),
      })
    )

    expect(screen.getByTestId('revocation-denial-badge')).toHaveTextContent(
      '403 FORBIDDEN • agent_revoked'
    )
    expect(screen.getAllByTestId('timeline-reason-code')[0]).toHaveTextContent('credential-compromise')
  })

  describe('binding and error code assertions', () => {
    it('distinguishes tenant_key_binding_mismatch 403 and does NOT render verified agent_revoked badge', async () => {
      const user = userEvent.setup()
      const transport = createMockLiveTransport({
        fetchStatus: 200,
        reqStatus: 403,
        reqErrorCode: 'tenant_key_binding_mismatch',
        reqBody: {
          error: {
            code: 'tenant_key_binding_mismatch',
            message: "Assertion key ID 'wrong-key' does not match credential binding",
          },
        },
      })

      render(
        <RevocationPanel
          bridge={liveBridge}
          preset={REVOCATION_RACE_PRESET}
          transport={transport}
        />
      )

      const select = screen.getByTestId('revocation-reason-select')
      await user.selectOptions(select, 'key-rotation')
      await user.click(screen.getByTestId('revocation-dispatch-btn'))

      await waitFor(() => {
        expect(screen.getByTestId('revocation-binding-mismatch-warning')).toBeInTheDocument()
      })

      // The verified agent_revoked badge MUST NOT be rendered
      expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
      expect(screen.getByTestId('revocation-binding-mismatch-warning')).toHaveTextContent(
        'tenant_key_binding_mismatch'
      )
    })

    it('distinguishes tenant_agent_binding_mismatch 403 and flags warning in timeline', async () => {
      const user = userEvent.setup()
      const transport = createMockLiveTransport({
        fetchStatus: 200,
        reqStatus: 403,
        reqErrorCode: 'tenant_agent_binding_mismatch',
        reqBody: {
          error: {
            code: 'tenant_agent_binding_mismatch',
            message: "Assertion agent_id does not match host credential binding",
          },
        },
      })

      render(
        <RevocationPanel
          bridge={liveBridge}
          preset={REVOCATION_RACE_PRESET}
          transport={transport}
        />
      )

      const select = screen.getByTestId('revocation-reason-select')
      await user.selectOptions(select, 'host-unenrolled')
      await user.click(screen.getByTestId('revocation-dispatch-btn'))

      await waitFor(() => {
        expect(screen.getByTestId('revocation-binding-mismatch-warning')).toBeInTheDocument()
      })

      expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
      expect(screen.getByTestId('revocation-timeline-event-binding_mismatch')).toBeInTheDocument()
    })

    it('distinguishes cross_tenant_forbidden 403', async () => {
      const user = userEvent.setup()
      const transport = createMockLiveTransport({
        fetchStatus: 200,
        reqStatus: 403,
        reqErrorCode: 'cross_tenant_forbidden',
        reqBody: {
          error: {
            code: 'cross_tenant_forbidden',
            message: 'Cannot upload evidence for cross tenant',
          },
        },
      })

      render(
        <RevocationPanel
          bridge={liveBridge}
          preset={REVOCATION_RACE_PRESET}
          transport={transport}
        />
      )

      const select = screen.getByTestId('revocation-reason-select')
      await user.selectOptions(select, 'credential-expired')
      await user.click(screen.getByTestId('revocation-dispatch-btn'))

      await waitFor(() => {
        expect(screen.getByTestId('revocation-binding-mismatch-warning')).toBeInTheDocument()
      })

      expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
    })
  })

  it('renders distinct network failure state when live dispatch fails transport-level fetch', async () => {
    const user = userEvent.setup()
    const transport = createMockLiveTransport({
      fetchNetworkError: new TypeError('Failed to fetch: Connection refused'),
    })

    render(
      <RevocationPanel
        bridge={liveBridge}
        preset={REVOCATION_RACE_PRESET}
        transport={transport}
      />
    )

    const select = screen.getByTestId('revocation-reason-select')
    await user.selectOptions(select, 'operator-request')

    await user.click(screen.getByTestId('revocation-dispatch-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('revocation-network-error')).toBeInTheDocument()
    })

    expect(screen.getByTestId('revocation-network-error')).toHaveTextContent(
      'Could not reach backend'
    )
    expect(screen.getByTestId('revocation-network-error')).toHaveTextContent('Connection refused')
    expect(screen.queryByTestId('revocation-denial-badge')).not.toBeInTheDocument()
  })

  it('re-verifies 403 upload denial using upload attempt trigger button', async () => {
    const user = userEvent.setup()
    const transport = createMockLiveTransport({
      fetchStatus: 200,
      reqStatus: 403,
      reqErrorCode: 'agent_revoked',
    })

    render(
      <RevocationPanel
        bridge={liveBridge}
        preset={REVOCATION_RACE_PRESET}
        transport={transport}
      />
    )

    const select = screen.getByTestId('revocation-reason-select')
    await user.selectOptions(select, 'credential-compromise')
    await user.click(screen.getByTestId('revocation-dispatch-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('upload-attempt-trigger-btn')).toBeInTheDocument()
    })

    // Click re-verify button
    await user.click(screen.getByTestId('upload-attempt-trigger-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('revocation-denial-badge')).toBeInTheDocument()
    })

    expect(transport.req).toHaveBeenCalledTimes(2)
  })

  it('preserves structural mock/live parity for Revocation Race preset', async () => {
    const user = userEvent.setup()

    // Render mock
    const { unmount: unmountMock } = render(
      <RevocationPanel bridge={mockBridge} preset={REVOCATION_RACE_PRESET} />
    )

    await user.selectOptions(
      screen.getByTestId('revocation-reason-select'),
      'credential-compromise'
    )
    await user.click(screen.getByTestId('revocation-dispatch-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('revocation-denial-badge')).toBeInTheDocument()
    })

    const mockBadgeText = screen.getByTestId('revocation-denial-badge').textContent
    const mockTimelineEventsCount = screen.getAllByTestId(/revocation-timeline-event-/).length
    unmountMock()

    // Render live
    const transport = createMockLiveTransport({
      fetchStatus: 200,
      reqStatus: 403,
      reqErrorCode: 'agent_revoked',
    })

    render(
      <RevocationPanel
        bridge={liveBridge}
        preset={REVOCATION_RACE_PRESET}
        transport={transport}
      />
    )

    await user.selectOptions(
      screen.getByTestId('revocation-reason-select'),
      'credential-compromise'
    )
    await user.click(screen.getByTestId('revocation-dispatch-btn'))

    await waitFor(() => {
      expect(screen.getByTestId('revocation-denial-badge')).toBeInTheDocument()
    })

    const liveBadgeText = screen.getByTestId('revocation-denial-badge').textContent
    const liveTimelineEventsCount = screen.getAllByTestId(/revocation-timeline-event-/).length

    expect(liveBadgeText).toEqual(mockBadgeText)
    expect(liveTimelineEventsCount).toEqual(mockTimelineEventsCount)
  })
})
