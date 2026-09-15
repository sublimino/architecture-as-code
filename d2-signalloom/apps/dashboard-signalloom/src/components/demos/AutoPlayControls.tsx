import React, {
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import {
  AUTO_PLAY_DWELL_MS,
  STAGE_IDS,
  STAGE_METADATA,
  getStageIndex,
  type AutoPlayPacing,
  type DemoStepperEvent,
  type DemoStepperState,
  type StageFailurePayload,
  type StageId,
} from './types'
import type { DemoBridge } from './bridge'

export type AutoPlayStatus = 'manual' | 'running' | 'halted' | 'completed'

export interface AutoPlayControlsProps {
  readonly bridge: DemoBridge
  readonly state: DemoStepperState
  readonly onStateUpdate?: (event: DemoStepperEvent) => void
  readonly onStageChange?: (stage: StageId, state: DemoStepperState) => void
  readonly onReset?: () => void
  readonly onStatusChange?: (status: AutoPlayStatus) => void
  readonly initialPacing?: AutoPlayPacing
  readonly disabled?: boolean
  readonly storage?: Storage | null
  readonly className?: string
}

export const AutoPlayControls: React.FC<AutoPlayControlsProps> = ({
  bridge,
  state,
  onStateUpdate,
  onStageChange,
  onReset,
  onStatusChange,
  initialPacing = '1x',
  disabled = false,
  storage,
  className = '',
}) => {
  const [status, setStatus] = useState<AutoPlayStatus>('manual')
  const [pacing, setPacing] = useState<AutoPlayPacing>(initialPacing)
  const [haltReason, setHaltReason] = useState<string | null>(null)
  const [haltedStage, setHaltedStage] = useState<StageId | null>(null)

  // Live-switchable speed toggle: pacingRef is updated synchronously so any future stage
  // transition reads the latest dwell without altering already-confirmed stages.
  const pacingRef = useRef<AutoPlayPacing>(pacing)
  pacingRef.current = pacing

  // Active state ref to read latest stepper state inside async loops
  const stateRef = useRef<DemoStepperState>(state)
  stateRef.current = state

  // Abort controller ref for in-flight auto-play cancellation
  const abortControllerRef = useRef<AbortController | null>(null)

  // Status ref to prevent race conditions during async stepping
  const isRunningRef = useRef<boolean>(false)

  const updateStatus = useCallback(
    (newStatus: AutoPlayStatus) => {
      isRunningRef.current = newStatus === 'running'
      setStatus(newStatus)
      onStatusChange?.(newStatus)
    },
    [onStatusChange],
  )

  // Stop / abort auto-play
  const stopAutoPlay = useCallback(() => {
    if (abortControllerRef.current) {
      abortControllerRef.current.abort()
      abortControllerRef.current = null
    }
    updateStatus('manual')
  }, [updateStatus])

  // Single stage step execution through dual-lock async gate
  const executeStageStep = useCallback(
    async (
      targetStage: StageId,
      signal: AbortSignal,
    ): Promise<{ success: boolean; aborted?: boolean; error?: string }> => {
      const currentDwellMs = AUTO_PLAY_DWELL_MS[pacingRef.current]

      onStateUpdate?.({
        type: 'START_TRANSITION',
        targetStage,
      })

      try {
        const outcome = await bridge.advance(targetStage, {
          dwellMs: currentDwellMs,
          signal,
        })

        if (signal.aborted) {
          return { success: false, aborted: true }
        }

        if (outcome.status === 'ok') {
          onStateUpdate?.({
            type: 'RESOLVE_TRANSITION',
            targetStage,
            payload: outcome.payload,
          })

          try {
            storage?.setItem('amxd.demo.currentStage', targetStage)
          } catch {
            /* storage write error ignored */
          }

          onStageChange?.(targetStage, stateRef.current)
          return { success: true }
        }

        // Bridge returned failure / rejection
        const isAborted = outcome.error.kind === 'aborted'
        if (isAborted) {
          return { success: false, aborted: true }
        }

        const failurePayload: StageFailurePayload = {
          stage: targetStage,
          errorReason: outcome.error.message,
          failedAt: new Date().toISOString(),
          recoverable: true,
        }

        onStateUpdate?.({
          type: 'FAIL_TRANSITION',
          targetStage,
          failure: failurePayload,
        })

        return {
          success: false,
          error: outcome.error.message,
        }
      } catch (err: unknown) {
        if (signal.aborted) {
          return { success: false, aborted: true }
        }

        const msg = err instanceof Error ? err.message : String(err)
        const failurePayload: StageFailurePayload = {
          stage: targetStage,
          errorReason: msg,
          failedAt: new Date().toISOString(),
          recoverable: true,
        }

        onStateUpdate?.({
          type: 'FAIL_TRANSITION',
          targetStage,
          failure: failurePayload,
        })

        return { success: false, error: msg }
      }
    },
    [bridge, onStateUpdate, onStageChange, storage],
  )

  // Start auto-play loop driving stage advancement exclusively through the dual-lock async gate
  const startAutoPlay = useCallback(async () => {
    if (disabled || stateRef.current.inFlight) return

    // If currently completed, or at final stage and confirmed, or halted, reset or resume cleanly
    let startIdx = getStageIndex(stateRef.current.currentStage)
    if (startIdx >= STAGE_IDS.length - 1 && stateRef.current.stageStatuses[STAGE_IDS[startIdx]] === 'confirmed') {
      // Re-start from stage 1 by resetting estate first
      try {
        bridge.resetEstate()
        storage?.removeItem('amxd.demo.currentStage')
      } catch {
        /* ignore */
      }
      onStateUpdate?.({ type: 'RESET_ESTATE' })
      startIdx = 0
    }

    const abortController = new AbortController()
    abortControllerRef.current = abortController

    setHaltReason(null)
    setHaltedStage(null)
    updateStatus('running')

    // Advance sequentially through remaining stages
    for (let i = startIdx; i < STAGE_IDS.length - 1; i += 1) {
      if (!isRunningRef.current || abortController.signal.aborted) {
        break
      }

      const targetStage = STAGE_IDS[i + 1]
      const stepResult = await executeStageStep(targetStage, abortController.signal)

      if (stepResult.aborted) {
        updateStatus('manual')
        return
      }

      if (!stepResult.success) {
        // Council finding guarantee: Halt immediately on rejection / failed confirmation.
        // Never silently skip to next stage.
        setHaltedStage(targetStage)
        setHaltReason(stepResult.error ?? `Stage ${STAGE_METADATA[targetStage].stepNumber} confirmation failed`)
        updateStatus('halted')
        return
      }
    }

    if (isRunningRef.current && !abortController.signal.aborted) {
      updateStatus('completed')
    }
  }, [bridge, disabled, executeStageStep, onStateUpdate, storage, updateStatus])

  // Toggle Auto-Play on / off
  const handleToggleAutoPlay = useCallback(() => {
    if (status === 'running') {
      stopAutoPlay()
    } else {
      void startAutoPlay()
    }
  }, [status, stopAutoPlay, startAutoPlay])

  // Live speed switch handler: only changes pacing for upcoming stages
  const handleSpeedSelect = useCallback((newPacing: AutoPlayPacing) => {
    setPacing(newPacing)
    pacingRef.current = newPacing
  }, [])

  // Idempotent Reset Estate: resets bridge state, clears namespaced storage, dispatches RESET_ESTATE
  const handleResetEstate = useCallback(() => {
    stopAutoPlay()

    try {
      bridge.resetEstate()
    } catch {
      /* bridge reset */
    }

    try {
      storage?.removeItem('amxd.demo.currentStage')
    } catch {
      /* storage remove */
    }

    onStateUpdate?.({ type: 'RESET_ESTATE' })
    setHaltReason(null)
    setHaltedStage(null)
    updateStatus('manual')
    onReset?.()
  }, [bridge, onReset, onStateUpdate, stopAutoPlay, storage, updateStatus])

  // Retry execution from halted state
  const handleRetryHalted = useCallback(() => {
    setHaltReason(null)
    setHaltedStage(null)
    void startAutoPlay()
  }, [startAutoPlay])

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (abortControllerRef.current) {
        abortControllerRef.current.abort()
      }
    }
  }, [])

  const currentIdx = getStageIndex(state.currentStage)
  const isLastStageConfirmed =
    currentIdx === STAGE_IDS.length - 1 && state.stageStatuses[state.currentStage] === 'confirmed'

  return (
    <div
      data-testid="autoplay-controls"
      className={`p-4 bg-[var(--surface)] border border-[var(--border)] rounded-lg space-y-3.5 shadow-sm ${className}`}
    >
      {/* Top Header Row: Title, Mode Indicator Badge */}
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-[var(--border)]/60 pb-3">
        <div className="flex items-center gap-2.5">
          <span className="text-xs font-mono font-bold uppercase tracking-wider text-[var(--cyan)]">
            Auto-Play & Estate Control
          </span>
          <span className="text-xs font-mono text-[var(--muted)]">
            • Dwell-AND-Confirmation Gate
          </span>
        </div>

        {/* Visible 3-Way Mode Indicator: Running vs Halted on Rejection vs Manual */}
        <div className="flex items-center gap-2">
          {status === 'running' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="running"
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-mono font-semibold bg-[var(--cyan)]/20 text-[var(--cyan)] border border-[var(--cyan)]/40 animate-pulse"
            >
              <span className="w-2 h-2 rounded-full bg-[var(--cyan)] animate-ping" />
              AUTO-PLAY RUNNING ({pacing.toUpperCase()})
            </span>
          )}

          {status === 'halted' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="halted"
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-mono font-semibold bg-[var(--error)]/20 text-[var(--error)] border border-[var(--error)]/50"
            >
              <span className="w-2 h-2 rounded-full bg-[var(--error)]" />
              AUTO-PLAY HALTED ON REJECTION
            </span>
          )}

          {status === 'manual' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="manual"
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-mono font-medium bg-[var(--surface2)] text-[var(--muted)] border border-[var(--border)]"
            >
              <span className="w-1.5 h-1.5 rounded-full bg-[var(--muted)]" />
              MANUAL STEPPING
            </span>
          )}

          {status === 'completed' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="completed"
              className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-mono font-semibold bg-[var(--teal)]/20 text-[var(--teal)] border border-[var(--teal)]/40"
            >
              <span className="w-2 h-2 rounded-full bg-[var(--teal)]" />
              AUTO-PLAY COMPLETED
            </span>
          )}
        </div>
      </div>

      {/* Main Controls Row: Auto-Play Start/Stop, 3-Speed Toggle, Reset Estate */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        {/* Left Side: Auto-Play Toggle & Speed Switcher */}
        <div className="flex flex-wrap items-center gap-3">
          {/* Auto-Play Start / Stop Button */}
          <button
            type="button"
            data-testid="autoplay-toggle-button"
            data-active={status === 'running'}
            aria-label={status === 'running' ? 'Pause Auto-Play' : 'Start Auto-Play'}
            disabled={disabled}
            onClick={handleToggleAutoPlay}
            className={`btn px-4 py-1.5 text-xs sm:text-sm font-semibold rounded transition-all flex items-center gap-2 ${
              status === 'running'
                ? 'bg-[var(--error)]/15 text-[var(--error)] border border-[var(--error)]/40 hover:bg-[var(--error)]/25'
                : 'btn-primary bg-[var(--cyan)] text-[var(--bg)] hover:brightness-110'
            }`}
          >
            {status === 'running' ? (
              <>
                <span data-testid="autoplay-stop-button" className="inline-flex items-center gap-1.5">
                  <svg aria-hidden="true" className="w-3.5 h-3.5 fill-current" viewBox="0 0 24 24">
                    <rect x="6" y="4" width="4" height="16" />
                    <rect x="14" y="4" width="4" height="16" />
                  </svg>
                  Stop Auto-Play
                </span>
              </>
            ) : (
              <>
                <span data-testid="autoplay-start-button" className="inline-flex items-center gap-1.5">
                  <svg aria-hidden="true" className="w-3.5 h-3.5 fill-current" viewBox="0 0 24 24">
                    <polygon points="5,3 19,12 5,21" />
                  </svg>
                  {isLastStageConfirmed ? 'Restart Auto-Play' : 'Start Auto-Play'}
                </span>
              </>
            )}
          </button>

          {/* Three Speed Toggles: 1x (4s), 2x (2s), instant (100ms) */}
          <div
            data-testid="autoplay-speed-toggle"
            role="radiogroup"
            aria-label="Auto-Play Speed Toggle"
            className="inline-flex rounded-md border border-[var(--border)] bg-[var(--bg)] p-0.5"
          >
            {(['1x', '2x', 'instant'] as const).map((spd) => {
              const isActive = pacing === spd
              const dwellLabel =
                spd === '1x' ? '4s' : spd === '2x' ? '2s' : '100ms'

              return (
                <button
                  key={spd}
                  type="button"
                  role="radio"
                  aria-checked={isActive}
                  data-testid={`autoplay-speed-${spd}`}
                  data-active={isActive}
                  disabled={disabled}
                  onClick={() => handleSpeedSelect(spd)}
                  className={`px-2.5 py-1 text-xs font-mono font-medium rounded transition-all ${
                    isActive
                      ? 'bg-[var(--cyan)] text-[var(--bg)] font-bold shadow-sm'
                      : 'text-[var(--muted)] hover:text-[var(--text)] hover:bg-[var(--surface2)]'
                  }`}
                  title={`${spd} speed (${dwellLabel} dwell minimum floor per stage)`}
                >
                  {spd} <span className="opacity-75 text-[10px]">({dwellLabel})</span>
                </button>
              )
            })}
          </div>
        </div>

        {/* Right Side: Idempotent Reset Estate */}
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="autoplay-reset-estate-button"
            data-reset-btn="true"
            aria-label="Reset demo estate to initial baseline"
            onClick={handleResetEstate}
            className="btn px-3 py-1.5 text-xs font-mono font-semibold rounded text-[var(--error)] border border-[var(--error)]/30 hover:bg-[var(--error)]/10 transition-all flex items-center gap-1.5"
          >
            <svg
              aria-hidden="true"
              className="w-3.5 h-3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            </svg>
            Reset Estate
          </button>
        </div>
      </div>

      {/* Visible Halted on Rejection Alert Banner */}
      {status === 'halted' && (
        <div
          data-testid="autoplay-halted-banner"
          role="alert"
          className="p-3 bg-[var(--error)]/10 border border-[var(--error)]/30 rounded-lg flex flex-wrap items-center justify-between gap-3 text-xs"
        >
          <div className="space-y-0.5">
            <div className="font-semibold text-[var(--error)] flex items-center gap-1.5">
              <span className="w-1.5 h-1.5 rounded-full bg-[var(--error)]" />
              <span>
                Stage {haltedStage ? STAGE_METADATA[haltedStage].stepNumber : ''} Verification
                Rejected — Auto-Play Halted
              </span>
            </div>
            <p data-testid="autoplay-error-message" className="text-[var(--muted)] font-mono">
              {haltReason || 'Stage confirmation condition not satisfied.'}
            </p>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              data-testid="autoplay-retry-button"
              onClick={handleRetryHalted}
              className="btn px-3 py-1 text-xs font-semibold rounded bg-[var(--error)]/20 text-[var(--error)] hover:bg-[var(--error)]/30 border border-[var(--error)]/40 transition-all"
            >
              Retry Stage
            </button>
            <button
              type="button"
              onClick={handleResetEstate}
              className="btn px-3 py-1 text-xs font-medium rounded text-[var(--muted)] hover:text-[var(--text)] transition-all"
            >
              Reset Estate
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

export default AutoPlayControls
