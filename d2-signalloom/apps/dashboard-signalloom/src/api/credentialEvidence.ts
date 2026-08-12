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

export type EvidenceState = 'observed' | 'absent' | 'unavailable'

export interface EvidenceStep {
  step: number
  label: string
  state: EvidenceState
  /** The literal command that produced this verdict — paste-and-rerun. */
  command: string
  /** Raw probe output, shown in the debugger console. */
  detail: string
  /** One plain sentence for a non-technical viewer. */
  summary: string
}

export interface CredentialEvidence {
  generated_at: string
  source: string
  steps: EvidenceStep[]
}

export const EVIDENCE_ENDPOINT = '/api/demo/supercred/evidence'

/** Narrow an unknown state string without inventing progress for it. */
export function normaliseState(raw: unknown): EvidenceState {
  return raw === 'observed' || raw === 'absent' ? raw : 'unavailable'
}

export function parseEvidence(payload: unknown): CredentialEvidence {
  const root = (payload ?? {}) as Record<string, unknown>
  const rawSteps = Array.isArray(root.steps) ? root.steps : []
  return {
    generated_at: typeof root.generated_at === 'string' ? root.generated_at : '',
    source: typeof root.source === 'string' ? root.source : 'unknown',
    steps: rawSteps.map((entry, index) => {
      const s = (entry ?? {}) as Record<string, unknown>
      return {
        step: typeof s.step === 'number' ? s.step : index + 1,
        label: typeof s.label === 'string' ? s.label : `Step ${index + 1}`,
        state: normaliseState(s.state),
        command: typeof s.command === 'string' ? s.command : '',
        detail: typeof s.detail === 'string' ? s.detail : '',
        summary: typeof s.summary === 'string' ? s.summary : '',
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
