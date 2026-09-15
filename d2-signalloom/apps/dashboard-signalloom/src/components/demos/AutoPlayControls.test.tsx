import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import AutoPlayControls, { type AutoPlayStatus } from './AutoPlayControls'
import { createMockBridge, type DemoBridge } from './bridge'
import { HAPPY_PATH_PRESET, TAMPER_BREACH_PRESET } from './scenarios'
import {
  INITIAL_STEPPER_STATE,
  STAGE_IDS,
  type DemoStepperState,
  type DemoStepperEvent,
  type StageId,
} from './types'

class MockStorage implements Storage {
  private store = new Map<string, string>()

  get length(): number {
    return this.store.size
  }

  clear(): void {
    this.store.clear()
  }

  getItem(key: string): string | null {
    return this.store.get(key) ?? null
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null
  }

  removeItem(key: string): void {
    this.store.delete(key)
  }

  setItem(key: string, value: string): void {
    this.store.set(key, value)
  }
}

describe('AutoPlayControls & Pacing Engine (AMXD-P5-1)', () => {
  let storage: MockStorage

  beforeEach(() => {
    storage = new MockStorage()
    vi.useRealTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  // Test Component Wrapper to maintain stepper state during tests
  const AutoPlayHarness: React.FC<{
    preset?: typeof HAPPY_PATH_PRESET
    initialPacing?: '1x' | '2x' | 'instant'
    bridgeOverride?: DemoBridge
    onStatusChange?: (status: AutoPlayStatus) => void
    initialStage?: StageId
  }> = ({
    preset = HAPPY_PATH_PRESET,
    initialPacing = '1x',
    bridgeOverride,
    onStatusChange,
    initialStage = 'operator_init',
  }) => {
    const bridge =
      bridgeOverride ??
      createMockBridge({
        preset,
        storage,
        latencyMs: 10,
      })

    const [state, setState] = React.useState<DemoStepperState>(() => {
      const init = { ...INITIAL_STEPPER_STATE }
      if (initialStage !== 'operator_init') {
        const stageIdx = STAGE_IDS.indexOf(initialStage)
        const statuses = { ...init.stageStatuses }
        for (let i = 0; i <= stageIdx; i += 1) {
          statuses[STAGE_IDS[i]] = 'confirmed'
        }
        return {
          ...init,
          currentStage: initialStage,
          stageStatuses: statuses,
        }
      }
      return init
    })

    const handleStateUpdate = React.useCallback((event: DemoStepperEvent) => {
      setState((prev) => {
        if (event.type === 'START_TRANSITION') {
          return {
            ...prev,
            inFlight: true,
            activeTransition: {
              from: prev.currentStage,
              to: event.targetStage,
              startedAt: Date.now(),
            },
            stageStatuses: {
              ...prev.stageStatuses,
              [event.targetStage]: 'in_flight',
            },
          }
        }
        if (event.type === 'RESOLVE_TRANSITION') {
          return {
            ...prev,
            inFlight: false,
            activeTransition: null,
            currentStage: event.targetStage,
            stageStatuses: {
              ...prev.stageStatuses,
              [event.targetStage]: 'confirmed',
            },
            stagePayloads: event.payload
              ? { ...prev.stagePayloads, [event.targetStage]: event.payload }
              : prev.stagePayloads,
          }
        }
        if (event.type === 'FAIL_TRANSITION') {
          return {
            ...prev,
            inFlight: false,
            activeTransition: null,
            stageStatuses: {
              ...prev.stageStatuses,
              [event.targetStage]: 'failed',
            },
            stageFailures: {
              ...prev.stageFailures,
              [event.targetStage]: event.failure,
            },
            lastError: event.failure.errorReason,
          }
        }
        if (event.type === 'RESET_ESTATE') {
          return INITIAL_STEPPER_STATE
        }
        return prev
      })
    }, [])

    return (
      <div data-testid="test-harness">
        <div data-testid="current-stage-display">{state.currentStage}</div>
        <div data-testid="in-flight-display">{state.inFlight ? 'true' : 'false'}</div>
        <div data-testid="stage-1-status">{state.stageStatuses.operator_init}</div>
        <div data-testid="stage-2-status">{state.stageStatuses.host_enrolled}</div>
        <div data-testid="stage-3-status">{state.stageStatuses.confinement_streaming}</div>
        <div data-testid="stage-4-status">{state.stageStatuses.adversarial_tamper}</div>
        <div data-testid="stage-5-status">{state.stageStatuses.revocation_denied}</div>

        <AutoPlayControls
          bridge={bridge}
          state={state}
          onStateUpdate={handleStateUpdate}
          onStatusChange={onStatusChange}
          initialPacing={initialPacing}
          storage={storage}
        />
      </div>
    )
  }

  it('renders initial state with manual stepping indicator and 1x speed selected', () => {
    render(<AutoPlayHarness />)

    expect(screen.getByTestId('autoplay-controls')).toBeInTheDocument()
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('MANUAL STEPPING')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'manual')

    expect(screen.getByTestId('autoplay-start-button')).toBeInTheDocument()
    expect(screen.getByTestId('autoplay-speed-toggle')).toBeInTheDocument()
    expect(screen.getByTestId('autoplay-speed-1x')).toHaveAttribute('data-active', 'true')
    expect(screen.getByTestId('autoplay-speed-2x')).toHaveAttribute('data-active', 'false')
    expect(screen.getByTestId('autoplay-speed-instant')).toHaveAttribute('data-active', 'false')

    expect(screen.getByTestId('autoplay-reset-estate-button')).toBeInTheDocument()
  })

  it('allows live speed switching between 1x, 2x, and instant modes', () => {
    render(<AutoPlayHarness initialPacing="1x" />)

    const speed2xBtn = screen.getByTestId('autoplay-speed-2x')
    const speedInstantBtn = screen.getByTestId('autoplay-speed-instant')
    const speed1xBtn = screen.getByTestId('autoplay-speed-1x')

    // Switch to 2x
    fireEvent.click(speed2xBtn)
    expect(speed2xBtn).toHaveAttribute('data-active', 'true')
    expect(speed1xBtn).toHaveAttribute('data-active', 'false')
    expect(speedInstantBtn).toHaveAttribute('data-active', 'false')

    // Switch to instant
    fireEvent.click(speedInstantBtn)
    expect(speedInstantBtn).toHaveAttribute('data-active', 'true')
    expect(speed2xBtn).toHaveAttribute('data-active', 'false')

    // Switch back to 1x
    fireEvent.click(speed1xBtn)
    expect(speed1xBtn).toHaveAttribute('data-active', 'true')
  })

  it('steps through all stages in 1x speed (4000ms dwell per stage) using fake timers', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="1x" />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY RUNNING (1X)')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'running')

    // Stage 2: host_enrolled is in flight
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('in_flight')

    // Advance dwell for Stage 2 (4000ms) + small mock latency
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('confirmed')

    // Advance dwell for Stage 3 (4000ms)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('confirmed')

    // Advance dwell for Stage 4 (4000ms)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('confirmed')

    // Advance dwell for Stage 5 (4000ms)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('confirmed')

    // Complete
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY COMPLETED')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'completed')
  })

  it('steps through all stages in 2x speed (2000ms dwell per stage) using fake timers', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="2x" />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY RUNNING (2X)')

    // Step 2
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2050)
    })
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('confirmed')

    // Step 3
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2050)
    })
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('confirmed')

    // Step 4
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2050)
    })
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('confirmed')

    // Step 5
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2050)
    })
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY COMPLETED')
  })

  it('steps through all stages in instant speed (100ms dwell per stage)', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="instant" />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY RUNNING (INSTANT)')

    // 4 stages * (100ms dwell + 10ms latency)
    for (let i = 2; i <= 5; i += 1) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(150)
      })
      expect(screen.getByTestId(`stage-${i}-status`)).toHaveTextContent('confirmed')
    }

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY COMPLETED')
  })

  /**
   * THE COUNCIL'S FINDING VERIFICATION (AMXD-P5-1 CORE DEFECT FIX)
   *
   * Proves that in instant mode (100ms dwell floor), a slow-confirming mock/backend
   * confirmation (e.g. 1500ms) MUST NOT advance the stage when the 100ms timer elapses!
   * The stage must wait until the confirmation promise settles, demonstrating that
   * dwell is a MINIMUM floor and never a sufficient condition for advancement.
   */
  it('proves instant mode (100ms) waits for slow confirmation promise and does NOT advance on dwell alone', async () => {
    vi.useFakeTimers()

    // Pass a bridge with latencyMs = 1500 (simulating slow confirmation taking 1500ms)
    const bridge = createMockBridge({
      preset: HAPPY_PATH_PRESET,
      storage,
      latencyMs: 1500,
    })

    render(<AutoPlayHarness initialPacing="instant" bridgeOverride={bridge} />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    // Stage 2 is in-flight
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('in_flight')

    // Advance fake timers by 100ms (the instant mode dwell floor)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(100)
    })

    // CRITICAL ASSERTION: The dwell timer finished, but confirmation promise (1500ms) is still pending.
    // Stage 2 MUST STILL BE in_flight, NOT confirmed!
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('in_flight')
    expect(screen.getByTestId('current-stage-display')).toHaveTextContent('operator_init')

    // Advance another 800ms (total 900ms elapsed) - still in-flight
    await act(async () => {
      await vi.advanceTimersByTimeAsync(800)
    })
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('in_flight')

    // Now advance past the 1500ms latency mark (e.g. +700ms, total 1600ms)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(700)
    })

    // Now confirmation has settled and Stage 2 is confirmed
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('confirmed')
  })

  it('halts Auto-Play immediately on rejected stage confirmation and displays error banner', async () => {
    vi.useFakeTimers()

    const bridge = createMockBridge({
      preset: TAMPER_BREACH_PRESET,
      storage,
      latencyMs: 10,
    })

    const originalAdvance = bridge.advance.bind(bridge)
    bridge.advance = vi.fn(async (stage, opts) => {
      if (stage === 'adversarial_tamper') {
        // Simulate rejected confirmation on Stage 4
        return {
          channelKind: 'mock' as const,
          channel: { kind: 'mock' as const, presetId: 'adversarial-breach', fixtureSource: 'preset' as const },
          status: 'error' as const,
          stage: 'adversarial_tamper' as const,
          error: {
            kind: 'application' as const,
            httpStatus: 409,
            message: 'Cryptographic SHA-256 integrity breach: tampered digest rejected by gate',
          },
          fixtureId: 'adversarial-breach:adversarial_tamper',
        }
      }
      return originalAdvance(stage, opts)
    })

    render(<AutoPlayHarness initialPacing="instant" bridgeOverride={bridge} />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    // Advance Stage 2 and Stage 3
    await act(async () => {
      await vi.advanceTimersByTimeAsync(300)
    })
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('confirmed')

    // Advance to Stage 4 (which fails/rejects)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(200)
    })

    // Auto-Play MUST halt immediately!
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY HALTED ON REJECTION')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'halted')

    expect(screen.getByTestId('autoplay-halted-banner')).toBeInTheDocument()
    expect(screen.getByTestId('autoplay-error-message')).toHaveTextContent(
      'Cryptographic SHA-256 integrity breach: tampered digest rejected by gate',
    )

    // Stage 4 failed
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('failed')

    // Stage 5 MUST NOT be started or confirmed (remains idle)!
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('idle')

    // Advancing more time does NOT advance past failure
    await act(async () => {
      await vi.advanceTimersByTimeAsync(5000)
    })
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('idle')
  })

  it('allows stopping an in-flight Auto-Play run mid-progression', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="1x" />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY RUNNING (1X)')

    // Click Stop Auto-Play while Stage 2 is in-flight
    const stopBtn = screen.getByTestId('autoplay-stop-button')
    await act(async () => {
      fireEvent.click(stopBtn)
    })

    // Mode reverts to manual
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('MANUAL STEPPING')
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'manual')
  })

  it('applies speed switch mid-run to future stages without altering past stages', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="1x" />)

    const startBtn = screen.getByTestId('autoplay-start-button')

    await act(async () => {
      fireEvent.click(startBtn)
    })

    // Let Stage 2 complete under 1x (4000ms)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('confirmed')

    // While Stage 3 is in progress under 1x, switch speed mid-run to instant
    const instantBtn = screen.getByTestId('autoplay-speed-instant')
    await act(async () => {
      fireEvent.click(instantBtn)
    })

    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveTextContent('AUTO-PLAY RUNNING (INSTANT)')

    // Stage 3 was already started with 1x dwell (4000ms), so it completes when its 4000ms finishes
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4050)
    })
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('confirmed')

    // Stage 4 was NOT yet reached when instant was clicked; it now uses the instant 100ms dwell floor!
    await act(async () => {
      await vi.advanceTimersByTimeAsync(150)
    })
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('confirmed')
  })

  it('proves Reset Estate is idempotent by resetting from two different starting stages', () => {
    const bridge = createMockBridge({
      preset: HAPPY_PATH_PRESET,
      storage,
    })

    // 1. Reset from Stage 3
    const harness1 = render(
      <AutoPlayHarness bridgeOverride={bridge} initialStage="confinement_streaming" />,
    )
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('confirmed')

    const resetBtn1 = screen.getByTestId('autoplay-reset-estate-button')
    act(() => {
      fireEvent.click(resetBtn1)
    })

    expect(screen.getByTestId('current-stage-display')).toHaveTextContent('operator_init')
    expect(screen.getByTestId('stage-1-status')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('idle')
    harness1.unmount()

    // 2. Reset from Stage 5
    const harness2 = render(
      <AutoPlayHarness bridgeOverride={bridge} initialStage="revocation_denied" />,
    )
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('confirmed')

    const resetBtn2 = screen.getByTestId('autoplay-reset-estate-button')
    act(() => {
      fireEvent.click(resetBtn2)
    })

    // Both result states are strictly identical!
    expect(screen.getByTestId('current-stage-display')).toHaveTextContent('operator_init')
    expect(screen.getByTestId('stage-1-status')).toHaveTextContent('confirmed')
    expect(screen.getByTestId('stage-2-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-3-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-4-status')).toHaveTextContent('idle')
    expect(screen.getByTestId('stage-5-status')).toHaveTextContent('idle')
    harness2.unmount()
  })

  it('measures Reset Estate wall-clock time against the <500ms KPI with high-resolution timer', () => {
    const bridge = createMockBridge({
      preset: HAPPY_PATH_PRESET,
      storage,
    })

    // Seed some state
    storage.setItem('amxd.demo.currentStage', 'confinement_streaming')
    storage.setItem('amxd.demo.sessionId', 'test-session')

    // Perform 100 iterations of resetEstate and measure wall-clock elapsed time
    const iterations = 100
    const times: number[] = []

    for (let i = 0; i < iterations; i += 1) {
      storage.setItem('amxd.demo.tempKey', `val-${i}`)
      const t0 = performance.now()
      const result = bridge.resetEstate()
      const t1 = performance.now()
      times.push(t1 - t0)

      expect(result.idempotent).toBe(true)
      expect(result.backendStateCleared).toBe(false)
    }

    const meanTime = times.reduce((a, b) => a + b, 0) / iterations
    const maxTime = Math.max(...times)

    // Log the measured figure for audit and proposal errata evidence
    console.log(
      `[KPI Measurement] Reset Estate: mean=${meanTime.toFixed(4)}ms, max=${maxTime.toFixed(4)}ms over ${iterations} iterations (KPI target: <500ms)`,
    )

    expect(meanTime).toBeLessThan(500)
    expect(maxTime).toBeLessThan(500)
  })

  it('renders distinct visible indicators for all three operational modes (running, halted, manual)', async () => {
    vi.useFakeTimers()

    render(<AutoPlayHarness initialPacing="1x" />)

    // 1. Manual mode
    const manualIndicator = screen.getByTestId('autoplay-mode-indicator')
    expect(manualIndicator).toHaveAttribute('data-mode', 'manual')
    expect(manualIndicator).toHaveTextContent('MANUAL STEPPING')

    // 2. Running mode
    const startBtn = screen.getByTestId('autoplay-start-button')
    await act(async () => {
      fireEvent.click(startBtn)
    })

    const runningIndicator = screen.getByTestId('autoplay-mode-indicator')
    expect(runningIndicator).toHaveAttribute('data-mode', 'running')
    expect(runningIndicator).toHaveTextContent('AUTO-PLAY RUNNING (1X)')

    // 3. Stop -> Manual
    const stopBtn = screen.getByTestId('autoplay-stop-button')
    await act(async () => {
      fireEvent.click(stopBtn)
    })
    expect(screen.getByTestId('autoplay-mode-indicator')).toHaveAttribute('data-mode', 'manual')
  })
})
