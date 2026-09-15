import React, { useCallback } from 'react'
import {
  STAGE_IDS,
  STAGE_METADATA,
  getStageIndex,
  type StageExecutionStatus,
  type StageId,
} from './types'
import { colors } from '../../styles/tokens'

export interface StepperHeaderProps {
  readonly currentStage: StageId
  readonly stageStatuses: Readonly<Record<StageId, StageExecutionStatus>>
  readonly inFlight?: boolean
  readonly onSelectStage?: (stage: StageId) => void
  readonly activeViewStage?: StageId
  readonly disabled?: boolean
  readonly className?: string
}

function StatusIcon({ status, stepNumber }: { status: StageExecutionStatus; stepNumber: number }) {
  if (status === 'confirmed') {
    return (
      <svg
        aria-hidden="true"
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="3"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="m5 13 4 4L19 7" />
      </svg>
    )
  }

  if (status === 'in_flight') {
    return (
      <svg
        aria-hidden="true"
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        className="animate-spin"
      >
        <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
      </svg>
    )
  }

  if (status === 'failed') {
    return (
      <svg
        aria-hidden="true"
        width="14"
        height="14"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="3"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M18 6 6 18M6 6l12 12" />
      </svg>
    )
  }

  return <span>{stepNumber}</span>
}

export const StepperHeader: React.FC<StepperHeaderProps> = ({
  currentStage,
  stageStatuses,
  inFlight = false,
  onSelectStage,
  activeViewStage,
  disabled = false,
  className = '',
}) => {
  const activeStage = activeViewStage ?? currentStage
  const currentStageIdx = getStageIndex(currentStage)

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent, stageId: StageId) => {
      if (disabled || inFlight) return

      const idx = getStageIndex(stageId)
      if (e.key === 'ArrowRight' && idx < STAGE_IDS.length - 1) {
        e.preventDefault()
        const nextId = STAGE_IDS[idx + 1]
        onSelectStage?.(nextId)
      } else if (e.key === 'ArrowLeft' && idx > 0) {
        e.preventDefault()
        const prevId = STAGE_IDS[idx - 1]
        onSelectStage?.(prevId)
      } else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        onSelectStage?.(stageId)
      }
    },
    [disabled, inFlight, onSelectStage],
  )

  return (
    <nav
      aria-label="AgentMaxxing Demo Stages"
      data-testid="stepper-header"
      className={`w-full bg-[var(--surface)] border border-[var(--border)] rounded-lg p-4 sm:p-5 ${className}`}
    >
      <ol className="flex flex-col md:flex-row items-stretch md:items-center justify-between gap-3 md:gap-2">
        {STAGE_IDS.map((stageId, index) => {
          const meta = STAGE_METADATA[stageId]
          const status = stageStatuses[stageId] ?? 'idle'
          const isCurrent = stageId === activeStage
          const isPassed = index < currentStageIdx || status === 'confirmed'
          const isSelectable = !disabled && !inFlight && (isPassed || index <= currentStageIdx + 1)

          // Tone configuration based on status
          let badgeBg = 'bg-[var(--surface2)]'
          let badgeBorder = 'border-[var(--border)]'
          let badgeText = 'text-[var(--muted)]'
          let titleText = 'text-[var(--dim)]'
          let statusLabel = 'Pending'

          if (status === 'confirmed') {
            badgeBg = 'bg-[var(--teal)]/15'
            badgeBorder = 'border-[var(--teal)]'
            badgeText = 'text-[var(--teal)]'
            titleText = isCurrent ? 'text-[var(--text)] font-semibold' : 'text-[var(--text)]'
            statusLabel = 'Confirmed'
          } else if (status === 'in_flight') {
            badgeBg = 'bg-[var(--cyan)]/20'
            badgeBorder = 'border-[var(--cyan)]'
            badgeText = 'text-[var(--cyan)]'
            titleText = 'text-[var(--cyan)] font-semibold'
            statusLabel = 'In Flight'
          } else if (status === 'failed') {
            badgeBg = 'bg-[var(--error)]/20'
            badgeBorder = 'border-[var(--error)]'
            badgeText = 'text-[var(--error)]'
            titleText = 'text-[var(--error)] font-semibold'
            statusLabel = 'Failed'
          } else if (isCurrent) {
            badgeBg = 'bg-[var(--cyan)]/10'
            badgeBorder = 'border-[var(--cyan)]'
            badgeText = 'text-[var(--cyan)]'
            titleText = 'text-[var(--text)] font-semibold'
            statusLabel = 'Active'
          }

          const focusRingClass = isCurrent
            ? 'ring-2 ring-[var(--cyan)] ring-offset-2 ring-offset-[var(--bg)] border-[var(--cyan)] shadow-[0_0_12px_rgba(6,182,212,0.25)]'
            : 'border-[var(--border)]'

          return (
            <React.Fragment key={stageId}>
              <li
                data-testid={`stage-indicator-${stageId}`}
                data-stage-id={stageId}
                className="flex-1 flex items-center min-w-0"
              >
                <button
                  type="button"
                  data-testid={`stage-jump-${stageId}`}
                  data-step={meta.stepNumber}
                  aria-label={`Stage ${meta.stepNumber}: ${meta.shortTitle} — ${statusLabel}`}
                  aria-current={isCurrent ? 'step' : undefined}
                  aria-disabled={!isSelectable ? 'true' : undefined}
                  disabled={!isSelectable}
                  onClick={() => isSelectable && onSelectStage?.(stageId)}
                  onKeyDown={(e) => handleKeyDown(e, stageId)}
                  className={`w-full text-left flex items-center gap-3 p-2.5 rounded-md transition-all duration-200 ${focusRingClass} ${
                    isSelectable
                      ? 'cursor-pointer hover:bg-[var(--surface2)]'
                      : 'cursor-not-allowed opacity-75'
                  }`}
                  style={{
                    backgroundColor: isCurrent ? 'var(--surface2)' : undefined,
                  }}
                >
                  <div
                    data-testid={`stage-step-${meta.stepNumber}`}
                    className={`w-8 h-8 rounded-full flex items-center justify-center text-xs font-mono font-bold border transition-colors ${badgeBg} ${badgeBorder} ${badgeText}`}
                  >
                    <StatusIcon status={status} stepNumber={meta.stepNumber} />
                  </div>

                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="text-[10px] font-mono uppercase tracking-wider text-[var(--muted)]">
                        Stage {meta.stepNumber}
                      </span>
                      <span
                        data-testid={`stage-status-${stageId}`}
                        className={`text-[10px] font-mono px-1.5 py-0.2 rounded border uppercase tracking-wider ${badgeBg} ${badgeBorder} ${badgeText}`}
                      >
                        {status}
                      </span>
                    </div>
                    <div className={`text-xs sm:text-sm truncate font-medium ${titleText}`}>
                      {meta.shortTitle}
                    </div>
                  </div>
                </button>
              </li>

              {index < STAGE_IDS.length - 1 && (
                <div
                  aria-hidden="true"
                  className="hidden md:block w-4 lg:w-6 h-0.5 mx-0.5 bg-[var(--border)] transition-colors self-center"
                  style={{
                    backgroundColor:
                      index < currentStageIdx
                        ? colors.tealLoom
                        : index === currentStageIdx && inFlight
                          ? colors.cyanLoom
                          : 'var(--border)',
                  }}
                />
              )}
            </React.Fragment>
          )
        })}
      </ol>
    </nav>
  )
}

export default StepperHeader
