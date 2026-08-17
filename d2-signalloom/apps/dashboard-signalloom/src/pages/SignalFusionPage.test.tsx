import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// Demo mode off — we drive mocked fetch calls, not fixture data.
vi.mock('../api/demoMode', () => ({
  isDemoMode: () => false,
  isProductionEnv: false,
  showDemoToggle: false,
}))

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

import SignalFusionPage from './SignalFusionPage'
import * as sfDemo from '../api/signalFusionDemo'
import * as weaveApiModule from '../api/weaveApi'
import type { DemoStep, DemoRunView, DemoRunLogChunk, DemoRunnerStatus } from '../api/signalFusionDemo'
import type { ProvisionalActor, CoverageStatement } from '../api/weaveApi'

// ─── Fixtures ───────────────────────────────────────────────────────────────

const STEPS: DemoStep[] = [
  { step_id: 'inferred', title: 'Inferred', description: 'Deploy, seed collectors, correlate' },
  { step_id: 'attested', title: 'Attested', description: 'Kernel observation — detect the agent' },
  { step_id: 'issued', title: 'Issued', description: 'Promote to issued identity, revoke' },
]

const IDLE_STATUS: DemoRunnerStatus = {
  active: null,
  recent: [],
  script_available: true,
}

const RUN_SUCCEEDED: DemoRunView = {
  run_id: 'run-001',
  step_id: 'inferred',
  kind: 'signalfusion',
  status: 'succeeded',
  started_at: '2026-08-16T10:00:00Z',
  finished_at: '2026-08-16T10:00:30Z',
  exit_code: 0,
}

const LOG_CHUNK: DemoRunLogChunk = {
  run_id: 'run-001',
  offset: 0,
  next_offset: 42,
  chunk: '[inferred] Deploying collectors...\n',
  truncated: false,
  eof: true,
}

const ACTORS: ProvisionalActor[] = [
  {
    id: 'actor-1',
    status: 'actionable',
    confidence: 0.87,
    evidence_chain: [
      {
        observation_id: 'obs-1',
        layer: 'network_egress',
        fidelity: 'strong',
        contribution: 'DNS anomaly',
        timestamp: '2026-08-16T09:00:00Z',
      },
    ],
    correlation_keys: ['ip:10.0.0.5'],
    created_at: '2026-08-16T09:00:00Z',
    updated_at: '2026-08-16T09:01:00Z',
    display_name: 'Suspicious Exfiltration Actor',
  },
]

const COVERAGE: CoverageStatement = {
  covered_layers: ['network_egress', 'identity_authorization', 'application_saas'],
  blind_spots: [
    { id: 'bs-1', layer: 'endpoint_host', description: 'No eBPF agent deployed' },
  ],
  closeable_by_issuance: ['endpoint_host'],
  deployment_coverage: '3 of 7 signal layers active',
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function renderPage() {
  return render(
    <MemoryRouter>
      <SignalFusionPage />
    </MemoryRouter>,
  )
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe('SignalFusionPage', () => {
  beforeEach(() => {
    vi.restoreAllMocks()
    // Re-arm the auth mock after restoreAllMocks clears it.
    getAccessTokenSilently.mockResolvedValue('test-token')
    // Default stubs — most tests override selectively.
    vi.spyOn(sfDemo, 'fetchSignalFusionSteps').mockResolvedValue(STEPS)
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue(IDLE_STATUS)
    vi.spyOn(sfDemo, 'startSignalFusionRun').mockResolvedValue({
      run_id: 'run-001',
      step_id: 'inferred',
      kind: 'signalfusion',
      status: 'running',
      started_at: '2026-08-16T10:00:00Z',
      finished_at: null,
      exit_code: null,
    })
    vi.spyOn(sfDemo, 'fetchSignalFusionRun').mockResolvedValue(RUN_SUCCEEDED)
    vi.spyOn(sfDemo, 'fetchSignalFusionRunLog').mockResolvedValue(LOG_CHUNK)
    vi.spyOn(sfDemo, 'resetSignalFusion').mockResolvedValue(RUN_SUCCEEDED)
    vi.spyOn(weaveApiModule.weaveApi, 'getActors').mockResolvedValue(ACTORS)
    vi.spyOn(weaveApiModule.weaveApi, 'getCoverage').mockResolvedValue(COVERAGE)
  })

  // ─── Rendering ──────────────────────────────────────────────────────────

  it('renders the page title', async () => {
    renderPage()
    expect(screen.getByText('Signal Fusion Demo')).toBeInTheDocument()
  })

  it('renders three act buttons after steps load', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })
    expect(screen.getByTestId('sf-act-attested')).toBeInTheDocument()
    expect(screen.getByTestId('sf-act-issued')).toBeInTheDocument()
  })

  it('shows act descriptions', async () => {
    renderPage()
    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })
    // The button or its surrounding area should show the title
    expect(screen.getByText('Inferred')).toBeInTheDocument()
    expect(screen.getByText('Attested')).toBeInTheDocument()
    expect(screen.getByText('Issued')).toBeInTheDocument()
  })

  // ─── Act execution ─────────────────────────────────────────────────────

  it('clicking an act button triggers the correct API call', async () => {
    const user = userEvent.setup()
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })

    await user.click(screen.getByTestId('sf-act-inferred'))

    await waitFor(() => {
      expect(sfDemo.startSignalFusionRun).toHaveBeenCalledWith('inferred', 'test-token')
    })
  })

  it('disables act buttons while a run is active', async () => {
    const user = userEvent.setup()
    // Return a running status so all buttons disable.
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockResolvedValue({
      active: {
        run_id: 'run-active',
        step_id: 'inferred',
        kind: 'signalfusion',
        status: 'running',
        started_at: '2026-08-16T10:00:00Z',
        finished_at: null,
        exit_code: null,
      },
      recent: [],
      script_available: true,
    })

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })

    // All act buttons should be disabled
    expect(screen.getByTestId('sf-act-inferred')).toBeDisabled()
    expect(screen.getByTestId('sf-act-attested')).toBeDisabled()
    expect(screen.getByTestId('sf-act-issued')).toBeDisabled()
  })

  // ─── Log output ─────────────────────────────────────────────────────────

  it('shows log output in the output panel after starting a run', async () => {
    const user = userEvent.setup()
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })

    await user.click(screen.getByTestId('sf-act-inferred'))

    await waitFor(() => {
      const logPanel = screen.getByTestId('sf-log-output')
      expect(logPanel.textContent).toContain('Deploying collectors')
    })
  })

  // ─── Error states ───────────────────────────────────────────────────────

  it('renders an error when start fails', async () => {
    const user = userEvent.setup()
    vi.spyOn(sfDemo, 'startSignalFusionRun').mockRejectedValue(new Error('500 — Internal error'))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-act-inferred')).toBeInTheDocument()
    })

    await user.click(screen.getByTestId('sf-act-inferred'))

    await waitFor(() => {
      expect(screen.getByTestId('sf-error')).toBeInTheDocument()
    })
    expect(screen.getByTestId('sf-error').textContent).toContain('500')
  })

  it('renders an error when the runner is not reachable', async () => {
    vi.spyOn(sfDemo, 'fetchSignalFusionSteps').mockRejectedValue(new Error('Network error'))
    vi.spyOn(sfDemo, 'fetchSignalFusionStatus').mockRejectedValue(new Error('Network error'))

    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-runner-error')).toBeInTheDocument()
    })
  })

  // ─── Results panel ──────────────────────────────────────────────────────

  it('shows actors in the results panel after loading', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-results-panel')).toBeInTheDocument()
    })

    expect(screen.getByText('Suspicious Exfiltration Actor')).toBeInTheDocument()
  })

  it('shows actor confidence with fidelity tier', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-actor-actor-1')).toBeInTheDocument()
    })

    // Confidence should be displayed as a percentage or score
    const actorEl = screen.getByTestId('sf-actor-actor-1')
    expect(actorEl.textContent).toContain('87')
  })

  it('shows evidence chain links per actor', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-actor-actor-1')).toBeInTheDocument()
    })

    const actorEl = screen.getByTestId('sf-actor-actor-1')
    expect(actorEl.textContent).toContain('DNS anomaly')
  })

  it('displays the coverage statement', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-coverage')).toBeInTheDocument()
    })

    expect(screen.getByTestId('sf-coverage').textContent).toContain('3 of 7')
  })

  it('shows blind spots in coverage', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-coverage')).toBeInTheDocument()
    })

    expect(screen.getByTestId('sf-coverage').textContent).toContain('No eBPF agent deployed')
  })

  // ─── Reset ──────────────────────────────────────────────────────────────

  it('has a reset button', async () => {
    renderPage()

    await waitFor(() => {
      expect(screen.getByTestId('sf-reset-btn')).toBeInTheDocument()
    })
  })
})
