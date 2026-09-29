/**
 * Fake fixture data for the Signal Weave page in demo mode.
 *
 * Tells the story of a shadow AI agent: an LLM-backed service that was
 * provisioned outside governance, discovered via network anomalies, and
 * correlated across layers until it became actionable.
 */
import type {
  SignalObservation,
  ProvisionalActor,
  CoverageStatement,
  StoreStats,
  AuthorizationChain,
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
    description: 'Outbound HTTPS to api.openai.com from unregistered pod in ml-workloads namespace (847 requests in 6h window).',
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
    description: 'Secondary egress to GCS storage bucket (model artifact retrieval pattern consistent with warm-start cache).',
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
    description: 'Service account ml-inference-sa read 3 secrets in kube-system (no RBAC binding exists in governance registry).',
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
    description: 'Container wrote to /etc/resolv.conf: DNS reconfiguration attempt to bypass corporate resolver.',
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
    description: 'Outbound payload sizes follow bimodal distribution, consistent with prompt/response rather than bulk transfer.',
  },
  {
    id: 'obs-cloud-001',
    timestamp: '2026-08-15T02:15:00Z',
    layer: 'cloud_control_plane',
    fidelity: 'definitive',
    source: 'k8s-apiserver-audit',
    confidence: 0.98,
    actor_hint: 'sa/ml-inference-sa',
    raw_evidence_ref: 'k8s-audit://default/secrets/vault-token',
    labels: { verb: 'get', resource: 'secrets', namespace: 'default', name: 'vault-token', status_code: '200' },
    description: 'K8s APIServer audit: get secret default/vault-token by sa/ml-inference-sa',
  },
  {
    id: 'obs-cloud-002',
    timestamp: '2026-08-15T02:45:00Z',
    layer: 'cloud_control_plane',
    fidelity: 'definitive',
    source: 'gcp-cloud-audit',
    confidence: 0.96,
    actor_hint: 'deployer-sa@osramp-demo.iam.gserviceaccount.com',
    raw_evidence_ref: 'gcp-audit://osramp-demo/projects/osramp-demo',
    labels: { service_name: 'iam.googleapis.com', method_name: 'google.iam.v1.SetIamPolicy', project_id: 'osramp-demo' },
    description: 'GCP Audit: deployer-sa called google.iam.v1.SetIamPolicy on project osramp-demo',
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
      { observation_id: 'obs-id-001', layer: 'identity_authorization', fidelity: 'definitive', contribution: 'Unregistered service account accessing secrets: strongest identity signal.', timestamp: '2026-08-15T02:12:00Z' },
      { observation_id: 'obs-net-001', layer: 'network_egress', fidelity: 'strong', contribution: 'High-volume outbound to OpenAI API confirms AI workload classification.', timestamp: '2026-08-15T02:14:00Z' },
      { observation_id: 'obs-cloud-001', layer: 'cloud_control_plane', fidelity: 'definitive', contribution: 'APIServer audit log proves direct secret token harvesting.', timestamp: '2026-08-15T02:15:00Z' },
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
    'cloud_control_plane',
  ],
  blind_spots: [
    { id: 'bs-001', layer: 'network_egress', description: 'Local transport (Unix socket, localhost): no Hubble visibility on loopback.' },
    { id: 'bs-002', layer: 'network_egress', description: 'Encrypted C2 channels using domain-fronting or steganographic payloads.' },
    { id: 'bs-003', layer: 'identity_authorization', description: 'Session inheritance via leaked tokens: no provenance chain for bearer reuse.' },
    { id: 'bs-005', layer: 'protocol', description: 'All protocol-level signals: protocol analyser not deployed.' },
  ],
  closeable_by_issuance: ['bs-003', 'bs-001'],
  deployment_coverage: '6 of 7 signal layers active. 1 layer requires additional collector deployment.',
}

// ─── Store Stats ────────────────────────────────────────────────────────────

const storeStats: StoreStats = {
  total_observations: observations.length,
  observations_by_layer: observations.reduce<Record<string, number>>((acc, o) => {
    acc[o.layer] = (acc[o.layer] || 0) + 1
    return acc
  }, {}),
  observations_by_fidelity: observations.reduce<Record<string, number>>((acc, o) => {
    acc[o.fidelity] = (acc[o.fidelity] || 0) + 1
    return acc
  }, {}),
  actor_count: actors.length,
  actors_by_status: actors.reduce<Record<string, number>>((acc, a) => {
    acc[a.status] = (acc[a.status] || 0) + 1
    return acc
  }, {}),
  last_ingestion: observations.length > 0
    ? observations.reduce((latest, o) => o.timestamp > latest ? o.timestamp : latest, observations[0].timestamp)
    : null,
  store_type: '*store.FrostDBStore',
}

// ─── Authorization Chains ───────────────────────────────────────────────────

const authorizationChains: Record<string, AuthorizationChain> = {
  'actor-shadow-llm-001': {
    action: 'High-volume outbound HTTPS requests to api.openai.com',
    agentIdentity: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    actsOnBehalfOf: 'system:serviceaccount:fe-signalloom-agents:agent-cardvault-sa acts-on-behalf-of security-admin@controlplane.io (authz: k8s-impersonation-policy)',
    principal: 'security-admin@controlplane.io',
    decision: 'authorized:actionable',
    confidence: 0.87,
    evidenceRefs: [
      'obs-id-001',
      'obs-net-001',
      'obs-cloud-001',
      'obs-app-001',
      'opa://decisions/2026-08-15/id-001',
      'k8s-audit://default/secrets/vault-token',
      'hubble://flows/2026-08-15/net-001',
    ],
    attestationGitoid: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    complete: true,
    actorId: 'actor-shadow-llm-001',
    canonicalId: 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa',
    aliases: ['pod/shadow-llm-proxy-7f8b9', 'sa/ml-inference-sa', 'ns/ml-workloads'],
  },
  'actor-data-scraper-002': {
    action: 'Periodic SaaS API outbound exfiltration',
    agentIdentity: 'pod/enrichment-cron-a3f2',
    actsOnBehalfOf: 'pod/enrichment-cron-a3f2 acts-on-behalf-of data-pipeline@corp.internal',
    principal: 'data-pipeline@corp.internal',
    decision: 'evaluated:provisional',
    confidence: 0.45,
    evidenceRefs: ['obs-net-003', 'obs-beh-003'],
    attestationGitoid: 'f4a1c24298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852c966',
    complete: true,
    actorId: 'actor-data-scraper-002',
    canonicalId: 'pod/enrichment-cron-a3f2',
  },
  'actor-promoted-scanner': {
    action: 'Automated vulnerability port scan and report exfiltration',
    agentIdentity: 'tenant-demo:agent-scanner',
    actsOnBehalfOf: 'sa/scanner-sa acts-on-behalf-of security-ops@controlplane.io (authz: cluster-admin-binding)',
    principal: 'security-ops@controlplane.io',
    decision: 'authorized:promoted',
    confidence: 0.92,
    evidenceRefs: ['obs-net-010', 'obs-id-010', 'obs-app-010'],
    attestationGitoid: 'a1b2c3d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcdef0',
    complete: true,
    actorId: 'actor-promoted-scanner',
    canonicalId: 'tenant-demo:agent-scanner',
  },
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
  {
    method: 'GET',
    test: re(/^\/signals\/actors\/[^/]+\/authorization/),
    data: (path: string) => {
      const match = path.match(/^\/signals\/actors\/([^/?]+)\/authorization/)
      const id = match ? match[1] : 'actor-shadow-llm-001'
      return authorizationChains[id] || authorizationChains['actor-shadow-llm-001']
    },
  },
  {
    method: 'GET',
    test: re(/^\/(?:api\/v1\/)?(?:signals\/)?authorization/),
    data: (path: string) => {
      const url = new URL(path, 'http://localhost')
      const actionId = url.searchParams.get('action_id') || url.searchParams.get('action')
      const actorId = url.searchParams.get('actor_id')
      if (actionId) {
        const found = authorizationChains[actionId] || Object.values(authorizationChains).find(c => c.action === actionId || c.action.includes(actionId) || c.actorId === actionId)
        if (found) {
          return {
            chains: [found],
            total: 1,
            complete_count: found.complete ? 1 : 0,
            kpi_fraction: 1.0,
          }
        }
        // Synthesize dynamic 7-hop chain for this actionId
        const dynamicChain: AuthorizationChain = {
          action: actionId,
          agentIdentity: actorId || 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/sa-order-agent',
          actsOnBehalfOf: '[kagent-planner -> data-pipeline-agent, data-pipeline-agent -> order-executor] (authz: k8s-impersonation-policy)',
          principal: 'secops@signal-loom.ai',
          decision: 'authorized:evaluated',
          confidence: 0.98,
          evidenceRefs: [
            `frostdb:seg-0x${actionId.replace(/[^a-f0-9]/gi, '').slice(0, 8) || '4a9b8f'}`,
            `webhook:audit-log-0x${actionId.replace(/[^a-f0-9]/gi, '').slice(0, 8) || '88f2'}`,
            'opa://decisions/2026-09-10/001',
            'hubble://flows/2026-09-10/net-001',
          ],
          attestationGitoid: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          complete: true,
          actorId: actorId || 'actor-dynamic',
          canonicalId: actorId || 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/sa-order-agent',
        }
        return {
          chains: [dynamicChain],
          total: 1,
          complete_count: 1,
          kpi_fraction: 1.0,
        }
      }
      return {
        chains: Object.values(authorizationChains),
        total: Object.keys(authorizationChains).length,
        complete_count: Object.values(authorizationChains).filter((c) => c.complete).length,
        kpi_fraction: 1.0,
      }
    },
  },
  { method: 'POST', test: re(/^\/signals\/actors\/[^/]+\/promote$/), data: () => ({ status: 'promoted' }) },
  { method: 'GET', test: re(/^\/signals\/coverage$/), data: () => coverage },
  { method: 'POST', test: re(/^\/signals\/correlate$/), data: () => ({ status: 'correlation_complete' }) },
  { method: 'GET', test: re(/^\/signals\/store\/stats$/), data: () => storeStats },
  { method: 'POST', test: re(/^\/signals\/collectors\/seed$/), data: () => ({ seeded: observations.length }) },
]

/** Exposed for tests that need the raw fixture shapes. */
export const fakeWeaveData = {
  observations,
  actors,
  coverage,
  storeStats,
  authorizationChains,
}
