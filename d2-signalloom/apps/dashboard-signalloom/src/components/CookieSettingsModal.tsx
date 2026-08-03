/**
 * CookieSettingsModal — update analytics opt-in post-consent.
 * Opened from Account Settings → Cookie Settings link.
 * Reads current preferences from GET /api/cookie-preferences,
 * writes changes via PATCH /api/cookie-preferences.
 */
import { useEffect, useState } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import LoadingState from './LoadingState'

interface Props {
  onClose: () => void
}

export default function CookieSettingsModal({ onClose }: Props) {
  const { getAccessTokenSilently } = useAuth0()
  const [analytics, setAnalytics] = useState(false)
  const [loading, setLoading]     = useState(true)
  const [saving, setSaving]       = useState(false)
  const [saved, setSaved]         = useState(false)
  const [error, setError]         = useState<string | null>(null)

  useEffect(() => {
    ;(async () => {
      try {
        const token = await getAccessTokenSilently()
        const res = await api.cookiePreferences.get(token)
        setAnalytics(res.cookie_preferences.analytics)
      } catch {
        // Fail open — show default unchecked state
      } finally {
        setLoading(false)
      }
    })()
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  async function handleSave() {
    setSaving(true)
    setError(null)
    setSaved(false)
    try {
      const token = await getAccessTokenSilently()
      const res = await api.cookiePreferences.patch(token, analytics)
      setAnalytics(res.cookie_preferences.analytics)
      setSaved(true)
    } catch {
      setError('Failed to save preferences — please try again.')
    } finally {
      setSaving(false)
    }
  }

  // Close on Escape
  useEffect(() => {
    function onKey(e: KeyboardEvent) { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)', backdropFilter: 'blur(6px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 8000,
      }}
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-labelledby="cookie-settings-title"
    >
      <div
        className="slide-up"
        style={{
          background: 'var(--surface, #1E293B)',
          border: '1px solid var(--border, #334155)',
          borderRadius: 12,
          width: 'min(460px, 94vw)',
          padding: '28px 28px 24px',
          boxShadow: '0 16px 48px rgba(0,0,0,0.6)',
        }}
        onClick={e => e.stopPropagation()}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 20 }}>
          <h2 id="cookie-settings-title" style={{ fontSize: 15, fontWeight: 700, color: 'var(--text, #F8FAFC)' }}>
            Cookie Preferences
          </h2>
          <button
            onClick={onClose}
            aria-label="Close cookie settings"
            style={{ background: 'none', border: 'none', color: 'var(--muted, #94A3B8)', cursor: 'pointer', fontSize: 18, lineHeight: 1 }}
          >
            ×
          </button>
        </div>

        {loading ? (
          <LoadingState status="loading" label="preferences" testId="cookie-prefs-load-state" />
        ) : (
          <>
            {/* Strictly necessary */}
            <div style={{ marginBottom: 20 }}>
              <p style={{ fontSize: 13, fontWeight: 600, color: 'var(--text, #F8FAFC)', marginBottom: 6 }}>
                Strictly necessary cookies <span style={{ fontWeight: 400, color: 'var(--slate-gray)', fontSize: 12 }}>(always on)</span>
              </p>
              <p style={{ fontSize: 12, color: 'var(--muted, #94A3B8)', lineHeight: 1.5 }}>
                Authentication, session state, security. Required for the service to function.
              </p>
            </div>

            {/* Analytics */}
            <div style={{ marginBottom: 24 }}>
              <label
                style={{ display: 'flex', alignItems: 'flex-start', gap: 10, cursor: 'pointer' }}
              >
                <input
                  type="checkbox"
                  checked={analytics}
                  onChange={e => { setAnalytics(e.target.checked); setSaved(false) }}
                  aria-label="Allow non-essential analytics cookies"
                  style={{ marginTop: 2, accentColor: 'var(--cyan, #06B6D4)', width: 15, height: 15, flexShrink: 0 }}
                />
                <span>
                  <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--text, #F8FAFC)', display: 'block', marginBottom: 3 }}>
                    Analytics
                  </span>
                  <span style={{ fontSize: 12, color: 'var(--muted, #94A3B8)', lineHeight: 1.5 }}>
                    Aggregated, anonymised usage data to help us improve the product. No advertising or cross-site tracking.
                  </span>
                </span>
              </label>
            </div>

            {error && <p style={{ fontSize: 12, color: 'var(--error)', marginBottom: 12 }}>{error}</p>}
            {saved && <p style={{ fontSize: 12, color: 'var(--teal)', marginBottom: 12 }}>Preferences saved.</p>}

            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button
                onClick={onClose}
                style={{
                  padding: '8px 16px', fontSize: 13, borderRadius: 6,
                  background: 'none', border: '1px solid var(--border, #334155)',
                  color: 'var(--muted, #94A3B8)', cursor: 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                onClick={handleSave}
                disabled={saving}
                style={{
                  padding: '8px 20px', fontSize: 13, fontWeight: 700, borderRadius: 6,
                  background: 'var(--cyan, #06B6D4)', color: 'var(--bg)',
                  border: 'none', cursor: saving ? 'not-allowed' : 'pointer',
                  opacity: saving ? 0.6 : 1,
                }}
              >
                {saving ? 'Saving…' : 'Save preferences'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
