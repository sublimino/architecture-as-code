import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import {
  connectorsApi,
  isConnectorsMockMode,
  mockConnectorsApi,
  liveConnectorsApi,
  http,
} from './connectorsClient'
import * as demoModeModule from './demoMode'

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
})
