import axios from 'axios'
import type { OnboardingStatus, OnboardingWizardState } from '../types/connectors'

// Same mock/live toggle as connectorsClient.ts (VITE_CONNECTORS_API_MODE) —
// this is part of the same connector-framework surface, not a separate
// feature flag.
const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''
const http = axios.create({ baseURL: BASE })

async function req<T>(
  path: string,
  token: string,
  config?: { method?: string },
): Promise<T> {
  const url = path.startsWith('/api') ? path : `/api${path}`
  const res = await http.request<T>({
    url,
    method: config?.method ?? 'GET',
    headers: { Authorization: `Bearer ${token}` },
  })
  return res.data
}

export interface OnboardingApi {
  getStatus(token: string): Promise<OnboardingStatus>
  skip(token: string): Promise<OnboardingStatus>
  getState(token: string): Promise<OnboardingWizardState>
  putState(token: string, state: OnboardingWizardState): Promise<OnboardingWizardState>
}

async function reqWithBody<T>(path: string, token: string, method: string, data: unknown): Promise<T> {
  const url = path.startsWith('/api') ? path : `/api${path}`
  const res = await http.request<T>({
    url,
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    data,
  })
  return res.data
}

const liveOnboardingApi: OnboardingApi = {
  getStatus: (token) => req<OnboardingStatus>('/onboarding/status', token),
  skip: (token) => req<OnboardingStatus>('/onboarding/skip', token, { method: 'POST' }),
  getState: (token) => req<OnboardingWizardState>('/onboarding/state', token),
  putState: (token, state) => reqWithBody<OnboardingWizardState>('/onboarding/state', token, 'PUT', state),
}

// ─── Mock implementation ──────────────────────────────────────────────────
// Module-level, in-memory only — resets on reload, same as mockConnectorsApi.

let mockSkippedAt: string | null = null
let mockWizardState: OnboardingWizardState = {
  selected_provider_ids: [],
  step_index: 0,
  provider_run_state: {},
}

function delay<T>(value: T, ms = 150): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

const mockOnboardingApi: OnboardingApi = {
  getStatus: () => delay({ skipped_at: mockSkippedAt }),
  skip: () => {
    mockSkippedAt = new Date().toISOString()
    return delay({ skipped_at: mockSkippedAt })
  },
  getState: () => delay(mockWizardState),
  putState: (_token, state) => {
    mockWizardState = state
    return delay(mockWizardState)
  },
}

const MOCK_MODE = (import.meta.env.VITE_CONNECTORS_API_MODE as string | undefined) !== 'live'

export const onboardingApi: OnboardingApi = MOCK_MODE ? mockOnboardingApi : liveOnboardingApi
