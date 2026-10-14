import { fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WorkflowSpecimens, WORKFLOW_SPECIMEN_NAMES } from './WorkflowSpecimens'

const EXPECTED_NAMES = [
  'AdversarialSimulationPanel',
  'AgentMaxxingLogStream',
  'AttestationBundleExport',
  'AutoPlayControls',
  'ConfinementTelemetryPanel',
  'EnrollmentPanel',
  'LandlockPolicyInspector',
  'StageProgressionController',
  'StepperHeader',
  'TokenIssuePanel',
  'ZeroPayloadInspector',
  'ApiKeyStep',
  'CompletionCelebration',
  'ContainmentPolicyConsentStep',
  'IdpLinkageStep',
  'OnboardingProgressHeader',
  'PreferencesStep',
  'ProgressBanner',
  'ProviderLogo',
  'ProviderSelectStep',
  'StepIcon',
  'SummaryStep',
  'TenantIdentityStep',
  'AgentsPreview',
  'AuditTrailPreview',
  'CompliancePreview',
  'DiscoveryPreview',
  'SettingsPreview',
  'ValidationErrorBanner',
  'WelcomeStep',
  'WizardFieldRenderer',
] as const

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('WorkflowSpecimens', () => {
  it('exports the exact readonly roster of genuinely mounted components', () => {
    expect(WORKFLOW_SPECIMEN_NAMES).toEqual(EXPECTED_NAMES)

    render(<WorkflowSpecimens />)
    for (const name of WORKFLOW_SPECIMEN_NAMES) {
      expect(screen.getByTestId(`workflow-specimen-${name}`)).toBeVisible()
    }
  })

  it('shows honest state variants and the contextual network deferral', () => {
    render(<WorkflowSpecimens />)

    expect(screen.getByTestId('workflow-state-primary')).toBeVisible()
    expect(screen.getByTestId('workflow-state-warning')).toBeVisible()
    expect(screen.getByTestId('workflow-state-error')).toBeVisible()
    expect(screen.getByTestId('workflow-state-empty')).toBeVisible()
    expect(screen.getByTestId('workflow-deferral-RevocationPanel')).toHaveTextContent(
      /defaultLiveTransport\.fetch.*revocation endpoint/i,
    )
  })

  it('keeps demo and onboarding interactions local without HTTP calls', () => {
    const fetchSpy = vi.fn(() => Promise.reject(new Error('fixture attempted fetch')))
    const openSpy = vi.fn()
    vi.stubGlobal('fetch', fetchSpy)
    vi.spyOn(XMLHttpRequest.prototype, 'open').mockImplementation(openSpy as XMLHttpRequest['open'])

    render(<WorkflowSpecimens />)

    const landlock = screen.getByTestId('workflow-specimen-LandlockPolicyInspector')
    fireEvent.click(within(landlock).getByRole('button', { name: /Inspect Path Rules/i }))
    expect(within(landlock).getByTestId('landlock-policy-inspector-table')).toBeVisible()

    const welcome = screen.getByTestId('workflow-specimen-WelcomeStep')
    fireEvent.click(within(welcome).getByRole('button', { name: /Get started/i }))
    expect(within(welcome).getByTestId('fixture-action-status')).toHaveTextContent('Welcome continued')

    const providers = screen.getByTestId('workflow-specimen-ProviderSelectStep')
    fireEvent.click(within(providers).getByText('GitHub'))
    expect(within(providers).getByTestId('fixture-action-status')).toHaveTextContent('github selected')

    const fields = screen.getByTestId('workflow-specimen-WizardFieldRenderer')
    fireEvent.change(within(fields).getByLabelText('Organisation URL *'), {
      target: { value: 'https://fixture.example' },
    })
    expect(within(fields).getByDisplayValue('https://fixture.example')).toBeVisible()

    expect(fetchSpy).not.toHaveBeenCalled()
    expect(openSpy).not.toHaveBeenCalled()
  })
})
