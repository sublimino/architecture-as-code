import React, { useState, useEffect, useMemo, useRef, useCallback } from 'react'
import { colors } from '../../styles/tokens'
import {
  type DemoBridge,
  type StageOutcome,
  describeChannel,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  TAMPER_BREACH_PRESET,
  type ScenarioPreset,
} from './scenarios'
import type { ConfinementStreamingPayload } from './types'

export interface ArtifactHashItem {
  readonly artifactId: string
  readonly rootId: 'agent-work' | 'agent-output' | string
  readonly expectedSha256: string
  readonly computedSha256: string
  readonly sizeBytes: number
  readonly mtimeNs?: string
  readonly status: 'match' | 'mismatch'
}

export type SourceHealthState = 'healthy' | 'degraded' | 'unavailable'

export interface ConfinementTelemetryPanelProps {
  readonly bridge: DemoBridge
  readonly preset?: ScenarioPreset
  readonly inFlight?: boolean
  readonly initialPayload?: ConfinementStreamingPayload | null
  readonly pollIntervalMs?: number
  readonly debounceMs?: number
  readonly customArtifacts?: readonly ArtifactHashItem[]
  readonly onOutcome?: (outcome: StageOutcome<'confinement_streaming'>) => void
  readonly onTelemetryPolled?: (payload: ConfinementStreamingPayload) => void
}

/**
 * Format bytes to MB with 2 decimal places.
 */
export function formatBytesToMb(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0.00 MB'
  const mb = bytes / (1024 * 1024)
  return `${mb.toFixed(2)} MB`
}

/**
 * Format milliseconds into ms and seconds display.
 */
export function formatCpuTime(ms: number): { formattedMs: string; formattedSec: string } {
  const safeMs = Number.isFinite(ms) && ms >= 0 ? ms : 0
  const formattedMs = `${safeMs.toLocaleString()} ms`
  const sec = safeMs / 1000
  const formattedSec = `${sec.toFixed(2)} s`
  return { formattedMs, formattedSec }
}

/**
 * Formats epoch timestamp or Date to HH:MM:SS format.
 */
export function formatTimeHms(timestamp: number | Date | string): string {
  const date =
    typeof timestamp === 'number'
      ? new Date(timestamp)
      : typeof timestamp === 'string'
        ? new Date(timestamp)
        : timestamp
  if (Number.isNaN(date.getTime())) return '--:--:--'
  const hours = String(date.getHours()).padStart(2, '0')
  const minutes = String(date.getMinutes()).padStart(2, '0')
  const seconds = String(date.getSeconds()).padStart(2, '0')
  return `${hours}:${minutes}:${seconds}`
}

/**
 * Derives default artifact comparison list for a preset and payload.
 */
export function deriveArtifactsForPreset(
  preset: ScenarioPreset,
  payload: ConfinementStreamingPayload | null
): ArtifactHashItem[] {
  // If payload has expectedSha256 and observedSha256 and they differ, or if preset is tamper breach
  const isTamper =
    preset.id === TAMPER_BREACH_PRESET.id ||
    (payload !== null && payload.expectedSha256 !== payload.observedSha256)

  const baselineDigest =
    payload?.expectedSha256 ??
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  const observedDigest =
    payload?.observedSha256 ??
    (isTamper
      ? 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      : baselineDigest)

  if (isTamper) {
    return [
      {
        artifactId: 'artifact-demo-001',
        rootId: 'agent-work',
        expectedSha256: baselineDigest,
        computedSha256: observedDigest,
        sizeBytes: 14320,
        mtimeNs: '1726365600000000000',
        status: baselineDigest === observedDigest ? 'match' : 'mismatch',
      },
      {
        artifactId: 'artifact-output-002',
        rootId: 'agent-output',
        expectedSha256: '2ea2db69b227faaf5a2d69cef2a23b6d7b20c2f572c58405bc1ed6902f22229d',
        computedSha256: '2ea2db69b227faaf5a2d69cef2a23b6d7b20c2f572c58405bc1ed6902f22229d',
        sizeBytes: 8192,
        mtimeNs: '1726365601000000000',
        status: 'match',
      },
    ]
  }

  return [
    {
      artifactId: 'artifact-work-001',
      rootId: 'agent-work',
      expectedSha256: baselineDigest,
      computedSha256: observedDigest,
      sizeBytes: 14320,
      mtimeNs: '1726365600000000000',
      status: baselineDigest === observedDigest ? 'match' : 'mismatch',
    },
    {
      artifactId: 'artifact-output-002',
      rootId: 'agent-output',
      expectedSha256: '2ea2db69b227faaf5a2d69cef2a23b6d7b20c2f572c58405bc1ed6902f22229d',
      computedSha256: '2ea2db69b227faaf5a2d69cef2a23b6d7b20c2f572c58405bc1ed6902f22229d',
      sizeBytes: 8192,
      mtimeNs: '1726365601000000000',
      status: 'match',
    },
    {
      artifactId: 'artifact-output-003',
      rootId: 'agent-output',
      expectedSha256: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
      computedSha256: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
      sizeBytes: 24576,
      mtimeNs: '1726365602000000000',
      status: 'match',
    },
  ]
}

export function ConfinementTelemetryPanel({
  bridge,
  preset = HAPPY_PATH_PRESET,
  inFlight = false,
  initialPayload = null,
  pollIntervalMs = 2500,
  debounceMs = 150,
  customArtifacts,
  onOutcome,
  onTelemetryPolled,
}: ConfinementTelemetryPanelProps): React.JSX.Element {
  const [payload, setPayload] = useState<ConfinementStreamingPayload | null>(initialPayload)
  const [sourceHealth, setSourceHealth] = useState<SourceHealthState>('healthy')
  const [lastPolledAt, setLastPolledAt] = useState<string>('--:--:--')
  const [displayCpuTicks, setDisplayCpuTicks] = useState<number>(initialPayload?.cpuTicks ?? 0)
  const [displayRssBytes, setDisplayRssBytes] = useState<number>(initialPayload?.rssBytes ?? 0)
  const [isFetching, setIsFetching] = useState<boolean>(false)
  const [error, setError] = useState<string | null>(null)

  const isMountedRef = useRef<boolean>(true)
  const pollTimerRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Seed state when initialPayload updates
  useEffect(() => {
    if (initialPayload) {
      setPayload(initialPayload)
      setDisplayCpuTicks(initialPayload.cpuTicks)
      setDisplayRssBytes(initialPayload.rssBytes)
    }
  }, [initialPayload])

  const channelDesc = useMemo(() => {
    return describeChannel({
      channel:
        bridge.channelKind === 'mock'
          ? { kind: 'mock', presetId: preset.id, fixtureSource: 'preset' }
          : {
              kind: 'live',
              requestPath: '/api/v1/external-agents/evidence-uploads',
              transport: 'req',
            },
    })
  }, [bridge.channelKind, preset.id])

  const artifacts: ArtifactHashItem[] = useMemo(() => {
    if (customArtifacts && customArtifacts.length > 0) {
      return [...customArtifacts]
    }
    return deriveArtifactsForPreset(preset, payload)
  }, [customArtifacts, preset, payload])

  const pollTelemetry = useCallback(
    async (isInitial = false) => {
      if (!isMountedRef.current) return
      setIsFetching(true)
      setError(null)

      try {
        const outcome = await bridge.advance('confinement_streaming')
        if (!isMountedRef.current) return

        // Timestamp sourced strictly from the actual response arrival time, not render time
        const responseArrivalEpoch = Date.now()
        const formattedArrival = formatTimeHms(responseArrivalEpoch)
        setLastPolledAt(formattedArrival)

        if (outcome.status === 'ok') {
          const freshPayload = outcome.payload
          setPayload(freshPayload)
          setSourceHealth('healthy')

          // Debounce numeric gauge re-render to eliminate cosmetic jitter
          if (debounceTimerRef.current) {
            clearTimeout(debounceTimerRef.current)
          }

          if (debounceMs <= 0) {
            setDisplayCpuTicks(freshPayload.cpuTicks)
            setDisplayRssBytes(freshPayload.rssBytes)
          } else {
            debounceTimerRef.current = setTimeout(() => {
              if (!isMountedRef.current) return
              setDisplayCpuTicks(freshPayload.cpuTicks)
              setDisplayRssBytes(freshPayload.rssBytes)
            }, debounceMs)
          }

          onTelemetryPolled?.(freshPayload)
          if (isInitial) {
            onOutcome?.(outcome)
          }
        } else {
          if (outcome.error.kind === 'aborted') return
          setSourceHealth('degraded')
          setError(outcome.error.message)
          if (isInitial) {
            onOutcome?.(outcome)
          }
        }
      } catch (err: unknown) {
        if (!isMountedRef.current) return
        const msg = err instanceof Error ? err.message : String(err)
        setSourceHealth('degraded')
        setError(msg)
      } finally {
        if (isMountedRef.current) {
          setIsFetching(false)
        }
      }
    },
    [bridge, debounceMs, onOutcome, onTelemetryPolled]
  )

  // Poll loop: starts on mount, cleans up cleanly on unmount with zero dangling timers
  useEffect(() => {
    isMountedRef.current = true

    // Initial fetch
    pollTelemetry(true)

    if (pollIntervalMs > 0) {
      pollTimerRef.current = setInterval(() => {
        pollTelemetry(false)
      }, pollIntervalMs)
    }

    return () => {
      isMountedRef.current = false
      if (pollTimerRef.current) {
        clearInterval(pollTimerRef.current)
        pollTimerRef.current = null
      }
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current)
        debounceTimerRef.current = null
      }
    }
  }, [pollIntervalMs, pollTelemetry])

  const handleManualRefresh = async () => {
    if (isFetching || inFlight) return
    await pollTelemetry(false)
  }

  const { formattedMs: cpuFormattedMs, formattedSec: cpuFormattedSec } =
    formatCpuTime(displayCpuTicks)
  const rssFormattedMb = formatBytesToMb(displayRssBytes)

  const isDegraded = sourceHealth === 'degraded'
  const isHealthy = sourceHealth === 'healthy'

  return (
    <div
      data-testid="confinement-telemetry-panel"
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
      {/* Header & Controls */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <h3 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: colors.electricWhite }}>
              Stage 3: Landlock Confinement & Telemetry
            </h3>
            <span
              data-testid="telemetry-channel-badge"
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
            <span
              data-testid="polling-cadence-badge"
              style={{
                fontSize: 11,
                padding: '2px 8px',
                borderRadius: 4,
                backgroundColor: colors.deepMidnight,
                color: colors.muted,
                fontFamily: 'monospace',
              }}
            >
              Poll interval: {(pollIntervalMs / 1000).toFixed(1)}s
            </span>
          </div>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: colors.muted }}>
            Stream metadata-only process metrics and live SHA-256 artifact verification.
          </p>
        </div>

        {/* Manual Refresh / Immediate Poll Button */}
        <button
          type="button"
          data-testid="refresh-telemetry-btn"
          disabled={isFetching || inFlight}
          onClick={handleManualRefresh}
          style={{
            backgroundColor: isFetching || inFlight ? colors.elevatedSlate : colors.cyanLoom,
            color: isFetching || inFlight ? colors.muted : colors.deepMidnight,
            border: 'none',
            borderRadius: 4,
            padding: '8px 14px',
            fontSize: 12,
            fontWeight: 600,
            cursor: isFetching || inFlight ? 'not-allowed' : 'pointer',
            opacity: isFetching || inFlight ? 0.6 : 1,
            display: 'flex',
            alignItems: 'center',
            gap: 6,
            transition: 'all 0.15s ease',
          }}
        >
          {isFetching ? 'Polling...' : 'Poll Telemetry Now'}
        </button>
      </div>

      {/* Target Route Notice & Global Freshness Status */}
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          fontSize: 12,
          color: colors.muted,
          fontFamily: 'monospace',
          backgroundColor: colors.deepMidnight,
          padding: '8px 12px',
          borderRadius: 4,
        }}
      >
        <span>POST /api/v1/external-agents/evidence-uploads</span>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span data-testid="last-polled-at" style={{ color: colors.electricWhite }}>
            Last polled at: <strong style={{ color: colors.cyanLoom }}>{lastPolledAt}</strong>
          </span>
          <span
            data-testid="zero-payload-badge"
            style={{
              color: colors.tealLoom,
              backgroundColor: colors.slateDark,
              padding: '2px 6px',
              borderRadius: 3,
              fontSize: 11,
              border: `1px solid ${colors.tealLoom}`,
            }}
          >
            Zero Customer Payload
          </span>
        </div>
      </div>

      {/* Error Display */}
      {error && (
        <div
          data-testid="telemetry-error"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${colors.red}`,
            borderRadius: 4,
            padding: 12,
            color: colors.red,
            fontSize: 13,
          }}
        >
          <strong>Telemetry Fetch Failed:</strong> {error}
        </div>
      )}

      {/* Process Gauges Grid */}
      <div
        data-testid="telemetry-gauges-container"
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
          gap: 16,
        }}
      >
        {/* 1. CPU Gauge (Cumulative CPU Execution Time) */}
        <div
          data-testid="cpu-gauge"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${isDegraded ? colors.amber : colors.elevatedSlate}`,
            borderRadius: 6,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: colors.electricWhite }}>
              CPU Execution Time
            </span>
            <span
              data-testid="cpu-health-badge"
              style={{
                fontSize: 10,
                fontWeight: 600,
                textTransform: 'uppercase',
                padding: '2px 6px',
                borderRadius: 4,
                backgroundColor: colors.slateDark,
                color: isHealthy ? colors.tealLoom : isDegraded ? colors.amber : colors.slateGray,
              }}
            >
              {sourceHealth}
            </span>
          </div>

          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span
              data-testid="cpu-gauge-value"
              style={{
                fontSize: 24,
                fontFamily: 'monospace',
                fontWeight: 700,
                color: colors.cyanLoom,
              }}
            >
              {cpuFormattedMs}
            </span>
            <span style={{ fontSize: 12, color: colors.muted, fontFamily: 'monospace' }}>
              ({cpuFormattedSec})
            </span>
          </div>

          {/* Visual Gauge Meter Bar */}
          <div
            style={{
              width: '100%',
              height: 6,
              backgroundColor: colors.slateDark,
              borderRadius: 3,
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                width: `${Math.min(100, Math.max(8, (displayCpuTicks % 5000) / 50))}%`,
                height: '100%',
                backgroundColor: colors.cyanLoom,
                transition: 'width 0.3s ease',
              }}
            />
          </div>

          <div
            data-testid="cpu-gauge-note"
            style={{
              fontSize: 11,
              color: colors.muted,
              lineHeight: 1.3,
            }}
          >
            Cumulative CPU time (cpu_time_ms). Instantaneous CPU % is internal to host-sensor and not
            exported to preserve zero-payload isolation.
          </div>

          <div
            data-testid="cpu-last-polled-at"
            style={{
              fontSize: 11,
              color: colors.dim,
              fontFamily: 'monospace',
              borderTop: `1px solid ${colors.elevatedSlate}`,
              paddingTop: 6,
            }}
          >
            Last polled: {lastPolledAt}
          </div>
        </div>

        {/* 2. RSS Memory Gauge */}
        <div
          data-testid="rss-gauge"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${isDegraded ? colors.amber : colors.elevatedSlate}`,
            borderRadius: 6,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: colors.electricWhite }}>
              Resident Memory (RSS)
            </span>
            <span
              data-testid="rss-health-badge"
              style={{
                fontSize: 10,
                fontWeight: 600,
                textTransform: 'uppercase',
                padding: '2px 6px',
                borderRadius: 4,
                backgroundColor: colors.slateDark,
                color: isHealthy ? colors.tealLoom : isDegraded ? colors.amber : colors.slateGray,
              }}
            >
              {sourceHealth}
            </span>
          </div>

          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span
              data-testid="rss-gauge-value"
              style={{
                fontSize: 24,
                fontFamily: 'monospace',
                fontWeight: 700,
                color: colors.irisViolet,
              }}
            >
              {rssFormattedMb}
            </span>
          </div>

          <div
            data-testid="rss-gauge-raw-bytes"
            style={{ fontSize: 12, color: colors.muted, fontFamily: 'monospace' }}
          >
            {displayRssBytes.toLocaleString()} bytes allocated
          </div>

          {/* Visual Memory Meter Bar */}
          <div
            style={{
              width: '100%',
              height: 6,
              backgroundColor: colors.slateDark,
              borderRadius: 3,
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                width: `${Math.min(100, Math.max(10, (displayRssBytes / (128 * 1024 * 1024)) * 100))}%`,
                height: '100%',
                backgroundColor: colors.irisViolet,
                transition: 'width 0.3s ease',
              }}
            />
          </div>

          <div
            data-testid="rss-last-polled-at"
            style={{
              fontSize: 11,
              color: colors.dim,
              fontFamily: 'monospace',
              borderTop: `1px solid ${colors.elevatedSlate}`,
              paddingTop: 6,
            }}
          >
            Last polled: {lastPolledAt}
          </div>
        </div>

        {/* 3. Open FDs Slot (Honest Unavailable State) */}
        <div
          data-testid="open-fds-slot"
          style={{
            backgroundColor: colors.deepMidnight,
            border: `1px solid ${colors.elevatedSlate}`,
            borderRadius: 6,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            gap: 12,
            opacity: 0.9,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: colors.muted }}>
              Open File Descriptors
            </span>
            <span
              data-testid="open-fds-unavailable-badge"
              style={{
                fontSize: 10,
                fontWeight: 600,
                textTransform: 'uppercase',
                padding: '2px 6px',
                borderRadius: 4,
                backgroundColor: colors.slateDark,
                color: colors.slateGray,
              }}
            >
              Unavailable
            </span>
          </div>

          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span
              data-testid="open-fds-value"
              style={{
                fontSize: 24,
                fontFamily: 'monospace',
                fontWeight: 700,
                color: colors.slateGray,
              }}
            >
              N/A
            </span>
          </div>

          <div
            data-testid="open-fds-note"
            style={{
              fontSize: 11,
              color: colors.muted,
              lineHeight: 1.3,
            }}
          >
            Not available in host-sensor-v1 contract (schema 1.0.0). No open-FD telemetry field is
            exported by sensor models.
          </div>

          <div
            data-testid="open-fds-last-polled-at"
            style={{
              fontSize: 11,
              color: colors.dim,
              fontFamily: 'monospace',
              borderTop: `1px solid ${colors.elevatedSlate}`,
              paddingTop: 6,
            }}
          >
            Last polled: {lastPolledAt}
          </div>
        </div>
      </div>

      {/* File Hashing Comparison Table */}
      <div
        data-testid="hash-table-container"
        style={{
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          backgroundColor: colors.deepMidnight,
          borderRadius: 6,
          padding: 16,
          border: `1px solid ${colors.elevatedSlate}`,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <h4 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: colors.electricWhite }}>
              Cryptographic Artifact SHA-256 Verification Table
            </h4>
            <span
              data-testid="artifact-count-badge"
              style={{
                fontSize: 11,
                padding: '1px 6px',
                borderRadius: 3,
                backgroundColor: colors.slateDark,
                color: colors.cyanLoom,
                fontFamily: 'monospace',
              }}
            >
              {artifacts.length} {artifacts.length === 1 ? 'artifact' : 'artifacts'}
            </span>
          </div>
          <span style={{ fontSize: 12, color: colors.muted }}>
            TOCTOU Safe • Landlock Confinement Boundary
          </span>
        </div>

        {/* Scrollable Table View */}
        <div
          style={{
            maxHeight: 280,
            overflowY: 'auto',
            border: `1px solid ${colors.elevatedSlate}`,
            borderRadius: 4,
          }}
        >
          <table
            data-testid="hash-comparison-table"
            style={{
              width: '100%',
              borderCollapse: 'collapse',
              fontSize: 12,
              textAlign: 'left',
            }}
          >
            <thead>
              <tr
                style={{
                  backgroundColor: colors.slateDark,
                  color: colors.muted,
                  borderBottom: `1px solid ${colors.elevatedSlate}`,
                  fontSize: 11,
                  textTransform: 'uppercase',
                  letterSpacing: '0.05em',
                }}
              >
                <th style={{ padding: '8px 12px' }}>Artifact ID</th>
                <th style={{ padding: '8px 12px' }}>Root</th>
                <th style={{ padding: '8px 12px' }}>Expected SHA-256</th>
                <th style={{ padding: '8px 12px' }}>Computed SHA-256</th>
                <th style={{ padding: '8px 12px' }}>Size</th>
                <th style={{ padding: '8px 12px', textAlign: 'right' }}>Integrity State</th>
              </tr>
            </thead>
            <tbody>
              {artifacts.map((artifact) => {
                const isMatch = artifact.status === 'match'
                return (
                  <tr
                    key={artifact.artifactId}
                    data-testid={`artifact-hash-row-${artifact.artifactId}`}
                    data-testid-group="hash-comparison-row"
                    style={{
                      borderBottom: `1px solid ${colors.elevatedSlate}`,
                      backgroundColor: isMatch ? 'transparent' : 'rgba(239, 68, 68, 0.08)',
                    }}
                  >
                    <td
                      data-testid={`artifact-id-${artifact.artifactId}`}
                      style={{
                        padding: '10px 12px',
                        fontFamily: 'monospace',
                        color: colors.electricWhite,
                        fontWeight: 500,
                      }}
                    >
                      {artifact.artifactId}
                    </td>
                    <td
                      data-testid={`artifact-root-${artifact.artifactId}`}
                      style={{
                        padding: '10px 12px',
                        fontFamily: 'monospace',
                        color: colors.muted,
                      }}
                    >
                      {artifact.rootId}
                    </td>
                    <td
                      data-testid={`artifact-expected-sha-${artifact.artifactId}`}
                      title={artifact.expectedSha256}
                      style={{
                        padding: '10px 12px',
                        fontFamily: 'monospace',
                        color: colors.cyanLoom,
                        fontSize: 11,
                      }}
                    >
                      {artifact.expectedSha256.slice(0, 16)}...
                    </td>
                    <td
                      data-testid={`artifact-computed-sha-${artifact.artifactId}`}
                      title={artifact.computedSha256}
                      style={{
                        padding: '10px 12px',
                        fontFamily: 'monospace',
                        color: isMatch ? colors.cyanLoom : colors.red,
                        fontWeight: isMatch ? 400 : 600,
                        fontSize: 11,
                      }}
                    >
                      {artifact.computedSha256.slice(0, 16)}...
                    </td>
                    <td
                      data-testid={`artifact-size-${artifact.artifactId}`}
                      style={{
                        padding: '10px 12px',
                        fontFamily: 'monospace',
                        color: colors.muted,
                        fontSize: 11,
                      }}
                    >
                      {artifact.sizeBytes.toLocaleString()} B
                    </td>
                    <td style={{ padding: '10px 12px', textAlign: 'right' }}>
                      <span
                        data-testid={`artifact-status-badge-${artifact.artifactId}`}
                        style={{
                          fontSize: 10,
                          fontWeight: 700,
                          textTransform: 'uppercase',
                          padding: '3px 8px',
                          borderRadius: 4,
                          backgroundColor: isMatch ? 'rgba(20, 184, 166, 0.15)' : 'rgba(239, 68, 68, 0.15)',
                          color: isMatch ? colors.tealLoom : colors.red,
                          border: `1px solid ${isMatch ? colors.tealLoom : colors.red}`,
                        }}
                      >
                        {isMatch ? 'Match' : 'Mismatch'}
                      </span>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
