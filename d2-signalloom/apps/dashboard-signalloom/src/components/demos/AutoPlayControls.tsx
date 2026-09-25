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
      className={`card ${className}`}
      style={{
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 8,
        padding: '14px 18px',
        marginBottom: 16,
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
      }}
    >
      {/* Top Header Row: Title, Mode Indicator Badge */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
          borderBottom: '1px solid var(--border)',
          paddingBottom: 10,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <span
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 700,
              textTransform: 'uppercase',
              letterSpacing: '0.06em',
              color: 'var(--cyan)',
            }}
          >
            Auto-Play & Estate Control
          </span>
          <span style={{ fontSize: 11, fontFamily: 'monospace', color: 'var(--muted)' }}>
            • Dual-Lock Async Gate
          </span>
        </div>

        {/* Visible 3-Way Mode Indicator: Running vs Halted on Rejection vs Manual vs Completed */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {status === 'running' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="running"
              className="tag"
              style={{
                background: 'rgba(6, 182, 212, 0.15)',
                color: 'var(--cyan)',
                border: '1px solid rgba(6, 182, 212, 0.4)',
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: 600,
                letterSpacing: '0.05em',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                padding: '3px 8px',
              }}
            >
              <span
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: '50%',
                  background: 'var(--cyan)',
                  boxShadow: '0 0 8px var(--cyan)',
                }}
              />
              AUTO-PLAY RUNNING ({pacing.toUpperCase()})
            </span>
          )}

          {status === 'halted' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="halted"
              className="tag"
              style={{
                background: 'rgba(220, 38, 38, 0.15)',
                color: 'var(--error)',
                border: '1px solid rgba(220, 38, 38, 0.4)',
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: 600,
                letterSpacing: '0.05em',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                padding: '3px 8px',
              }}
            >
              <span
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: '50%',
                  background: 'var(--error)',
                }}
              />
              AUTO-PLAY HALTED ON REJECTION
            </span>
          )}

          {status === 'manual' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="manual"
              className="tag"
              style={{
                background: 'var(--surface2)',
                color: 'var(--muted)',
                border: '1px solid var(--border)',
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: 500,
                letterSpacing: '0.05em',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                padding: '3px 8px',
              }}
            >
              <span
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: '50%',
                  background: 'var(--muted)',
                }}
              />
              MANUAL STEPPING
            </span>
          )}

          {status === 'completed' && (
            <span
              data-testid="autoplay-mode-indicator"
              data-mode="completed"
              className="tag"
              style={{
                background: 'rgba(16, 185, 129, 0.15)',
                color: 'var(--teal)',
                border: '1px solid rgba(16, 185, 129, 0.4)',
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: 600,
                letterSpacing: '0.05em',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
                padding: '3px 8px',
              }}
            >
              <span
                style={{
                  width: 6,
                  height: 6,
                  borderRadius: '50%',
                  background: 'var(--teal)',
                  boxShadow: '0 0 6px var(--teal)',
                }}
              />
              AUTO-PLAY COMPLETED
            </span>
          )}
        </div>
      </div>

      {/* Main Controls Row: Auto-Play Start/Stop, 3-Speed Toggle, Reset Estate */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 12,
          flexWrap: 'wrap',
        }}
      >
        {/* Left Side: Auto-Play Start/Stop Button & Speed Switcher */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          {/* Start / Stop Button */}
          <button
            type="button"
            data-testid="autoplay-toggle-button"
            data-active={status === 'running'}
            aria-label={status === 'running' ? 'Pause Auto-Play' : 'Start Auto-Play'}
            disabled={disabled}
            onClick={handleToggleAutoPlay}
            className={`btn ps-3.5 pe-4 ${status === 'running' ? 'btn-danger' : 'btn-primary'}`}
            style={{
              padding: '7px 16px',
              fontSize: 13,
              fontWeight: 600,
              fontFamily: 'inherit',
              borderRadius: 4,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 8,
              cursor: disabled ? 'not-allowed' : 'pointer',
              opacity: disabled ? 0.5 : 1,
              background: status === 'running' ? 'rgba(220, 38, 38, 0.15)' : 'var(--cyan)',
              color: status === 'running' ? 'var(--error)' : 'var(--bg)',
              border: status === 'running' ? '1px solid rgba(220, 38, 38, 0.4)' : '1px solid transparent',
              transition: 'all 0.15s ease-in-out',
            }}
          >
            {status === 'running' ? (
              <span data-testid="autoplay-stop-button" style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                <svg aria-hidden="true" style={{ width: 12, height: 12, fill: 'currentColor' }} viewBox="0 0 24 24">
                  <rect x="6" y="4" width="4" height="16" />
                  <rect x="14" y="4" width="4" height="16" />
                </svg>
                <span>Stop Auto-Play</span>
              </span>
            ) : (
              <span data-testid="autoplay-start-button" style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                <svg
                  aria-hidden="true"
                  style={{ width: 12, height: 12, fill: 'currentColor', transform: 'translateX(1.5px)' }}
                  viewBox="0 0 24 24"
                >
                  <polygon points="5,3 19,12 5,21" />
                </svg>
                <span>{isLastStageConfirmed ? 'Restart Auto-Play' : 'Start Auto-Play'}</span>
              </span>
            )}
          </button>

          {/* Segmented Speed Selector: 1x (4s), 2x (2s), instant (100ms) */}
          <div
            data-testid="autoplay-speed-toggle"
            role="radiogroup"
            aria-label="Auto-Play Speed Toggle"
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              background: 'var(--bg)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              padding: 2,
              gap: 2,
            }}
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
                  data-static="true"
                  disabled={disabled}
                  onClick={() => handleSpeedSelect(spd)}
                  style={{
                    padding: '5px 12px',
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: isActive ? 700 : 500,
                    borderRadius: 4,
                    border: isActive ? '1px solid rgba(6, 182, 212, 0.4)' : '1px solid transparent',
                    background: isActive ? 'var(--surface2)' : 'transparent',
                    color: isActive ? 'var(--cyan)' : 'var(--muted)',
                    cursor: disabled ? 'not-allowed' : 'pointer',
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 6,
                    transition: 'all 0.15s ease-in-out',
                    boxShadow: isActive ? '0 1px 3px rgba(0, 0, 0, 0.25)' : 'none',
                  }}
                  title={`${spd} speed (${dwellLabel} dwell minimum floor per stage)`}
                >
                  <span>{spd}</span>
                  <span
                    style={{
                      fontSize: 10,
                      opacity: isActive ? 0.9 : 0.6,
                      color: isActive ? 'var(--cyan)' : 'var(--muted)',
                    }}
                  >
                    ({dwellLabel})
                  </span>
                </button>
              )
            })}
          </div>
        </div>

        {/* Right Side: Idempotent Reset Estate */}
        <div>
          <button
            type="button"
            data-testid="autoplay-reset-estate-button"
            data-reset-btn="true"
            aria-label="Reset demo estate to initial baseline"
            onClick={handleResetEstate}
            className="btn btn-secondary ps-2.5 pe-3.5"
            style={{
              padding: '7px 14px',
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: 600,
              borderRadius: 4,
              border: '1px solid var(--border)',
              background: 'var(--surface2)',
              color: 'var(--muted)',
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              cursor: 'pointer',
              transition: 'all 0.15s ease-in-out',
            }}
          >
            <svg
              aria-hidden="true"
              style={{ width: 13, height: 13, color: 'var(--muted)' }}
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
            <span>Reset Estate</span>
          </button>
        </div>
      </div>

      {/* Visible Halted on Rejection Alert Banner */}
      {status === 'halted' && (
        <div
          data-testid="autoplay-halted-banner"
          role="alert"
          style={{
            padding: '12px 16px',
            background: 'rgba(220, 38, 38, 0.08)',
            border: '1px solid rgba(220, 38, 38, 0.3)',
            borderRadius: 6,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            flexWrap: 'wrap',
            gap: 12,
            marginTop: 4,
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <div
              style={{
                fontSize: 12,
                fontWeight: 600,
                color: 'var(--error)',
                display: 'inline-flex',
                alignItems: 'center',
                gap: 6,
              }}
            >
              <span style={{ width: 6, height: 6, borderRadius: '50%', background: 'var(--error)' }} />
              <span>
                Stage {haltedStage ? STAGE_METADATA[haltedStage].stepNumber : ''} Verification
                Rejected — Auto-Play Halted
              </span>
            </div>
            <p
              data-testid="autoplay-error-message"
              style={{
                margin: 0,
                fontSize: 11,
                fontFamily: 'monospace',
                color: 'var(--muted)',
              }}
            >
              {haltReason || 'Stage confirmation condition not satisfied.'}
            </p>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <button
              type="button"
              data-testid="autoplay-retry-button"
              onClick={handleRetryHalted}
              className="btn"
              style={{
                padding: '4px 10px',
                fontSize: 11,
                fontWeight: 600,
                borderRadius: 4,
                background: 'rgba(220, 38, 38, 0.2)',
                color: 'var(--error)',
                border: '1px solid rgba(220, 38, 38, 0.4)',
                cursor: 'pointer',
              }}
            >
              Retry Stage
            </button>
            <button
              type="button"
              onClick={handleResetEstate}
              className="btn btn-secondary"
              style={{
                padding: '4px 10px',
                fontSize: 11,
                fontWeight: 500,
                borderRadius: 4,
                cursor: 'pointer',
              }}
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
