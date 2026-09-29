// Hardened demo fixtures for Federated Services (Surface 11).
// Exported fixtures and route matchers for demo mode.

import type {
  TrustZone,
  Federation,
  FederatedService,
  AttestationPolicy,
  SpiffeIdentity,
  FederationEvent,
  FederationSummaryResponse,
} from '../types/api'

export const TRUST_ZONES: TrustZone[] = [
  { name: 'signalloom-eu', domain: 'eu.signalloom.svc.cluster.local', clusters: 2, servers: 2, status: 'active' },
  { name: 'signalloom-us', domain: 'us.signalloom.svc.cluster.local', clusters: 1, servers: 1, status: 'active' },
  { name: 'partner-acme', domain: 'acme.partner.example', clusters: 1, servers: 1, status: 'active' },
]

export const FEDERATIONS: Federation[] = [
  { left: 'signalloom-eu', right: 'signalloom-us', mode: 'bidirectional', policy: 'ap-payments', status: 'federated' },
  { left: 'signalloom-eu', right: 'partner-acme', mode: 'one-way (eu -> acme)', policy: 'ap-partner-read', status: 'federated' },
  { left: 'signalloom-us', right: 'partner-acme', mode: 'pending bundle exchange', policy: 'ap-partner-read', status: 'connecting' },
]

export const FEDERATED_SERVICES: FederatedService[] = [
  { service: 'payments-api', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'payments.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'ledger-grpc', home: 'signalloom-eu', consumer: 'signalloom-us', endpoint: 'ledger.local:9443', transport: 'Cofide Go SDK', status: 'active' },
  { service: 'kyc-lookup', home: 'partner-acme', consumer: 'signalloom-eu', endpoint: 'kyc.local:8443', transport: 'xDS (Envoy)', status: 'active' },
  { service: 'settlement-feed', home: 'signalloom-us', consumer: 'partner-acme', endpoint: 'settle.local:8443', transport: 'Cofide Go SDK', status: 'connecting' },
]

export const POLICIES: AttestationPolicy[] = [
  { name: 'ap-payments', selector: 'k8s:ns:payments, k8s:sa:api', zones: 'eu, us' },
  { name: 'ap-partner-read', selector: 'k8s:ns:partner, k8s:label:federate=true', zones: 'eu, acme' },
  { name: 'ap-node-tpm', selector: 'tpm:ek_sha256:9f3c...', zones: 'eu, us' },
]

export const SPIFFE_IDS: SpiffeIdentity[] = [
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom', workload: 'dashboard', ns: 'fe-signalloom', sa: 'fe-signalloom', svid: 'X.509', expiry: '2026-08-02T18:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent', workload: 'agent', ns: 'fe-signalloom-agents', sa: 'cardvault-agent', svid: 'JWT', expiry: '2026-08-02T14:30:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/payments-api', workload: 'service', ns: 'payments', sa: 'payments-api', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://signalloom.demo/ns/payments/sa/ledger-grpc', workload: 'service', ns: 'payments', sa: 'ledger-grpc', svid: 'X.509', expiry: '2026-08-03T06:00:00Z' },
  { uri: 'spiffe://acme.partner.example/ns/kyc/sa/kyc-lookup', workload: 'service', ns: 'kyc', sa: 'kyc-lookup', svid: 'X.509', expiry: '2026-08-02T22:00:00Z' },
]

export const FEDERATION_EVENTS: FederationEvent[] = [
  { ts: '2026-08-02T09:14:22Z', zone: 'signalloom-eu', event: 'Bundle refreshed', detail: 'Trust bundle rotated (SHA-256: 9f3c...a1b2)', severity: 'info' },
  { ts: '2026-08-02T09:12:05Z', zone: 'signalloom-us', event: 'Federation established', detail: 'Bidirectional bundle exchange with signalloom-eu complete', severity: 'info' },
  { ts: '2026-08-02T08:58:33Z', zone: 'partner-acme', event: 'Bundle exchange pending', detail: 'Awaiting signalloom-us bundle acceptance', severity: 'pending' },
  { ts: '2026-08-02T08:45:01Z', zone: 'signalloom-eu', event: 'SVID issued', detail: 'payments-api X.509 SVID renewed (TTL 24h)', severity: 'info' },
  { ts: '2026-08-02T08:30:00Z', zone: 'signalloom-eu', event: 'Attestation passed', detail: 'cardvault-agent k8s workload attestation (SA match)', severity: 'info' },
]

export const SDK_SNIPPET = `import "github.com/cofide/cofide-sdk-go/cofide"

// No static secrets: the SDK fetches this workload's SVID from the
// local SPIRE agent over the SPIFFE Workload API, handles automatic
// rotation, and presents it to remote peers during mTLS handshake.

ctx := context.Background()
client, err := cofide.NewClient(ctx, cofide.WithTrustDomain("signalloom.eu"))
if err != nil {
    log.Fatalf("failed to initialize Cofide client: %v", err)
}
defer client.Close()

// Dial a federated service in signalloom-us:
// The transport validates the remote peer's SVID against the federated trust bundle.
conn, err := client.Dial(ctx, "payments.local:8443",
    cofide.WithTargetTrustDomain("signalloom.us"),
    cofide.WithAudience("payments-api"),
)
`

export const FEDERATION_SUMMARY: FederationSummaryResponse = {
  zones: TRUST_ZONES,
  federations: FEDERATIONS,
  services: FEDERATED_SERVICES,
  policies: POLICIES,
  identities: SPIFFE_IDS,
  events: FEDERATION_EVENTS,
}

function re(pattern: RegExp) {
  return (path: string) => pattern.test(path)
}

export const FEDERATION_ROUTES = [
  { method: 'GET', test: re(/^\/v1\/federation\/summary$/), data: () => FEDERATION_SUMMARY },
  { method: 'GET', test: re(/^\/federation\/summary$/), data: () => FEDERATION_SUMMARY },
  { method: 'GET', test: re(/^\/v1\/federation\/zones$/), data: () => TRUST_ZONES },
  { method: 'GET', test: re(/^\/federation\/zones$/), data: () => TRUST_ZONES },
  { method: 'GET', test: re(/^\/v1\/federation\/federations$/), data: () => FEDERATIONS },
  { method: 'GET', test: re(/^\/federation\/federations$/), data: () => FEDERATIONS },
  { method: 'GET', test: re(/^\/v1\/federation\/services$/), data: () => FEDERATED_SERVICES },
  { method: 'GET', test: re(/^\/federation\/services$/), data: () => FEDERATED_SERVICES },
  { method: 'GET', test: re(/^\/v1\/federation\/policies$/), data: () => POLICIES },
  { method: 'GET', test: re(/^\/federation\/policies$/), data: () => POLICIES },
  { method: 'GET', test: re(/^\/v1\/federation\/identities$/), data: () => SPIFFE_IDS },
  { method: 'GET', test: re(/^\/federation\/identities$/), data: () => SPIFFE_IDS },
  { method: 'GET', test: re(/^\/v1\/federation\/events$/), data: () => FEDERATION_EVENTS },
  { method: 'GET', test: re(/^\/federation\/events$/), data: () => FEDERATION_EVENTS },
]
