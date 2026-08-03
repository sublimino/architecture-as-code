// The compliance findings that are currently open, named.
//
// The Agent Posture table below this already encodes the same facts, but it
// encodes them as a grid of coloured badges: a reader has to know which column
// is which framework and which cell went red to work out that something is
// wrong, and the agent it belongs to is three columns away. That is fine for
// an operator auditing at their own pace and useless to someone reading the
// page over a presenter's shoulder.
//
// So this states each open finding as a sentence — which control failed, on
// which agent, when it was assessed. It is derived entirely from
// GET /compliance/posture (the live endpoint, projected for the demo), so it
// appears when a scan finds something and disappears when the finding stops
// being reported. There is no fixture and no demo-specific branch in here.
//
// Contrast (worst case across Dark / Light / Andy) — see CredentialStateNotice
// for the full rationale and why --error is never used as body text:
//   --text  on the 12% error tint ..... 13.16:1  (AA needs 4.5)
//   --muted on the 12% error tint ...... 5.37:1  (AA needs 4.5)
//   --error 2px border vs host surface .. 3.03:1  (AA-UI needs 3.0)

import type { AgentPosture } from '../types/api'
import { tint } from './StatusBadge'

const ERROR_TINT = tint('var(--error)', 0.12)

export interface OpenFinding {
  agentId: string
  agentName: string
  controlId: string
  controlName: string
  frameworkName: string
  assessedAt: string | null
}

/**
 * Every failing control across every agent, newest assessment first.
 *
 * Newest-first is what makes this readable during a live scan: the finding the
 * platform just raised is the one at the top. Ties fall back to agent then
 * control name so the order is stable between polls — a list that reshuffles
 * itself every 2.5s is worse than no list.
 */
export function openFindings(agents: AgentPosture[]): OpenFinding[] {
  const findings: OpenFinding[] = []
  for (const agent of agents ?? []) {
    for (const r of agent.results ?? []) {
      if (r.status !== 'fail') continue
      findings.push({
        agentId: agent.agent_id,
        agentName: agent.agent_name,
        controlId: r.control_id,
        controlName: r.control_name,
        frameworkName: r.framework_name,
        assessedAt: r.assessed_at ?? null,
      })
    }
  }

  return findings.sort((a, b) => {
    const at = a.assessedAt ?? ''
    const bt = b.assessedAt ?? ''
    if (at !== bt) return bt.localeCompare(at)
    if (a.agentName !== b.agentName) return a.agentName.localeCompare(b.agentName)
    return a.controlName.localeCompare(b.controlName)
  })
}

function fmtStamp(iso: string | null): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  return d.toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

export default function OpenFindingsPanel({ agents }: { agents: AgentPosture[] }) {
  const findings = openFindings(agents)

  // Nothing open means nothing to say. The panel's absence is the all-clear —
  // and it is what makes a teardown visible: the findings stop being reported
  // and the panel goes away on the next poll.
  if (findings.length === 0) return null

  return (
    <section
      // Appears without user action on a window nobody is touching, so it has
      // to announce itself rather than wait to be found.
      role="status"
      aria-live="polite"
      aria-label="Open compliance findings"
      data-testid="open-findings-panel"
      style={{
        marginBottom: 24, padding: '16px 20px', borderRadius: 6,
        background: ERROR_TINT,
        border: '2px solid var(--error)',
      }}
    >
      <h2 style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', letterSpacing: '0.03em', margin: '0 0 10px' }}>
        {findings.length} OPEN COMPLIANCE {findings.length === 1 ? 'FINDING' : 'FINDINGS'}
      </h2>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0, display: 'flex', flexDirection: 'column', gap: 8 }}>
        {findings.map((f) => {
          const when = fmtStamp(f.assessedAt)
          return (
            <li key={`${f.agentId}:${f.controlId}`} style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.5 }}>
              <strong>{f.controlName}</strong> failed on <strong>{f.agentName}</strong>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                {f.frameworkName} · {f.controlId}
                {when && <> · assessed {when}</>}
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
