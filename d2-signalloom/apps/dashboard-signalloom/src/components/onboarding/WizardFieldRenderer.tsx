import type { WizardFieldSpec } from '../../types/connectors'

interface Props {
  fields: WizardFieldSpec[]
  values: Record<string, string>
  onChange: (name: string, value: string) => void
  disabled?: boolean
}

// Renders a WizardStepConfig.fields array generically — no per-provider
// hardcoding. `password` fields are masked and write-only: this component
// never receives a previously-stored secret value to pre-fill, since the API
// never returns credentials once stored.
export default function WizardFieldRenderer({ fields, values, onChange, disabled }: Props) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
      {fields.map((field) => (
        <div key={field.name}>
          <label
            htmlFor={`wf-${field.name}`}
            style={{ display: 'block', fontSize: 13, color: 'var(--muted)', marginBottom: 6, fontWeight: 500 }}
          >
            {field.label}
            {field.required && ' *'}
          </label>

          {field.type === 'select' ? (
            <select
              id={`wf-${field.name}`}
              value={values[field.name] ?? ''}
              onChange={(e) => onChange(field.name, e.target.value)}
              disabled={disabled}
              style={{ width: '100%' }}
            >
              <option value="" disabled>Select…</option>
              {(field.options ?? []).map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
          ) : (
            <input
              id={`wf-${field.name}`}
              type={field.type === 'password' ? 'password' : 'text'}
              autoComplete="off"
              value={values[field.name] ?? ''}
              onChange={(e) => onChange(field.name, e.target.value)}
              placeholder={field.placeholder}
              disabled={disabled}
              style={{ width: '100%' }}
            />
          )}

          {field.help_text && (
            <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>{field.help_text}</p>
          )}
        </div>
      ))}
    </div>
  )
}
