import { useMemo, useState, type ReactNode } from 'react'
import { AdversarialSimulationPanel } from '../../components/demos/AdversarialSimulationPanel'
import { AgentMaxxingLogStream } from '../../components/demos/AgentMaxxingLogStream'
import { AttestationBundleExport } from '../../components/demos/AttestationBundleExport'
import { AutoPlayControls } from '../../components/demos/AutoPlayControls'
import { ConfinementTelemetryPanel } from '../../components/demos/ConfinementTelemetryPanel'
import { EnrollmentPanel } from '../../components/demos/EnrollmentPanel'
import { LandlockPolicyInspector } from '../../components/demos/LandlockPolicyInspector'
import { StageProgressionController } from '../../components/demos/StageProgressionController'
import StepperHeader from '../../components/demos/StepperHeader'
import { TokenIssuePanel } from '../../components/demos/TokenIssuePanel'
import { ZeroPayloadInspector } from '../../components/demos/ZeroPayloadInspector'
import { createMockBridge } from '../../components/demos/bridge'
import { HAPPY_PATH_PRESET, TAMPER_BREACH_PRESET } from '../../components/demos/scenarios'
import { INITIAL_STEPPER_STATE } from '../../components/demos/types'
import ApiKeyStep from '../../components/onboarding/ApiKeyStep'
import CompletionCelebration from '../../components/onboarding/CompletionCelebration'
import ContainmentPolicyConsentStep from '../../components/onboarding/ContainmentPolicyConsentStep'
import IdpLinkageStep from '../../components/onboarding/IdpLinkageStep'
import OnboardingProgressHeader, { type StepDefinition } from '../../components/onboarding/OnboardingProgressHeader'
import PreferencesStep from '../../components/onboarding/PreferencesStep'
import ProgressBanner from '../../components/onboarding/ProgressBanner'
import ProviderLogo from '../../components/onboarding/ProviderLogo'
import ProviderSelectStep from '../../components/onboarding/ProviderSelectStep'
import StepIcon from '../../components/onboarding/StepIcon'
import SummaryStep from '../../components/onboarding/SummaryStep'
import TenantIdentityStep from '../../components/onboarding/TenantIdentityStep'
import {
  AgentsPreview,
  AuditTrailPreview,
  CompliancePreview,
  DiscoveryPreview,
  SettingsPreview,
} from '../../components/onboarding/TourPreviews'
import ValidationErrorBanner from '../../components/onboarding/ValidationErrorBanner'
import WelcomeStep from '../../components/onboarding/WelcomeStep'
import WizardFieldRenderer from '../../components/onboarding/WizardFieldRenderer'
import type { ConnectorProvider, WizardFieldSpec } from '../../types/connectors'

export const WORKFLOW_SPECIMEN_NAMES = [
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
] as const satisfies readonly string[]

const FIXTURE_TIMESTAMP = '2026-09-15T02:00:00Z'
const noop = () => undefined

const PROVIDERS = [
  {
    provider_id: 'github',
    display_name: 'GitHub',
    wizard_config: {
      fields: [],
      permissions: ['read:org'],
      docs_link: '/help/connectors/github',
      help_text: 'Discover GitHub Apps, deploy keys, and automation tokens.',
    },
  },
  {
    provider_id: 'okta',
    display_name: 'Okta',
    wizard_config: {
      fields: [],
      permissions: ['okta.apps.read'],
      docs_link: '/help/connectors/okta',
      help_text: 'Inventory service applications and workload identities.',
    },
  },
] satisfies ConnectorProvider[]

const WIZARD_FIELDS = [
  {
    name: 'organisationUrl',
    label: 'Organisation URL',
    type: 'text',
    required: true,
    placeholder: 'https://example.okta.com',
    help_text: 'Use the tenant URL shown in the provider console.',
  },
  {
    name: 'region',
    label: 'Region',
    type: 'select',
    options: [
      { value: 'eu', label: 'Europe' },
      { value: 'us', label: 'United States' },
    ],
  },
] satisfies WizardFieldSpec[]

const ONBOARDING_STEPS: StepDefinition[] = [
  { id: 'organisation', title: 'Organisation', subtitle: 'Tenant identity' },
  { id: 'identity-provider', title: 'Identity provider', subtitle: 'Federated access' },
  { id: 'preferences', title: 'Preferences', subtitle: 'Scanning policy' },
]

function Specimen({ name, children }: { name: (typeof WORKFLOW_SPECIMEN_NAMES)[number]; children: ReactNode }) {
  return (
    <article data-testid={`workflow-specimen-${name}`} className="card" style={{ minWidth: 0 }}>
      <h3 style={{ color: 'var(--text)', fontSize: 14, margin: '0 0 14px' }}>{name}</h3>
      {children}
    </article>
  )
}

function DemoSpecimens() {
  const bridge = useMemo(() => createMockBridge({ preset: HAPPY_PATH_PRESET, latencyMs: 0 }), [])

  return (
    <div style={{ display: 'grid', gap: 16 }}>
      <Specimen name="AdversarialSimulationPanel">
        <AdversarialSimulationPanel
          bridge={bridge}
          preset={TAMPER_BREACH_PRESET}
          initialPayload={{
            tamperType: 'hash_mismatch',
            injectedAt: FIXTURE_TIMESTAMP,
            originalSha256: 'a'.repeat(64),
            tamperedSha256: 'b'.repeat(64),
            breachDetected: true,
            containmentTriggered: true,
            detectionLatencyMs: 18,
          }}
        />
      </Specimen>
      <Specimen name="AgentMaxxingLogStream">
        <AgentMaxxingLogStream
          title="Deterministic containment log"
          status="streaming"
          statusTone="warning"
          initialLog={'02:00:00 host enrolled\n02:00:01 Landlock boundary confirmed'}
          streaming={false}
        />
      </Specimen>
      <Specimen name="AttestationBundleExport">
        <div data-testid="workflow-state-primary">
          <AttestationBundleExport preset={HAPPY_PATH_PRESET} activeStage="confinement_streaming" />
        </div>
      </Specimen>
      <Specimen name="AutoPlayControls">
        <AutoPlayControls bridge={bridge} state={INITIAL_STEPPER_STATE} storage={null} />
      </Specimen>
      <Specimen name="ConfinementTelemetryPanel">
        <ConfinementTelemetryPanel
          bridge={bridge}
          preset={HAPPY_PATH_PRESET}
          pollIntervalMs={86_400_000}
          showLogStream={false}
          initialPayload={{
            processComm: 'cpai-engineer',
            cpuTicks: 172,
            rssBytes: 67_108_864,
            openFds: 14,
            expectedSha256: 'c'.repeat(64),
            observedSha256: 'c'.repeat(64),
            hashMatch: true,
            zeroPayloadVerified: true,
          }}
        />
      </Specimen>
      <Specimen name="EnrollmentPanel">
        <EnrollmentPanel
          bridge={bridge}
          initialPayload={{
            hostId: 'host-fixture-01',
            agentId: 'agent-fixture-01',
            publicKeyFingerprint: `SHA256:${'d'.repeat(43)}`,
            enrolledAt: FIXTURE_TIMESTAMP,
            status: 'enrolled',
          }}
        />
      </Specimen>
      <Specimen name="LandlockPolicyInspector"><LandlockPolicyInspector /></Specimen>
      <Specimen name="StageProgressionController">
        <StageProgressionController bridge={bridge} storage={null}>
          {({ currentStage }) => <p style={{ color: 'var(--muted)' }}>Active fixture stage: {currentStage}</p>}
        </StageProgressionController>
      </Specimen>
      <Specimen name="StepperHeader">
        <StepperHeader currentStage="host_enrolled" activeViewStage="host_enrolled" stageStatuses={{ ...INITIAL_STEPPER_STATE.stageStatuses, operator_init: 'confirmed', host_enrolled: 'in_flight' }} />
      </Specimen>
      <Specimen name="TokenIssuePanel">
        <TokenIssuePanel
          bridge={bridge}
          initialPayload={{ tokenId: 'token-fixture-01', issuedAt: FIXTURE_TIMESTAMP, ttlSeconds: 900, operatorId: 'operator-fixture', tokenPrefix: 'sl_demo_' }}
        />
      </Specimen>
      <Specimen name="ZeroPayloadInspector"><ZeroPayloadInspector /></Specimen>
    </div>
  )
}

function ProviderSelectFixture() {
  const [selected, setSelected] = useState<string[]>([])
  const [status, setStatus] = useState('No provider selected')
  const toggle = (id: string) => {
    setSelected((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id])
    setStatus(`${id} selected`)
  }
  return <><ProviderSelectStep providers={PROVIDERS} selectedProviderIds={selected} connectedProviderIds={new Set()} onToggle={toggle} /><p data-testid="fixture-action-status">{status}</p></>
}

function WelcomeFixture() {
  const [status, setStatus] = useState('Awaiting action')
  return <><WelcomeStep onContinue={() => setStatus('Welcome continued')} onOpenHelp={() => setStatus('Help opened')} /><p data-testid="fixture-action-status">{status}</p></>
}

function WizardFieldsFixture() {
  const [values, setValues] = useState<Record<string, string>>({ region: 'eu' })
  return <WizardFieldRenderer fields={WIZARD_FIELDS} values={values} onChange={(name, value) => setValues((current) => ({ ...current, [name]: value }))} />
}

function OnboardingSpecimens() {
  return (
    <div style={{ display: 'grid', gap: 16 }}>
      <Specimen name="ApiKeyStep"><ApiKeyStep revealed={{ key: 'sl_fixture_redacted', prefix_hint: 'sl_fixture' }} revealing={false} onReveal={noop} onContinue={noop} onBack={noop} /></Specimen>
      <Specimen name="CompletionCelebration"><CompletionCelebration tenantProfile={{ organizationName: 'Northstar Bank' }} idpConfig={{ providerName: 'Okta' }} containmentPolicy={{ policyTier: 'strict-sandboxed' }} onContinue={noop} /></Specimen>
      <Specimen name="ContainmentPolicyConsentStep"><ContainmentPolicyConsentStep tenantProfile={{ organizationName: 'Northstar Bank' }} idpConfig={{ providerName: 'Okta' }} initialValues={{ policyTier: 'strict-sandboxed', zeroTrustIdentity: true, autonomousContainment: true, auditTrailRetention: true }} onSubmit={noop} onBack={noop} onSkip={noop} /></Specimen>
      <Specimen name="IdpLinkageStep"><IdpLinkageStep initialValues={{ providerId: 'okta', providerName: 'Okta', issuerUrl: 'https://northstar.example', clientId: 'fixture-client', scopes: 'openid profile email', connectionTested: true, connectionMessage: 'Connection verified' }} onNext={noop} onBack={noop} onSkip={noop} /></Specimen>
      <Specimen name="OnboardingProgressHeader"><OnboardingProgressHeader currentStepIndex={1} totalSteps={ONBOARDING_STEPS.length} steps={ONBOARDING_STEPS} onSkip={noop} /></Specimen>
      <Specimen name="PreferencesStep"><PreferencesStep initialValues={{ preferred_scan_cadence_hours: 24, alert_email: 'security@example.test', alert_threshold: 7 }} submitting={false} onSubmit={noop} onBack={noop} /></Specimen>
      <Specimen name="ProgressBanner"><div data-testid="workflow-state-warning"><ProgressBanner providers={PROVIDERS} selectedProviderIds={['github', 'okta']} providerRunState={{ github: { status: 'connected' }, okta: { status: 'error', error: 'Consent expired' } }} stepNumber={2} totalSteps={4} onSkip={noop} /></div></Specimen>
      <Specimen name="ProviderLogo"><ProviderLogo providerId="github" displayName="GitHub" size={44} /></Specimen>
      <Specimen name="ProviderSelectStep"><ProviderSelectFixture /></Specimen>
      <Specimen name="StepIcon"><StepIcon kind="preferences" /></Specimen>
      <Specimen name="SummaryStep"><div data-testid="workflow-state-empty"><SummaryStep connectors={[]} disconnectingId={null} onDisconnect={noop} onFinish={noop} onBack={noop} /></div></Specimen>
      <Specimen name="TenantIdentityStep"><TenantIdentityStep initialValues={{ organizationName: 'Northstar Bank', workspaceId: 'northstar-eu', adminEmail: 'security@example.test', environment: 'evaluation', sector: 'financial-services', jurisdiction: 'GB', reportingCurrency: 'GBP', riskAppetiteTolerance: 'moderate' }} onNext={noop} onSkip={noop} /></Specimen>
      <Specimen name="AgentsPreview"><AgentsPreview /></Specimen>
      <Specimen name="AuditTrailPreview"><AuditTrailPreview /></Specimen>
      <Specimen name="CompliancePreview"><CompliancePreview /></Specimen>
      <Specimen name="DiscoveryPreview"><DiscoveryPreview /></Specimen>
      <Specimen name="SettingsPreview"><SettingsPreview /></Specimen>
      <Specimen name="ValidationErrorBanner"><div data-testid="workflow-state-error"><ValidationErrorBanner errors={['Issuer URL must use HTTPS', 'Administrator email is required']} /></div></Specimen>
      <Specimen name="WelcomeStep"><WelcomeFixture /></Specimen>
      <Specimen name="WizardFieldRenderer"><WizardFieldsFixture /></Specimen>
    </div>
  )
}

export function WorkflowSpecimens() {
  return (
    <section data-testid="workflow-specimens" style={{ display: 'grid', gap: 24 }}>
      <div>
        <h2 style={{ color: 'var(--text)', fontSize: 16, marginBottom: 6 }}>Workflow components</h2>
        <p style={{ color: 'var(--muted)', fontSize: 12, margin: 0 }}>Deterministic, provider-free fixtures. Actions update component or fixture-local state only.</p>
      </div>
      <DemoSpecimens />
      <OnboardingSpecimens />
      <aside data-testid="workflow-deferral-RevocationPanel" className="card" style={{ borderColor: 'var(--amber)', color: 'var(--muted)', fontSize: 12 }}>
        <strong style={{ color: 'var(--amber)' }}>RevocationPanel deferred:</strong>{' '}
        its submit path directly calls <code>defaultLiveTransport.fetch</code> against the revocation endpoint. Mounting a decorative substitute would conceal that runtime dependency.
      </aside>
    </section>
  )
}
