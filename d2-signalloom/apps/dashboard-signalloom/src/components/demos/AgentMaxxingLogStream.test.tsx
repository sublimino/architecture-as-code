import React from 'react'
import { render, screen, act, fireEvent, waitFor } from '@testing-library/react'
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  AgentMaxxingLogStream,
  useAgentMaxxingLogStream,
  formatStageLogLines,
  formatStageLog,
  formatErrorLogLine,
  formatTimestamp,
  ANSI,
} from './AgentMaxxingLogStream'
import { stripAnsi } from '../StreamingLogBlock'
import type {
  AdversarialTamperPayload,
  ConfinementStreamingPayload,
  HostEnrolledPayload,
  OperatorInitPayload,
  RevocationDeniedPayload,
} from './types'

describe('AgentMaxxingLogStream & useAgentMaxxingLogStream', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // ==========================================================================
  // 1. Stage Log Formatting & Verification
  // ==========================================================================
  describe('Stage Log Generation & Invariant Formatting', () => {
    it('formatTimestamp produces [HH:MM:SS] standard format', () => {
      const fixedDate = new Date(2026, 8, 25, 14, 30, 45)
      expect(formatTimestamp(fixedDate)).toBe('[14:30:45]')
      expect(formatTimestamp('invalid')).toBe('[00:00:00]')
    })

    it('Stage 1 (operator_init): logs token minting, OIDC audience validation, and token digest hashing with ANSI styling', () => {
      const payload: OperatorInitPayload = {
        tokenId: 'tok-amxd-7788',
        issuedAt: '2026-09-25T14:30:00Z',
        ttlSeconds: 3600,
        operatorId: 'operator-alice@control-plane.io',
        tokenPrefix: 'sl_amxd',
      }

      const lines = formatStageLogLines('operator_init', payload, {
        timestamp: new Date(2026, 8, 25, 10, 0, 0),
      })
      const fullText = lines.join('\n')
      const cleanText = stripAnsi(fullText)

      // Invariants required by spec
      expect(cleanText).toContain('token minting')
      expect(cleanText).toContain('OIDC audience validation')
      expect(cleanText).toContain('token digest hashing')
      expect(cleanText).toContain('operator-alice@control-plane.io')
      expect(cleanText).toContain('tok-amxd-7788')
      expect(cleanText).toContain('[10:00:00]')

      // ANSI coloring checks
      expect(fullText).toContain(ANSI.cyan)
      expect(fullText).toContain(ANSI.teal)
      expect(fullText).toContain(ANSI.reset)
      expect(lines.length).toBeGreaterThanOrEqual(6)
    })

    it('Stage 2 (host_enrolled): logs agent registration, Landlock LSM ruleset creation (ABI v3), deny_paths enforcement, and filter.py TOCTOU hash check', () => {
      const payload: HostEnrolledPayload = {
        hostId: 'host-worker-west-01',
        agentId: 'agent-4412',
        publicKeyFingerprint: 'SHA256:abc123xyz789fingerprint',
        enrolledAt: '2026-09-25T14:31:00Z',
        status: 'enrolled',
      }

      const lines = formatStageLogLines('host_enrolled', payload, {
        timestamp: new Date(2026, 8, 25, 10, 0, 1),
      })
      const cleanText = stripAnsi(lines.join('\n'))

      expect(cleanText).toContain('agent registration')
      expect(cleanText).toContain('Landlock LSM ruleset creation (ABI v3)')
      expect(cleanText).toContain('deny_paths enforcement')
      expect(cleanText).toContain('/home/*/.ssh')
      expect(cleanText).toContain('/etc/shadow')
      expect(cleanText).toContain('filter.py TOCTOU hash check')
      expect(cleanText).toContain('host-worker-west-01')
      expect(cleanText).toContain('SHA256:abc123xyz789fingerprint')
    })

    it('Stage 3 (confinement_streaming): logs live telemetry, CPU/memory stats, zero-customer-payload validator (24/24 allowlist fields match, 0 customer bytes)', () => {
      const payload: ConfinementStreamingPayload = {
        processComm: 'nono-agent',
        cpuTicks: 1650,
        rssBytes: 52428800,
        openFds: 4,
        expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        observedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        hashMatch: true,
        zeroPayloadVerified: true,
      }

      const lines = formatStageLogLines('confinement_streaming', payload, {
        timestamp: new Date(2026, 8, 25, 10, 0, 2),
      })
      const cleanText = stripAnsi(lines.join('\n'))

      expect(cleanText).toContain('live telemetry')
      expect(cleanText).toContain('CPU/memory stats')
      expect(cleanText).toContain('zero-customer-payload validator')
      expect(cleanText).toContain('24/24 allowlist fields match, 0 customer bytes')
      expect(cleanText).toContain('1650')
      expect(cleanText).toContain('50.00 MB')
      expect(cleanText).toContain('nono-agent')
      expect(cleanText).toContain('Hash match verified')
    })

    it('Stage 4 (adversarial_tamper): logs tamper injection detection, SHA-256 hash divergence, anti-tamper quarantine trigger, security alert emission', () => {
      const payload: AdversarialTamperPayload = {
        tamperType: 'hash_mismatch',
        injectedAt: '2026-09-25T14:33:00Z',
        originalSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        tamperedSha256: 'deadbeef98fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        breachDetected: true,
        containmentTriggered: true,
        detectionLatencyMs: 38,
      }

      const lines = formatStageLogLines('adversarial_tamper', payload, {
        timestamp: new Date(2026, 8, 25, 10, 0, 3),
      })
      const cleanText = stripAnsi(lines.join('\n'))

      expect(cleanText.toLowerCase()).toContain('tamper injection detection')
      expect(cleanText.toLowerCase()).toContain('sha-256 hash divergence')
      expect(cleanText.toLowerCase()).toContain('anti-tamper quarantine trigger')
      expect(cleanText.toLowerCase()).toContain('security alert emission')
      expect(cleanText).toContain('deadbeef')
      expect(cleanText).toContain('38ms')
    })

    it('Stage 5 (revocation_denied): logs operator-attributed token revocation, credential eviction, 403 Forbidden verification', () => {
      const payload: RevocationDeniedPayload = {
        hostId: 'host-compromised-09',
        operatorAttribution: 'Operator (sec-ops-lead)',
        revokedAt: '2026-09-25T14:35:00Z',
        attemptedEndpoint: '/api/v1/external-agents/evidence-uploads',
        responseStatusCode: 403,
        denialConfirmed: true,
        proofDigest: 'f00d4298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      }

      const lines = formatStageLogLines('revocation_denied', payload, {
        timestamp: new Date(2026, 8, 25, 10, 0, 4),
      })
      const cleanText = stripAnsi(lines.join('\n'))

      expect(cleanText).toContain('operator-attributed token revocation')
      expect(cleanText).toContain('credential eviction')
      expect(cleanText).toContain('403 Forbidden verification')
      expect(cleanText).toContain('Operator (sec-ops-lead)')
      expect(cleanText).toContain('HTTP 403 Forbidden')
      expect(cleanText).toContain('host-compromised-09')
    })

    it('formatStageLog returns a single string with trailing newline', () => {
      const str = formatStageLog('operator_init', null)
      expect(typeof str).toBe('string')
      expect(str.endsWith('\n')).toBe(true)
      expect(str.split('\n').length).toBeGreaterThan(5)
    })

    it('formatErrorLogLine formats error with FAILED: marker and ANSI red escape', () => {
      const errorLog = formatErrorLogLine(
        'confinement_streaming',
        new Error('Socket disconnected abruptly'),
        new Date(2026, 8, 25, 11, 22, 33),
      )
      expect(errorLog).toContain('[11:22:33]')
      expect(errorLog).toContain('[telemetry]')
      expect(errorLog).toContain('FAILED:')
      expect(errorLog).toContain('Socket disconnected abruptly')
      expect(errorLog).toContain(ANSI.red)
    })
  })

  // ==========================================================================
  // 2. Progressive Chunk Streaming
  // ==========================================================================
  describe('Progressive Chunk Streaming in Hook and Component', () => {
    function HookTestComponent({ onReady }: { onReady: (hook: ReturnType<typeof useAgentMaxxingLogStream>) => void }) {
      const stream = useAgentMaxxingLogStream({ progressiveDelayMs: 50 })
      React.useEffect(() => {
        onReady(stream)
      }, [stream, onReady])
      return <div data-testid="hook-log-length">{stream.lineCount}</div>
    }

    it('supports progressive chunk streaming with interval timer', async () => {
      vi.useFakeTimers()
      let hook!: ReturnType<typeof useAgentMaxxingLogStream>

      render(<HookTestComponent onReady={(h) => (hook = h)} />)

      expect(hook.isStreaming).toBe(false)
      expect(hook.lineCount).toBe(0)

      // Trigger progressive streaming
      let streamPromise!: Promise<void>
      act(() => {
        streamPromise = hook.streamStage('confinement_streaming', null, { delayMs: 50 })
      })

      // Immediately, isStreaming becomes true and first chunk is emitted
      expect(hook.isStreaming).toBe(true)
      expect(hook.lineCount).toBe(1)

      // Advance by 50ms -> second line arrives
      act(() => {
        vi.advanceTimersByTime(50)
      })
      expect(hook.lineCount).toBe(2)

      // Advance by 100ms -> two more lines arrive
      act(() => {
        vi.advanceTimersByTime(100)
      })
      expect(hook.lineCount).toBe(4)

      // Advance through remaining chunks
      act(() => {
        vi.advanceTimersByTime(500)
      })
      await act(async () => {
        await streamPromise
      })

      expect(hook.isStreaming).toBe(false)
      expect(hook.status).toBe('completed')
      expect(hook.lineCount).toBeGreaterThanOrEqual(8)
    })

    it('flush() terminates progressive streaming immediately and dumps all pending chunks', async () => {
      vi.useFakeTimers()
      let hook!: ReturnType<typeof useAgentMaxxingLogStream>

      render(<HookTestComponent onReady={(h) => (hook = h)} />)

      act(() => {
        void hook.streamStage('host_enrolled', null, { delayMs: 100 })
      })

      expect(hook.isStreaming).toBe(true)
      expect(hook.lineCount).toBe(1)

      // Flush early
      act(() => {
        hook.flush()
      })

      expect(hook.isStreaming).toBe(false)
      expect(hook.lineCount).toBeGreaterThanOrEqual(8)
      expect(hook.status).toBe('completed')
    })
  })

  // ==========================================================================
  // 3. Clear Action
  // ==========================================================================
  describe('Clear Action', () => {
    it('clears log from hook directly', () => {
      function ClearHarness() {
        const stream = useAgentMaxxingLogStream({ initialLog: 'line 1\nline 2\n' })
        return (
          <div>
            <div data-testid="log-content">{stream.log}</div>
            <div data-testid="log-lines">{stream.lineCount}</div>
            <button data-testid="btn-clear" onClick={stream.clear}>
              Clear
            </button>
          </div>
        )
      }

      render(<ClearHarness />)
      expect(screen.getByTestId('log-lines')).toHaveTextContent('2')

      fireEvent.click(screen.getByTestId('btn-clear'))
      expect(screen.getByTestId('log-lines')).toHaveTextContent('0')
      expect(screen.getByTestId('log-content')).toHaveTextContent('')
    })

    it('clicking Clear button in AgentMaxxingLogStream component clears log and calls onClear callback', () => {
      const onClearSpy = vi.fn()
      render(
        <AgentMaxxingLogStream
          initialLog="[10:00:00] [operator] ✓ Ready\n"
          onClear={onClearSpy}
        />,
      )

      expect(screen.getByTestId('log-stream-line-count')).toHaveTextContent('1 line')

      const clearBtn = screen.getByTestId('log-stream-clear-btn')
      fireEvent.click(clearBtn)

      expect(screen.getByTestId('log-stream-line-count')).toHaveTextContent('0 lines')
      expect(onClearSpy).toHaveBeenCalledTimes(1)
    })
  })

  // ==========================================================================
  // 4. Copy Action
  // ==========================================================================
  describe('Copy Action', () => {
    it('clicking Copy button copies raw ANSI log to clipboard and invokes onCopy', async () => {
      const rawText = '\x1b[1;36m[telemetry]\x1b[0m \x1b[1;32m✓\x1b[0m Confinement active\n'
      const writeTextSpy = vi.fn().mockResolvedValue(undefined)
      Object.assign(navigator, {
        clipboard: {
          writeText: writeTextSpy,
        },
      })

      const onCopySpy = vi.fn()
      render(<AgentMaxxingLogStream initialLog={rawText} onCopy={onCopySpy} />)

      const copyBtn = screen.getByTestId('log-stream-copy-btn')
      fireEvent.click(copyBtn)

      await waitFor(() => {
        expect(writeTextSpy).toHaveBeenCalledWith(rawText)
        expect(onCopySpy).toHaveBeenCalledWith(rawText)
      })
    })

    it('handles clipboard failure gracefully without throwing', async () => {
      const rawText = 'Log message\n'
      const writeTextSpy = vi.fn().mockRejectedValue(new Error('Permission denied'))
      Object.assign(navigator, {
        clipboard: {
          writeText: writeTextSpy,
        },
      })

      const onCopySpy = vi.fn()
      render(<AgentMaxxingLogStream initialLog={rawText} onCopy={onCopySpy} />)

      const copyBtn = screen.getByTestId('log-stream-copy-btn')
      expect(() => fireEvent.click(copyBtn)).not.toThrow()

      await waitFor(() => {
        expect(onCopySpy).toHaveBeenCalledWith(rawText)
      })
    })
  })

  // ==========================================================================
  // 5. Error Handling
  // ==========================================================================
  describe('Error Handling', () => {
    it('appends error formatted with red FAILED: marker', () => {
      function ErrorHarness() {
        const stream = useAgentMaxxingLogStream()
        return (
          <div>
            <div data-testid="error-status">{stream.status}</div>
            <div data-testid="error-log">{stream.log}</div>
            <button
              data-testid="btn-error"
              onClick={() =>
                stream.appendError('confinement_streaming', 'EACCES: permission denied to /etc/shadow')
              }
            >
              Trigger Error
            </button>
          </div>
        )
      }

      render(<ErrorHarness />)
      fireEvent.click(screen.getByTestId('btn-error'))

      expect(screen.getByTestId('error-status')).toHaveTextContent('failed')
      const text = screen.getByTestId('error-log').textContent ?? ''
      expect(text).toContain('FAILED:')
      expect(text).toContain('EACCES: permission denied to /etc/shadow')
    })
  })

  // ==========================================================================
  // 6. Design System Tokens & Status Indicator
  // ==========================================================================
  describe('Design System Tokens & Status Indicator', () => {
    it('renders with clean design system styling tokens and live status badge', () => {
      render(
        <AgentMaxxingLogStream
          stage="confinement_streaming"
          streaming={true}
          initialLog="[12:00:00] [telemetry] Streaming...\n"
        />,
      )

      const root = screen.getByTestId('agentmaxxing-log-stream')
      expect(root).toBeInTheDocument()
      expect(root.style.backgroundColor).toBe('var(--surface)')
      expect(root.style.borderColor).toBe('var(--border)')
      expect(root.style.color).toBe('var(--text)')

      const statusBadge = screen.getByTestId('log-stream-status-indicator')
      expect(statusBadge).toHaveTextContent('STREAMING')

      const stageBadge = screen.getByTestId('agentmaxxing-log-stream-stage-badge')
      expect(stageBadge).toHaveTextContent('STAGE 03')

      const lineCount = screen.getByTestId('log-stream-line-count')
      expect(lineCount).toHaveTextContent('1 line')

      // StreamingLogBlock is integrated
      expect(screen.getByTestId('streaming-log')).toBeInTheDocument()
    })

    it('renders with external useAgentMaxxingLogStream hook instance', () => {
      function ExternalHookHarness() {
        const stream = useAgentMaxxingLogStream()
        React.useEffect(() => {
          void stream.appendStageLog('operator_init', {
            tokenId: 'tok-ext-01',
            operatorId: 'admin@signalloom.io',
          })
        }, [])

        return <AgentMaxxingLogStream logStream={stream} stage="operator_init" />
      }

      render(<ExternalHookHarness />)
      expect(screen.getByTestId('log-stream-line-count')).not.toHaveTextContent('0 lines')
      expect(screen.getByTestId('streaming-log')).toBeInTheDocument()
    })
  })
})
