// ─── Policy-as-Versioned-Code types ─────────────────────────────────────────

export interface ComplianceCheck {
  framework: string
  controlSet: string
  control: string
  check: string
  passed: boolean
  policyVersion: string
  ale: number
  var95: number
  tvar: number
  carriedGbp: number
  scanTimestamp: string
  calibrationSource: string
}

export interface FrameworkSummary {
  id: string
  name: string
  versions: string[]
  totalControls: number
  passedControls: number
  failedControls: number
  totalExposureGbp: number
}

export interface ComplianceScanRequest {
  namespace: string
  policyVersion: string
  frameworks: string[]
}

export interface PostureSummary {
  totalChecks: number
  passed: number
  failed: number
  totalAle: number
  totalVar95: number
  totalTvar: number
  totalCarriedGbp: number
  scanTimestamp: string
  frameworks: FrameworkSummary[]
}
