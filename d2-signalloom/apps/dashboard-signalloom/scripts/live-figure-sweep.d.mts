// Types for the plain-JS sweep script, so the test can import `sweep` without
// an implicit any. Kept alongside the script rather than converted to TS: the
// script must stay runnable by bare `node` with no build step, because it is
// meant to work in CI and on a developer's machine before install.

export interface LiveFigureFinding {
  /** 'ungated-fixture-import' | 'figure-literal' */
  rule: string
  /** Path relative to the swept src root, forward slashes. */
  file: string
  line: number
  /** Human-readable description of what was matched. */
  detail: string
  /** Why this shape is a defect. */
  why: string
}

export interface LiveFigureException {
  file: string
  rule: string
  /** Omitted = whole-file exception. Present = scoped to this one finding. */
  detail?: string
  /** Mandatory. An exception without a reason is a silenced defect. */
  reason: string
}

/** Scan a `src` directory and return every finding, sorted by file then line. */
export declare function sweep(srcRoot: string): LiveFigureFinding[]

/** The pinned exception list, exported so a test can assert each has a reason. */
export declare const EXCEPTIONS: LiveFigureException[]
