import { useState, useCallback, useEffect, useRef } from 'react'
import { useAppContext } from '../App'
import { useAuth0 } from '../auth/oidc'
import FleetTopology from '../components/fleet/FleetTopology'
import FleetRiskGauge from '../components/fleet/FleetRiskGauge'
import LoadingState, { loadPhase } from '../components/LoadingState'
import type { FleetTopology as FleetTopologyData } from '../api/fleetApi'
import {
  fetchFleetTopology,
  deployFleet,
  scanFleet,
  stunFleetAgent,
  recoverFleet,
  resetFleet,
} from '../api/fleetApi'

// ── Constants ───────────────────────────────────────────────────────────────

const FLEET_POLL_MS = 2000

// ── Component ───────────────────────────────────────────────────────────────

interface FleetDemoPageProps {
  audience?: boolean
}

export default function FleetDemoPage({ audience = false }: FleetDemoPageProps) {
  const { superadmin } = useAppContext()
  const { getAccessTokenSilently } = useAuth0()

  // Fleet state.
  const [topology, setTopology] = useState<FleetTopologyData | null>(null)
  const [cascadeInProgress, setCascadeInProgress] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)

  // Per-operation loading states.
  const [topologyLoading, setTopologyLoading] = useState(false)
  const [topologyLoaded, setTopologyLoaded] = useState(false)
  const [deployLoading, setDeployLoading] = useState(false)
  const [deployError, setDeployError] = useState<string | null>(null)
  const [deployLoaded, setDeployLoaded] = useState(false)
  const [scanLoading, setScanLoading] = useState(false)
  const [scanError, setScanError] = useState<string | null>(null)
  const [scanLoaded, setScanLoaded] = useState(false)
  const [stunLoading, setStunLoading] = useState(false)
  const [stunError, setStunError] = useState<string | null>(null)
  const [stunLoaded, setStunLoaded] = useState(false)
  const [recoverLoading, setRecoverLoading] = useState(false)
  const [recoverError, setRecoverError] = useState<string | null>(null)
  const [recoverLoaded, setRecoverLoaded] = useState(false)
  const [resetLoading, setResetLoading] = useState(false)
  const [resetError, setResetError] = useState<string | null>(null)
  const [resetLoaded, setResetLoaded] = useState(false)

  // Stun target.
  const [stunTarget, setStunTarget] = useState('agent-cardvault')

  // Poll for topology.
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const loadTopology = useCallback(async () => {
    setTopologyLoading(true)
    setError(null)
    try {
      const data = await fetchFleetTopology()
      setTopology(data)
      setTopologyLoaded(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load fleet topology')
    } finally {
      setTopologyLoading(false)
    }
  }, [])

  // Start polling on mount.
  useEffect(() => {
    void loadTopology()
    pollRef.current = setInterval(() => { void loadTopology() }, FLEET_POLL_MS)
    return () => {
      if (pollRef.current) clearInterval(pollRef.current)
    }
  }, [loadTopology])

  const handleDeploy = useCallback(async () => {
    setDeployLoading(true)
    setDeployError(null)
    try {
      const token = await getAccessTokenSilently()
      await deployFleet(token)
      setDeployLoaded(true)
      void loadTopology()
    } catch (err) {
      setDeployError(err instanceof Error ? err.message : 'Deploy failed')
    } finally {
      setDeployLoading(false)
    }
  }, [getAccessTokenSilently, loadTopology])

  const handleScan = useCallback(async () => {
    setScanLoading(true)
    setScanError(null)
    try {
      const token = await getAccessTokenSilently()
      await scanFleet(token)
      setScanLoaded(true)
      void loadTopology()
    } catch (err) {
      setScanError(err instanceof Error ? err.message : 'Scan failed')
    } finally {
      setScanLoading(false)
    }
  }, [getAccessTokenSilently, loadTopology])

  const handleStun = useCallback(async () => {
    setStunLoading(true)
    setStunError(null)
    try {
      const token = await getAccessTokenSilently()
      const event = await stunFleetAgent(stunTarget, token)
      setStunLoaded(true)
      // Trigger cascade animation.
      setCascadeInProgress(event.affectedIds)
      void loadTopology()
    } catch (err) {
      setStunError(err instanceof Error ? err.message : 'Stun failed')
    } finally {
      setStunLoading(false)
    }
  }, [getAccessTokenSilently, stunTarget, loadTopology])

  const handleRecover = useCallback(async () => {
    setRecoverLoading(true)
    setRecoverError(null)
    setCascadeInProgress([])
    try {
      const token = await getAccessTokenSilently()
      await recoverFleet(token)
      setRecoverLoaded(true)
      void loadTopology()
    } catch (err) {
      setRecoverError(err instanceof Error ? err.message : 'Recover failed')
    } finally {
      setRecoverLoading(false)
    }
  }, [getAccessTokenSilently, loadTopology])

  const handleReset = useCallback(async () => {
    setResetLoading(true)
    setResetError(null)
    setCascadeInProgress([])
    try {
      const token = await getAccessTokenSilently()
      await resetFleet(token)
      setResetLoaded(true)
      void loadTopology()
    } catch (err) {
      setResetError(err instanceof Error ? err.message : 'Reset failed')
    } finally {
      setResetLoading(false)
    }
  }, [getAccessTokenSilently, loadTopology])

  // Computed summaries.
  const agents = topology?.agents ?? []
  const activeCount = agents.filter(a => a.state === 'active').length
  const stunnedCount = agents.filter(a => a.state === 'stunned').length
  const nonCompliantCount = agents.filter(a => a.state === 'non-compliant').length
  const stunnableAgents = agents.filter(a => a.type !== 'observability')

  const risk = topology?.aggregateRisk ?? { ale: 0, var95: 0, trend: 'stable' as const }

  const showControls = superadmin && !audience

  // Button style.
  const btn = (loading: boolean): React.CSSProperties => ({
    padding: '8px 16px',
    borderRadius: 8,
    border: '1px solid var(--border)',
    background: 'var(--surface)',
    color: 'var(--text)',
    fontSize: 13,
    fontWeight: 500,
    cursor: loading ? 'wait' : 'pointer',
    opacity: loading ? 0.6 : 1,
    fontFamily: 'inherit',
    transition: 'opacity 0.15s',
    width: '100%',
  })

  if (audience) {
    return (
      <div data-testid="fleet-demo-page" style={{ display: 'flex', height: '100vh', gap: 0 }}>
        <div style={{ flex: 1, position: 'relative' }}>
          <FleetTopology
            agents={agents}
            edges={topology?.edges ?? []}
            cascadeInProgress={cascadeInProgress}
            audience
          />
        </div>
        <div style={{
          width: 300,
          padding: 20,
          background: 'var(--surface)',
          borderLeft: '1px solid var(--border)',
          display: 'flex',
          flexDirection: 'column',
          gap: 16,
        }}>
          <FleetRiskGauge
            ale={risk.ale}
            var95={risk.var95}
            trend={risk.trend}
            previousAle={risk.previousAle}
          />
          <div style={{ fontSize: 12, color: 'var(--muted)', textAlign: 'center' }}>
            {agents.length} agents deployed
          </div>
        </div>
      </div>
    )
  }

  return (
    <div data-testid="fleet-demo-page">
      <h1 style={{ fontSize: 22, fontWeight: 700, color: 'var(--text)', marginBottom: 4 }}>
        Fleet Demo
      </h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 20 }}>
        Multi-agent SuperCredential fleet topology and cascade visualisation.
      </p>

      <div style={{ display: 'flex', gap: 24, minHeight: 500 }}>
        {/* Left panel: topology graph (60%) */}
        <div style={{ flex: 6, minWidth: 0 }}>
          <div style={{
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 12,
            height: '100%',
            minHeight: 500,
            overflow: 'hidden',
          }}>
            <FleetTopology
              agents={agents}
              edges={topology?.edges ?? []}
              cascadeInProgress={cascadeInProgress}
              onStun={showControls ? handleStun : undefined}
              onRecover={showControls ? handleRecover : undefined}
            />
          </div>
        </div>

        {/* Right panel: gauge + controls (40%) */}
        <div style={{ flex: 4, display: 'flex', flexDirection: 'column', gap: 16 }}>
          {/* Risk gauge */}
          <FleetRiskGauge
            ale={risk.ale}
            var95={risk.var95}
            trend={risk.trend}
            previousAle={risk.previousAle}
          />

          {/* Topology loading state */}
          <LoadingState
            status={loadPhase({ loading: topologyLoading, error, loaded: topologyLoaded })}
            label="fleet topology"
            error={error}
            onRetry={loadTopology}
            testId="fleet-topology-status"
          />

          {/* Fleet summary */}
          <div
            data-testid="fleet-summary"
            style={{
              padding: '12px 16px',
              borderRadius: 8,
              background: 'var(--surface)',
              border: '1px solid var(--border)',
              display: 'flex',
              flexWrap: 'wrap',
              gap: 16,
              fontSize: 13,
              color: 'var(--text)',
            }}
          >
            <span><strong>{agents.length}</strong> deployed</span>
            <span style={{ color: 'var(--cyan)' }}><strong>{activeCount}</strong> active</span>
            <span style={{ color: 'var(--error)' }}><strong>{stunnedCount}</strong> stunned</span>
            <span style={{ color: 'var(--amber)' }}><strong>{nonCompliantCount}</strong> non-compliant</span>
          </div>

          {/* Instructor controls (superadmin only) */}
          {showControls && (
            <div
              data-testid="fleet-controls"
              style={{
                padding: '16px',
                borderRadius: 12,
                background: 'var(--surface)',
                border: '1px solid var(--border)',
                display: 'flex',
                flexDirection: 'column',
                gap: 12,
              }}
            >
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
                Instructor Controls
              </div>

              {/* Deploy */}
              <button data-testid="fleet-deploy-btn" onClick={handleDeploy} disabled={deployLoading} style={btn(deployLoading)}>
                {deployLoading ? 'Deploying...' : 'Deploy Fleet'}
              </button>
              <LoadingState
                status={loadPhase({ loading: deployLoading, error: deployError, loaded: deployLoaded })}
                label="deploy"
                error={deployError}
                testId="fleet-deploy-status"
              />

              {/* Scan */}
              <button data-testid="fleet-scan-btn" onClick={handleScan} disabled={scanLoading} style={btn(scanLoading)}>
                {scanLoading ? 'Scanning...' : 'Scan Fleet'}
              </button>
              <LoadingState
                status={loadPhase({ loading: scanLoading, error: scanError, loaded: scanLoaded })}
                label="scan"
                error={scanError}
                testId="fleet-scan-status"
              />

              {/* Stun */}
              <div style={{ display: 'flex', gap: 8 }}>
                <select
                  data-testid="fleet-stun-select"
                  value={stunTarget}
                  onChange={e => setStunTarget(e.target.value)}
                  style={{
                    flex: 1,
                    padding: '8px 12px',
                    borderRadius: 8,
                    border: '1px solid var(--border)',
                    background: 'var(--surface)',
                    color: 'var(--text)',
                    fontSize: 13,
                    fontFamily: 'inherit',
                  }}
                >
                  {stunnableAgents.map(a => (
                    <option key={a.id} value={a.id}>{a.name}</option>
                  ))}
                  {stunnableAgents.length === 0 && (
                    <option value="agent-cardvault">agent-cardvault</option>
                  )}
                </select>
                <button data-testid="fleet-stun-btn" onClick={handleStun} disabled={stunLoading} style={{ ...btn(stunLoading), width: 'auto', whiteSpace: 'nowrap' }}>
                  {stunLoading ? 'Stunning...' : 'Stun'}
                </button>
              </div>
              <LoadingState
                status={loadPhase({ loading: stunLoading, error: stunError, loaded: stunLoaded })}
                label="stun"
                error={stunError}
                testId="fleet-stun-status"
              />

              {/* Recover */}
              <button data-testid="fleet-recover-btn" onClick={handleRecover} disabled={recoverLoading} style={btn(recoverLoading)}>
                {recoverLoading ? 'Recovering...' : 'Recover Fleet'}
              </button>
              <LoadingState
                status={loadPhase({ loading: recoverLoading, error: recoverError, loaded: recoverLoaded })}
                label="recover"
                error={recoverError}
                testId="fleet-recover-status"
              />

              {/* Reset */}
              <button data-testid="fleet-reset-btn" onClick={handleReset} disabled={resetLoading} style={btn(resetLoading)}>
                {resetLoading ? 'Resetting...' : 'Reset Fleet'}
              </button>
              <LoadingState
                status={loadPhase({ loading: resetLoading, error: resetError, loaded: resetLoaded })}
                label="reset"
                error={resetError}
                testId="fleet-reset-status"
              />
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
