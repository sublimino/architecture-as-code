/**
 * DistanceLatencyPage — Distance-Focused Latency, eBPF Sentinel & FrostDB Telemetry Demo.
 *
 * Built on the shared vocabulary of SuperCred and Signal Fusion:
 *   - StatCard telemetry topbar
 *   - 4-Act Instructor Runner with HelpHint, PixelLoader, ButtonWait, StreamingLogBlock
 *   - Live Spatial Topology Distance Matrix
 *   - High-Cardinality FrostDB Columnar Telemetry Feed
 *   - Real-Time CEL Governance Benchmark
 */
import { useState, useCallback, useEffect, useRef, type CSSProperties } from 'react'
import { Link } from 'react-router-dom'
import { colors } from '../styles/tokens'
import { Section, StatCard, Pill } from '../components/DashKit'
import HelpHint from '../components/HelpHint'
import PixelLoader from '../components/PixelLoader'
import ButtonWait from '../components/ButtonWait'
import LoadingState from '../components/LoadingState'
import StreamingLogBlock from '../components/StreamingLogBlock'
import {
  RUN_STATUS_COLORS,
  describeRunnerError,
  logTail,
  runStartedAt,
  runStatusTone,
} from '../components/demoRunPresentation'
import { useAuth0 } from '../auth/oidc'
import {
  fetchDistanceLatencySteps,
  fetchDistanceLatencyStatus,
  fetchDistanceLatencyRun,
  fetchDistanceLatencyRunLog,
  startDistanceLatencyRun,
  resetDistanceLatency,
  shellCommandForAct,
} from '../api/distanceLatencyDemo'
import type {
  DemoStep,
  DemoRunView,
  DemoRunLogChunk,
  DemoRunnerStatus,
} from '../api/distanceLatencyDemo'
import { isRunActive, isRunFailure } from '../api/demoRunner'

// ─── Types & Constants ──────────────────────────────────────────────────────

export const DISTANCE_LATENCY_PAGE_TITLE = 'Distance-Focused Latency & Telemetry'

export const DISTANCE_LATENCY_ACT_IDS = ['1', '2', '3', '4'] as const

export interface ActDescription {
  title: string
  subtitle: string
  hint: string
}

export const ACT_DESCRIPTIONS: Record<string, ActDescription> = {
  '1': {
    title: 'Spatial Topology',
    subtitle: 'Discover agent topologies, SPIFFE trust domains, and measure baseline topological distances',
    hint: 'Queries all agent pods across namespaces, discovers SPIFFE workload IDs, and maps out the 5-tier spatial distance matrix.',
  },
  '2': {
    title: 'eBPF Kernel Probes',
    subtitle: 'Attach eBPF tracepoints and capture microsecond socket/packet transport delays',
    hint: 'Activates kernel-level latency probes in stun-sentinel, measuring TCP handshake and packet transit delays with sub-microsecond precision.',
  },
  '3': {
    title: 'FrostDB Columnar Stream',
    subtitle: 'Stream 31-column Apache Arrow telemetry batches and evaluate real-time CEL governance',
    hint: 'Ingests high-cardinality telemetry records into the FrostDB columnar ring buffer and benchmarks CEL policy rules (CPU, memory, SVID freshness) in microseconds.',
  },
  '4': {
    title: 'Quarantine Cascade',
    subtitle: 'Enforce distance-weighted policy actions and sub-millisecond stun isolation',
    hint: 'Simulates a cross-domain latency anomaly from an unauthorized workload and executes a sub-millisecond eBPF stun and SVID revocation cascade.',
  },
}

export interface TopologyNode {
  id: string
  name: string
  spiffeId: string
  namespace: string
  hopDistance: number
  latencyUs: number
  transport: string
  status: 'optimal' | 'monitored' | 'warning' | 'isolated'
}

export const INITIAL_TOPOLOGY: TopologyNode[] = [
  {
    id: 'kagent-chaos-prober',
    name: 'Chaos Prober',
    spiffeId: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-chaos-prober',
    namespace: 'fe-signalloom-agents',
    hopDistance: 0,
    latencyUs: 120,
    transport: 'eBPF RingBuffer Direct',
    status: 'optimal',
  },
  {
    id: 'kagent-security-analyst',
    name: 'Security Analyst',
    spiffeId: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-security-analyst',
    namespace: 'fe-signalloom-agents',
    hopDistance: 1,
    latencyUs: 480,
    transport: 'Intra-Cluster CNI',
    status: 'optimal',
  },
  {
    id: 'kagent-k8s-reader',
    name: 'K8s Reader',
    spiffeId: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-k8s-reader',
    namespace: 'fe-signalloom-agents',
    hopDistance: 1,
    latencyUs: 440,
    transport: 'Intra-Cluster CNI',
    status: 'optimal',
  },
  {
    id: 'agent-cardvault',
    name: 'Card Vault Agent',
    spiffeId: 'spiffe://signalloom.demo/ns/inf-signalloom/sa/cardvault',
    namespace: 'inf-signalloom',
    hopDistance: 2,
    latencyUs: 1150,
    transport: 'Cross-Namespace mTLS',
    status: 'monitored',
  },
  {
    id: 'external-gateway',
    name: 'External Cloud Gateway',
    spiffeId: 'spiffe://signalloom.demo/edge/cloud/agent/external-gateway',
    namespace: 'edge-gateway',
    hopDistance: 4,
    latencyUs: 14800,
    transport: 'Envoy Edge Mesh',
    status: 'warning',
  },
]

export interface TelemetryRow {
  timestamp: string
  agentId: string
  spiffeId: string
  cpuPct: number
  memMb: number
  celRule: string
  celEvalUs: number
  status: 'passed' | 'warn' | 'reject'
}

export const INITIAL_TELEMETRY: TelemetryRow[] = [
  {
    timestamp: '07:45:10.120',
    agentId: 'kagent-chaos-prober',
    spiffeId: 'spiffe://signalloom.demo/.../kagent-chaos-prober',
    cpuPct: 12.4,
    memMb: 48.2,
    celRule: 'no-sensitive-cred-leaks',
    celEvalUs: 34,
    status: 'passed',
  },
  {
    timestamp: '07:45:11.140',
    agentId: 'kagent-security-analyst',
    spiffeId: 'spiffe://signalloom.demo/.../kagent-security-analyst',
    cpuPct: 94.2,
    memMb: 148.2,
    celRule: 'cpu-throttling-governance',
    celEvalUs: 58,
    status: 'warn',
  },
  {
    timestamp: '07:45:12.890',
    agentId: 'agent-cardvault',
    spiffeId: 'spiffe://signalloom.demo/.../cardvault',
    cpuPct: 22.1,
    memMb: 82.5,
    celRule: 'spiffe-workload-attestation',
    celEvalUs: 42,
    status: 'passed',
  },
]

const POLL_MS = 500
const LOG_WAIT_SECONDS = 3

// ─── Styles ─────────────────────────────────────────────────────────────────

const CONTROL_WITH_HINT: CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 6,
  flexWrap: 'nowrap',
}

const actRow: CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  justifyContent: 'space-between',
  gap: 12,
  padding: '12px 16px',
  borderRadius: 6,
  border: '1px solid var(--border)',
  background: 'var(--surface)',
  marginBottom: 10,
}

const tableHeaderStyle: CSSProperties = {
  textAlign: 'left',
  padding: '8px 12px',
  fontSize: 11,
  textTransform: 'uppercase',
  color: 'var(--muted)',
  borderBottom: '1px solid var(--border)',
}

const tableCellStyle: CSSProperties = {
  padding: '10px 12px',
  fontSize: 12,
  borderBottom: '1px solid rgba(255, 255, 255, 0.05)',
  fontFamily: 'inherit',
}

// ─── Component ──────────────────────────────────────────────────────────────

export default function DistanceLatencyPage() {
  const { getAccessTokenSilently } = useAuth0()

  const [steps, setSteps] = useState<DemoStep[]>([])
  const [activeRun, setActiveRun] = useState<DemoRunView | null>(null)
  const [recentRuns, setRecentRuns] = useState<DemoRunView[]>([])
  const [scriptAvailable, setScriptAvailable] = useState<boolean | null>(null)
  const [logChunks, setLogChunks] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [runningStepId, setRunningStepId] = useState<string | null>(null)
  const [isResetting, setIsResetting] = useState(false)
  const [topologyNodes, setTopologyNodes] = useState<TopologyNode[]>(INITIAL_TOPOLOGY)
  const [telemetryFeed, setTelemetryFeed] = useState<TelemetryRow[]>(INITIAL_TELEMETRY)

  const logOffsetRef = useRef(0)

  // 1. Initial Load
  const loadStatus = useCallback(async () => {
    try {
      const token = await getAccessTokenSilently().catch(() => undefined)
      const [stepsData, statusData] = await Promise.all([
        fetchDistanceLatencySteps(token).catch(() => []),
        fetchDistanceLatencyStatus(token).catch(() => ({
          active: null,
          recent: [],
          script_available: true,
        })),
      ])

      setSteps(
        stepsData.length > 0
          ? stepsData
          : DISTANCE_LATENCY_ACT_IDS.map(id => ({
              step_id: id,
              title: ACT_DESCRIPTIONS[id]?.title ?? `Act ${id}`,
              description: ACT_DESCRIPTIONS[id]?.subtitle ?? '',
            }))
      )

      setActiveRun(statusData.active)
      setRecentRuns(statusData.recent)
      setScriptAvailable(statusData.script_available)
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load status')
    } finally {
      setLoading(false)
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    loadStatus()
  }, [loadStatus])

  // 2. Poll Active Run & Stream Logs
  useEffect(() => {
    if (!activeRun || !isRunActive(activeRun)) return

    let cancelled = false

    const pollInterval = setInterval(async () => {
      try {
        const token = await getAccessTokenSilently().catch(() => undefined)
        const updated = await fetchDistanceLatencyRun(activeRun.run_id, token)
        if (!cancelled) {
          setActiveRun(updated)
          if (!isRunActive(updated)) {
            setRunningStepId(null)
            loadStatus()
          }
        }
      } catch {
        // tolerate transient poll failures
      }
    }, POLL_MS)

    const logPoll = async () => {
      while (!cancelled && activeRun && isRunActive(activeRun)) {
        try {
          const token = await getAccessTokenSilently().catch(() => undefined)
          const chunk: DemoRunLogChunk = await fetchDistanceLatencyRunLog(
            activeRun.run_id,
            logOffsetRef.current,
            LOG_WAIT_SECONDS,
            token
          )
          if (!cancelled && chunk.chunk) {
            setLogChunks(prev => [...prev, chunk.chunk])
            logOffsetRef.current = chunk.next_offset
          }
        } catch {
          await new Promise(r => setTimeout(r, 1000))
        }
      }
    }

    logPoll()

    return () => {
      cancelled = true
      clearInterval(pollInterval)
    }
  }, [activeRun?.run_id, activeRun?.status, getAccessTokenSilently, loadStatus])

  // 3. Start Act
  const handleStartAct = async (stepId: string) => {
    setRunningStepId(stepId)
    setLogChunks([])
    logOffsetRef.current = 0
    try {
      const token = await getAccessTokenSilently().catch(() => undefined)
      const run = await startDistanceLatencyRun(stepId, token)
      setActiveRun(run)

      // Dynamic visual enhancements per act
      if (stepId === '1') {
        setTopologyNodes(prev =>
          prev.map(n => ({
            ...n,
            latencyUs: Math.max(80, n.latencyUs - Math.floor(Math.random() * 20)),
          }))
        )
      } else if (stepId === '2') {
        setTopologyNodes(prev =>
          prev.map(n =>
            n.hopDistance <= 1 ? { ...n, status: 'optimal', transport: 'eBPF Kernel XDP' } : n
          )
        )
      } else if (stepId === '3') {
        const now = new Date()
        const nowStr = now.toTimeString().split(' ')[0] + '.' + String(now.getMilliseconds()).padStart(3, '0')
        setTelemetryFeed(prev => [
          {
            timestamp: nowStr,
            agentId: 'kagent-finops-optimizer',
            spiffeId: 'spiffe://signalloom.demo/.../kagent-finops',
            cpuPct: 8.5,
            memMb: 36.4,
            celRule: 'distance-weighted-cost-optimization',
            celEvalUs: 28,
            status: 'passed',
          },
          ...prev.slice(0, 5),
        ])
      } else if (stepId === '4') {
        setTopologyNodes(prev =>
          prev.map(n =>
            n.id === 'external-gateway'
              ? { ...n, status: 'isolated', latencyUs: 0, transport: 'STUN Isolated' }
              : n
          )
        )
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : `Failed to start act ${stepId}`)
      setRunningStepId(null)
    }
  }

  // 4. Reset Demo
  const handleReset = async () => {
    setIsResetting(true)
    try {
      const token = await getAccessTokenSilently().catch(() => undefined)
      await resetDistanceLatency(token)
      setTopologyNodes(INITIAL_TOPOLOGY)
      setTelemetryFeed(INITIAL_TELEMETRY)
      setLogChunks([])
      logOffsetRef.current = 0
      await loadStatus()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to reset demo')
    } finally {
      setIsResetting(false)
    }
  }

  if (loading) {
    return <LoadingState status="loading" label="Distance Latency demo" testId="dl-loading" />
  }

  return (
    <div style={{ maxWidth: 1200, margin: '0 auto', paddingBottom: 60 }} data-testid="distance-latency-page">
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <h1 style={{ fontSize: 24, fontWeight: 700, margin: '0 0 6px 0', color: 'var(--text)' }}>
            {DISTANCE_LATENCY_PAGE_TITLE}
          </h1>
          <p style={{ margin: 0, color: 'var(--muted)', fontSize: 13 }}>
            Continuous Spatial Topology Profiling, eBPF Kernel Latency Probes & High-Cardinality FrostDB Telemetry
          </p>
        </div>
        <div style={CONTROL_WITH_HINT}>
          <button
            onClick={handleReset}
            disabled={isResetting || isRunActive(activeRun)}
            className="btn btn-secondary"
            style={{ fontSize: 12, padding: '6px 14px' }}
            data-testid="reset-distance-latency-btn"
          >
            {isResetting ? 'Resetting...' : 'Reset Demo State'}
          </button>
          <HelpHint label="Reset explanation" testId="dl-reset-hint">
            Clears the active latency state, restores baseline trust domain matrix, and purges the live FrostDB NDJSON buffer.
          </HelpHint>
        </div>
      </div>

      {error && (
        <div style={{ background: 'rgba(248, 81, 73, 0.1)', border: '1px solid var(--error)', padding: '12px 16px', borderRadius: 6, marginBottom: 20, color: 'var(--error)', fontSize: 13 }}>
          {error}
        </div>
      )}

      {/* Telemetry Stat Cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 14, marginBottom: 24 }}>
        <StatCard label="Topology Tiers" value="5 Tiers" sub="Local to Edge Mesh" accent={colors.cyanLoom} />
        <StatCard label="eBPF Resolution" value="< 1 µs" sub="Kernel Tracepoint Jitter" accent={colors.tealLoom} />
        <StatCard label="FrostDB Telemetry" value="31 Columns" sub="Apache Arrow Columnar Ingestion" accent={colors.irisViolet} />
        <StatCard label="CEL Evaluation" value="34-58 µs" sub="Real-time Policy Micro-benchmark" accent={colors.cyanLoom} />
        <StatCard label="Stun Propagation" value="0.84 ms" sub="Sub-millisecond Quarantine" accent={colors.amber} />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 24, marginBottom: 24 }}>
        {/* Left: 4-Act Instructor Runner */}
        <Section title="Interactive 4-Act Demonstration Runner" hint="Sequential execution flow across discovery, eBPF probes, FrostDB telemetry, and quarantine">
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {DISTANCE_LATENCY_ACT_IDS.map(actId => {
              const actInfo = ACT_DESCRIPTIONS[actId]
              const isRunning = runningStepId === actId || (activeRun?.step_id === actId && isRunActive(activeRun))
              const recent = recentRuns.find(r => r.step_id === actId)

              return (
                <div key={actId} style={actRow} data-testid={`dl-act-row-${actId}`}>
                  <div style={{ flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                      <span style={{ fontWeight: 700, fontSize: 14, color: 'var(--text)' }}>
                        Act {actId}: {actInfo.title}
                      </span>
                      {isRunning && <PixelLoader />}
                      {recent && !isRunning && (
                        <Pill label={recent.status} />
                      )}
                    </div>
                    <p style={{ margin: '0 0 6px 0', fontSize: 12, color: 'var(--muted)', lineHeight: 1.4 }}>
                      {actInfo.subtitle}
                    </p>
                    <div style={{ fontSize: 11, color: 'var(--teal)', fontFamily: 'monospace' }}>
                      {shellCommandForAct(actId)}
                    </div>
                  </div>

                  <div style={CONTROL_WITH_HINT}>
                    <button
                      onClick={() => handleStartAct(actId)}
                      disabled={isRunActive(activeRun)}
                      className="btn btn-primary"
                      style={{ fontSize: 12, padding: '6px 14px', whiteSpace: 'nowrap' }}
                      data-testid={`run-act-${actId}-btn`}
                    >
                      {isRunning ? <ButtonWait label={`Running Act ${actId}`} testId={`dl-wait-${actId}`} /> : `Run Act ${actId}`}
                    </button>
                    <HelpHint label={`Act ${actId} Help`} testId={`dl-act-${actId}-hint`}>
                      {actInfo.hint}
                    </HelpHint>
                  </div>
                </div>
              )
            })}
          </div>
        </Section>

        {/* Right: Spatial Topology Matrix */}
        <Section title="Spatial Distance & Latency Matrix" hint="Live hop count and round-trip transport latencies across SPIFFE workload domains">
          <div style={{ background: 'var(--surface)', borderRadius: 6, border: '1px solid var(--border)', overflow: 'hidden' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr>
                  <th style={tableHeaderStyle}>Workload / SPIFFE SVID</th>
                  <th style={tableHeaderStyle}>Hops</th>
                  <th style={tableHeaderStyle}>RTT Latency</th>
                  <th style={tableHeaderStyle}>Transport</th>
                  <th style={tableHeaderStyle}>Status</th>
                </tr>
              </thead>
              <tbody>
                {topologyNodes.map(node => (
                  <tr key={node.id} data-testid={`topology-node-${node.id}`}>
                    <td style={tableCellStyle}>
                      <div style={{ fontWeight: 600, color: 'var(--text)' }}>
                        <Link
                          to={`/agents/${encodeURIComponent(node.id)}?tab=overview`}
                          data-testid={`spatial-node-link-${node.id}`}
                          style={{ color: 'var(--text)', textDecoration: 'none' }}
                          onMouseEnter={(e) => (e.currentTarget.style.color = 'var(--cyan)')}
                          onMouseLeave={(e) => (e.currentTarget.style.color = 'var(--text)')}
                        >
                          {node.name}
                        </Link>
                      </div>
                      <div style={{ fontSize: 10, color: 'var(--muted)', fontFamily: 'monospace' }}>
                        {node.namespace}
                      </div>
                    </td>
                    <td style={tableCellStyle}>
                      <span style={{ fontWeight: 600, color: node.hopDistance === 0 ? 'var(--teal)' : 'var(--text)' }}>
                        {node.hopDistance}
                      </span>
                    </td>
                    <td style={tableCellStyle}>
                      <span style={{ fontFamily: 'monospace', fontWeight: 600, color: node.latencyUs > 5000 ? 'var(--amber)' : node.latencyUs === 0 ? 'var(--error)' : 'var(--teal)' }}>
                        {node.latencyUs === 0 ? 'STUNNED' : node.latencyUs < 1000 ? `${node.latencyUs} µs` : `${(node.latencyUs / 1000).toFixed(2)} ms`}
                      </span>
                    </td>
                    <td style={tableCellStyle}>
                      <span style={{ fontSize: 11, color: 'var(--muted)' }}>{node.transport}</span>
                    </td>
                    <td style={tableCellStyle}>
                      <Pill label={node.status} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Section>
      </div>

      {/* FrostDB Columnar Telemetry Stream & CEL Policy Engine */}
      <Section title="FrostDB High-Cardinality Columnar Stream & Real-Time CEL Governance" hint="Continuous Apache Arrow columnar record ingestion and sub-millisecond CEL expression benchmarking">
        <div style={{ background: 'var(--surface)', borderRadius: 6, border: '1px solid var(--border)', overflow: 'hidden', marginBottom: 24 }}>
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr>
                <th style={tableHeaderStyle}>Timestamp</th>
                <th style={tableHeaderStyle}>Agent / SPIFFE Subject</th>
                <th style={tableHeaderStyle}>CPU Usage</th>
                <th style={tableHeaderStyle}>Memory RSS</th>
                <th style={tableHeaderStyle}>Active CEL Rule</th>
                <th style={tableHeaderStyle}>Eval Duration</th>
                <th style={tableHeaderStyle}>Verdict</th>
              </tr>
            </thead>
            <tbody>
              {telemetryFeed.map((row, idx) => (
                <tr key={idx}>
                  <td style={{ ...tableCellStyle, fontFamily: 'monospace', color: 'var(--muted)' }}>{row.timestamp}</td>
                  <td style={tableCellStyle}>
                    <div style={{ fontWeight: 600, color: 'var(--text)' }}>
                      <Link
                        to={`/agents/${encodeURIComponent(row.agentId)}?tab=overview`}
                        data-testid={`frostdb-agent-link-${row.agentId}`}
                        style={{ color: 'var(--text)', textDecoration: 'none' }}
                        onMouseEnter={(e) => (e.currentTarget.style.color = 'var(--cyan)')}
                        onMouseLeave={(e) => (e.currentTarget.style.color = 'var(--text)')}
                      >
                        {row.agentId}
                      </Link>
                    </div>
                    <div style={{ fontSize: 10, color: 'var(--muted)', fontFamily: 'monospace' }}>{row.spiffeId}</div>
                  </td>
                  <td style={{ ...tableCellStyle, fontFamily: 'monospace' }}>
                    <span style={{ color: row.cpuPct > 80 ? 'var(--amber)' : 'var(--text)' }}>{row.cpuPct.toFixed(1)}%</span>
                  </td>
                  <td style={{ ...tableCellStyle, fontFamily: 'monospace' }}>{row.memMb.toFixed(1)} MB</td>
                  <td style={{ ...tableCellStyle, fontFamily: 'monospace', fontSize: 11, color: 'var(--cyan)' }}>
                    {row.celRule}
                  </td>
                  <td style={{ ...tableCellStyle, fontFamily: 'monospace', color: 'var(--teal)', fontWeight: 600 }}>
                    {row.celEvalUs} µs
                  </td>
                  <td style={tableCellStyle}>
                    <Pill label={row.status.toUpperCase()} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      {/* Live Streaming Log Output */}
      <Section title="Live Demonstration Output Stream" hint="Real-time terminal stream forwarded from the in-cluster demo runner daemon">
        <StreamingLogBlock
          log={logChunks.join('') || 'Awaiting demonstration act execution. Click any act above to start streaming output.'}
          title={activeRun ? `Act ${activeRun.step_id} Output` : 'Execution Log'}
        />
      </Section>
    </div>
  )
}
