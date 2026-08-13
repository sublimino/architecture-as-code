// The credential chain as OBSERVED, not as asserted.
//
// The card this feeds used to build six steps from `!!agent.id` and print
// hardcoded timestamps, so every step read "completed" the moment an agent
// existed. This type has no `completed`. A step is only ever:
//
//   observed     a probe ran and confirmed it
//   absent       a probe ran and disproved it
//   unavailable  the probe could not run — NOT the same as absent
//
// Keeping `unavailable` distinct from `absent` is the whole discipline. They
// render differently and neither renders as progress: "we could not look" and
// "we looked and it is not there" are different claims, and collapsing them is
// how a broken probe becomes a confident one.

import { DEMO_API } from './demoRunner'

export type EvidenceState = 'observed' | 'absent' | 'unavailable'

/**
 * One command and its output, backing part of a step's verdict.
 *
 * A step carried exactly one command until step 6 proved that was too few. A
 * stun is a revocation (the mechanism), an annotation (corroboration) and a
 * NetworkPolicy (containment); with room for one command, whichever one was
 * shown silently became the definition of the step — and the one that had been
 * shown was the NetworkPolicy, the weakest of the three.
 */
export interface EvidenceProof {
  /** Short name for the tab — what this command is evidence OF. */
  label: string
  /** The literal command that produced this output — paste-and-rerun. */
  command: string
  /** Raw output, shown in the debugger console. */
  detail: string
}

export interface EvidenceStep {
  step: number
  label: string
  state: EvidenceState
  /** The primary proof's command, carried for producers that predate `proofs`. */
  command: string
  /** The primary proof's output, carried for producers that predate `proofs`. */
  detail: string
  /** One plain sentence for a non-technical viewer. */
  summary: string
  /**
   * Every proof behind the verdict, primary first. Always populated after
   * parsing: a payload carrying only `command`/`detail` is normalised to a
   * single proof, so the renderer has one shape to draw and an old producer
   * degrades to exactly what it used to show.
   */
  proofs: EvidenceProof[]
}

export interface CredentialEvidence {
  generated_at: string
  source: string
  steps: EvidenceStep[]
}

// Routed through the same prefix as every other demo-runner call. Spelling this
// `/api/demo/supercred/evidence` reaches fe-signalloom-api instead of the runner
// — a pod with no kubectl and no scripts, where the handler dies with
// `IndexError: 4` and the card renders a bare HTTP 500. See DEMO_API.
export const EVIDENCE_ENDPOINT = `${DEMO_API}/evidence`

/** Narrow an unknown state string without inventing progress for it. */
export function normaliseState(raw: unknown): EvidenceState {
  return raw === 'observed' || raw === 'absent' ? raw : 'unavailable'
}

/**
 * Normalise a step's proofs to the multi-proof shape, whatever the producer sent.
 *
 * The single-command shape is not deprecated data to be tolerated — it is what
 * every step with one probe still sends, and what a runner image built before
 * `proofs` existed sends for all of them. Both collapse to the same thing: one
 * proof, labelled with the step it belongs to.
 */
function parseProofs(raw: unknown, fallback: { label: string; command: string; detail: string }): EvidenceProof[] {
  const entries = Array.isArray(raw) ? raw : []
  const proofs = entries
    .map((entry) => {
      const p = (entry ?? {}) as Record<string, unknown>
      return {
        label: typeof p.label === 'string' ? p.label : '',
        command: typeof p.command === 'string' ? p.command : '',
        detail: typeof p.detail === 'string' ? p.detail : '',
      }
    })
    // A proof with no command proves nothing and would render as an empty tab.
    .filter((p) => p.command !== '')
  return proofs.length > 0 ? proofs : [fallback]
}

export function parseEvidence(payload: unknown): CredentialEvidence {
  const root = (payload ?? {}) as Record<string, unknown>
  const rawSteps = Array.isArray(root.steps) ? root.steps : []
  return {
    generated_at: typeof root.generated_at === 'string' ? root.generated_at : '',
    source: typeof root.source === 'string' ? root.source : 'unknown',
    steps: rawSteps.map((entry, index) => {
      const s = (entry ?? {}) as Record<string, unknown>
      const label = typeof s.label === 'string' ? s.label : `Step ${index + 1}`
      const command = typeof s.command === 'string' ? s.command : ''
      const detail = typeof s.detail === 'string' ? s.detail : ''
      return {
        step: typeof s.step === 'number' ? s.step : index + 1,
        label,
        state: normaliseState(s.state),
        command,
        detail,
        summary: typeof s.summary === 'string' ? s.summary : '',
        proofs: parseProofs(s.proofs, { label, command, detail }),
      }
    }),
  }
}

/**
 * How many steps are actually proven. Used for the executive one-liner.
 *
 * `unavailable` deliberately counts toward neither proven nor disproven — it is
 * reported separately so a reader can tell "5 of 6 confirmed" from "5 of 6
 * confirmed, 1 we could not check".
 */
export function evidenceSummary(steps: EvidenceStep[]): {
  observed: number
  absent: number
  unavailable: number
  total: number
} {
  return {
    observed: steps.filter((s) => s.state === 'observed').length,
    absent: steps.filter((s) => s.state === 'absent').length,
    unavailable: steps.filter((s) => s.state === 'unavailable').length,
    total: steps.length,
  }
}
