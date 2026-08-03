// What the platform did to an agent's credentials, stated in words.
//
// `lifecycle_state` renders as "suspended", which is a governance verdict, not
// an answer to the question a reader actually has: can this agent still reach
// anything, and why not? This component answers that, and names the cause, so
// the evidence stands on its own without a narrator.
//
// Visible to every authenticated user. There is deliberately no superadmin
// gate — a customer whose agent was just isolated is precisely the person who
// needs to see it.
//
// ── Colour ──────────────────────────────────────────────────────────────────
// Red is a redundant channel here, never the carrier of meaning: the words
// "Credentials revoked" say it, and the colour only reinforces it. That matters
// because `var(--error)` as TEXT bottoms out at 3.03:1 against `--surface2` in
// the Dark theme, which fails AA for body copy. So all text is `--text` or
// `--muted` over a 12% error tint, and `--error` appears only as a 2px border
// (a non-text UI boundary, which AA scores at 3:1).
//
// Analytic worst case across Dark / Light / Andy, over the least favourable
// host surface (--surface2):
//   --text  on the tint ............... 13.16:1  (AA needs 4.5)
//   --muted on the tint ................ 5.37:1  (AA needs 4.5)
//   --error 2px border vs host surface .. 3.03:1  (AA-UI needs 3.0)
//
// Verified empirically rather than only calculated: rendered in headless
// Chrome under all three themes and measured with getComputedStyle, resolving
// the color-mix() fill and compositing it against its real ancestors. 42 text
// nodes, zero AA failures, worst text 6.95:1, borders 3.70 / 6.18 / 5.14.
//
// Amber is deliberately not used as a fill anywhere: black-on-amber is 4.06:1
// in the Andy theme and fails AA.

import type { AgentCredentialState } from '../types/api'
import { tint } from './StatusBadge'

const ERROR_TINT = tint('var(--error)', 0.12)

function fmtStamp(iso: string | null | undefined): string | null {
  if (!iso) return null
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return null
  return d.toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

export interface CredentialStateNoticeProps {
  credentialState?: AgentCredentialState | null
  /** Named in the revoked wording so a screenshot identifies its own subject. */
  agentName?: string | null
  /** `inline` for a table cell, `panel` for the agent detail page. */
  variant?: 'inline' | 'panel'
}

export default function CredentialStateNotice({
  credentialState,
  agentName,
  variant = 'inline',
}: CredentialStateNoticeProps) {
  // Absent means the platform has nothing to say about this agent's
  // credentials, which is not the same as saying they are fine.
  if (!credentialState) return null

  if (credentialState.status !== 'revoked') {
    return (
      <span
        style={{ fontSize: 11, color: 'var(--muted)', whiteSpace: 'nowrap' }}
        data-testid="credential-state-active"
      >
        Credentials active
      </span>
    )
  }

  const when = fmtStamp(credentialState.revoked_at)
  const reason = credentialState.reason?.trim()
  const subject = agentName?.trim()

  // aria-live: on the audience window this appears without any user action, so
  // a screen reader has to be told rather than left to discover it on the next
  // manual traversal.
  const shared = {
    role: 'status' as const,
    'aria-live': 'polite' as const,
    'data-testid': 'credential-state-revoked',
  }

  if (variant === 'inline') {
    return (
      <span
        {...shared}
        style={{
          display: 'inline-flex', flexDirection: 'column', gap: 2,
          padding: '4px 9px', borderRadius: 4,
          background: ERROR_TINT,
          border: '2px solid var(--error)',
          maxWidth: 260,
        }}
      >
        <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--text)', letterSpacing: '0.03em' }}>
          STUNNED — CREDENTIALS REVOKED
        </span>
        {reason && (
          <span style={{ fontSize: 11, color: 'var(--text)', lineHeight: 1.35 }}>{reason}</span>
        )}
        {when && (
          <span style={{ fontSize: 10, color: 'var(--muted)' }}>Revoked {when}</span>
        )}
      </span>
    )
  }

  return (
    <div
      {...shared}
      style={{
        padding: '14px 18px', borderRadius: 6, marginBottom: 20,
        background: ERROR_TINT,
        border: '2px solid var(--error)',
      }}
    >
      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', letterSpacing: '0.03em', marginBottom: 6 }}>
        STUNNED — CREDENTIALS REVOKED
      </div>
      <div style={{ fontSize: 13, color: 'var(--text)', lineHeight: 1.55 }}>
        {subject ? <strong>{subject}</strong> : 'This agent'} can no longer authenticate to the
        platform. Every credential it held has been revoked
        {reason ? <> — {reason}</> : null}.
      </div>
      {(when || credentialState.revoked_by) && (
        <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 8 }}>
          {when && <>Revoked {when}</>}
          {when && credentialState.revoked_by && ' · '}
          {credentialState.revoked_by && <>by {credentialState.revoked_by}</>}
        </div>
      )}
    </div>
  )
}
