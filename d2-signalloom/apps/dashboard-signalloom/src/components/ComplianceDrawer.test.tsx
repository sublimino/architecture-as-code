import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ComplianceDrawer, { type ComplianceDrawerItem } from './ComplianceDrawer'

describe('ComplianceDrawer', () => {
  const mockOnClose = vi.fn()

  const sampleItem: ComplianceDrawerItem = {
    frameworkId: 'fw-eu-ai',
    frameworkName: 'EU AI Act',
    frameworkVersion: 'v2.1',
    regulatoryBody: 'European Commission',
    controlId: 'AIT-3',
    controlName: 'Data Provenance',
    description: 'Verify training and validation data provenance is recorded with tamper-evident logs.',
    agentId: 'agent-sentinel-1',
    agentName: 'Sentinel Agent',
    status: 'fail',
    policyVersion: 'v2.1.0',
    totalChecks: 10,
    passedChecks: 7,
    failedChecks: 3,
    postureScore: 0.7,
    evidenceHashes: [
      'sha256:4f8a12bc9034ef5678901234567890abcdef1234567890abcdef1234567890ab',
      'sha256:7b9c34de1256fa7890123456789012abcdef1234567890abcdef1234567890cd',
    ],
    remediation: 'Attach cryptographic provenance bundles to all dataset ingestion pipelines.',
    checks: [
      { check: 'Model card published', passed: true, policyVersion: 'v2.1.0' },
      { check: 'Data provenance recorded', passed: false, policyVersion: 'v2.1.0', remediation: 'Enable data lineage collector on pod.' },
      { check: 'Human oversight override trail', passed: false, policyVersion: 'v2.1.0', remediation: 'Configure approval webhook.' },
    ],
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('renders nothing when open is false', () => {
    render(<ComplianceDrawer open={false} item={sampleItem} onClose={mockOnClose} />)
    expect(screen.queryByTestId('compliance-drawer')).not.toBeInTheDocument()
  })

  it('renders nothing when item is null', () => {
    render(<ComplianceDrawer open={true} item={null} onClose={mockOnClose} />)
    expect(screen.queryByTestId('compliance-drawer')).not.toBeInTheDocument()
  })

  it('renders header with framework title, control ID, and compliance status badge', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    expect(screen.getByTestId('compliance-drawer')).toBeInTheDocument()
    expect(screen.getByTestId('compliance-drawer-title')).toHaveTextContent('EU AI Act')
    expect(screen.getByText(/Control AIT-3: Data Provenance/i)).toBeInTheDocument()
    expect(screen.getByTestId('compliance-drawer-status-badge')).toBeInTheDocument()
    expect(screen.getByText(sampleItem.description!)).toBeInTheDocument()
  })

  it('renders summary metrics: total, passed, failed, and percentage score from float ratio', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    expect(screen.getByTestId('metric-total-checks')).toHaveTextContent('10')
    expect(screen.getByTestId('metric-passed-checks')).toHaveTextContent('7')
    expect(screen.getByTestId('metric-failed-checks')).toHaveTextContent('3')
    expect(screen.getByTestId('metric-posture-score')).toHaveTextContent('70%')
  })

  it('formats posture score from integer or fallback check ratio', () => {
    const intItem: ComplianceDrawerItem = {
      ...sampleItem,
      postureScore: 85,
    }
    const { rerender } = render(<ComplianceDrawer open={true} item={intItem} onClose={mockOnClose} />)
    expect(screen.getByTestId('metric-posture-score')).toHaveTextContent('85%')

    const fallbackItem: ComplianceDrawerItem = {
      ...sampleItem,
      postureScore: null,
      totalChecks: 4,
      passedChecks: 3,
      failedChecks: 1,
    }
    rerender(<ComplianceDrawer open={true} item={fallbackItem} onClose={mockOnClose} />)
    expect(screen.getByTestId('metric-posture-score')).toHaveTextContent('75%')
  })

  it('renders evaluated policy version and cryptographic evidence hashes', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    expect(screen.getByTestId('compliance-policy-version')).toHaveTextContent('v2.1.0')
    const hashes = screen.getAllByTestId('compliance-evidence-hash')
    expect(hashes.length).toBe(2)
    expect(hashes[0]).toHaveTextContent(sampleItem.evidenceHashes![0])
  })

  it('renders actionable remediation guidance for failing checks', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    const remSection = screen.getByTestId('compliance-remediation-section')
    expect(remSection).toBeInTheDocument()
    expect(remSection).toHaveTextContent(sampleItem.remediation!)
    expect(within(remSection).getByText(/Enable data lineage collector on pod/i)).toBeInTheDocument()
  })

  it('renders expandable raw evidence JSON viewer and handles copy-to-clipboard', async () => {
    const user = userEvent.setup()
    const writeTextMock = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: writeTextMock },
      configurable: true,
      writable: true,
    })

    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    const jsonViewer = screen.getByTestId('compliance-evidence-json')
    expect(jsonViewer).toBeInTheDocument()
    expect(jsonViewer.textContent).toContain('EU AI Act')

    const copyBtn = screen.getByTestId('compliance-copy-json')
    await user.click(copyBtn)
    expect(writeTextMock).toHaveBeenCalled()
    expect(copyBtn).toHaveTextContent('Copied!')

    const toggleBtn = screen.getByTestId('compliance-toggle-json')
    await user.click(toggleBtn)
    expect(screen.queryByTestId('compliance-evidence-json')).not.toBeInTheDocument()
    await user.click(toggleBtn)
    expect(screen.getByTestId('compliance-evidence-json')).toBeInTheDocument()
  })

  it('meets WAI-ARIA modal standards with role="dialog", aria-modal="true", and aria-labelledby', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    const dialog = screen.getByRole('dialog')
    expect(dialog).toHaveAttribute('aria-modal', 'true')
    expect(dialog).toHaveAttribute('aria-labelledby', 'compliance-drawer-title')
  })

  it('closes on close button click and backdrop click', async () => {
    const user = userEvent.setup()
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    const closeBtn = screen.getByTestId('compliance-drawer-close')
    await user.click(closeBtn)
    expect(mockOnClose).toHaveBeenCalledTimes(1)

    const backdrop = screen.getByTestId('compliance-drawer-backdrop')
    await user.click(backdrop)
    expect(mockOnClose).toHaveBeenCalledTimes(2)

    const footerClose = screen.getByTestId('compliance-drawer-footer-close')
    await user.click(footerClose)
    expect(mockOnClose).toHaveBeenCalledTimes(3)
  })

  it('closes on Escape key dismiss', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(mockOnClose).toHaveBeenCalledTimes(1)
  })

  it('traps focus within the drawer when Tab or Shift+Tab is pressed', () => {
    render(<ComplianceDrawer open={true} item={sampleItem} onClose={mockOnClose} />)

    const closeBtn = screen.getByTestId('compliance-drawer-close')
    const footerClose = screen.getByTestId('compliance-drawer-footer-close')

    footerClose.focus()
    expect(document.activeElement).toBe(footerClose)

    // Tabbing from last element wraps to first
    fireEvent.keyDown(window, { key: 'Tab', shiftKey: false })
    expect(document.activeElement).toBe(closeBtn)

    // Shift-Tabbing from first element wraps to last
    fireEvent.keyDown(window, { key: 'Tab', shiftKey: true })
    expect(document.activeElement).toBe(footerClose)
  })
})
