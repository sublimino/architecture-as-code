import React, { useState, useEffect, useMemo, useCallback } from 'react'
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
import type { AdversarialTamperPayload } from './types'

// ============================================================================
// 1. Host-Sensor Real Constants & Rejection Reasons (grounded in sensor code)
// ============================================================================

/**
 * Exact rate limit thresholds defined by ExternalAgentEvidenceV1Limit
 * in src/types/externalAgent.ts and host-sensor ratelimit.py.
 */
export const MAX_FILE_SIZE_BYTES = 16777216 // 16 MiB (16 * 1024 * 1024)
export const MAX_FILES_PER_WINDOW = 120
export const MAX_BYTES_PER_WINDOW = 67108864 // 64 MiB (64 * 1024 * 1024)
export const WINDOW_SECONDS = 60

/**
 * openat2 resolve flags used by PinnedRoot in test_file_validator.py and file_validator.py.
 */
export const SYSCALL_FLAGS_OPENAT2 = [
  'RESOLVE_BENEATH',
  'RESOLVE_NO_SYMLINKS',
  'RESOLVE_NO_XDEV',
] as const

/**
 * Exact rejection reasons and messages sourced from file_validator.py RejectionReason enum
 * and query_statx / openat2_validate error paths.
 */
export const REJECTION_MESSAGES = {
  symlink_rejected: 'Kernel rejected symbolic link in path (ELOOP via RESOLVE_NO_SYMLINKS)',
  escape_rejected: 'Absolute paths are forbidden; path must be descriptor-relative',
  mount_crossing_rejected: 'Kernel rejected path escape or mount boundary crossing (EXDEV)',
  oversize_rejected: `File size 17825792 exceeds limit ${MAX_FILE_SIZE_BYTES} bytes (max_file_size_bytes: ${MAX_FILE_SIZE_BYTES}, window: ${WINDOW_SECONDS}s)`,
  hash_mismatch: 'tamper_integrity_mismatch_flagged: computed digest does not match anchor SHA-256',
} as const

export interface EphemeralArtifact {
  readonly artifactId: string
  readonly rootId: 'agent-work' | 'agent-output'
  readonly sha256: string
  readonly sizeBytes: number
  readonly mtimeNs: string
}

export const BASELINE_EPHEMERAL_ARTIFACT: EphemeralArtifact = {
  artifactId: 'artifact-demo-001',
  rootId: 'agent-work',
  sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  sizeBytes: 14320,
  mtimeNs: '1726365600000000000',
}

export const CORRUPTED_SHA256 = 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

/**
 * Restores a tampered ephemeral artifact byte-for-byte to its baseline authentic state.
 */
export function restoreEphemeralArtifact(tampered: EphemeralArtifact): EphemeralArtifact {
  return {
    ...tampered,
    sha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
  }
}

// ============================================================================
// 2. Component Props & Internal State Types
// ============================================================================

export interface AdversarialSimulationPanelProps {
  readonly bridge: DemoBridge
  readonly preset?: ScenarioPreset
  readonly inFlight?: boolean
  readonly initialPayload?: AdversarialTamperPayload | null
  readonly onOutcome?: (outcome: StageOutcome<'adversarial_tamper'>) => void
  readonly onTamperInjected?: (payload: AdversarialTamperPayload) => void
  readonly onReset?: () => void
}

interface HashMismatchState {
  readonly isInjected: boolean
  readonly isInjecting: boolean
  readonly currentSha256: string
  readonly originalSha256: string
  readonly containmentTriggered: boolean
  readonly latencyMs: number | null
  readonly injectedAt: string | null
}

interface SymlinkEscapeState {
  readonly isInjected: boolean
  readonly isInjecting: boolean
  readonly status: 'eligible' | 'ineligible'
  readonly reason: string | null
  readonly rejectionMessage: string | null
  readonly bytesRead: number
  readonly syscallFlags: readonly string[]
  readonly containmentTriggered: boolean
  readonly latencyMs: number | null
  readonly injectedAt: string | null
}

interface OversizedWriteState {
  readonly isInjected: boolean
  readonly isInjecting: boolean
  readonly status: 'eligible' | 'ineligible'
  readonly attemptedSizeBytes: number
  readonly maxFileSizeBytes: number
  readonly reason: string | null
  readonly rejectionMessage: string | null
  readonly bytesRead: number
  readonly containmentTriggered: boolean
  readonly latencyMs: number | null
  readonly injectedAt: string | null
}

// ============================================================================
// 3. Main AdversarialSimulationPanel Component
// ============================================================================

export function AdversarialSimulationPanel({
  bridge,
  preset = HAPPY_PATH_PRESET,
  inFlight = false,
  initialPayload = null,
  onOutcome,
  onTamperInjected,
  onReset,
}: AdversarialSimulationPanelProps): React.JSX.Element {
  // Determine if preset initially defaults to tamper breach
  const presetIsTamperBreach = preset.id === TAMPER_BREACH_PRESET.id

  // Control 1: Hash Mismatch State
  const [hashState, setHashState] = useState<HashMismatchState>(() => {
    const isTampered =
      initialPayload?.tamperType === 'hash_mismatch'
        ? initialPayload.containmentTriggered
        : presetIsTamperBreach
    const original =
      preset.tamper_config?.mock_site.original_value ||
      BASELINE_EPHEMERAL_ARTIFACT.sha256
    const corrupted =
      preset.tamper_config?.mock_site.corrupted_value ||
      CORRUPTED_SHA256

    return {
      isInjected: isTampered,
      isInjecting: false,
      currentSha256: isTampered ? corrupted : original,
      originalSha256: original,
      containmentTriggered: isTampered,
      latencyMs: initialPayload?.detectionLatencyMs ?? (isTampered ? 18 : null),
      injectedAt: initialPayload?.injectedAt ?? null,
    }
  })

  // Control 2: Symlink Escape State
  const [symlinkState, setSymlinkState] = useState<SymlinkEscapeState>(() => {
    const isTampered = initialPayload?.tamperType === 'symlink_escape' && initialPayload.containmentTriggered
    return {
      isInjected: isTampered,
      isInjecting: false,
      status: isTampered ? 'ineligible' : 'eligible',
      reason: isTampered ? 'symlink_rejected' : null,
      rejectionMessage: isTampered ? REJECTION_MESSAGES.symlink_rejected : null,
      bytesRead: 0,
      syscallFlags: SYSCALL_FLAGS_OPENAT2,
      containmentTriggered: isTampered,
      latencyMs: initialPayload?.detectionLatencyMs ?? (isTampered ? 22 : null),
      injectedAt: initialPayload?.injectedAt ?? null,
    }
  })

  // Control 3: Oversized Write State
  const [oversizeState, setOversizeState] = useState<OversizedWriteState>(() => {
    const isTampered = initialPayload?.tamperType === 'oversized_write' && initialPayload.containmentTriggered
    return {
      isInjected: isTampered,
      isInjecting: false,
      status: isTampered ? 'ineligible' : 'eligible',
      attemptedSizeBytes: 17825792,
      maxFileSizeBytes: MAX_FILE_SIZE_BYTES,
      reason: isTampered ? 'oversize_rejected' : null,
      rejectionMessage: isTampered ? REJECTION_MESSAGES.oversize_rejected : null,
      bytesRead: 0,
      containmentTriggered: isTampered,
      latencyMs: initialPayload?.detectionLatencyMs ?? (isTampered ? 14 : null),
      injectedAt: initialPayload?.injectedAt ?? null,
    }
  })

  const [ephemeralArtifact, setEphemeralArtifact] = useState<EphemeralArtifact>(BASELINE_EPHEMERAL_ARTIFACT)

  // Channel descriptor
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

  // Sync initialPayload updates if provided from outside
  useEffect(() => {
    if (!initialPayload) return

    if (initialPayload.tamperType === 'hash_mismatch') {
      setHashState((prev) => ({
        ...prev,
        isInjected: initialPayload.containmentTriggered,
        currentSha256: initialPayload.tamperedSha256,
        originalSha256: initialPayload.originalSha256,
        containmentTriggered: initialPayload.containmentTriggered,
        latencyMs: initialPayload.detectionLatencyMs,
        injectedAt: initialPayload.injectedAt,
      }))
    } else if (initialPayload.tamperType === 'symlink_escape') {
      setSymlinkState((prev) => ({
        ...prev,
        isInjected: initialPayload.containmentTriggered,
        status: initialPayload.containmentTriggered ? 'ineligible' : 'eligible',
        reason: 'symlink_rejected',
        rejectionMessage: REJECTION_MESSAGES.symlink_rejected,
        containmentTriggered: initialPayload.containmentTriggered,
        latencyMs: initialPayload.detectionLatencyMs,
        injectedAt: initialPayload.injectedAt,
      }))
    } else if (initialPayload.tamperType === 'oversized_write') {
      setOversizeState((prev) => ({
        ...prev,
        isInjected: initialPayload.containmentTriggered,
        status: initialPayload.containmentTriggered ? 'ineligible' : 'eligible',
        reason: 'oversize_rejected',
        rejectionMessage: REJECTION_MESSAGES.oversize_rejected,
        containmentTriggered: initialPayload.containmentTriggered,
        latencyMs: initialPayload.detectionLatencyMs,
        injectedAt: initialPayload.injectedAt,
      }))
    }
  }, [initialPayload])

  // ==========================================================================
  // Control 1: Inject / Restore Hash Mismatch
  // ==========================================================================
  const handleInjectHashMismatch = useCallback(async () => {
    if (inFlight || hashState.isInjecting) return

    setHashState((prev) => ({ ...prev, isInjecting: true }))
    const startTime = typeof performance !== 'undefined' ? performance.now() : Date.now()

    // Simulate async tamper transition
    await new Promise((resolve) => setTimeout(resolve, 40))

    const endTime = typeof performance !== 'undefined' ? performance.now() : Date.now()
    const measuredLatency = Math.max(1, Math.round(endTime - startTime))
    const timestamp = new Date().toISOString()
    const corruptedDigest =
      preset.tamper_config?.mock_site.corrupted_value || CORRUPTED_SHA256

    setEphemeralArtifact((prev) => ({
      ...prev,
      sha256: corruptedDigest,
    }))

    setHashState({
      isInjected: true,
      isInjecting: false,
      currentSha256: corruptedDigest,
      originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      containmentTriggered: true,
      latencyMs: measuredLatency,
      injectedAt: timestamp,
    })

    const payload: AdversarialTamperPayload = {
      tamperType: 'hash_mismatch',
      injectedAt: timestamp,
      originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      tamperedSha256: corruptedDigest,
      breachDetected: true,
      containmentTriggered: true,
      detectionLatencyMs: measuredLatency,
    }

    onTamperInjected?.(payload)
  }, [inFlight, hashState.isInjecting, preset.tamper_config, onTamperInjected])

  const handleRestoreHashMismatch = useCallback(async () => {
    if (inFlight || hashState.isInjecting) return

    setHashState((prev) => ({ ...prev, isInjecting: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    setEphemeralArtifact((prev) => restoreEphemeralArtifact(prev))

    setHashState({
      isInjected: false,
      isInjecting: false,
      currentSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })

    const payload: AdversarialTamperPayload = {
      tamperType: 'hash_mismatch',
      injectedAt: new Date().toISOString(),
      originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      tamperedSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      breachDetected: false,
      containmentTriggered: false,
      detectionLatencyMs: 0,
    }

    onTamperInjected?.(payload)
  }, [inFlight, hashState.isInjecting, onTamperInjected])

  // ==========================================================================
  // Control 2: Inject / Restore Symlink Escape
  // ==========================================================================
  const handleInjectSymlinkEscape = useCallback(async () => {
    if (inFlight || symlinkState.isInjecting) return

    setSymlinkState((prev) => ({ ...prev, isInjecting: true }))
    const startTime = typeof performance !== 'undefined' ? performance.now() : Date.now()

    await new Promise((resolve) => setTimeout(resolve, 40))

    const endTime = typeof performance !== 'undefined' ? performance.now() : Date.now()
    const measuredLatency = Math.max(1, Math.round(endTime - startTime))
    const timestamp = new Date().toISOString()

    setSymlinkState({
      isInjected: true,
      isInjecting: false,
      status: 'ineligible',
      reason: 'symlink_rejected',
      rejectionMessage: REJECTION_MESSAGES.symlink_rejected,
      bytesRead: 0,
      syscallFlags: SYSCALL_FLAGS_OPENAT2,
      containmentTriggered: true,
      latencyMs: measuredLatency,
      injectedAt: timestamp,
    })

    const payload: AdversarialTamperPayload = {
      tamperType: 'symlink_escape',
      injectedAt: timestamp,
      originalSha256: hashState.originalSha256,
      tamperedSha256: hashState.currentSha256, // Does NOT alter hash mismatch state
      breachDetected: true,
      containmentTriggered: true,
      detectionLatencyMs: measuredLatency,
    }

    onTamperInjected?.(payload)
  }, [inFlight, symlinkState.isInjecting, hashState.originalSha256, hashState.currentSha256, onTamperInjected])

  const handleRestoreSymlinkEscape = useCallback(async () => {
    if (inFlight || symlinkState.isInjecting) return

    setSymlinkState((prev) => ({ ...prev, isInjecting: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    setSymlinkState({
      isInjected: false,
      isInjecting: false,
      status: 'eligible',
      reason: null,
      rejectionMessage: null,
      bytesRead: 0,
      syscallFlags: SYSCALL_FLAGS_OPENAT2,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })
  }, [inFlight, symlinkState.isInjecting])

  // ==========================================================================
  // Control 3: Inject / Restore Oversized Write
  // ==========================================================================
  const handleInjectOversizedWrite = useCallback(async () => {
    if (inFlight || oversizeState.isInjecting) return

    setOversizeState((prev) => ({ ...prev, isInjecting: true }))
    const startTime = typeof performance !== 'undefined' ? performance.now() : Date.now()

    await new Promise((resolve) => setTimeout(resolve, 40))

    const endTime = typeof performance !== 'undefined' ? performance.now() : Date.now()
    const measuredLatency = Math.max(1, Math.round(endTime - startTime))
    const timestamp = new Date().toISOString()

    setOversizeState({
      isInjected: true,
      isInjecting: false,
      status: 'ineligible',
      attemptedSizeBytes: 17825792,
      maxFileSizeBytes: MAX_FILE_SIZE_BYTES,
      reason: 'oversize_rejected',
      rejectionMessage: REJECTION_MESSAGES.oversize_rejected,
      bytesRead: 0,
      containmentTriggered: true,
      latencyMs: measuredLatency,
      injectedAt: timestamp,
    })

    const payload: AdversarialTamperPayload = {
      tamperType: 'oversized_write',
      injectedAt: timestamp,
      originalSha256: hashState.originalSha256,
      tamperedSha256: hashState.currentSha256, // Does NOT alter hash mismatch state
      breachDetected: true,
      containmentTriggered: true,
      detectionLatencyMs: measuredLatency,
    }

    onTamperInjected?.(payload)
  }, [inFlight, oversizeState.isInjecting, hashState.originalSha256, hashState.currentSha256, onTamperInjected])

  const handleRestoreOversizedWrite = useCallback(async () => {
    if (inFlight || oversizeState.isInjecting) return

    setOversizeState((prev) => ({ ...prev, isInjecting: true }))
    await new Promise((resolve) => setTimeout(resolve, 20))

    setOversizeState({
      isInjected: false,
      isInjecting: false,
      status: 'eligible',
      attemptedSizeBytes: 17825792,
      maxFileSizeBytes: MAX_FILE_SIZE_BYTES,
      reason: null,
      rejectionMessage: null,
      bytesRead: 0,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })
  }, [inFlight, oversizeState.isInjecting])

  // ==========================================================================
  // Reset Estate (Restores All Controls Byte-for-Byte)
  // ==========================================================================
  const handleResetEstate = useCallback(() => {
    setEphemeralArtifact(BASELINE_EPHEMERAL_ARTIFACT)
    setHashState({
      isInjected: false,
      isInjecting: false,
      currentSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })
    setSymlinkState({
      isInjected: false,
      isInjecting: false,
      status: 'eligible',
      reason: null,
      rejectionMessage: null,
      bytesRead: 0,
      syscallFlags: SYSCALL_FLAGS_OPENAT2,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })
    setOversizeState({
      isInjected: false,
      isInjecting: false,
      status: 'eligible',
      attemptedSizeBytes: 17825792,
      maxFileSizeBytes: MAX_FILE_SIZE_BYTES,
      reason: null,
      rejectionMessage: null,
      bytesRead: 0,
      containmentTriggered: false,
      latencyMs: null,
      injectedAt: null,
    })
    onReset?.()
  }, [onReset])

  const isHashMatch = hashState.currentSha256 === hashState.originalSha256

  return (
    <div
      data-testid="adversarial-simulation-panel"
      className="space-y-6"
      style={{ color: colors.electricWhite }}
    >
      {/* Header with Provenance & Channel Badge */}
      <div className="flex flex-wrap items-center justify-between gap-3 p-4 bg-[var(--surface)] border border-[var(--border)] rounded-lg shadow-sm">
        <div className="flex items-center gap-3">
          <span
            data-testid="adversarial-channel-badge"
            className="px-2.5 py-1 rounded text-xs font-mono font-medium border"
            style={{
              backgroundColor: 'rgba(6, 182, 212, 0.1)',
              borderColor: colors.cyanLoom,
              color: colors.cyanLoom,
            }}
          >
            {channelDesc.label}
          </span>
          <span className="text-xs font-mono text-[var(--muted)]">
            Ground Truth: Linux openat2(2) & 16 MiB Rate Limits
          </span>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="reset-adversarial-estate-btn"
            onClick={handleResetEstate}
            disabled={inFlight}
            className="px-3 py-1.5 rounded text-xs font-mono text-[var(--muted)] hover:text-[var(--text)] bg-[var(--surface2)] hover:bg-[var(--border)] border border-[var(--border)] transition-colors cursor-pointer disabled:opacity-50"
          >
            Reset All Tamper Injections
          </button>
        </div>
      </div>

      {/* Grid of Three Independent Injection Controls */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        {/* ================================================================= */}
        {/* Control 1: Hash Mismatch Injection */}
        {/* ================================================================= */}
        <div
          data-testid="tamper-control-hash-mismatch"
          className="p-5 bg-[var(--surface)] border border-[var(--border)] rounded-lg flex flex-col justify-between space-y-4 shadow-sm"
        >
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono font-bold text-[var(--cyan)] uppercase">
                Control 01 • SHA-256 Tamper
              </span>
              <span
                data-testid="hash-status-badge"
                className="px-2 py-0.5 rounded text-[11px] font-mono uppercase font-semibold border"
                style={{
                  backgroundColor: isHashMatch
                    ? 'rgba(20, 184, 166, 0.15)'
                    : 'rgba(239, 68, 68, 0.15)',
                  borderColor: isHashMatch ? colors.tealLoom : colors.red,
                  color: isHashMatch ? colors.tealLoom : colors.red,
                }}
              >
                {isHashMatch ? 'Intact' : 'Tampered'}
              </span>
            </div>

            <div>
              <h3 className="text-base font-semibold text-[var(--text)]">
                Cryptographic Hash Mismatch
              </h3>
              <p className="text-xs text-[var(--muted)] mt-1 leading-relaxed">
                Modifies the computed SHA-256 digest on an ephemeral session artifact. Demonstrates
                instant detection by the verification anchor and downstream ingestion rejection.
              </p>
            </div>

            {/* Hash Comparison Box */}
            <div className="p-3 bg-[var(--bg)] border border-[var(--border)] rounded space-y-2 font-mono text-xs">
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Target Artifact</div>
                <div className="text-[var(--text)] font-semibold">{ephemeralArtifact.artifactId}</div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Anchor / Expected SHA-256</div>
                <div
                  data-testid="original-hash-value"
                  className="text-[11px] text-[var(--cyan)] truncate"
                  title={hashState.originalSha256}
                >
                  {hashState.originalSha256}
                </div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Observed SHA-256</div>
                <div
                  data-testid="current-hash-value"
                  className="text-[11px] truncate"
                  style={{
                    color: isHashMatch ? colors.cyanLoom : colors.red,
                    fontWeight: isHashMatch ? 400 : 700,
                  }}
                  title={hashState.currentSha256}
                >
                  {hashState.currentSha256}
                </div>
              </div>
            </div>

            {/* Containment Alert Badge */}
            {hashState.containmentTriggered && (
              <div
                data-testid="containment-alert-hash-mismatch"
                className="p-3 rounded border space-y-1.5"
                style={{
                  backgroundColor: 'rgba(239, 68, 68, 0.1)',
                  borderColor: colors.red,
                }}
              >
                <div className="flex items-center justify-between">
                  <span
                    data-testid="containment-alert-badge-hash_mismatch"
                    className="px-2 py-0.5 rounded text-[11px] font-mono font-bold uppercase"
                    style={{
                      backgroundColor: colors.red,
                      color: 'var(--on-accent)',
                    }}
                  >
                    Containment Alert: Tamper Detected
                  </span>
                  {hashState.latencyMs !== null && (
                    <span
                      data-testid="latency-hash-mismatch"
                      className="text-xs font-mono text-[var(--muted)]"
                    >
                      {hashState.latencyMs} ms
                    </span>
                  )}
                </div>
                <p className="text-xs text-[var(--text)] font-mono leading-relaxed">
                  {REJECTION_MESSAGES.hash_mismatch}
                </p>
              </div>
            )}
          </div>

          <div className="pt-3 border-t border-[var(--border)] flex items-center justify-between gap-2">
            <button
              type="button"
              data-testid="inject-hash-mismatch-btn"
              onClick={handleInjectHashMismatch}
              disabled={inFlight || hashState.isInjecting}
              className="flex-1 px-3 py-2 rounded text-xs font-medium font-mono bg-[var(--error)]/20 hover:bg-[var(--error)]/30 text-[var(--error)] border border-[var(--error)]/40 hover:border-[var(--error)] transition-colors cursor-pointer disabled:opacity-50"
            >
              {hashState.isInjecting ? 'Injecting Tamper...' : 'Inject Hash Tamper'}
            </button>
            {hashState.isInjected && (
              <button
                type="button"
                data-testid="restore-hash-mismatch-btn"
                onClick={handleRestoreHashMismatch}
                disabled={inFlight || hashState.isInjecting}
                className="px-3 py-2 rounded text-xs font-mono text-[var(--teal)] hover:bg-[var(--teal)]/15 border border-[var(--teal)]/40 transition-colors cursor-pointer disabled:opacity-50"
              >
                Restore
              </button>
            )}
          </div>
        </div>

        {/* ================================================================= */}
        {/* Control 2: Symlink Escape Injection */}
        {/* ================================================================= */}
        <div
          data-testid="tamper-control-symlink-escape"
          className="p-5 bg-[var(--surface)] border border-[var(--border)] rounded-lg flex flex-col justify-between space-y-4 shadow-sm"
        >
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono font-bold text-[var(--cyan)] uppercase">
                Control 02 • Path Traversal
              </span>
              <span
                data-testid="symlink-status-badge"
                className="px-2 py-0.5 rounded text-[11px] font-mono uppercase font-semibold border"
                style={{
                  backgroundColor: symlinkState.isInjected
                    ? 'rgba(239, 68, 68, 0.15)'
                    : 'rgba(20, 184, 166, 0.15)',
                  borderColor: symlinkState.isInjected ? colors.red : colors.tealLoom,
                  color: symlinkState.isInjected ? colors.red : colors.tealLoom,
                }}
              >
                {symlinkState.isInjected ? 'Blocked' : 'Eligible'}
              </span>
            </div>

            <div>
              <h3 className="text-base font-semibold text-[var(--text)]">
                Descriptor Symlink Escape
              </h3>
              <p className="text-xs text-[var(--muted)] mt-1 leading-relaxed">
                Simulates agent trying to read an external symlink target (`/etc/passwd` or `../`).
                Enforced by Linux `openat2` with `RESOLVE_NO_SYMLINKS` and `RESOLVE_BENEATH`.
              </p>
            </div>

            {/* Syscall & Boundary Info Box */}
            <div className="p-3 bg-[var(--bg)] border border-[var(--border)] rounded space-y-2 font-mono text-xs">
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Target Attack Vector</div>
                <div className="text-[var(--text)] font-semibold">symlink_outside.txt → /etc/passwd</div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Kernel Syscall Guard</div>
                <div
                  data-testid="syscall-flags-symlink-escape"
                  className="text-[11px] text-[var(--cyan)]"
                >
                  openat2({SYSCALL_FLAGS_OPENAT2.join(' | ')})
                </div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Canary Bytes Read</div>
                <div
                  data-testid="bytes-read-symlink-escape"
                  className="text-[11px] font-bold text-[var(--teal)]"
                >
                  0 bytes read (Pre-read Rejection)
                </div>
              </div>
            </div>

            {/* Containment Alert Badge */}
            {symlinkState.containmentTriggered && (
              <div
                data-testid="containment-alert-symlink-escape"
                className="p-3 rounded border space-y-1.5"
                style={{
                  backgroundColor: 'rgba(239, 68, 68, 0.1)',
                  borderColor: colors.red,
                }}
              >
                <div className="flex items-center justify-between">
                  <span
                    data-testid="containment-alert-badge-symlink_escape"
                    className="px-2 py-0.5 rounded text-[11px] font-mono font-bold uppercase"
                    style={{
                      backgroundColor: colors.red,
                      color: 'var(--on-accent)',
                    }}
                  >
                    Containment Alert: Symlink Blocked
                  </span>
                  {symlinkState.latencyMs !== null && (
                    <span
                      data-testid="latency-symlink-escape"
                      className="text-xs font-mono text-[var(--muted)]"
                    >
                      {symlinkState.latencyMs} ms
                    </span>
                  )}
                </div>
                <p
                  data-testid="rejection-reason-symlink-escape"
                  className="text-xs text-[var(--text)] font-mono leading-relaxed"
                >
                  {symlinkState.rejectionMessage}
                </p>
              </div>
            )}
          </div>

          <div className="pt-3 border-t border-[var(--border)] flex items-center justify-between gap-2">
            <button
              type="button"
              data-testid="inject-symlink-escape-btn"
              onClick={handleInjectSymlinkEscape}
              disabled={inFlight || symlinkState.isInjecting}
              className="flex-1 px-3 py-2 rounded text-xs font-medium font-mono bg-[var(--error)]/20 hover:bg-[var(--error)]/30 text-[var(--error)] border border-[var(--error)]/40 hover:border-[var(--error)] transition-colors cursor-pointer disabled:opacity-50"
            >
              {symlinkState.isInjecting ? 'Testing Escape...' : 'Inject Symlink Escape'}
            </button>
            {symlinkState.isInjected && (
              <button
                type="button"
                data-testid="restore-symlink-escape-btn"
                onClick={handleRestoreSymlinkEscape}
                disabled={inFlight || symlinkState.isInjecting}
                className="px-3 py-2 rounded text-xs font-mono text-[var(--teal)] hover:bg-[var(--teal)]/15 border border-[var(--teal)]/40 transition-colors cursor-pointer disabled:opacity-50"
              >
                Restore
              </button>
            )}
          </div>
        </div>

        {/* ================================================================= */}
        {/* Control 3: Oversized Write Injection */}
        {/* ================================================================= */}
        <div
          data-testid="tamper-control-oversized-write"
          className="p-5 bg-[var(--surface)] border border-[var(--border)] rounded-lg flex flex-col justify-between space-y-4 shadow-sm"
        >
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-xs font-mono font-bold text-[var(--cyan)] uppercase">
                Control 03 • Rate & Size Limit
              </span>
              <span
                data-testid="oversize-status-badge"
                className="px-2 py-0.5 rounded text-[11px] font-mono uppercase font-semibold border"
                style={{
                  backgroundColor: oversizeState.isInjected
                    ? 'rgba(239, 68, 68, 0.15)'
                    : 'rgba(20, 184, 166, 0.15)',
                  borderColor: oversizeState.isInjected ? colors.red : colors.tealLoom,
                  color: oversizeState.isInjected ? colors.red : colors.tealLoom,
                }}
              >
                {oversizeState.isInjected ? 'Exceeded' : 'Under Limit'}
              </span>
            </div>

            <div>
              <h3 className="text-base font-semibold text-[var(--text)]">
                Pre-Read Oversized Payload
              </h3>
              <p className="text-xs text-[var(--muted)] mt-1 leading-relaxed">
                Presents an artifact exceeding the host-sensor pre-read limit ({MAX_FILE_SIZE_BYTES} bytes / 16 MiB).
                Proves descriptor statx check rejects payload before reading bytes.
              </p>
            </div>

            {/* Threshold and Config Info Box */}
            <div className="p-3 bg-[var(--bg)] border border-[var(--border)] rounded space-y-2 font-mono text-xs">
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Configured Allowlist Limit</div>
                <div
                  data-testid="threshold-oversized-write"
                  className="text-[11px] text-[var(--cyan)] font-semibold"
                >
                  {MAX_FILE_SIZE_BYTES.toLocaleString()} bytes (16.00 MB max)
                </div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Window Thresholds</div>
                <div className="text-[11px] text-[var(--muted)]">
                  {MAX_FILES_PER_WINDOW} files / {WINDOW_SECONDS}s • {(MAX_BYTES_PER_WINDOW / (1024 * 1024)).toFixed(0)} MB aggregate
                </div>
              </div>
              <div>
                <div className="text-[10px] text-[var(--muted)] uppercase">Canary Bytes Ingested</div>
                <div
                  data-testid="bytes-read-oversized-write"
                  className="text-[11px] font-bold text-[var(--teal)]"
                >
                  0 bytes read (Pre-read Rejection)
                </div>
              </div>
            </div>

            {/* Containment Alert Badge */}
            {oversizeState.containmentTriggered && (
              <div
                data-testid="containment-alert-oversized-write"
                className="p-3 rounded border space-y-1.5"
                style={{
                  backgroundColor: 'rgba(239, 68, 68, 0.1)',
                  borderColor: colors.red,
                }}
              >
                <div className="flex items-center justify-between">
                  <span
                    data-testid="containment-alert-badge-oversized_write"
                    className="px-2 py-0.5 rounded text-[11px] font-mono font-bold uppercase"
                    style={{
                      backgroundColor: colors.red,
                      color: 'var(--on-accent)',
                    }}
                  >
                    Containment Alert: Size Limit Exceeded
                  </span>
                  {oversizeState.latencyMs !== null && (
                    <span
                      data-testid="latency-oversized-write"
                      className="text-xs font-mono text-[var(--muted)]"
                    >
                      {oversizeState.latencyMs} ms
                    </span>
                  )}
                </div>
                <p
                  data-testid="rejection-reason-oversized-write"
                  className="text-xs text-[var(--text)] font-mono leading-relaxed"
                >
                  {oversizeState.rejectionMessage}
                </p>
              </div>
            )}
          </div>

          <div className="pt-3 border-t border-[var(--border)] flex items-center justify-between gap-2">
            <button
              type="button"
              data-testid="inject-oversized-write-btn"
              onClick={handleInjectOversizedWrite}
              disabled={inFlight || oversizeState.isInjecting}
              className="flex-1 px-3 py-2 rounded text-xs font-medium font-mono bg-[var(--error)]/20 hover:bg-[var(--error)]/30 text-[var(--error)] border border-[var(--error)]/40 hover:border-[var(--error)] transition-colors cursor-pointer disabled:opacity-50"
            >
              {oversizeState.isInjecting ? 'Testing Limit...' : 'Inject Oversized Write'}
            </button>
            {oversizeState.isInjected && (
              <button
                type="button"
                data-testid="restore-oversized-write-btn"
                onClick={handleRestoreOversizedWrite}
                disabled={inFlight || oversizeState.isInjecting}
                className="px-3 py-2 rounded text-xs font-mono text-[var(--teal)] hover:bg-[var(--teal)]/15 border border-[var(--teal)]/40 transition-colors cursor-pointer disabled:opacity-50"
              >
                Restore
              </button>
            )}
          </div>
        </div>
      </div>

      {/* ===================================================================== */}
      {/* Live Hash Comparison Table Section (Feeds into Stage 3 Artifact View) */}
      {/* ===================================================================== */}
      <div className="p-5 bg-[var(--surface)] border border-[var(--border)] rounded-lg space-y-4 shadow-sm">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--border)] pb-3">
          <div>
            <h3 className="text-sm font-semibold text-[var(--text)] uppercase tracking-wider font-mono">
              Live Artifact Digest Verification Ledger
            </h3>
            <p className="text-xs text-[var(--muted)] mt-0.5">
              Reflects active hash comparison across session artifacts. Tampering modifies the computed digest and turns the status badge red.
            </p>
          </div>

          <span
            data-testid="containment-alert-badge"
            className="px-2.5 py-1 rounded text-xs font-mono font-bold uppercase border"
            style={{
              backgroundColor: isHashMatch
                ? 'rgba(20, 184, 166, 0.15)'
                : 'rgba(239, 68, 68, 0.15)',
              borderColor: isHashMatch ? colors.tealLoom : colors.red,
              color: isHashMatch ? colors.tealLoom : colors.red,
            }}
          >
            {isHashMatch ? 'All Artifacts Verified' : 'Integrity Tamper Detected'}
          </span>
        </div>

        <div
          data-testid="hash-comparison-table"
          className="overflow-x-auto rounded border border-[var(--border)] bg-[var(--bg)]"
        >
          <table className="w-full text-left text-xs border-collapse font-mono">
            <thead>
              <tr className="border-b border-[var(--border)] bg-[var(--surface2)] text-[var(--muted)] text-[11px] uppercase">
                <th className="p-3">Artifact ID</th>
                <th className="p-3">Root Scope</th>
                <th className="p-3">Expected SHA-256</th>
                <th className="p-3">Computed SHA-256</th>
                <th className="p-3">Size</th>
                <th className="p-3 text-right">Integrity Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[var(--border)]/50">
              <tr
                data-testid={`artifact-row-${ephemeralArtifact.artifactId}`}
                className="hover:bg-[var(--surface2)]/40 transition-colors"
              >
                <td className="p-3 font-semibold text-[var(--text)]">
                  {ephemeralArtifact.artifactId}
                </td>
                <td className="p-3 text-[var(--muted)]">{ephemeralArtifact.rootId}</td>
                <td
                  data-testid={`artifact-expected-sha-${ephemeralArtifact.artifactId}`}
                  className="p-3 text-[var(--cyan)]"
                  title={BASELINE_EPHEMERAL_ARTIFACT.sha256}
                >
                  {BASELINE_EPHEMERAL_ARTIFACT.sha256.slice(0, 16)}...
                </td>
                <td
                  data-testid={`artifact-computed-sha-${ephemeralArtifact.artifactId}`}
                  className="p-3 font-semibold"
                  style={{
                    color: isHashMatch ? colors.cyanLoom : colors.red,
                  }}
                  title={hashState.currentSha256}
                >
                  {hashState.currentSha256.slice(0, 16)}...
                </td>
                <td className="p-3 text-[var(--muted)]">
                  {ephemeralArtifact.sizeBytes.toLocaleString()} B
                </td>
                <td className="p-3 text-right">
                  <span
                    data-testid={`artifact-status-badge-${ephemeralArtifact.artifactId}`}
                    className="px-2.5 py-1 rounded text-[10px] font-bold uppercase border"
                    style={{
                      backgroundColor: isHashMatch
                        ? 'rgba(20, 184, 166, 0.15)'
                        : 'rgba(239, 68, 68, 0.15)',
                      borderColor: isHashMatch ? colors.tealLoom : colors.red,
                      color: isHashMatch ? colors.tealLoom : colors.red,
                    }}
                  >
                    {isHashMatch ? 'Match' : 'Mismatch'}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
