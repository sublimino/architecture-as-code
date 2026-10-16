import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { AxiosError, AxiosHeaders } from 'axios'
import {
  apiErrorCode,
  connectorErrorMessage,
  connectorsApi,
  isConnectorsMockMode,
  mockConnectorsApi,
  liveConnectorsApi,
  http,
} from './connectorsClient'
import * as demoModeModule from './demoMode'
import {
  initialDiscoveryWorkloads,
  claudeAgentFixture,
  openaiAgentFixture,
  remoteEnvironmentFixtures,
} from './fakeData'

describe('connectorsClient mode dispatch & honesty', () => {
  const originalEnv = { ...import.meta.env }

  beforeEach(() => {
    vi.restoreAllMocks()
    demoModeModule.setDemoMode(true)
  })

  afterEach(() => {
    demoModeModule.setDemoMode(true)
  })

  describe('isConnectorsMockMode', () => {
    it('defaults to demoMode state when no build-time override is present', () => {
      demoModeModule.setDemoMode(true)
      expect(isConnectorsMockMode()).toBe(true)

      demoModeModule.setDemoMode(false)
      expect(isConnectorsMockMode()).toBe(false)
    })

    it('forces live mode when VITE_CONNECTORS_API_MODE is "live" even if demoMode is true', () => {
      const orig = import.meta.env.VITE_CONNECTORS_API_MODE
      try {
        ;(import.meta.env as Record<string, unknown>).VITE_CONNECTORS_API_MODE = 'live'
        demoModeModule.setDemoMode(true)
        expect(isConnectorsMockMode()).toBe(false)
      } finally {
        ;(import.meta.env as Record<string, unknown>).VITE_CONNECTORS_API_MODE = orig
      }
    })

    it('forces mock mode when VITE_CONNECTORS_API_MODE is "mock" even if demoMode is false', () => {
      const orig = import.meta.env.VITE_CONNECTORS_API_MODE
      try {
        ;(import.meta.env as Record<string, unknown>).VITE_CONNECTORS_API_MODE = 'mock'
        demoModeModule.setDemoMode(false)
        expect(isConnectorsMockMode()).toBe(true)
      } finally {
        ;(import.meta.env as Record<string, unknown>).VITE_CONNECTORS_API_MODE = orig
      }
    })
  })

  describe('connectorsApi routing', () => {
    it('forwards supplied credentials through testConnector in live mode', async () => {
      demoModeModule.setDemoMode(false)
      const liveSpy = vi.spyOn(liveConnectorsApi, 'testConnector').mockResolvedValue({
        connector_id: 'conn-1', valid: true, scopes_ok: true,
      } as Awaited<ReturnType<typeof liveConnectorsApi.testConnector>>)
      await connectorsApi.testConnector('tok', 'conn-1', { api_key: 'sk-typed' })
      expect(liveSpy).toHaveBeenCalledWith('tok', 'conn-1', { api_key: 'sk-typed' })
    })

    it('routes listProviders to mockConnectorsApi in demo mode', async () => {
      demoModeModule.setDemoMode(true)
      const mockSpy = vi.spyOn(mockConnectorsApi, 'listProviders')
      const liveSpy = vi.spyOn(liveConnectorsApi, 'listProviders')

      const providers = await connectorsApi.listProviders('test-token')
      expect(mockSpy).toHaveBeenCalledWith('test-token')
      expect(liveSpy).not.toHaveBeenCalled()
      expect(providers.length).toBeGreaterThan(0)
    })

    it('routes listProviders to liveConnectorsApi in live mode', async () => {
      demoModeModule.setDemoMode(false)
      const mockSpy = vi.spyOn(mockConnectorsApi, 'listProviders')
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: { providers: [{ provider_id: 'live_test', display_name: 'Live Provider' }] },
      })

      const providers = await connectorsApi.listProviders('live-token')
      expect(mockSpy).not.toHaveBeenCalled()
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/providers',
          method: 'GET',
          headers: expect.objectContaining({
            Authorization: 'Bearer live-token',
          }),
        }),
      )
      expect(providers).toEqual([{ provider_id: 'live_test', display_name: 'Live Provider' }])
    })

    it('routes listConnectors to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: {
          connectors: [
            {
              connector_id: 'live-conn-1',
              provider_id: 'aws_iam',
              display_name: 'Live AWS',
              status: 'connected',
            },
          ],
        },
      })

      const connectors = await connectorsApi.listConnectors('live-token')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors',
          method: 'GET',
        }),
      )
      expect(connectors[0].connector_id).toBe('live-conn-1')
    })

    it('routes getStatus to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: {
          status: 'healthy',
          synced_at: '2026-10-13T00:00:00Z',
          total_connectors: 1,
          active_connectors: 1,
          connectors: [],
        },
      })

      const status = await connectorsApi.getStatus('live-token')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/status',
          method: 'GET',
        }),
      )
      expect(status.status).toBe('healthy')
    })

    it('routes toggleConnector to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: {
          connector_id: 'conn-1',
          provider_id: 'aws_iam',
          display_name: 'AWS',
          status: 'disconnected',
        },
      })

      const res = await connectorsApi.toggleConnector('live-token', 'conn-1', false)
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/conn-1/toggle',
          method: 'POST',
          data: { enabled: false },
        }),
      )
      expect(res.status).toBe('disconnected')
    })

    it('routes deleteConnector to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: { connector_id: 'conn-1', status: 'disconnected' },
      })

      await connectorsApi.deleteConnector('live-token', 'conn-1')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/conn-1',
          method: 'DELETE',
        }),
      )
    })

    it('routes testConnector to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({
        data: {
          connector_id: 'conn-1',
          status: 'connected',
          tested_at: '2026-10-13T00:00:00Z',
          latency_ms: 45,
          valid: true,
          scopes_ok: true,
          error_msg: null,
          credential_expires_at: null,
          needs_rotation: false,
        },
      })

      const result = await connectorsApi.testConnector('live-token', 'conn-1')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/conn-1/test',
          method: 'POST',
        }),
      )
      expect(result.valid).toBe(true)
    })
  })

  describe('Claude and OpenAI provider integration', () => {
    it('returns claude and openai in listProviders with verified fields', async () => {
      demoModeModule.setDemoMode(true)
      const providers = await connectorsApi.listProviders('test-token')
      const claude = providers.find((p) => p.provider_id === 'claude')
      const openai = providers.find((p) => p.provider_id === 'openai')

      expect(claude).toBeDefined()
      expect(openai).toBeDefined()

      expect(claude?.display_name).toBe('Anthropic Claude')

      const apiKeyField = claude?.wizard_config.fields.find((f) => f.name === 'api_key')
      expect(apiKeyField).toBeDefined()
      expect(apiKeyField?.required).toBe(true)
      expect(apiKeyField?.type).toBe('password')

      const workspaceField = claude?.wizard_config.fields.find((f) => f.name === 'workspace_id')
      expect(workspaceField).toBeDefined()
      expect(workspaceField?.required).toBe(false)

      const adminApiKeyField = claude?.wizard_config.fields.find((f) => f.name === 'admin_api_key')
      expect(adminApiKeyField).toBeDefined()
      expect(adminApiKeyField?.required).toBe(false)

      expect(claude?.wizard_config.permissions).toContain('models.read')
      expect(claude?.wizard_config.permissions).toContain('messages.batches.read')

      // OpenAI alignment verification
      const openaiKeyField = openai?.wizard_config.fields.find((f) => f.name === 'api_key')
      expect(openaiKeyField).toBeDefined()
      expect(openaiKeyField?.required).toBe(true)
      expect(openaiKeyField?.type).toBe('password')

      const openaiOrgField = openai?.wizard_config.fields.find((f) => f.name === 'openai_org_id')
      expect(openaiOrgField).toBeDefined()
      expect(openaiOrgField?.required).toBe(false)
    })

    it('succeeds when creating and testing a claude connector', async () => {
      demoModeModule.setDemoMode(true)
      const created = await connectorsApi.createConnector('test-token', {
        provider_id: 'claude',
        display_name: 'Production Claude Agent Connector',
        credentials: {
          api_key: 'sk-ant-api03-testkey',
          workspace_id: 'wrkspc_test123',
        },
        metadata: {
          env: 'production',
        },
      })

      expect(created.provider_id).toBe('claude')
      expect(created.status).toBe('connected')
      expect(created.connector_id).toBeDefined()

      const testResult = await connectorsApi.testConnector('test-token', created.connector_id)
      expect(testResult.valid).toBe(true)
      expect(testResult.scopes_ok).toBe(true)
      expect(testResult.error_msg).toBeNull()
    })

    it('routes triggerScan and getSyncLogs to liveConnectorsApi when demoMode is false', async () => {
      demoModeModule.setDemoMode(false)
      const mockResult = {
        provider_id: 'claude',
        synced_at: '2026-10-16T12:00:00Z',
        duration_ms: 120,
        status: 'success',
        records_scanned: { agents: 1, models: 1, environments: 1, tools: 1 },
        policies_evaluated: { egress_rules: 1, violations: 0 },
        logs: [],
      }

      const httpSpy = vi.spyOn(http, 'request').mockResolvedValue({ data: mockResult })

      const scanRes = await connectorsApi.triggerScan('live-token', 'claude')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/claude/scan',
          method: 'POST',
        }),
      )
      expect(scanRes.provider_id).toBe('claude')

      const logRes = await connectorsApi.getSyncLogs('live-token', 'claude')
      expect(httpSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          url: '/api/connectors/claude/logs',
          method: 'GET',
        }),
      )
      expect(logRes?.provider_id).toBe('claude')
    })


    it('propagates live triggerScan failures instead of fabricating a result', async () => {
      demoModeModule.setDemoMode(false)
      vi.spyOn(http, 'request').mockRejectedValue(httpError(404, 'connector_not_configured'))

      const err = await connectorsApi.triggerScan('live-token', 'claude').then(
        () => null,
        (e: unknown) => e,
      )
      expect(err).not.toBeNull()
      expect(apiErrorCode(err)).toBe('connector_not_configured')
      expect(connectorErrorMessage(err)).toMatch(/not connected/i)
    })

    it('reports 501 scan_unsupported as an explicit unsupported message', async () => {
      demoModeModule.setDemoMode(false)
      vi.spyOn(http, 'request').mockRejectedValue(httpError(501, 'scan_unsupported'))

      const err = await connectorsApi.triggerScan('live-token', 'okta').catch((e: unknown) => e)
      expect(connectorErrorMessage(err)).toMatch(/not supported/i)
    })

    it('maps live getSyncLogs 404 never_scanned to null (honest empty state)', async () => {
      demoModeModule.setDemoMode(false)
      vi.spyOn(http, 'request').mockRejectedValue(httpError(404, 'never_scanned'))

      await expect(connectorsApi.getSyncLogs('live-token', 'claude')).resolves.toBeNull()
    })

    it('propagates any other live getSyncLogs failure', async () => {
      demoModeModule.setDemoMode(false)
      const spy = vi.spyOn(http, 'request')

      spy.mockRejectedValueOnce(httpError(500, 'internal_error'))
      await expect(connectorsApi.getSyncLogs('live-token', 'claude')).rejects.toBeDefined()

      spy.mockRejectedValueOnce(httpError(404, 'not_found'))
      await expect(connectorsApi.getSyncLogs('live-token', 'claude')).rejects.toBeDefined()
    })
  })

  describe('demo fixture coherence', () => {
    it('describes each discovered AI workload identically in the discovery list and the agent detail', () => {
      const pairs = [
        { fixture: claudeAgentFixture, provider: 'Anthropic Claude' },
        { fixture: openaiAgentFixture, provider: 'OpenAI' },
      ]
      for (const { fixture, provider } of pairs) {
        const listed = initialDiscoveryWorkloads.find((w) => w.id === fixture.id)
        expect(listed, fixture.id).toBeDefined()
        expect(listed!.source_label).toBe(provider)
        expect(listed!.name).toBe(fixture.name)
        expect(listed!.model).toBe(fixture.model_name)
        expect(listed!.owner).toBe(fixture.owner)
        expect(listed!.metadata!.tools).toEqual(fixture.tools)
        expect(listed!.metadata!.responsibility).toMatchObject({ owner_name: fixture.responsibility?.owner_name })
        // Discovered, not claimed: the detail must not claim a registry link
        // the discovery list does not show.
        expect(listed!.status).toBe('discovered')
        expect(fixture.is_registry_linked).toBe(false)
      }
    })

    it('keeps the demo sync counts consistent with its own logs and environment fixture', async () => {
      for (const providerId of ['claude', 'openai'] as const) {
        const result = await mockConnectorsApi.getSyncLogs('demo-token', providerId)
        expect(result).not.toBeNull()
        const env = remoteEnvironmentFixtures[providerId]
        expect(result!.records_scanned.agents).toBe(env.connectedAgents.length)
        const modelsLog = result!.logs.find((l) => Array.isArray(l.details?.models))
        expect(modelsLog, providerId).toBeDefined()
        expect(result!.records_scanned.models).toBe((modelsLog!.details!.models as unknown[]).length)
      }
    })
  })
})

function httpError(status: number, code: string): AxiosError {
  return new AxiosError(`Request failed with status code ${status}`, 'ERR_BAD_RESPONSE', undefined, undefined, {
    status,
    statusText: '',
    headers: {},
    config: { headers: new AxiosHeaders() },
    data: { error: { code, message: code } },
  })
}
