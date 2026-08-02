import axios from 'axios'
import type { OnboardingStatus, OnboardingWizardState } from '../types/connectors'

// This used to share connectorsClient.ts's VITE_CONNECTORS_API_MODE mock/live
// toggle, on the assumption both APIs land together (same connector-framework
// surface). In practice the onboarding backend (006_onboarding.sql,
// onboarding.py) shipped and has been live for a while, but the connectors
// backend (GET /connectors, GET /connectors/providers) never has — no router
// for it exists in fe-signalloom. Flipping the shared flag to 'live' would
// fix onboarding but 404 every connectors call, so onboarding gets its own
// switch: always live now that its backend exists. connectorsClient.ts keeps
// the VITE_CONNECTORS_API_MODE gate (still mock-only) until that backend is
// actually built.
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

export const onboardingApi: OnboardingApi = liveOnboardingApi
