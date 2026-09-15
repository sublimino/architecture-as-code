import { render, screen, waitFor, act, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import {
  AdversarialSimulationPanel,
  BASELINE_EPHEMERAL_ARTIFACT,
  CORRUPTED_SHA256,
  MAX_FILE_SIZE_BYTES,
  MAX_FILES_PER_WINDOW,
  MAX_BYTES_PER_WINDOW,
  WINDOW_SECONDS,
  REJECTION_MESSAGES,
  SYSCALL_FLAGS_OPENAT2,
  restoreEphemeralArtifact,
} from './AdversarialSimulationPanel'
import {
  createMockBridge,
  createLiveBridge,
  type LiveTransport,
  type MockDemoBridge,
  type LiveDemoBridge,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  TAMPER_BREACH_PRESET,
} from './scenarios'
import type { AdversarialTamperPayload } from './types'

function mockEvidenceTransport(): LiveTransport {
  return {
    req: vi.fn(async () => ({
      status: 'tamper_detected',
      verified: false,
    })),
    fetch: vi.fn(async () => new Response(JSON.stringify({}), { status: 200 })),
  }
}

describe('AdversarialSimulationPanel (Stage 4: Adversarial Simulation)', () => {
  let mockBridge: MockDemoBridge
  let liveBridge: LiveDemoBridge

  beforeEach(() => {
    mockBridge = createMockBridge({ preset: HAPPY_PATH_PRESET, latencyMs: 0 })
    liveBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: mockEvidenceTransport(),
    })
  })

  describe('Ground Truth Constants & Pure Restore Helpers', () => {
    it('defines exact rate limit thresholds matching ExternalAgentEvidenceV1Limit', () => {
      expect(MAX_FILE_SIZE_BYTES).toBe(16777216)
      expect(MAX_FILES_PER_WINDOW).toBe(120)
      expect(MAX_BYTES_PER_WINDOW).toBe(67108864)
      expect(WINDOW_SECONDS).toBe(60)
    })

    it('defines openat2 resolve syscall flags matching Linux kernel and host-sensor validator', () => {
      expect(SYSCALL_FLAGS_OPENAT2).toEqual([
        'RESOLVE_BENEATH',
        'RESOLVE_NO_SYMLINKS',
        'RESOLVE_NO_XDEV',
      ])
    })

    it('restoreEphemeralArtifact restores tampered artifact byte-for-byte to pre-tamper baseline', () => {
      const original = { ...BASELINE_EPHEMERAL_ARTIFACT }
      const tampered = {
        ...original,
        sha256: CORRUPTED_SHA256,
      }

      expect(tampered.sha256).not.toBe(original.sha256)
      expect(tampered.sha256).toBe(CORRUPTED_SHA256)

      const restored = restoreEphemeralArtifact(tampered)
      expect(restored.sha256).toBe(original.sha256)
      expect(restored.artifactId).toBe(original.artifactId)
      expect(restored.sizeBytes).toBe(original.sizeBytes)
      expect(restored.mtimeNs).toBe(original.mtimeNs)
    })
  })

  describe('Three Independent Injection Controls Layout & Rendering', () => {
    it('renders all three injection controls with their respective data-testids', () => {
      render(<AdversarialSimulationPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

      expect(screen.getByTestId('adversarial-simulation-panel')).toBeInTheDocument()
      expect(screen.getByTestId('adversarial-channel-badge')).toHaveTextContent('Mock fixture')

      // Control 1: Hash Mismatch
      expect(screen.getByTestId('tamper-control-hash-mismatch')).toBeInTheDocument()
      expect(screen.getByTestId('inject-hash-mismatch-btn')).toBeInTheDocument()

      // Control 2: Symlink Escape
      expect(screen.getByTestId('tamper-control-symlink-escape')).toBeInTheDocument()
      expect(screen.getByTestId('inject-symlink-escape-btn')).toBeInTheDocument()

      // Control 3: Oversized Write
      expect(screen.getByTestId('tamper-control-oversized-write')).toBeInTheDocument()
      expect(screen.getByTestId('inject-oversized-write-btn')).toBeInTheDocument()

      // Hash comparison table
      expect(screen.getByTestId('hash-comparison-table')).toBeInTheDocument()
      expect(screen.getByTestId('reset-adversarial-estate-btn')).toBeInTheDocument()
    })

    it('does NOT render fabricated openFds anywhere in the panel (Anti-G2 check)', () => {
      const { container } = render(
        <AdversarialSimulationPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />
      )
      expect(container.textContent).not.toContain('openFds')
      expect(screen.queryByTestId('open-fds-slot')).not.toBeInTheDocument()
    })
  })

  describe('Control 1: Cryptographic Hash Mismatch Injection & Byte-for-Byte Restore', () => {
    it('clicking Inject Hash Tamper modifies artifact hash and triggers red containment badge', async () => {
      const onTamperInjected = vi.fn()

      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          onTamperInjected={onTamperInjected}
        />
      )

      expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/intact/i)
      expect(screen.getByTestId('current-hash-value')).toHaveTextContent(
        BASELINE_EPHEMERAL_ARTIFACT.sha256
      )
      expect(screen.queryByTestId('containment-alert-hash-mismatch')).not.toBeInTheDocument()

      const injectBtn = screen.getByTestId('inject-hash-mismatch-btn')
      await act(async () => {
        fireEvent.click(injectBtn)
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-hash-mismatch')).toBeInTheDocument()
      })

      expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/tampered/i)
      expect(screen.getByTestId('containment-alert-badge-hash_mismatch')).toHaveTextContent(
        /containment alert: tamper detected/i
      )
      expect(screen.getByTestId('current-hash-value')).toHaveTextContent(CORRUPTED_SHA256)
      expect(screen.getByTestId('artifact-status-badge-artifact-demo-001')).toHaveTextContent(
        /mismatch/i
      )

      // Measured latency is rendered honestly in milliseconds
      const latencyBadge = screen.getByTestId('latency-hash-mismatch')
      expect(latencyBadge).toBeInTheDocument()
      expect(latencyBadge.textContent).toMatch(/\d+\s*ms/)

      // Payload delivered to callback
      expect(onTamperInjected).toHaveBeenCalledWith(
        expect.objectContaining({
          tamperType: 'hash_mismatch',
          originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
          tamperedSha256: CORRUPTED_SHA256,
          breachDetected: true,
          containmentTriggered: true,
        })
      )
    })

    it('clicking Restore restores the tampered artifact byte-for-byte to baseline state', async () => {
      const onTamperInjected = vi.fn()

      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          onTamperInjected={onTamperInjected}
        />
      )

      // Inject tamper first
      await act(async () => {
        fireEvent.click(screen.getByTestId('inject-hash-mismatch-btn'))
      })

      await waitFor(() => {
        expect(screen.getByTestId('restore-hash-mismatch-btn')).toBeInTheDocument()
      })

      // Click restore
      await act(async () => {
        fireEvent.click(screen.getByTestId('restore-hash-mismatch-btn'))
      })

      await waitFor(() => {
        expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/intact/i)
      })

      expect(screen.getByTestId('current-hash-value')).toHaveTextContent(
        BASELINE_EPHEMERAL_ARTIFACT.sha256
      )
      expect(screen.getByTestId('artifact-status-badge-artifact-demo-001')).toHaveTextContent(
        /match/i
      )
      expect(screen.queryByTestId('containment-alert-hash-mismatch')).not.toBeInTheDocument()

      expect(onTamperInjected).toHaveBeenLastCalledWith(
        expect.objectContaining({
          tamperType: 'hash_mismatch',
          originalSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
          tamperedSha256: BASELINE_EPHEMERAL_ARTIFACT.sha256,
          breachDetected: false,
          containmentTriggered: false,
        })
      )
    })
  })

  describe('Control 2: Symlink Escape & Anti-Traversal Rejection', () => {
    it('demonstrates descriptor-relative anti-escape rejection matching test_file_validator.py', async () => {
      const onTamperInjected = vi.fn()

      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          onTamperInjected={onTamperInjected}
        />
      )

      expect(screen.getByTestId('symlink-status-badge')).toHaveTextContent(/eligible/i)
      expect(screen.getByTestId('syscall-flags-symlink-escape')).toHaveTextContent(
        'openat2(RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV)'
      )
      expect(screen.getByTestId('bytes-read-symlink-escape')).toHaveTextContent('0 bytes read')

      const injectBtn = screen.getByTestId('inject-symlink-escape-btn')
      await act(async () => {
        fireEvent.click(injectBtn)
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-symlink-escape')).toBeInTheDocument()
      })

      expect(screen.getByTestId('symlink-status-badge')).toHaveTextContent(/blocked/i)
      expect(screen.getByTestId('containment-alert-badge-symlink_escape')).toHaveTextContent(
        /containment alert: symlink blocked/i
      )
      expect(screen.getByTestId('rejection-reason-symlink-escape')).toHaveTextContent(
        REJECTION_MESSAGES.symlink_rejected
      )

      // Measured latency is rendered honestly
      const latencyBadge = screen.getByTestId('latency-symlink-escape')
      expect(latencyBadge).toBeInTheDocument()
      expect(latencyBadge.textContent).toMatch(/\d+\s*ms/)

      // Canary assertion: 0 bytes read remains true
      expect(screen.getByTestId('bytes-read-symlink-escape')).toHaveTextContent('0 bytes read')
    })
  })

  describe('Control 3: Pre-Read Oversized Payload Rate-Limit Rejection', () => {
    it('demonstrates rate-limit rejection with exact configured 16777216 byte threshold', async () => {
      const onTamperInjected = vi.fn()

      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          onTamperInjected={onTamperInjected}
        />
      )

      expect(screen.getByTestId('oversize-status-badge')).toHaveTextContent(/under limit/i)
      expect(screen.getByTestId('threshold-oversized-write')).toHaveTextContent(
        '16,777,216 bytes (16.00 MB max)'
      )

      const injectBtn = screen.getByTestId('inject-oversized-write-btn')
      await act(async () => {
        fireEvent.click(injectBtn)
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-oversized-write')).toBeInTheDocument()
      })

      expect(screen.getByTestId('oversize-status-badge')).toHaveTextContent(/exceeded/i)
      expect(screen.getByTestId('containment-alert-badge-oversized_write')).toHaveTextContent(
        /containment alert: size limit exceeded/i
      )
      expect(screen.getByTestId('rejection-reason-oversized-write')).toHaveTextContent(
        'File size 17825792 exceeds limit 16777216 bytes'
      )
      expect(screen.getByTestId('bytes-read-oversized-write')).toHaveTextContent('0 bytes read')

      // Measured latency
      const latencyBadge = screen.getByTestId('latency-oversized-write')
      expect(latencyBadge).toBeInTheDocument()
      expect(latencyBadge.textContent).toMatch(/\d+\s*ms/)
    })
  })

  describe('State Independence & Non-Interference Proof', () => {
    it('triggering symlink escape does NOT mutate the artifact hash of hash-mismatch control', async () => {
      render(<AdversarialSimulationPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

      const originalHash = screen.getByTestId('current-hash-value').textContent
      expect(originalHash).toBe(BASELINE_EPHEMERAL_ARTIFACT.sha256)

      // Trigger Symlink Escape
      await act(async () => {
        fireEvent.click(screen.getByTestId('inject-symlink-escape-btn'))
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-symlink-escape')).toBeInTheDocument()
      })

      // Hash mismatch control must still be intact and uncorrupted!
      expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/intact/i)
      expect(screen.getByTestId('current-hash-value')).toHaveTextContent(
        BASELINE_EPHEMERAL_ARTIFACT.sha256
      )
      expect(screen.queryByTestId('containment-alert-hash-mismatch')).not.toBeInTheDocument()
      expect(screen.getByTestId('artifact-status-badge-artifact-demo-001')).toHaveTextContent(
        /match/i
      )
    })

    it('triggering oversized write does NOT mutate artifact hash or symlink rejection state', async () => {
      render(<AdversarialSimulationPanel bridge={mockBridge} preset={HAPPY_PATH_PRESET} />)

      // Trigger Oversized Write
      await act(async () => {
        fireEvent.click(screen.getByTestId('inject-oversized-write-btn'))
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-oversized-write')).toBeInTheDocument()
      })

      // Hash control and Symlink control are completely untouched
      expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/intact/i)
      expect(screen.getByTestId('symlink-status-badge')).toHaveTextContent(/eligible/i)
      expect(screen.queryByTestId('containment-alert-hash-mismatch')).not.toBeInTheDocument()
      expect(screen.queryByTestId('containment-alert-symlink-escape')).not.toBeInTheDocument()
    })
  })

  describe('Double-Click Protection & In-Flight Disablement', () => {
    it('disables injection buttons when inFlight prop is true', () => {
      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          inFlight={true}
        />
      )

      expect(screen.getByTestId('inject-hash-mismatch-btn')).toBeDisabled()
      expect(screen.getByTestId('inject-symlink-escape-btn')).toBeDisabled()
      expect(screen.getByTestId('inject-oversized-write-btn')).toBeDisabled()
      expect(screen.getByTestId('reset-adversarial-estate-btn')).toBeDisabled()
    })
  })

  describe('Reset Estate Full Lifecycle', () => {
    it('Reset All Tamper Injections restores all 3 controls to baseline intact state', async () => {
      const onReset = vi.fn()

      render(
        <AdversarialSimulationPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          onReset={onReset}
        />
      )

      // Trigger all 3
      await act(async () => {
        fireEvent.click(screen.getByTestId('inject-hash-mismatch-btn'))
        fireEvent.click(screen.getByTestId('inject-symlink-escape-btn'))
        fireEvent.click(screen.getByTestId('inject-oversized-write-btn'))
      })

      await waitFor(() => {
        expect(screen.getByTestId('containment-alert-hash-mismatch')).toBeInTheDocument()
        expect(screen.getByTestId('containment-alert-symlink-escape')).toBeInTheDocument()
        expect(screen.getByTestId('containment-alert-oversized-write')).toBeInTheDocument()
      })

      // Click Reset
      await act(async () => {
        fireEvent.click(screen.getByTestId('reset-adversarial-estate-btn'))
      })

      expect(screen.getByTestId('hash-status-badge')).toHaveTextContent(/intact/i)
      expect(screen.getByTestId('symlink-status-badge')).toHaveTextContent(/eligible/i)
      expect(screen.getByTestId('oversize-status-badge')).toHaveTextContent(/under limit/i)
      expect(screen.queryByTestId('containment-alert-hash-mismatch')).not.toBeInTheDocument()
      expect(screen.queryByTestId('containment-alert-symlink-escape')).not.toBeInTheDocument()
      expect(screen.queryByTestId('containment-alert-oversized-write')).not.toBeInTheDocument()

      expect(onReset).toHaveBeenCalled()
    })
  })
})
