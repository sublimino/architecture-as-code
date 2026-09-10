import { beforeEach, describe, expect, it, vi } from 'vitest'
import { http, onboardingApi, OnboardingApiError } from './onboardingClient'
import type { OnboardingStatus, OnboardingWizardState } from '../types/connectors'

describe('onboardingApi client', () => {
  const TEST_TOKEN = 'test-bearer-token-xyz'

  beforeEach(() => {
    vi.restoreAllMocks()
  })

  describe('getStatus', () => {
    it('dispatches GET /api/onboarding/status with Bearer token', async () => {
      const mockStatus: OnboardingStatus = {
        status: 'pending',
        skipped_at: null,
        completed_at: null,
      }
      const requestSpy = vi.spyOn(http, 'request').mockResolvedValueOnce({ data: mockStatus })

      const result = await onboardingApi.getStatus(TEST_TOKEN)

      expect(requestSpy).toHaveBeenCalledTimes(1)
      expect(requestSpy).toHaveBeenCalledWith({
        url: '/api/onboarding/status',
        method: 'GET',
        headers: { Authorization: `Bearer ${TEST_TOKEN}` },
      })
      expect(result).toEqual(mockStatus)
    })
  })

  describe('skip', () => {
    it('dispatches POST /api/onboarding/skip with Bearer token', async () => {
      const mockStatus: OnboardingStatus = {
        status: 'skipped',
        skipped_at: '2026-09-10T09:00:00Z',
        completed_at: null,
      }
      const requestSpy = vi.spyOn(http, 'request').mockResolvedValueOnce({ data: mockStatus })

      const result = await onboardingApi.skip(TEST_TOKEN)

      expect(requestSpy).toHaveBeenCalledTimes(1)
      expect(requestSpy).toHaveBeenCalledWith({
        url: '/api/onboarding/skip',
        method: 'POST',
        headers: { Authorization: `Bearer ${TEST_TOKEN}` },
      })
      expect(result).toEqual(mockStatus)
    })
  })

  describe('complete', () => {
    it('dispatches POST /api/onboarding/complete with Bearer token', async () => {
      const mockStatus: OnboardingStatus = {
        status: 'completed',
        skipped_at: null,
        completed_at: '2026-09-10T09:00:00Z',
      }
      const requestSpy = vi.spyOn(http, 'request').mockResolvedValueOnce({ data: mockStatus })

      const result = await onboardingApi.complete(TEST_TOKEN)

      expect(requestSpy).toHaveBeenCalledTimes(1)
      expect(requestSpy).toHaveBeenCalledWith({
        url: '/api/onboarding/complete',
        method: 'POST',
        headers: { Authorization: `Bearer ${TEST_TOKEN}` },
      })
      expect(result).toEqual(mockStatus)
    })
  })

  describe('getState', () => {
    it('dispatches GET /api/onboarding/state with Bearer token', async () => {
      const mockState: OnboardingWizardState = {
        selected_provider_ids: ['okta'],
        step_index: 1,
        provider_run_state: {
          okta: { status: 'connected' },
        },
      }
      const requestSpy = vi.spyOn(http, 'request').mockResolvedValueOnce({ data: mockState })

      const result = await onboardingApi.getState(TEST_TOKEN)

      expect(requestSpy).toHaveBeenCalledTimes(1)
      expect(requestSpy).toHaveBeenCalledWith({
        url: '/api/onboarding/state',
        method: 'GET',
        headers: { Authorization: `Bearer ${TEST_TOKEN}` },
      })
      expect(result).toEqual(mockState)
    })
  })

  describe('putState', () => {
    it('dispatches PUT /api/onboarding/state with JSON body and Bearer token', async () => {
      const stateToSave: OnboardingWizardState = {
        selected_provider_ids: ['okta', 'entra'],
        step_index: 2,
        provider_run_state: {
          okta: { status: 'connected' },
          entra: { status: 'submitting' },
        },
      }
      const requestSpy = vi.spyOn(http, 'request').mockResolvedValueOnce({ data: stateToSave })

      const result = await onboardingApi.putState(TEST_TOKEN, stateToSave)

      expect(requestSpy).toHaveBeenCalledTimes(1)
      expect(requestSpy).toHaveBeenCalledWith({
        url: '/api/onboarding/state',
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${TEST_TOKEN}`,
        },
        data: stateToSave,
      })
      expect(result).toEqual(stateToSave)
    })
  })

  describe('error handling and zero-mock guarantee', () => {
    it('throws structured OnboardingApiError on 401 Unauthorized', async () => {
      const errorResponse = {
        isAxiosError: true,
        response: {
          status: 401,
          data: { error: 'unauthorized', message: 'Token expired or invalid' },
        },
      }
      vi.spyOn(http, 'request').mockRejectedValueOnce(errorResponse)

      await expect(onboardingApi.getStatus(TEST_TOKEN)).rejects.toThrow(OnboardingApiError)
      await expect(
        (async () => {
          vi.spyOn(http, 'request').mockRejectedValueOnce(errorResponse)
          await onboardingApi.getStatus(TEST_TOKEN)
        })(),
      ).rejects.toMatchObject({
        status: 401,
        code: 'unauthorized',
        message: 'Token expired or invalid',
      })
    })

    it('throws structured OnboardingApiError with validation detail on 422', async () => {
      const errorResponse = {
        isAxiosError: true,
        response: {
          status: 422,
          data: {
            detail: [{ msg: 'step_index must be an integer' }],
          },
        },
      }
      vi.spyOn(http, 'request').mockRejectedValueOnce(errorResponse)

      await expect(
        onboardingApi.putState(TEST_TOKEN, { selected_provider_ids: [], step_index: 0, provider_run_state: {} }),
      ).rejects.toMatchObject({
        status: 422,
        message: 'step_index must be an integer',
      })
    })

    it('throws structured OnboardingApiError on network failure without falling back to mock data', async () => {
      const networkError = {
        isAxiosError: true,
        message: 'Network Error',
      }
      vi.spyOn(http, 'request').mockRejectedValueOnce(networkError)

      await expect(onboardingApi.getStatus(TEST_TOKEN)).rejects.toMatchObject({
        message: expect.stringContaining('Network Error'),
      })
    })
  })
})
