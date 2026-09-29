import { useState, useEffect, useRef } from 'react'
import { useAuth0 } from '../auth/oidc'
import { Section } from './DashKit'
import {
  fetchSignalFusionSteps,
  startSignalFusionRun,
  fetchSignalFusionRunLog,
} from '../api/signalFusionDemo'
import type { DemoStep, DemoRunView, DemoRunLogChunk } from '../api/signalFusionDemo'

export type DemoRunState = 'idle' | 'running' | 'succeeded' | 'failed'

export default function SignalFusionDemoControls() {
  const { getAccessTokenSilently } = useAuth0()
  const [steps, setSteps] = useState<DemoStep[]>([])
  const [runState, setRunState] = useState<DemoRunState>('idle')
  const [activeRunId, setActiveRunId] = useState<string | null>(null)
  const [logOutput, setLogOutput] = useState('')
  const [loadError, setLoadError] = useState<string | null>(null)
  const logRef = useRef<HTMLPreElement>(null)
  const pollRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Load steps on mount
  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const token = await getAccessTokenSilently()
        const s = await fetchSignalFusionSteps(token)
        if (!cancelled) setSteps(s)
      } catch (err) {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : 'Failed to load demo steps')
      }
    })()
    return () => { cancelled = true }
  }, [getAccessTokenSilently])

  // Poll log when a run is active
  useEffect(() => {
    if (!activeRunId || runState !== 'running') return
    let offset = 0
    let cancelled = false

    async function poll() {
      if (cancelled) return
      try {
        const token = await getAccessTokenSilently()
        const chunk: DemoRunLogChunk = await fetchSignalFusionRunLog(activeRunId!, offset, token, 2)
        if (cancelled) return
        if (chunk.chunk) {
          setLogOutput(prev => prev + chunk.chunk)
          offset = chunk.next_offset
        }
        if (chunk.eof) {
          setRunState('succeeded')
          return
        }
      } catch {
        // Keep polling on transient errors
      }
      if (!cancelled) {
        pollRef.current = setTimeout(poll, 500)
      }
    }

    void poll()
    return () => {
      cancelled = true
      if (pollRef.current) clearTimeout(pollRef.current)
    }
  }, [activeRunId, runState, getAccessTokenSilently])

  // Auto-scroll log
  useEffect(() => {
    if (logRef.current) {
      logRef.current.scrollTop = logRef.current.scrollHeight
    }
  }, [logOutput])

  const handleRun = async (stepId: string) => {
    try {
      setRunState('running')
      setLogOutput('')
      const token = await getAccessTokenSilently()
      const run: DemoRunView = await startSignalFusionRun(stepId, token)
      setActiveRunId(run.run_id)
    } catch (err) {
      setRunState('failed')
      setLogOutput(err instanceof Error ? err.message : 'Failed to start demo run')
    }
  }

  if (loadError) return null
  if (steps.length === 0) return null

  const isRunning = runState === 'running'

  return (
    <Section title="Signal Fusion Demo" hint="Run the three-act demo lifecycle">
      <div className="card" style={{ padding: '20px 24px' }} data-testid="sf-demo-controls">
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginBottom: logOutput ? 14 : 0 }}>
          {steps.map(step => (
            <button
              key={step.step_id}
              data-testid={`sf-demo-act-${step.step_id}`}
              disabled={isRunning}
              onClick={() => void handleRun(step.step_id)}
              style={{
                padding: '8px 16px',
                fontSize: 12,
                fontWeight: 600,
                borderRadius: 'var(--radius-sm, 6px)',
                border: '1px solid var(--border-subtle, var(--border))',
                background: isRunning ? 'var(--surface2)' : 'var(--teal)',
                color: isRunning ? 'var(--muted)' : 'var(--on-accent, #fff)',
                cursor: isRunning ? 'not-allowed' : 'pointer',
                opacity: isRunning ? 0.6 : 1,
              }}
              title={step.description}
            >
              Act {step.step_id}: {step.title}
            </button>
          ))}
          {runState === 'running' && (
            <span style={{ fontSize: 12, color: 'var(--amber)', alignSelf: 'center', fontWeight: 600 }}>
              Running...
            </span>
          )}
          {runState === 'succeeded' && (
            <span style={{ fontSize: 12, color: 'var(--teal)', alignSelf: 'center', fontWeight: 600 }}>
              Completed
            </span>
          )}
          {runState === 'failed' && (
            <span style={{ fontSize: 12, color: 'var(--error)', alignSelf: 'center', fontWeight: 600 }}>
              Failed
            </span>
          )}
        </div>

        {logOutput && (
          <pre
            ref={logRef}
            data-testid="sf-demo-log"
            style={{
              maxHeight: 320,
              overflow: 'auto',
              padding: '12px 16px',
              fontSize: 11,
              fontFamily: 'monospace',
              lineHeight: 1.6,
              background: 'var(--surface, #111)',
              color: 'var(--text)',
              borderRadius: 'var(--radius-sm, 6px)',
              border: '1px solid var(--border)',
              margin: 0,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-all',
            }}
          >
            {logOutput}
          </pre>
        )}
      </div>
    </Section>
  )
}
