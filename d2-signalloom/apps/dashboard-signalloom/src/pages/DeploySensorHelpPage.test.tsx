import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import DeploySensorHelpPage from './DeploySensorHelpPage'

describe('DeploySensorHelpPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    Object.defineProperty(navigator, 'clipboard', {
      value: {
        writeText: vi.fn().mockResolvedValue(undefined),
      },
      configurable: true,
      writable: true,
    })
  })

  function renderPage() {
    return render(
      <MemoryRouter initialEntries={['/settings/help/deploy-sensor']}>
        <DeploySensorHelpPage />
      </MemoryRouter>
    )
  }

  it('renders heading, architecture summary, and main sections', () => {
    renderPage()

    expect(screen.getByRole('heading', { name: /Help to Deploy Sensor/i })).toBeInTheDocument()
    expect(screen.getByTestId('architecture-section')).toBeInTheDocument()
    expect(screen.getByText(/Architectural Overview: Telemetry Ingestion Pipeline/i)).toBeInTheDocument()
    expect(screen.getByTestId('kernel-sensor-section')).toBeInTheDocument()
    expect(screen.getByTestId('host-sensor-section')).toBeInTheDocument()
    expect(screen.getByTestId('troubleshooting-section')).toBeInTheDocument()
    expect(screen.getByTestId('doc-links-section')).toBeInTheDocument()
  })

  it('renders copyable snippets for Kernel and Host sensor installation', () => {
    renderPage()

    // Kernel sensor CLI & Helm snippets
    expect(screen.getByTestId('kernel-cli-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('kernel-helm-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('kernel-kustomize-snippet')).toBeInTheDocument()

    // Host sensor snippets
    expect(screen.getByTestId('host-systemd-unit-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('host-systemd-cmds-snippet')).toBeInTheDocument()
    expect(screen.getByTestId('host-docker-snippet')).toBeInTheDocument()
  })

  it('copies snippet to clipboard when clicking copy button', async () => {
    renderPage()

    const kernelSnippet = screen.getByTestId('kernel-cli-snippet')
    const copyBtn = kernelSnippet.querySelector('button')!
    expect(copyBtn).toHaveTextContent('Copy')

    fireEvent.click(copyBtn)

    await waitFor(() => {
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
        'kubectl apply -f https://deploy.signalloom.ai/kernel-sensor/daemonset.yaml'
      )
      expect(copyBtn).toHaveTextContent('✓ Copied')
    })
  })

  it('renders troubleshooting tips covering cgroups v2, BPF permissions, BTF and netlink', () => {
    renderPage()

    expect(screen.getByText(/Cgroups v2 Unified Hierarchy Missing or Hybrid Mode/i)).toBeInTheDocument()
    expect(screen.getByText(/BPF Permissions & Capability Dropping/i)).toBeInTheDocument()
    expect(screen.getByText(/Kernel Headers & BTF \(BPF Type Format\) Verification/i)).toBeInTheDocument()
    expect(screen.getByText(/Netlink Socket Diag Access/i)).toBeInTheDocument()
  })

  it('renders links to external documentation portal routes', () => {
    renderPage()

    const archLink = screen.getByTestId('doc-link-detective-telemetry')
    expect(archLink).toHaveAttribute('href', '/docs/security/detective-telemetry-architecture/')

    const covLink = screen.getByTestId('doc-link-detection-coverage')
    expect(covLink).toHaveAttribute('href', '/docs/operate/detection-coverage/')

    const runbookLink = screen.getByTestId('doc-link-containment-runbook')
    expect(runbookLink).toHaveAttribute('href', '/docs/operate/containment-runbook/')
  })

  it('provides navigation back to settings', () => {
    renderPage()

    const backLink = screen.getByTestId('back-to-settings-link')
    expect(backLink).toHaveAttribute('href', '/settings')
  })
})
