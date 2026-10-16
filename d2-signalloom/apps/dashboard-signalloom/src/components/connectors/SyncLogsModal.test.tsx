import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import SyncLogsModal from './SyncLogsModal'
import { connectorsApi, type SyncResult } from '../../api/connectorsClient'

const mockSyncResult: SyncResult = {
  provider_id: 'claude',
  synced_at: '2026-10-16T12:00:00.000Z',
  duration_ms: 142,
  status: 'success',
  records_scanned: {
    agents: 3,
    models: 4,
    environments: 1,
    tools: 2,
  },
  policies_evaluated: {
    egress_rules: 2,
    violations: 0,
  },
  logs: [
    {
      id: 'log-1',
      timestamp: '2026-10-16T12:00:00.010Z',
      level: 'info',
      message: 'Initiating discovery sync with Anthropic Claude API...',
    },
    {
      id: 'log-2',
      timestamp: '2026-10-16T12:00:00.050Z',
      level: 'debug',
      message: 'Discovered model catalog: claude-3-5-sonnet-20241022',
      endpoint: 'GET /v1/models',
      status_code: 200,
      duration_ms: 142,
      details: {
        models: ['claude-3-5-sonnet-20241022', 'claude-3-haiku-20240307'],
        default_context: 200000,
      },
    },
    {
      id: 'log-3',
      timestamp: '2026-10-16T12:00:00.090Z',
      level: 'warn',
      message: 'Environment cloud-dev env_01CyCigBbDRSLTzSCyyHQ7eT nearing max allowed hosts',
    },
    {
      id: 'log-4',
      timestamp: '2026-10-16T12:00:00.120Z',
      level: 'error',
      message: 'Failed to probe auxiliary telemetry gateway at 10.0.0.99',
    },
  ],
}

vi.mock('../../api/connectorsClient', () => ({
  connectorsApi: {
    getSyncLogs: vi.fn(),
    triggerScan: vi.fn(),
  },
}))

vi.mock('../../auth/superadmin', () => ({
  useSuperadmin: vi.fn(() => [false, vi.fn()]),
}))

vi.mock('../../auth/oidc', () => ({
  useAuth0: vi.fn(() => ({
    getAccessTokenSilently: vi.fn().mockResolvedValue('test-token'),
  })),
}))

describe('SyncLogsModal', () => {
  const onClose = vi.fn()
  const onRescan = vi.fn().mockResolvedValue(undefined)

  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(connectorsApi.getSyncLogs).mockResolvedValue(mockSyncResult)
    vi.mocked(connectorsApi.triggerScan).mockResolvedValue(mockSyncResult)
  })

  it('renders sync summary, record counts, and log entries', async () => {
    render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        onRescan={onRescan}
        isSuperadmin={false}
      />,
    )

    // Verify header details
    expect(screen.getByText('Anthropic Claude')).toBeInTheDocument()
    expect(screen.getByText(/Sync & Telemetry Logs/i)).toBeInTheDocument()

    // Wait for data load
    await waitFor(() => {
      expect(screen.getByText(/Success/i)).toBeInTheDocument()
    })

    expect(screen.getByText(/142 ms/i)).toBeInTheDocument()

    // Record count pills
    expect(screen.getByText(/Agents \(3\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Models \(4\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Environments \(1\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Tools \(2\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Egress evaluated \(2\)/i)).toBeInTheDocument()
    expect(screen.getByText(/Violations \(0\)/i)).toBeInTheDocument()

    // Log messages
    expect(screen.getByText(/Initiating discovery sync with Anthropic Claude API/i)).toBeInTheDocument()
    expect(screen.getByText(/Discovered model catalog: claude-3-5-sonnet-20241022/i)).toBeInTheDocument()
    expect(screen.getByText(/nearing max allowed hosts/i)).toBeInTheDocument()
    expect(screen.getByText(/Failed to probe auxiliary telemetry gateway/i)).toBeInTheDocument()
  })

  it('filters logs by log level and text search', async () => {
    render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        isSuperadmin={true}
      />,
    )

    await waitFor(() => {
      expect(screen.getByText(/Discovered model catalog/i)).toBeInTheDocument()
    })

    // Filter by Level: WARN
    const levelSelect = screen.getByTestId('sync-log-level-filter')
    fireEvent.change(levelSelect, { target: { value: 'WARN' } })

    expect(screen.getByText(/nearing max allowed hosts/i)).toBeInTheDocument()
    expect(screen.queryByText(/Initiating discovery sync/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Discovered model catalog/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/Failed to probe auxiliary telemetry gateway/i)).not.toBeInTheDocument()

    // Filter by Level: ALL again
    fireEvent.change(levelSelect, { target: { value: 'ALL' } })
    expect(screen.getByText(/Initiating discovery sync/i)).toBeInTheDocument()

    // Filter by search text
    const searchInput = screen.getByTestId('sync-log-search')
    fireEvent.change(searchInput, { target: { value: 'auxiliary telemetry' } })

    expect(screen.getByText(/Failed to probe auxiliary telemetry gateway/i)).toBeInTheDocument()
    expect(screen.queryByText(/Initiating discovery sync/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/nearing max allowed hosts/i)).not.toBeInTheDocument()
  })

  it('reveals superadmin wire details when active, and displays advisory banner when not superadmin', async () => {
    const { rerender } = render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        isSuperadmin={false}
      />,
    )

    await waitFor(() => {
      expect(screen.getByTestId('superadmin-advisory-banner')).toBeInTheDocument()
    })

    expect(screen.getByText(/🔒 Verbose wire traces, raw API payloads, and header telemetry are available in Superadmin mode./i)).toBeInTheDocument()
    // Non-superadmin should not have wire payload toggle
    expect(screen.queryByTestId('wire-trace-payload-log-2')).not.toBeInTheDocument()

    // Rerender as Superadmin
    rerender(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        isSuperadmin={true}
      />,
    )

    // Advisory banner should disappear
    expect(screen.queryByTestId('superadmin-advisory-banner')).not.toBeInTheDocument()

    // Debug entry reveals endpoint, status code, latency
    expect(screen.getByText('GET /v1/models')).toBeInTheDocument()
    expect(screen.getByText('200')).toBeInTheDocument()
    expect(screen.getByText(/142ms/i)).toBeInTheDocument()

    // Wire payload inspector exists
    const wireDetails = screen.getByTestId('wire-trace-payload-log-2')
    expect(wireDetails).toBeInTheDocument()
    expect(wireDetails).toHaveTextContent('claude-3-5-sonnet-20241022')
  })

  it('copies logs to clipboard when copy button is clicked', async () => {
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, {
      clipboard: {
        writeText: writeTextMock,
      },
    })

    render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        isSuperadmin={true}
      />,
    )

    await waitFor(() => {
      expect(screen.getByTestId('btn-copy-sync-logs')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId('btn-copy-sync-logs'))

    expect(writeTextMock).toHaveBeenCalledTimes(1)
    const copiedContent = writeTextMock.mock.calls[0][0]
    expect(copiedContent).toContain('Anthropic Claude')
    expect(copiedContent).toContain('Initiating discovery sync')

    // Visual feedback
    await waitFor(() => {
      expect(screen.getByText(/Copied/i)).toBeInTheDocument()
    })
  })

  it('triggers rescan when Scan Now button in modal is clicked', async () => {
    render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        onRescan={onRescan}
        isSuperadmin={true}
      />,
    )

    await waitFor(() => {
      expect(screen.getByTestId('btn-modal-rescan')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId('btn-modal-rescan'))

    await waitFor(() => {
      expect(onRescan).toHaveBeenCalledTimes(1)
    })
  })

  it('closes on escape key or clicking close button', async () => {
    render(
      <SyncLogsModal
        isOpen={true}
        providerId="claude"
        providerName="Anthropic Claude"
        onClose={onClose}
        isSuperadmin={true}
      />,
    )

    await waitFor(() => {
      expect(screen.getByTestId('btn-close-sync-logs')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByTestId('btn-close-sync-logs'))
    expect(onClose).toHaveBeenCalledTimes(1)

    // Press escape
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(2)
  })
})
