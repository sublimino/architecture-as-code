/**
 * ConsentModal — first-use legal + cookie consent gate (ClickUp 86cabhuub Phase 2).
 *
 * Cannot be dismissed: no X button, no Escape key, no click-outside.
 * Accept button is enabled only when:
 *   1. All three legal docs scrolled to ≥95% of their content
 *   2. The acceptance + authority-warranty checkbox is checked
 *   (Analytics cookie opt-in is free — both yes and no are valid)
 *
 * Feature flag: if VITE_CONSENT_MODAL_ENABLED is "false" (or absent),
 * this component will not be rendered at all — gated in App.tsx.
 *
 * Scroll tracking: each legal doc iframe fires
 *   postMessage({ type: 'sl-legal-scrolled', doc: 'terms' | 'privacy' | 'eula' })
 * when the user scrolls to ≥95% of the document height.
 */
import { useEffect, useState } from 'react'
import type { CookiePreferences } from '../types/api'

const LEGAL_BASE =
  (import.meta.env.VITE_LEGAL_BASE_URL as string | undefined) ??
  'https://discovery.signal-loom.ai'

type DocKey = 'terms' | 'privacy' | 'eula'

const DOCS: { key: DocKey; label: string; src: string }[] = [
  { key: 'terms',   label: 'Terms of Service', src: `${LEGAL_BASE}/legal/terms?embed=1`   },
  { key: 'privacy', label: 'Privacy Policy',   src: `${LEGAL_BASE}/legal/privacy?embed=1` },
  { key: 'eula',    label: 'EULA',             src: `${LEGAL_BASE}/legal/eula?embed=1`    },
]

const DOC_VERSIONS: Record<DocKey, string> = { terms: '1.2', privacy: '1.2', eula: '1.2' }

interface Props {
  onAccept: (prefs: CookiePreferences) => Promise<void>
}

export default function ConsentModal({ onAccept }: Props) {
  const [activeTab, setActiveTab]   = useState<DocKey>('terms')
  const [scrolledDocs, setScrolledDocs] = useState<Record<DocKey, boolean>>({
    terms: false, privacy: false, eula: false,
  })
  const [analyticsConsent, setAnalyticsConsent] = useState(false)
  const [warrantyChecked, setWarrantyChecked]     = useState(false)
  const [accepting, setAccepting]   = useState(false)
  const [error, setError]           = useState<string | null>(null)

  // Lazy-load iframe srcs — only load a tab's iframe when first visited
  const [loadedSrcs, setLoadedSrcs] = useState<Record<DocKey, string>>({
    terms: DOCS[0].src, privacy: '', eula: '',
  })

  const allScrolled = scrolledDocs.terms && scrolledDocs.privacy && scrolledDocs.eula
  const canAccept   = allScrolled && warrantyChecked && !accepting

  // Listen for scroll-to-≥95% postMessages from legal doc iframes
  useEffect(() => {
    function onMessage(evt: MessageEvent) {
      if (!evt.data || evt.data.type !== 'sl-legal-scrolled') return
      const doc = evt.data.doc as DocKey
      if (doc === 'terms' || doc === 'privacy' || doc === 'eula') {
        setScrolledDocs(prev => prev[doc] ? prev : { ...prev, [doc]: true })
      }
    }
    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [])

  // Block Escape key while modal is visible
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation() }
    }
    window.addEventListener('keydown', onKeyDown, { capture: true })
    return () => window.removeEventListener('keydown', onKeyDown, { capture: true })
  }, [])

  function switchTab(key: DocKey) {
    setActiveTab(key)
    setLoadedSrcs(prev => {
      if (prev[key]) return prev
      return { ...prev, [key]: DOCS.find(d => d.key === key)!.src }
    })
  }

  async function handleAccept() {
    setAccepting(true)
    setError(null)
    try {
      await onAccept({ strictly_necessary: true, analytics: analyticsConsent })
    } catch {
      setError('Failed to record acceptance — please try again.')
      setAccepting(false)
    }
  }

  const scrollHint = !allScrolled
    ? 'Scroll to the bottom of each document to enable the Accept button.'
    : !warrantyChecked
      ? 'Check the box below to confirm before accepting.'
      : 'You\'re all set — click Accept & Continue.'
  const hintColor = !allScrolled ? 'var(--muted, #94A3B8)' : !warrantyChecked ? '#f59e0b' : '#22c55e'

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        zIndex: 9000,
      }}
      role="dialog"
      aria-modal="true"
      aria-labelledby="consent-modal-title"
    >
      <div
        className="slide-up"
        style={{
          background: 'var(--surface, #1E293B)',
          border: '1px solid var(--border, #334155)',
          borderRadius: 12,
          width: 'min(860px, 96vw)',
          maxHeight: '90vh',
          display: 'flex',
          flexDirection: 'column',
          overflow: 'hidden',
          boxShadow: '0 24px 64px rgba(0,0,0,0.7)',
        }}
        onClick={e => e.stopPropagation()}
      >
        {/* Header + tabs */}
        <div style={{ padding: '20px 24px 0', borderBottom: '1px solid var(--border, #334155)', flexShrink: 0 }}>
          <h2
            id="consent-modal-title"
            style={{ fontSize: 16, fontWeight: 700, color: 'var(--text, #F8FAFC)', marginBottom: 16 }}
          >
            Welcome to Signal Loom — please review and accept
          </h2>
          <div style={{ display: 'flex', marginBottom: -1 }}>
            {DOCS.map(doc => {
              const isActive = activeTab === doc.key
              const isDone   = scrolledDocs[doc.key]
              return (
                <button
                  key={doc.key}
                  onClick={() => switchTab(doc.key)}
                  style={{
                    padding: '10px 18px', fontSize: 13, fontWeight: 600,
                    color: isActive ? 'var(--cyan, #06B6D4)' : 'var(--muted, #94A3B8)',
                    background: 'none', border: 'none',
                    borderBottom: isActive ? '2px solid var(--cyan, #06B6D4)' : '2px solid transparent',
                    cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6,
                  }}
                >
                  {doc.label}
                  <span
                    style={{
                      display: 'inline-block', width: 14, height: 14, borderRadius: '50%',
                      background: isDone ? 'var(--cyan, #06B6D4)' : 'var(--border, #334155)',
                      color: isDone ? '#020617' : 'transparent',
                      fontSize: 9, lineHeight: '14px', textAlign: 'center',
                    }}
                    aria-hidden="true"
                  >
                    {isDone ? '✓' : ''}
                  </span>
                </button>
              )
            })}
          </div>
        </div>

        {/* Doc iframes */}
        <div style={{ flex: 1, position: 'relative', overflow: 'hidden', minHeight: 280 }}>
          {DOCS.map(doc => (
            <div
              key={doc.key}
              style={{ position: 'absolute', inset: 0, display: activeTab === doc.key ? 'block' : 'none' }}
            >
              {loadedSrcs[doc.key] ? (
                <iframe
                  src={loadedSrcs[doc.key]}
                  title={doc.label}
                  data-doc-version={DOC_VERSIONS[doc.key]}
                  style={{ width: '100%', height: '100%', border: 'none', background: '#020617' }}
                />
              ) : null}
            </div>
          ))}
        </div>

        {/* Cookie preferences panel */}
        <div
          style={{
            padding: '14px 24px',
            borderTop: '1px solid var(--border, #334155)',
            background: 'rgba(6,182,212,0.04)',
            flexShrink: 0,
          }}
        >
          <p style={{ fontSize: 12, fontWeight: 700, color: 'var(--text, #F8FAFC)', marginBottom: 10 }}>
            Cookie preferences
          </p>
          <p style={{ fontSize: 12, color: 'var(--muted, #94A3B8)', marginBottom: 10, lineHeight: 1.5 }}>
            Strictly necessary cookies are required to keep you signed in and keep the service
            working securely. These cannot be disabled.
          </p>

          {/* Strictly necessary — locked */}
          <label
            style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8, cursor: 'not-allowed', opacity: 0.7 }}
            title="Strictly necessary cookies are always required and cannot be disabled."
          >
            <input
              type="checkbox"
              checked
              disabled
              aria-label="Strictly necessary cookies — always on, cannot be disabled"
              style={{ accentColor: 'var(--cyan, #06B6D4)', width: 14, height: 14 }}
            />
            <span style={{ fontSize: 12, color: 'var(--muted, #94A3B8)' }}>
              Strictly necessary <span style={{ fontSize: 11, color: '#475569' }}>(always on)</span>
            </span>
          </label>

          {/* Analytics — opt-in */}
          <label
            style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}
            title="Aggregated, anonymised usage data to help us improve the product. No advertising or cross-site tracking."
          >
            <input
              type="checkbox"
              checked={analyticsConsent}
              onChange={e => setAnalyticsConsent(e.target.checked)}
              aria-label="Allow non-essential analytics cookies to help us improve the product"
              style={{ accentColor: 'var(--cyan, #06B6D4)', width: 14, height: 14 }}
            />
            <span style={{ fontSize: 12, color: 'var(--muted, #94A3B8)', lineHeight: 1.4 }}>
              Allow non-essential analytics cookies to help us improve the product
            </span>
          </label>
          <p style={{ fontSize: 11, color: '#475569', marginTop: 8 }}>
            You can change these at any time from Account Settings → Cookie Settings.
          </p>
        </div>

        {/* Acceptance + submit footer */}
        <div
          style={{
            padding: '14px 24px',
            borderTop: '1px solid var(--border, #334155)',
            display: 'flex', alignItems: 'flex-start', gap: 14, flexWrap: 'wrap',
            flexShrink: 0,
          }}
        >
          <label
            style={{
              display: 'flex', alignItems: 'flex-start', gap: 10,
              flex: 1, minWidth: 200, fontSize: 13,
              color: 'var(--muted, #94A3B8)', cursor: 'pointer',
            }}
          >
            <input
              type="checkbox"
              checked={warrantyChecked}
              onChange={e => setWarrantyChecked(e.target.checked)}
              style={{ marginTop: 2, accentColor: 'var(--cyan, #06B6D4)', width: 15, height: 15, flexShrink: 0 }}
            />
            <span style={{ lineHeight: 1.5 }}>
              I have read and agree to the Terms of Service, EULA, and Privacy Policy,
              and I confirm I am authorized to bind my organization to these terms.
            </span>
          </label>

          <div style={{ fontSize: 12, color: hintColor, flexBasis: '100%', marginTop: 2 }}>
            {scrollHint}
          </div>

          {error && (
            <div style={{ fontSize: 12, color: '#ef4444', flexBasis: '100%' }}>{error}</div>
          )}

          <button
            disabled={!canAccept}
            onClick={handleAccept}
            style={{
              padding: '10px 24px', fontSize: 14, fontWeight: 700, borderRadius: 6,
              background: canAccept ? 'var(--cyan, #06B6D4)' : undefined,
              color: canAccept ? '#020617' : undefined,
              opacity: canAccept ? 1 : 0.35, border: 'none',
              cursor: canAccept ? 'pointer' : 'not-allowed',
              whiteSpace: 'nowrap', transition: 'opacity 0.2s',
            }}
          >
            {accepting ? 'Saving…' : 'Accept & Continue'}
          </button>
        </div>
      </div>
    </div>
  )
}
