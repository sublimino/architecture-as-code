import { useParams, Link } from 'react-router-dom'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeSanitize from 'rehype-sanitize'
import type { Components } from 'react-markdown'
import EmptyState from '../components/EmptyState'
import entraContent from '../help-content/connectors/entra.md?raw'
import oktaContent from '../help-content/connectors/okta.md?raw'
import openaiContent from '../help-content/connectors/openai.md?raw'

interface ProviderHelp {
  displayName: string
  content: string | null
}

// Route slugs are our own vocabulary (matching the ticket's /help/connectors/{provider}
// URLs), distinct from the connector framework's provider_id values (e.g. ad_entra) —
// this map is the single place that translates between the two.
const PROVIDERS: Record<string, ProviderHelp> = {
  entra: { displayName: 'Microsoft Entra ID', content: entraContent },
  okta: { displayName: 'Okta', content: oktaContent },
  openai: { displayName: 'OpenAI', content: openaiContent },
  google: { displayName: 'Google Workspace', content: null },
  aws: { displayName: 'AWS IAM', content: null },
  gcp: { displayName: 'GCP IAM', content: null },
}

const markdownComponents: Components = {
  h1: ({ children }) => <h1 className="display" style={{ fontSize: 26, fontWeight: 700, marginBottom: 16 }}>{children}</h1>,
  h2: ({ children }) => <h2 className="kicker" style={{ color: 'var(--cyan)', marginTop: 28, marginBottom: 10 }}>{children}</h2>,
  h3: ({ children }) => <h3 className="label" style={{ color: 'var(--text)', marginTop: 18, marginBottom: 8 }}>{children}</h3>,
  p: ({ children }) => <p style={{ fontSize: 13.5, lineHeight: 1.7, color: 'var(--text)', marginBottom: 12 }}>{children}</p>,
  ul: ({ children }) => <ul style={{ paddingLeft: 20, marginBottom: 12, fontSize: 13.5, lineHeight: 1.7 }}>{children}</ul>,
  ol: ({ children }) => <ol style={{ paddingLeft: 20, marginBottom: 12, fontSize: 13.5, lineHeight: 1.7 }}>{children}</ol>,
  table: ({ children }) => (
    <div style={{ overflowX: 'auto', marginBottom: 16 }}>
      <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 13 }}>{children}</table>
    </div>
  ),
  th: ({ children }) => (
    <th style={{ textAlign: 'left', padding: '8px 12px', borderBottom: '1px solid var(--border)', color: 'var(--muted)' }} className="label">
      {children}
    </th>
  ),
  td: ({ children }) => <td style={{ padding: '8px 12px', borderBottom: '1px solid var(--border)' }}>{children}</td>,
  code: ({ children }) => <code className="mono" style={{ background: 'var(--surface2)', padding: '1px 5px', borderRadius: 4, fontSize: 12.5 }}>{children}</code>,
  blockquote: ({ children }) => (
    <blockquote style={{ borderLeft: '2px solid var(--cyan)', paddingLeft: 14, margin: '12px 0', color: 'var(--muted)', fontSize: 13 }}>
      {children}
    </blockquote>
  ),
}

export default function ConnectorHelpPage() {
  const { provider } = useParams<{ provider: string }>()
  const help = (provider && PROVIDERS[provider]) || null

  return (
    <div className="fade-in" style={{ maxWidth: 760 }}>
      <p style={{ marginBottom: 16 }}>
        <Link to="/onboarding" className="label" style={{ color: 'var(--muted)' }}>← Back to connector setup</Link>
      </p>

      {help?.content ? (
        <div className="card" style={{ padding: '28px 32px' }}>
          <ReactMarkdown
            remarkPlugins={[remarkGfm]}
            rehypePlugins={[rehypeSanitize]}
            components={markdownComponents}
          >
            {help.content}
          </ReactMarkdown>
        </div>
      ) : (
        <EmptyState
          kicker="Coming soon"
          body={`Setup guide for ${help?.displayName ?? 'this provider'} is on the way.`}
          tone="cyan"
        />
      )}
    </div>
  )
}
