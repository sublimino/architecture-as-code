/**
 * Fake fixture data for the Signal Weave page in demo mode.
 *
 * Tells the story of a shadow AI agent — an LLM-backed service that was
 * provisioned outside governance, discovered via network anomalies, and
 * correlated across layers until it became actionable.
 */
import type {
  SignalObservation,
  ProvisionalActor,
  CoverageStatement,
  SignalLayer,
  FidelityTier,
} from './weaveApi'

// ─── Observations ────────────────────────────────────────────────────────────

const observations: SignalObservation[] = [
  {
    id: 'obs-net-001',
    timestamp: '2026-08-15T02:14:00Z',
    layer: 'network_egress',
    fidelity: 'strong',
    source: 'cilium-hubble',
    confidence: 0.82,
    actor_hint: 'pod/shadow-llm-proxy-7f8b9',
    raw_evidence_ref: 'hubble://flows/2026-08-15/net-001',
    labels: { namespace: 'ml-workloads', dst: 'api.openai.com:443' },
    description: 'Outbound HTTPS to api.openai.com from unregistered pod in ml-workloads namespace — 847 requests in 6h window.',
  },
  {
    id: 'obs-net-002',
    timestamp: '2026-08-15T03:22:00Z',
    layer: 'network_egress',
    fidelity: 'suggestive',
    source: 'cilium-hubble',
    confidence: 0.61,
    actor_hint: 'pod/shadow-llm-proxy-7f8b9',
    raw_evidence_ref: 'hubble://flows/2026-08-15/net-002',
    labels: { namespace: 'ml-workloads', dst: 'storage.googleapis.com:443' },
    description: 'Secondary egress to GCS storage bucket — model artifact retrieval pattern consistent with warm-start cache.',
  },
  {
    id: 'obs-id-001',
    timestamp: '2026-08-15T02:12:00Z',
    layer: 'identity_authorization',
    fidelity: 'definitive',
    source: 'opa-audit-log',
    confidence: 0.95,
    actor_hint: 'sa/ml-inference-sa',
    raw_evidence_ref: 'opa://decisions/2026-08-15/id-001',
    labels: { serviceaccount: 'ml-inference-sa', action: 'secrets.get' },
    description: 'Service account ml-inference-sa read 3 secrets in kube-system — no RBAC binding exists in governance registry.',
  },
  {
    id: 'obs-id-002',
    timestamp: '2026-08-15T04:05:00Z',
    layer: 'identity_authorization',
    fidelity: 'strong',
    source: 'k8s-audit-log',
    confidence: 0.78,
    actor_hint: 'sa/ml-inference-sa',
    raw_evidence_ref: 'k8s-audit://2026-08-15/id-002',
    labels: { serviceaccount: 'ml-inference-sa', resource: 'configmaps' },
    description: 'Same SA patched a ConfigMap in default namespace with base64-encoded model configuration.',
  },
  {
    id: 'obs-app-001',
    timestamp: '2026-08-15T02:30:00Z',
    layer: 'application_saas',
    fidelity: 'strong',
    source: 'wiz-cspm',
    confidence: 0.74,
    raw_evidence_ref: 'wiz://findings/app-001',
    labels: { finding_type: 'shadow_ai', severity: 'high' },
    description: 'Wiz flagged unregistered AI workload: container image contains transformers library and exposes /v1/chat/completions endpoint.',
  },
  {
    id: 'obs-ep-001',
    timestamp: '2026-08-15T05:10:00Z',
    layer: 'endpoint_host',
    fidelity: 'suggestive',
    source: 'falco',
    confidence: 0.55,
    actor_hint: 'pod/shadow-llm-proxy-7f8b9',
    raw_evidence_ref: 'falco://alerts/ep-001',
    labels: { rule: 'write_below_etc', container: 'shadow-llm-proxy' },
    description: 'Container wrote to /etc/resolv.conf — DNS reconfiguration attempt to bypass corporate resolver.',
  },
  {
    id: 'obs-beh-001',
    timestamp: '2026-08-15T06:00:00Z',
    layer: 'behavioural',
    fidelity: 'circumstantial',
    source: 'signal-loom-ml',
    confidence: 0.42,
    raw_evidence_ref: 'sl-ml://models/beh-001',
    labels: { model: 'request-cadence-v2', anomaly_score: '0.87' },
    description: 'Request cadence anomaly: pod issues API calls at 142/min during off-hours vs cluster baseline of 12/min.',
  },
  {
    id: 'obs-beh-002',
    timestamp: '2026-08-15T07:30:00Z',
    layer: 'behavioural',
    fidelity: 'suggestive',
    source: 'signal-loom-ml',
    confidence: 0.58,
    raw_evidence_ref: 'sl-ml://models/beh-002',
    labels: { model: 'data-exfil-detector-v1', risk: 'medium' },
    description: 'Outbound payload sizes follow bimodal distribution — consistent with prompt/response rather than bulk transfer.',
  },
]

// ─── Provisional Actors ──────────────────────────────────────────────────────

const actors: ProvisionalActor[] = [
  {
    id: 'actor-shadow-llm-001',
    status: 'actionable',
    confidence: 0.87,
    display_name: 'Shadow LLM Proxy',
    correlation_keys: ['pod/shadow-llm-proxy-7f8b9', 'sa/ml-inference-sa', 'ns/ml-workloads'],
    created_at: '2026-08-15T02:14:00Z',
    updated_at: '2026-08-15T07:30:00Z',
    evidence_chain: [
      { observation_id: 'obs-id-001', layer: 'identity_authorization', fidelity: 'definitive', contribution: 'Unregistered service account accessing secrets — strongest identity signal.', timestamp: '2026-08-15T02:12:00Z' },
      { observation_id: 'obs-net-001', layer: 'network_egress', fidelity: 'strong', contribution: 'High-volume outbound to OpenAI API confirms AI workload classification.', timestamp: '2026-08-15T02:14:00Z' },
      { observation_id: 'obs-app-001', layer: 'application_saas', fidelity: 'strong', contribution: 'CSPM finding independently confirms shadow AI workload.', timestamp: '2026-08-15T02:30:00Z' },
      { observation_id: 'obs-net-002', layer: 'network_egress', fidelity: 'suggestive', contribution: 'GCS egress pattern consistent with model artifact retrieval.', timestamp: '2026-08-15T03:22:00Z' },
      { observation_id: 'obs-id-002', layer: 'identity_authorization', fidelity: 'strong', contribution: 'Same SA writing config outside its namespace scope.', timestamp: '2026-08-15T04:05:00Z' },
      { observation_id: 'obs-ep-001', layer: 'endpoint_host', fidelity: 'suggestive', contribution: 'DNS reconfiguration attempt suggests evasion intent.', timestamp: '2026-08-15T05:10:00Z' },
      { observation_id: 'obs-beh-001', layer: 'behavioural', fidelity: 'circumstantial', contribution: 'Off-hours request cadence anomaly adds temporal context.', timestamp: '2026-08-15T06:00:00Z' },
      { observation_id: 'obs-beh-002', layer: 'behavioural', fidelity: 'suggestive', contribution: 'Payload distribution confirms conversational API pattern.', timestamp: '2026-08-15T07:30:00Z' },
    ],
  },
  {
    id: 'actor-data-scraper-002',
    status: 'provisional',
    confidence: 0.45,
    display_name: 'Data Enrichment Scraper',
    correlation_keys: ['pod/enrichment-cron-a3f2', 'ns/data-pipeline'],
    created_at: '2026-08-14T18:00:00Z',
    updated_at: '2026-08-15T04:00:00Z',
    evidence_chain: [
      { observation_id: 'obs-net-003', layer: 'network_egress', fidelity: 'suggestive', contribution: 'Periodic outbound to multiple SaaS APIs outside approved list.', timestamp: '2026-08-14T18:00:00Z' },
      { observation_id: 'obs-beh-003', layer: 'behavioural', fidelity: 'circumstantial', contribution: 'Cron-like scheduling pattern with 15-minute intervals.', timestamp: '2026-08-15T04:00:00Z' },
    ],
  },
  {
    id: 'actor-promoted-scanner',
    status: 'promoted',
    confidence: 0.92,
    display_name: 'Rogue Vulnerability Scanner',
    agent_registry_id: 'tenant-demo:agent-scanner',
    correlation_keys: ['pod/vuln-scan-nightly', 'sa/scanner-sa'],
    created_at: '2026-08-10T09:00:00Z',
    updated_at: '2026-08-13T14:00:00Z',
    promoted_at: '2026-08-13T14:00:00Z',
    evidence_chain: [
      { observation_id: 'obs-net-010', layer: 'network_egress', fidelity: 'definitive', contribution: 'Scan traffic to internal subnets outside approved scope.', timestamp: '2026-08-10T09:00:00Z' },
      { observation_id: 'obs-id-010', layer: 'identity_authorization', fidelity: 'definitive', contribution: 'SA bound to cluster-admin without approval record.', timestamp: '2026-08-10T09:05:00Z' },
      { observation_id: 'obs-app-010', layer: 'application_saas', fidelity: 'strong', contribution: 'Scanner reports exfiltrated to unapproved external endpoint.', timestamp: '2026-08-11T02:00:00Z' },
    ],
  },
]

// ─── Coverage Statement ──────────────────────────────────────────────────────

const coverage: CoverageStatement = {
  covered_layers: [
    'network_egress',
    'identity_authorization',
    'application_saas',
    'endpoint_host',
    'behavioural',
  ],
  blind_spots: [
    { id: 'bs-001', layer: 'network_egress', description: 'Local transport (Unix socket, localhost) — no Hubble visibility on loopback.' },
    { id: 'bs-002', layer: 'network_egress', description: 'Encrypted C2 channels using domain-fronting or steganographic payloads.' },
    { id: 'bs-003', layer: 'identity_authorization', description: 'Session inheritance via leaked tokens — no provenance chain for bearer reuse.' },
    { id: 'bs-004', layer: 'cloud_control_plane', description: 'All cloud API signals — cloud control plane collector not deployed.' },
    { id: 'bs-005', layer: 'protocol', description: 'All protocol-level signals — protocol analyser not deployed.' },
  ],
  closeable_by_issuance: ['bs-003', 'bs-001'],
  deployment_coverage: '5 of 7 signal layers active. 2 layers require additional collector deployment.',
}

// ─── Route matcher type (matches fakeData.ts pattern) ───────────────────────

type Match = {
  method: string
  test: (path: string) => boolean
  data: (path: string, body?: unknown) => unknown
}

const re = (r: RegExp) => (path: string) => r.test(path)

export const WEAVE_ROUTES: Match[] = [
  { method: 'GET', test: re(/^\/signals\/observations$/), data: () => observations },
  { method: 'GET', test: re(/^\/signals\/actors$/), data: () => actors },
  { method: 'GET', test: re(/^\/signals\/actors\/[^/]+$/), data: () => actors[0] },
  { method: 'POST', test: re(/^\/signals\/actors\/[^/]+\/promote$/), data: () => ({ status: 'promoted' }) },
  { method: 'GET', test: re(/^\/signals\/coverage$/), data: () => coverage },
  { method: 'POST', test: re(/^\/signals\/correlate$/), data: () => ({ status: 'correlation_complete' }) },
  { method: 'POST', test: re(/^\/signals\/collectors\/seed$/), data: () => ({ seeded: observations.length }) },
]

/** Exposed for tests that need the raw fixture shapes. */
export const fakeWeaveData = {
  observations,
  actors,
  coverage,
}
