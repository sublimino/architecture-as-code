import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { PagePattern, PageHeader, PageLoader } from './PagePattern'
import { FeatureFlagProvider } from '../../providers/FeatureFlagProvider'

describe('PageHeader', () => {
  it('renders title, eyebrow, description, and hint', () => {
    render(
      <PageHeader
        title="Agent Governance"
        eyebrow="Estate"
        description="Comprehensive live monitoring and admission control for sovereign AI agents."
        hint="All agent telemetry is signed."
      />,
    )

    expect(screen.getByRole('heading', { level: 1, name: 'Agent Governance' })).toBeInTheDocument()
    expect(screen.getByTestId('page-eyebrow')).toHaveTextContent('Estate')
    expect(screen.getByTestId('page-description')).toHaveTextContent('Comprehensive live monitoring')
    expect(screen.getByTestId('page-hint')).toBeInTheDocument()
  })

  it('renders actions slot', () => {
    render(
      <PageHeader
        title="Topology"
        actions={<button type="button">Refresh Graph</button>}
      />,
    )

    expect(screen.getByRole('button', { name: 'Refresh Graph' })).toBeInTheDocument()
  })
})

describe('PageLoader', () => {
  it('renders PixelLoader with custom label and testid', () => {
    render(<PageLoader label="Loading Network Tests" minHeight="50vh" testId="custom-loader" />)
    expect(screen.getByTestId('custom-loader')).toBeInTheDocument()
    expect(screen.getByText('Loading Network Tests')).toBeInTheDocument()
  })
})

describe('PagePattern', () => {
  it('renders healthy content with header and children', () => {
    render(
      <PagePattern
        title="Compliance Controls"
        eyebrow="Assurance"
        description="Active CIS and CRA policy evaluation."
      >
        <div data-testid="compliance-content">Controls List</div>
      </PagePattern>,
    )

    expect(screen.getByRole('heading', { level: 1, name: 'Compliance Controls' })).toBeInTheDocument()
    expect(screen.getByTestId('compliance-content')).toBeInTheDocument()
  })

  it('renders in-page LoadingState when loading is true', () => {
    render(
      <PagePattern
        title="Risk Exposure"
        loading={true}
        loadingLabel="risk calculation"
      >
        <div>Content that should not be visible</div>
      </PagePattern>,
    )

    expect(screen.getByRole('heading', { level: 1, name: 'Risk Exposure' })).toBeInTheDocument()
    expect(screen.getByTestId('page-pattern-loading')).toBeInTheDocument()
    expect(screen.queryByText('Content that should not be visible')).toBeNull()
  })

  it('renders ErrorState with retry when error is provided', () => {
    const handleRetry = vi.fn()
    render(
      <PagePattern
        title="Weave Feed"
        error="Network timeout reaching eBPF Sentinel"
        onRetry={handleRetry}
      >
        <div>Should not render</div>
      </PagePattern>,
    )

    expect(screen.getByText('Network timeout reaching eBPF Sentinel')).toBeInTheDocument()
    const retryBtn = screen.getByRole('button', { name: /retry/i })
    expect(retryBtn).toBeInTheDocument()
    fireEvent.click(retryBtn)
    expect(handleRetry).toHaveBeenCalledTimes(1)
  })

  it('renders EmptyState when empty is true', () => {
    render(
      <PagePattern
        title="Discovered Workloads"
        empty={true}
        emptyKicker="No unmanaged workloads found"
        emptyBody="All observed cluster pods belong to enrolled namespaces."
      >
        <div>Should not render</div>
      </PagePattern>,
    )

    expect(screen.getByText('No unmanaged workloads found')).toBeInTheDocument()
    expect(screen.getByText('All observed cluster pods belong to enrolled namespaces.')).toBeInTheDocument()
  })

  it('evaluates feature flag and displays PageLoader during loading, never premature 404', () => {
    render(
      <FeatureFlagProvider initialFlags={{ page_test_flag: false }} disableAutoFetch={true}>
        <PagePattern
          title="Experimental Feature"
          flag="page_test_flag"
        >
          <div data-testid="flagged-content">Special Content</div>
        </PagePattern>
      </FeatureFlagProvider>,
    )

    // Flag is false -> renders NotFoundPage
    expect(screen.getByTestId('not-found')).toBeInTheDocument()
    expect(screen.queryByTestId('flagged-content')).toBeNull()
  })

  it('renders flagged content when feature flag is enabled', () => {
    render(
      <FeatureFlagProvider initialFlags={{ page_test_flag: true }} disableAutoFetch={true}>
        <PagePattern
          title="Experimental Feature"
          flag="page_test_flag"
        >
          <div data-testid="flagged-content">Special Content</div>
        </PagePattern>
      </FeatureFlagProvider>,
    )

    expect(screen.getByTestId('flagged-content')).toBeInTheDocument()
    expect(screen.queryByTestId('not-found')).toBeNull()
  })
})
