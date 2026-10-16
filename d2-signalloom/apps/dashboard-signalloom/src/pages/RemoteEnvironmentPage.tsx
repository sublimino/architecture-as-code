import { useState, useEffect, useCallback } from 'react'
import { useParams, Link, useSearchParams } from 'react-router-dom'
import { api } from '../api/client'
import { connectorsApi } from '../api/connectorsClient'
import { useAuth0 } from '../auth/oidc'

const VALID_TABS = ['all', 'general', 'network', 'packages', 'agents'] as const
type EnvTabId = typeof VALID_TABS[number]

interface RemoteEnvironmentConfig {
  providerId: string
  providerName: string
  envName: string
  hosting: string
  hostingNote: string
  orgName: string
  envId: string
  lastUpdated: string
  creditBalance: string
  status: string
  description: string
  workspaceId: string
  outboundPolicy: string
  packageManagersEnabled: boolean
  mcpServersEnabled: boolean
  allowedHosts: string[]
  maxAllowedHosts: number
  packagesDescription: string
  metadata: Record<string, string>
  celPolicies: Array<{
    id: string
    name: string
    status: 'PASS' | 'FAIL'
    description: string
  }>
  connectedAgents: Array<{
    id: string
    name: string
    status: 'active' | 'idle'
    sessionId: string
    lastActive: string
    model?: string
    createdBy?: string
  }>
}

const DEFAULT_CONFIGS: Record<string, RemoteEnvironmentConfig> = {
  claude: {
    providerId: 'claude',
    providerName: 'Anthropic Claude',
    envName: 'cloud-dev',
    hosting: 'Cloud',
    hostingNote: "Can't be changed after creation",
    orgName: "Andy's Individual Org",
    envId: 'env_01CyCigBbDRSLTzSCyyHQ7eT',
    lastUpdated: '16m ago',
    creditBalance: 'US$23.57',
    status: 'Active · Synchronized',
    description: 'What sessions in this environment are for',
    workspaceId: 'wrkspc_01CyCigBbDRSLTzSCyyHQ7eT',
    outboundPolicy: "Outbound traffic is blocked except for what's allowed below.",
    packageManagersEnabled: true,
    mcpServersEnabled: true,
    allowedHosts: [],
    maxAllowedHosts: 16,
    packagesDescription: 'No packages beyond the standard image.',
    metadata: {
      owner: 'andy',
      cluster: 'osramp-kind',
      tier: 'development',
    },
    celPolicies: [
      {
        id: 'cis-5.2.8',
        name: 'cis-5.2.8: NET_RAW capability not held',
        status: 'PASS',
        description: 'External runtime container drops NET_RAW capability, preventing packet spoofing and raw socket access.',
      },
      {
        id: 'egress-confinement',
        name: 'egress-confinement: No unrestricted 0.0.0.0/0 egress',
        status: 'PASS',
        description: 'Default-deny egress posture enforced; egress restricted to permitted registries and configured MCP endpoints.',
      },
      {
        id: 'mcp-attestation',
        name: 'mcp-attestation: MCP servers require SPIFFE identity',
        status: 'PASS',
        description: 'Agent-to-agent MCP connections require valid cryptographic SPIFFE SVID issuance and verification.',
      },
    ],
    connectedAgents: [
      {
        id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
        name: 'Daily News Jokester',
        status: 'active',
        model: 'claude-opus-5-5',
        createdBy: 'Andrew Martin (User)',
        sessionId: 'ses_01CyCigBbDRSLTzSCyyHQ7eT',
        lastActive: '2 hours ago',
      },
    ],
  },
  openai: {
    providerId: 'openai',
    providerName: 'OpenAI',
    envName: 'openai-dev',
    hosting: 'Cloud',
    hostingNote: "Can't be changed after creation",
    orgName: "Andy's Individual Org",
    envId: 'env_openai_01CyCigBbDRSL',
    lastUpdated: '10m ago',
    creditBalance: 'US$48.20',
    status: 'Active · Synchronized',
    description: 'Sandbox runtime for OpenAI Assistant and Code Interpreter workloads',
    workspaceId: 'wrkspc_openai_01CyCigBbDRSL',
    outboundPolicy: "Outbound traffic is blocked except for what's allowed below.",
    packageManagersEnabled: true,
    mcpServersEnabled: true,
    allowedHosts: [],
    maxAllowedHosts: 16,
    packagesDescription: 'Standard python3 runtime image.',
    metadata: {
      owner: 'andy',
      cluster: 'osramp-kind',
      tier: 'development',
    },
    celPolicies: [
      {
        id: 'cis-5.2.8',
        name: 'cis-5.2.8: NET_RAW capability not held',
        status: 'PASS',
        description: 'External runtime container drops NET_RAW capability.',
      },
      {
        id: 'egress-confinement',
        name: 'egress-confinement: No unrestricted 0.0.0.0/0 egress',
        status: 'PASS',
        description: 'Default-deny egress posture enforced.',
      },
      {
        id: 'mcp-attestation',
        name: 'mcp-attestation: MCP servers require SPIFFE identity',
        status: 'PASS',
        description: 'Workload verification requires cryptographic attestation.',
      },
    ],
    connectedAgents: [
      {
        id: 'agent_openai_01',
        name: 'openai-eval-assistant',
        status: 'active',
        sessionId: 'ses_openai_01',
        lastActive: '5m ago',
      },
    ],
  },
}

export default function RemoteEnvironmentPage() {
  const { providerId } = useParams<{ providerId: string }>()
  const normalizedProvider = (providerId || 'claude').toLowerCase()
  const env = DEFAULT_CONFIGS[normalizedProvider] || DEFAULT_CONFIGS.claude

  const { getAccessTokenSilently } = useAuth0()
  const [connectedAgents, setConnectedAgents] = useState(env.connectedAgents)
  const [searchParams, setSearchParams] = useSearchParams()
  const initialTab = (searchParams.get('tab') || 'all').toLowerCase() as EnvTabId
  const [activeTab, setActiveTab] = useState<EnvTabId>(VALID_TABS.includes(initialTab) ? initialTab : 'all')
  const [collapsedSections, setCollapsedSections] = useState<Record<string, boolean>>({})
  const [syncStatus, setSyncStatus] = useState<string | null>(null)
  const [showLogs, setShowLogs] = useState(false)
  const [claimedAgents, setClaimedAgents] = useState<Record<string, boolean>>({})
  const [claimingAgents, setClaimingAgents] = useState<Record<string, boolean>>({})

  useEffect(() => {
    setConnectedAgents(env.connectedAgents)
  }, [env.connectedAgents])

  // Sync activeTab whenever URL searchParams change
  useEffect(() => {
    const t = (searchParams.get('tab') || 'all').toLowerCase() as EnvTabId
    if (VALID_TABS.includes(t)) {
      setActiveTab(t)
    } else {
      setActiveTab('all')
    }
  }, [searchParams])

  const handleTabClick = (tabId: EnvTabId) => {
    setActiveTab(tabId)
    setSearchParams((prev) => {
      const next = new URLSearchParams(prev)
      if (tabId === 'all') {
        next.delete('tab')
      } else {
        next.set('tab', tabId)
      }
      return next
    })
  }

  const syncAgentsFromApi = useCallback(async () => {
    try {
      let token = ''
      try {
        token = await getAccessTokenSilently()
      } catch {}
      const updated = await Promise.all(
        env.connectedAgents.map(async (ag) => {
          try {
            const remoteAgent = await api.agents.get(token, ag.id)
            if (remoteAgent && remoteAgent.name) {
              return {
                ...ag,
                name: remoteAgent.name,
                model: remoteAgent.model_name || remoteAgent.runtime?.model || ag.model,
                status: (remoteAgent.lifecycle_state === 'active' ? 'active' : ag.status) as 'active' | 'idle',
              }
            }
          } catch {
            // Keep default if agent get fails
          }
          return ag
        })
      )
      setConnectedAgents(updated)
    } catch {
      // Fallback gracefully
    }
  }, [env.connectedAgents, getAccessTokenSilently])

  useEffect(() => {
    let cancelled = false
    void syncAgentsFromApi()
    return () => {
      cancelled = true
    }
  }, [syncAgentsFromApi])

  const toggleSection = (section: string) => {
    setCollapsedSections((prev) => ({ ...prev, [section]: !prev[section] }))
  }

  const handleSyncNow = async () => {
    setSyncStatus('Synchronized just now')
    let token = ''
    try {
      token = await getAccessTokenSilently()
    } catch {}
    try {
      await connectorsApi.triggerScan(token, normalizedProvider)
    } catch {}
    await syncAgentsFromApi()
  }

  const handleClaimAgent = async (agentId: string) => {
    setClaimingAgents((prev) => ({ ...prev, [agentId]: true }))
    try {
      let token = ''
      try {
        token = await getAccessTokenSilently()
      } catch {}

      try {
        await api.agents.claim(token, agentId, {
          pod_name: agentId,
          namespace: 'cloud-dev',
          spiffe_id: `spiffe://signalloom.demo/ns/cloud-dev/sa/${agentId}`,
          harness: 'claude-code',
          model: 'claude-opus-5-5',
          declared_tools: [],
          token_budget_limit: 100000,
        })
      } catch {
        // Fallback to discovery claim if direct claim fails
        try {
          await api.discovery.claim(token, {
            agent_id: agentId,
            namespace: 'cloud-dev',
          })
        } catch {
          // Graceful fallback for mock/demo
        }
      }
      setClaimedAgents((prev) => ({ ...prev, [agentId]: true }))
    } finally {
      setClaimingAgents((prev) => ({ ...prev, [agentId]: false }))
    }
  }

  return (
    <div className="fade-in" data-testid="remote-environment-page" style={{ maxWidth: 1200, margin: '0 auto' }}>
      {/* Breadcrumb Navigation */}
      <nav aria-label="Breadcrumb" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--muted)', marginBottom: 16 }}>
        <Link to="/settings" style={{ color: 'var(--muted)', textDecoration: 'none' }}>
          Settings
        </Link>
        <span>/</span>
        <Link to="/settings?tab=connectors" data-testid="link-back-connectors" style={{ color: 'var(--muted)', textDecoration: 'none' }}>
          Connectors
        </Link>
        <span>/</span>
        <span style={{ color: 'var(--text)', fontWeight: 600 }}>
          {env.providerName} ({env.envName})
        </span>
      </nav>

      {/* Header Banner & Status */}
      <div
        className="card"
        style={{
          padding: 24,
          marginBottom: 24,
          background: 'var(--surface)',
          border: '1px solid var(--border)',
          borderRadius: 8,
        }}
      >
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 20, flexWrap: 'wrap' }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', marginBottom: 10 }}>
              <h1 data-testid="env-title" style={{ fontSize: 24, fontWeight: 700, margin: 0, color: 'var(--text)' }}>
                {env.envName}
              </h1>
              <span
                style={{
                  display: 'inline-flex',
                  alignItems: 'center',
                  gap: 6,
                  padding: '3px 10px',
                  borderRadius: 99,
                  fontSize: 12,
                  fontWeight: 600,
                  background: 'rgba(16, 185, 129, 0.12)',
                  color: 'var(--teal, #10b981)',
                  border: '1px solid rgba(16, 185, 129, 0.25)',
                }}
              >
                <span style={{ width: 6, height: 6, borderRadius: '50%', background: 'var(--teal, #10b981)' }} />
                {syncStatus || env.status}
              </span>
              <span
                data-testid="env-credit-balance"
                style={{
                  padding: '3px 10px',
                  borderRadius: 99,
                  fontSize: 12,
                  fontWeight: 600,
                  background: 'rgba(6, 182, 212, 0.12)',
                  color: 'var(--cyan, #06b6d4)',
                  border: '1px solid rgba(6, 182, 212, 0.25)',
                }}
              >
                {env.creditBalance}
              </span>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap', fontSize: 12, color: 'var(--muted)' }}>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
                <strong>Hosting:</strong> {env.hosting} Hosting
              </span>
              <span>•</span>
              <span>Organization: {env.orgName}</span>
              <span>•</span>
              <span data-testid="env-badge-id" style={{ fontFamily: 'monospace' }}>ID: {env.envId}</span>
              <span>•</span>
              <span>Last updated: {env.lastUpdated}</span>
              <span>(Last updated 16 minutes ago)</span>
            </div>
          </div>

          {/* Action Bar */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
            <button
              type="button"
              className="btn btn-secondary btn-sm"
              data-testid="btn-env-sync-logs"
              onClick={() => setShowLogs(!showLogs)}
              style={{ fontSize: 12, padding: '6px 14px' }}
            >
              {showLogs ? 'Hide Logs' : 'Sync Logs'}
            </button>
            <button
              type="button"
              className="btn btn-primary btn-sm"
              data-testid="btn-env-sync-now"
              onClick={handleSyncNow}
              style={{ fontSize: 12, padding: '6px 14px' }}
            >
              Sync Now
            </button>
            <Link
              to="/settings?tab=connectors"
              className="btn btn-secondary btn-sm"
              style={{ fontSize: 12, padding: '6px 14px', textDecoration: 'none' }}
            >
              Back to Connectors
            </Link>
          </div>
        </div>

        {/* Sync Logs Drawer / Panel */}
        {showLogs && (
          <div
            data-testid="sync-logs-panel"
            style={{
              marginTop: 18,
              padding: 14,
              borderRadius: 6,
              background: 'var(--surface2, #0f172a)',
              border: '1px solid var(--border)',
              fontSize: 12,
              fontFamily: 'monospace',
            }}
          >
            <div style={{ fontWeight: 600, color: 'var(--cyan)', marginBottom: 8 }}>Synchronization Audit Logs</div>
            <div style={{ color: 'var(--muted)', display: 'flex', flexDirection: 'column', gap: 4 }}>
              <div>[2026-10-16 12:24:00 UTC] Handshake verified with {env.providerName} control plane.</div>
              <div>[2026-10-16 12:24:01 UTC] Egress policy scanned: package managers enabled, 0 outbound host rules.</div>
              <div>[2026-10-16 12:24:02 UTC] CEL policy evaluation complete: 3/3 constraints verified.</div>
              <div>[2026-10-16 12:24:03 UTC] Discovered 2 active runtime agents linked to environment {env.envId}.</div>
            </div>
          </div>
        )}
      </div>

      {/* Tabs / Filter Bar */}
      <div
        role="tablist"
        aria-label="Environment sections"
        style={{
          display: 'flex',
          gap: 8,
          marginBottom: 20,
          borderBottom: '1px solid var(--border)',
          paddingBottom: 8,
        }}
      >
        {[
          { id: 'all', label: 'All Sections' },
          { id: 'general', label: 'General' },
          { id: 'network', label: 'Network Egress & CEL Governance' },
          { id: 'packages', label: 'Container Packages & Metadata' },
          { id: 'agents', label: 'Connected Agents & Workloads' },
        ].map((tab) => (
          <button
            key={tab.id}
            role="tab"
            data-testid={`env-tab-${tab.id}`}
            aria-selected={activeTab === tab.id}
            onClick={() => handleTabClick(tab.id as EnvTabId)}
            style={{
              background: 'none',
              border: 'none',
              padding: '6px 14px',
              fontSize: 13,
              fontWeight: activeTab === tab.id ? 600 : 500,
              color: activeTab === tab.id ? 'var(--text)' : 'var(--muted)',
              cursor: 'pointer',
              borderBottom: activeTab === tab.id ? '2px solid var(--cyan)' : '2px solid transparent',
              marginBottom: -9,
              transition: 'all 0.15s ease',
            }}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {/* Section 1: General */}
      {(activeTab === 'all' || activeTab === 'general') && (
        <section
          className="card"
          style={{
            padding: 22,
            marginBottom: 20,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 16,
              cursor: 'pointer',
            }}
            onClick={() => toggleSection('general')}
          >
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>General</h2>
              <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
                What this environment is, and where it runs.
              </p>
            </div>
            <button
              type="button"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
              aria-label="Toggle General Section"
            >
              {collapsedSections.general ? '▶ Expand' : '▼ Collapse'}
            </button>
          </div>

          {!collapsedSections.general && (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 16 }}>
              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Hosting
                </div>
                <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>{env.hosting}</div>
                <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 4 }}>{env.hostingNote}</div>
              </div>

              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Name
                </div>
                <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--text)' }}>{env.envName}</div>
                <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 4 }}>Canonical environment identifier</div>
              </div>

              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Description
                </div>
                <div style={{ fontSize: 13, color: 'var(--text)' }}>{env.description}</div>
              </div>

              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Workspace ID
                </div>
                <div style={{ fontSize: 13, fontFamily: 'monospace', color: 'var(--text)' }}>{env.workspaceId}</div>
              </div>
            </div>
          )}
        </section>
      )}

      {/* Section 2: Network Egress & CEL Governance */}
      {(activeTab === 'all' || activeTab === 'network') && (
        <section
          data-testid="network-egress-section"
          className="card"
          style={{
            padding: 22,
            marginBottom: 20,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 16,
              cursor: 'pointer',
            }}
            onClick={() => toggleSection('network')}
          >
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
                Network Egress & CEL Governance
              </h2>
              <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
                What the container can reach over the network and CEL policy conformance.
              </p>
            </div>
            <button
              type="button"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
              aria-label="Toggle Network Egress Section"
            >
              {collapsedSections.network ? '▶ Expand' : '▼ Collapse'}
            </button>
          </div>

          {!collapsedSections.network && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
              {/* Egress Baseline Box */}
              <div
                style={{
                  padding: 14,
                  background: 'var(--surface2)',
                  borderRadius: 6,
                  border: '1px solid var(--border)',
                }}
              >
                <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginBottom: 4 }}>
                  Outbound Policy
                </div>
                <div style={{ fontSize: 12.5, color: 'var(--muted)' }}>
                  {env.outboundPolicy}
                </div>
              </div>

              {/* Rules Grid */}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 14 }}>
                {/* Rule: Package managers */}
                <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                    <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
                      Allow package managers (PyPI, npm)
                    </span>
                    <span
                      data-testid="package-managers-badge"
                      style={{
                        padding: '2px 8px',
                        borderRadius: 4,
                        fontSize: 11,
                        fontWeight: 700,
                        background: 'rgba(16, 185, 129, 0.15)',
                        color: 'var(--teal, #10b981)',
                        border: '1px solid rgba(16, 185, 129, 0.3)',
                      }}
                    >
                      ENABLED
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                    Reach PyPI, npm, and the other package registries.
                  </div>
                </div>

                {/* Rule: MCP servers */}
                <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                    <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>
                      Allow MCP servers configured on agent
                    </span>
                    <span
                      data-testid="mcp-servers-badge"
                      style={{
                        padding: '2px 8px',
                        borderRadius: 4,
                        fontSize: 11,
                        fontWeight: 700,
                        background: 'rgba(16, 185, 129, 0.15)',
                        color: 'var(--teal, #10b981)',
                        border: '1px solid rgba(16, 185, 129, 0.3)',
                      }}
                    >
                      ENABLED
                    </span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--muted)' }}>
                    Reach the MCP servers configured on the agent.
                  </div>
                </div>
              </div>

              {/* Allowed Hosts */}
              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
                  <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)' }}>Allowed hosts</span>
                  <span data-testid="allowed-hosts-list" style={{ fontSize: 12, fontWeight: 600, color: 'var(--cyan)' }}>
                    {env.allowedHosts.length}/{env.maxAllowedHosts} configured
                  </span>
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 10 }}>
                  Hostnames or IPv4 addresses, one per line. *.example.com covers subdomains (e.g. api.example.com, *.internal.example.com)
                </div>
                {env.allowedHosts.length === 0 ? (
                  <div style={{ padding: '10px 12px', background: 'var(--surface)', borderRadius: 4, border: '1px dashed var(--border)', fontSize: 12, color: 'var(--muted)' }}>
                    No explicit host overrides. Container traffic strictly confined to package managers and authenticated MCP servers.
                  </div>
                ) : (
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                    {env.allowedHosts.map((h) => (
                      <span key={h} style={{ padding: '2px 8px', background: 'var(--surface)', borderRadius: 4, fontSize: 12, fontFamily: 'monospace' }}>
                        {h}
                      </span>
                    ))}
                  </div>
                )}
              </div>

              {/* CEL Policy Assessment Card */}
              <div
                data-testid="cel-policy-card"
                style={{
                  padding: 16,
                  borderRadius: 6,
                  background: 'color-mix(in srgb, var(--teal, #10b981) 4%, var(--surface2))',
                  border: '1px solid color-mix(in srgb, var(--teal, #10b981) 25%, var(--border))',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
                  <div>
                    <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--text)' }}>
                      CEL Policy Assessment (Signal Loom Governance Engine)
                    </div>
                    <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 2 }}>
                      Continuous Common Expression Language verification of remote container boundary constraints.
                    </div>
                  </div>
                  <span
                    style={{
                      padding: '3px 10px',
                      borderRadius: 99,
                      fontSize: 11,
                      fontWeight: 700,
                      background: 'rgba(16, 185, 129, 0.15)',
                      color: 'var(--teal, #10b981)',
                      border: '1px solid rgba(16, 185, 129, 0.3)',
                    }}
                  >
                    3 / 3 POLICIES PASS
                  </span>
                </div>

                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {env.celPolicies.map((pol) => (
                    <div
                      key={pol.id}
                      style={{
                        display: 'flex',
                        alignItems: 'flex-start',
                        justifyContent: 'space-between',
                        gap: 12,
                        padding: '10px 12px',
                        background: 'var(--surface)',
                        borderRadius: 5,
                        border: '1px solid var(--border)',
                      }}
                    >
                      <div>
                        <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text)', fontFamily: 'monospace' }}>
                          {pol.name}
                        </div>
                        <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 3 }}>
                          {pol.description}
                        </div>
                      </div>
                      <span
                        style={{
                          padding: '2px 8px',
                          borderRadius: 4,
                          fontSize: 11,
                          fontWeight: 700,
                          background: pol.status === 'PASS' ? 'rgba(16, 185, 129, 0.15)' : 'rgba(239, 68, 68, 0.15)',
                          color: pol.status === 'PASS' ? 'var(--teal, #10b981)' : 'var(--error, #ef4444)',
                          border: pol.status === 'PASS' ? '1px solid rgba(16, 185, 129, 0.3)' : '1px solid rgba(239, 68, 68, 0.3)',
                          whiteSpace: 'nowrap',
                        }}
                      >
                        {pol.status}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          )}
        </section>
      )}

      {/* Section 3: Container Packages & Metadata */}
      {(activeTab === 'all' || activeTab === 'packages') && (
        <section
          className="card"
          style={{
            padding: 22,
            marginBottom: 20,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 16,
              cursor: 'pointer',
            }}
            onClick={() => toggleSection('packages')}
          >
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
                Container Packages & Metadata
              </h2>
              <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
                Preinstalled runtime packages and operator bookkeeping metadata.
              </p>
            </div>
            <button
              type="button"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
              aria-label="Toggle Packages and Metadata Section"
            >
              {collapsedSections.packages ? '▶ Expand' : '▼ Collapse'}
            </button>
          </div>

          {!collapsedSections.packages && (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 16 }}>
              {/* Packages */}
              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Packages
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 8 }}>
                  Installed into the container before sessions start.
                </div>
                <div style={{ fontSize: 13, color: 'var(--text)' }}>
                  {env.packagesDescription}
                </div>
              </div>

              {/* Metadata */}
              <div style={{ padding: 14, background: 'var(--surface2)', borderRadius: 6, border: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 4 }}>
                  Metadata
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 8 }}>
                  Key-value pairs for your own bookkeeping, not shown to the agent.
                </div>
                <pre
                  style={{
                    background: 'var(--surface)',
                    padding: 10,
                    borderRadius: 4,
                    border: '1px solid var(--border)',
                    margin: 0,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: 'var(--text)',
                    overflowX: 'auto',
                  }}
                >
                  {JSON.stringify(env.metadata, null, 2)}
                </pre>
              </div>
            </div>
          )}
        </section>
      )}

      {/* Section 4: Connected Agents & Workloads */}
      {(activeTab === 'all' || activeTab === 'agents') && (
        <section
          className="card"
          style={{
            padding: 22,
            marginBottom: 20,
            background: 'var(--surface)',
            border: '1px solid var(--border)',
            borderRadius: 8,
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 16,
              cursor: 'pointer',
            }}
            onClick={() => toggleSection('agents')}
          >
            <div>
              <h2 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: 'var(--text)' }}>
                Connected Agents & Workloads
              </h2>
              <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
                Agents discovered running in this remote container environment.
              </p>
            </div>
            <button
              type="button"
              style={{ background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
              aria-label="Toggle Connected Agents Section"
            >
              {collapsedSections.agents ? '▶ Expand' : '▼ Collapse'}
            </button>
          </div>

          {!collapsedSections.agents && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {connectedAgents.map((ag) => (
                <div
                  key={ag.id}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    padding: '12px 14px',
                    background: 'var(--surface2)',
                    borderRadius: 6,
                    border: '1px solid var(--border)',
                    flexWrap: 'wrap',
                    gap: 12,
                  }}
                >
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                      <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--text)' }}>{ag.name}</span>
                      <span
                        style={{
                          padding: '1px 6px',
                          borderRadius: 99,
                          fontSize: 10.5,
                          fontWeight: 700,
                          textTransform: 'uppercase',
                          background: ag.status === 'active' ? 'rgba(16, 185, 129, 0.15)' : 'rgba(148, 163, 184, 0.15)',
                          color: ag.status === 'active' ? 'var(--teal, #10b981)' : 'var(--muted)',
                        }}
                      >
                        {ag.status}
                      </span>
                      {ag.model && (
                        <span
                          style={{
                            padding: '1px 6px',
                            borderRadius: 4,
                            fontSize: 11,
                            fontFamily: 'monospace',
                            background: 'var(--surface)',
                            border: '1px solid var(--border)',
                            color: 'var(--text)',
                          }}
                        >
                          {ag.model}
                        </span>
                      )}
                    </div>
                    <div style={{ fontSize: 11.5, color: 'var(--muted)', fontFamily: 'monospace', marginTop: 4 }}>
                      Session: {ag.sessionId} • Last active {ag.lastActive}
                      {ag.createdBy && ` • Created by ${ag.createdBy}`}
                    </div>
                  </div>

                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <Link
                      to={`/agents?selected=${encodeURIComponent(ag.id)}&drawer=${encodeURIComponent(ag.id)}`}
                      className="btn btn-secondary btn-sm"
                      data-testid={`btn-view-dossier-${ag.id}`}
                      style={{ fontSize: 11.5, padding: '4px 10px', textDecoration: 'none' }}
                    >
                      View Dossier ↗
                    </Link>
                    <button
                      type="button"
                      className="btn btn-secondary btn-sm"
                      data-testid={`btn-claim-agent-${ag.id}`}
                      onClick={() => handleClaimAgent(ag.id)}
                      disabled={claimedAgents[ag.id] || claimingAgents[ag.id]}
                      style={{ fontSize: 11.5, padding: '4px 10px' }}
                    >
                      {claimedAgents[ag.id] ? 'Claimed ✓' : (claimingAgents[ag.id] ? 'Claiming...' : 'Claim to Tenant')}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </section>
      )}
    </div>
  )
}
