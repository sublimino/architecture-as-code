/**
 * Findings raised in the window: which rule fired, how hard, under which
 * bundle version, and a jump back to the observation that caused it.
 *
 * The bundle version is on every row and not in a page header on purpose.
 * Policy is versioned code: a reviewer judging a finding needs to know which
 * revision of the bundle judged it, because the same signal under 0.4.1 and
 * 0.4.2 can be two different decisions and "the rule was wrong" is a different
 * conclusion from "the rule changed".
 */
import type { PolicyFinding } from '../../api/policyApi'
import { LabelChips, layerColor, layerLabel, severityColor, thStyle, tdStyle, timeShort } from './presentation'

export default function FindingsList({ findings }: { findings: PolicyFinding[] }) {
  if (findings.length === 0) {
    return (
      <div data-testid="findings-empty" style={{ padding: '20px 0', fontSize: 12.5, color: 'var(--muted)' }}>
        No finding raised in this window.
      </div>
    )
  }

  return (
    // Eight columns do not fit a narrow card. `overflow: hidden` clipped the
    // trailing "Source signal" column, i.e. the jump to the observation that
    // caused the finding; scroll instead so every column stays reachable.
    <div className="card" style={{ padding: 0, overflowX: 'auto' }} data-testid="findings-list">
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ borderBottom: '1px solid var(--border)' }}>
            <th style={thStyle}>Time</th>
            <th style={thStyle}>Rule</th>
            <th style={thStyle}>Layer</th>
            <th style={thStyle}>Severity</th>
            <th style={thStyle}>Mode</th>
            <th style={thStyle}>Bundle</th>
            <th style={thStyle}>Actor</th>
            <th style={thStyle}>Source signal</th>
          </tr>
        </thead>
        <tbody>
          {findings.map((f) => (
            <tr key={f.id} data-testid="finding-row" style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={{ ...tdStyle, color: 'var(--muted)', fontVariantNumeric: 'tabular-nums' }}>
                {timeShort(f.timestamp)}
              </td>
              <td style={tdStyle}>
                <div data-testid="finding-rule" style={{ fontWeight: 600 }}>{f.rule_id}</div>
                <LabelChips labels={f.labels} />
              </td>
              <td style={{ ...tdStyle, color: layerColor(f.layer), fontWeight: 600, fontSize: 12 }}>
                {layerLabel(f.layer)}
              </td>
              <td style={tdStyle}>
                <span
                  data-testid="finding-severity"
                  className="tag"
                  style={{ color: severityColor(f.severity), background: 'var(--surface2)' }}
                >
                  {f.severity}
                </span>
              </td>
              <td style={{ ...tdStyle, color: 'var(--muted)', fontSize: 12 }}>{f.mode}</td>
              <td style={{ ...tdStyle, fontSize: 12 }} data-testid="finding-bundle">
                {f.bundle_id} {f.bundle_version}
              </td>
              <td style={{ ...tdStyle, fontSize: 12 }} title="Pseudonymous actor reference">{f.actor}</td>
              <td style={tdStyle}>
                <a
                  data-testid="finding-observation-link"
                  href={`#observation-${f.source_observation_id}`}
                  style={{ fontSize: 12, color: 'var(--cyan)' }}
                >
                  {f.source_observation_id}
                </a>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
