import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import DistanceLatencyPage, {
  DISTANCE_LATENCY_PAGE_TITLE,
  ACT_DESCRIPTIONS,
} from './DistanceLatencyPage'
import * as dlDemo from '../api/distanceLatencyDemo'
import type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus } from '../api/distanceLatencyDemo'

const STEPS: DemoStep[] = [
  { step_id: '1', title: 'Spatial Topology', description: 'Discover agent topologies' },
  { step_id: '2', title: 'eBPF Kernel Probes', description: 'Attach eBPF tracepoints' },
  { step_id: '3', title: 'FrostDB Columnar Stream', description: 'Stream 31-column telemetry' },
  { step_id: '4', title: 'Quarantine Cascade', description: 'Enforce distance-weighted stun' },
]

const IDLE_STATUS: DemoRunnerStatus = {
  active: null,
  recent: [],
  script_available: true,
}

const RUN_SUCCEEDED: DemoRunView = {
  run_id: 'run-dl-001',
  step_id: '1',
  kind: 'step',
  status: 'succeeded',
  started_at: '2026-09-02T07:45:00Z',
  finished_at: '2026-09-02T07:45:10Z',
  exit_code: 0,
}

const LOG_CHUNK: DemoRunLogChunk = {
  run_id: 'run-dl-001',
  offset: 0,
  next_offset: 120,
  chunk: '[07:45:00Z] [distancelatency] Act 1: Discovering agent trust topology...\n[07:45:10Z] [distancelatency] ✓ Act 1 Complete\n',
  truncated: false,
  eof: true,
}

describe('DistanceLatencyPage', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    getAccessTokenSilently.mockResolvedValue('test-token')
    vi.spyOn(dlDemo, 'fetchDistanceLatencySteps').mockResolvedValue(STEPS)
    vi.spyOn(dlDemo, 'fetchDistanceLatencyStatus').mockResolvedValue(IDLE_STATUS)
    vi.spyOn(dlDemo, 'startDistanceLatencyRun').mockResolvedValue(RUN_SUCCEEDED)
    vi.spyOn(dlDemo, 'fetchDistanceLatencyRun').mockResolvedValue(RUN_SUCCEEDED)
    vi.spyOn(dlDemo, 'fetchDistanceLatencyRunLog').mockResolvedValue(LOG_CHUNK)
    vi.spyOn(dlDemo, 'resetDistanceLatency').mockResolvedValue({
      run_id: 'run-reset-01',
      step_id: '4',
      kind: 'reset',
      status: 'succeeded',
      started_at: '2026-09-02T07:45:00Z',
      finished_at: '2026-09-02T07:45:05Z',
      exit_code: 0,
    })
  })

  it('renders page header and stat cards', async () => {
    render(
      <MemoryRouter>
        <DistanceLatencyPage />
      </MemoryRouter>
    )

    await waitFor(() => {
      expect(screen.getByText(DISTANCE_LATENCY_PAGE_TITLE)).toBeInTheDocument()
    })

    expect(screen.getByText('Topology Tiers')).toBeInTheDocument()
    expect(screen.getByText('eBPF Resolution')).toBeInTheDocument()
    expect(screen.getByText('FrostDB Telemetry')).toBeInTheDocument()
    expect(screen.getByText('CEL Evaluation')).toBeInTheDocument()
    expect(screen.getByText('Stun Propagation')).toBeInTheDocument()
  })

  it('renders all four demo acts with run buttons', async () => {
    render(
      <MemoryRouter>
        <DistanceLatencyPage />
      </MemoryRouter>
    )

    await waitFor(() => {
      expect(screen.getByTestId('dl-act-row-1')).toBeInTheDocument()
    })

    expect(screen.getByTestId('dl-act-row-2')).toBeInTheDocument()
    expect(screen.getByTestId('dl-act-row-3')).toBeInTheDocument()
    expect(screen.getByTestId('dl-act-row-4')).toBeInTheDocument()

    expect(screen.getByTestId('run-act-1-btn')).toBeInTheDocument()
    expect(screen.getByTestId('run-act-2-btn')).toBeInTheDocument()
    expect(screen.getByTestId('run-act-3-btn')).toBeInTheDocument()
    expect(screen.getByTestId('run-act-4-btn')).toBeInTheDocument()
  })

  it('triggers act 1 execution and updates state', async () => {
    const user = userEvent.setup()
    render(
      <MemoryRouter>
        <DistanceLatencyPage />
      </MemoryRouter>
    )

    await waitFor(() => {
      expect(screen.getByTestId('run-act-1-btn')).toBeInTheDocument()
    })

    await user.click(screen.getByTestId('run-act-1-btn'))

    await waitFor(() => {
      expect(dlDemo.startDistanceLatencyRun).toHaveBeenCalledWith('1', 'test-token')
    })
  })

  it('renders the spatial distance topology table and frostdb feed', async () => {
    render(
      <MemoryRouter>
        <DistanceLatencyPage />
      </MemoryRouter>
    )

    await waitFor(() => {
      expect(screen.getByTestId('topology-node-kagent-chaos-prober')).toBeInTheDocument()
    })

    expect(screen.getByTestId('topology-node-kagent-security-analyst')).toBeInTheDocument()
    expect(screen.getByTestId('topology-node-agent-cardvault')).toBeInTheDocument()
    expect(screen.getByText('Chaos Prober')).toBeInTheDocument()
    expect(screen.getByText('FrostDB High-Cardinality Columnar Stream & Real-Time CEL Governance')).toBeInTheDocument()
  })
})
