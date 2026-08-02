// Fake compliance-policy fixtures for demo mode.
//
// Separated from fakeData.ts to avoid bloating the main fixture file. These
// routes are imported and merged into the ROUTES array in fakeData.ts.

import type {
  ComplianceCheck,
  FrameworkSummary,
  PostureSummary,
} from '../types/compliance'

const NOW = '2026-07-27T12:00:00Z'
const CALIBRATION = 'industry-indicative'

// ─── EU AI Act Controls ─────────────────────────────────────────────────────

const EU_AI_ACT_CHECKS: ComplianceCheck[] = [
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-1', check: 'Model card published', passed: true, policyVersion: 'v2.1', ale: 8200, var95: 34000, tvar: 52000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-2', check: 'Decision explanation logged', passed: true, policyVersion: 'v2.1', ale: 6100, var95: 28000, tvar: 45000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-3', check: 'Data provenance recorded', passed: false, policyVersion: 'v2.0', ale: 12400, var95: 58000, tvar: 89000, carriedGbp: 12400, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-1', check: 'Kill switch operational', passed: true, policyVersion: 'v2.1', ale: 15800, var95: 72000, tvar: 110000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-2', check: 'Human-in-the-loop enforced', passed: true, policyVersion: 'v2.1', ale: 9500, var95: 41000, tvar: 63000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-3', check: 'Override audit trail', passed: false, policyVersion: 'v2.0', ale: 18700, var95: 85000, tvar: 130000, carriedGbp: 18700, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-1', check: 'Risk assessment documented', passed: true, policyVersion: 'v2.1', ale: 7300, var95: 31000, tvar: 48000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-2', check: 'Bias testing complete', passed: true, policyVersion: 'v2.1', ale: 11200, var95: 49000, tvar: 76000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-3', check: 'Incident response plan', passed: true, policyVersion: 'v1.0', ale: 5600, var95: 24000, tvar: 38000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Data Governance', control: 'AID-1', check: 'Training data catalogue', passed: false, policyVersion: 'v2.0', ale: 22100, var95: 98000, tvar: 155000, carriedGbp: 22100, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── NIST 800-53 Controls ───────────────────────────────────────────────────

const NIST_CHECKS: ComplianceCheck[] = [
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-1', check: 'Access policy defined', passed: true, policyVersion: 'v2.1', ale: 9800, var95: 42000, tvar: 65000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-2', check: 'Account management', passed: true, policyVersion: 'v2.1', ale: 7200, var95: 30000, tvar: 47000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-3', check: 'Enforcement mechanism', passed: false, policyVersion: 'v2.0', ale: 14300, var95: 64000, tvar: 98000, carriedGbp: 14300, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-1', check: 'Audit policy defined', passed: true, policyVersion: 'v2.1', ale: 6400, var95: 27000, tvar: 42000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-2', check: 'Auditable events identified', passed: true, policyVersion: 'v2.1', ale: 8100, var95: 35000, tvar: 54000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-3', check: 'Content of audit records', passed: true, policyVersion: 'v1.0', ale: 5200, var95: 22000, tvar: 34000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-1', check: 'Protection policy defined', passed: true, policyVersion: 'v2.1', ale: 11500, var95: 50000, tvar: 78000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-7', check: 'Boundary protection', passed: false, policyVersion: 'v2.0', ale: 31200, var95: 142000, tvar: 218000, carriedGbp: 31200, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-8', check: 'Transmission confidentiality', passed: true, policyVersion: 'v2.1', ale: 8900, var95: 38000, tvar: 59000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Identification & Auth', control: 'IA-1', check: 'I&A policy defined', passed: true, policyVersion: 'v2.1', ale: 7600, var95: 33000, tvar: 51000, carriedGbp: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

const ALL_CHECKS = [...EU_AI_ACT_CHECKS, ...NIST_CHECKS]

// ─── olly-sentinel partial compliance ───────────────────────────────────────

const OLLY_CHECKS_V2: ComplianceCheck[] = ALL_CHECKS.map((c) => ({
  ...c,
  check: `[olly-sentinel] ${c.check}`,
  // At v2.0, olly-sentinel is only partially compliant
  passed: c.policyVersion === 'v1.0' ? true : c.passed,
}))

const OLLY_CHECKS_V1: ComplianceCheck[] = ALL_CHECKS.map((c) => ({
  ...c,
  check: `[olly-sentinel] ${c.check}`,
  policyVersion: 'v1.0',
  passed: true, // fully compliant at v1.0
  carriedGbp: 0,
}))

// ─── Summaries ──────────────────────────────────────────────────────────────

function summariseFramework(id: string, name: string, checks: ComplianceCheck[]): FrameworkSummary {
  const fwChecks = checks.filter((c) => c.framework === name)
  const passed = fwChecks.filter((c) => c.passed).length
  const failed = fwChecks.length - passed
  const versions = [...new Set(fwChecks.map((c) => c.policyVersion))].sort()
  return {
    id,
    name,
    versions,
    totalControls: fwChecks.length,
    passedControls: passed,
    failedControls: failed,
    totalExposureGbp: fwChecks.reduce((s, c) => s + c.carriedGbp, 0),
  }
}

function buildPostureSummary(checks: ComplianceCheck[]): PostureSummary {
  const passed = checks.filter((c) => c.passed).length
  return {
    totalChecks: checks.length,
    passed,
    failed: checks.length - passed,
    totalAle: checks.reduce((s, c) => s + c.ale, 0),
    totalVar95: checks.reduce((s, c) => s + c.var95, 0),
    totalTvar: checks.reduce((s, c) => s + c.tvar, 0),
    totalCarriedGbp: checks.reduce((s, c) => s + c.carriedGbp, 0),
    scanTimestamp: checks[0]?.scanTimestamp ?? NOW,
    frameworks: [
      summariseFramework('eu-ai-act', 'EU AI Act', checks),
      summariseFramework('nist-800-53', 'NIST 800-53', checks),
    ],
  }
}

const POSTURE_SUMMARY = buildPostureSummary(ALL_CHECKS)
const FRAMEWORK_LIST: FrameworkSummary[] = POSTURE_SUMMARY.frameworks

// ─── Scan by version (what-if) ──────────────────────────────────────────────

function checksForVersion(version: string): ComplianceCheck[] {
  if (version === 'v1.0') {
    return ALL_CHECKS.map((c) => ({ ...c, policyVersion: 'v1.0', passed: true, carriedGbp: 0 }))
  }
  if (version === 'v2.0') {
    return ALL_CHECKS // mix of pass/fail as defined
  }
  // v2.1 — tightest policy, fewer failures
  return ALL_CHECKS.map((c) => ({
    ...c,
    policyVersion: 'v2.1',
    passed: c.policyVersion === 'v2.1' ? c.passed : true,
    carriedGbp: c.policyVersion === 'v2.1' ? c.carriedGbp : 0,
  }))
}

// ─── Route matcher type (matches fakeData.ts pattern) ───────────────────────

type Match = {
  method: string
  test: (path: string) => boolean
  data: (path: string, body?: unknown) => unknown
}

const re = (r: RegExp) => (path: string) => r.test(path)

export const COMPLIANCE_POLICY_ROUTES: Match[] = [
  {
    method: 'GET',
    test: re(/^\/compliance\/policy\/frameworks$/),
    data: () => FRAMEWORK_LIST,
  },
  {
    method: 'GET',
    test: re(/^\/compliance\/policy\/summary$/),
    data: () => POSTURE_SUMMARY,
  },
  {
    method: 'POST',
    test: re(/^\/compliance\/policy\/scan$/),
    data: (_p, body) => {
      const req = body as { policyVersion?: string } | undefined
      const version = req?.policyVersion ?? 'v2.0'
      const checks = checksForVersion(version)
      return {
        checks,
        summary: buildPostureSummary(checks),
      }
    },
  },
]

// Re-export raw data for tests and other consumers
export { ALL_CHECKS, OLLY_CHECKS_V2, OLLY_CHECKS_V1, POSTURE_SUMMARY, FRAMEWORK_LIST, checksForVersion }
