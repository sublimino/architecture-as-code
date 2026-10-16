import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
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

    it('verifies discovered Claude and OpenAI agents have full CEL compliance metadata', () => {
      const claudeDiscovery = initialDiscoveryWorkloads.find((w) => w.id === 'claude-agent-fin-analyst')
      const openaiDiscovery = initialDiscoveryWorkloads.find((w) => w.id === 'openai-assistant-triage')

      expect(claudeDiscovery).toBeDefined()
      expect(openaiDiscovery).toBeDefined()

      // Claude discovery CEL metadata
      expect(claudeDiscovery?.source).toBe('external_services')
      expect(claudeDiscovery?.source_label).toBe('Anthropic Claude')
      expect(claudeDiscovery?.model).toBe('claude-3-5-sonnet-20241022')
      expect(claudeDiscovery!.metadata!.runtime).toEqual({
        model: 'claude-3-5-sonnet-20241022',
        framework: 'claude-code',
      })
      expect(claudeDiscovery!.metadata!.operational_state).toEqual({
        runtime_status: 'running',
      })
      expect(claudeDiscovery!.metadata!.tools).toEqual(['read_sec_filing', 'calculate_risk_var'])
      expect(claudeDiscovery!.metadata!.guardrails).toEqual({
        prompt_injection_filter: true,
        human_override_active: true,
      })
      expect(claudeDiscovery!.metadata!.telemetry).toEqual({
        token_usage: { total: 170500 },
      })
      expect(claudeDiscovery!.metadata!.responsibility).toEqual({
        owner_name: 'Risk Ops',
        owner_id: 'risk-ops@signalloom.demo',
      })

      // OpenAI discovery CEL metadata
      expect(openaiDiscovery?.source).toBe('external_services')
      expect(openaiDiscovery?.source_label).toBe('OpenAI')
      expect(openaiDiscovery?.model).toBe('gpt-4o')
      expect(openaiDiscovery!.metadata!.runtime).toEqual({
        model: 'gpt-4o',
        framework: 'openai-assistants',
      })
      expect(openaiDiscovery!.metadata!.operational_state).toEqual({
        runtime_status: 'running',
      })
      expect(openaiDiscovery!.metadata!.tools).toEqual(['file_search', 'route_ticket'])
      expect(openaiDiscovery!.metadata!.guardrails).toEqual({
        prompt_injection_filter: true,
        human_override_active: true,
      })
      expect(openaiDiscovery!.metadata!.telemetry).toEqual({
        token_usage: { total: 85000 },
      })
      expect(openaiDiscovery!.metadata!.responsibility).toEqual({
        owner_name: 'Support Ops',
        owner_id: 'support-ops@signalloom.demo',
      })

      // AgentResponse fixtures CEL metadata
      expect(claudeAgentFixture.tools).toEqual(['read_sec_filing', 'calculate_risk_var'])
      expect(claudeAgentFixture.guardrails).toEqual({ prompt_injection_filter: true, human_override_active: true })
      expect(claudeAgentFixture.telemetry).toEqual({ token_usage: { total: 170500 } })
      expect(claudeAgentFixture.responsibility?.owner_name).toBe('Risk Ops')

      expect(openaiAgentFixture.tools).toEqual(['file_search', 'route_ticket'])
      expect(openaiAgentFixture.guardrails).toEqual({ prompt_injection_filter: true, human_override_active: true })
      expect(openaiAgentFixture.telemetry).toEqual({ token_usage: { total: 85000 } })
      expect(openaiAgentFixture.responsibility?.owner_name).toBe('Support Ops')
    })

    it('returns realistic mock sync logs for claude, openai, and dex with wire telemetry', async () => {
      demoModeModule.setDemoMode(true)

      // Test claude sync logs
      const claudeResult = await connectorsApi.getSyncLogs('demo-token', 'claude')
      expect(claudeResult.provider_id).toBe('claude')
      expect(claudeResult.status).toBe('success')
      expect(claudeResult.records_scanned).toEqual({
        agents: 3,
        models: 4,
        environments: 1,
        tools: 2,
      })
      expect(claudeResult.policies_evaluated).toEqual({
        egress_rules: 2,
        violations: 0,
      })

      // Verify specific required log signatures
      const messages = claudeResult.logs.map((l) => l.message).join(' ')
      expect(messages).toContain('claude-3-5-sonnet-20241022')
      expect(messages).toContain('batch message processing queues')
      expect(messages).toContain('env_01CyCigBbDRSLTzSCyyHQ7eT')
      expect(messages).toContain('0/16')
      expect(messages).toContain('MCP servers allowed, package managers allowed')

      // Check debug wire traces in claude
      const modelsLog = claudeResult.logs.find((l) => l.endpoint === 'GET /v1/models')
      expect(modelsLog).toBeDefined()
      expect(modelsLog?.status_code).toBe(200)
      expect(modelsLog?.duration_ms).toBeGreaterThan(0)
      expect(modelsLog?.details).toHaveProperty('models')

      // Test triggerScan updates connector and returns fresh result
      const scannedResult = await connectorsApi.triggerScan('demo-token', 'claude')
      expect(scannedResult.provider_id).toBe('claude')
      expect(scannedResult.records_scanned.models).toBe(4)

      // Test OpenAI sync logs
      const openaiResult = await connectorsApi.getSyncLogs('demo-token', 'openai')
      expect(openaiResult.provider_id).toBe('openai')
      expect(openaiResult.records_scanned.agents).toBe(2)
      const openaiMessages = openaiResult.logs.map((l) => l.message).join(' ')
      expect(openaiMessages).toContain('gpt-4o')

      // Test Dex sync logs
      const dexResult = await connectorsApi.getSyncLogs('demo-token', 'dex')
      expect(dexResult.provider_id).toBe('dex')
      expect(dexResult.records_scanned.environments).toBe(1)
      const dexMessages = dexResult.logs.map((l) => l.message).join(' ')
      expect(dexMessages).toContain('Dex')
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
      expect(logRes.provider_id).toBe('claude')
    })
  })
})

