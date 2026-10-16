import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import { api } from '../api/client'
import RemoteEnvironmentPage from './RemoteEnvironmentPage'

function renderPage(initialEntries = ['/settings/connectors/claude']) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <Routes>
        <Route path="/settings/connectors/:providerId" element={<RemoteEnvironmentPage />} />
        <Route path="/settings/connectors" element={<RemoteEnvironmentPage />} />
        <Route path="/connectors/:providerId" element={<RemoteEnvironmentPage />} />
      </Routes>
    </MemoryRouter>
  )
}

describe('RemoteEnvironmentPage', () => {
  it('renders environment header, badges, and credit balance', () => {
    renderPage(['/settings/connectors/claude'])

    // Breadcrumb
    expect(screen.getByText('Settings')).toBeInTheDocument()
    expect(screen.getByText('Connectors')).toBeInTheDocument()
    expect(screen.getByText(/Anthropic Claude \(cloud-dev\)/i)).toBeInTheDocument()

    // Environment name
    expect(screen.getByRole('heading', { level: 1, name: /cloud-dev/i })).toBeInTheDocument()

    // Badges
    expect(screen.getByText(/Cloud Hosting/i)).toBeInTheDocument()
    expect(screen.getByText(/Organization: Andy's Individual Org/i)).toBeInTheDocument()
    expect(screen.getByText(/ID: env_01CyCigBbDRSLTzSCyyHQ7eT/i)).toBeInTheDocument()
    expect(screen.getByText(/Last updated: 16m ago/i)).toBeInTheDocument()

    // Status and Credits
    expect(screen.getByText(/Active · Synchronized/i)).toBeInTheDocument()
    expect(screen.getByText('US$23.57')).toBeInTheDocument()
  })

  it('renders action bar with sync buttons and back to connectors link', () => {
    renderPage(['/settings/connectors/claude'])

    const syncNowBtn = screen.getByTestId('btn-env-sync-now')
    const syncLogsBtn = screen.getByTestId('btn-env-sync-logs')
    const backLink = screen.getByTestId('link-back-connectors')

    expect(syncNowBtn).toBeInTheDocument()
    expect(syncLogsBtn).toBeInTheDocument()
    expect(backLink).toBeInTheDocument()
    expect(backLink).toHaveAttribute('href', expect.stringContaining('/settings?tab=connectors'))

    // Trigger sync now action
    fireEvent.click(syncNowBtn)
    expect(screen.getByText(/Synchronized just now/i)).toBeInTheDocument()

    // Trigger sync logs toggle
    fireEvent.click(syncLogsBtn)
    expect(screen.getByText(/Synchronization Audit Logs/i)).toBeInTheDocument()
  })

  it('renders General section with hosting details', () => {
    renderPage(['/settings/connectors/claude'])

    expect(screen.getByRole('heading', { name: 'General' })).toBeInTheDocument()
    expect(screen.getByText("Can't be changed after creation")).toBeInTheDocument()
    expect(screen.getByText('What sessions in this environment are for')).toBeInTheDocument()
    expect(screen.getByText(/wrkspc_01/i)).toBeInTheDocument()
  })

  it('renders Network Egress and CEL Governance section with package managers, MCP servers, and allowed hosts', () => {
    renderPage(['/settings/connectors/claude'])

    expect(screen.getByRole('heading', { name: /Network Egress & CEL Governance/i })).toBeInTheDocument()
    expect(screen.getByText(/Outbound traffic is blocked except for what's allowed below/i)).toBeInTheDocument()

    expect(screen.getByText(/Allow package managers \(PyPI, npm\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Allow MCP servers configured on agent/i)).toBeInTheDocument()
    expect(screen.getByText(/0\/16 configured/i)).toBeInTheDocument()
    expect(screen.getByText(/Hostnames or IPv4 addresses, one per line/i)).toBeInTheDocument()

    // CEL Policy Assessment Card
    expect(screen.getByTestId('cel-policy-card')).toBeInTheDocument()
    expect(screen.getByText(/cis-5.2.8: NET_RAW capability not held/i)).toBeInTheDocument()
    expect(screen.getByText(/egress-confinement: No unrestricted 0.0.0.0\/0 egress/i)).toBeInTheDocument()
    expect(screen.getByText(/mcp-attestation: MCP servers require SPIFFE identity/i)).toBeInTheDocument()

    const passBadges = screen.getAllByText('PASS')
    expect(passBadges.length).toBeGreaterThanOrEqual(3)
  })

  it('renders Container Packages & Metadata section', () => {
    renderPage(['/settings/connectors/claude'])

    expect(screen.getByRole('heading', { name: /Container Packages & Metadata/i })).toBeInTheDocument()
    expect(screen.getByText('No packages beyond the standard image.')).toBeInTheDocument()
    expect(screen.getByText(/"owner": "andy"/i)).toBeInTheDocument()
    expect(screen.getByText(/"cluster": "osramp-kind"/i)).toBeInTheDocument()
  })

  it('renders Connected Agents & Workloads section with running agent metadata and claim controls', async () => {
    renderPage(['/settings/connectors/claude'])

    expect(screen.getByRole('heading', { name: /Connected Agents & Workloads/i })).toBeInTheDocument()
    expect(screen.getByText('Daily News Jokester')).toBeInTheDocument()
    expect(screen.getByText(/ses_01CyCigBbDRSLTzSCyyHQ7eT/i)).toBeInTheDocument()
    expect(screen.getByText('active')).toBeInTheDocument()
    expect(screen.getByText('claude-opus-5-5')).toBeInTheDocument()
    expect(screen.getByText(/Andrew Martin \(User\)/i)).toBeInTheDocument()

    const dossierLink = screen.getByRole('link', { name: /View Dossier/i })
    expect(dossierLink).toHaveAttribute('href', '/agents?selected=agent_01FoEhnKF9QsC5DGmuELhm7G&drawer=agent_01FoEhnKF9QsC5DGmuELhm7G')

    const claimSpy = vi.spyOn(api.agents, 'claim').mockResolvedValueOnce({
      claim_id: 'claim-test-1',
      tenant_id: 'default',
      status: 'claimed',
      claimed_at: new Date().toISOString(),
    } as any)

    const claimBtn = screen.getByTestId('btn-claim-agent-agent_01FoEhnKF9QsC5DGmuELhm7G')
    fireEvent.click(claimBtn)
    await waitFor(() => {
      expect(claimSpy).toHaveBeenCalledWith(expect.any(String), 'agent_01FoEhnKF9QsC5DGmuELhm7G', expect.objectContaining({
        pod_name: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      }))
    })
    expect(await screen.findByRole('button', { name: /Claimed ✓/i })).toBeDisabled()
    claimSpy.mockRestore()
  })

  it('deep links to specific tab via URL search parameter and allows switching tabs', () => {
    renderPage(['/settings/connectors/claude?tab=agents'])

    // Agents tab should be active
    const agentsTab = screen.getByTestId('env-tab-agents')
    expect(agentsTab).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('heading', { name: /Connected Agents & Workloads/i })).toBeInTheDocument()

    // General and Network sections should NOT be rendered when tab=agents
    expect(screen.queryByRole('heading', { name: /General/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /Network Egress & CEL Governance/i })).not.toBeInTheDocument()

    // Clicking Network tab switches view
    const networkTab = screen.getByTestId('env-tab-network')
    fireEvent.click(networkTab)
    expect(networkTab).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('heading', { name: /Network Egress & CEL Governance/i })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /Connected Agents & Workloads/i })).not.toBeInTheDocument()
  })

  it('defaults to claude when providerId is not specified or fallback', () => {
    renderPage(['/settings/connectors'])

    expect(screen.getByText(/Anthropic Claude \(cloud-dev\)/i)).toBeInTheDocument()
  })

  it('dynamically pulls back updated remote agent name via API call', async () => {
    const getSpy = vi.spyOn(api.agents, 'get').mockResolvedValueOnce({
      id: 'agent_01FoEhnKF9QsC5DGmuELhm7G',
      name: 'Daily News Jokester (Live Renamed)',
      tenant_id: 'default',
      lifecycle_state: 'active',
      compliance_summary: { total_controls: 12, passing: 12, failing: 0, pending: 0, posture_score: 100 },
    } as any)

    renderPage(['/settings/connectors/claude'])

    expect(await screen.findByText('Daily News Jokester (Live Renamed)')).toBeInTheDocument()
    expect(getSpy).toHaveBeenCalledWith(expect.any(String), 'agent_01FoEhnKF9QsC5DGmuELhm7G')
    getSpy.mockRestore()
  })
})
