import React, { useState, useMemo, useEffect } from 'react'
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
import { UNATTRIBUTED_OPERATOR_LABEL, type HostEnrolledPayload } from './types'

export interface EnrollmentPanelProps {
  readonly bridge: DemoBridge
  readonly preset?: ScenarioPreset
  readonly inFlight?: boolean
  readonly operatorId?: string
  readonly initialPayload?: HostEnrolledPayload | null
  readonly onOutcome?: (outcome: StageOutcome<'host_enrolled'>) => void
  readonly onEnrolled?: (payload: HostEnrolledPayload) => void
}

export function EnrollmentPanel({
  bridge,
  preset = HAPPY_PATH_PRESET,
  inFlight = false,
  operatorId,
  initialPayload = null,
  onOutcome,
  onEnrolled,
}: EnrollmentPanelProps): React.JSX.Element {
  const [payload, setPayload] = useState<HostEnrolledPayload | null>(initialPayload)

  // When a controller owns the transition the resolved payload arrives as a prop after
  // this component has already mounted, so seeding state once at mount is not enough.
  useEffect(() => {
    if (initialPayload) setPayload(initialPayload)
  }, [initialPayload])
  const [isSubmitting, setIsSubmitting] = useState<boolean>(false)
  const [error, setError] = useState<string | null>(null)
  const [copiedField, setCopiedField] = useState<string | null>(null)

  const channelDesc = useMemo(() => {
    return describeChannel({
      channel:
        bridge.channelKind === 'mock'
          ? { kind: 'mock', presetId: preset.id, fixtureSource: 'preset' }
          : {
              kind: 'live',
              requestPath: '/api/v1/external-agents/enroll',
              transport: 'req',
            },
    })
  }, [bridge.channelKind, preset.id])

  // Attributable enrollment: names the triggering operator or the explicit mock principal.
  // The live branch must name a principal the session authenticated; when none is
  // available it renders UNATTRIBUTED_OPERATOR_LABEL rather than inventing an account.
  const operatorAttribution = useMemo(() => {
    if (bridge.channelKind === 'mock') {
      return `Mock Operator (${preset.tenant_id})`
    }
    return operatorId?.trim() || UNATTRIBUTED_OPERATOR_LABEL
  }, [bridge.channelKind, preset.tenant_id, operatorId])

  const isAttributed =
    bridge.channelKind === 'mock' || Boolean(operatorId?.trim())

  // Key algorithm and revocation endpoint derived from real schema / preset
  const keyAlgorithm = 'Ed25519'
  const revocationEndpoint = `/v1/external-agents/${preset.agent_id}/revocations`

  const isDisabled = Boolean(inFlight || isSubmitting)

  const handleEnrollHost = async () => {
    if (isDisabled) return
    setIsSubmitting(true)
    setError(null)
    try {
      const outcome = await bridge.advance('host_enrolled')
      onOutcome?.(outcome)
      if (outcome.status === 'ok') {
        setPayload(outcome.payload)
        onEnrolled?.(outcome.payload)
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

  const handleCopy = async (field: string, text: string) => {
    if (navigator?.clipboard?.writeText) {
      try {
        await navigator.clipboard.writeText(text)
        setCopiedField(field)
        setTimeout(() => setCopiedField(null), 2000)
      } catch {
        /* clipboard access failed */
      }
    }
  }

  return (
    <div
      data-testid="enrollment-panel"
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
              Stage 2: Host Ed25519 Enrollment
            </h3>
            <span
              data-testid="enrollment-channel-badge"
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
            Exchange one-time token for Ed25519 host credential and register sensor.
          </p>
        </div>

        {/* Primary Action Button */}
        <button
          type="button"
          data-testid="host-enroll-btn"
          disabled={isDisabled}
          onClick={handleEnrollHost}
          style={{
            backgroundColor: isDisabled ? colors.elevatedSlate : colors.tealLoom,
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
          {isSubmitting ? 'Enrolling Host...' : 'Enroll Host'}
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
        POST /api/v1/external-agents/enroll
      </div>

      {/* Error Display */}
      {error && (
        <div
          data-testid="enrollment-error"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${colors.red}`,
            borderRadius: 4,
            padding: 12,
            color: colors.red,
            fontSize: 13,
          }}
        >
          <strong>Enrollment Failed:</strong> {error}
        </div>
      )}

      {/* Enrollment Results Display */}
      {payload && (
        <div
          data-testid="enrollment-result"
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
          {/* Attributable Enrollment Record */}
          <div
            data-testid="enrollment-attribution-record"
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
              <span
                data-testid="enrollment-attribution-principal"
                data-attributed={isAttributed ? 'true' : 'false'}
                style={{
                  fontFamily: 'monospace',
                  fontWeight: 600,
                  color: isAttributed ? colors.electricWhite : colors.amber,
                }}
              >
                {operatorAttribution}
              </span>
            </div>
            {bridge.channelKind === 'mock' && (
              <div style={{ fontSize: 11, color: colors.cyanLoom, textAlign: 'right' }}>
                [mock principal: {preset.tenant_id}]
              </div>
            )}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Enrolled At:</span>
              <span style={{ fontFamily: 'monospace' }}>{payload.enrolledAt}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Host ID:</span>
              <span style={{ fontFamily: 'monospace' }}>{payload.hostId}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Agent ID:</span>
              <span style={{ fontFamily: 'monospace' }}>{payload.agentId}</span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ color: colors.muted }}>Enrollment Status:</span>
              <span
                style={{
                  color: payload.status === 'enrolled' ? colors.tealLoom : colors.amber,
                  fontWeight: 600,
                  textTransform: 'uppercase',
                  fontSize: 11,
                }}
              >
                {payload.status}
              </span>
            </div>
          </div>

          {/* Cryptographic Scheme & Read-Only Ed25519 Badge */}
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
            <span style={{ fontSize: 12, color: colors.muted }}>Cryptographic Scheme:</span>
            <span
              data-testid="key-algorithm-badge"
              style={{
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: 700,
                backgroundColor: colors.elevatedSlate,
                color: colors.cyanLoom,
                padding: '3px 8px',
                borderRadius: 4,
                border: `1px solid ${colors.cyanLoom}`,
              }}
            >
              {keyAlgorithm}
            </span>
          </div>

          {/* Public Key Fingerprint */}
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
            <span style={{ fontSize: 12, color: colors.muted }}>Public Key Fingerprint:</span>
            <span
              data-testid="public-key-fingerprint"
              style={{
                fontFamily: 'monospace',
                fontSize: 12,
                color: colors.electricWhite,
              }}
            >
              {payload.publicKeyFingerprint}
            </span>
          </div>

          {/* Read-Only Revocation Endpoint */}
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 6,
              backgroundColor: colors.slateDark,
              padding: '12px 14px',
              borderRadius: 4,
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontSize: 12, color: colors.muted, fontWeight: 500 }}>
                Bound Revocation Endpoint (read-only):
              </span>
              <button
                type="button"
                data-testid="copy-revocation-endpoint-btn"
                onClick={() => handleCopy('revocation', revocationEndpoint)}
                style={{
                  backgroundColor: colors.elevatedSlate,
                  color: colors.electricWhite,
                  border: 'none',
                  borderRadius: 4,
                  padding: '3px 8px',
                  fontSize: 11,
                  cursor: 'pointer',
                }}
              >
                {copiedField === 'revocation' ? 'Copied!' : 'Copy Path'}
              </button>
            </div>
            {/* Strictly read-only copyable display, NOT an editable input */}
            <div
              data-testid="revocation-endpoint"
              tabIndex={0}
              role="textbox"
              aria-readonly="true"
              style={{
                fontFamily: 'monospace',
                fontSize: 12,
                color: colors.amber,
                backgroundColor: colors.deepMidnight,
                padding: '8px 10px',
                borderRadius: 4,
                userSelect: 'all',
                wordBreak: 'break-all',
              }}
            >
              {revocationEndpoint}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
