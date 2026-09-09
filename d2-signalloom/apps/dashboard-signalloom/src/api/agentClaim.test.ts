import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  claimDiscoveredAgent,
  submitClaim,
  type AgentClaimRequest,
  type AgentClaimResponse,
} from './agentClaim'

const request: AgentClaimRequest = {
  pod_name: 'kagent-k8s-reader',
  namespace: 'fe-signalloom-agents',
  spiffe_id: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-reader',
  harness: 'kagent',
  model: 'anthropic-claude',
  declared_tools: ['k8s_get_resources'],
  token_budget_limit: 250000,
  agent_id: 'discovered:reader',
}

const response: AgentClaimResponse = {
  claim_id: 'claim-kagent-k8s-reader',
  status: 'granted',
  spiffe_svid_verified: true,
  allocated_token_budget: 250000,
  signal_session_url: '/ws/agents/registry-reader/signal',
  ebpf_sentinel_bound: true,
  agent_id: 'registry-reader',
}

describe('agent claim API', () => {
  const fetchMock = vi.fn()
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    fetchMock.mockReset()
    globalThis.fetch = fetchMock as typeof fetch
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('posts the complete authenticated payload to the canonical generic endpoint', async () => {
    const signal = new AbortController().signal
    fetchMock.mockResolvedValue(new Response(JSON.stringify(response), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }))

    await expect(submitClaim('oidc-token', request, signal)).resolves.toEqual(response)
    expect(fetchMock).toHaveBeenCalledWith('/api/v1/agents/claim', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer oidc-token',
      },
      body: JSON.stringify(request),
      signal,
    })
  })

  it('URL-encodes the discovered identifier on the canonical row endpoint', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify(response), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }))

    await expect(claimDiscoveredAgent('oidc-token', 'namespace/reader bot', request)).resolves.toEqual(response)
    expect(fetchMock).toHaveBeenCalledWith('/api/v1/agents/namespace%2Freader%20bot/claim', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer oidc-token',
      },
      body: JSON.stringify(request),
      signal: undefined,
    })
  })

  it('surfaces the standard API error-envelope message', async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({
      error: {
        code: 'claim_failed',
        message: 'SPIFFE SVID verification failed',
      },
    }), { status: 500, headers: { 'Content-Type': 'application/json' } }))

    await expect(claimDiscoveredAgent('oidc-token', 'reader', request))
      .rejects.toThrow('SPIFFE SVID verification failed')
  })

  it('uses a safe status fallback for malformed proxy errors', async () => {
    fetchMock.mockResolvedValue(new Response('<html>gateway failure</html>', { status: 502 }))

    await expect(submitClaim('oidc-token', request)).rejects.toThrow('Claim failed (502)')
  })
})
