import { CORE_SPECIMEN_NAMES } from './CoreSpecimens'
import { EXTRA_SPECIMEN_NAMES } from './ExtraSpecimens'
import { WORKFLOW_SPECIMEN_NAMES } from './WorkflowSpecimens'

export type CoverageKind = 'specimen' | 'route' | 'unwired' | 'unrepresented' | 'internal' | 'guard' | 'provider'
export type CoverageScope = 'shared' | 'page' | 'fixture' | 'infrastructure'

interface CoverageBase {
  source: string
  symbol: string
  scope: CoverageScope
}

export type ComponentCoverageEntry = CoverageBase & (
  | { kind: 'specimen'; href: string }
  | { kind: 'route'; href: string; state: string; reason: string }
  | { kind: 'unwired' | 'unrepresented' | 'internal' | 'guard' | 'provider'; reason: string }
)

type SourceSymbols = readonly [source: string, symbols: string]

const SOURCE_SYMBOLS: readonly SourceSymbols[] = [
  ['components/GovernancePolicyTable.tsx', 'GovernancePolicyTable'],
  ['components/ProofConsole.tsx', 'ProofConsole'],
  ['components/ConfirmDialog.tsx', 'ConfirmDialog'],
  ['components/CodingAgentCard.tsx', 'CodingAgentCard'],
  ['components/signals/ObservationFeed.tsx', 'ObservationFeed'],
  ['components/signals/FindingsList.tsx', 'FindingsList'],
  ['components/signals/WindowSelector.tsx', 'WindowSelector'],
  ['components/signals/SourceTable.tsx', 'SourceTable'],
  ['components/signals/presentation.tsx', 'LabelChips'],
  ['components/signals/DecisionCard.tsx', 'DecisionCard'],
  ['components/signals/IngestRateChart.tsx', 'IngestRateChart'],
  ['components/DelegationAttestationDrawer.tsx', 'DelegationAttestationDrawer'],
  ['components/ThemeToggle.tsx', 'ThemeToggle'],
  ['components/ApiKeyRevealModal.tsx', 'ApiKeyRevealModal'],
  ['components/ConnectorConfigureModal.tsx', 'ConnectorConfigureModal'],
  ['components/connectors/RemoteSyncBadge.tsx', 'RemoteSyncBadge'],
  ['components/connectors/SyncLogsModal.tsx', 'SyncLogsModal'],
  ['components/connectors/SyncStatusPill.tsx', 'SyncStatusPill'],
  ['components/CodingAgentsTab.tsx', 'CodingAgentsTab'],
  ['components/agents/ClaimModal.tsx', 'ClaimModal'],
  ['components/DelegationChainNode.tsx', 'DelegationChainNode'],
  ['components/AuthorizationProofDrawer.tsx', 'AuthorizationProofDrawer'],
  ['components/DataTable.tsx', 'DataTable'],
  ['components/DonutChart.tsx', 'DonutChart'],
  ['components/demos/ZeroPayloadInspector.tsx', 'ZeroPayloadInspector'],
  ['components/demos/LandlockPolicyInspector.tsx', 'LandlockPolicyInspector'],
  ['components/demos/AutoPlayControls.tsx', 'AutoPlayControls'],
  ['components/demos/TokenIssuePanel.tsx', 'TokenIssuePanel'],
  ['components/demos/StageProgressionController.tsx', 'StageProgressionController'],
  ['components/demos/ConfinementTelemetryPanel.tsx', 'ConfinementTelemetryPanel'],
  ['components/demos/AdversarialSimulationPanel.tsx', 'AdversarialSimulationPanel'],
  ['components/demos/StepperHeader.tsx', 'StepperHeader'],
  ['components/demos/EnrollmentPanel.tsx', 'EnrollmentPanel'],
  ['components/demos/AttestationBundleExport.tsx', 'AttestationBundleExport'],
  ['components/demos/AgentMaxxingLogStream.tsx', 'AgentMaxxingLogStream'],
  ['components/demos/RevocationPanel.tsx', 'RevocationPanel'],
  ['components/LoadingState.tsx', 'LoadingState'],
  ['components/WhoAuthorizedPanel.tsx', 'WhoAuthorizedPanel'],
  ['components/AgentAssessmentsTab.tsx', 'AgentAssessmentsTab'],
  ['components/AgentReviewQueue.tsx', 'AgentReviewQueue'],
  ['components/CompactOperationalTable.tsx', 'CompactOperationalTable CompactDisclosure CompactEmail CompactObservedTime'],
  ['pages/design-system/CompactInventorySpecimen.tsx', 'CompactInventorySpecimen'],
  ['components/AgentIdentityTab.tsx', 'AgentIdentityTab'],
  ['components/SignalFusionDemoControls.tsx', 'SignalFusionDemoControls'],
  ['components/fleet/RoleViewSelector.tsx', 'RoleViewSelector'],
  ['components/fleet/FleetBadge.tsx', 'FleetBadge'],
  ['components/fleet/FleetRiskGauge.tsx', 'FleetRiskGauge'],
  ['components/fleet/FleetTopology.tsx', 'FleetTopology'],
  ['components/EmptyState.tsx', 'EmptyState'],
  ['components/NotificationBell.tsx', 'NotificationBell'],
  ['components/TriageMenu.tsx', 'TriageMenu'],
  ['components/CredentialEvidencePanel.tsx', 'CredentialEvidencePanel'],
  ['components/ConversionNote.tsx', 'ConversionNote'],
  ['components/DemoToggle.tsx', 'DemoToggle'],
  ['components/IdentityAuditPanel.tsx', 'IdentityAuditPanel'],
  ['components/AgentEvidenceDrawer.tsx', 'AgentEvidenceDrawer'],
  ['components/PixelLoader.tsx', 'PixelLoader'],
  ['components/Sidebar.tsx', 'Sidebar'],
  ['components/CredentialStateNotice.tsx', 'CredentialStateNotice'],
  ['components/PolicyEditor.tsx', 'PolicyEditor'],
  ['components/ComplianceDrawer.tsx', 'ComplianceDrawer'],
  ['components/PageToc.tsx', 'PageTocLayout'],
  ['components/onboarding/ProgressBanner.tsx', 'ProgressBanner'],
  ['components/onboarding/ProviderLogo.tsx', 'ProviderLogo'],
  ['components/onboarding/SetupBanner.tsx', 'SetupBanner'],
  ['components/onboarding/WelcomeStep.tsx', 'WelcomeStep'],
  ['components/onboarding/WizardFieldRenderer.tsx', 'WizardFieldRenderer'],
  ['components/onboarding/TourPreviews.tsx', 'DiscoveryPreview AgentsPreview CompliancePreview AuditTrailPreview SettingsPreview'],
  ['components/onboarding/ValidationErrorBanner.tsx', 'ValidationErrorBanner'],
  ['components/onboarding/OnboardingProgressHeader.tsx', 'OnboardingProgressHeader'],
  ['components/onboarding/StepIcon.tsx', 'StepIcon'],
  ['components/onboarding/ProviderSelectStep.tsx', 'ProviderSelectStep'],
  ['components/onboarding/OnboardingWizard.tsx', 'OnboardingWizard'],
  ['components/onboarding/ContainmentPolicyConsentStep.tsx', 'ContainmentPolicyConsentStep'],
  ['components/onboarding/PreferencesStep.tsx', 'PreferencesStep'],
  ['components/onboarding/ProviderConfigureStep.tsx', 'ProviderConfigureStep'],
  ['components/onboarding/ApiKeyStep.tsx', 'ApiKeyStep'],
  ['components/onboarding/CompletionCelebration.tsx', 'CompletionCelebration'],
  ['components/onboarding/TenantIdentityStep.tsx', 'TenantIdentityStep'],
  ['components/onboarding/IdpLinkageStep.tsx', 'IdpLinkageStep'],
  ['components/onboarding/SummaryStep.tsx', 'SummaryStep'],
  ['components/HelpModal.tsx', 'HelpModal'],
  ['components/StreamingLogBlock.tsx', 'StreamingLogBlock'],
  ['components/ButtonWait.tsx', 'ButtonWait'],
  ['components/AgentAccessTab.tsx', 'AgentAccessTab'],
  ['components/StunPlanes.tsx', 'StunOverallHeadline PlaneOutcomeTable PlaneStrip'],
  ['components/DataTableToolbar.tsx', 'DataTableToolbar ToolbarSearch ToolbarFacet ToolbarSelect ToolbarClear ToolbarCount'],
  ['components/AgentCockpitSection.tsx', 'AgentCockpitSection'],
  ['components/KeyboardShortcutsOverlay.tsx', 'KeyboardShortcutsOverlay'],
  ['components/AgentSuperFilterTable.tsx', 'AgentSuperFilterTable'],
  ['components/RbacImporterPanel.tsx', 'RbacImporterPanel'],
  ['components/AgentActivityTab.tsx', 'AgentActivityTab'],
  ['components/DiscoveredWorkloadDrawer.tsx', 'DiscoveredWorkloadDrawer'],
  ['components/ErrorState.tsx', 'ErrorState'],
  ['components/admin/InviteUserModal.tsx', 'InviteUserModal'],
  ['components/admin/EditUserModal.tsx', 'EditUserModal'],
  ['components/AgentDeepLink.tsx', 'AgentDeepLink'],
  ['components/SafeLink.tsx', 'SafeLink'],
  ['components/SignalBadge.tsx', 'SignalBadge'],
  ['components/SuperCredInstructorPanel.tsx', 'SuperCredInstructorPanel'],
  ['components/CurrencySetting.tsx', 'CurrencySetting'],
  ['components/EvidenceDrawer.tsx', 'EvidenceDrawer'],
  ['components/CycleDetectedWarning.tsx', 'CycleDetectedWarning'],
  ['components/DelegationEventFilter.tsx', 'DelegationEventFilter'],
  ['components/ApiKeyRotateModal.tsx', 'ApiKeyRotateModal'],
  ['components/OpenFindingsPanel.tsx', 'OpenFindingsPanel'],
  ['components/AgentCockpitTelemetry.tsx', 'AgentCockpitTelemetryView TelemetryErrorBoundary AgentCockpitTelemetry'],
  ['components/trust/NodeDetailDrawer.tsx', 'NodeDetailDrawer'],
  ['components/trust/TrustGraph.tsx', 'TrustGraph'],
  ['components/trust/TrustTopologyCanvas.tsx', 'TrustTopologyCanvas'],
  ['components/CredentialActionsMenu.tsx', 'CredentialActionsMenu'],
  ['components/HelpHint.tsx', 'HelpHint'],
  ['components/CookieSettingsModal.tsx', 'CookieSettingsModal'],
  ['components/AgentOverviewTab.tsx', 'AgentOverviewTab'],
  ['components/AuditDetailDrawer.tsx', 'renderSyntaxHighlightedJson AuditDetailDrawer'],
  ['components/AddClusterModal.tsx', 'AddClusterModal'],
  ['components/MetricsTopBar.tsx', 'MetricsTopBarView MetricsTopBar'],
  ['components/RiskWidget.tsx', 'SourceBadge RiskWidget'],
  ['components/headers/primitives.tsx', 'BellIcon SearchIcon ChevronIcon ArrowIcon SeverityDot SeverityTag UnreadPill Chip HeaderFrame Mark Avatar AlertLink'],
  ['components/headers/variants.tsx', 'CommandBarHeader ContextBarHeader OperationsHeader QuietHeader SituationHeader'],
  ['components/TopNav.tsx', 'TopNav'],
  ['components/StunReasonForm.tsx', 'StunReasonForm'],
  ['components/WidthToggle.tsx', 'WidthToggle'],
  ['components/StatusBadge.tsx', 'StatusBadge KernelStateBadge'],
  ['components/ConsentModal.tsx', 'ConsentModal'],
  ['components/FloatingConfigControls.tsx', 'FloatingConfigControls'],
  ['components/DashKit.tsx', 'Pill StatCard Section Table'],
  ['components/common/FeatureGate.tsx', 'FeatureGate'],
  ['components/common/PagePattern.tsx', 'PageHeader PageLoader PagePattern'],
  ['pages/NotFoundPage.tsx', 'NotFoundPage'],
  ['pages/AgentDetailPage.tsx', 'AgentDetailPage EventTypeTag ViolationBadge Timeline RequestTransitionModal IssueCredentialModal RevokeCredentialModal DossierHeader'],
  ['pages/FleetAudiencePage.tsx', 'FleetAudiencePage'],
  ['pages/DesignSystemHeadersPage.tsx', 'DesignSystemHeadersPage Group ExampleHeading Caveat NotWhen'],
  ['pages/DesignSystemCssLabPage.tsx', 'DesignSystemCssLabPage'],
  ['pages/CompliancePolicyPage.tsx', 'CompliancePolicyPage VersionPill'],
  ['pages/DesignSystemPage.tsx', 'DesignSystemPage Group Specimen Caveat ExampleHeading CoverageCatalogue'],
  ['pages/UsersPage.tsx', 'UsersPage StatCard'],
  ['pages/RiskExposurePage.tsx', 'RiskExposurePage'],
  ['pages/RedeemInvite.tsx', 'RedeemInvite'],
  ['pages/SignalFusionPage.tsx', 'SignalFusionPage'],
  ['pages/SignalStorePage.tsx', 'SignalStorePage'],
  ['pages/CredentialInventoryPage.tsx', 'CredentialInventoryPage StatCard ToolbarSearch ToolbarSelect ToolbarCount Toolbar'],
  ['pages/admin/UserTable.tsx', 'RoleBadge StatusIndicator UserTable'],
  ['pages/admin/UsersPage.tsx', 'UsersPage'],
  ['components/admin/AdminNavTabs.tsx', 'AdminNavTabs'],
  ['pages/admin/FeaturesPage.tsx', 'FeaturesPage FlagToggle'],
  ['pages/DiscoveryPage.tsx', 'DiscoveryPage ControlBadge ControlRecommendationsCell AutoClaimModal AttentionPanel ConnectDirectoryCta ScanStatusCard DiscoverySourcesStrip SyncBadge DiscoveryEmptyState WorkloadRow'],
  ['pages/AgentTrustTopologyPage.tsx', 'AgentTrustTopologyPage Detail AssuranceMeter TrustPath DegradedBanner'],
  ['pages/DiscoveryAccountDetailPage.tsx', 'DiscoveryAccountDetailPage Field'],
  ['pages/CryptographyPage.tsx', 'CryptographyPage FilterBar NoMatch'],
  ['pages/CallbackPage.tsx', 'CallbackPage'],
  ['pages/SuperCredPage.tsx', 'SuperCredPage FilterChip DemoStepControls'],
  ['pages/CollusionAccessPage.tsx', 'SubjectAgentLink GroupMembersLink CollaboratorGainsLinks CollusionAccessPage FilterStrip FilteredEmpty NoFindings ProofRow'],
  ['pages/OnboardingWizard.tsx', 'OnboardingWizardPage'],
  ['pages/FeedsExplorerPage.tsx', 'FeedsExplorerPage'],
  ['pages/FrameworkDetailPage.tsx', 'FrameworkDetailPage'],
  ['pages/SignalsPage.tsx', 'SignalsPage'],
  ['pages/design-system/WorkflowSpecimens.tsx', 'WorkflowSpecimens Specimen DemoSpecimens ProviderSelectFixture WelcomeFixture WizardFieldsFixture OnboardingSpecimens'],
  ['pages/AgentsPage.tsx', 'AgentsPage RegisterModal EditAgentModal AgentStatCards AgentTableRow GovernedTab SignalSummaryPanel'],
  ['pages/FederatedServicesPage.tsx', 'FederatedServicesPage Unmeasured PanelRefusal FieldRefusals Panel FilterBar NoMatch'],
  ['pages/AgentPosturePage.tsx', 'AgentPosturePage SignalEvidenceSection'],
  ['pages/CodingAgentTopologyPage.tsx', 'CodingAgentTopologyPage'],
  ['pages/LoginPage.tsx', 'LoginPage'],
  ['pages/RbacExplorerPage.tsx', 'RbacExplorerPage RbacErrorBoundary TableToolbar TableEmptyState'],
  ['pages/RbacAnalysisPage.tsx', 'RbacAnalysisPage'],
  ['pages/PolicyEvaluationPage.tsx', 'PolicyEvaluationPage LivePolicyEvaluation DemoPolicyEvaluation'],
  ['pages/AgentMaxxingDemoPage.tsx', 'AgentMaxxingDemoPage'],
  ['pages/FleetDemoPage.tsx', 'FleetDemoPage'],
  ['pages/WeavePage.tsx', 'WeavePage SignalThread ActorCard CoverageHonestyPanel'],
  ['pages/DistanceLatencyPage.tsx', 'DistanceLatencyPage'],
  ['pages/NetworkTestsPage.tsx', 'NetworkTestsPage FilterToolbar'],
  ['pages/ConnectorHelpPage.tsx', 'ConnectorHelpPage markdownComponents'],
  ['pages/design-system/CoreSpecimens.tsx', 'CoreSpecimens Specimen DelegationEventFilterSpecimen StunReasonFormSpecimen RoleViewSelectorSpecimen ConfirmDialogSpecimen'],
  ['pages/design-system/ExtraSpecimens.tsx', 'ExtraSpecimens Specimen OverlayButton FixtureRouter'],
  ['pages/design-system/ContextSpecimens.tsx', 'ContextSpecimens'],
  ['pages/design-system/PagePatternSpecimen.tsx', 'PagePatternSpecimen'],
  ['providers/FeatureFlagProvider.tsx', 'FeatureFlagProvider'],
  ['auth/ProtectedRoute.tsx', 'ProtectedRoute'],
  ['auth/oidc.tsx', 'OidcProvider'],
  ['money/CurrencyContext.tsx', 'CurrencyProvider'],
  ['App.tsx', 'SuperadminRoute AdminRoute GatedRoute App'],
  ['views/Compliance.tsx', 'Compliance PostureBar'],

  ['views/Agents.tsx', 'Agents AgentCard NHICard'],
  ['views/Settings.tsx', 'Settings SectionCard Field FrameworkToggle ApiKeyStatus'],
  ['views/AuditTrail.tsx', 'AuditTrail EventTag ToolbarField'],
  ['components/AgentOnboardingTab.tsx', 'AgentOnboardingTab'],
  ['components/help/HelpCardComponents.tsx', 'CopyableCodeBlock DocLinkCard'],
  ['pages/DeploySensorHelpPage.tsx', 'DeploySensorHelpPage'],
  ['pages/OnboardAgentHelpPage.tsx', 'OnboardAgentHelpPage'],
  ['pages/RemoteEnvironmentPage.tsx', 'RemoteEnvironmentPage LiveEnvironmentView DemoEnvironmentView RemoteAgentsPanel Section Tile Breadcrumb ErrorBanner'],
]

type Representation =
  | { kind: 'specimen'; href: string }
  | { kind: 'route'; href: string; state: string; reason: string }
  | { kind: 'unwired' | 'unrepresented' | 'internal' | 'guard' | 'provider'; reason: string }

const representations = new Map<string, Representation>()

function exactKey(source: string, symbol: string): string {
  return `${source}#${symbol}`
}

function symbolsFor(source: string): string {
  const group = SOURCE_SYMBOLS.find(([candidate]) => candidate === source)
  if (!group) throw new Error(`Unknown component coverage source: ${source}`)
  return group[1]
}

function represent(source: string, symbols: string, representation: Representation): void {
  for (const symbol of symbols.split(' ')) representations.set(exactKey(source, symbol), representation)
}

function routeSource(source: string, href: string, state: string): void {
  represent(source, symbolsFor(source), {
    kind: 'route',
    href,
    state,
    reason: 'The owning page supplies application context and data; this link opens the verified rendered state.',
  })
}

// Route ownership is deliberately declared by exact source. There is no
// filename, subtree, or symbol-name fallback: an unreviewed symbol remains
// visibly unrepresented until somebody verifies its real render state.
const ROUTE_SOURCES: readonly [source: string, href: string, state: string][] = [
  ['pages/AgentDetailPage.tsx', '/agents/demo-agent', 'Open the demo agent and use its Overview, Identity, Assessments, Activity, Access, or Coding agents tab.'],
  ['pages/FleetAudiencePage.tsx', '/fleet/audience', 'Open the read-only fleet audience presentation.'],
  ['pages/CompliancePolicyPage.tsx', '/policies', 'Open Compliance Policies; the policy table and version pills are visible.'],
  ['pages/UsersPage.tsx', '/users', 'Open Users to view the tenant user summary cards and table.'],
  ['pages/RiskExposurePage.tsx', '/risk', 'Open FAIR Risk Exposure with demo mode enabled.'],
  ['pages/RedeemInvite.tsx', '/redeem-invite', 'Open a protected invitation redemption flow.'],
  ['pages/SignalFusionPage.tsx', '/signal-fusion', 'Open Signal Fusion as a superadmin with demo mode enabled.'],
  ['pages/SignalStorePage.tsx', '/signal-store', 'Open Signal Store to view stored telemetry records.'],
  ['pages/CredentialInventoryPage.tsx', '/credential-inventory', 'Open Credential Inventory; its toolbar and stat cards are visible above the inventory.'],
  ['pages/admin/UserTable.tsx', '/admin/users', 'Open Admin Users to view role badges, status indicators, and the paginated user table.'],
  ['pages/admin/UsersPage.tsx', '/admin/users', 'Open Admin Users as a superadmin.'],
  ['pages/admin/FeaturesPage.tsx', '/admin/features', 'Open Feature Flags as a superadmin, select a tenant and wait for its flags to load; inspect the feature switches without toggling them.'],
  ['pages/DiscoveryPage.tsx', '/discovery', 'Open Discovery in demo mode; scan status, workload rows, and attention controls are visible.'],
  ['pages/AgentTrustTopologyPage.tsx', '/topology', 'Open Topology and select a trust node to expose detail and assurance states.'],
  ['pages/DiscoveryAccountDetailPage.tsx', '/discovery/accounts/demo-account', 'Open the demo discovery account detail route.'],
  ['pages/CryptographyPage.tsx', '/cryptography', 'Open Cryptography and adjust a filter to expose filter and empty states.'],
  ['pages/CallbackPage.tsx', '/callback', 'Enter through the OIDC callback redirect while authentication is completing.'],
  ['pages/SuperCredPage.tsx', '/supercred', 'Open SuperCred as a superadmin and advance the demo controls.'],
  ['pages/CollusionAccessPage.tsx', '/collusion-access', 'Open Collusion & Access in demo mode; use its filters and inspect finding proof rows.'],
  ['pages/OnboardingWizard.tsx', '/onboarding', 'Open Setup Wizard to render the page-owned wizard shell.'],
  ['pages/FeedsExplorerPage.tsx', '/feeds', 'Open Feeds Explorer with demo data.'],
  ['pages/FrameworkDetailPage.tsx', '/compliance/eu-ai-act', 'Open the EU AI Act framework detail route.'],
  ['pages/SignalsPage.tsx', '/signals', 'Open Signals in demo mode to render its live-signals and decisions tabs.'],
  ['pages/AgentsPage.tsx', '/agents', 'Open Agents in demo mode; use the governed and attention views or open an agent action.'],
  ['pages/FederatedServicesPage.tsx', '/federated-services', 'Open Federated Services and adjust filters to expose panel and no-match states.'],
  ['pages/AgentPosturePage.tsx', '/compliance/posture', 'Open Agent Posture and expand signal evidence.'],
  ['pages/CodingAgentTopologyPage.tsx', '/topology', 'Open Topology and select the coding-agent topology view.'],
  ['pages/LoginPage.tsx', '/login', 'Open the unauthenticated login route.'],
  ['pages/RbacExplorerPage.tsx', '/rbac-explorer', 'Open RBAC Explorer with the rbac_analysis feature enabled.'],
  ['pages/RbacAnalysisPage.tsx', '/rbac-analysis', 'Open RBAC Analysis with the rbac_analysis feature enabled.'],
  ['pages/PolicyEvaluationPage.tsx', '/evaluations', 'Open Policy Evaluation to inspect CEL rules, input sources, and in-toto attestation statements.'],
  ['pages/AgentMaxxingDemoPage.tsx', '/demos/agentmaxxing', 'Open AgentMaxxing as a superadmin and advance its staged containment demo.'],
  ['pages/FleetDemoPage.tsx', '/fleet', 'Open Fleet Demo as a superadmin with demos_fleet enabled.'],
  ['pages/WeavePage.tsx', '/weave', 'Open The Weave in demo mode to view signal threads, actors, and coverage honesty.'],
  ['pages/DistanceLatencyPage.tsx', '/distance-latency', 'Open Distance & Latency as a superadmin.'],
  ['pages/NetworkTestsPage.tsx', '/network-tests', 'Open Network Tests and use its filter toolbar.'],
  ['pages/ConnectorHelpPage.tsx', '/help/connectors/github', 'Open GitHub connector help to render the provider-specific Markdown guide.'],
  ['views/Compliance.tsx', '/compliance', 'Open Compliance Overview.'],
  ['views/Agents.tsx', '/agents', 'Open the legacy Agents view through the agent inventory.'],
  ['views/Settings.tsx', '/settings', 'Open Settings to view platform configuration controls.'],
  ['views/AuditTrail.tsx', '/audit', 'Open Audit Trail with demo mode enabled.'],
  ['pages/DeploySensorHelpPage.tsx', '/settings/help/deploy-sensor', 'Open Settings and choose Deploy Sensor Help in the infrastructure guide.'],
  ['pages/OnboardAgentHelpPage.tsx', '/settings/help/onboard-agent', 'Open Settings and choose Onboard Agent Help in the agent integration guide.'],
  ['pages/RemoteEnvironmentPage.tsx', '/settings/connectors/claude', 'Open the Remote Environment Console for a connected AI provider: the connector record and last scan in live mode, the fixture environment in demo mode.'],
]

for (const route of ROUTE_SOURCES) routeSource(...route)

// Verified component-owned route states. These are intentionally sparse: an
// unknown is labelled unrepresented rather than silently linked to /agents.
routeSource('components/admin/AdminNavTabs.tsx', '/admin/features', 'Open Feature Flags as a superadmin; the Admin Navigation tabs appear above the tenant controls.')
routeSource('components/signals/ObservationFeed.tsx', '/signals', 'Open Signals, choose Live signals, and leave the source filter on All sources.')
routeSource('components/signals/DecisionCard.tsx', '/signals', 'Open Signals and choose the Decisions tab to view a policy decision card.')
routeSource('components/signals/IngestRateChart.tsx', '/signals', 'Open Signals, choose Live signals, and select a layer chip beneath Ingest rate.')
routeSource('components/CurrencySetting.tsx', '/settings', 'Open Settings and use the Display currency control.')
routeSource('components/ApiKeyRotateModal.tsx', '/settings', 'Open Settings and choose Rotate on an existing API key.')
routeSource('components/ApiKeyRevealModal.tsx', '/settings', 'Open Settings and create or rotate an API key to reveal the one-time key modal.')
routeSource('components/ConnectorConfigureModal.tsx', '/settings', 'Open Settings, select Connectors tab, and choose Configure or toggle a connector.')
routeSource('components/connectors/RemoteSyncBadge.tsx', '/settings', 'Open Settings, select Connectors tab: each connected AI provider row shows its remote sync state (Live, Polling, Reconnecting or Sync error).')
routeSource('components/connectors/SyncLogsModal.tsx', '/settings', 'Open Settings, select Connectors tab, and choose See Log on a connected connector to inspect wire traces.')
routeSource('components/AgentIdentityTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Identity tab.')
routeSource('components/AgentOverviewTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Overview tab.')
routeSource('components/AgentAssessmentsTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Assessments tab.')
routeSource('components/AgentActivityTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Activity tab.')
routeSource('components/AgentAccessTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Access tab.')
routeSource('components/AgentOnboardingTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Onboarding tab.')
routeSource('components/CodingAgentsTab.tsx', '/agents/demo-agent', 'Open the demo agent and choose the Coding agents tab.')
routeSource('components/AgentReviewQueue.tsx', '/agents', 'Open Agents; the review queue appears above the inventory after evidence loads.')
routeSource('components/admin/EditUserModal.tsx', '/admin/users', 'Open Admin Users as a superadmin and choose Edit on a user row.')
routeSource('components/admin/InviteUserModal.tsx', '/admin/users', 'Open Admin Users as a superadmin and choose Invite user.')
routeSource('components/demos/RevocationPanel.tsx', '/demos/agentmaxxing', 'Open AgentMaxxing and advance to the Revocation Race stage.')
routeSource('components/HelpModal.tsx', '/agents', 'Open Agents and invoke Help from the top navigation.')
routeSource('components/Sidebar.tsx', '/agents', 'Open Agents while authenticated; the application sidebar frames the route.')
routeSource('components/TopNav.tsx', '/agents', 'Open Agents while authenticated; the top navigation frames the route.')
routeSource('components/FloatingConfigControls.tsx', '/agents', 'Open Agents and use the fixed controls at the bottom-right corner.')
routeSource('components/ThemeToggle.tsx', '/agents', 'Open Agents and use the bottom-right theme control.')
routeSource('components/DemoToggle.tsx', '/agents', 'Open Agents and use the bottom-right demo mode control.')
routeSource('components/WidthToggle.tsx', '/agents', 'Open Agents and use the bottom-right content width control.')

function routeSymbol(source: string, symbol: string, href: string, state: string, reason: string): void {
  represent(source, symbol, { kind: 'route', href, state, reason })
}

// Each entry below was traced from the exact exported symbol to the component
// or page that mounts it. This is intentionally symbol-level: sharing a source
// file does not prove that every export from that file is reachable.
const VERIFIED_ROUTE_SYMBOLS: readonly [source: string, symbol: string, href: string, state: string, reason: string][] = [
  ['components/DelegationAttestationDrawer.tsx', 'DelegationAttestationDrawer', '/agents/demo-agent', 'Open the demo agent, choose Activity, then open a delegation attestation.', 'Rendered by components/AgentActivityTab.tsx on the Agent Detail route.'],
  ['components/agents/ClaimModal.tsx', 'ClaimModal', '/agents/demo-agent', 'Open the demo agent and choose Claim agent.', 'Rendered directly by pages/AgentDetailPage.tsx; Discovery also mounts the same modal.'],
  ['components/AuthorizationProofDrawer.tsx', 'AuthorizationProofDrawer', '/agents/demo-agent', 'Open the demo agent, choose Activity, then open an authorization proof.', 'Rendered by components/AgentActivityTab.tsx on the Agent Detail route.'],
  ['components/WhoAuthorizedPanel.tsx', 'WhoAuthorizedPanel', '/agents/demo-agent', 'Open the demo agent and choose the Identity tab.', 'Rendered by components/AgentIdentityTab.tsx; the Weave also mounts this panel.'],
  ['components/fleet/FleetRiskGauge.tsx', 'FleetRiskGauge', '/fleet', 'Open Fleet Demo with demos_fleet enabled to view cluster risk gauges.', 'Rendered directly by pages/FleetDemoPage.tsx.'],
  ['components/fleet/FleetTopology.tsx', 'FleetTopology', '/fleet', 'Open Fleet Demo with demos_fleet enabled to view the fleet topology.', 'Rendered directly by pages/FleetDemoPage.tsx.'],
  ['components/NotificationBell.tsx', 'NotificationBell', '/agents', 'Open the authenticated application shell on Agents; the notification bell is visible in shell navigation.', 'Rendered by components/Sidebar.tsx and components/TopNav.tsx.'],
  ['components/TriageMenu.tsx', 'TriageMenu', '/discovery/accounts/demo-account', 'Open the demo discovery account and use the account triage actions menu.', 'Rendered directly by pages/DiscoveryAccountDetailPage.tsx.'],
  ['components/CredentialEvidencePanel.tsx', 'CredentialEvidencePanel', '/supercred', 'Open SuperCred as a superadmin to view credential evidence.', 'Rendered directly by pages/SuperCredPage.tsx.'],
  ['components/IdentityAuditPanel.tsx', 'IdentityAuditPanel', '/weave', 'Open The Weave to view the identity audit panel.', 'Rendered directly by pages/WeavePage.tsx.'],
  ['components/AgentEvidenceDrawer.tsx', 'AgentEvidenceDrawer', '/agents', 'Open Agents and select an agent row to reveal its evidence drawer.', 'Rendered directly by pages/AgentsPage.tsx.'],
  ['components/ComplianceDrawer.tsx', 'ComplianceDrawer', '/compliance', 'Open Compliance Overview and select a control or framework detail.', 'Rendered directly by views/Compliance.tsx.'],
  ['components/onboarding/SetupBanner.tsx', 'SetupBanner', '/agents', 'Open any authenticated application route while onboarding remains incomplete.', 'Rendered by App.tsx above the active route when needsOnboarding is true.'],
  ['components/onboarding/OnboardingWizard.tsx', 'OnboardingWizard', '/onboarding', 'Open Setup Wizard to render the live onboarding wizard.', 'Rendered by pages/OnboardingWizard.tsx.'],
  ['components/AgentCockpitSection.tsx', 'AgentCockpitSection', '/agents/demo-agent', 'Open the demo agent and choose Overview to view the agent cockpit.', 'Rendered by components/AgentOverviewTab.tsx and components/AgentEvidenceDrawer.tsx.'],
  ['components/KeyboardShortcutsOverlay.tsx', 'KeyboardShortcutsOverlay', '/agents', 'Open the authenticated application shell and press ? to show keyboard shortcuts.', 'Mounted by App.tsx for every authenticated route.'],
  ['components/RbacImporterPanel.tsx', 'RbacImporterPanel', '/rbac-analysis', 'Open RBAC Analysis with the rbac_analysis feature enabled and use the importer panel.', 'Rendered directly by pages/RbacAnalysisPage.tsx.'],
  ['components/DiscoveredWorkloadDrawer.tsx', 'DiscoveredWorkloadDrawer', '/discovery', 'Open Discovery and select a workload row to reveal its drawer.', 'Rendered directly by pages/DiscoveryPage.tsx.'],
  ['components/SignalBadge.tsx', 'SignalBadge', '/agents', 'Open Agents in demo mode to view signal badges on agent records.', 'Rendered by pages/AgentsPage.tsx; Agent Posture also mounts the badge.'],
  ['components/SuperCredInstructorPanel.tsx', 'SuperCredInstructorPanel', '/supercred', 'Open SuperCred as a superadmin to view Instructor Controls.', 'Rendered directly by pages/SuperCredPage.tsx.'],
  ['components/EvidenceDrawer.tsx', 'EvidenceDrawer', '/weave', 'Open The Weave and select an actor to reveal its evidence drawer.', 'Rendered directly by pages/WeavePage.tsx.'],
  ['components/OpenFindingsPanel.tsx', 'OpenFindingsPanel', '/compliance', 'Open Compliance Overview to view current open findings.', 'Rendered directly by views/Compliance.tsx.'],
  ['components/AgentCockpitTelemetry.tsx', 'AgentCockpitTelemetry', '/agents/demo-agent', 'Open the demo agent and choose Overview to view live cockpit telemetry.', 'Rendered through components/AgentCockpitSection.tsx on Agent Detail and Agents drawer states.'],
  ['components/trust/NodeDetailDrawer.tsx', 'NodeDetailDrawer', '/topology', 'Open Topology and select a trust node to reveal its detail drawer.', 'Rendered directly by pages/AgentTrustTopologyPage.tsx.'],
  ['components/trust/TrustGraph.tsx', 'TrustGraph', '/topology', 'Open Topology to view the rendered trust graph.', 'Rendered directly by pages/AgentTrustTopologyPage.tsx.'],
  ['components/CredentialActionsMenu.tsx', 'CredentialActionsMenu', '/agents/demo-agent', 'Open the demo agent and use the credential actions menu in its dossier header.', 'Rendered directly by pages/AgentDetailPage.tsx.'],
  ['components/AuditDetailDrawer.tsx', 'AuditDetailDrawer', '/audit', 'Open Audit Trail and select an event to reveal its detail drawer.', 'Rendered directly by views/AuditTrail.tsx.'],
  ['components/AddClusterModal.tsx', 'AddClusterModal', '/rbac-analysis', 'Open RBAC Analysis with the rbac_analysis feature enabled and choose Add cluster.', 'Rendered by pages/RbacAnalysisPage.tsx and pages/RbacExplorerPage.tsx.'],
  ['components/MetricsTopBar.tsx', 'MetricsTopBar', '/agents', 'Open the authenticated application shell on Agents to view the metrics top bar.', 'Rendered by components/TopNav.tsx.'],
  ['components/ConsentModal.tsx', 'ConsentModal', '/agents', 'Open an authenticated route when consent is enabled and the current user still requires consent.', 'Conditionally rendered by App.tsx from verified authentication and consent state.'],
  ['App.tsx', 'App', '/agents', 'Open the authenticated Agents route to render the application shell and routed page.', 'App.tsx owns the shared shell and application route tree.'],
  ['components/help/HelpCardComponents.tsx', 'CopyableCodeBlock', '/settings/help/deploy-sensor', 'Open Deploy Sensor Help to view copyable command blocks.', 'Rendered by pages/DeploySensorHelpPage.tsx and pages/OnboardAgentHelpPage.tsx.'],
  ['components/help/HelpCardComponents.tsx', 'DocLinkCard', '/settings/help/deploy-sensor', 'Open Deploy Sensor Help to view documentation link cards.', 'Rendered by pages/DeploySensorHelpPage.tsx and pages/OnboardAgentHelpPage.tsx.'],
]

for (const route of VERIFIED_ROUTE_SYMBOLS) routeSymbol(...route)

represent('components/AgentCockpitTelemetry.tsx', 'TelemetryErrorBoundary', {
  kind: 'internal',
  reason: 'Internal error boundary used by AgentCockpitTelemetry; its real rendered fallback is owned by that component rather than an independently navigable state.',
})

for (const [source, symbol, reason] of [
  ['components/SignalFusionDemoControls.tsx', 'SignalFusionDemoControls', 'No application imports found; pages/design-system/ExtraSpecimens.tsx names it only in DEFERRALS because its authentication and API transport are not injectable.'],
  ['components/onboarding/ProviderConfigureStep.tsx', 'ProviderConfigureStep', 'No application imports found; components/onboarding/OnboardingWizard.tsx references ProviderConfigureStep only in a comment stating that it is not rendered there.'],
  ['components/trust/TrustTopologyCanvas.tsx', 'TrustTopologyCanvas', 'No application imports found; the only repository reference outside components/trust/TrustTopologyCanvas.tsx is pages/design-system/componentCoverage.ts.'],
  ['components/CookieSettingsModal.tsx', 'CookieSettingsModal', 'No application render is reachable: App.tsx initializes cookieSettingsOpen to false and no production source calls setCookieSettingsOpen(true).'],
] as const) represent(source, symbol, { kind: 'unwired', reason })

const DIRECT_SPECIMENS: readonly [source: string, symbols: string, href: string][] = [
  ['components/CompactOperationalTable.tsx', 'CompactOperationalTable CompactDisclosure CompactEmail CompactObservedTime', '/design-system#compact-inventory'],
  ['pages/design-system/CompactInventorySpecimen.tsx', 'CompactInventorySpecimen', '/design-system#compact-inventory'],
  ['components/PixelLoader.tsx', 'PixelLoader', '/design-system#pixel-loader'],
  ['components/LoadingState.tsx', 'LoadingState', '/design-system#loading-state'],
  ['components/ErrorState.tsx', 'ErrorState', '/design-system#error-state'],
  ['pages/NotFoundPage.tsx', 'NotFoundPage', '/design-system#error-pages'],
  ['components/common/PagePattern.tsx', 'PageHeader PageLoader PagePattern', '/design-system#page-patterns'],
  ['pages/design-system/PagePatternSpecimen.tsx', 'PagePatternSpecimen', '/design-system#page-patterns'],
  ['components/EmptyState.tsx', 'EmptyState', '/design-system#empty-state'],

  ['components/StatusBadge.tsx', 'StatusBadge', '/design-system#status-badge'],
  ['components/HelpHint.tsx', 'HelpHint', '/design-system#help-hint'],
  ['components/DataTable.tsx', 'DataTable', '/design-system#data-table'],
  ['components/DataTableToolbar.tsx', 'DataTableToolbar ToolbarSearch ToolbarFacet ToolbarSelect ToolbarClear ToolbarCount', '/design-system#data-table'],
  ['components/DonutChart.tsx', 'DonutChart', '/design-system#donut-chart'],
  ['components/ProofConsole.tsx', 'ProofConsole', '/design-system#proof-console'],
  ['components/CredentialStateNotice.tsx', 'CredentialStateNotice', '/design-system#credential-state-notice'],
  ['components/DashKit.tsx', 'Pill StatCard Section Table', '/design-system#dash-kit'],
  ['components/ButtonWait.tsx', 'ButtonWait', '/design-system#button-wait'],
  ['components/SafeLink.tsx', 'SafeLink', '/design-system#safe-link'],
  ['components/AgentDeepLink.tsx', 'AgentDeepLink', '/design-system#agent-deep-link'],
  ['components/PageToc.tsx', 'PageTocLayout', '/design-system#tokens'],
  ['components/headers/primitives.tsx', symbolsFor('components/headers/primitives.tsx'), '/design-system#core-examples'],
  ['components/headers/variants.tsx', symbolsFor('components/headers/variants.tsx'), '/design-system/headers'],
  ['components/signals/WindowSelector.tsx', 'WindowSelector', '/design-system#context-examples'],
  ['components/signals/FindingsList.tsx', 'FindingsList', '/design-system#context-examples'],
  ['components/signals/SourceTable.tsx', 'SourceTable', '/design-system#context-examples'],
  ['components/signals/presentation.tsx', 'LabelChips', '/design-system#context-examples'],
  ['pages/admin/UserTable.tsx', 'RoleBadge StatusIndicator', '/design-system#context-examples'],
  ['pages/CollusionAccessPage.tsx', 'SubjectAgentLink GroupMembersLink CollaboratorGainsLinks', '/design-system#context-examples'],
  ['pages/design-system/CoreSpecimens.tsx', symbolsFor('pages/design-system/CoreSpecimens.tsx'), '/design-system#core-examples'],
  ['pages/design-system/ExtraSpecimens.tsx', symbolsFor('pages/design-system/ExtraSpecimens.tsx'), '/design-system#extra-examples'],
  ['pages/design-system/WorkflowSpecimens.tsx', symbolsFor('pages/design-system/WorkflowSpecimens.tsx'), '/design-system#workflow-examples'],
  ['pages/design-system/ContextSpecimens.tsx', 'ContextSpecimens', '/design-system#context-examples'],
  ['pages/DesignSystemPage.tsx', symbolsFor('pages/DesignSystemPage.tsx'), '/design-system'],
  ['pages/DesignSystemHeadersPage.tsx', symbolsFor('pages/DesignSystemHeadersPage.tsx'), '/design-system/headers'],
]

for (const [source, symbols, href] of DIRECT_SPECIMENS) represent(source, symbols, { kind: 'specimen', href })

function representFixtureNames(names: readonly string[], href: string): void {
  for (const name of names) {
    const matches = SOURCE_SYMBOLS.filter(([, symbols]) => symbols.split(' ').includes(name))
    if (matches.length !== 1) throw new Error(`Fixture symbol ${name} resolves to ${matches.length} exact sources`)
    represent(matches[0][0], name, { kind: 'specimen', href })
  }
}

representFixtureNames(CORE_SPECIMEN_NAMES, '/design-system#core-examples')
representFixtureNames(EXTRA_SPECIMEN_NAMES, '/design-system#extra-examples')
representFixtureNames(WORKFLOW_SPECIMEN_NAMES, '/design-system#workflow-examples')

represent('pages/DesignSystemCssLabPage.tsx', 'DesignSystemCssLabPage', {
  kind: 'route',
  href: '/design-system/css',
  state: 'Open the CSS Lab as a superadmin to inspect the isolated stylesheet experiments.',
  reason: 'The CSS lab is a separately routed design-system page rather than a fixed-prop specimen.',
})


represent('components/AuditDetailDrawer.tsx', 'renderSyntaxHighlightedJson', {
  kind: 'internal',
  reason: 'Internal JSX formatter used by AuditDetailDrawer; it is not a standalone visual component.',
})
represent('pages/ConnectorHelpPage.tsx', 'markdownComponents', {
  kind: 'internal',
  reason: 'Internal Markdown renderer map used by ConnectorHelpPage; it is not a standalone specimen.',
})
represent('components/common/FeatureGate.tsx', 'FeatureGate', {
  kind: 'guard',
  reason: 'Route guard that selects children or a fallback from feature-flag state; it has no independent visual surface.',
})
represent('auth/ProtectedRoute.tsx', 'ProtectedRoute', {
  kind: 'guard',
  reason: 'Authentication and onboarding guard that returns application routes or redirects, not an independent specimen.',
})
represent('App.tsx', 'SuperadminRoute AdminRoute GatedRoute', {
  kind: 'guard',
  reason: 'Authorization and feature-gate route guards that render children, loaders, or redirect; they are not visual specimens.',
})

for (const [source, symbol, reason] of [
  ['providers/FeatureFlagProvider.tsx', 'FeatureFlagProvider', 'Application feature-flag context provider with no independent visual output.'],
  ['auth/oidc.tsx', 'OidcProvider', 'OIDC context provider that supplies authentication state without an independent visual output.'],
  ['money/CurrencyContext.tsx', 'CurrencyProvider', 'Currency context provider that supplies formatting state without an independent visual output.'],
] as const) represent(source, symbol, { kind: 'provider', reason })

function scopeFor(source: string): CoverageScope {
  if (source.startsWith('components/')) return 'shared'
  if (source.startsWith('pages/design-system/') || source.startsWith('pages/DesignSystem')) return 'fixture'
  if (source.startsWith('providers/') || source.startsWith('auth/') || source.startsWith('money/') || source === 'App.tsx') return 'infrastructure'
  return 'page'
}

const UNREPRESENTED: Representation = {
  kind: 'unrepresented',
  reason: 'No safe fixed-prop specimen or verified reachable route state has been registered for this symbol.',
}

export const COMPONENT_COVERAGE: readonly ComponentCoverageEntry[] = SOURCE_SYMBOLS.flatMap(
  ([source, symbols]) => symbols.split(' ').map((symbol): ComponentCoverageEntry => ({
    source,
    symbol,
    scope: scopeFor(source),
    ...(representations.get(exactKey(source, symbol)) ?? UNREPRESENTED),
  } as ComponentCoverageEntry)),
)

export function coverageKey(entry: Pick<ComponentCoverageEntry, 'source' | 'symbol'>): string {
  return `${entry.source}#${entry.symbol}`
}
