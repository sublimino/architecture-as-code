import axios from 'axios'
import type { OnboardingStatus, OnboardingWizardState } from '../types/connectors'

const BASE = (import.meta.env.VITE_API_BASE_URL as string) ?? ''
export const http = axios.create({ baseURL: BASE })

export class OnboardingApiError extends Error {
  status?: number
  code?: string
  detail?: string

  constructor(message: string, status?: number, code?: string, detail?: string) {
    super(message)
    this.name = 'OnboardingApiError'
    this.status = status
    this.code = code
    this.detail = detail
  }
}

function handleAxiosError(err: unknown, action: string): never {
  if (axios.isAxiosError(err)) {
    const status = err.response?.status
    const data = err.response?.data as { error?: string; message?: string; detail?: string | Array<{ msg?: string }> } | undefined
    let message = `Failed to ${action}`
    if (data?.message) {
      message = data.message
    } else if (typeof data?.detail === 'string') {
      message = data.detail
    } else if (Array.isArray(data?.detail) && data.detail[0]?.msg) {
      message = data.detail[0].msg
    } else if (err.message) {
      message = `${message}: ${err.message}`
    }
    throw new OnboardingApiError(message, status, data?.error, typeof data?.detail === 'string' ? data.detail : undefined)
  }
  if (err instanceof Error) {
    throw new OnboardingApiError(err.message)
  }
  throw new OnboardingApiError(`Failed to ${action}: Unknown error`)
}

async function req<T>(
  path: string,
  token: string,
  action: string,
  config?: { method?: string },
): Promise<T> {
  const url = path.startsWith('/api') ? path : `/api${path}`
  try {
    const res = await http.request<T>({
      url,
      method: config?.method ?? 'GET',
      headers: { Authorization: `Bearer ${token}` },
    })
    return res.data
  } catch (err) {
    handleAxiosError(err, action)
  }
}

async function reqWithBody<T>(
  path: string,
  token: string,
  method: string,
  data: unknown,
  action: string,
): Promise<T> {
  const url = path.startsWith('/api') ? path : `/api${path}`
  try {
    const res = await http.request<T>({
      url,
      method,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      data,
    })
    return res.data
  } catch (err) {
    handleAxiosError(err, action)
  }
}

export interface OnboardingApi {
  getStatus(token: string): Promise<OnboardingStatus>
  skip(token: string): Promise<OnboardingStatus>
  complete(token: string): Promise<OnboardingStatus>
  getState(token: string): Promise<OnboardingWizardState>
  putState(token: string, state: OnboardingWizardState): Promise<OnboardingWizardState>
}

const liveOnboardingApi: OnboardingApi = {
  getStatus: (token) => req<OnboardingStatus>('/onboarding/status', token, 'retrieve onboarding status'),
  skip: (token) => req<OnboardingStatus>('/onboarding/skip', token, 'skip onboarding', { method: 'POST' }),
  complete: (token) => req<OnboardingStatus>('/onboarding/complete', token, 'complete onboarding', { method: 'POST' }),
  getState: (token) => req<OnboardingWizardState>('/onboarding/state', token, 'retrieve wizard state'),
  putState: (token, state) => reqWithBody<OnboardingWizardState>('/onboarding/state', token, 'PUT', state, 'save wizard state'),
}

export const onboardingApi: OnboardingApi = liveOnboardingApi
