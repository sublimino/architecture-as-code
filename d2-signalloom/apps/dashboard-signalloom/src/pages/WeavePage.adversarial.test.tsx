/**
 * Adversarial rendering tests for WeavePage and its sub-components.
 *
 * Attack vectors:
 * 1. Coverage panel with corrupted data — empty blind_spots, missing fields, 50 blind spots
 * 2. Actor display with adversarial data — confidence > 1.0, < 0, empty evidence, 100 links
 * 3. Evidence with unknown layers — layers not in the LAYER_COLORS map
 * 4. Error state rendering — verifies the error prop is displayed
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type {
  SignalObservation,
  ProvisionalActor,
  CoverageStatement,
  EvidenceLink,
  BlindSpot,
} from '../api/weaveApi'

// ── Mocks ──────────────────────────────────────────────────────────────────

const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

const mockGetObservations = vi.fn()
const mockGetActors = vi.fn()
const mockGetCoverage = vi.fn()

vi.mock('../api/weaveApi', async () => {
  const actual = await vi.importActual<typeof import('../api/weaveApi')>('../api/weaveApi')
  return {
    ...actual,
    weaveApi: {
      getObservations: (...args: unknown[]) => mockGetObservations(...args),
      getActors: (...args: unknown[]) => mockGetActors(...args),
      getCoverage: (...args: unknown[]) => mockGetCoverage(...args),
      promoteActor: vi.fn(),
      runCorrelation: vi.fn(),
    },
  }
})

vi.mock('../api/signalFusionDemo', () => ({
  fetchSignalFusionSteps: vi.fn().mockResolvedValue([]),
  startSignalFusionRun: vi.fn().mockResolvedValue({ run_id: 'run-test', status: 'running' }),
  fetchSignalFusionRunLog: vi.fn().mockResolvedValue({ chunk: '', next_offset: 0, eof: true }),
  fetchSignalFusionStatus: vi.fn().mockResolvedValue({ active_run: null }),
  resetSignalFusion: vi.fn().mockResolvedValue({ run_id: 'run-reset', status: 'running' }),
  fetchSignalFusionRun: vi.fn().mockResolvedValue({ run_id: 'run-test', status: 'completed' }),
}))

// ── Helpers ────────────────────────────────────────────────────────────────

function makeObservation(overrides: Partial<SignalObservation> = {}): SignalObservation {
  return {
    id: 'obs-001',
    timestamp: '2026-08-15T10:00:00Z',
    layer: 'network_egress',
    fidelity: 'strong',
    source: 'hubble',
    confidence: 0.8,
    raw_evidence_ref: 'ref-001',
    description: 'Outbound connection to suspicious IP',
    ...overrides,
  }
}

function makeActor(overrides: Partial<ProvisionalActor> = {}): ProvisionalActor {
  return {
    id: 'actor-001',
    status: 'actionable',
    confidence: 0.75,
    evidence_chain: [
      {
        observation_id: 'obs-001',
        layer: 'network_egress',
        fidelity: 'strong',
        contribution: 'Outbound C2 traffic detected',
        timestamp: '2026-08-15T10:00:00Z',
      },
    ],
    correlation_keys: ['ip:10.0.0.1'],
    created_at: '2026-08-15T09:00:00Z',
    updated_at: '2026-08-15T10:00:00Z',
    ...overrides,
  }
}

function makeCoverage(overrides: Partial<CoverageStatement> = {}): CoverageStatement {
  return {
    covered_layers: ['network_egress', 'identity_authorization'],
    blind_spots: [
      { id: 'bs-001', layer: 'network_egress', description: 'Loopback not visible' },
    ],
    closeable_by_issuance: ['bs-001'],
    deployment_coverage: '2 of 7 layers active',
    ...overrides,
  }
}

async function renderWeavePage() {
  const WeavePage = (await import('./WeavePage')).default
  return render(<WeavePage />)
}

// ── Setup ──────────────────────────────────────────────────────────────────

beforeEach(() => {
  vi.clearAllMocks()
  mockGetObservations.mockResolvedValue([makeObservation()])
  mockGetActors.mockResolvedValue([makeActor()])
  mockGetCoverage.mockResolvedValue(makeCoverage())
})

afterEach(() => {
  // Do NOT call vi.restoreAllMocks() — it restores module-level mocks
  // like signalFusionDemo, causing `steps` to become undefined when a
  // queued microtask re-renders after cleanup.
})

// ── 1. Coverage panel with corrupted data ──────────────────────────────────

describe('CoverageHonestyPanel adversarial data', () => {
  it('renders with empty blind_spots array', async () => {
    mockGetCoverage.mockResolvedValue(makeCoverage({
      blind_spots: [],
      closeable_by_issuance: [],
    }))

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const panel = screen.getByTestId('coverage-panel')
    expect(panel).toBeInTheDocument()
    // With zero blind spots, each layer row shows "---" for its blind spot column.
    // The panel renders without crashing — that's the adversarial concern.
    expect(panel.textContent).toContain('---')
  })

  it('renders with 50 blind spots without crashing', async () => {
    const manyBlindSpots: BlindSpot[] = Array.from({ length: 50 }, (_, i) => ({
      id: `bs-${String(i).padStart(3, '0')}`,
      layer: 'network_egress' as const,
      description: `Blind spot number ${i}`,
    }))

    mockGetCoverage.mockResolvedValue(makeCoverage({
      blind_spots: manyBlindSpots,
      closeable_by_issuance: ['bs-000', 'bs-001'],
    }))

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('coverage-panel')).toBeInTheDocument()
    })

    // All 50 should be accessible in the DOM (the panel doesn't paginate)
    const panel = screen.getByTestId('coverage-panel')
    expect(panel.textContent).toContain('50')
  })

  it('renders when closeable_by_issuance references non-existent blind spot IDs', async () => {
    mockGetCoverage.mockResolvedValue(makeCoverage({
      blind_spots: [
        { id: 'bs-001', layer: 'network_egress', description: 'Real spot' },
      ],
      closeable_by_issuance: ['bs-001', 'bs-nonexistent', 'bs-also-missing'],
    }))

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('coverage-panel')).toBeInTheDocument()
    })

    // The panel counts closeable_by_issuance.length (3) even though only 1 exists
    // PINNED: no validation that closeable IDs reference real blind spots
    const panel = screen.getByTestId('coverage-panel')
    expect(panel.textContent).toContain('3')
    expect(panel.textContent).toContain('1')
  })
})

// ── 2. Actor display with adversarial data ──────────────────────────────────

describe('ActorCard adversarial rendering', () => {
  it('renders actor with confidence > 1.0 without crashing', async () => {
    /**
     * FINDING: confidence=1.5 produces confidencePct=150 and the bar
     * width becomes "150%" which overflows the container.  The bar
     * element uses `overflow: hidden` on the parent so the visual
     * overflow is clipped, but the percentage text reads "150%" which
     * is misleading.
     */
    mockGetActors.mockResolvedValue([makeActor({ confidence: 1.5 })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    // The text contains "150%" — PINNED as current behaviour
    expect(card.textContent).toContain('150%')
  })

  it('renders actor with confidence < 0 without crashing', async () => {
    /**
     * FINDING: confidence=-0.5 produces confidencePct=-50 and the bar
     * width becomes "-50%". CSS treats negative widths as 0 so the bar
     * is invisible, but the text reads "-50%" which is misleading.
     */
    mockGetActors.mockResolvedValue([makeActor({ confidence: -0.5 })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('-50%')
  })

  it('renders actor with confidence=0 correctly', async () => {
    mockGetActors.mockResolvedValue([makeActor({ confidence: 0 })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('0%')
  })

  it('renders actor with empty evidence_chain', async () => {
    /**
     * Empty evidence chain: layerCount becomes 0 from
     * `new Set([].map(...)).size`, and the metadata reads
     * "0 observations" / "0 layers" — renders without crashing.
     */
    mockGetActors.mockResolvedValue([makeActor({ evidence_chain: [] })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('0 observations')
    expect(card.textContent).toContain('0 layers')
  })

  it('renders actor with 100 evidence links', async () => {
    const manyLinks: EvidenceLink[] = Array.from({ length: 100 }, (_, i) => ({
      observation_id: `obs-${i}`,
      layer: (['network_egress', 'identity_authorization', 'application_saas'] as const)[i % 3],
      fidelity: 'strong' as const,
      contribution: `Evidence item ${i}`,
      timestamp: `2026-08-15T${String(10 + Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}:00Z`,
    }))

    mockGetActors.mockResolvedValue([makeActor({ evidence_chain: manyLinks })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('100 observations')
    expect(card.textContent).toContain('3 layers')
  })

  it('renders actor with unknown status gracefully', async () => {
    /**
     * STATUS_COLORS uses Record<string, string> with a fallback:
     * `STATUS_COLORS[actor.status] ?? 'var(--dim)'`
     * So an unknown status gets 'var(--dim)' — no crash.
     */
    mockGetActors.mockResolvedValue([makeActor({
      status: 'unknown-status' as ProvisionalActor['status'],
    })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const badge = screen.getByTestId('actor-status-badge')
    expect(badge).toBeInTheDocument()
    expect(badge.textContent).toContain('unknown-status')
  })
})

// ── 3. EvidenceDrawer with adversarial data ──────────────────────────────────

describe('EvidenceDrawer adversarial rendering', () => {
  it('renders evidence with unknown layer without crashing', async () => {
    /**
     * FINDING: LAYER_COLORS[link.layer] returns undefined for an unknown
     * layer, which means the colour is undefined and rendered as no colour.
     * LAYER_LABELS[link.layer] also returns undefined, so the label badge
     * displays "undefined".
     */
    const unknownLayerEvidence: EvidenceLink[] = [
      {
        observation_id: 'obs-unknown',
        layer: 'quantum_entanglement' as unknown as EvidenceLink['layer'],
        fidelity: 'definitive',
        contribution: 'Quantum signal detected',
        timestamp: '2026-08-15T10:00:00Z',
      },
    ]

    mockGetActors.mockResolvedValue([makeActor({ evidence_chain: unknownLayerEvidence })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    // Click "View Evidence" to open the drawer
    const viewBtn = screen.getByTestId('view-evidence-btn')
    await userEvent.click(viewBtn)

    await waitFor(() => {
      expect(screen.getByTestId('evidence-drawer')).toBeInTheDocument()
    })

    // The evidence item renders — the unknown layer produces undefined labels
    // PINNED: no fallback for unknown layers
    const item = screen.getByTestId('evidence-item')
    expect(item).toBeInTheDocument()
  })

  it('renders empty evidence chain in drawer without crashing', async () => {
    mockGetActors.mockResolvedValue([makeActor({ evidence_chain: [] })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const viewBtn = screen.getByTestId('view-evidence-btn')
    await userEvent.click(viewBtn)

    await waitFor(() => {
      expect(screen.getByTestId('evidence-drawer')).toBeInTheDocument()
    })

    // Drawer opens but no evidence items
    const items = screen.queryAllByTestId('evidence-item')
    expect(items).toHaveLength(0)
  })

  it('drawer close button works', async () => {
    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    // Open drawer
    const viewBtn = screen.getByTestId('view-evidence-btn')
    await userEvent.click(viewBtn)

    await waitFor(() => {
      expect(screen.getByTestId('evidence-drawer')).toBeInTheDocument()
    })

    // Close it
    const closeBtn = screen.getByTestId('evidence-drawer-close')
    await userEvent.click(closeBtn)

    await waitFor(() => {
      expect(screen.queryByTestId('evidence-drawer')).not.toBeInTheDocument()
    })
  })
})

// ── 4. Signal observations with adversarial fidelity values ──────────────────

describe('SignalThread adversarial rendering', () => {
  it('renders observation with unknown fidelity tier', async () => {
    /**
     * FINDING: FIDELITY_SIZES[obs.fidelity] returns undefined for an unknown
     * fidelity, so the dot size becomes "undefinedpx" — CSS treats this as
     * zero, rendering an invisible dot. No crash, but silent data loss.
     */
    mockGetObservations.mockResolvedValue([makeObservation({
      fidelity: 'omniscient' as unknown as SignalObservation['fidelity'],
    })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const threads = screen.getByTestId('signal-threads')
    expect(threads).toBeInTheDocument()
  })

  it('renders observation with confidence > 1.0', async () => {
    /**
     * FINDING: opacity = 0.4 + confidence * 0.6
     * With confidence=2.0: opacity = 0.4 + 1.2 = 1.6
     * CSS clamps opacity to [0, 1], so visually it's fine.
     * But the semantic meaning is wrong — confidence should be [0, 1].
     */
    mockGetObservations.mockResolvedValue([makeObservation({ confidence: 2.0 })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })
  })
})

// ── 5. Error state rendering ──────────────────────────────────────────────────

describe('WeavePage error state', () => {
  it('displays error message when API fails', async () => {
    mockGetObservations.mockRejectedValue(new Error('Network down'))

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-load-state')).toBeInTheDocument()
    })

    expect(screen.getByTestId('weave-load-state').textContent).toContain('Network down')
  })

  it('displays generic error for non-Error throw', async () => {
    mockGetObservations.mockRejectedValue('string error')

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-load-state')).toBeInTheDocument()
    })

    // The catch block: `err instanceof Error ? err.message : 'Failed to load signal data.'`
    expect(screen.getByTestId('weave-load-state').textContent).toContain('Failed to load signal data')
  })
})

// ── 6. Stat cards with null coverage ──────────────────────────────────────────

describe('WeavePage stat cards with null coverage', () => {
  it('handles null coverage gracefully using nullish coalescing', async () => {
    mockGetCoverage.mockResolvedValue(null)

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    // coverage?.blind_spots.length ?? 0 should give 0
    // coverage?.covered_layers.length ?? 0 should give 0
    // coverage?.closeable_by_issuance.length ?? 0 should give 0
    // The coverage panel should NOT render (conditional: {coverage && <CoverageHonestyPanel>})
    expect(screen.queryByTestId('coverage-panel')).not.toBeInTheDocument()
  })
})

// ── 7. Actor with no display_name ──────────────────────────────────────────

describe('Actor display_name fallback', () => {
  it('falls back to actor.id when display_name is undefined', async () => {
    mockGetActors.mockResolvedValue([makeActor({ display_name: undefined })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('actor-001')
  })

  it('renders display_name when present', async () => {
    mockGetActors.mockResolvedValue([makeActor({ display_name: 'Shadow LLM Proxy' })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    const card = screen.getByTestId('actor-card')
    expect(card.textContent).toContain('Shadow LLM Proxy')
  })
})

// ── 8. Promote button visibility ──────────────────────────────────────────

describe('Promote button conditional rendering', () => {
  it('shows promote button only for actionable actors', async () => {
    mockGetActors.mockResolvedValue([makeActor({ status: 'actionable' })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    expect(screen.getByTestId('promote-actor-btn')).toBeInTheDocument()
  })

  it('hides promote button for provisional actors', async () => {
    mockGetActors.mockResolvedValue([makeActor({ status: 'provisional' })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    expect(screen.queryByTestId('promote-actor-btn')).not.toBeInTheDocument()
  })

  it('hides promote button for promoted actors', async () => {
    mockGetActors.mockResolvedValue([makeActor({ status: 'promoted' })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    expect(screen.queryByTestId('promote-actor-btn')).not.toBeInTheDocument()
  })

  it('hides promote button for dismissed actors', async () => {
    mockGetActors.mockResolvedValue([makeActor({ status: 'dismissed' })])

    await renderWeavePage()
    await waitFor(() => {
      expect(screen.getByTestId('weave-page')).toBeInTheDocument()
    })

    expect(screen.queryByTestId('promote-actor-btn')).not.toBeInTheDocument()
  })
})
