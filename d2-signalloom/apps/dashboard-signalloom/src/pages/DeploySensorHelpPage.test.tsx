import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { existsSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
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

    // Kernel sensor: kubectl apply -k and Flux snippets. There is no Helm chart.
    expect(screen.getByTestId('kernel-cli-snippet')).toBeInTheDocument()
    expect(screen.queryByTestId('kernel-helm-snippet')).not.toBeInTheDocument()
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
        expect.stringContaining(
          'kubectl apply -k d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant\n'
        )
      )
      expect(copyBtn).toHaveTextContent('✓ Copied')
    })
  })

  // The page must describe the warden the repository actually deploys. Every
  // expected value below is read from the manifests on disk, so a rename, a
  // namespace move or a new capability fails here instead of leaving the page
  // telling users to deploy something that does not exist.
  describe('matches the signalloom-warden manifests', () => {
    const repo = resolve(__dirname, '../../../../..')
    const read = (p: string) => readFileSync(join(repo, p), 'utf8')
    const ds = read('d2-signalloom/infra/agent-swarm/signalloom-warden/daemonset.yaml')
    const dsDoc = ds.slice(ds.indexOf('kind: DaemonSet'))
    const meta = dsDoc.slice(dsDoc.indexOf('metadata:'), dsDoc.indexOf('\nspec:'))
    const one = (src: string, re: RegExp) => {
      const m = src.match(re)
      if (!m) throw new Error(`manifest has no match for ${re}`)
      return m[1]
    }
    const name = one(meta, /^ {2}name: (\S+)$/m)
    const namespace = one(meta, /^ {2}namespace: (\S+)$/m)
    const container = one(dsDoc, /^ {6}containers:\n {8}- name: (\S+)$/m)
    const image = one(dsDoc, /^ {10}image: (\S+)$/m).replace(/:[^:/]+$/, '')
    const roleLabel = one(meta, /^ {4}signalloom\.ai\/role: "?([^"\n]+)"?$/m)
    const selector = one(dsDoc, /matchLabels:\n {6}app\.kubernetes\.io\/name: (\S+)/)
    const caps = one(dsDoc, /add:\n((?: {16}- \S+\n)+)/).trim().split('\n').map((l) => l.replace(/^\s*-\s*/, ''))

    it('shows the DaemonSet name, namespace, container, image and labels from daemonset.yaml', () => {
      renderPage()
      expect(screen.getByTestId('warden-daemonset')).toHaveTextContent(new RegExp(`^${name}$`))
      expect(screen.getByTestId('warden-namespace')).toHaveTextContent(new RegExp(`^${namespace}$`))
      expect(screen.getByTestId('warden-container')).toHaveTextContent(new RegExp(`^${container}$`))
      expect(screen.getByTestId('warden-image')).toHaveTextContent(new RegExp(`^${image}$`))
      expect(screen.getByTestId('warden-labels')).toHaveTextContent(
        `app.kubernetes.io/name=${selector}, signalloom.ai/role=${roleLabel}`
      )
      expect(screen.getByTestId('warden-capabilities')).toHaveTextContent(caps.join(', '))
      expect(screen.getByTestId('warden-logs-cmd')).toHaveTextContent(
        `kubectl logs -n ${namespace} daemonset/${name} -c ${container}`
      )
    })

    it('points at overlays that exist and a namespace kustomization that creates that namespace', () => {
      renderPage()
      const cli = screen.getByTestId('kernel-cli-snippet').textContent ?? ''
      const paths = [...cli.matchAll(/kubectl apply -k (\S+)/g)].map((m) => m[1])
      expect(paths).toEqual([
        'd2-signalloom/infra/agent-swarm/signalloom-warden-namespace',
        'd2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant',
      ])
      for (const p of paths) expect(existsSync(join(repo, p, 'kustomization.yaml'))).toBe(true)
      expect(read(`${paths[0]}/namespace.yaml`)).toMatch(new RegExp(`^ {2}name: ${namespace}$`, 'm'))
      expect(cli).toContain(`rollout status ds/${name}`)
      expect(cli).toContain(`-n ${namespace} apply -f signalloom-warden-ingest-token.yaml`)
    })

    it('shows the Flux path the fleet ResourceSet actually reconciles', () => {
      renderPage()
      const rs = read('d2-osramp-fleet/tenants/base/agent-swarm.yaml')
      const entry = rs.slice(rs.indexOf('name: agent-signalloom-warden'))
      const rsPath = one(entry, /^ +path: (\S+)$/m)
      expect(screen.getByTestId('kernel-kustomize-snippet').textContent).toContain(`path: ${rsPath}`)
    })

    it('names nothing the repository no longer ships', () => {
      renderPage()
      const kernel = screen.getByTestId('kernel-sensor-section').textContent ?? ''
      const trouble = screen.getByTestId('troubleshooting-section').textContent ?? ''
      for (const text of [kernel, trouble]) {
        expect(text).not.toMatch(/stun-sentinel|signalloom-system|:latest|Tetragon|helm /i)
      }
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
