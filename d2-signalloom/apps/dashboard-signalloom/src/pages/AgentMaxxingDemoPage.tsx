import React, { useEffect, useMemo, useRef, useState } from 'react'
import StageProgressionController from '../components/demos/StageProgressionController'
import { TokenIssuePanel } from '../components/demos/TokenIssuePanel'
import { EnrollmentPanel } from '../components/demos/EnrollmentPanel'
import { ConfinementTelemetryPanel } from '../components/demos/ConfinementTelemetryPanel'
import { AdversarialSimulationPanel } from '../components/demos/AdversarialSimulationPanel'
import { RevocationPanel } from '../components/demos/RevocationPanel'
import { LandlockPolicyInspector } from '../components/demos/LandlockPolicyInspector'
import { AttestationBundleExport } from '../components/demos/AttestationBundleExport'
import {
  HAPPY_PATH_PRESET,
  SCENARIO_PRESETS,
  type ScenarioPreset,
} from '../components/demos/scenarios'
import { isDemoMode, subscribeDemoMode } from '../api/demoMode'
import {
  STAGE_METADATA,
  getStageIndex,
} from '../components/demos/types'
import {
  AgentMaxxingLogStream,
  useAgentMaxxingLogStream,
} from '../components/demos/AgentMaxxingLogStream'
import { StatCard } from '../components/DashKit'
import { useAuth0 } from '../auth/oidc'

/**
 * The principal a live-channel issuance or enrollment record is attributed to.
 *
 * Read from the authenticated OIDC profile, never from a constant. Returns `undefined`
 * when the session has authenticated nobody, which the panels render as an explicit
 * unattributed marker (a demo console that fabricates an operator name is indisputably
 * worse than one that admits it has none).
 */
export function deriveOperatorPrincipal(
  profile: Record<string, unknown> | undefined,
): string | undefined {
  const claim = (key: string): string =>
    typeof profile?.[key] === 'string' ? (profile[key] as string).trim() : ''
  return claim('email') || claim('preferred_username') || claim('sub') || undefined
}

function useOperatorPrincipal(): string | undefined {
  const { user } = useAuth0()
  return useMemo(
    () => deriveOperatorPrincipal(user as Record<string, unknown> | undefined),
    [user],
  )
}

export const AgentMaxxingDemoPage: React.FC = () => {
  const operatorPrincipal = useOperatorPrincipal()
  const logStream = useAgentMaxxingLogStream({ defaultStage: 'operator_init' })
  const streamedStagesRef = useRef<Set<string>>(new Set())
  const [activePreset, setActivePreset] = useState<ScenarioPreset>(HAPPY_PATH_PRESET)
  const [demoMode, setDemoMode] = useState<boolean>(() => isDemoMode())

  useEffect(() => {
    return subscribeDemoMode((on) => setDemoMode(on))
  }, [])

  const channelKind: 'mock' | 'live' = demoMode ? 'mock' : 'live'

  return (
    <div
      data-testid="agentmaxxing-demo-page"
      style={{ paddingBottom: 40 }}
    >
      {/* Page Header */}
      <header style={{ marginBottom: 24 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12, flexWrap: 'wrap' }}>
          <span
            className="tag"
            style={{
              background: 'rgba(6, 182, 212, 0.12)',
              color: 'var(--cyan)',
              border: '1px solid rgba(6, 182, 212, 0.3)',
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: 600,
              letterSpacing: '0.05em',
            }}
          >
            Agent Governance Lab
          </span>
          <span style={{ fontSize: 12, fontFamily: 'monospace', color: 'var(--muted)' }}>
            AMXD v0.1.0 • Deterministic 5-Stage Stepper
          </span>
          <span
            className="tag"
            style={{
              marginLeft: 'auto',
              background: 'var(--surface)',
              color: 'var(--teal)',
              border: '1px solid rgba(16, 185, 129, 0.3)',
              fontFamily: 'monospace',
              fontSize: 11,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
            }}
          >
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: 'var(--teal)' }} />
            Zero Customer Payload Invariant
          </span>
        </div>

        <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', margin: 0, marginBottom: 6 }}>
          AgentMaxxing Interactive Demo Console
        </h1>
        <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, maxWidth: 780, lineHeight: 1.55 }}>
          Step-by-step laboratory for external Linux host agent onboarding, Landlock LSM process
          confinement telemetry, live cryptographic artifact verification, adversarial tamper
          containment, and instant attributable revocation with 403 Forbidden denial proofs.
        </p>

        {/* Preset Switcher UI */}
        <div
          data-testid="preset-switcher"
          style={{
            marginTop: 18,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            flexWrap: 'wrap',
          }}
        >
          <span
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: 700,
              color: 'var(--muted)',
              textTransform: 'uppercase',
              letterSpacing: '0.05em',
            }}
          >
            Scenario Preset:
          </span>
          <div
            style={{
              display: 'inline-flex',
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              borderRadius: 6,
              padding: 3,
              gap: 4,
            }}
          >
            {SCENARIO_PRESETS.map((p) => {
              const isSelected = activePreset.id === p.id
              return (
                <button
                  key={p.id}
                  type="button"
                  data-testid={`preset-option-${p.id}`}
                  onClick={() => {
                    if (activePreset.id !== p.id) {
                      try {
                        localStorage.removeItem('amxd.demo.currentStage')
                      } catch {
                        /* ignore storage error */
                      }
                      setActivePreset(p)
                    }
                  }}
                  style={{
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: isSelected ? 600 : 500,
                    padding: '5px 12px',
                    borderRadius: 4,
                    border: isSelected ? '1px solid var(--cyan)' : '1px solid transparent',
                    background: isSelected ? 'rgba(6, 182, 212, 0.12)' : 'transparent',
                    color: isSelected ? 'var(--cyan)' : 'var(--text)',
                    cursor: 'pointer',
                    transition: 'all 0.15s ease',
                  }}
                >
                  {p.name}
                </button>
              )
            })}
          </div>
          <span
            style={{
              fontSize: 11,
              fontFamily: 'monospace',
              color: 'var(--muted)',
            }}
          >
            {activePreset.description}
          </span>
        </div>
      </header>

      {/* Main Interactive Progression Controller */}
      <main style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
        <StageProgressionController
          key={`${activePreset.id}-${channelKind}`}
          preset={activePreset}
          channel={channelKind}
          statCards={({ state, bridge, inFlight }) => {
            const currentStep = getStageIndex(state.currentStage) + 1
            const stepStr = String(currentStep).padStart(2, '0')
            const isConfirmed = state.stageStatuses[state.currentStage] === 'confirmed'
            const progressLabel = `${stepStr} / 05 ${isConfirmed ? 'Confirmed' : 'Pending'}`
            const executionState = inFlight ? 'In Flight' : 'Active'
            const channelPreset = `${bridge.channelKind.toUpperCase()} / LIVE`
            const presetName = bridge.preset?.name || activePreset.name

            return (
              <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 24 }}>
                <StatCard
                  label="Stage Progress"
                  value={progressLabel}
                  sub="Deterministic 5-Stage Stepper"
                  accent="var(--cyan)"
                />
                <StatCard
                  label="Execution State"
                  value={executionState}
                  sub="Dual-lock async gate"
                  accent="var(--teal)"
                />
                <StatCard
                  label="Channel & Preset"
                  value={channelPreset}
                  sub={presetName}
                  accent="var(--violet)"
                />
                <StatCard
                  label="Invariant Status"
                  value="Zero Customer Payload"
                  sub="SHA-256 verifiable"
                  accent="var(--teal)"
                />
              </div>
            )
          }}
        >
          {({
            activeViewStage,
            state,
            bridge,
            inFlight,
            recordStagePayload,
          }) => {
            const meta = STAGE_METADATA[activeViewStage]
            const isConfirmed = state.stageStatuses[activeViewStage] === 'confirmed'
            const isInFlight = state.stageStatuses[activeViewStage] === 'in_flight'
            const payload = state.stagePayloads[activeViewStage]

            // Stream stage logs whenever stage transitions or is confirmed
            useEffect(() => {
              const stageKey = `${activePreset.id}-${activeViewStage}-${isConfirmed ? 'confirmed' : 'pending'}-${isInFlight ? 'flight' : 'idle'}`
              if (!streamedStagesRef.current.has(stageKey)) {
                streamedStagesRef.current.add(stageKey)
                const currentPayload = state.stagePayloads[activeViewStage]
                // Stream with short delay if inFlight, or append directly if confirmed
                if (isInFlight || isConfirmed) {
                  logStream.appendStageLog(activeViewStage, currentPayload, { progressive: isInFlight, delayMs: 30 })
                }
              }
            }, [activePreset.id, activeViewStage, isConfirmed, isInFlight, state.stagePayloads])

            return (
              <>
                <section
                  data-testid={`stage-panel-${activeViewStage}`}
                  className="card"
                  style={{
                    background: 'var(--surface)',
                    border: '1px solid var(--border)',
                    borderRadius: 8,
                    padding: 24,
                  }}
                >
                  {/* Active Stage Header */}
                  <div
                    style={{
                      display: 'flex',
                      alignItems: 'flex-start',
                      justifyContent: 'space-between',
                      gap: 16,
                      borderBottom: '1px solid var(--border)',
                      paddingBottom: 16,
                      marginBottom: 20,
                      flexWrap: 'wrap',
                    }}
                  >
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span
                          style={{
                            fontSize: 11,
                            fontFamily: 'monospace',
                            fontWeight: 700,
                            color: 'var(--cyan)',
                          }}
                        >
                          STAGE 0{meta.stepNumber}
                        </span>
                        <span style={{ color: 'var(--border)' }}>•</span>
                        <span
                          style={{
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: 'var(--muted)',
                          }}
                        >
                          {bridge.channelKind.toUpperCase()} CHANNEL ({bridge.preset.name})
                        </span>
                      </div>
                      <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--text)', margin: 0 }}>
                        {meta.title}
                      </h2>
                      <p style={{ fontSize: 12, color: 'var(--muted)', margin: 0 }}>
                        {meta.description}
                      </p>
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                      <span
                        data-testid={`panel-status-badge-${activeViewStage}`}
                        className="tag"
                        style={{
                          padding: '4px 10px',
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: 600,
                          textTransform: 'uppercase',
                          letterSpacing: '0.05em',
                          background: isConfirmed
                            ? 'rgba(16, 185, 129, 0.15)'
                            : isInFlight
                              ? 'rgba(6, 182, 212, 0.20)'
                              : 'var(--surface2)',
                          border: isConfirmed
                            ? '1px solid var(--teal)'
                            : isInFlight
                              ? '1px solid var(--cyan)'
                              : '1px solid var(--border)',
                          color: isConfirmed
                            ? 'var(--teal)'
                            : isInFlight
                              ? 'var(--cyan)'
                              : 'var(--muted)',
                        }}
                      >
                        {state.stageStatuses[activeViewStage]}
                      </span>
                    </div>
                  </div>

                  {/* Stage 1: AMXD-P2-2 TokenIssuePanel */}
                  {activeViewStage === 'operator_init' && (
                    <TokenIssuePanel
                      bridge={bridge}
                      preset={bridge.preset}
                      inFlight={inFlight}
                      operatorId={operatorPrincipal}
                      initialPayload={state.stagePayloads.operator_init ?? null}
                      onIssued={(issued) => recordStagePayload('operator_init', issued)}
                    />
                  )}

                  {/* Stage 2: AMXD-P2-2 EnrollmentPanel */}
                  {activeViewStage === 'host_enrolled' && (
                    <EnrollmentPanel
                      bridge={bridge}
                      preset={bridge.preset}
                      inFlight={inFlight}
                      operatorId={operatorPrincipal}
                      initialPayload={state.stagePayloads.host_enrolled ?? null}
                    />
                  )}

                  {/* Stage 3: AMXD-P3-1 ConfinementTelemetryPanel & LandlockPolicyInspector */}
                  {activeViewStage === 'confinement_streaming' && (
                    <>
                      <ConfinementTelemetryPanel
                        bridge={bridge}
                        preset={bridge.preset}
                        inFlight={inFlight}
                        initialPayload={state.stagePayloads.confinement_streaming ?? null}
                        onOutcome={(outcome) => {
                          if (outcome.status === 'ok') {
                            recordStagePayload('confinement_streaming', outcome.payload)
                          }
                        }}
                        onTelemetryPolled={(polledPayload) => {
                          recordStagePayload('confinement_streaming', polledPayload)
                        }}
                      />
                      <LandlockPolicyInspector defaultOpen={true} />
                    </>
                  )}

                  {/* Stage 4: AMXD-P4-1 AdversarialSimulationPanel */}
                  {activeViewStage === 'adversarial_tamper' && (
                    <AdversarialSimulationPanel
                      bridge={bridge}
                      preset={bridge.preset}
                      inFlight={inFlight}
                      initialPayload={state.stagePayloads.adversarial_tamper ?? null}
                      onOutcome={(outcome) => {
                        if (outcome.status === 'ok') {
                          recordStagePayload('adversarial_tamper', outcome.payload)
                        }
                      }}
                      onTamperInjected={(tamperPayload) => {
                        recordStagePayload('adversarial_tamper', tamperPayload)
                      }}
                    />
                  )}

                  {/* Stage 5: AMXD-P4-2 RevocationPanel */}
                  {activeViewStage === 'revocation_denied' && (
                    <RevocationPanel
                      bridge={bridge}
                      preset={bridge.preset}
                      inFlight={inFlight}
                      operatorId={operatorPrincipal}
                      initialPayload={state.stagePayloads.revocation_denied ?? null}
                      onRevocationComplete={(revoked) =>
                        recordStagePayload('revocation_denied', revoked)
                      }
                    />
                  )}

                  {/* Cryptographic Evidence Payload Preview */}
                  {payload && (
                    <div
                      data-testid={`stage-payload-preview-${activeViewStage}`}
                      style={{
                        marginTop: 16,
                        padding: '12px 16px',
                        background: 'var(--surface2)',
                        border: '1px solid var(--border)',
                        borderRadius: 6,
                        overflowX: 'auto',
                      }}
                    >
                      <div
                        style={{
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: 'var(--muted)',
                          marginBottom: 6,
                          textTransform: 'uppercase',
                          letterSpacing: '0.05em',
                        }}
                      >
                        Cryptographic Evidence Payload ({activeViewStage})
                      </div>
                      <pre
                        style={{
                          fontSize: 11,
                          fontFamily: 'monospace',
                          margin: 0,
                          color: 'var(--text)',
                          lineHeight: 1.4,
                        }}
                      >
                        {JSON.stringify(payload, null, 2)}
                      </pre>
                    </div>
                  )}

                  {/* Cryptographic Attestation Bundle Export */}
                  <AttestationBundleExport
                    preset={bridge.preset}
                    activeStage={activeViewStage}
                    state={state}
                    payload={payload}
                  />
                </section>

                {/* Execution Log Stream Slot: Streams logs like SuperCredential Demo */}
                <div
                  data-testid="execution-log-stream-slot"
                  style={{ marginTop: 8 }}
                >
                  <AgentMaxxingLogStream
                    logStream={logStream}
                    stage={activeViewStage}
                    streaming={inFlight || logStream.isStreaming}
                    title={`AgentMaxxing Telemetry · ${meta.shortTitle}`}
                    testId="agentmaxxing-log-stream"
                  />
                </div>
              </>
            )
          }}
        </StageProgressionController>
      </main>
    </div>
  )
}

export default AgentMaxxingDemoPage
