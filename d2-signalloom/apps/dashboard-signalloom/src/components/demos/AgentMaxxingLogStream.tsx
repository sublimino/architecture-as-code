import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import StreamingLogBlock, { visibleLines } from '../StreamingLogBlock'
import {
  STAGE_METADATA,
  type AdversarialTamperPayload,
  type ConfinementStreamingPayload,
  type HostEnrolledPayload,
  type OperatorInitPayload,
  type RevocationDeniedPayload,
  type StageId,
  type StagePayloadMap,
} from './types'

// ============================================================================
// ANSI Color Sequences & Format Constants
// ============================================================================

export const ANSI = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  cyan: '\x1b[1;36m',
  teal: '\x1b[1;32m',
  red: '\x1b[1;31m',
  amber: '\x1b[1;33m',
} as const

export interface StageLogFormatOptions {
  readonly timestamp?: Date | string | number
  readonly error?: string | Error
}

/**
 * Formats epoch, ISO string, or Date into standard bracketed clock `[HH:MM:SS]`.
 * Matches StreamingLogBlock's TIMESTAMP regular expression for leading metadata.
 */
export function formatTimestamp(dateInput?: Date | string | number): string {
  const date = dateInput
    ? typeof dateInput === 'string' || typeof dateInput === 'number'
      ? new Date(dateInput)
      : dateInput
    : new Date()
  if (Number.isNaN(date.getTime())) return '[00:00:00]'
  const h = String(date.getHours()).padStart(2, '0')
  const m = String(date.getMinutes()).padStart(2, '0')
  const s = String(date.getSeconds()).padStart(2, '0')
  return `[${h}:${m}:${s}]`
}

/**
 * Generates ANSI-colored, timestamped log lines for each AgentMaxxing execution stage.
 * Ensures all cryptographic, kernel Landlock LSM, and zero-payload invariants are logged.
 */
export function formatStageLogLines<S extends StageId>(
  stage: S,
  payload?: Partial<StagePayloadMap[S]> | null,
  options: StageLogFormatOptions = {},
): string[] {
  const ts = options.timestamp ? formatTimestamp(options.timestamp) : formatTimestamp()
  const { cyan, teal, red, reset } = ANSI

  switch (stage) {
    case 'operator_init': {
      const p = (payload as Partial<OperatorInitPayload>) || {}
      const tokenId = p.tokenId ?? 'tok-init-001'
      const tokenPrefix = p.tokenPrefix ?? 'sl_amxd'
      const ttl = p.ttlSeconds ?? 3600
      const operatorId = p.operatorId ?? 'operator@signalloom.internal'
      const digest = p.tokenId
        ? `sha256:${p.tokenId.slice(0, 16)}...`
        : 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

      return [
        `${ts} ${cyan}[operator]${reset} Initializing Stage 1: Operator Authentication & Token Minting`,
        `${ts} ${cyan}[operator]${reset} Validating OIDC audience (aud: signalloom-controlplane, issuer: auth0)`,
        `${ts} ${cyan}[operator]${reset} ${teal}✓${reset} OIDC audience validation passed for operator ${operatorId}`,
        `${ts} ${cyan}[operator]${reset} Executing token minting (prefix: ${tokenPrefix}, ttl: ${ttl}s, id: ${tokenId})`,
        `${ts} ${cyan}[operator]${reset} ${teal}✓${reset} Token minting completed; single-use enrollment token generated`,
        `${ts} ${cyan}[operator]${reset} Computing cryptographic token digest hashing for audit verification`,
        `${ts} ${cyan}[operator]${reset} ${teal}✓${reset} Token digest hashing verified: ${digest}`,
      ]
    }

    case 'host_enrolled': {
      const p = (payload as Partial<HostEnrolledPayload>) || {}
      const hostId = p.hostId ?? 'host-linux-node-01'
      const agentId = p.agentId ?? 'agent-amxd-worker-01'
      const fp = p.publicKeyFingerprint ?? 'SHA256:7mP0nQ6yBvF8zR2tK9xW5eL1sA4='
      const filterHash = 'b3f58a2d9c1e7a4f6d8b0c2e4a6f8d0b2c4e6a8f0d2b4c6e8a0f2d4b6c8e0a2f'

      return [
        `${ts} ${cyan}[landlock]${reset} Initializing Stage 2: Agent Registration & Landlock LSM Enforcement`,
        `${ts} ${cyan}[landlock]${reset} Executing agent registration for host ${hostId} (agent_id: ${agentId})`,
        `${ts} ${cyan}[landlock]${reset} ${teal}✓${reset} Agent registration confirmed; public key fingerprint: ${fp}`,
        `${ts} ${cyan}[landlock]${reset} Configuring Landlock LSM ruleset creation (ABI v3, handled_access_fs=0x7fff)`,
        `${ts} ${cyan}[landlock]${reset} ${teal}✓${reset} Landlock LSM ruleset creation (ABI v3) active (fd=5, restricted process comm=nono)`,
        `${ts} ${cyan}[landlock]${reset} Applying deny_paths enforcement (/home/*/.ssh, /etc/shadow, /etc/sudoers, /root)`,
        `${ts} ${cyan}[landlock]${reset} ${teal}✓${reset} deny_paths enforcement active: sensitive host paths quarantined`,
        `${ts} ${cyan}[landlock]${reset} Executing filter.py TOCTOU hash check against deployed binary`,
        `${ts} ${cyan}[landlock]${reset} ${teal}✓${reset} filter.py TOCTOU hash check verified: sha256:${filterHash.slice(0, 16)}...`,
      ]
    }

    case 'confinement_streaming': {
      const p = (payload as Partial<ConfinementStreamingPayload>) || {}
      const comm = p.processComm ?? 'nono'
      const cpuTicks = p.cpuTicks ?? 1420
      const cpuSec = (cpuTicks / 1000).toFixed(2)
      const rssBytes = p.rssBytes ?? 48234496
      const rssMb = (rssBytes / (1024 * 1024)).toFixed(2)
      const fds = p.openFds ?? 3
      const expHash =
        p.expectedSha256 ?? 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      const obsHash = p.observedSha256 ?? expHash
      const match = p.hashMatch ?? expHash === obsHash

      return [
        `${ts} ${cyan}[telemetry]${reset} Initializing Stage 3: Landlock Confinement & Telemetry Streaming`,
        `${ts} ${cyan}[telemetry]${reset} Polling live telemetry stream for process: ${comm} (cgroup v2 sandbox)`,
        `${ts} ${cyan}[telemetry]${reset} ${teal}✓${reset} Live telemetry channel connected (cgroup v2 stats active)`,
        `${ts} ${cyan}[telemetry]${reset} Ingesting CPU/memory stats: cpuTicks=${cpuTicks} (${cpuSec}s), rssBytes=${rssBytes} (${rssMb} MB), openFds=${fds}`,
        `${ts} ${cyan}[telemetry]${reset} ${teal}✓${reset} CPU/memory stats within confinement thresholds`,
        `${ts} ${cyan}[telemetry]${reset} Executing zero-customer-payload validator against host sensor filter.py schema`,
        `${ts} ${cyan}[telemetry]${reset} ${teal}✓${reset} Zero-customer-payload validator confirmed: 24/24 allowlist fields match, 0 customer bytes`,
        `${ts} ${cyan}[telemetry]${reset} Cryptographic artifact hash verification: ${expHash.slice(0, 16)}... vs ${obsHash.slice(0, 16)}...`,
        `${ts} ${cyan}[telemetry]${reset} ${match ? `${teal}✓${reset} Hash match verified (match=true)` : `${red}✗${reset} FAILED: Hash mismatch detected`}`,
      ]
    }

    case 'adversarial_tamper': {
      const p = (payload as Partial<AdversarialTamperPayload>) || {}
      const tamperType = p.tamperType ?? 'hash_mismatch'
      const origHash =
        p.originalSha256 ?? 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      const tampHash =
        p.tamperedSha256 ?? 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      const breach = p.breachDetected ?? true
      const containment = p.containmentTriggered ?? true
      const latency = p.detectionLatencyMs ?? 42

      return [
        `${ts} ${cyan}[anti-tamper]${reset} Initializing Stage 4: Adversarial Simulation & Anti-Tamper Containment`,
        `${ts} ${cyan}[anti-tamper]${reset} Executing simulated attack vector: ${tamperType}`,
        `${ts} ${cyan}[anti-tamper]${reset} ${red}✗${reset} Tamper injection detection confirmed: breach_detected=${breach}`,
        `${ts} ${cyan}[anti-tamper]${reset} SHA-256 hash divergence detected:`,
        `${ts} ${cyan}[anti-tamper]${reset}   Expected: ${origHash}`,
        `${ts} ${cyan}[anti-tamper]${reset}   Observed: ${tampHash}`,
        `${ts} ${cyan}[anti-tamper]${reset} Activating anti-tamper quarantine trigger via cgroup freezer SIGSTOP`,
        `${ts} ${cyan}[anti-tamper]${reset} ${teal}✓${reset} Anti-tamper quarantine trigger executed: containment_triggered=${containment}`,
        `${ts} ${cyan}[anti-tamper]${reset} Dispatching security alert emission SIEM-TAMPER-ALERT to audit log bus`,
        `${ts} ${cyan}[anti-tamper]${reset} ${teal}✓${reset} Security alert emission confirmed (detection latency: ${latency}ms)`,
      ]
    }

    case 'revocation_denied': {
      const p = (payload as Partial<RevocationDeniedPayload>) || {}
      const hostId = p.hostId ?? 'host-linux-node-01'
      const operator = p.operatorAttribution ?? 'Mock Operator (acme-corp)'
      const revokedAt = p.revokedAt ?? new Date().toISOString()
      const endpoint = p.attemptedEndpoint ?? '/api/v1/external-agents/evidence-uploads'
      const statusCode = p.responseStatusCode ?? 403
      const proofDigest =
        p.proofDigest ?? 'c0ffee4298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

      return [
        `${ts} ${cyan}[revocation]${reset} Initializing Stage 5: Attributable Revocation & 403 Denial Verification`,
        `${ts} ${cyan}[revocation]${reset} Dispatching operator-attributed token revocation for host ${hostId}`,
        `${ts} ${cyan}[revocation]${reset} ${teal}✓${reset} Operator-attributed token revocation attributed to: ${operator} at ${revokedAt}`,
        `${ts} ${cyan}[revocation]${reset} Commencing credential eviction across host memory and OpenBao lease store`,
        `${ts} ${cyan}[revocation]${reset} ${teal}✓${reset} Credential eviction completed; session tokens purged`,
        `${ts} ${cyan}[revocation]${reset} Testing subsequent request to ${endpoint}`,
        `${ts} ${cyan}[revocation]${reset} ${teal}✓${reset} 403 Forbidden verification confirmed (HTTP 403 Forbidden: status code ${statusCode})`,
        `${ts} ${cyan}[revocation]${reset} Denial proof digest recorded: sha256:${proofDigest.slice(0, 16)}...`,
      ]
    }

    default: {
      return [
        `${ts} ${cyan}[agentmaxxing]${reset} Executing stage: ${stage}`,
        `${ts} ${cyan}[agentmaxxing]${reset} ${teal}✓${reset} Stage ${stage} executed successfully`,
      ]
    }
  }
}

/**
 * Returns formatted stage log as a single newline-delimited string.
 */
export function formatStageLog<S extends StageId>(
  stage: S,
  payload?: Partial<StagePayloadMap[S]> | null,
  options?: StageLogFormatOptions,
): string {
  return formatStageLogLines(stage, payload, options).join('\n') + '\n'
}

/**
 * Formats an error line with appropriate stage prefix, ANSI red error marker, and timestamp.
 */
export function formatErrorLogLine(
  stage: StageId,
  error: string | Error,
  timestamp?: Date | string | number,
): string {
  const ts = timestamp ? formatTimestamp(timestamp) : formatTimestamp()
  const msg = error instanceof Error ? error.message : String(error)
  const tag =
    stage === 'operator_init'
      ? 'operator'
      : stage === 'host_enrolled'
        ? 'landlock'
        : stage === 'confinement_streaming'
          ? 'telemetry'
          : stage === 'adversarial_tamper'
            ? 'anti-tamper'
            : 'revocation'

  return `${ts} ${ANSI.cyan}[${tag}]${ANSI.reset} ${ANSI.red}FAILED:${ANSI.reset} ${msg}`
}

// ============================================================================
// Hook: useAgentMaxxingLogStream
// ============================================================================

export interface UseAgentMaxxingLogStreamOptions {
  readonly initialLog?: string
  readonly defaultStage?: StageId
  readonly maxLines?: number
  readonly progressiveDelayMs?: number
}

export interface UseAgentMaxxingLogStreamReturn {
  readonly log: string
  readonly lines: readonly string[]
  readonly isStreaming: boolean
  readonly lineCount: number
  readonly status: string
  readonly statusTone: string
  readonly appendLog: (chunk: string) => void
  readonly appendLine: (line: string) => void
  readonly appendStageLog: <S extends StageId>(
    stage: S,
    payload?: Partial<StagePayloadMap[S]> | null,
    options?: { progressive?: boolean; delayMs?: number; timestamp?: Date | string | number },
  ) => Promise<void>
  readonly streamStage: <S extends StageId>(
    stage: S,
    payload?: Partial<StagePayloadMap[S]> | null,
    options?: { delayMs?: number; timestamp?: Date | string | number },
  ) => Promise<void>
  readonly appendError: (
    stage: StageId,
    error: string | Error,
    timestamp?: Date | string | number,
  ) => void
  readonly clear: () => void
  readonly setStatus: (status: string, tone?: string) => void
  readonly flush: () => void
}

export function useAgentMaxxingLogStream(
  options: UseAgentMaxxingLogStreamOptions = {},
): UseAgentMaxxingLogStreamReturn {
  const { initialLog = '', progressiveDelayMs = 40 } = options

  const [log, setLog] = useState<string>(initialLog)
  const [isStreaming, setIsStreaming] = useState<boolean>(false)
  const [status, setStatus] = useState<string>('idle')
  const [statusTone, setStatusTone] = useState<string>('var(--muted)')

  const activeTimerRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const pendingChunksRef = useRef<string[]>([])
  const isMountedRef = useRef<boolean>(true)

  useEffect(() => {
    isMountedRef.current = true
    return () => {
      isMountedRef.current = false
      if (activeTimerRef.current) {
        clearInterval(activeTimerRef.current)
        activeTimerRef.current = null
      }
    }
  }, [])

  const appendLog = useCallback((chunk: string) => {
    setLog((prev) => prev + chunk)
  }, [])

  const appendLine = useCallback((line: string) => {
    setLog((prev) => prev + (line.endsWith('\n') ? line : line + '\n'))
  }, [])

  const appendError = useCallback(
    (stage: StageId, error: string | Error, timestamp?: Date | string | number) => {
      const errorLine = formatErrorLogLine(stage, error, timestamp)
      setLog((prev) => prev + errorLine + '\n')
      setStatus('failed')
      setStatusTone('var(--error)')
    },
    [],
  )

  const clear = useCallback(() => {
    if (activeTimerRef.current) {
      clearInterval(activeTimerRef.current)
      activeTimerRef.current = null
    }
    pendingChunksRef.current = []
    setLog('')
    setIsStreaming(false)
    setStatus('idle')
    setStatusTone('var(--muted)')
  }, [])

  const flush = useCallback(() => {
    if (activeTimerRef.current) {
      clearInterval(activeTimerRef.current)
      activeTimerRef.current = null
    }
    if (pendingChunksRef.current.length > 0) {
      const remaining = pendingChunksRef.current.join('\n') + '\n'
      pendingChunksRef.current = []
      setLog((prev) => prev + remaining)
    }
    setIsStreaming(false)
    setStatus('completed')
    setStatusTone('var(--teal)')
  }, [])

  const appendStageLog = useCallback(
    async <S extends StageId>(
      stage: S,
      payload?: Partial<StagePayloadMap[S]> | null,
      opts?: { progressive?: boolean; delayMs?: number; timestamp?: Date | string | number },
    ): Promise<void> => {
      const stageLines = formatStageLogLines(stage, payload, opts)

      if (!opts?.progressive) {
        const text = stageLines.join('\n') + '\n'
        setLog((prev) => prev + text)
        setStatus('completed')
        setStatusTone('var(--teal)')
        return
      }

      // Progressive streaming mode
      if (activeTimerRef.current) {
        clearInterval(activeTimerRef.current)
        activeTimerRef.current = null
      }

      setIsStreaming(true)
      setStatus('streaming')
      setStatusTone('var(--cyan)')

      return new Promise<void>((resolve) => {
        if (stageLines.length === 0) {
          setIsStreaming(false)
          setStatus('idle')
          setStatusTone('var(--muted)')
          resolve()
          return
        }

        pendingChunksRef.current = [...stageLines]
        const delay = opts?.delayMs ?? progressiveDelayMs

        // Emit first line immediately
        const first = pendingChunksRef.current.shift()!
        setLog((prev) => prev + first + '\n')

        if (pendingChunksRef.current.length === 0) {
          setIsStreaming(false)
          setStatus('completed')
          setStatusTone('var(--teal)')
          resolve()
          return
        }

        activeTimerRef.current = setInterval(() => {
          if (!isMountedRef.current) {
            if (activeTimerRef.current) clearInterval(activeTimerRef.current)
            activeTimerRef.current = null
            resolve()
            return
          }

          if (pendingChunksRef.current.length > 0) {
            const next = pendingChunksRef.current.shift()!
            setLog((prev) => prev + next + '\n')
          }

          if (pendingChunksRef.current.length === 0) {
            if (activeTimerRef.current) {
              clearInterval(activeTimerRef.current)
              activeTimerRef.current = null
            }
            setIsStreaming(false)
            setStatus('completed')
            setStatusTone('var(--teal)')
            resolve()
          }
        }, delay)
      })
    },
    [progressiveDelayMs],
  )

  const streamStage = useCallback(
    async <S extends StageId>(
      stage: S,
      payload?: Partial<StagePayloadMap[S]> | null,
      opts?: { delayMs?: number; timestamp?: Date | string | number },
    ): Promise<void> => {
      return appendStageLog(stage, payload, { ...opts, progressive: true })
    },
    [appendStageLog],
  )

  const setStatusCustom = useCallback((newStatus: string, tone = 'var(--muted)') => {
    setStatus(newStatus)
    setStatusTone(tone)
  }, [])

  const { lines } = useMemo(() => visibleLines(log, 1000), [log])
  const lineCount = lines.length === 1 && lines[0] === '' ? 0 : lines.length

  return useMemo(
    () => ({
      log,
      lines,
      isStreaming,
      lineCount,
      status,
      statusTone,
      appendLog,
      appendLine,
      appendStageLog,
      streamStage,
      appendError,
      clear,
      setStatus: setStatusCustom,
      flush,
    }),
    [
      log,
      lines,
      isStreaming,
      lineCount,
      status,
      statusTone,
      appendLog,
      appendLine,
      appendStageLog,
      streamStage,
      appendError,
      clear,
      setStatusCustom,
      flush,
    ],
  )
}

// ============================================================================
// Component: AgentMaxxingLogStream
// ============================================================================

export interface AgentMaxxingLogStreamProps {
  readonly logStream?: UseAgentMaxxingLogStreamReturn
  readonly initialLog?: string
  readonly stage?: StageId
  readonly title?: string
  readonly status?: string
  readonly statusTone?: string
  readonly streaming?: boolean
  readonly maxLines?: number
  readonly placeholder?: string
  readonly onClear?: () => void
  readonly onCopy?: (rawLog: string) => void
  readonly testId?: string
  readonly className?: string
  readonly style?: React.CSSProperties
}

export function AgentMaxxingLogStream({
  logStream: propLogStream,
  initialLog = '',
  stage,
  title,
  status: propStatus,
  statusTone: propStatusTone,
  streaming: propStreaming,
  maxLines,
  placeholder = 'Waiting for execution logs...',
  onClear,
  onCopy,
  testId = 'agentmaxxing-log-stream',
  className = '',
  style,
}: AgentMaxxingLogStreamProps): React.JSX.Element {
  const internalStream = useAgentMaxxingLogStream({ initialLog, defaultStage: stage })
  const stream = propLogStream ?? internalStream

  const log = stream.log
  const isStreaming = propStreaming !== undefined ? propStreaming : stream.isStreaming
  const displayStatus = propStatus ?? stream.status
  const displayStatusTone = propStatusTone ?? stream.statusTone
  const lineCount = stream.lineCount

  const handleClear = useCallback(() => {
    stream.clear()
    onClear?.()
  }, [stream, onClear])

  const handleCopy = useCallback(async () => {
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard) {
        await navigator.clipboard.writeText(log)
      }
    } catch {
      /* clipboard write error in non-secure or test context */
    }
    onCopy?.(log)
  }, [log, onCopy])

  const stageMeta = stage ? STAGE_METADATA[stage] : null
  const displayTitle =
    title ?? (stageMeta ? `Execution Log · ${stageMeta.shortTitle}` : 'AgentMaxxing Log Stream')

  return (
    <div
      data-testid={testId}
      className={`card ${className}`}
      style={{
        backgroundColor: 'var(--surface)',
        borderColor: 'var(--border)',
        borderWidth: 1,
        borderStyle: 'solid',
        borderRadius: 8,
        padding: '16px',
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
        color: 'var(--text)',
        ...style,
      }}
    >
      {/* Header Controls Bar */}
      <div
        data-testid={`${testId}-toolbar`}
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
          borderBottom: '1px solid var(--border)',
          paddingBottom: 12,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <span
            data-testid="log-stream-status-indicator"
            className="tag"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              padding: '3px 8px',
              borderRadius: 4,
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 600,
              letterSpacing: '0.05em',
              textTransform: 'uppercase',
              backgroundColor: isStreaming ? 'rgba(6, 182, 212, 0.15)' : 'rgba(148, 163, 184, 0.12)',
              color: isStreaming ? 'var(--cyan)' : 'var(--muted)',
              border: `1px solid ${isStreaming ? 'var(--cyan)' : 'var(--border)'}`,
            }}
          >
            <span
              style={{
                width: 6,
                height: 6,
                borderRadius: '50%',
                backgroundColor: isStreaming ? 'var(--cyan)' : 'var(--muted)',
                display: 'inline-block',
              }}
            />
            <span>{isStreaming ? 'STREAMING' : displayStatus.toUpperCase()}</span>
          </span>

          {stage && (
            <span
              data-testid={`${testId}-stage-badge`}
              className="tag"
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: 600,
                padding: '3px 8px',
                borderRadius: 4,
                background: 'var(--surface2)',
                color: 'var(--cyan)',
                border: '1px solid var(--border)',
              }}
            >
              STAGE 0{stageMeta?.stepNumber ?? ''}
            </span>
          )}

          <span
            data-testid="log-stream-line-count"
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              color: 'var(--muted)',
              marginLeft: 2,
            }}
          >
            {lineCount} {lineCount === 1 ? 'line' : 'lines'}
          </span>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button
            type="button"
            data-testid="log-stream-clear-btn"
            onClick={handleClear}
            className="btn btn-secondary"
            style={{
              padding: '4px 10px',
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 500,
              borderRadius: 4,
              cursor: 'pointer',
              background: 'var(--surface2)',
              color: 'var(--muted)',
              border: '1px solid var(--border)',
            }}
          >
            Clear
          </button>
          <button
            type="button"
            data-testid="log-stream-copy-btn"
            onClick={handleCopy}
            className="btn btn-secondary"
            style={{
              padding: '4px 10px',
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 500,
              borderRadius: 4,
              cursor: 'pointer',
              background: 'var(--surface2)',
              color: 'var(--muted)',
              border: '1px solid var(--border)',
            }}
          >
            Copy
          </button>
        </div>
      </div>

      {/* StreamingLogBlock Integration */}
      <StreamingLogBlock
        log={log}
        streaming={isStreaming}
        title={displayTitle}
        status={displayStatus}
        statusTone={displayStatusTone}
        maxLines={maxLines}
        placeholder={placeholder}
        testId="streaming-log"
      />
    </div>
  )
}

export default AgentMaxxingLogStream
