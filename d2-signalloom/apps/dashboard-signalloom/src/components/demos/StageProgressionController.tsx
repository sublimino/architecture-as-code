import React, {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from 'react'
import {
  INITIAL_STEPPER_STATE,
  STAGE_IDS,
  STAGE_METADATA,
  getStageIndex,
  nextState,
  type AutoPlayPacing,
  type DemoStepperState,
  type StageId,
} from './types'
import {
  createDemoBridge,
  type DemoBridge,
} from './bridge'
import {
  HAPPY_PATH_PRESET,
  type ScenarioPreset,
} from './scenarios'
import StepperHeader from './StepperHeader'

export const AMXD_DEMO_STAGE_STORAGE_KEY = 'amxd.demo.currentStage'

export interface StageProgressionContextValue {
  readonly state: DemoStepperState
  readonly bridge: DemoBridge
  readonly currentStage: StageId
  readonly activeViewStage: StageId
  readonly inFlight: boolean
  readonly isAdvancing: boolean
  readonly canAdvance: boolean
  readonly canRetreat: boolean
  readonly advance: () => Promise<void>
  readonly retreat: () => void
  readonly jumpToStage: (stage: StageId) => Promise<void>
  readonly resetEstate: () => void
  readonly selectViewStage: (stage: StageId) => void
}

export interface StageProgressionControllerProps {
  readonly bridge?: DemoBridge
  readonly preset?: ScenarioPreset
  readonly channel?: 'mock' | 'live'
  readonly autoDwellMs?: number
  readonly autoPacing?: AutoPlayPacing
  readonly onStageChange?: (stage: StageId, state: DemoStepperState) => void
  readonly onReset?: () => void
  readonly storage?: Storage | null
  readonly className?: string
  readonly children?: (context: StageProgressionContextValue) => React.ReactNode
}

function resolveStorageInstance(propStorage?: Storage | null): Storage | null {
  if (propStorage !== undefined) return propStorage
  try {
    if (typeof localStorage !== 'undefined') return localStorage
  } catch {
    /* access restricted in sandbox or private browsing */
  }
  try {
    if (typeof window !== 'undefined' && window.localStorage) return window.localStorage
  } catch {
    /* access restricted */
  }
  return null
}

function getInitialState(store: Storage | null): DemoStepperState {
  if (store) {
    try {
      const stored = store.getItem(AMXD_DEMO_STAGE_STORAGE_KEY)
      if (stored && STAGE_IDS.includes(stored as StageId)) {
        const stage = stored as StageId
        const stageIdx = getStageIndex(stage)
        const statuses = { ...INITIAL_STEPPER_STATE.stageStatuses }
        for (let i = 0; i <= stageIdx; i += 1) {
          statuses[STAGE_IDS[i]] = 'confirmed'
        }
        return {
          ...INITIAL_STEPPER_STATE,
          currentStage: stage,
          stageStatuses: statuses,
        }
      }
    } catch {
      /* ignore storage read error */
    }
  }
  return INITIAL_STEPPER_STATE
}

export const StageProgressionController: React.FC<StageProgressionControllerProps> = ({
  bridge: propBridge,
  preset = HAPPY_PATH_PRESET,
  channel = 'mock',
  autoDwellMs,
  onStageChange,
  onReset,
  storage: propStorage,
  className = '',
  children,
}) => {
  const store = resolveStorageInstance(propStorage)

  // Bridge instance
  const bridge = useMemo<DemoBridge>(() => {
    if (propBridge) return propBridge
    return createDemoBridge(channel, { preset, storage: store })
  }, [propBridge, channel, preset, store])

  // Reducer initialization with persisted or clean state
  const [state, dispatch] = useReducer(nextState, store, getInitialState)

  // Active view stage (can differ from execution currentStage if operator inspects previous stages)
  const [activeViewStage, setActiveViewStage] = useState<StageId>(state.currentStage)

  // ARIA live region announcement
  const [announcement, setAnnouncement] = useState<string>(
    `AgentMaxxing Demo Console loaded at ${STAGE_METADATA[state.currentStage].title}`,
  )

  // Ref tracking in-flight status to ensure immediate synchronous no-op on rapid clicks
  const inFlightRef = useRef(false)
  inFlightRef.current = state.inFlight

  // Sync activeViewStage when currentStage advances
  useEffect(() => {
    setActiveViewStage(state.currentStage)
  }, [state.currentStage])

  const currentIdx = getStageIndex(state.currentStage)
  const activeViewIdx = getStageIndex(activeViewStage)

  const canAdvance = currentIdx < STAGE_IDS.length - 1 && !state.inFlight
  const canRetreat = activeViewIdx > 0 && !state.inFlight

  const advance = useCallback(async () => {
    if (inFlightRef.current || state.inFlight) {
      // Rapid click during in-flight transition is a strict no-op with visible feedback
      return
    }

    const currentStageIndex = getStageIndex(state.currentStage)
    if (currentStageIndex >= STAGE_IDS.length - 1) return

    const targetStage = STAGE_IDS[currentStageIndex + 1]
    const targetMeta = STAGE_METADATA[targetStage]

    dispatch({ type: 'START_TRANSITION', targetStage })
    setAnnouncement(`Starting transition to ${targetMeta.title}...`)

    try {
      const outcome = await bridge.advance(targetStage, {
        dwellMs: autoDwellMs,
      })

      if (outcome.status === 'ok') {
        dispatch({ type: 'RESOLVE_TRANSITION', targetStage, payload: outcome.payload })
        setActiveViewStage(targetStage)
        setAnnouncement(`${targetMeta.title} confirmed.`)

        try {
          store?.setItem(AMXD_DEMO_STAGE_STORAGE_KEY, targetStage)
        } catch {
          /* storage write error ignored */
        }

        onStageChange?.(targetStage, state)
      } else {
        const failurePayload = {
          stage: targetStage,
          errorReason: outcome.error.message,
          failedAt: new Date().toISOString(),
          recoverable: true,
        }
        dispatch({ type: 'FAIL_TRANSITION', targetStage, failure: failurePayload })
        setAnnouncement(`Stage ${targetMeta.stepNumber} failed: ${outcome.error.message}`)
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      const failurePayload = {
        stage: targetStage,
        errorReason: msg,
        failedAt: new Date().toISOString(),
        recoverable: true,
      }
      dispatch({ type: 'FAIL_TRANSITION', targetStage, failure: failurePayload })
      setAnnouncement(`Stage ${targetMeta.stepNumber} error: ${msg}`)
    }
  }, [state, bridge, autoDwellMs, store, onStageChange])

  const retreat = useCallback(() => {
    if (inFlightRef.current || state.inFlight) return
    const activeIdx = getStageIndex(activeViewStage)
    if (activeIdx <= 0) return

    const prevStage = STAGE_IDS[activeIdx - 1]
    setActiveViewStage(prevStage)
    setAnnouncement(`Navigated back to ${STAGE_METADATA[prevStage].title}`)
  }, [activeViewStage, state.inFlight])

  const jumpToStage = useCallback(
    async (targetStage: StageId) => {
      if (inFlightRef.current || state.inFlight) return
      if (targetStage === activeViewStage) return

      const targetIdx = getStageIndex(targetStage)
      const currIdx = getStageIndex(state.currentStage)

      if (targetIdx <= currIdx || state.stageStatuses[targetStage] === 'confirmed') {
        setActiveViewStage(targetStage)
        setAnnouncement(`Viewing ${STAGE_METADATA[targetStage].title}`)
        return
      }

      if (targetIdx === currIdx + 1) {
        await advance()
        return
      }

      setAnnouncement(
        `Cannot jump to Stage ${STAGE_METADATA[targetStage].stepNumber}. Complete Stage ${STAGE_METADATA[STAGE_IDS[currIdx + 1]].stepNumber} first.`,
      )
    },
    [activeViewStage, state.currentStage, state.stageStatuses, state.inFlight, advance],
  )

  const resetEstate = useCallback(() => {
    if (inFlightRef.current || state.inFlight) return

    try {
      bridge.resetEstate()
    } catch {
      /* bridge reset */
    }

    try {
      store?.removeItem(AMXD_DEMO_STAGE_STORAGE_KEY)
    } catch {
      /* store remove */
    }

    dispatch({ type: 'RESET_ESTATE' })
    setActiveViewStage('operator_init')
    setAnnouncement('Demo estate reset to Stage 1: Operator Token Issuance.')
    onReset?.()
  }, [bridge, store, onReset, state.inFlight])

  // Keyboard navigation on left/right arrow when controller container is focused
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      const targetTag = (e.target as HTMLElement)?.tagName
      if (targetTag === 'INPUT' || targetTag === 'TEXTAREA' || targetTag === 'SELECT') {
        return
      }

      if (e.key === 'ArrowRight' && canAdvance) {
        e.preventDefault()
        advance()
      } else if (e.key === 'ArrowLeft' && canRetreat) {
        e.preventDefault()
        retreat()
      }
    },
    [canAdvance, canRetreat, advance, retreat],
  )

  const contextValue: StageProgressionContextValue = useMemo(
    () => ({
      state,
      bridge,
      currentStage: state.currentStage,
      activeViewStage,
      inFlight: state.inFlight,
      isAdvancing: state.inFlight,
      canAdvance,
      canRetreat,
      advance,
      retreat,
      jumpToStage,
      resetEstate,
      selectViewStage: setActiveViewStage,
    }),
    [
      state,
      bridge,
      activeViewStage,
      canAdvance,
      canRetreat,
      advance,
      retreat,
      jumpToStage,
      resetEstate,
    ],
  )

  return (
    <div
      tabIndex={0}
      role="region"
      aria-label="AgentMaxxing Stage Progression Controller"
      onKeyDown={handleKeyDown}
      className={`space-y-4 focus:outline-none ${className}`}
      data-testid="stage-progression-controller"
    >
      {/* ARIA Live Region for Screen-Reader Announcements */}
      <div
        role="status"
        aria-live="polite"
        aria-atomic="true"
        className="sr-only"
        data-testid="stepper-aria-live"
      >
        {announcement}
      </div>

      {/* Stepper Header Presentational Component */}
      <StepperHeader
        currentStage={state.currentStage}
        activeViewStage={activeViewStage}
        stageStatuses={state.stageStatuses}
        inFlight={state.inFlight}
        disabled={state.inFlight}
        onSelectStage={jumpToStage}
      />

      {/* Controller Navigation Toolbar */}
      <div
        data-testid="stepper-controls-bar"
        className="flex flex-wrap items-center justify-between gap-3 p-3.5 bg-[var(--surface)] border border-[var(--border)] rounded-lg"
      >
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-testid="stepper-retreat-button"
            data-back-btn="true"
            aria-label="Previous Stage"
            disabled={!canRetreat || state.inFlight}
            onClick={retreat}
            className={`btn px-3.5 py-1.5 text-xs sm:text-sm font-medium rounded transition-all ${
              !canRetreat || state.inFlight
                ? 'opacity-40 cursor-not-allowed bg-[var(--surface2)] text-[var(--muted)] border-[var(--border)]'
                : 'btn-secondary hover:border-[var(--cyan)]'
            }`}
          >
            ← Back
          </button>

          <button
            type="button"
            data-testid="stepper-advance-button"
            data-forward-btn="true"
            aria-label={state.inFlight ? 'Advancing stage...' : 'Next Stage'}
            disabled={!canAdvance || state.inFlight}
            onClick={advance}
            className={`btn px-4 py-1.5 text-xs sm:text-sm font-medium rounded transition-all flex items-center gap-2 ${
              !canAdvance || state.inFlight
                ? 'opacity-50 cursor-not-allowed bg-[var(--surface2)] text-[var(--muted)] border-[var(--border)]'
                : 'btn-primary bg-[var(--cyan)] text-[var(--bg)] font-semibold hover:brightness-110'
            }`}
          >
            {state.inFlight ? (
              <>
                <svg
                  aria-hidden="true"
                  className="animate-spin h-3.5 w-3.5 text-current"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="3"
                >
                  <circle cx="12" cy="12" r="10" strokeDasharray="32" strokeDashoffset="10" />
                </svg>
                <span>Advancing...</span>
              </>
            ) : currentIdx >= STAGE_IDS.length - 1 ? (
              <span>Completed</span>
            ) : (
              <span>Advance Stage →</span>
            )}
          </button>
        </div>

        <div className="flex items-center gap-2">
          <span className="text-xs font-mono text-[var(--muted)] hidden sm:inline">
            Stage {getStageIndex(state.currentStage) + 1} of 5
          </span>

          <button
            type="button"
            data-testid="stepper-reset-button"
            aria-label="Reset demo estate"
            disabled={state.inFlight}
            onClick={resetEstate}
            className={`btn px-3 py-1.5 text-xs font-medium rounded transition-all ${
              state.inFlight
                ? 'opacity-40 cursor-not-allowed text-[var(--muted)]'
                : 'text-[var(--error)] border border-[var(--error)]/30 hover:bg-[var(--error)]/10'
            }`}
          >
            Reset Estate
          </button>
        </div>
      </div>

      {/* Render children or stage panels if provided */}
      {children && children(contextValue)}
    </div>
  )
}

export default StageProgressionController
