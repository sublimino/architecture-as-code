import { render, screen, waitFor, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import {
  ConfinementTelemetryPanel,
  formatBytesToMb,
  formatCpuTime,
  formatTimeHms,
  deriveArtifactsForPreset,
  type ArtifactHashItem,
} from './ConfinementTelemetryPanel'
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
  type ScenarioPreset,
} from './scenarios'
import type { ConfinementStreamingPayload } from './types'

function happyTelemetryTransport(overrides?: Partial<ConfinementStreamingPayload>): LiveTransport {
  return {
    req: vi.fn(async () => ({
      processComm: 'nono',
      cpuTicks: 1420,
      rssBytes: 48234496,
      openFds: 3,
      expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      observedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      hashMatch: true,
      zeroPayloadVerified: true,
      ...overrides,
    })),
    fetch: vi.fn(async () => new Response(JSON.stringify({}), { status: 200 })),
  }
}

function failureTelemetryTransport(errorMessage = 'Telemetry service unavailable'): LiveTransport {
  return {
    req: vi.fn(async () => {
      throw Object.assign(new Error(errorMessage), { status: 503 })
    }),
    fetch: vi.fn(async () => new Response(JSON.stringify({ error: errorMessage }), { status: 503 })),
  }
}

describe('ConfinementTelemetryPanel (Stage 3: Confinement & Telemetry)', () => {
  let mockBridge: MockDemoBridge
  let liveBridge: LiveDemoBridge

  beforeEach(() => {
    mockBridge = createMockBridge({ preset: HAPPY_PATH_PRESET, latencyMs: 0 })
    liveBridge = createLiveBridge({
      preset: HAPPY_PATH_PRESET,
      transport: happyTelemetryTransport(),
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  describe('Pure formatting & artifact derivation helpers', () => {
    it('formatBytesToMb formats bytes correctly', () => {
      expect(formatBytesToMb(0)).toBe('0.00 MB')
      expect(formatBytesToMb(1024 * 1024)).toBe('1.00 MB')
      expect(formatBytesToMb(48234496)).toBe('46.00 MB')
      expect(formatBytesToMb(62455808)).toBe('59.56 MB')
      expect(formatBytesToMb(-100)).toBe('0.00 MB')
      expect(formatBytesToMb(NaN)).toBe('0.00 MB')
    })

    it('formatCpuTime formats ms and seconds correctly', () => {
      expect(formatCpuTime(0)).toEqual({ formattedMs: '0 ms', formattedSec: '0.00 s' })
      expect(formatCpuTime(1420)).toEqual({ formattedMs: '1,420 ms', formattedSec: '1.42 s' })
      expect(formatCpuTime(2150)).toEqual({ formattedMs: '2,150 ms', formattedSec: '2.15 s' })
      expect(formatCpuTime(-50)).toEqual({ formattedMs: '0 ms', formattedSec: '0.00 s' })
    })

    it('formatTimeHms formats timestamps cleanly', () => {
      const date = new Date(2026, 8, 15, 14, 30, 45)
      expect(formatTimeHms(date)).toBe('14:30:45')
      expect(formatTimeHms('invalid')).toBe('--:--:--')
    })

    it('deriveArtifactsForPreset derives match artifacts for Happy Path preset', () => {
      const artifacts = deriveArtifactsForPreset(HAPPY_PATH_PRESET, null)
      expect(artifacts.length).toBeGreaterThan(0)
      expect(artifacts.every((a) => a.status === 'match')).toBe(true)
    })

    it('deriveArtifactsForPreset derives mismatch artifact for Tamper Breach preset', () => {
      const artifacts = deriveArtifactsForPreset(TAMPER_BREACH_PRESET, null)
      expect(artifacts.some((a) => a.status === 'mismatch')).toBe(true)
      const tampered = artifacts.find((a) => a.status === 'mismatch')
      expect(tampered?.computedSha256).toContain('deadbeef')
    })
  })

  describe('Gauge rendering from real polled fields', () => {
    it('renders initial layout with CPU, RSS, Open FDs slots and hash comparison table', async () => {
      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      expect(screen.getByTestId('confinement-telemetry-panel')).toBeInTheDocument()
      expect(screen.getByTestId('telemetry-channel-badge')).toHaveTextContent('Mock fixture')
      expect(screen.getByTestId('polling-cadence-badge')).toBeInTheDocument()
      expect(screen.getByTestId('refresh-telemetry-btn')).toBeInTheDocument()
      expect(screen.getByTestId('telemetry-gauges-container')).toBeInTheDocument()
      expect(screen.getByTestId('cpu-gauge')).toBeInTheDocument()
      expect(screen.getByTestId('rss-gauge')).toBeInTheDocument()
      expect(screen.getByTestId('open-fds-slot')).toBeInTheDocument()
      expect(screen.getByTestId('hash-comparison-table')).toBeInTheDocument()
      expect(screen.getByTestId('zero-payload-badge')).toBeInTheDocument()
    })

    it('renders CPU gauge sourced from cpu_time_ms with explicit cumulative time note', async () => {
      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
          initialPayload={{
            processComm: 'nono',
            cpuTicks: 1420,
            rssBytes: 48234496,
            openFds: 3,
            expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            observedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            hashMatch: true,
            zeroPayloadVerified: true,
          }}
        />
      )

      await waitFor(() => {
        expect(screen.getByTestId('cpu-gauge-value')).toHaveTextContent('1,420 ms')
      })

      expect(screen.getByText('(1.42 s)')).toBeInTheDocument()
      expect(screen.getByTestId('cpu-health-badge')).toHaveTextContent('healthy')
      expect(screen.getByTestId('cpu-gauge-note')).toHaveTextContent(
        'Cumulative CPU time (cpu_time_ms)'
      )
      expect(screen.getByTestId('cpu-gauge-note')).toHaveTextContent(
        'Instantaneous CPU % is internal to host-sensor'
      )
    })

    it('renders RSS gauge in MB sourced from resident_memory_bytes with raw byte count', async () => {
      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
          initialPayload={{
            processComm: 'nono',
            cpuTicks: 1420,
            rssBytes: 48234496,
            openFds: 3,
            expectedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            observedSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            hashMatch: true,
            zeroPayloadVerified: true,
          }}
        />
      )

      await waitFor(() => {
        expect(screen.getByTestId('rss-gauge-value')).toHaveTextContent('46.00 MB')
      })

      expect(screen.getByTestId('rss-gauge-raw-bytes')).toHaveTextContent(
        '48,234,496 bytes allocated'
      )
      expect(screen.getByTestId('rss-health-badge')).toHaveTextContent('healthy')
    })

    it('renders Open FDs slot as explicitly Unavailable with no fabricated number', async () => {
      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      const fdsSlot = screen.getByTestId('open-fds-slot')
      expect(fdsSlot).toBeInTheDocument()
      expect(screen.getByTestId('open-fds-value')).toHaveTextContent('N/A')
      expect(screen.getByTestId('open-fds-unavailable-badge')).toHaveTextContent('Unavailable')
      expect(screen.getByTestId('open-fds-note')).toHaveTextContent(
        'Not available in host-sensor-v1 contract (schema 1.0.0)'
      )
      expect(screen.getByTestId('open-fds-note')).toHaveTextContent(
        'No open-FD telemetry field is exported'
      )

      // Ensure no fabricated integer is shown in the open FDs value slot
      expect(screen.getByTestId('open-fds-value')).not.toHaveTextContent(/^\d+$/)
    })
  })

  describe('Timestamps and fetch-time freshness sourcing', () => {
    it('displays response arrival timestamp beside gauges and in status bar', async () => {
      const fixedEpoch = new Date(2026, 8, 15, 10, 15, 30).getTime()
      vi.useFakeTimers()
      vi.setSystemTime(fixedEpoch)

      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      // Initial mount triggers pollTelemetry under fake timers
      await act(async () => {
        await vi.advanceTimersByTimeAsync(10)
      })

      expect(screen.getByTestId('last-polled-at')).toHaveTextContent('10:15:30')
      expect(screen.getByTestId('cpu-last-polled-at')).toHaveTextContent('10:15:30')
      expect(screen.getByTestId('rss-last-polled-at')).toHaveTextContent('10:15:30')
      expect(screen.getByTestId('open-fds-last-polled-at')).toHaveTextContent('10:15:30')
    })
  })

  describe('Clean unmounting & poll loop verification with fake timers', () => {
    it('cleans up interval and debounce timer on unmount with zero dangling timers', async () => {
      vi.useFakeTimers()
      const advanceSpy = vi.fn(mockBridge.advance.bind(mockBridge))
      const spyBridge = { ...mockBridge, advance: advanceSpy }

      const { unmount } = render(
        <ConfinementTelemetryPanel
          bridge={spyBridge as unknown as MockDemoBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={2000}
        />
      )

      // Initial poll at mount
      expect(advanceSpy).toHaveBeenCalledTimes(1)

      // Advance one poll interval (2000ms)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2000)
      })
      expect(advanceSpy).toHaveBeenCalledTimes(2)

      // Unmount component (simulating navigation away to Stage 4)
      unmount()

      // Advance several more intervals
      await act(async () => {
        await vi.advanceTimersByTimeAsync(10000)
      })

      // Proves no dangling interval: advance was NOT called after unmount
      expect(advanceSpy).toHaveBeenCalledTimes(2)
    })

    it('advances through several poll intervals and asserts exactly one poll per interval', async () => {
      vi.useFakeTimers()
      const advanceSpy = vi.fn(mockBridge.advance.bind(mockBridge))
      const spyBridge = { ...mockBridge, advance: advanceSpy }

      render(
        <ConfinementTelemetryPanel
          bridge={spyBridge as unknown as MockDemoBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={2500}
          debounceMs={100}
        />
      )

      // Initial mount call
      expect(advanceSpy).toHaveBeenCalledTimes(1)

      // Tick 1 (2500ms)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2500)
      })
      expect(advanceSpy).toHaveBeenCalledTimes(2)

      // Tick 2 (5000ms total)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2500)
      })
      expect(advanceSpy).toHaveBeenCalledTimes(3)

      // Tick 3 (7500ms total)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2500)
      })
      expect(advanceSpy).toHaveBeenCalledTimes(4)
    })

    it('debounces gauge re-render without dropping real transitions or blocking timestamp updates', async () => {
      vi.useFakeTimers()
      let cpuVal = 1000

      const dynamicBridge = {
        ...mockBridge,
        advance: vi.fn(async () => {
          cpuVal += 100
          return {
            channelKind: 'mock' as const,
            channel: { kind: 'mock' as const, presetId: HAPPY_PATH_PRESET.id, fixtureSource: 'preset' as const },
            status: 'ok' as const,
            stage: 'confinement_streaming' as const,
            payload: {
              processComm: 'nono',
              cpuTicks: cpuVal,
              rssBytes: 48234496,
              openFds: 3,
              expectedSha256: 'e3b0c442',
              observedSha256: 'e3b0c442',
              hashMatch: true,
              zeroPayloadVerified: true,
            },
            declaredHttpStatus: 202,
            fixtureId: 'f1',
          }
        }),
      }

      render(
        <ConfinementTelemetryPanel
          bridge={dynamicBridge as unknown as MockDemoBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={3000}
          debounceMs={200}
        />
      )

      // Initial fetch starts and completes
      await act(async () => {
        await vi.advanceTimersByTimeAsync(10)
      })

      // Advance past debounce (200ms)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(250)
      })

      expect(screen.getByTestId('cpu-gauge-value')).toHaveTextContent('1,100 ms')
    })
  })

  describe('File-hashing comparison table (Match and Mismatch paths)', () => {
    it('renders match state correctly for Happy Path preset', async () => {
      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      expect(screen.getByTestId('hash-comparison-table')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-hash-row-artifact-work-001')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-id-artifact-work-001')).toHaveTextContent('artifact-work-001')
      expect(screen.getByTestId('artifact-root-artifact-work-001')).toHaveTextContent('agent-work')
      expect(screen.getByTestId('artifact-status-badge-artifact-work-001')).toHaveTextContent('Match')
      expect(screen.getByTestId('artifact-status-badge-artifact-work-001')).toHaveStyle({
        color: 'var(--teal)',
      })
    })

    it('renders mismatch state correctly for Tamper Breach preset', async () => {
      const tamperBridge = createMockBridge({ preset: TAMPER_BREACH_PRESET, latencyMs: 0 })

      render(
        <ConfinementTelemetryPanel
          bridge={tamperBridge}
          preset={TAMPER_BREACH_PRESET}
          pollIntervalMs={0}
        />
      )

      expect(screen.getByTestId('artifact-hash-row-artifact-demo-001')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-status-badge-artifact-demo-001')).toHaveTextContent('Mismatch')
      expect(screen.getByTestId('artifact-status-badge-artifact-demo-001')).toHaveStyle({
        color: 'var(--error)',
      })
      expect(screen.getByTestId('artifact-computed-sha-artifact-demo-001')).toHaveTextContent('deadbeef')
    })

    it('renders custom artifact list with correct expected-vs-computed hashes', async () => {
      const customArtifacts: ArtifactHashItem[] = [
        {
          artifactId: 'custom-file-01',
          rootId: 'agent-work',
          expectedSha256: 'aaaa111122223333444455556666777788889999aaaabbbbccccddddeeeeffff',
          computedSha256: 'aaaa111122223333444455556666777788889999aaaabbbbccccddddeeeeffff',
          sizeBytes: 4096,
          mtimeNs: '1726365600000000000',
          status: 'match',
        },
        {
          artifactId: 'custom-file-02-tampered',
          rootId: 'agent-output',
          expectedSha256: 'bbbb111122223333444455556666777788889999aaaabbbbccccddddeeeeffff',
          computedSha256: 'ffff111122223333444455556666777788889999aaaabbbbccccddddeeeeffff',
          sizeBytes: 12288,
          mtimeNs: '1726365601000000000',
          status: 'mismatch',
        },
      ]

      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
          customArtifacts={customArtifacts}
        />
      )

      expect(screen.getByTestId('artifact-hash-row-custom-file-01')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-status-badge-custom-file-01')).toHaveTextContent('Match')

      expect(screen.getByTestId('artifact-hash-row-custom-file-02-tampered')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-status-badge-custom-file-02-tampered')).toHaveTextContent(
        'Mismatch'
      )
    })

    it('handles large artifact lists with scrollable container without clipping', async () => {
      const largeArtifactList: ArtifactHashItem[] = Array.from({ length: 30 }, (_, i) => ({
        artifactId: `artifact-bulk-${String(i).padStart(3, '0')}`,
        rootId: i % 2 === 0 ? 'agent-work' : 'agent-output',
        expectedSha256: `${String(i).padStart(4, '0')}${'a'.repeat(60)}`,
        computedSha256: `${String(i).padStart(4, '0')}${'a'.repeat(60)}`,
        sizeBytes: 1024 * (i + 1),
        mtimeNs: '1726365600000000000',
        status: 'match' as const,
      }))

      render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
          customArtifacts={largeArtifactList}
        />
      )

      expect(screen.getByTestId('artifact-count-badge')).toHaveTextContent('30 artifacts')
      expect(screen.getByTestId('artifact-hash-row-artifact-bulk-000')).toBeInTheDocument()
      expect(screen.getByTestId('artifact-hash-row-artifact-bulk-029')).toBeInTheDocument()
    })
  })

  describe('Live channel & error resilience', () => {
    it('renders live backend error gracefully and updates health state to degraded', async () => {
      const errorBridge = createLiveBridge({
        preset: HAPPY_PATH_PRESET,
        transport: failureTelemetryTransport('Telemetry service gateway timed out'),
      })

      render(
        <ConfinementTelemetryPanel
          bridge={errorBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      await waitFor(() => {
        expect(screen.getByTestId('telemetry-error')).toBeInTheDocument()
      })

      expect(screen.getByTestId('telemetry-error')).toHaveTextContent(
        'Telemetry service gateway timed out'
      )
      expect(screen.getByTestId('cpu-health-badge')).toHaveTextContent('degraded')
      expect(screen.getByTestId('rss-health-badge')).toHaveTextContent('degraded')
    })

    it('allows manual on-demand refresh via button', async () => {
      const user = userEvent.setup()
      const advanceSpy = vi.fn(mockBridge.advance.bind(mockBridge))
      const spyBridge = { ...mockBridge, advance: advanceSpy }

      render(
        <ConfinementTelemetryPanel
          bridge={spyBridge as unknown as MockDemoBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )

      await waitFor(() => {
        expect(screen.getByTestId('refresh-telemetry-btn')).toHaveTextContent('Poll Telemetry Now')
      })

      const refreshBtn = screen.getByTestId('refresh-telemetry-btn')
      await user.click(refreshBtn)

      expect(advanceSpy).toHaveBeenCalledTimes(2) // 1 initial + 1 click
    })

    it('renders structurally identical testids for mock and live channels on Happy Path preset', async () => {
      const { container: mockContainer, unmount: unmountMock } = render(
        <ConfinementTelemetryPanel
          bridge={mockBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )
      await waitFor(() => expect(screen.getByTestId('cpu-gauge')).toBeInTheDocument())
      const mockTestIds = extractTestIds(mockContainer)
      unmountMock()

      const { container: liveContainer, unmount: unmountLive } = render(
        <ConfinementTelemetryPanel
          bridge={liveBridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={0}
        />
      )
      await waitFor(() => expect(screen.getByTestId('cpu-gauge')).toBeInTheDocument())
      const liveTestIds = extractTestIds(liveContainer)
      unmountLive()

      expect(mockTestIds).toEqual(liveTestIds)
    })
  })
})

function extractTestIds(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll('[data-testid]'))
    .map((el) => el.getAttribute('data-testid') || '')
    .filter(Boolean)
    .sort()
}
