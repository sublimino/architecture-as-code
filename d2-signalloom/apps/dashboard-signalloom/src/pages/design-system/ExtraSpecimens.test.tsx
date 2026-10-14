import { act, fireEvent, render, screen, within } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api } from '../../api/client'
import { EXTRA_SPECIMEN_NAMES, ExtraSpecimens } from './ExtraSpecimens'
import { FIXTURE_CURRENCY_CONTEXT_VALUE } from './fixtureCurrency'

vi.mock('../../auth/oidc', () => ({
  useAuth0: () => ({
    user: { sub: 'fixture-reviewer' },
    isAuthenticated: true,
    getAccessTokenSilently: vi.fn().mockResolvedValue('fixture-token'),
  }),
}))

const EXPECTED_NAMES = [
  'DelegationAttestationDrawer',
  'AuthorizationProofDrawer',
  'WhoAuthorizedPanel',
  'FleetRiskGauge',
  'FleetTopology',
  'NotificationBell',
  'TriageMenu',
  'CredentialEvidencePanel',
  'IdentityAuditPanel',
  'ComplianceDrawer',
  'SetupBanner',
  'ProviderConfigureStep',
  'DiscoveredWorkloadDrawer',
  'SignalBadge',
  'EvidenceDrawer',
  'OpenFindingsPanel',
  'TelemetryErrorBoundary',
  'NodeDetailDrawer',
  'TrustGraph',
  'TrustTopologyCanvas',
  'CredentialActionsMenu',
  'AuditDetailDrawer',
  'AddClusterModal',
] as const

const EXPECTED_DEFERRALS = [
  'ClaimModal',
  'SignalFusionDemoControls',
  'AgentEvidenceDrawer',
  'OnboardingWizard',
  'AgentCockpitSection',
  'RbacImporterPanel',
  'SuperCredInstructorPanel',
  'AgentCockpitTelemetry',
  'CookieSettingsModal',
  'MetricsTopBar',
  'ConsentModal',
  'KeyboardShortcutsOverlay',
] as const

afterEach(() => vi.restoreAllMocks())

describe('ExtraSpecimens', () => {
  it('exports one frozen inert currency value for the parent gallery', async () => {
    const getPreferences = vi.spyOn(api.userPreferences, 'get')
    const patchCurrency = vi.spyOn(api.userPreferences, 'patchCurrency')
    const importedAgain = (await import('./fixtureCurrency')).FIXTURE_CURRENCY_CONTEXT_VALUE

    FIXTURE_CURRENCY_CONTEXT_VALUE.ensureLoaded()
    await FIXTURE_CURRENCY_CONTEXT_VALUE.setCurrency('GBP')

    expect(importedAgain).toBe(FIXTURE_CURRENCY_CONTEXT_VALUE)
    expect(Object.isFrozen(FIXTURE_CURRENCY_CONTEXT_VALUE)).toBe(true)
    expect(FIXTURE_CURRENCY_CONTEXT_VALUE.currency).toBeNull()
    expect(getPreferences).not.toHaveBeenCalled()
    expect(patchCurrency).not.toHaveBeenCalled()
  })

  it('publishes exactly the names of its mounted production specimens', () => {
    render(<ExtraSpecimens />)

    expect(EXTRA_SPECIMEN_NAMES).toEqual(EXPECTED_NAMES)
    for (const name of EXTRA_SPECIMEN_NAMES) {
      const specimen = screen.getByTestId(`extra-specimen-${name}`)
      expect(within(specimen).getByText(name, { selector: 'strong' })).toBeInTheDocument()
      expect(specimen).toHaveAttribute('data-source', expect.stringContaining('/'))
    }
  })

  it('renders authenticated visual children without requesting backend preferences', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const getPreferences = vi.spyOn(api.userPreferences, 'get').mockResolvedValue({ display_currency: 'USD' })
    const patchCurrency = vi.spyOn(api.userPreferences, 'patchCurrency').mockResolvedValue({ display_currency: 'USD' })
    render(<ExtraSpecimens />)
    await act(async () => undefined)

    expect(screen.getByTestId('fleet-risk-gauge')).toHaveTextContent('Medium Risk')
    expect(screen.getByTestId('fleet-topology')).toBeInTheDocument()
    expect(screen.getByTestId('identity-audit-panel')).toHaveTextContent('OpenBao & SPIRE')
    expect(screen.getByTestId('credential-evidence-panel')).toHaveTextContent('No evidence has been collected yet')
    expect(screen.getByTestId('open-findings-panel')).toHaveTextContent('Workload identity')
    expect(screen.getByTestId('extra-trust-graph-size')).toContainElement(screen.getByTestId('trust-graph-container'))
    expect(screen.getByTestId('extra-trust-canvas-size').querySelector('[data-testid="trust-canvas"]')).toBeInTheDocument()
    expect(getPreferences).not.toHaveBeenCalled()
    expect(patchCurrency).not.toHaveBeenCalled()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('renders genuine routed components beneath an existing application router', () => {
    render(<MemoryRouter><ExtraSpecimens /></MemoryRouter>)

    expect(screen.getByText('2 of 4 providers connected')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Set up GitHub' })).toBeInTheDocument()
  })

  it('keeps the parent gallery route when the setup specimen continues', () => {
    function LocationProbe() {
      return <output data-testid="fixture-location">{useLocation().pathname}</output>
    }

    render(
      <MemoryRouter initialEntries={['/design-system/lab']}>
        <ExtraSpecimens />
        <LocationProbe />
      </MemoryRouter>,
    )

    fireEvent.click(within(screen.getByTestId('extra-specimen-SetupBanner')).getByRole('button', { name: 'Complete setup' }))
    expect(screen.getByTestId('fixture-location')).toHaveTextContent('/design-system/lab')
  })

  it('opens one genuine overlay at a time and closes it locally', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    render(<ExtraSpecimens />)

    fireEvent.click(screen.getByRole('button', { name: 'Open DelegationAttestationDrawer specimen' }))
    expect(screen.getByRole('dialog', { name: 'Attestation & Landlock Verification' })).toHaveTextContent('gallery-action-01')

    fireEvent.click(screen.getByRole('button', { name: 'Open ComplianceDrawer specimen' }))
    expect(screen.queryByRole('dialog', { name: 'Attestation & Landlock Verification' })).not.toBeInTheDocument()
    expect(screen.getByTestId('compliance-drawer')).toHaveTextContent('SLSA gallery baseline')

    fireEvent.click(screen.getByTestId('compliance-drawer-close'))
    expect(screen.queryByTestId('compliance-drawer')).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('does not register the production keyboard overlay global listener', () => {
    render(<ExtraSpecimens />)

    fireEvent.keyDown(window, { key: '?' })
    expect(screen.queryByRole('dialog', { name: /keyboard shortcuts/i })).not.toBeInTheDocument()
    expect(screen.getByTestId('extra-deferral-KeyboardShortcutsOverlay')).toHaveTextContent('global window keydown listener')
  })

  it('opens every local overlay in the rendering document without backend requests', () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const { container } = render(<ExtraSpecimens />)
    const overlays = [
      ['DelegationAttestationDrawer', 'delegation-attestation-drawer', 'close-attestation-drawer'],
      ['AuthorizationProofDrawer', 'authorization-proof-drawer', 'close-proof-drawer'],
      ['ComplianceDrawer', 'compliance-drawer', 'compliance-drawer-close'],
      ['DiscoveredWorkloadDrawer', 'discovered-workload-drawer', 'drawer-close-btn'],
      ['EvidenceDrawer', 'evidence-drawer', 'evidence-drawer-close'],
      ['NodeDetailDrawer', 'node-detail-drawer', 'node-drawer-close-btn'],
      ['AuditDetailDrawer', 'audit-detail-drawer', 'audit-detail-drawer-close'],
    ] as const

    for (const [name, overlayTestId, closeTestId] of overlays) {
      fireEvent.click(screen.getByRole('button', { name: `Open ${name} specimen` }))
      const overlay = screen.getByTestId(overlayTestId)
      expect(overlay.ownerDocument).toBe(container.ownerDocument)
      fireEvent.click(screen.getByTestId(closeTestId))
      expect(screen.queryByTestId(overlayTestId)).not.toBeInTheDocument()
    }

    fireEvent.click(screen.getByRole('button', { name: 'Open AddClusterModal specimen' }))
    const modal = screen.getByTestId('add-cluster-modal')
    expect(modal.ownerDocument).toBe(container.ownerDocument)
    fireEvent.click(within(modal).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByTestId('add-cluster-modal')).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('reports precise source-backed deferrals for unsafe components', () => {
    render(<ExtraSpecimens />)

    for (const name of EXPECTED_DEFERRALS) {
      expect(screen.getByTestId(`extra-deferral-${name}`)).not.toBeEmptyDOMElement()
    }
    expect(screen.getByTestId('extra-deferral-ClaimModal')).toHaveTextContent('useAuth0')
    expect(screen.getByTestId('extra-deferral-SignalFusionDemoControls')).toHaveTextContent('fetchSignalFusionSteps')
    expect(screen.getByTestId('extra-deferral-AgentEvidenceDrawer')).toHaveTextContent('useAgentRisk')
    expect(screen.getByTestId('extra-deferral-CookieSettingsModal')).toHaveTextContent('api.cookiePreferences.get')
    expect(screen.getByTestId('extra-deferral-ConsentModal')).toHaveTextContent('VITE_LEGAL_BASE_URL')
  })
})
