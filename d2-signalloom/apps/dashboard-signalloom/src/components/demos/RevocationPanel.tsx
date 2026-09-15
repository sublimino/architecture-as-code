import React, { useState, useMemo, useEffect, useCallback } from 'react'
import { colors } from '../../styles/tokens'
import {
  type DemoBridge,
  type StageOutcome,
  type LiveTransport,
  describeChannel,
  defaultLiveTransport,
} from './bridge'
import {
  REVOCATION_RACE_PRESET,
  type ScenarioPreset,
} from './scenarios'
import {
  UNATTRIBUTED_OPERATOR_LABEL,
  type RevocationDeniedPayload,
} from './types'
import type { ExternalAgentRevocationV1 } from '../../types/externalAgent'

export type RevocationReasonCode = ExternalAgentRevocationV1['reason_code']

export const REVOCATION_REASON_OPTIONS: readonly {
  readonly code: RevocationReasonCode
  readonly label: string
  readonly description: string
}[] = [
  {
    code: 'operator-request',
    label: 'Operator Request',
    description: 'Manual operator-initiated decommissioning or administrative quarantine',
  },
  {
    code: 'credential-compromise',
    label: 'Credential Compromise',
    description: 'Suspected private key exfiltration or anomalous execution pattern',
  },
  {
    code: 'host-unenrolled',
    label: 'Host Unenrolled',
    description: 'Host sensor disconnected, decommissioned, or failed heartbeat',
  },
  {
    code: 'key-rotation',
    label: 'Key Rotation',
    description: 'Scheduled cryptographic credential rollover and retirement',
  },
  {
    code: 'credential-expired',
    label: 'Credential Expired',
    description: 'Validity window elapsed without valid renewal token',
  },
] as const

export interface AuditTimelineEvent {
  readonly id: string
  readonly timestamp: string
  readonly type: 'revocation_issued' | 'upload_denied' | 'binding_mismatch' | 'execution_error'
  readonly title: string
  readonly endpoint: string
  readonly operator: string
  readonly reasonCode?: RevocationReasonCode
  readonly reasonText?: string
  readonly targetHostId: string
  readonly targetAgentId: string
  readonly statusCode?: number
  readonly errorCode?: string
  readonly detailMessage: string
  readonly outcomeState: 'revoked' | 'denied' | 'error' | 'warning'
}

export interface DenialVerificationResult {
  readonly confirmed: boolean
  readonly statusCode: number
  readonly errorCode: string
  readonly rawResponseExcerpt?: string
  readonly isBindingMismatch: boolean
}

export interface RevocationPanelProps {
  readonly bridge: DemoBridge
  readonly preset?: ScenarioPreset
  readonly inFlight?: boolean
  readonly operatorId?: string
  readonly initialPayload?: RevocationDeniedPayload | null
  readonly agentId?: string
  readonly hostId?: string
  readonly keyId?: string
  readonly tenantId?: string
  readonly hostCredentialToken?: string
  readonly token?: string
  readonly transport?: LiveTransport
  readonly onOutcome?: (outcome: StageOutcome<'revocation_denied'>) => void
  readonly onRevocationComplete?: (payload: RevocationDeniedPayload) => void
}

/**
 * Extracts normalized error code from HTTP response body / error structures.
 */
export function extractErrorCode(data: unknown): string {
  if (!data || typeof data !== 'object') return ''
  const obj = data as Record<string, unknown>

  // 1. obj.error.code
  if (obj.error && typeof obj.error === 'object') {
    const errObj = obj.error as Record<string, unknown>
    if (typeof errObj.code === 'string') return errObj.code
  }

  // 2. obj.error as string
  if (typeof obj.error === 'string') return obj.error

  // 3. obj.error_code
  if (typeof obj.error_code === 'string') return obj.error_code

  // 4. obj.code
  if (typeof obj.code === 'string') return obj.code

  // 5. obj.detail.code or obj.detail
  if (obj.detail && typeof obj.detail === 'object') {
    const detObj = obj.detail as Record<string, unknown>
    if (typeof detObj.code === 'string') return detObj.code
  }
  if (typeof obj.detail === 'string') return obj.detail

  return ''
}

export function RevocationPanel({
  bridge,
  preset = REVOCATION_RACE_PRESET,
  inFlight = false,
  operatorId,
  initialPayload = null,
  agentId: propAgentId,
  hostId: propHostId,
  keyId: propKeyId,
  tenantId: propTenantId,
  hostCredentialToken,
  token = '',
  transport: propTransport,
  onOutcome,
  onRevocationComplete,
}: RevocationPanelProps): React.JSX.Element {
  // Session-derived targets: strictly derived from preset or session state, NO free-text input
  const targetHostId = propHostId || preset.host_id
  const targetAgentId = propAgentId || preset.agent_id
  const targetKeyId = propKeyId || `${preset.id}-key`
  const targetTenantId = propTenantId || preset.tenant_id

  const activeTransport = propTransport || defaultLiveTransport

  // Form State
  const [selectedReason, setSelectedReason] = useState<RevocationReasonCode | ''>('')
  const [customNotes, setCustomNotes] = useState<string>('')
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false)
  const [isVerifyingUpload, setIsVerifyingUpload] = useState<boolean>(false)
  const [revocationSettled, setRevocationSettled] = useState<boolean>(Boolean(initialPayload))

  // Persistence for selected reason (persists after form is settled)
  const [persistedReason, setPersistedReason] = useState<RevocationReasonCode | null>(null)

  // Verification & Denial State
  const [denialResult, setDenialResult] = useState<DenialVerificationResult | null>(
    initialPayload
      ? {
          confirmed: initialPayload.denialConfirmed,
          statusCode: initialPayload.responseStatusCode,
          errorCode: 'agent_revoked',
          isBindingMismatch: false,
        }
      : null
  )

  // Error States
  const [networkError, setNetworkError] = useState<string | null>(null)
  const [applicationError, setApplicationError] = useState<string | null>(null)

  // Audit Timeline Log
  const [timelineEvents, setTimelineEvents] = useState<AuditTimelineEvent[]>([])

  const channelDesc = useMemo(() => {
    return describeChannel({
      channel:
        bridge.channelKind === 'mock'
          ? { kind: 'mock', presetId: preset.id, fixtureSource: 'preset' }
          : {
              kind: 'live',
              requestPath: `/v1/external-agents/hosts/${targetHostId}/revoke`,
              transport: 'fetch',
            },
    })
  }, [bridge.channelKind, preset.id, targetHostId])

  // Operator attribution naming
  const operatorAttribution = useMemo(() => {
    if (bridge.channelKind === 'mock') {
      return `Mock Operator (${targetTenantId})`
    }
    return operatorId?.trim() || UNATTRIBUTED_OPERATOR_LABEL
  }, [bridge.channelKind, targetTenantId, operatorId])

  // Sync initial payload if provided after mount
  useEffect(() => {
    if (initialPayload) {
      setRevocationSettled(true)
      setDenialResult({
        confirmed: initialPayload.denialConfirmed,
        statusCode: initialPayload.responseStatusCode,
        errorCode: 'agent_revoked',
        isBindingMismatch: false,
      })
    }
  }, [initialPayload])

  // Disabled gate: async transition in flight or form is submitting
  const isDispatchDisabled = Boolean(
    inFlight || isSubmitting || !selectedReason || revocationSettled
  )

  /**
   * Helper to append an audit timeline event
   */
  const addTimelineEvent = useCallback((event: Omit<AuditTimelineEvent, 'id'>) => {
    const id = `rev-event-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
    setTimelineEvents((prev) => [...prev, { ...event, id }])
  }, [])

  /**
   * Constructs syntactically valid evidence assertion envelope matching exact credential binding.
   */
  const createBoundEvidenceEnvelope = useCallback(() => {
    return {
      assertion_envelope: {
        key_id: targetKeyId,
        assertions: [
          {
            agent_id: targetAgentId,
            host_id: targetHostId,
            evidence_type: 'artifact',
            sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          },
        ],
      },
      tenant_id: targetTenantId,
    }
  }, [targetKeyId, targetAgentId, targetHostId, targetTenantId])

  /**
   * Step 2: Attempt evidence upload and verify HTTP 403 'agent_revoked' denial
   */
  const verifyPostRevocationUpload = useCallback(
    async (revokedReason: RevocationReasonCode): Promise<DenialVerificationResult> => {
      setIsVerifyingUpload(true)
      setNetworkError(null)
      const nowIso = new Date().toISOString()
      const uploadPath = '/v1/external-agents/evidence-uploads'
      const envelope = createBoundEvidenceEnvelope()

      if (bridge.channelKind === 'mock') {
        // Mock channel verification: simulate 403 agent_revoked response
        const mockResult: DenialVerificationResult = {
          confirmed: true,
          statusCode: 403,
          errorCode: 'agent_revoked',
          isBindingMismatch: false,
          rawResponseExcerpt: `{"error":{"code":"agent_revoked","message":"External agent '${targetAgentId}' has been revoked: ${revokedReason}"}}`,
        }

        addTimelineEvent({
          timestamp: nowIso,
          type: 'upload_denied',
          title: 'Evidence Upload Denied (Post-Revocation Proof)',
          endpoint: '/api/v1/external-agents/evidence-uploads',
          operator: operatorAttribution,
          reasonCode: revokedReason,
          targetHostId,
          targetAgentId,
          statusCode: 403,
          errorCode: 'agent_revoked',
          detailMessage: `Upload rejected by authorization engine: agent '${targetAgentId}' revoked (reason: ${revokedReason})`,
          outcomeState: 'denied',
        })

        setDenialResult(mockResult)
        setIsVerifyingUpload(false)
        return mockResult
      }

      // Live channel: perform real HTTP upload call
      try {
        const effectiveToken = hostCredentialToken || token
        await activeTransport.req(uploadPath, effectiveToken, {
          method: 'POST',
          data: envelope,
        })

        // If upload unexpectedly succeeds on revoked host, that is a verification failure
        const unexpectedSuccess: DenialVerificationResult = {
          confirmed: false,
          statusCode: 202,
          errorCode: 'unexpected_upload_accepted',
          isBindingMismatch: false,
          rawResponseExcerpt: 'Upload accepted: expected 403 denial.',
        }
        addTimelineEvent({
          timestamp: nowIso,
          type: 'execution_error',
          title: 'Evidence Upload Unexpectedly Accepted',
          endpoint: '/api/v1/external-agents/evidence-uploads',
          operator: operatorAttribution,
          reasonCode: revokedReason,
          targetHostId,
          targetAgentId,
          statusCode: 202,
          errorCode: 'unexpected_upload_accepted',
          detailMessage: 'CRITICAL: Host credential was not revoked server-side.',
          outcomeState: 'error',
        })
        setDenialResult(unexpectedSuccess)
        return unexpectedSuccess
      } catch (err: unknown) {
        // Inspect HTTP error response
        const errObj = err as {
          status?: number
          response?: { status?: number; data?: unknown }
          data?: unknown
          message?: string
          name?: string
        }
        const httpStatus = errObj.response?.status ?? errObj.status ?? 0
        const responseData = errObj.response?.data ?? errObj.data

        const parsedErrorCode = extractErrorCode(responseData) || 'unknown_error'

        // Check for binding mismatch 403 codes
        const isMismatch = [
          'tenant_key_binding_mismatch',
          'tenant_agent_binding_mismatch',
          'tenant_host_binding_mismatch',
          'cross_tenant_forbidden',
        ].includes(parsedErrorCode)

        const isRevoked = httpStatus === 403 && parsedErrorCode === 'agent_revoked'

        const result: DenialVerificationResult = {
          confirmed: isRevoked,
          statusCode: httpStatus,
          errorCode: parsedErrorCode,
          isBindingMismatch: isMismatch,
          rawResponseExcerpt:
            typeof responseData === 'object'
              ? JSON.stringify(responseData)
              : String(errObj.message || err),
        }

        if (isRevoked) {
          addTimelineEvent({
            timestamp: nowIso,
            type: 'upload_denied',
            title: 'Evidence Upload Denied (403 agent_revoked)',
            endpoint: '/api/v1/external-agents/evidence-uploads',
            operator: operatorAttribution,
            reasonCode: revokedReason,
            targetHostId,
            targetAgentId,
            statusCode: 403,
            errorCode: 'agent_revoked',
            detailMessage: `Upload blocked with confirmed agent_revoked status on agent '${targetAgentId}'`,
            outcomeState: 'denied',
          })
        } else if (isMismatch) {
          addTimelineEvent({
            timestamp: nowIso,
            type: 'binding_mismatch',
            title: `Binding Mismatch 403 (${parsedErrorCode})`,
            endpoint: '/api/v1/external-agents/evidence-uploads',
            operator: operatorAttribution,
            reasonCode: revokedReason,
            targetHostId,
            targetAgentId,
            statusCode: 403,
            errorCode: parsedErrorCode,
            detailMessage: `Upload returned 403 due to envelope binding mismatch '${parsedErrorCode}', not revocation.`,
            outcomeState: 'warning',
          })
        } else {
          addTimelineEvent({
            timestamp: nowIso,
            type: 'execution_error',
            title: `Upload Verification Failed (${httpStatus || 'Network'})`,
            endpoint: '/api/v1/external-agents/evidence-uploads',
            operator: operatorAttribution,
            reasonCode: revokedReason,
            targetHostId,
            targetAgentId,
            statusCode: httpStatus,
            errorCode: parsedErrorCode,
            detailMessage: errObj.message || 'Upload verification request failed',
            outcomeState: 'error',
          })
        }

        setDenialResult(result)
        return result
      } finally {
        setIsVerifyingUpload(false)
      }
    },
    [
      bridge.channelKind,
      createBoundEvidenceEnvelope,
      hostCredentialToken,
      token,
      activeTransport,
      addTimelineEvent,
      operatorAttribution,
      targetHostId,
      targetAgentId,
    ]
  )

  /**
   * Step 1: Dispatch revocation call via bare path direct fetch
   */
  const handleDispatchRevocation = async () => {
    if (isDispatchDisabled || !selectedReason) return
    setIsSubmitting(true)
    setNetworkError(null)
    setApplicationError(null)
    const reasonCode = selectedReason
    setPersistedReason(reasonCode)
    const nowIso = new Date().toISOString()

    try {
      if (bridge.channelKind === 'mock') {
        // Advance mock bridge
        const outcome = await bridge.advance('revocation_denied')
        onOutcome?.(outcome)

        // Record revocation event
        addTimelineEvent({
          timestamp: nowIso,
          type: 'revocation_issued',
          title: 'Host Credential Revoked',
          endpoint: `/v1/external-agents/hosts/${targetHostId}/revoke`,
          operator: operatorAttribution,
          reasonCode,
          reasonText: customNotes || undefined,
          targetHostId,
          targetAgentId,
          statusCode: 200,
          detailMessage: `Revocation lease issued by ${operatorAttribution} with reason code '${reasonCode}'`,
          outcomeState: 'revoked',
        })

        setRevocationSettled(true)

        // Run subsequent upload verification
        const vResult = await verifyPostRevocationUpload(reasonCode)

        const payloadResult: RevocationDeniedPayload = {
          hostId: targetHostId,
          operatorAttribution,
          revokedAt: nowIso,
          attemptedEndpoint: '/api/v1/external-agents/evidence-uploads',
          responseStatusCode: 403,
          denialConfirmed: vResult.confirmed,
          proofDigest: `mock-proof-${targetHostId}-${reasonCode}`,
        }
        onRevocationComplete?.(payloadResult)
        return
      }

      // Live Channel: direct fetch to bare route /v1/external-agents/hosts/{host_id}/revoke
      const revokePath = `/v1/external-agents/hosts/${encodeURIComponent(targetHostId)}/revoke`

      let res: Response
      try {
        res = await activeTransport.fetch(revokePath, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(token ? { Authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify({
            reason_code: reasonCode,
            reason: customNotes || `Operator attributable revocation: ${reasonCode}`,
          }),
        })
      } catch (fetchErr: unknown) {
        // Network-level failure (DNS, connection refused, offline)
        const errMsg = fetchErr instanceof Error ? fetchErr.message : String(fetchErr)
        setNetworkError(`Could not reach backend at ${revokePath}: ${errMsg}`)
        addTimelineEvent({
          timestamp: nowIso,
          type: 'execution_error',
          title: 'Revocation Dispatch Network Failure',
          endpoint: revokePath,
          operator: operatorAttribution,
          reasonCode,
          targetHostId,
          targetAgentId,
          detailMessage: `Network transport failure: ${errMsg}`,
          outcomeState: 'error',
        })
        return
      }

      if (!res.ok) {
        const status = res.status
        let errBodyText = ''
        try {
          errBodyText = await res.text()
        } catch {
          /* ignore */
        }
        setApplicationError(`Backend returned HTTP ${status} on revocation request: ${errBodyText}`)
        addTimelineEvent({
          timestamp: nowIso,
          type: 'execution_error',
          title: `Revocation Rejected (HTTP ${status})`,
          endpoint: revokePath,
          operator: operatorAttribution,
          reasonCode,
          targetHostId,
          targetAgentId,
          statusCode: status,
          detailMessage: `Server rejected revocation: ${errBodyText}`,
          outcomeState: 'error',
        })
        return
      }

      // Successful revocation response
      addTimelineEvent({
        timestamp: nowIso,
        type: 'revocation_issued',
        title: 'Host Credential Revoked (Live API Confirmed)',
        endpoint: revokePath,
        operator: operatorAttribution,
        reasonCode,
        reasonText: customNotes || undefined,
        targetHostId,
        targetAgentId,
        statusCode: res.status,
        detailMessage: `Host '${targetHostId}' successfully revoked on tenant '${targetTenantId}' with reason '${reasonCode}'`,
        outcomeState: 'revoked',
      })

      setRevocationSettled(true)

      // Automatically execute Step 2: verify post-revocation upload denial
      const vResult = await verifyPostRevocationUpload(reasonCode)

      const payloadResult: RevocationDeniedPayload = {
        hostId: targetHostId,
        operatorAttribution,
        revokedAt: nowIso,
        attemptedEndpoint: '/api/v1/external-agents/evidence-uploads',
        responseStatusCode: 403,
        denialConfirmed: vResult.confirmed,
        proofDigest: `live-proof-${targetHostId}-${reasonCode}-${Date.now()}`,
      }
      onRevocationComplete?.(payloadResult)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      setApplicationError(msg)
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <div
      data-testid="revocation-panel"
      style={{
        backgroundColor: colors.slateDark,
        borderRadius: 6,
        border: `1px solid ${colors.elevatedSlate}`,
        padding: 24,
        display: 'flex',
        flexDirection: 'column',
        gap: 20,
      }}
    >
      {/* Header & Channel Indicator */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: colors.electricWhite }}>
              Stage 5: Attributable Revocation & 403 Denial Proof
            </h3>
            <span
              data-testid="revocation-channel-badge"
              style={{
                fontSize: 11,
                padding: '2px 8px',
                borderRadius: 4,
                backgroundColor: colors.elevatedSlate,
                color: bridge.channelKind === 'live' ? colors.tealLoom : colors.cyanLoom,
                fontWeight: 500,
              }}
            >
              {channelDesc.label}
            </span>
          </div>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: colors.muted }}>
            Revoke host credential with mandatory attribution reason, then verify subsequent
            telemetry upload returns verified 403 Forbidden with error code{' '}
            <code style={{ color: colors.cyanLoom, fontSize: 12 }}>agent_revoked</code>.
          </p>
        </div>

        {/* Action Status Badge */}
        {denialResult?.confirmed && (
          <div
            data-testid="revocation-denial-badge"
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
              padding: '6px 12px',
              borderRadius: 4,
              backgroundColor: 'rgba(239, 68, 68, 0.15)',
              border: `1px solid ${colors.red}`,
              color: colors.red,
              fontWeight: 600,
              fontSize: 12,
              fontFamily: 'monospace',
            }}
          >
            <span
              style={{
                display: 'inline-block',
                width: 8,
                height: 8,
                borderRadius: '50%',
                backgroundColor: colors.red,
              }}
            />
            403 FORBIDDEN • agent_revoked
          </div>
        )}
      </div>

      {/* Target Binding & Security Guard Metadata */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))',
          gap: 12,
          padding: 14,
          backgroundColor: colors.deepMidnight,
          border: `1px solid ${colors.elevatedSlate}`,
          borderRadius: 4,
          fontSize: 12,
        }}
      >
        <div>
          <span style={{ color: colors.muted, display: 'block', fontSize: 11 }}>
            Target Host ID (Session Bound)
          </span>
          <span
            data-testid="revocation-target-host"
            style={{ color: colors.electricWhite, fontFamily: 'monospace', fontWeight: 600 }}
          >
            {targetHostId}
          </span>
        </div>

        <div>
          <span style={{ color: colors.muted, display: 'block', fontSize: 11 }}>
            Bound Agent ID
          </span>
          <span
            data-testid="revocation-target-agent"
            style={{ color: colors.electricWhite, fontFamily: 'monospace' }}
          >
            {targetAgentId}
          </span>
        </div>

        <div>
          <span style={{ color: colors.muted, display: 'block', fontSize: 11 }}>
            Triggering Operator
          </span>
          <span
            data-testid="revocation-operator-attribution"
            style={{
              color: operatorAttribution.startsWith('UNATTRIBUTED') ? colors.amber : colors.tealLoom,
              fontWeight: 500,
            }}
          >
            {operatorAttribution}
          </span>
        </div>

        <div>
          <span style={{ color: colors.muted, display: 'block', fontSize: 11 }}>
            Revocation Endpoint (Bare Path)
          </span>
          <span style={{ color: colors.dim, fontFamily: 'monospace', fontSize: 11 }}>
            POST /v1/external-agents/hosts/{targetHostId}/revoke
          </span>
        </div>
      </div>

      {/* Form Controls: Attributable Reason Selector */}
      {!revocationSettled && (
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
            padding: 16,
            backgroundColor: colors.elevatedSlate,
            borderRadius: 4,
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <label
              htmlFor="revocation-reason-select"
              style={{ fontSize: 13, fontWeight: 600, color: colors.electricWhite }}
            >
              Attribution Reason Code <span style={{ color: colors.red }}>*</span>
            </label>
            <select
              id="revocation-reason-select"
              data-testid="revocation-reason-select"
              value={selectedReason}
              onChange={(e) => setSelectedReason(e.target.value as RevocationReasonCode | '')}
              disabled={isSubmitting || inFlight}
              style={{
                padding: '8px 12px',
                borderRadius: 4,
                backgroundColor: colors.deepMidnight,
                color: colors.electricWhite,
                border: `1px solid ${selectedReason ? colors.tealLoom : colors.dim}`,
                fontSize: 13,
                outline: 'none',
                cursor: 'pointer',
              }}
            >
              <option value="" disabled>
                -- Select Mandatory Attribution Reason --
              </option>
              {REVOCATION_REASON_OPTIONS.map((opt) => (
                <option key={opt.code} value={opt.code}>
                  {opt.label} ({opt.code})
                </option>
              ))}
            </select>
            {selectedReason && (
              <span style={{ fontSize: 11, color: colors.muted }}>
                {REVOCATION_REASON_OPTIONS.find((o) => o.code === selectedReason)?.description}
              </span>
            )}
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <label
              htmlFor="revocation-notes-input"
              style={{ fontSize: 12, color: colors.muted }}
            >
              Operator Audit Notes (Optional)
            </label>
            <input
              id="revocation-notes-input"
              data-testid="revocation-notes-input"
              type="text"
              placeholder="e.g. Host sensor flagged by anomalous out-of-bounds syscall alert"
              value={customNotes}
              onChange={(e) => setCustomNotes(e.target.value)}
              disabled={isSubmitting || inFlight}
              style={{
                padding: '6px 10px',
                borderRadius: 4,
                backgroundColor: colors.deepMidnight,
                color: colors.electricWhite,
                border: `1px solid ${colors.dim}`,
                fontSize: 12,
                outline: 'none',
              }}
            />
          </div>

          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 4 }}>
            <button
              type="button"
              data-testid="revocation-dispatch-btn"
              onClick={handleDispatchRevocation}
              disabled={isDispatchDisabled}
              style={{
                padding: '8px 18px',
                borderRadius: 4,
                backgroundColor: isDispatchDisabled ? colors.dim : colors.red,
                color: colors.electricWhite,
                border: 'none',
                fontWeight: 600,
                fontSize: 13,
                cursor: isDispatchDisabled ? 'not-allowed' : 'pointer',
                opacity: isDispatchDisabled ? 0.6 : 1,
                transition: 'background-color 0.2s, opacity 0.2s',
              }}
            >
              {isSubmitting ? 'Revoking Host...' : 'Revoke Host Credential'}
            </button>
          </div>
        </div>
      )}

      {/* Network Failure State */}
      {networkError && (
        <div
          data-testid="revocation-network-error"
          style={{
            padding: 12,
            backgroundColor: 'rgba(239, 68, 68, 0.1)',
            border: `1px solid ${colors.red}`,
            borderRadius: 4,
            color: colors.red,
            fontSize: 13,
          }}
        >
          <div style={{ fontWeight: 600, marginBottom: 4 }}>Could not reach backend</div>
          <div style={{ fontSize: 12, color: colors.muted }}>{networkError}</div>
        </div>
      )}

      {/* Application Error State */}
      {applicationError && (
        <div
          data-testid="revocation-application-error"
          style={{
            padding: 12,
            backgroundColor: 'rgba(245, 158, 11, 0.1)',
            border: `1px solid ${colors.amber}`,
            borderRadius: 4,
            color: colors.amber,
            fontSize: 13,
          }}
        >
          <div style={{ fontWeight: 600, marginBottom: 4 }}>Application Request Failure</div>
          <div style={{ fontSize: 12 }}>{applicationError}</div>
        </div>
      )}

      {/* Post-Revocation Actions & Re-test trigger */}
      {revocationSettled && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: 14,
            backgroundColor: colors.elevatedSlate,
            borderRadius: 4,
          }}
        >
          <div>
            <span style={{ fontSize: 13, fontWeight: 600, color: colors.electricWhite, display: 'block' }}>
              Host Credential Revoked
            </span>
            <span style={{ fontSize: 12, color: colors.muted }}>
              Attributed reason:{' '}
              <strong style={{ color: colors.tealLoom }}>{persistedReason || 'operator-request'}</strong>
            </span>
          </div>

          <button
            type="button"
            data-testid="upload-attempt-trigger-btn"
            onClick={() => verifyPostRevocationUpload(persistedReason || 'operator-request')}
            disabled={isVerifyingUpload || inFlight}
            style={{
              padding: '6px 14px',
              borderRadius: 4,
              backgroundColor: colors.deepMidnight,
              color: colors.cyanLoom,
              border: `1px solid ${colors.cyanLoom}`,
              fontSize: 12,
              fontWeight: 500,
              cursor: isVerifyingUpload ? 'wait' : 'pointer',
            }}
          >
            {isVerifyingUpload ? 'Testing Upload...' : 'Re-verify 403 Upload Denial'}
          </button>
        </div>
      )}

      {/* Binding Mismatch Warning (if tripped instead of agent_revoked) */}
      {denialResult?.isBindingMismatch && (
        <div
          data-testid="revocation-binding-mismatch-warning"
          style={{
            padding: 12,
            backgroundColor: 'rgba(245, 158, 11, 0.15)',
            border: `1px solid ${colors.amber}`,
            borderRadius: 4,
            color: colors.amber,
            fontSize: 12,
          }}
        >
          <strong>Notice:</strong> 403 returned error code{' '}
          <code style={{ fontWeight: 600 }}>{denialResult.errorCode}</code> (Binding Mismatch)
          instead of <code style={{ fontWeight: 600 }}>agent_revoked</code>. Check envelope
          key/agent/host alignment.
        </div>
      )}

      {/* Cryptographic Audit Timeline */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <h4
          style={{
            margin: 0,
            fontSize: 13,
            fontWeight: 600,
            color: colors.electricWhite,
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
          }}
        >
          Attributable Security Audit Timeline
        </h4>

        <div
          data-testid="revocation-timeline"
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${colors.elevatedSlate}`,
            borderRadius: 4,
            padding: 12,
          }}
        >
          {timelineEvents.length === 0 ? (
            <div style={{ fontSize: 12, color: colors.dim, fontStyle: 'italic', padding: 8 }}>
              No revocation events recorded yet. Select an attributable reason and dispatch revocation to begin.
            </div>
          ) : (
            timelineEvents.map((event) => {
              const isRevokeEvent = event.type === 'revocation_issued'
              const isDeniedEvent = event.type === 'upload_denied'

              return (
                <div
                  key={event.id}
                  data-testid={
                    isRevokeEvent
                      ? 'revocation-timeline-event-revoked'
                      : isDeniedEvent
                        ? 'revocation-timeline-event-denied'
                        : `revocation-timeline-event-${event.type}`
                  }
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 4,
                    padding: 10,
                    backgroundColor: colors.slateDark,
                    borderLeft: `3px solid ${
                      event.outcomeState === 'denied'
                        ? colors.red
                        : event.outcomeState === 'revoked'
                          ? colors.amber
                          : event.outcomeState === 'warning'
                            ? colors.amber
                            : colors.tealLoom
                    }`,
                    borderRadius: 2,
                  }}
                >
                  <div
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                      fontSize: 12,
                    }}
                  >
                    <span style={{ fontWeight: 600, color: colors.electricWhite }}>
                      {event.title}
                    </span>
                    <span style={{ fontSize: 11, color: colors.dim, fontFamily: 'monospace' }}>
                      {event.timestamp}
                    </span>
                  </div>

                  <div style={{ fontSize: 12, color: colors.muted, display: 'flex', flexWrap: 'wrap', gap: 12 }}>
                    <span>
                      Endpoint:{' '}
                      <code style={{ color: colors.cyanLoom, fontSize: 11 }}>{event.endpoint}</code>
                    </span>
                    <span>
                      Operator: <strong style={{ color: colors.electricWhite }}>{event.operator}</strong>
                    </span>
                    {event.reasonCode && (
                      <span data-testid="timeline-reason-code">
                        Reason:{' '}
                        <span
                          style={{
                            padding: '1px 6px',
                            borderRadius: 3,
                            backgroundColor: colors.elevatedSlate,
                            color: colors.tealLoom,
                            fontSize: 11,
                            fontWeight: 600,
                          }}
                        >
                          {event.reasonCode}
                        </span>
                      </span>
                    )}
                    {event.statusCode && (
                      <span>
                        HTTP Status:{' '}
                        <strong
                          style={{
                            color: event.statusCode === 403 ? colors.red : colors.tealLoom,
                            fontFamily: 'monospace',
                          }}
                        >
                          {event.statusCode}
                        </strong>
                      </span>
                    )}
                  </div>

                  <div style={{ fontSize: 11, color: colors.dim, marginTop: 2 }}>
                    {event.detailMessage}
                  </div>
                </div>
              )
            })
          )}
        </div>
      </div>
    </div>
  )
}

export default RevocationPanel
