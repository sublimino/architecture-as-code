import signalLoomLogo from '../../assets/signal-loom-logo.png'
import {
  DiscoveryPreview,
  AgentsPreview,
  CompliancePreview,
  AuditTrailPreview,
  SettingsPreview,
} from './TourPreviews'

// Screen 1 of the wizard per the original US-ENHC-011 design ("Welcome +
// framing"), never actually built when the wizard shipped — added here per
// Wendy's review along with a platform tour and a Help & FAQ link, so a
// first-time user knows where things are before diving into setup.
const TOUR_ITEMS = [
  { label: 'Discovery', blurb: 'Where the non-human identities we find for you show up, with risk findings and triage actions.', Preview: DiscoveryPreview },
  { label: 'Agents', blurb: 'Your governed AI agents — lifecycle state, compliance posture, and enrollment.', Preview: AgentsPreview },
  { label: 'Compliance', blurb: 'Framework-by-framework posture (SOC 2, EU AI Act, and others you select).', Preview: CompliancePreview },
  { label: 'Audit Trail', blurb: 'A full history of governance actions, exportable for evidence.', Preview: AuditTrailPreview },
  { label: 'Settings', blurb: 'Connected providers, scan preferences, API access, and account details.', Preview: SettingsPreview },
]

interface Props {
  onContinue: () => void
  onOpenHelp: () => void
}

export default function WelcomeStep({ onContinue, onOpenHelp }: Props) {
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 10 }}>
        <img src={signalLoomLogo} alt="Signal Loom" width={48} height={48} style={{ borderRadius: 12, objectFit: 'cover', flexShrink: 0 }} />
        <h1 style={{ fontSize: 28, fontWeight: 700, color: 'var(--text)', letterSpacing: '-0.02em' }}>
          Welcome to <span style={{ background: 'linear-gradient(90deg, var(--cyan), var(--violet, #8B5CF6))', WebkitBackgroundClip: 'text', backgroundClip: 'text', color: 'transparent' }}>Signal Loom</span>
        </h1>
      </div>
      <p style={{ color: 'var(--muted)', fontSize: 16, marginBottom: 28, lineHeight: 1.7, maxWidth: 640 }}>
        Let's find your non-human identities. This short setup connects your identity providers
        so Signal Loom can start discovering service accounts, API keys, and bots — and get you
        governing them.
      </p>

      <div className="card" style={{ padding: '20px 24px', marginBottom: 24 }}>
        <p style={{ fontSize: 12, fontWeight: 700, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 18 }}>
          A tour of the platform
        </p>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 20 }}>
          {TOUR_ITEMS.map(({ label, blurb, Preview }) => (
            <div key={label} style={{ display: 'flex', gap: 16, alignItems: 'center' }}>
              <Preview />
              <div>
                <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>{label}</div>
                <div style={{ fontSize: 13, color: 'var(--muted)', marginTop: 3, lineHeight: 1.5 }}>{blurb}</div>
              </div>
            </div>
          ))}
        </div>
      </div>

      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 24 }}>
        Have questions along the way?{' '}
        <button
          onClick={onOpenHelp}
          style={{ background: 'none', border: 'none', padding: 0, color: 'var(--cyan)', cursor: 'pointer', fontSize: 13, textDecoration: 'underline', fontFamily: 'inherit' }}
        >
          Open Help &amp; FAQ
        </button>
        {' '}anytime from the sidebar too.
      </p>

      <button className="btn btn-primary" onClick={onContinue}>
        Get started
      </button>
    </div>
  )
}
