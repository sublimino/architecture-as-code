import { useState, useCallback, useEffect, useMemo, useRef } from 'react'
import { useAppContext } from '../App'
import { useAuth0 } from '../auth/oidc'
import FleetTopology from '../components/fleet/FleetTopology'
import FleetRiskGauge from '../components/fleet/FleetRiskGauge'
import FleetBadge, { stateToken, trustToken } from '../components/fleet/FleetBadge'
import HelpHint from '../components/HelpHint'
import LoadingState, { loadPhase } from '../components/LoadingState'
import ButtonWait from '../components/ButtonWait'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import ErrorState from '../components/ErrorState'
import { StatCard, Section } from '../components/DashKit'
import type { AgentState, FleetTopology as FleetTopologyData } from '../api/fleetApi'
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

/** Rows per page in the roster. A demo fleet is five to twelve agents, so this
 *  shows the whole estate at once and the pager stays hidden until it cannot. */
const ROSTER_PAGE_SIZE = 10

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

// ─── Roster ─────────────────────────────────────────────────────────────────
//
// The fleet's agents were already on this page, drawn as cards on the diagram.
// What the diagram cannot do is sort, filter, or be read from the back of a
// room by someone who wants to find one workload by name, and two of the six
// fields the API returns for every agent — `team` and the workload ID the Stun
// control actually sends — were not on screen anywhere at all.
//
// So this is the same data in the medium that answers those questions, on the
// shared DataTable. No new request: `topology.agents` is the array the poll has
// been fetching since this page was written.

interface RosterRow {
  id: string
  name: string
  type: string
  team: string
  trustProfile: AgentState['trustProfile']
  state: AgentState['state']
}

const ROSTER_COLUMNS: Column<RosterRow>[] = [
  { key: 'name', label: 'Agent', sortable: true },
  {
    key: 'id',
    label: 'Workload ID',
    sortable: true,
    help:
      'The name the fleet manager knows this agent by, and the exact value the Stun ' +
      'control sends. It is the last part of the agent’s SPIFFE ID rather than a ' +
      'display label, which is why it is spelled differently from the Agent column.',
  },
  {
    key: 'type',
    label: 'Type',
    sortable: true,
    help:
      'What the workload does. Type decides which OpenBao role it is issued and which ' +
      'icon it draws on the diagram. Observability agents are the one type that cannot ' +
      'be stunned, which is why the cascade stops at the SRE monitor.',
  },
  {
    key: 'team',
    label: 'Team',
    sortable: true,
    help:
      'Who owns the workload. It carries no policy weight today; it is here because a ' +
      'cascade is a list of people to call, and that list is otherwise nowhere on screen.',
  },
  {
    key: 'trustProfile',
    label: 'Trust',
    sortable: true,
    help:
      'How far the fleet manager trusts this workload’s attestation. High is fully ' +
      'attested hardware identity, low rests on weaker evidence and so contributes more ' +
      'to the loss figure. High trust is good, which is the opposite of high risk.',
  },
  {
    key: 'state',
    label: 'State',
    sortable: true,
    help:
      'Where the agent stands right now. Active is authenticating normally, ' +
      'non-compliant has drifted out of policy but still works, and stunned has had its ' +
      'credentials revoked and cannot authenticate at all. The colors match the diagram.',
  },
]

/** Trust profiles, worst last, so the filter reads in the order that matters. */
const TRUST_PROFILES: AgentState['trustProfile'][] = ['high', 'medium', 'low']

/** The sentinel every filter uses for "do not narrow on this". */
const ALL = 'all'

const SEARCH_INPUT: React.CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  minWidth: 230,
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
}

/**
 * A filter chip, selected or not.
 *
 * Tinted fill plus a full-strength border rather than a solid accent fill: text
 * on solid cyan fails AA in at least one of the three themes. Lifted from the
 * DataTable specimen on DesignSystemPage so the ten pages migrating in parallel
 * grow the same chip.
 */
function chipStyle(selected: boolean): React.CSSProperties {
  return {
    fontSize: 11.5,
    padding: '4px 9px',
    borderRadius: 4,
    cursor: 'pointer',
    color: selected ? 'var(--cyan)' : 'var(--muted)',
    background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
    border: `1px solid ${selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)'}`,
  }
}

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

  // Roster filters. Presentation state only: it narrows an array that is
  // already in memory and never reaches the fleet manager.
  const [rosterSearch, setRosterSearch] = useState('')
  const [rosterState, setRosterState] = useState<string>(ALL)
  const [rosterTrust, setRosterTrust] = useState<string>(ALL)

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

  // ── Reachability ────────────────────────────────────────────────────────
  //
  // Three outcomes have to look like three things, and two of them are easy to
  // collapse into one by accident. `agents` is `[]` when the fleet manager says
  // the estate is empty AND when it never answered, because a failed poll
  // leaves `topology` null. Rendering "no agents" for both is the exact failure
  // FleetUnreachableError exists to prevent: nginx's SPA catch-all answers an
  // unproxied /fleet-api/ with 200 and index.html, so `res.ok` is true for a
  // reply that is not this API at all, and a page that trusted it would show a
  // healthy empty fleet to a room while the backend was simply absent.
  //
  // `topology === null` is the discriminator, not `agents.length`. A poll that
  // fails AFTER a good load keeps the last known estate on screen and lets the
  // LoadingState beside it carry the error, because blanking a live demo on one
  // dropped request is its own failure.
  const unreachable = error !== null && topology === null

  // ── Roster rows ─────────────────────────────────────────────────────────

  // Keyed on `topology`, not on `agents`. `agents` is `topology?.agents ?? []`,
  // which mints a fresh array on every render, so a memo depending on it would
  // recompute on every one of them — twice a second, forever, given the poll.
  // `topology` is the state value and only changes when a fetch resolves.
  // Deliberately NOT fixed by memoizing `agents` itself: that array is handed
  // to FleetTopology, whose layout effects key on it, and stabilizing its
  // identity would quietly change how often the diagram re-lays-out.
  const rosterRows: RosterRow[] = useMemo(
    () => (topology?.agents ?? []).map(a => ({
      id: a.id,
      name: a.name,
      type: a.type,
      team: a.team,
      trustProfile: a.trustProfile,
      state: a.state,
    })),
    [topology],
  )

  /** States actually present, in the API's own order of severity. */
  const rosterStates = useMemo(() => {
    const seen = new Set(rosterRows.map(r => r.state))
    return (['active', 'non-compliant', 'grace-period', 'stunned', 'deploying', 'absent'] as const)
      .filter(s => seen.has(s))
  }, [rosterRows])

  const stateCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const row of rosterRows) counts[row.state] = (counts[row.state] ?? 0) + 1
    return counts
  }, [rosterRows])

  const trustCounts = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const row of rosterRows) counts[row.trustProfile] = (counts[row.trustProfile] ?? 0) + 1
    return counts
  }, [rosterRows])

  /**
   * The predicate, which is the one thing DataTable can never own.
   *
   * Search spans the four text fields an operator would actually type at: the
   * display name, the workload ID the Stun control sends, the type and the
   * owning team. Trust and state are not searched because they have their own
   * controls, and a free-text "low" matching a trust profile would silently
   * fight the chip beside it.
   */
  const filteredRoster = useMemo(() => {
    const needle = rosterSearch.trim().toLowerCase()
    return rosterRows.filter(row => {
      if (rosterState !== ALL && row.state !== rosterState) return false
      if (rosterTrust !== ALL && row.trustProfile !== rosterTrust) return false
      if (!needle) return true
      return (
        row.name.toLowerCase().includes(needle) ||
        row.id.toLowerCase().includes(needle) ||
        row.type.toLowerCase().includes(needle) ||
        row.team.toLowerCase().includes(needle)
      )
    })
  }, [rosterRows, rosterSearch, rosterState, rosterTrust])

  const filtersActive = rosterSearch.trim() !== '' || rosterState !== ALL || rosterTrust !== ALL

  const clearRosterFilters = useCallback(() => {
    setRosterSearch('')
    setRosterState(ALL)
    setRosterTrust(ALL)
  }, [])

  if (audience) {
    // This variant is what goes on the projector, and it is the one place a
    // silent failure is most expensive and least likely to be noticed: it had
    // no error surface at all, so an unreachable fleet manager rendered as an
    // empty diagram beside a risk gauge reading zero — a picture of a perfectly
    // healthy estate with nothing in it, in front of a room. The shared
    // ErrorState replaces the whole view rather than sitting in a corner,
    // because at projector distance a corner is not read.
    if (unreachable) {
      return (
        <div
          data-testid="fleet-demo-page"
          style={{ display: 'flex', height: '100vh', alignItems: 'center', justifyContent: 'center' }}
        >
          <div data-testid="fleet-audience-unreachable">
            <ErrorState message={error} onRetry={loadTopology} />
          </div>
        </div>
      )
    }

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

          {/* Fleet summary.
              Four counts that were a row of coloured words in a bordered box
              that existed nowhere else in the product. They are now DashKit
              StatCards, the same primitive the Federated Services and Collusion
              & Access dashboards count with, and the accents are unchanged —
              cyan active, red stunned, amber non-compliant — because they are
              the diagram's colours and changing them here would desynchronise
              the two halves of the screen. */}
          <div data-testid="fleet-summary">
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
                Fleet Counts
              </span>
              <HelpHint label="What these fleet counts mean" testId="fleet-summary-help">
                Deployed is every agent the fleet manager is holding, whatever state it is in, so it
                is the total the other three divide up. Active is authenticating normally, stunned has
                had its credentials revoked by you or by a cascade, and non-compliant has drifted out
                of policy but is still working. The three do not have to add up to deployed: an agent
                still coming up counts in none of them.
              </HelpHint>
            </div>
            {unreachable ? (
              // Four cards reading "0 deployed, 0 active, 0 stunned, 0
              // non-compliant" is a picture of a clean, empty estate, and it is
              // what this block drew while the ErrorState below it said the
              // fleet manager had never answered. Two contradictory claims on
              // one screen, and the confident one is the lie: nobody counted
              // anything, because nobody replied. A count you do not have is
              // not zero.
              <div
                data-testid="fleet-summary-unreachable"
                className="card"
                style={{ padding: '14px 16px', fontSize: 12.5, color: 'var(--muted)' }}
              >
                No counts. The fleet manager did not answer, so this is not a fleet of zero
                agents; it is a fleet nobody has heard from.
              </div>
            ) : (
              // A 2x2 grid rather than flex wrap. DashKit's StatCard carries
              // `flex: 1; min-width: 180`, which in this 40%-width column fits
              // three across and drops the fourth onto a full-bleed row of its
              // own, so "Non-compliant" rendered three times the width of
              // "Stunned" and read as the most important number here.
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 10 }}>
                <StatCard label="Deployed" value={String(agents.length)} sub="agents deployed" accent="var(--text)" />
                <StatCard label="Active" value={String(activeCount)} sub="active and authenticating" accent="var(--cyan)" />
                <StatCard label="Stunned" value={String(stunnedCount)} sub="credentials revoked" accent="var(--error)" />
                <StatCard label="Non-compliant" value={String(nonCompliantCount)} sub="drifted out of policy" accent="var(--amber)" />
              </div>
            )}
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
                <HelpHint label="What the Deploy Fleet control does" testId="fleet-deploy-help">
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
                <HelpHint label="What the Scan Fleet control does" testId="fleet-scan-help">
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
                <HelpHint label="What the Stun control does" testId="fleet-stun-help">
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
                <HelpHint label="What the Recover Fleet control does" testId="fleet-recover-help">
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
                <HelpHint label="What the Reset Fleet control does" testId="fleet-reset-help">
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

      {/* ── Fleet roster ────────────────────────────────────────────────────
          The diagram answers "what depends on what". It cannot answer "which
          agents does the AI team own", "what is the workload ID I have to type
          into Stun", or "show me only the low-trust ones", and those are the
          questions asked from the floor. Same array, same poll, sortable. */}
      <Section
        title="Fleet roster"
        hint="the same agents the diagram draws, as rows you can sort and narrow"
      >
        {unreachable ? (
          // NOT an EmptyState. A fleet manager that never answered and a fleet
          // manager that answered "nothing deployed" are different claims, and
          // only one of them means the demo is broken. Filters over an estate
          // nobody has heard from would be theater, so the toolbar goes too.
          <div data-testid="fleet-roster-unreachable">
            <ErrorState message={error} onRetry={loadTopology} />
          </div>
        ) : (
          <DataTable
            columns={ROSTER_COLUMNS}
            data={filteredRoster}
            pageSize={ROSTER_PAGE_SIZE}
            testIdPrefix="fleet-roster"
            toolbar={
              <div
                style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
                role="group"
                aria-label="Filter the fleet roster"
              >
                <input
                  type="search"
                  aria-label="Search the fleet roster"
                  placeholder="Search agent, ID, type or team…"
                  value={rosterSearch}
                  onChange={e => setRosterSearch(e.target.value)}
                  data-testid="fleet-roster-search"
                  style={SEARCH_INPUT}
                />

                <button
                  type="button"
                  onClick={() => setRosterState(ALL)}
                  aria-pressed={rosterState === ALL}
                  data-testid="fleet-roster-filter-all"
                  style={chipStyle(rosterState === ALL)}
                >
                  all states <span style={{ color: 'var(--dim)' }}>{rosterRows.length}</span>
                </button>
                {rosterStates.map(state => {
                  const selected = rosterState === state
                  return (
                    <button
                      key={state}
                      type="button"
                      onClick={() => setRosterState(state)}
                      aria-pressed={selected}
                      data-testid={`fleet-roster-filter-${state}`}
                      style={chipStyle(selected)}
                    >
                      {state} <span style={{ color: 'var(--dim)' }}>{stateCounts[state] ?? 0}</span>
                    </button>
                  )
                })}

                {/* A select rather than three more chips. Two chip rows read as
                    one row of eight controls with no grouping, and global.css
                    already themes every select in the product. */}
                <select
                  aria-label="Filter the fleet roster by trust profile"
                  value={rosterTrust}
                  onChange={e => setRosterTrust(e.target.value)}
                  data-testid="fleet-roster-trust"
                  style={{ fontSize: 12 }}
                >
                  <option value={ALL}>All trust profiles</option>
                  {TRUST_PROFILES.map(profile => (
                    <option key={profile} value={profile}>
                      {profile} trust ({trustCounts[profile] ?? 0})
                    </option>
                  ))}
                </select>

                {filtersActive && (
                  <button
                    type="button"
                    className="btn btn-secondary"
                    onClick={clearRosterFilters}
                    data-testid="fleet-roster-clear"
                    style={{ fontSize: 11.5, padding: '4px 9px' }}
                  >
                    Clear filters
                  </button>
                )}

                <span data-testid="fleet-roster-count" style={{ fontSize: 11.5, color: 'var(--muted)' }}>
                  {filteredRoster.length} of {rosterRows.length} shown
                </span>

                <HelpHint label="What the roster filters do" testId="fleet-roster-help">
                  Every control here narrows the table in the browser and nothing else. No request
                  reaches the fleet manager, the diagram beside it keeps drawing the whole estate, and
                  the counts above stay counts of the whole fleet rather than of what is on screen.
                  Filtering during a demo is safe; it changes what you are looking at and never what
                  the cluster is doing.
                </HelpHint>
              </div>
            }
            emptyState={
              filtersActive ? (
                <EmptyState
                  kicker="No agents match those filters"
                  body="Clear the search box, choose all states, or pick a different trust profile."
                />
              ) : (
                <EmptyState
                  tone="amber"
                  kicker="No agents deployed"
                  body="The fleet manager answered, and the estate is empty. Deploy Fleet builds it."
                />
              )
            }
            renderRow={(row: RosterRow) => (
              <tr
                key={row.id}
                data-testid={`fleet-roster-row-${row.id}`}
                style={{ borderBottom: '1px solid var(--border)' }}
              >
                <td style={DataTable.td}>{row.name}</td>
                <td style={{ ...DataTable.td, color: 'var(--muted)' }}>{row.id}</td>
                <td style={DataTable.td}>{row.type}</td>
                <td style={DataTable.td}>{row.team}</td>
                <td style={DataTable.td}>
                  <FleetBadge label={row.trustProfile} token={trustToken(row.trustProfile)} />
                </td>
                <td style={DataTable.td}>
                  <FleetBadge label={row.state} token={stateToken(row.state)} />
                </td>
              </tr>
            )}
          />
        )}
      </Section>
    </div>
  )
}
