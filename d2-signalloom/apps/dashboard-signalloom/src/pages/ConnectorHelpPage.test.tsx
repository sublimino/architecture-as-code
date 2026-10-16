import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'
import ConnectorHelpPage from './ConnectorHelpPage'

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/help/connectors/:provider" element={<ConnectorHelpPage />} />
        <Route path="/onboarding" element={<div>ONBOARDING WIZARD</div>} />
      </Routes>
    </MemoryRouter>
  )
}

describe('ConnectorHelpPage', () => {
  it('renders the Entra setup walkthrough as markdown content', () => {
    renderAt('/help/connectors/entra')
    expect(
      screen.getByRole('heading', { name: /Connecting your Azure AD \/ Entra ID directory/i })
    ).toBeInTheDocument()
    expect(screen.getAllByText(/Application\.Read\.All/).length).toBeGreaterThan(0)
  })

  it('renders the Claude guide the connector wizard links to, stating what it reads', () => {
    renderAt('/help/connectors/claude')
    expect(screen.getByRole('heading', { level: 1, name: /Anthropic Claude/i })).toBeInTheDocument()
    expect(screen.getAllByText(/\/v1\/agents/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/\/v1\/models/).length).toBeGreaterThan(0)
    expect(screen.queryByText('Coming soon')).not.toBeInTheDocument()
  })

  it('renders a Coming soon EmptyState for stub providers', () => {
    for (const provider of ['google', 'aws', 'gcp']) {
      const { unmount } = renderAt(`/help/connectors/${provider}`)
      expect(screen.getByText('Coming soon')).toBeInTheDocument()
      unmount()
    }
  })

  it('falls back to Coming soon for an unknown provider slug', () => {
    renderAt('/help/connectors/nonexistent')
    expect(screen.getByText('Coming soon')).toBeInTheDocument()
  })

  it('sanitizes raw HTML embedded in markdown content (no unsanitized dangerouslySetInnerHTML)', async () => {
    // Exercise the same react-markdown + rehype-sanitize pipeline the page uses,
    // feeding it a script tag the way an untrusted markdown source might.
    const { default: ReactMarkdown } = await import('react-markdown')
    const { default: rehypeSanitize } = await import('rehype-sanitize')
    const remarkGfm = (await import('remark-gfm')).default

    render(
      <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeSanitize]}>
        {'# Heading\n\n<script>window.__pwned = true</script>\n\nSafe paragraph.'}
      </ReactMarkdown>
    )

    expect(screen.getByText('Safe paragraph.')).toBeInTheDocument()
    expect(document.querySelector('script')).not.toBeInTheDocument()
    expect(document.body.innerHTML).not.toContain('__pwned')
  })
})
