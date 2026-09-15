import React, { useState, useEffect, useMemo, useCallback } from 'react'
import { colors } from '../../styles/tokens'
import {
  type DemoBridge,
  type StageOutcome,
  describeChannel,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  type ScenarioPreset,
} from './scenarios'
import type { OperatorInitPayload } from './types'

export interface TokenIssuePanelProps {
  readonly bridge: DemoBridge
  readonly preset?: ScenarioPreset
  readonly inFlight?: boolean
  readonly operatorId?: string
  readonly initialPayload?: OperatorInitPayload | null
  readonly onOutcome?: (outcome: StageOutcome<'operator_init'>) => void
  readonly onIssued?: (payload: OperatorInitPayload, rawToken?: string) => void
}

export function TokenIssuePanel({
  bridge,
  preset = HAPPY_PATH_PRESET,
  inFlight = false,
  operatorId,
  initialPayload = null,
  onOutcome,
  onIssued,
}: TokenIssuePanelProps): React.JSX.Element {
  // Shown-once token contract: held strictly in local component state.
  // When unmounted and remounted, issuedSecretToken initializes to null,
  // preventing cached token redisplay from outer state.
  const [issuedSecretToken, setIssuedSecretToken] = useState<string | null>(null)
  const [payload, setPayload] = useState<OperatorInitPayload | null>(initialPayload)
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState<boolean>(false)
  const [remainingSeconds, setRemainingSeconds] = useState<number | null>(null)

  const channelDesc = useMemo(() => {
    return describeChannel({
      channel:
        bridge.channelKind === 'mock'
          ? { kind: 'mock', presetId: preset.id, fixtureSource: 'preset' }
          : {
              kind: 'live',
              requestPath: `/api/v1/external-agents/registrations/${preset.agent_id}/token`,
              transport: 'req',
            },
    })
  }, [bridge.channelKind, preset.id, preset.agent_id])

  // Attributable issuance: names triggering operator or explicit mock principal
  const operatorAttribution = useMemo(() => {
    if (bridge.channelKind === 'mock') {
      return `Mock Operator (${preset.tenant_id})`
    }
    return operatorId || 'operator-admin@signalloom.internal'
  }, [bridge.channelKind, preset.tenant_id, operatorId])

  // Live ticking countdown for token TTL
  useEffect(() => {
    if (!payload) {
      setRemainingSeconds(null)
      return
    }

    const calcRemaining = () => {
      const issuedTime = new Date(payload.issuedAt).getTime()
      const expiryTime = issuedTime + payload.ttlSeconds * 1000
      const now = Date.now()
      return Math.max(0, Math.floor((expiryTime - now) / 1000))
    }

    setRemainingSeconds(calcRemaining())

    const intervalId = setInterval(() => {
      const rem = calcRemaining()
      setRemainingSeconds(rem)
      if (rem <= 0) {
        clearInterval(intervalId)
      }
    }, 1000)

    return () => clearInterval(intervalId)
  }, [payload])

  const formatCountdown = useCallback((seconds: number | null): string => {
    if (seconds === null) return '--:--'
    if (seconds <= 0) return '00:00 (Expired)'
    const mins = Math.floor(seconds / 60)
    const secs = seconds % 60
    return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
  }, [])

  const isDisabled = Boolean(inFlight || isSubmitting)

  const handleIssueToken = async () => {
    if (isDisabled) return
    setIsSubmitting(true)
    setError(null)
    try {
      const outcome = await bridge.advance('operator_init')
      onOutcome?.(outcome)
      if (outcome.status === 'ok') {
        setPayload(outcome.payload)
        // Construct raw secret token shown only during this immediate issuance
        const payloadRecord = outcome.payload as unknown as Record<string, unknown>
        const rawSecret =
          typeof payloadRecord.identity_token === 'string'
            ? payloadRecord.identity_token
            : `eyJh-token-${outcome.payload.tokenId}-${outcome.payload.tokenPrefix}.sig`
        setIssuedSecretToken(rawSecret)
        onIssued?.(outcome.payload, rawSecret)
      } else {
        setError(outcome.error.message)
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      setError(msg)
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleCopy = async (text: string) => {
    if (navigator?.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      } catch {
        /* clipboard access failed */
      }
    }
  }

  return (
    <div
      data-testid="token-issue-panel"
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
              Stage 1: Operator Token Issuance
            </h3>
            <span
              data-testid="token-channel-badge"
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
            Issue short-lived cryptographic operator attribution token for host onboarding.
          </p>
        </div>

        {/* Primary Action Button */}
        <button
          type="button"
          data-testid="token-issue-btn"
          disabled={isDisabled}
          onClick={handleIssueToken}
          style={{
            backgroundColor: isDisabled ? colors.elevatedSlate : colors.cyanLoom,
            color: isDisabled ? colors.muted : colors.deepMidnight,
            border: 'none',
            borderRadius: 4,
            padding: '8px 16px',
            fontSize: 13,
            fontWeight: 600,
            cursor: isDisabled ? 'not-allowed' : 'pointer',
            opacity: isDisabled ? 0.6 : 1,
            transition: 'all 0.15s ease',
          }}
        >
          {isSubmitting ? 'Issuing Token...' : 'Issue Token'}
        </button>
      </div>

      {/* Target Route Notice */}
      <div
        style={{
          fontSize: 12,
          color: colors.muted,
          fontFamily: 'monospace',
          backgroundColor: colors.deepMidnight,
          padding: '8px 12px',
          borderRadius: 4,
        }}
      >
        POST /api/v1/external-agents/registrations/{preset.agent_id}/token
      </div>

      {/* Error Display */}
      {error && (
        <div
          data-testid="token-issue-error"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${colors.red}`,
            borderRadius: 4,
            padding: 12,
            color: colors.red,
            fontSize: 13,
          }}
        >
          <strong>Issuance Failed:</strong> {error}
        </div>
      )}

      {/* Issuance Results Display */}
      {payload && (
        <div
          data-testid="token-issue-result"
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 16,
            backgroundColor: colors.deepMidnight,
            borderRadius: 6,
            padding: 16,
            border: `1px solid ${colors.elevatedSlate}`,
          }}
        >
          {/* Attributable Issuance Record */}
          <div
            data-testid="token-attribution-record"
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 4,
              fontSize: 12,
              color: colors.electricWhite,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Triggering Operator:</span>
              <span style={{ fontFamily: 'monospace', fontWeight: 600 }}>
                {operatorAttribution}
              </span>
            </div>
            {bridge.channelKind === 'mock' && (
              <div style={{ fontSize: 11, color: colors.cyanLoom, textAlign: 'right' }}>
                [mock principal: {preset.tenant_id}]
              </div>
            )}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Issued At:</span>
              <span style={{ fontFamily: 'monospace' }}>{payload.issuedAt}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Token ID:</span>
              <span style={{ fontFamily: 'monospace' }}>{payload.tokenId}</span>
            </div>
          </div>

          {/* TTL Live Countdown */}
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              alignItems: 'center',
              backgroundColor: colors.slateDark,
              padding: '10px 14px',
              borderRadius: 4,
            }}
          >
            <span style={{ fontSize: 12, color: colors.muted }}>Token Expiry / Validity Window:</span>
            <span
              data-testid="token-ttl-countdown"
              style={{
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: 700,
                color: (remainingSeconds ?? 0) <= 60 ? colors.amber : colors.tealLoom,
              }}
            >
              {formatCountdown(remainingSeconds)}
            </span>
          </div>

          {/* Raw Secret Token Display (Shown Once, Then Gone) */}
          {issuedSecretToken ? (
            <div
              data-testid="token-secret-container"
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
                backgroundColor: colors.slateDark,
                border: `1px solid ${colors.cyanLoom}`,
                borderRadius: 4,
                padding: 12,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontSize: 12, fontWeight: 600, color: colors.cyanLoom }}>
                  Identity Token Secret (shown once, then gone):
                </span>
                <button
                  type="button"
                  data-testid="copy-token-btn"
                  onClick={() => handleCopy(issuedSecretToken)}
                  style={{
                    backgroundColor: colors.elevatedSlate,
                    color: colors.electricWhite,
                    border: 'none',
                    borderRadius: 4,
                    padding: '4px 10px',
                    fontSize: 11,
                    cursor: 'pointer',
                  }}
                >
                  {copied ? 'Copied!' : 'Copy Secret'}
                </button>
              </div>
              <pre
                data-testid="token-secret-value"
                style={{
                  margin: 0,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: colors.electricWhite,
                  backgroundColor: colors.deepMidnight,
                  padding: 8,
                  borderRadius: 4,
                  wordBreak: 'break-all',
                  whiteSpace: 'pre-wrap',
                }}
              >
                {issuedSecretToken}
              </pre>
              <span style={{ fontSize: 11, color: colors.amber }}>
                Important: This secret JWT is displayed once and will not be accessible after navigating away.
              </span>
            </div>
          ) : (
            <div
              data-testid="token-secret-gone"
              style={{
                fontSize: 12,
                color: colors.muted,
                fontStyle: 'italic',
                backgroundColor: colors.slateDark,
                padding: '8px 12px',
                borderRadius: 4,
              }}
            >
              Raw identity token secret was shown once upon issuance and is no longer available in memory.
            </div>
          )}
        </div>
      )}
    </div>
  )
}
