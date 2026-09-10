import React from 'react'

export interface StepDefinition {
  id: string
  title: string
  subtitle?: string
}

interface OnboardingProgressHeaderProps {
  currentStepIndex: number
  totalSteps: number
  steps: StepDefinition[]
  onStepClick?: (index: number) => void
  onSkip: () => void
}

export default function OnboardingProgressHeader({
  currentStepIndex,
  totalSteps,
  steps,
  onStepClick,
  onSkip,
}: OnboardingProgressHeaderProps) {
  const stepNumber = currentStepIndex + 1
  const progressPct = totalSteps > 0 ? Math.round((stepNumber / totalSteps) * 100) : 0

  return (
    <header style={{ borderBottom: '1px solid var(--border)', marginBottom: 28, background: 'var(--surface)' }}>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 16,
          padding: '16px 32px 12px',
          flexWrap: 'wrap',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', gap: 24, flexWrap: 'wrap' }}>
          <div>
            <span style={{ fontSize: 12, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.05em', color: 'var(--cyan)' }}>
              Step {stepNumber} of {totalSteps}
            </span>
            <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: '2px 0 0' }}>
              {steps[currentStepIndex]?.title ?? 'Setup'}
            </h2>
          </div>

          {/* Stepper pills */}
          <nav aria-label="Onboarding Progress" style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            {steps.map((step, idx) => {
              const isCompleted = idx < currentStepIndex
              const isCurrent = idx === currentStepIndex
              const isClickable = Boolean(onStepClick && isCompleted)

              return (
                <button
                  key={step.id}
                  type="button"
                  disabled={!isClickable}
                  onClick={() => isClickable && onStepClick && onStepClick(idx)}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 6,
                    padding: '6px 12px',
                    borderRadius: 20,
                    border: isCurrent
                      ? '1px solid var(--cyan)'
                      : isCompleted
                      ? '1px solid rgba(16, 185, 129, 0.4)'
                      : '1px solid var(--border)',
                    background: isCurrent
                      ? 'rgba(6, 182, 212, 0.12)'
                      : isCompleted
                      ? 'rgba(16, 185, 129, 0.08)'
                      : 'transparent',
                    color: isCurrent
                      ? 'var(--cyan)'
                      : isCompleted
                      ? 'var(--teal)'
                      : 'var(--muted)',
                    fontSize: 12,
                    fontWeight: isCurrent ? 600 : 500,
                    cursor: isClickable ? 'pointer' : 'default',
                    transition: 'all 0.15s ease',
                  }}
                >
                  <span
                    style={{
                      width: 18,
                      height: 18,
                      borderRadius: '50%',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: 10,
                      fontWeight: 700,
                      background: isCompleted
                        ? 'var(--teal)'
                        : isCurrent
                        ? 'var(--cyan)'
                        : 'var(--border)',
                      color: isCompleted || isCurrent ? '#000' : 'var(--muted)',
                    }}
                  >
                    {isCompleted ? '✓' : idx + 1}
                  </span>
                  <span>{step.title}</span>
                </button>
              )
            })}
          </nav>
        </div>

        <button
          type="button"
          className="btn btn-secondary"
          onClick={onSkip}
          data-testid="skip-onboarding-button"
          style={{ fontSize: 13 }}
        >
          Skip for now
        </button>
      </div>

      {/* Accessible progressbar */}
      <div style={{ padding: '0 32px 14px' }}>
        <div
          role="progressbar"
          aria-valuenow={progressPct}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-label={`Onboarding progress: ${progressPct}% completed`}
          style={{
            height: 4,
            borderRadius: 2,
            background: 'var(--border)',
            overflow: 'hidden',
          }}
        >
          <div
            style={{
              width: `${progressPct}%`,
              height: '100%',
              background: 'linear-gradient(90deg, var(--cyan), var(--violet, #8B5CF6))',
              transition: 'width 0.3s ease',
            }}
          />
        </div>
      </div>
    </header>
  )
}
