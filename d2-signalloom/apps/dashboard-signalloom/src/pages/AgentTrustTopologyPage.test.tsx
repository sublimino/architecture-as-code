import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import AgentTrustTopologyPage, { trustEdges, trustNodes } from './AgentTrustTopologyPage'

describe('AgentTrustTopologyPage', () => {
  it('never represents hardcoded topology as runtime-observed', () => {
    expect([...trustNodes, ...trustEdges].every(item => item.evidence !== 'observed')).toBe(true)
    render(<AgentTrustTopologyPage />)
    expect(screen.getByText(/No relationship on this page is runtime-observed/i)).toBeInTheDocument()
    expect(screen.getAllByText('Runtime-observed').length).toBeGreaterThan(0)
  })

  it('uses canonical SPIFFE, agent-trust service accounts, and five-minute OpenBao TTLs', () => {
    const agents = trustNodes.filter(node => node.kind === 'agent' && node.location === 'in-cluster')
    expect(agents.every(node => /^spiffe:\/\/signalloom\.demo\/platform\/signalloom\/tenant\/[^/]+\/project\/[^/]+\/agent\/[^/]+$/.test(node.spiffeId ?? ''))).toBe(true)
    expect(agents.every(node => node.namespace?.startsWith('agent-trust-') && node.serviceAccount?.startsWith('agent-trust-') && node.ttl === '5m' && node.audience === 'openbao-supercredential')).toBe(true)
  })

  it('models every requested cloud provider with lower-assurance external controls', () => {
    for (const label of ['AWS Lambda', 'Google Cloud Run', 'Azure Container Apps']) {
      const node = trustNodes.find(item => item.label === label)
      expect(node).toMatchObject({ location: 'external', evidence: 'modeled', assurance: 'lower' })
      expect(node?.providerAssertion && node?.keyCustody && node?.rotationReload && node?.trustBundle && node?.deEnrollment && node?.productionGap).toBeTruthy()
    }
  })

  it('offers an evidence plane and visible provenance for every selectable edge', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.click(screen.getByRole('button', { name: /^Evidence plane$/i }))
    expect(screen.getByRole('button', { name: /^Evidence plane$/i })).toHaveAttribute('aria-pressed', 'true')
    trustEdges.forEach(edge => expect(screen.getAllByRole('button', { name: new RegExp(edge.source) }).length).toBeGreaterThan(0))
    expect(screen.getAllByText(/Fixture-tested|Modeled/).length).toBeGreaterThan(0)
  })

  it('does not reintroduce unrelated tenant nodes or edges after filtering', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.selectOptions(screen.getByLabelText('Tenant'), 'acme')
    expect(screen.getByText('Acme tenant')).toBeInTheDocument()
    expect(screen.queryByText('Northstar tenant')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /cross-tenant network denial/i })).not.toBeInTheDocument()
  })

  it('retains cloud providers and their ancestors for external filtering', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.selectOptions(screen.getByLabelText('Location'), 'external')
    expect(screen.getByText('AWS Lambda')).toBeInTheDocument(); expect(screen.getByText('Google Cloud Run')).toBeInTheDocument(); expect(screen.getByText('Azure Container Apps')).toBeInTheDocument()
    expect(screen.getByText('Acme Payments')).toBeInTheDocument(); expect(screen.getByText('Signal Loom platform')).toBeInTheDocument()
  })

  it('distinguishes network blocks from application authorization rejections', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    await user.click(screen.getByRole('button', { name: /^Authorization plane$/i })); await user.click(screen.getByRole('button', { name: /cross-project application denial/i }))
    expect(screen.getByText('Application authorization rejection')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /^Network plane$/i })); await user.click(screen.getByRole('button', { name: /cross-tenant network denial/i }))
    expect(screen.getByText('Network block')).toBeInTheDocument()
  })

  it('selects node details through a native keyboard button', async () => {
    const user = userEvent.setup(); render(<AgentTrustTopologyPage />)
    const button = screen.getByRole('button', { name: /planner · in-cluster/i })
    button.focus(); await user.keyboard('{Enter}')
    expect(screen.getByRole('heading', { name: 'planner' })).toBeInTheDocument()
    expect(screen.getByText(/spiffe:\/\/signalloom\.demo\/platform\/signalloom/i)).toBeInTheDocument()
  })

  it('keeps stale and unknown semantics out of the green observed treatment', () => {
    render(<AgentTrustTopologyPage />)
    // Was pinned to var(--amber). The legend now greys the evidence states that
    // have no instances on this page and marks them "· none" — Runtime-observed
    // and Stale are both empty by design, and rendering "Runtime-observed" in
    // confident green as the first and highest-contrast item in the strip, with
    // a 0 in the StatCard directly above it, had the page arguing against its
    // own thesis.
    //
    // The property this test is named for is unchanged and still asserted: the
    // stale entry must never take the colour reserved for runtime-observed.
    const stale = screen.getByText(/Stale \/ dotted warning/i)
    expect(stale).not.toHaveStyle({ color: 'var(--teal)' })
    expect(stale).toHaveStyle({ color: 'var(--muted)' })
    expect(screen.getAllByText(/unknown/).length).toBeGreaterThan(0)
  })
})
