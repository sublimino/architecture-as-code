// The single place a connector credential check turns into a verdict.
//
// Live mode: the verdict is whatever the server said, through
// POST /connectors/providers/{id}/test (typed credentials) or
// POST /connectors/{id}/test (credentials the server already holds). Demo mode
// is decided by the connectorsApi mode seam, which routes to the simulator, and
// the message says so. Nothing here ever invents a pass.
import { connectorsApi, isConnectorsMockMode } from '../../api/connectorsClient'
import type { ProviderCredentialTestResult } from '../../api/connectorsClient'

export type VerificationStatus = 'verified' | 'failed' | 'unchecked'

export interface VerificationOutcome {
  status: VerificationStatus
  message: string
}

export const NOT_CHECKED_MESSAGE = 'Not checked: this provider cannot be verified before saving.'

interface VerifyArgs {
  token: string
  providerId: string
  credentials: Record<string, string>
  // Set when the server already holds credentials for this provider.
  connectorId?: string
}

/** Drops blank values: an empty field is "not entered", never an empty secret. */
export function typedCredentials(values: Record<string, string>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(values)
      .map(([k, v]) => [k, v.trim()] as const)
      .filter(([, v]) => v !== ''),
  )
}

function failureDetail(err: unknown): { status?: number; code?: string; message: string } {
  const e = err as {
    message?: string
    response?: { status?: number; data?: { error?: { code?: string; message?: string }; detail?: unknown } }
  }
  const data = e?.response?.data
  const detail = typeof data?.detail === 'string' ? data.detail : undefined
  return {
    status: e?.response?.status,
    code: data?.error?.code ?? detail,
    message: data?.error?.message ?? detail ?? e?.message ?? 'unknown error',
  }
}

function verdict(result: ProviderCredentialTestResult): VerificationOutcome {
  const prefix = isConnectorsMockMode() ? 'Demo data (simulated check): ' : ''
  if (result.valid && result.scopes_ok) {
    return { status: 'verified', message: `${prefix}Verified by the server.` }
  }
  if (result.valid) {
    const why = result.error_msg ? `: ${result.error_msg}` : '.'
    return { status: 'failed', message: `${prefix}Credentials accepted, but the granted scopes are insufficient${why}` }
  }
  return { status: 'failed', message: `${prefix}${result.error_msg ?? 'The server rejected these credentials.'}` }
}

export async function verifyConnectorCredentials({
  token,
  providerId,
  credentials,
  connectorId,
}: VerifyArgs): Promise<VerificationOutcome> {
  const typed = typedCredentials(credentials)
  try {
    if (Object.keys(typed).length > 0) {
      return verdict(await connectorsApi.testProviderCredentials(token, providerId, typed))
    }
    if (connectorId) {
      return verdict(await connectorsApi.testConnector(token, connectorId))
    }
    return { status: 'failed', message: 'Enter the credentials to test.' }
  } catch (err) {
    const { status, code, message } = failureDetail(err)
    if (status === 501 || code === 'test_unsupported') {
      return { status: 'unchecked', message: NOT_CHECKED_MESSAGE }
    }
    return {
      status: 'failed',
      message: status
        ? `The server could not test these credentials (HTTP ${status}): ${message}`
        : `The server could not be reached: ${message}`,
    }
  }
}
