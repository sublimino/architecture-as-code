export type Tone = 'healthy' | 'attention' | 'critical' | 'neutral' | 'identity'

export type Agent = {
  id: string
  name: string
  owner: string
  environment: string
  posture: number
  status: 'Trusted' | 'Needs review' | 'Contained'
  controls: string
  lastSeen: string
  tone: Tone
}

export const agents: Agent[] = [
  { id: 'cardvault', name: 'CardVault', owner: 'Payments platform', environment: 'Production', posture: 42, status: 'Needs review', controls: '4 failing', lastSeen: '2 min ago', tone: 'attention' },
  { id: 'policy-engine', name: 'Policy Engine', owner: 'Platform security', environment: 'Production', posture: 96, status: 'Trusted', controls: '18 passing', lastSeen: 'Now', tone: 'healthy' },
  { id: 'audit-exporter', name: 'Audit Exporter', owner: 'Assurance', environment: 'Production', posture: 88, status: 'Trusted', controls: '12 passing', lastSeen: '1 min ago', tone: 'healthy' },
  { id: 'sandbox-agent', name: 'Sandbox Agent', owner: 'Unassigned', environment: 'Development', posture: 61, status: 'Contained', controls: 'Unassessed', lastSeen: '3 hours ago', tone: 'critical' },
]

export const controls = [
  { id: 'SL-07', name: 'Credential rotation', framework: 'Signal Loom baseline', status: 'Failing', affected: 2, evidence: 'Observed 8 min ago', tone: 'critical' as Tone },
  { id: 'SL-12', name: 'Least-privilege access', framework: 'Signal Loom baseline', status: 'Needs evidence', affected: 3, evidence: 'Modeled from RBAC', tone: 'attention' as Tone },
  { id: 'SOC2-CC6.1', name: 'Logical access controls', framework: 'SOC 2', status: 'Passing', affected: 0, evidence: 'Observed now', tone: 'healthy' as Tone },
  { id: 'NIST-IA-5', name: 'Authenticator management', framework: 'NIST 800-53', status: 'Passing', affected: 0, evidence: 'Fixture-tested', tone: 'healthy' as Tone },
]

export const auditEvents = [
  { time: '10:42:18', title: 'Credential revoked', subject: 'spiffe://signalloom.local/cardvault', actor: 'demo-user', tone: 'critical' as Tone, detail: 'Lease 7d3c revoked after rotation policy failed.' },
  { time: '10:41:54', title: 'Control reassessed', subject: 'SL-07 · Credential rotation', actor: 'policy-engine', tone: 'attention' as Tone, detail: 'Two agents remain outside the 24-hour rotation window.' },
  { time: '10:39:03', title: 'Trust path observed', subject: 'CardVault → Payments API', actor: 'spire-server', tone: 'identity' as Tone, detail: 'mTLS relationship observed at the production boundary.' },
  { time: '10:34:27', title: 'Evidence package created', subject: 'SOC 2 · CC6.1', actor: 'audit-exporter', tone: 'healthy' as Tone, detail: '12 evidence items bound to policy version 34.' },
]

export const graphNodes = [
  { id: 'cardvault', position: { x: 40, y: 190 }, data: { label: 'CardVault', kind: 'Agent', status: 'Needs review', tone: 'attention', description: 'Production payment agent with an overdue credential.' }, type: 'loom' },
  { id: 'spire', position: { x: 300, y: 70 }, data: { label: 'SPIRE identity', kind: 'Identity', status: 'Observed', tone: 'identity', description: 'Workload identity attested by the local SPIRE server.' }, type: 'loom' },
  { id: 'bao', position: { x: 300, y: 310 }, data: { label: 'OpenBao lease', kind: 'Credential', status: 'Revoked', tone: 'critical', description: 'Dynamic credential lease revoked after policy failure.' }, type: 'loom' },
  { id: 'policy', position: { x: 580, y: 60 }, data: { label: 'Policy Engine', kind: 'Decision', status: 'Enforcing', tone: 'healthy', description: 'Evaluates workload access against policy version 34.' }, type: 'loom' },
  { id: 'payments', position: { x: 590, y: 270 }, data: { label: 'Payments API', kind: 'Service', status: 'Protected', tone: 'healthy', description: 'Target service requiring identity and an active credential.' }, type: 'loom' },
  { id: 'evidence', position: { x: 860, y: 155 }, data: { label: 'Audit evidence', kind: 'Evidence', status: 'Fresh', tone: 'neutral', description: 'Observed decision and revocation evidence, retained for assurance.' }, type: 'loom' },
] satisfies Array<{ id: string; position: { x: number; y: number }; data: Record<string, string>; type: string }>

export const graphEdges = [
  { id: 'e1', source: 'cardvault', target: 'spire', label: 'attested as', animated: true, style: { stroke: 'var(--identity)' } },
  { id: 'e2', source: 'cardvault', target: 'bao', label: 'lease revoked', style: { stroke: 'var(--critical)', strokeDasharray: '7 5' } },
  { id: 'e3', source: 'spire', target: 'policy', label: 'identity claims', style: { stroke: 'var(--accent)' } },
  { id: 'e4', source: 'bao', target: 'payments', label: 'credential denied', style: { stroke: 'var(--critical)', strokeDasharray: '3 5' } },
  { id: 'e5', source: 'policy', target: 'payments', label: 'authorizes', animated: true, style: { stroke: 'var(--healthy)' } },
  { id: 'e6', source: 'policy', target: 'evidence', label: 'records decision', style: { stroke: 'var(--muted)' } },
  { id: 'e7', source: 'payments', target: 'evidence', label: 'emits event', style: { stroke: 'var(--muted)' } },
]
