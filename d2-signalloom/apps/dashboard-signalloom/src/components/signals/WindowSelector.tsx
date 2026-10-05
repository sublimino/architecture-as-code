/**
 * The window selector: 5 / 10 / 30 / 90 minutes, shared by both tabs.
 *
 * `aria-pressed` rather than a radio group, because this is a toolbar of
 * toggles over one shared value and that is the pattern the rest of the
 * dashboard's segmented controls already use.
 */
import { POLICY_WINDOWS, type PolicyWindow } from '../../api/policyApi'

export default function WindowSelector({
  value,
  onChange,
  disabled = false,
}: {
  value: PolicyWindow
  onChange: (w: PolicyWindow) => void
  disabled?: boolean
}) {
  return (
    <div
      role="group"
      aria-label="Time window"
      data-testid="window-selector"
      style={{ display: 'flex', gap: 4, background: 'var(--surface2)', padding: 3, borderRadius: 6, border: '1px solid var(--border)' }}
    >
      {POLICY_WINDOWS.map((w) => {
        const active = w === value
        return (
          <button
            key={w}
            type="button"
            data-testid={`window-btn-${w}`}
            aria-pressed={active}
            disabled={disabled}
            onClick={() => onChange(w)}
            style={{
              padding: '5px 12px',
              fontSize: 12,
              fontWeight: 600,
              borderRadius: 4,
              border: active ? '1px solid var(--teal)' : '1px solid transparent',
              background: active ? 'var(--surface)' : 'transparent',
              color: active ? 'var(--text)' : 'var(--muted)',
              cursor: disabled ? 'not-allowed' : 'pointer',
            }}
          >
            {w}
          </button>
        )
      })}
    </div>
  )
}
