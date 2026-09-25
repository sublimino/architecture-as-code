import React, { useCallback } from 'react'
import {
  STAGE_IDS,
  STAGE_METADATA,
  getStageIndex,
  type StageExecutionStatus,
  type StageId,
} from './types'

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
      className={`card ${className}`.trim()}
      style={{
        padding: '16px 20px',
        marginBottom: 16,
        background: 'var(--surface)',
        border: '1px solid var(--border)',
        borderRadius: 8,
      }}
    >
      <ol
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 8,
          listStyle: 'none',
          padding: 0,
          margin: 0,
          flexWrap: 'wrap',
        }}
      >
        {STAGE_IDS.map((stageId, index) => {
          const meta = STAGE_METADATA[stageId]
          const status = stageStatuses[stageId] ?? 'idle'
          const isCurrent = stageId === activeStage
          const isPassed = index < currentStageIdx || status === 'confirmed'
          const isSelectable = !disabled && !inFlight && (isPassed || index <= currentStageIdx + 1)

          // Tone configuration based on status
          let badgeBg = 'var(--surface2)'
          let badgeBorder = 'var(--border)'
          let badgeText = 'var(--muted)'
          let titleColor = 'var(--muted)'
          let statusLabel = 'Pending'

          if (status === 'confirmed') {
            badgeBg = 'rgba(16, 185, 129, 0.15)'
            badgeBorder = 'var(--teal)'
            badgeText = 'var(--teal)'
            titleColor = isCurrent ? 'var(--text)' : 'var(--text)'
            statusLabel = 'Confirmed'
          } else if (status === 'in_flight') {
            badgeBg = 'rgba(6, 182, 212, 0.20)'
            badgeBorder = 'var(--cyan)'
            badgeText = 'var(--cyan)'
            titleColor = 'var(--cyan)'
            statusLabel = 'In Flight'
          } else if (status === 'failed') {
            badgeBg = 'rgba(220, 38, 38, 0.20)'
            badgeBorder = 'var(--error)'
            badgeText = 'var(--error)'
            titleColor = 'var(--error)'
            statusLabel = 'Failed'
          } else if (isCurrent) {
            badgeBg = 'rgba(6, 182, 212, 0.12)'
            badgeBorder = 'var(--cyan)'
            badgeText = 'var(--cyan)'
            titleColor = 'var(--text)'
            statusLabel = 'Active'
          }

          return (
            <React.Fragment key={stageId}>
              <li
                data-testid={`stage-indicator-${stageId}`}
                data-stage-id={stageId}
                style={{
                  flex: 1,
                  display: 'flex',
                  alignItems: 'center',
                  minWidth: 160,
                }}
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
                  style={{
                    width: '100%',
                    textAlign: 'left',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 12,
                    padding: '10px 12px',
                    borderRadius: 6,
                    border: isCurrent ? '1px solid var(--cyan)' : '1px solid var(--border)',
                    background: isCurrent ? 'var(--surface2)' : 'transparent',
                    boxShadow: isCurrent ? '0 0 12px rgba(6, 182, 212, 0.25)' : 'none',
                    cursor: isSelectable ? 'pointer' : 'not-allowed',
                    opacity: isSelectable ? 1 : 0.65,
                    transition: 'all 0.15s ease',
                  }}
                >
                  <div
                    data-testid={`stage-step-${meta.stepNumber}`}
                    style={{
                      width: 32,
                      height: 32,
                      borderRadius: '50%',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: 700,
                      flexShrink: 0,
                      background: badgeBg,
                      border: `1px solid ${badgeBorder}`,
                      color: badgeText,
                      transition: 'all 0.15s ease',
                    }}
                  >
                    <StatusIcon status={status} stepNumber={meta.stepNumber} />
                  </div>

                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 2 }}>
                      <span
                        style={{
                          fontSize: 10,
                          fontFamily: 'monospace',
                          textTransform: 'uppercase',
                          letterSpacing: '0.05em',
                          color: 'var(--muted)',
                        }}
                      >
                        Stage {meta.stepNumber}
                      </span>
                      <span
                        data-testid={`stage-status-${stageId}`}
                        className="tag"
                        style={{
                          fontSize: 10,
                          fontFamily: 'monospace',
                          padding: '1px 6px',
                          background: badgeBg,
                          border: `1px solid ${badgeBorder}`,
                          color: badgeText,
                        }}
                      >
                        {status}
                      </span>
                    </div>
                    <div
                      style={{
                        fontSize: 12,
                        fontWeight: isCurrent ? 600 : 500,
                        color: titleColor,
                        whiteSpace: 'nowrap',
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                      }}
                    >
                      {meta.shortTitle}
                    </div>
                  </div>
                </button>
              </li>

              {index < STAGE_IDS.length - 1 && (
                <div
                  aria-hidden="true"
                  style={{
                    width: 16,
                    height: 2,
                    margin: '0 4px',
                    backgroundColor:
                      index < currentStageIdx
                        ? 'var(--teal)'
                        : index === currentStageIdx && inFlight
                          ? 'var(--cyan)'
                          : 'var(--border)',
                    flexShrink: 0,
                    alignSelf: 'center',
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
