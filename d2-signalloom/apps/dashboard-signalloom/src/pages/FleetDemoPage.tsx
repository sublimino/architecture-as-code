import { useState, useCallback, useEffect, useRef } from 'react'
import { useAppContext } from '../App'
import { useAuth0 } from '../auth/oidc'
import FleetTopology from '../components/fleet/FleetTopology'
import FleetRiskGauge from '../components/fleet/FleetRiskGauge'
import HelpHint from '../components/HelpHint'
import LoadingState, { loadPhase } from '../components/LoadingState'
import ButtonWait from '../components/ButtonWait'
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

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// Every control here already had a LoadingState beside it saying THAT it was
// running. None said for how long, which is the only thing anyone wants to
// know a minute into a fleet deploy against a real cluster.
//
// The private component that used to live here is now `ButtonWait` in
// components/, shared with the other three pages that had each grown their own
// version of it. Everything it decided — no visible word, a reserved width, an
// accessible name, no live region beside the LoadingState's — it still decides,
// and now decides identically everywhere. The `aria-label` ternary that used to
// sit on each of these five buttons went with it.

/** Fits the compact wait plus the button's padding — the Stun control is the
 *  one button here that sizes to its content rather than filling its column. */
const STUN_BUTTON_W = 110

// ─── Chrome ─────────────────────────────────────────────────────────────────
//
// These five controls used to carry a private `btn()` style function that
// reimplemented the shared button badly: --surface fill and a --border
// outline, where every other button in the product is a filled .btn-primary,
// .btn-secondary or .btn-danger. The result was a column of grey outlined
// boxes with no hierarchy, so Reset Fleet, which destroys the estate, read
// exactly like Scan Fleet, which reads it.
//
// Nothing here sets fill, border or colour any more. The only inline style
// left is layout: these buttons fill their column, and .btn does not
// centre a label it was never asked to stretch.

/** Layout-only. Every colour comes from the .btn classes. */
const FILL_COLUMN: React.CSSProperties = { width: '100%', justifyContent: 'center' }

/** A control and the hint that explains it, on one row. */
const CONTROL_ROW: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8 }

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
      {/* This page is presented from, live. The previous single line said
          "topology and cascade visualisation", which is a label rather than an
          explanation: it named the picture without saying what a card is, what
          a line is, what the money on the right is measuring, or that the
          buttons act on a real cluster with no confirmation step. Everything
          an instructor has to say out loud in the first thirty seconds is now
          on the page, and the running order, which is presenter guidance
          rather than product documentation, sits in the hint. */}
      <div data-testid="fleet-intro" style={{ maxWidth: 780, marginBottom: 20 }}>
        <p style={{ fontSize: 13, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.55 }}>
          A live SuperCredential fleet: every agent running in the cluster, drawn as the
          dependency graph the fleet manager actually serves. Each card is one workload agent
          with its team and its trust profile. Each line runs downward from an agent to whatever
          needs it, which makes the diagram a blast radius as well as a topology (revoke
          credentials at the top of a chain and everything below loses access too). Links into
          the SRE monitor are drawn differently, because the cascade deliberately stops there.
        </p>
        <p style={{ fontSize: 13, color: 'var(--muted)', margin: '0 0 8px', lineHeight: 1.55 }}>
          The figure on the right prices that exposure. <strong style={{ color: 'var(--text)' }}>ALE</strong> is
          Annual Loss Expectancy, what this fleet is modeled to cost in a typical year;{' '}
          <strong style={{ color: 'var(--text)' }}>VaR95</strong> is the bad year that only 1 in 20 exceeds.
          Both come from a FAIR simulation over the agents currently deployed and recompute on
          every poll, so stunning an agent moves a number a board recognizes rather than lighting
          up another red icon.
        </p>
        <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, lineHeight: 1.55, display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          <span>
            Instructor controls (superadmin only) act on the real cluster immediately, with no
            confirmation step. Check the hint beside a control before pressing it in front of
            an audience.
          </span>
          {showControls && (
            <HelpHint label="Suggested running order for this demo" testId="fleet-intro-help">
              Deploy fleet first, then Scan fleet to show the estate coming up clean. Stun the card
              vault and let the cascade run down the diagram while the loss figure climbs; that is
              the moment the demo exists for. Recover fleet puts everything back for the next
              audience. Leave Reset fleet until you are finished, because it tears the estate down
              to nothing and the next deploy has to build it again.
            </HelpHint>
          )}
        </p>
      </div>

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
              <div style={CONTROL_ROW}>
                <button
                  data-testid="fleet-deploy-btn"
                  className="btn btn-primary"
                  onClick={handleDeploy}
                  disabled={deployLoading}
                  style={FILL_COLUMN}
                >
                  {deployLoading ? <ButtonWait testId="fleet-deploy-loader" label="Deploying" /> : 'Deploy Fleet'}
                </button>
                <HelpHint label="What the Deploy control does" testId="fleet-deploy-help">
                  Asks the fleet manager to bring the whole estate up: one workload per agent on
                  the diagram, each with its own SPIFFE identity and its own OpenBao role. The call
                  returns as soon as the deployment is accepted, so the diagram filling in is what
                  tells you it finished, not the button.
                </HelpHint>
              </div>
              <LoadingState
                status={loadPhase({ loading: deployLoading, error: deployError, loaded: deployLoaded })}
                label="deploy"
                error={deployError}
                testId="fleet-deploy-status"
              />

              {/* Scan */}
              <div style={CONTROL_ROW}>
                <button
                  data-testid="fleet-scan-btn"
                  className="btn btn-secondary"
                  onClick={handleScan}
                  disabled={scanLoading}
                  style={FILL_COLUMN}
                >
                  {scanLoading ? <ButtonWait testId="fleet-scan-loader" label="Scanning" /> : 'Scan Fleet'}
                </button>
                <HelpHint label="What the Scan control does" testId="fleet-scan-help">
                  Runs a compliance sweep across every deployed agent and flags the ones that have
                  drifted out of policy, which shows up as the non-compliant count below and an
                  amber card on the diagram. It only reads state: nothing is revoked, and no agent
                  stops working.
                </HelpHint>
              </div>
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
                  // Layout only. global.css already themes `input, select,
                  // textarea`; the fill and border that used to be set here
                  // were --surface/--border against the stylesheet's
                  // --surface2/--border-subtle, so this was the one select in
                  // the product that matched no other.
                  style={{ flex: 1, minWidth: 0 }}
                >
                  {stunnableAgents.map(a => (
                    <option key={a.id} value={a.id}>{a.name}</option>
                  ))}
                  {stunnableAgents.length === 0 && (
                    <option value="agent-cardvault">agent-cardvault</option>
                  )}
                </select>
                {/* The only content-sized button in the column, and the one
                    that shares its row with a select — so it goes compact and
                    keeps a fixed min-width, or the select resizes under the
                    operator's cursor every time the figure gains a digit. */}
                <button
                  data-testid="fleet-stun-btn"
                  onClick={handleStun}
                  disabled={stunLoading}
                  className="btn btn-danger"
                  style={{ minWidth: STUN_BUTTON_W, whiteSpace: 'nowrap', justifyContent: 'center' }}
                >
                  {stunLoading ? <ButtonWait testId="fleet-stun-loader" label="Stunning" /> : 'Stun'}
                </button>
                <HelpHint label="What Stun does to the fleet" testId="fleet-stun-help">
                  Revokes the selected agent’s credentials and marks it stunned, then does the same to every agent that depends on it. That spreading failure is the cascade drawn on the left. The pods keep running; they simply cannot authenticate any more. Recover fleet puts it back.
                </HelpHint>
              </div>
              <LoadingState
                status={loadPhase({ loading: stunLoading, error: stunError, loaded: stunLoaded })}
                label="stun"
                error={stunError}
                testId="fleet-stun-status"
              />

              {/* Recover */}
              <div style={CONTROL_ROW}>
                <button
                  data-testid="fleet-recover-btn"
                  className="btn btn-secondary"
                  onClick={handleRecover}
                  disabled={recoverLoading}
                  style={FILL_COLUMN}
                >
                  {recoverLoading ? <ButtonWait testId="fleet-recover-loader" label="Recovering" /> : 'Recover Fleet'}
                </button>
                <HelpHint label="What Recover fleet does" testId="fleet-recover-help">
                  Restores credentials to every stunned agent and marks it running again, in dependency order so nothing is brought back before the agent it relies on. It reverses a stun; it does not redeploy anything that was torn down.
                </HelpHint>
              </div>
              <LoadingState
                status={loadPhase({ loading: recoverLoading, error: recoverError, loaded: recoverLoaded })}
                label="recover"
                error={recoverError}
                testId="fleet-recover-status"
              />

              {/* Reset */}
              <div style={CONTROL_ROW}>
                <button
                  data-testid="fleet-reset-btn"
                  className="btn btn-danger"
                  onClick={handleReset}
                  disabled={resetLoading}
                  style={FILL_COLUMN}
                >
                  {resetLoading ? <ButtonWait testId="fleet-reset-loader" label="Resetting" /> : 'Reset Fleet'}
                </button>
                <HelpHint label="What Reset fleet does" testId="fleet-reset-help">
                  Tears the whole fleet down and returns the estate to empty. Every agent on the diagram goes away, stunned or not, and the risk figure falls to zero because there is nothing left to lose. Deploy fleet builds it again from scratch.
                </HelpHint>
              </div>
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
