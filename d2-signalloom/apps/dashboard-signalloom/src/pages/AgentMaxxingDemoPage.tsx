import React from 'react'
import StageProgressionController from '../components/demos/StageProgressionController'
import {
  STAGE_METADATA,
} from '../components/demos/types'

export const AgentMaxxingDemoPage: React.FC = () => {
  return (
    <div
      data-testid="agentmaxxing-demo-page"
      className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6 space-y-6"
    >
      {/* Page Header */}
      <header className="space-y-2 border-b border-[var(--border)] pb-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-3">
            <span className="px-2.5 py-0.5 rounded text-[11px] font-mono font-semibold uppercase tracking-wider bg-[var(--cyan)]/15 text-[var(--cyan)] border border-[var(--cyan)]/30">
              Agent Governance Lab
            </span>
            <span className="text-xs font-mono text-[var(--muted)]">
              AMXD v0.1.0 • Deterministic 5-Stage Stepper
            </span>
          </div>

          <div className="flex items-center gap-2">
            <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-mono bg-[var(--surface)] text-[var(--teal)] border border-[var(--teal)]/30">
              <span className="w-1.5 h-1.5 rounded-full bg-[var(--teal)]" />
              Zero Customer Payload Invariant
            </span>
          </div>
        </div>

        <h1 className="text-2xl sm:text-3xl font-bold tracking-tight text-[var(--text)]">
          AgentMaxxing Interactive Demo Console
        </h1>
        <p className="text-sm text-[var(--muted)] max-w-4xl leading-relaxed">
          Step-by-step laboratory for external Linux host agent onboarding, Landlock LSM process
          confinement telemetry, live cryptographic artifact verification, adversarial tamper
          containment, and instant attributable revocation with 403 Forbidden denial proofs.
        </p>
      </header>

      {/* Main Interactive Progression Controller */}
      <main className="space-y-6">
        <StageProgressionController>
          {({ activeViewStage, state, bridge, inFlight, canAdvance, advance }) => {
            const meta = STAGE_METADATA[activeViewStage]
            const isConfirmed = state.stageStatuses[activeViewStage] === 'confirmed'
            const isInFlight = state.stageStatuses[activeViewStage] === 'in_flight'
            const payload = state.stagePayloads[activeViewStage]

            return (
              <section
                data-testid={`stage-panel-${activeViewStage}`}
                className="bg-[var(--surface)] border border-[var(--border)] rounded-lg p-5 sm:p-6 space-y-5 shadow-sm"
              >
                {/* Active Stage Header */}
                <div className="flex flex-wrap items-start justify-between gap-4 border-b border-[var(--border)] pb-4">
                  <div className="space-y-1">
                    <div className="flex items-center gap-2">
                      <span className="text-xs font-mono font-bold text-[var(--cyan)]">
                        STAGE 0{meta.stepNumber}
                      </span>
                      <span className="text-[var(--border)]">•</span>
                      <span className="text-xs font-mono text-[var(--muted)]">
                        {bridge.channelKind.toUpperCase()} CHANNEL ({bridge.preset.name})
                      </span>
                    </div>
                    <h2 className="text-xl font-bold text-[var(--text)]">{meta.title}</h2>
                    <p className="text-xs sm:text-sm text-[var(--muted)]">{meta.description}</p>
                  </div>

                  <div className="flex items-center gap-2">
                    <span
                      data-testid={`panel-status-badge-${activeViewStage}`}
                      className={`px-2.5 py-1 rounded text-xs font-mono font-medium uppercase tracking-wider border ${
                        isConfirmed
                          ? 'bg-[var(--teal)]/15 border-[var(--teal)] text-[var(--teal)]'
                          : isInFlight
                            ? 'bg-[var(--cyan)]/20 border-[var(--cyan)] text-[var(--cyan)] animate-pulse'
                            : 'bg-[var(--surface2)] border-[var(--border)] text-[var(--muted)]'
                      }`}
                    >
                      {state.stageStatuses[activeViewStage]}
                    </span>
                  </div>
                </div>

                {/* Stage Specific Panel Placeholder / Telemetry Frame */}
                <div className="min-h-[220px] rounded-lg border border-[var(--border)] bg-[var(--bg)] p-4 sm:p-5 flex flex-col justify-between">
                  <div className="space-y-3">
                    <div className="flex items-center justify-between text-xs font-mono text-[var(--muted)] border-b border-[var(--border)]/50 pb-2">
                      <span>COMPONENT: {meta.owningCard}</span>
                      <span>STAGE ID: {activeViewStage}</span>
                    </div>

                    <div className="py-4 space-y-2">
                      <div className="text-sm font-medium text-[var(--text)]">
                        {activeViewStage === 'operator_init' && 'Operator Token Issuance & Attribution'}
                        {activeViewStage === 'host_enrolled' && 'Ed25519 Cryptographic Host Sensor Enrollment'}
                        {activeViewStage === 'confinement_streaming' && 'Landlock LSM Telemetry & SHA-256 Hashing'}
                        {activeViewStage === 'adversarial_tamper' && 'Simulated Hash Mismatch & Boundary Alert'}
                        {activeViewStage === 'revocation_denied' && 'Attributable Revocation & 403 Forbidden Upload Denial'}
                      </div>
                      <p className="text-xs text-[var(--muted)] leading-relaxed">
                        {isConfirmed
                          ? 'Stage execution verified. State machine transition resolved with immutable cryptographic telemetry.'
                          : isInFlight
                            ? 'Executing dual-lock async gate (minimum dwell timer + backend/mock verification resolution)...'
                            : 'Stage pending execution. Click "Advance Stage" above or use keyboard right-arrow to step.'}
                      </p>
                    </div>

                    {payload && (
                      <div
                        data-testid={`stage-payload-preview-${activeViewStage}`}
                        className="mt-2 p-3 bg-[var(--surface)] border border-[var(--border)] rounded text-xs font-mono text-[var(--dim)] overflow-x-auto"
                      >
                        <pre className="text-[11px] leading-tight">
                          {JSON.stringify(payload, null, 2)}
                        </pre>
                      </div>
                    )}
                  </div>

                  <div className="pt-3 border-t border-[var(--border)]/50 flex items-center justify-between text-xs text-[var(--muted)]">
                    <span>Zero customer code or prompt tokens processed</span>
                    {canAdvance && (
                      <button
                        type="button"
                        onClick={advance}
                        disabled={inFlight}
                        className="text-xs font-medium text-[var(--cyan)] hover:underline flex items-center gap-1 cursor-pointer"
                      >
                        Advance to Stage {meta.stepNumber + 1} →
                      </button>
                    )}
                  </div>
                </div>
              </section>
            )
          }}
        </StageProgressionController>
      </main>
    </div>
  )
}

export default AgentMaxxingDemoPage
