import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

// Mock useAuth0
const getAccessTokenSilently = vi.fn().mockResolvedValue('test-token')
vi.mock('../auth/oidc', () => ({
  useAuth0: () => ({ getAccessTokenSilently }),
}))

// Mock recharts to avoid SVG rendering issues in jsdom
vi.mock('recharts', () => ({
  ResponsiveContainer: ({ children }: { children: React.ReactNode }) => <div data-testid="responsive-container">{children}</div>,
  BarChart: ({ children }: { children: React.ReactNode }) => <div data-testid="bar-chart">{children}</div>,
  Bar: () => null,
  XAxis: () => null,
  YAxis: () => null,
  CartesianGrid: () => null,
  Tooltip: () => null,
  Cell: () => null,
}))

// Mock the API client
vi.mock('../api/client', () => ({
  api: {
    compliancePolicy: {
      frameworks: vi.fn().mockResolvedValue([
        {
          id: 'eu-ai-act',
          name: 'EU AI Act',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 10,
          passedControls: 7,
          failedControls: 3,
          totalExposure: { amount: 53200, currency: 'GBP' },
        },
        {
          id: 'nist-800-53',
          name: 'NIST 800-53',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 10,
          passedControls: 8,
          failedControls: 2,
          totalExposure: { amount: 45500, currency: 'GBP' },
        },
        {
          id: 'finos-aigf',
          name: 'FINOS AIGF',
          versions: ['v1.0', 'v2.0', 'v2.1'],
          totalControls: 11,
          passedControls: 8,
          failedControls: 3,
          totalExposure: { amount: 50500, currency: 'GBP' },
        },
      ]),
      summary: vi.fn().mockResolvedValue({
        totalChecks: 41,
        passed: 30,
        failed: 11,
        currency: 'GBP',
        totalAle: { amount: 195500, currency: 'GBP' },
        totalVar95: { amount: 858000, currency: 'GBP' },
        totalTvar: { amount: 1332000, currency: 'GBP' },
        totalCarried: { amount: 98700, currency: 'GBP' },
        scanTimestamp: '2026-07-27T12:00:00Z',
        frameworks: [],
      }),
      scan: vi.fn().mockResolvedValue({
        checks: [],
        summary: {
          totalChecks: 41,
          passed: 35,
          failed: 6,
          currency: 'GBP',
          totalAle: { amount: 195500, currency: 'GBP' },
          totalVar95: { amount: 858000, currency: 'GBP' },
          totalTvar: { amount: 1332000, currency: 'GBP' },
          totalCarried: { amount: 31100, currency: 'GBP' },
          scanTimestamp: '2026-07-27T12:01:00Z',
          frameworks: [],
        },
      }),
    },
    policies: {
      list: vi.fn().mockResolvedValue([
        {
          framework_id: 'eu-ai-act',
          active_version: 'v2.1.0',
          latest_version: 'v2.1.0',
          active_bundle: {
            id: 'eu-ai-act-v2.1.0',
            framework_id: 'eu-ai-act',
            version: 'v2.1.0',
            author: 'system',
            description: 'EU AI Act Rules',
            created_at: '2026-09-28T12:00:00Z',
            checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            rules: [
              {
                id: 'container-run-as-non-root',
                name: 'AI system container runs as non-root',
                cel_expression: 'object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)',
                severity: 'high',
                remediation: 'Set runAsNonRoot to true.',
              },
            ],
          },
          version_history: [
            {
              version: 'v2.1.0',
              author: 'system',
              description: 'Active release',
              created_at: '2026-09-28T12:00:00Z',
              rule_count: 1,
              checksum: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            },
            {
              version: 'v2.0.0',
              author: 'alice',
              description: 'Prior draft',
              created_at: '2026-09-20T10:00:00Z',
              rule_count: 1,
              checksum: 'a1b2c3d4e5f6',
            },
          ],
        },
      ]),
      registerBundle: vi.fn().mockResolvedValue({
        id: 'eu-ai-act-v2.1.1',
        version: 'v2.1.1',
      }),
      rollback: vi.fn().mockResolvedValue({
        message: 'Rolled back successfully',
        active_bundle: {
          id: 'eu-ai-act-v2.0.0',
          version: 'v2.0.0',
        },
      }),
      evaluate: vi.fn().mockResolvedValue({
        compliant: true,
      }),
    },
  },
}))

import CompliancePolicyPage from './CompliancePolicyPage'

function renderPage() {
  return render(
    <MemoryRouter>
      <CompliancePolicyPage />
    </MemoryRouter>,
  )
}

describe('CompliancePolicyPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders the Policy Compliance heading and breadcrumb navigation', async () => {
    renderPage()
    expect(screen.getByRole('heading', { level: 1, name: 'Policy Compliance' })).toBeInTheDocument()
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' })).toBeInTheDocument()
    expect(screen.getByText('Policy-as-Code & CEL Rules')).toBeInTheDocument()
  })

  it('mounts PolicyEditor with active bundle rules on default editor tab', async () => {
    renderPage()
    expect(await screen.findByTestId('policy-editor-container')).toBeInTheDocument()
    expect(screen.getByTestId('cel-code-textarea')).toBeInTheDocument()
    expect(screen.getByTestId('cel-diagnostic-valid')).toBeInTheDocument()
  })

  it('renders framework cards, stat cards, and chart after switching to overview tab', async () => {
    const user = userEvent.setup()
    renderPage()

    const overviewTab = screen.getByTestId('tab-overview')
    await user.click(overviewTab)

    expect(await screen.findByText('Total Checks')).toBeInTheDocument()
    expect(await screen.findByText('41')).toBeInTheDocument()
    const euMatches = await screen.findAllByText('EU AI Act')
    expect(euMatches.length).toBeGreaterThanOrEqual(1)
    expect(screen.getByTestId('bar-chart')).toBeInTheDocument()
  })

  it('calls the scan API when Scan Now is clicked', async () => {
    const { api } = await import('../api/client')
    const user = userEvent.setup()
    renderPage()

    await screen.findByTestId('policy-editor-container')
    await user.click(screen.getByRole('button', { name: /Scan Now/i }))

    await waitFor(() => {
      expect(api.compliancePolicy.scan).toHaveBeenCalled()
    })
  })

  it('calls registerBundle when Save New Version is clicked in editor', async () => {
    const { api } = await import('../api/client')
    const user = userEvent.setup()
    renderPage()

    await screen.findByTestId('policy-editor-container')
    const saveBtn = screen.getByTestId('save-policy-btn')
    await user.click(saveBtn)

    await waitFor(() => {
      expect(api.policies.registerBundle).toHaveBeenCalled()
    })
  })

  it('dispatches rollback when rollback action is confirmed in editor', async () => {
    const { api } = await import('../api/client')
    const user = userEvent.setup()
    renderPage()

    await screen.findByTestId('policy-editor-container')
    await user.click(screen.getByTestId('toggle-version-history-btn'))
    await user.click(screen.getByTestId('version-item-v2.0.0'))

    const rollbackBtn = screen.getByTestId('rollback-btn')
    await user.click(rollbackBtn)

    const confirmButtons = screen.getAllByRole('button', { name: /Rollback to v2.0.0/i })
    await user.click(confirmButtons[confirmButtons.length - 1])

    await waitFor(() => {
      expect(api.policies.rollback).toHaveBeenCalledWith(
        'test-token',
        expect.objectContaining({
          framework_id: 'eu-ai-act',
          target_version: 'v2.0.0',
        }),
      )
    })
  })
})
