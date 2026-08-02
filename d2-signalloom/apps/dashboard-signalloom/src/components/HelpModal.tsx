import { useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { useAppContext } from '../App'

type Tab = 'faq' | 'support'

interface FaqItem {
  q: string
  a: ReactNode
}

interface FaqSection {
  title: string
  items: FaqItem[]
}

const FAQ_SECTIONS: FaqSection[] = [
  {
    title: 'Getting started',
    items: [
      {
        q: 'What is Signal Loom?',
        a: 'Signal Loom is an AI agent governance platform. It lets you enroll AI agents, manage their lifecycle, track compliance against frameworks like SOC 2 and EU AI Act, and audit every governance action.',
      },
      {
        q: 'How do I register a new agent?',
        a: 'Open the Agents page (Governed tab) and click Register Agent. Enter the agent\'s name and type — and optionally a description and owner. The agent is created in the enrolled state and appears in the Governed tab; your operator then activates it. Agents can also be enrolled programmatically via the registry API.',
      },
      {
        q: 'What do the lifecycle states mean?',
        a: 'Enrolled — registered but not yet active. Active — running in production and fully governed. Suspended — temporarily halted (e.g. for investigation). Revoked — permanently decommissioned.',
      },
    ],
  },
  {
    title: 'Managing agents',
    items: [
      {
        q: 'How do I change an agent\'s lifecycle state?',
        a: 'Lifecycle changes (for example enrolled → active, or active → suspended) are applied by your Signal Loom operator — they are not made directly from the dashboard. To request one, open the agent\'s detail page and click Request Transition, then choose the target state and give a reason. This sends the request to your operator, who applies the change; it is then recorded in the agent\'s activity timeline and the audit log. (You can also raise the request via Help → Contact Support.) Valid transitions are: enrolled → active; active → suspended or revoked; suspended → active or revoked. Revoked is permanent.',
      },
      {
        q: 'What is a violation?',
        a: 'A violation is a policy infraction detected by the OPA compliance engine — for example, an agent without an assigned owner or an expired credential. Violations appear on the Agent Detail page and in the Attention panel.',
      },
      {
        q: 'How do I acknowledge a violation?',
        a: 'On the Agent Detail page, find the violation in the timeline or violations list and click Acknowledge. This marks it as reviewed and removes it from the Attention Required panel.',
      },
    ],
  },
  {
    title: 'Compliance & frameworks',
    items: [
      {
        q: 'Which compliance frameworks are supported?',
        a: 'Stage 1 supports SOC 2 (CC6.1, CC6.2, CC7.2) and EU AI Act (Traceability, Human Oversight, Incident Attribution). Additional frameworks can be enabled — contact support.',
      },
      {
        q: 'What is a posture score?',
        a: 'A posture score is the percentage of compliance controls an agent is passing (0–100). Good = 80 or above, Warning = 50–79, Critical = below 50. Agents with no assessment data show as Pending.',
      },
      {
        q: 'How does reassessment work?',
        a: 'Click a failed cell in the Framework Detail matrix to request a reassessment. The OPA engine re-evaluates the agent against that control. Results update within 24 hours and the cell changes to ↻ until completed.',
      },
    ],
  },
  {
    title: 'NHI Discovery',
    items: [
      {
        q: 'What is an NHI account?',
        a: 'A Non-Human Identity (NHI) account is a service account or managed identity found during a directory scan (e.g. from Entra ID). These represent AI agents or automation accounts that may need governance.',
      },
      {
        q: 'What does "Enroll" do?',
        a: 'Enrolling an NHI account registers it into the Signal Loom agent registry and begins governance tracking — lifecycle management, compliance assessment, and audit logging.',
      },
      {
        q: 'What does "Dismiss" do?',
        a: 'Dismissing marks the account as reviewed and not requiring enrollment — for example, a known system account. If the account changes after dismissal, it reappears for triage.',
      },
      {
        q: 'How do I connect my Entra directory?',
        a: (
          <ConnectorHelpLink to="/help/connectors/entra">
            Follow the Entra/Azure AD connector setup guide
          </ConnectorHelpLink>
        ),
      },
    ],
  },
  {
    title: 'Billing & plans',
    items: [
      {
        q: 'What plans are available?',
        a: 'Signal Loom offers Starter, Professional, and Enterprise tiers. Starter includes up to 10 agents and SOC 2 controls. Professional adds EU AI Act, NHI discovery, and up to 50 agents. Enterprise is unlimited.',
      },
      {
        q: 'How is billing calculated?',
        a: 'Billing is per enrolled agent per month, pro-rated for partial months. Agent count is based on the max enrolled at any point in the billing period.',
      },
      {
        q: 'How do I upgrade my plan?',
        a: 'Contact support@signal-loom.ai or use the Contact Support tab to submit an upgrade request. Our team will respond within one business day.',
      },
    ],
  },
  {
    title: 'Security & access',
    items: [
      {
        q: 'How is my data isolated from other tenants?',
        a: 'Signal Loom uses PostgreSQL Row Level Security (RLS). Every database query is scoped to your tenant_id — it is impossible for one tenant to read another tenant\'s data.',
      },
      {
        q: 'Where are my auth tokens stored?',
        a: 'Access tokens are stored in memory only (never in localStorage or sessionStorage). This prevents token theft via XSS. Tokens are refreshed automatically via PKCE on page load.',
      },
      {
        q: 'How do I rotate my API key?',
        a: 'Contact support@signal-loom.ai with the subject "API Key Rotation Request". Key rotations are logged in the audit trail. We respond within one business day.',
      },
    ],
  },
]

// The modal is a fixed-position overlay — closing it on navigate keeps it
// from sitting on top of the help page it just linked to.
function ConnectorHelpLink({ to, children }: { to: string; children: ReactNode }) {
  const { setHelpOpen } = useAppContext()
  return (
    <Link to={to} onClick={() => setHelpOpen(false)}>
      {children}
    </Link>
  )
}

function FAQSection({ section }: { section: FaqSection }) {
  const [openIdx, setOpenIdx] = useState<number | null>(null)
  return (
    <div style={{ marginBottom: 20 }}>
      <h3 style={{ fontSize: 13, fontWeight: 700, color: 'var(--cyan)', marginBottom: 8, textTransform: 'uppercase', letterSpacing: '0.06em' }}>
        {section.title}
      </h3>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {section.items.map((item, i) => (
          <div key={i} style={{ border: '1px solid var(--border)', borderRadius: 6, overflow: 'hidden' }}>
            <button
              onClick={() => setOpenIdx(openIdx === i ? null : i)}
              style={{
                width: '100%', display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 14px', background: openIdx === i ? 'var(--surface2)' : 'transparent',
                border: 'none', color: 'var(--text)', cursor: 'pointer', textAlign: 'left', gap: 10,
              }}
            >
              <span style={{ fontSize: 13, fontWeight: 500, flex: 1 }}>{item.q}</span>
              <span style={{ color: 'var(--muted)', fontSize: 14, flexShrink: 0 }}>{openIdx === i ? '▲' : '▼'}</span>
            </button>
            {openIdx === i && (
              <div style={{ padding: '0 14px 12px', fontSize: 13, color: 'var(--muted)', lineHeight: 1.6, borderTop: '1px solid var(--border)' }}>
                <div style={{ paddingTop: 10 }}>{item.a}</div>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

export default function HelpModal() {
  const { helpOpen, setHelpOpen } = useAppContext()
  const { getAccessTokenSilently } = useAuth0()

  const [activeTab, setActiveTab] = useState<Tab>('faq')
  const [subject, setSubject] = useState('')
  const [urgency, setUrgency] = useState<'low' | 'normal' | 'high' | 'critical'>('normal')
  const [message, setMessage] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [success, setSuccess] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  if (!helpOpen) return null

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    setFormError(null)
    try {
      const token = await getAccessTokenSilently()
      await api.support(token, { subject, urgency, message })
      setSuccess(true)
      setSubject('')
      setUrgency('normal')
      setMessage('')
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Submission failed. Please try again.')
    } finally {
      setSubmitting(false)
    }
  }

  function close() {
    setHelpOpen(false)
    setSuccess(false)
    setFormError(null)
    setActiveTab('faq')
  }

  return (
    <div
      style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000 }}
      onClick={e => { if (e.target === e.currentTarget) close() }}
    >
      <div
        className="card slide-up"
        style={{ width: 560, maxWidth: '95vw', maxHeight: '85vh', display: 'flex', flexDirection: 'column', position: 'relative', padding: 0, overflow: 'hidden' }}
      >
        {/* Modal header */}
        <div style={{ padding: '20px 24px 0', flexShrink: 0 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <h2 style={{ fontSize: 17, fontWeight: 700 }}>Help & Support</h2>
            <button
              onClick={close}
              style={{ background: 'none', border: 'none', color: 'var(--muted)', fontSize: 22, lineHeight: 1, cursor: 'pointer', padding: '0 4px' }}
            >
              ×
            </button>
          </div>

          {/* Tabs */}
          <div style={{ display: 'flex', gap: 0, borderBottom: '1px solid var(--border)' }}>
            {(['faq', 'support'] as Tab[]).map(tab => (
              <button
                key={tab}
                onClick={() => setActiveTab(tab)}
                style={{
                  padding: '8px 18px', background: 'none', border: 'none',
                  borderBottom: activeTab === tab ? '2px solid var(--cyan)' : '2px solid transparent',
                  color: activeTab === tab ? 'var(--cyan)' : 'var(--muted)',
                  fontWeight: activeTab === tab ? 600 : 400,
                  fontSize: 13, cursor: 'pointer', marginBottom: -1,
                  transition: 'color 0.15s',
                }}
              >
                {tab === 'faq' ? 'FAQ' : 'Contact Support'}
              </button>
            ))}
          </div>
        </div>

        {/* Tab content */}
        <div style={{ flex: 1, overflow: 'auto', padding: '20px 24px 24px' }}>
          {activeTab === 'faq' && (
            <div>
              {FAQ_SECTIONS.map(section => (
                <FAQSection key={section.title} section={section} />
              ))}
              <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 8, textAlign: 'center' }}>
                Can't find your answer?{' '}
                <button
                  onClick={() => setActiveTab('support')}
                  style={{ background: 'none', border: 'none', color: 'var(--cyan)', cursor: 'pointer', fontSize: 12, padding: 0 }}
                >
                  Contact support →
                </button>
              </p>
            </div>
          )}

          {activeTab === 'support' && (
            success ? (
              <div style={{ textAlign: 'center', padding: '32px 0' }}>
                <div style={{ fontSize: 44, marginBottom: 14 }}>✅</div>
                <p style={{ fontWeight: 600, fontSize: 15, marginBottom: 6 }}>Request submitted</p>
                <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 24 }}>We'll be in touch within one business day.</p>
                <button className="btn btn-secondary" onClick={close}>Close</button>
              </div>
            ) : (
              <div>
                <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 20 }}>We'll respond within one business day.</p>
                <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div>
                    <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 5 }}>Subject</label>
                    <input
                      value={subject}
                      onChange={e => setSubject(e.target.value)}
                      required
                      maxLength={255}
                      placeholder="Brief description of your issue"
                      style={{ width: '100%' }}
                    />
                  </div>
                  <div>
                    <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 5 }}>Urgency</label>
                    <select value={urgency} onChange={e => setUrgency(e.target.value as typeof urgency)} style={{ width: '100%' }}>
                      <option value="low">Low — general question</option>
                      <option value="normal">Normal — needs attention soon</option>
                      <option value="high">High — impacting operations</option>
                      <option value="critical">Critical — system down or data risk</option>
                    </select>
                  </div>
                  <div>
                    <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 5 }}>Message</label>
                    <textarea
                      value={message}
                      onChange={e => setMessage(e.target.value)}
                      required
                      maxLength={5000}
                      rows={5}
                      placeholder="Describe your issue in detail…"
                      style={{ width: '100%', resize: 'vertical' }}
                    />
                  </div>
                  {formError && <p style={{ color: 'var(--error)', fontSize: 13 }}>{formError}</p>}
                  <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
                    <button type="button" className="btn btn-secondary" onClick={close}>Cancel</button>
                    <button type="submit" className="btn btn-primary" disabled={submitting}>
                      {submitting ? 'Sending…' : 'Submit Request'}
                    </button>
                  </div>
                </form>
              </div>
            )
          )}
        </div>
      </div>
    </div>
  )
}
