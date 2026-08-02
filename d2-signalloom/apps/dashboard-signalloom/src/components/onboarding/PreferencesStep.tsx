import { useState, type FormEvent } from 'react'
import StepIcon from './StepIcon'

export interface PreferencesValues {
  preferred_scan_cadence_hours: number
  alert_email: string
  alert_threshold: number
}

interface Props {
  initialValues: PreferencesValues
  submitting: boolean
  error?: string
  onSubmit: (values: PreferencesValues) => void
  onBack: () => void
}

const CADENCE_OPTIONS = [
  { value: 24, label: 'Daily' },
  { value: 168, label: 'Weekly' },
]

// Screen 4 of the onboarding wizard (86cajpvar QA item 4, Slice 1b). Cadence
// applies to connectors created from this point forward (see
// connectors.py::create_connector) — it's not retroactive. Alert email falls
// back to the tenant's contact email server-side if left blank here.
export default function PreferencesStep({ initialValues, submitting, error, onSubmit, onBack }: Props) {
  const [cadence, setCadence] = useState(initialValues.preferred_scan_cadence_hours)
  const [alertEmail, setAlertEmail] = useState(initialValues.alert_email)
  const [threshold, setThreshold] = useState(initialValues.alert_threshold)

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (submitting) return
    onSubmit({
      preferred_scan_cadence_hours: cadence,
      alert_email: alertEmail.trim(),
      alert_threshold: threshold,
    })
  }

  return (
    <div style={{ maxWidth: 560 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 6 }}>
        <StepIcon kind="preferences" />
        <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--text)' }}>
          Set your scan preferences
        </h1>
      </div>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginBottom: 20 }}>
        You can change these any time from Settings.
      </p>

      <form onSubmit={handleSubmit} noValidate>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
          <div>
            <label
              htmlFor="pref-cadence"
              style={{ display: 'block', fontSize: 13, color: 'var(--muted)', marginBottom: 6, fontWeight: 500 }}
            >
              Scan cadence
            </label>
            <select
              id="pref-cadence"
              value={cadence}
              onChange={(e) => setCadence(Number(e.target.value))}
              disabled={submitting}
              style={{ width: '100%' }}
            >
              {CADENCE_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
            <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Applies to providers you connect from here on — doesn't change providers you've already connected.
            </p>
          </div>

          <div>
            <label
              htmlFor="pref-alert-email"
              style={{ display: 'block', fontSize: 13, color: 'var(--muted)', marginBottom: 6, fontWeight: 500 }}
            >
              Alert email
            </label>
            <input
              id="pref-alert-email"
              type="email"
              autoComplete="off"
              value={alertEmail}
              onChange={(e) => setAlertEmail(e.target.value)}
              placeholder="you@company.com"
              disabled={submitting}
              style={{ width: '100%' }}
            />
            <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              Leave blank to use your account's contact email.
            </p>
          </div>

          <div>
            <label
              htmlFor="pref-threshold"
              style={{ display: 'block', fontSize: 13, color: 'var(--muted)', marginBottom: 6, fontWeight: 500 }}
            >
              Alert threshold
            </label>
            <input
              id="pref-threshold"
              type="number"
              min={1}
              value={threshold}
              onChange={(e) => setThreshold(Math.max(1, Number(e.target.value) || 1))}
              disabled={submitting}
              style={{ width: '100%' }}
            />
            <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
              We'll email you when a scan finds this many or more at-risk accounts.
            </p>
          </div>
        </div>

        {error && (
          <div
            style={{
              marginTop: 16,
              padding: '10px 14px',
              background: 'rgba(220,38,38,0.1)',
              border: '1px solid rgba(220,38,38,0.4)',
              borderRadius: 6,
              color: 'var(--error)',
              fontSize: 13,
            }}
          >
            {error}
          </div>
        )}

        <div style={{ display: 'flex', gap: 10, marginTop: 24 }}>
          <button type="button" className="btn btn-secondary" onClick={onBack} disabled={submitting}>
            Back
          </button>
          <button type="submit" className="btn btn-primary" disabled={submitting}>
            {submitting ? 'Saving…' : 'Continue'}
          </button>
        </div>
      </form>
    </div>
  )
}
