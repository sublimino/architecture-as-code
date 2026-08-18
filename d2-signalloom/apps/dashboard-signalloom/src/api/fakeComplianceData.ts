// Fake compliance-policy fixtures for demo mode.
//
// Separated from fakeData.ts to avoid bloating the main fixture file. These
// routes are imported and merged into the ROUTES array in fakeData.ts.

import type {
  ComplianceCheck,
  FrameworkSummary,
  PostureSummary,
} from '../types/compliance'
import type { CurrencyCode } from '../money/currency'
import { money, sumMoney, type Money } from '../money/money'

const NOW = '2026-07-27T12:00:00Z'
const CALIBRATION = 'industry-indicative'

/**
 * The reporting currency of this demo document.
 *
 * One org, one reporting currency — the engine emits `doc.Currency` per ORG,
 * so mixing denominations inside a single scan would misrepresent what the
 * payload can actually look like. Multi-currency rendering is exercised in
 * fakeComplianceData.test.ts, which builds documents in other currencies and a
 * deliberately mixed one, rather than by making the shipped demo confusing.
 */
const DEMO_CURRENCY: CurrencyCode = 'GBP'

/**
 * The fixture rows as authored: bare numbers, all in DEMO_CURRENCY.
 *
 * Denominated in one place by `denominate()` below rather than repeating
 * `{ amount, currency }` twenty-two times, which would bury the numbers the
 * fixture exists to state.
 */
type RawCheck = Omit<ComplianceCheck, 'ale' | 'var95' | 'tvar' | 'carried'> & {
  ale: number
  var95: number
  tvar: number
  carried: number
}

function denominate(c: RawCheck): ComplianceCheck {
  return {
    ...c,
    ale: money(c.ale, DEMO_CURRENCY),
    var95: money(c.var95, DEMO_CURRENCY),
    tvar: money(c.tvar, DEMO_CURRENCY),
    carried: money(c.carried, DEMO_CURRENCY),
  }
}

/** Zero exposure in this document's currency. */
const noExposure = (): Money => money(0, DEMO_CURRENCY)

// ─── EU AI Act Controls ─────────────────────────────────────────────────────

const EU_AI_ACT_CHECKS: RawCheck[] = [
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-1', check: 'Model card published', passed: true, policyVersion: 'v2.1', ale: 8200, var95: 34000, tvar: 52000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-2', check: 'Decision explanation logged', passed: true, policyVersion: 'v2.1', ale: 6100, var95: 28000, tvar: 45000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Transparency', control: 'AIT-3', check: 'Data provenance recorded', passed: false, policyVersion: 'v2.0', ale: 12400, var95: 58000, tvar: 89000, carried: 12400, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-1', check: 'Kill switch operational', passed: true, policyVersion: 'v2.1', ale: 15800, var95: 72000, tvar: 110000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-2', check: 'Human-in-the-loop enforced', passed: true, policyVersion: 'v2.1', ale: 9500, var95: 41000, tvar: 63000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Human Oversight', control: 'AIO-3', check: 'Override audit trail', passed: false, policyVersion: 'v2.0', ale: 18700, var95: 85000, tvar: 130000, carried: 18700, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-1', check: 'Risk assessment documented', passed: true, policyVersion: 'v2.1', ale: 7300, var95: 31000, tvar: 48000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-2', check: 'Bias testing complete', passed: true, policyVersion: 'v2.1', ale: 11200, var95: 49000, tvar: 76000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Risk Management', control: 'AIR-3', check: 'Incident response plan', passed: true, policyVersion: 'v1.0', ale: 5600, var95: 24000, tvar: 38000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'EU AI Act', controlSet: 'Data Governance', control: 'AID-1', check: 'Training data catalogue', passed: false, policyVersion: 'v2.0', ale: 22100, var95: 98000, tvar: 155000, carried: 22100, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── NIST 800-53 Controls ───────────────────────────────────────────────────

const NIST_CHECKS: RawCheck[] = [
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-1', check: 'Access policy defined', passed: true, policyVersion: 'v2.1', ale: 9800, var95: 42000, tvar: 65000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-2', check: 'Account management', passed: true, policyVersion: 'v2.1', ale: 7200, var95: 30000, tvar: 47000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Access Control', control: 'AC-3', check: 'Enforcement mechanism', passed: false, policyVersion: 'v2.0', ale: 14300, var95: 64000, tvar: 98000, carried: 14300, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-1', check: 'Audit policy defined', passed: true, policyVersion: 'v2.1', ale: 6400, var95: 27000, tvar: 42000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-2', check: 'Auditable events identified', passed: true, policyVersion: 'v2.1', ale: 8100, var95: 35000, tvar: 54000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Audit & Accountability', control: 'AU-3', check: 'Content of audit records', passed: true, policyVersion: 'v1.0', ale: 5200, var95: 22000, tvar: 34000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-1', check: 'Protection policy defined', passed: true, policyVersion: 'v2.1', ale: 11500, var95: 50000, tvar: 78000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-7', check: 'Boundary protection', passed: false, policyVersion: 'v2.0', ale: 31200, var95: 142000, tvar: 218000, carried: 31200, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'System & Comms Protection', control: 'SC-8', check: 'Transmission confidentiality', passed: true, policyVersion: 'v2.1', ale: 8900, var95: 38000, tvar: 59000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIST 800-53', controlSet: 'Identification & Auth', control: 'IA-1', check: 'I&A policy defined', passed: true, policyVersion: 'v2.1', ale: 7600, var95: 33000, tvar: 51000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── DORA — Regulation (EU) 2022/2554 ───────────────────────────────────────
//
// Control IDs are DORA article numbers and the check text is the article's own
// subject matter. Control sets follow the regulation's chapter structure:
// Ch. II ICT risk management (Arts 5-16), Ch. III ICT-related incident
// management (17-23), Ch. IV digital operational resilience testing (24-27),
// Ch. V ICT third-party risk (28-44).

const DORA_CHECKS: RawCheck[] = [
  { framework: 'DORA', controlSet: 'ICT Risk Management', control: 'Art. 6', check: 'ICT risk management framework documented', passed: true, policyVersion: 'v2.1', ale: 9400, var95: 41000, tvar: 65000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Risk Management', control: 'Art. 9', check: 'Protection and prevention controls applied', passed: true, policyVersion: 'v2.1', ale: 12800, var95: 59000, tvar: 91000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Risk Management', control: 'Art. 10', check: 'Anomalous activity detection in place', passed: false, policyVersion: 'v2.0', ale: 26500, var95: 117000, tvar: 182000, carried: 26500, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Risk Management', control: 'Art. 12', check: 'Backup, restoration and recovery procedures', passed: true, policyVersion: 'v2.1', ale: 10600, var95: 47000, tvar: 74000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Incident Management', control: 'Art. 17', check: 'ICT-related incident management process', passed: true, policyVersion: 'v2.1', ale: 8700, var95: 39000, tvar: 61000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Incident Management', control: 'Art. 19', check: 'Major incident reporting within regulatory deadline', passed: false, policyVersion: 'v2.0', ale: 34800, var95: 158000, tvar: 249000, carried: 34800, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'Digital Operational Resilience Testing', control: 'Art. 24', check: 'Resilience testing programme established', passed: true, policyVersion: 'v2.1', ale: 7900, var95: 33000, tvar: 51000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'Digital Operational Resilience Testing', control: 'Art. 25', check: 'ICT tools and systems tested', passed: true, policyVersion: 'v1.0', ale: 6300, var95: 29000, tvar: 46000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Third-Party Risk', control: 'Art. 28', check: 'Third-party ICT risk register maintained', passed: true, policyVersion: 'v2.1', ale: 13900, var95: 63000, tvar: 101000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'DORA', controlSet: 'ICT Third-Party Risk', control: 'Art. 30', check: 'Key contractual provisions present in agent supplier contracts', passed: false, policyVersion: 'v2.0', ale: 29700, var95: 135000, tvar: 209000, carried: 29700, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── NIS2 — Directive (EU) 2022/2555 ────────────────────────────────────────
//
// Control IDs are the lettered cybersecurity risk-management measures of
// Article 21(2)(a)-(j). The control sets are a reading grouping, not a
// structure the directive itself imposes — Art. 21(2) is a flat list.

const NIS2_CHECKS: RawCheck[] = [
  { framework: 'NIS2', controlSet: 'Risk Management Measures', control: 'Art. 21(2)(a)', check: 'Risk analysis and information system security policies', passed: true, policyVersion: 'v2.1', ale: 10200, var95: 46000, tvar: 74000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Risk Management Measures', control: 'Art. 21(2)(f)', check: 'Effectiveness of risk-management measures assessed', passed: false, policyVersion: 'v2.0', ale: 19600, var95: 84000, tvar: 131000, carried: 19600, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Incident Handling', control: 'Art. 21(2)(b)', check: 'Incident handling procedures operational', passed: true, policyVersion: 'v2.1', ale: 9100, var95: 41000, tvar: 63000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Incident Handling', control: 'Art. 21(2)(c)', check: 'Business continuity, backup and crisis management', passed: true, policyVersion: 'v1.0', ale: 7400, var95: 32000, tvar: 50000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Supply Chain Security', control: 'Art. 21(2)(d)', check: 'Direct supplier and service provider security addressed', passed: false, policyVersion: 'v2.0', ale: 27300, var95: 126000, tvar: 195000, carried: 27300, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Supply Chain Security', control: 'Art. 21(2)(e)', check: 'Security in acquisition, development and maintenance', passed: true, policyVersion: 'v2.1', ale: 11800, var95: 51000, tvar: 81000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Access Control & Cryptography', control: 'Art. 21(2)(h)', check: 'Cryptography and encryption policy applied', passed: true, policyVersion: 'v2.1', ale: 8600, var95: 36000, tvar: 57000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Access Control & Cryptography', control: 'Art. 21(2)(i)', check: 'Human resources security, access control and asset management', passed: true, policyVersion: 'v2.1', ale: 12100, var95: 51000, tvar: 81000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Access Control & Cryptography', control: 'Art. 21(2)(j)', check: 'Multi-factor authentication enforced for agent operators', passed: false, policyVersion: 'v2.0', ale: 23400, var95: 100000, tvar: 157000, carried: 23400, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'NIS2', controlSet: 'Cyber Hygiene', control: 'Art. 21(2)(g)', check: 'Cyber hygiene practices and security training', passed: true, policyVersion: 'v2.1', ale: 5900, var95: 27000, tvar: 42000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── Cyber Resilience Act — Regulation (EU) 2024/2847 ───────────────────────
//
// Control IDs cite Annex I of the ADOPTED regulation. The lettering moved
// between the 2022 proposal and the adopted text — attack surfaces was (h) in
// the draft and is (j) in 2024/2847 — so these are deliberately taken from the
// adopted numbering and not from the widely-mirrored proposal.

const CRA_CHECKS: RawCheck[] = [
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(a)', check: 'Released without known exploitable vulnerabilities', passed: false, policyVersion: 'v2.0', ale: 33600, var95: 144000, tvar: 231000, carried: 33600, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(b)', check: 'Secure by default configuration', passed: true, policyVersion: 'v2.1', ale: 9700, var95: 44000, tvar: 69000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(d)', check: 'Unauthorised access controlled and reported', passed: true, policyVersion: 'v2.1', ale: 14600, var95: 67000, tvar: 103000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(e)', check: 'Data confidentiality protected in transit and at rest', passed: true, policyVersion: 'v2.1', ale: 11300, var95: 52000, tvar: 83000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(j)', check: 'Attack surface and external interfaces limited', passed: true, policyVersion: 'v2.1', ale: 10900, var95: 49000, tvar: 78000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Product Security Properties', control: 'Annex I Pt I(2)(l)', check: 'Security-relevant internal activity recorded', passed: true, policyVersion: 'v1.0', ale: 6800, var95: 29000, tvar: 45000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Vulnerability Handling', control: 'Annex I Pt II(1)', check: 'SBOM covering top-level dependencies published', passed: false, policyVersion: 'v2.0', ale: 28900, var95: 124000, tvar: 195000, carried: 28900, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Vulnerability Handling', control: 'Annex I Pt II(2)', check: 'Vulnerabilities remediated without delay', passed: true, policyVersion: 'v2.1', ale: 15400, var95: 71000, tvar: 110000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Vulnerability Handling', control: 'Annex I Pt II(5)', check: 'Coordinated vulnerability disclosure policy enforced', passed: true, policyVersion: 'v2.1', ale: 7100, var95: 32000, tvar: 50000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'Cyber Resilience Act', controlSet: 'Vulnerability Handling', control: 'Annex I Pt II(7)', check: 'Security updates distributed securely', passed: false, policyVersion: 'v2.0', ale: 21800, var95: 98000, tvar: 151000, carried: 21800, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

// ─── FINOS AI Governance Framework ──────────────────────────────────────────
//
// Control IDs and check text are the framework's own risk identifiers and
// titles, verbatim, from air-governance-framework.finos.org. AIR-SEC-024/025/
// 026/029 and AIR-OP-028 are the agentic risks added in v2.0 — they are the
// reason this framework is the one that most directly prices an agent estate.
//
// Note the ID-space collision with this file's EU AI Act rows, which use
// synthetic AIR-1/AIR-2/AIR-3 for "Risk Management". Those are NOT FINOS AIR
// identifiers and are not real EU AI Act citations either.

const FINOS_AIGF_CHECKS: RawCheck[] = [
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-002', check: 'Information Leaked to Vector Store', passed: true, policyVersion: 'v2.1', ale: 16200, var95: 70000, tvar: 109000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-010', check: 'Prompt Injection', passed: false, policyVersion: 'v2.0', ale: 38400, var95: 166000, tvar: 258000, carried: 38400, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-024', check: 'Agent Action Authorization Bypass', passed: false, policyVersion: 'v2.0', ale: 41500, var95: 192000, tvar: 297000, carried: 41500, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-025', check: 'Tool Chain Manipulation and Injection', passed: true, policyVersion: 'v2.1', ale: 17900, var95: 79000, tvar: 124000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-026', check: 'MCP Server Supply Chain Compromise', passed: false, policyVersion: 'v2.0', ale: 36200, var95: 157000, tvar: 242000, carried: 36200, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Security Risks', control: 'AIR-SEC-029', check: 'Agent-Mediated Credential Discovery and Harvesting', passed: true, policyVersion: 'v2.1', ale: 19300, var95: 86000, tvar: 134000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Operational Risks', control: 'AIR-OP-017', check: 'Lack of Explainability', passed: true, policyVersion: 'v1.0', ale: 6600, var95: 30000, tvar: 48000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Operational Risks', control: 'AIR-OP-019', check: 'Data Quality and Drift', passed: true, policyVersion: 'v2.1', ale: 8300, var95: 38000, tvar: 59000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Operational Risks', control: 'AIR-OP-028', check: 'Multi-Agent Trust Boundary Violations', passed: true, policyVersion: 'v2.1', ale: 14100, var95: 60000, tvar: 95000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
  { framework: 'FINOS AI Governance Framework', controlSet: 'AI Regulatory & Compliance Risks', control: 'AIR-RC-001', check: 'Information Leaked To Hosted Model', passed: true, policyVersion: 'v2.1', ale: 12600, var95: 55000, tvar: 88000, carried: 0, scanTimestamp: NOW, calibrationSource: CALIBRATION },
]

const ALL_CHECKS: ComplianceCheck[] = [
  ...EU_AI_ACT_CHECKS,
  ...NIST_CHECKS,
  ...DORA_CHECKS,
  ...NIS2_CHECKS,
  ...CRA_CHECKS,
  ...FINOS_AIGF_CHECKS,
].map(denominate)

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
  carried: noExposure(),
}))

// ─── Summaries ──────────────────────────────────────────────────────────────

/**
 * Stable id for a framework name — `EU AI Act` → `eu-ai-act`.
 *
 * Derived rather than hand-maintained. The two ids that existed before this
 * function (`eu-ai-act`, `nist-800-53`) are exactly what it produces, so no
 * consumer keyed on those strings changes behaviour.
 */
function frameworkId(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
}

function summariseFramework(
  id: string,
  name: string,
  checks: ComplianceCheck[],
  fallbackCurrency: CurrencyCode,
): FrameworkSummary {
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
    totalExposure:
      sumMoney(fwChecks.map((c) => c.carried), fallbackCurrency) ?? money(0, fallbackCurrency),
  }
}

function buildPostureSummary(checks: ComplianceCheck[]): PostureSummary {
  const passed = checks.filter((c) => c.passed).length
  // The document currency is READ from the rows, not asserted. It used to be
  // the DEMO_CURRENCY constant, which meant a document built from non-GBP
  // checks reported `currency: 'GBP'` while carrying figures in something else
  // — the precise mislabelling the ComplianceCheck header warns about, one org
  // file away from putting a wrong currency symbol in front of every figure on
  // screen. DEMO_CURRENCY remains the fallback for the two cases where the rows
  // cannot answer: an empty document, and a mixed-denomination one.
  const currencies = new Set(checks.map((c) => c.ale.currency))
  const documentCurrency: CurrencyCode =
    currencies.size === 1 ? [...currencies][0] : DEMO_CURRENCY
  return {
    totalChecks: checks.length,
    passed,
    failed: checks.length - passed,
    currency: documentCurrency,
    totalAle: sumMoney(checks.map((c) => c.ale), documentCurrency) ?? money(0, documentCurrency),
    totalVar95: sumMoney(checks.map((c) => c.var95), documentCurrency) ?? money(0, documentCurrency),
    totalTvar: sumMoney(checks.map((c) => c.tvar), documentCurrency) ?? money(0, documentCurrency),
    totalCarried: sumMoney(checks.map((c) => c.carried), documentCurrency) ?? money(0, documentCurrency),
    scanTimestamp: checks[0]?.scanTimestamp ?? NOW,
    // Derived from the checks, never a hand-maintained list. The previous
    // version named its two frameworks literally, which meant adding a
    // framework to ALL_CHECKS put its rows on the page while leaving it out of
    // `summary.frameworks` and out of the /compliance/policy/frameworks route —
    // a silent omission with nothing to catch it. Insertion order of the first
    // appearance is preserved, so the framework list reads in fixture order.
    frameworks: [...new Set(checks.map((c) => c.framework))].map((name) =>
      summariseFramework(frameworkId(name), name, checks, documentCurrency),
    ),
  }
}

const POSTURE_SUMMARY = buildPostureSummary(ALL_CHECKS)
const FRAMEWORK_LIST: FrameworkSummary[] = POSTURE_SUMMARY.frameworks

// ─── Scan by version (what-if) ──────────────────────────────────────────────

function checksForVersion(version: string): ComplianceCheck[] {
  if (version === 'v1.0') {
    return ALL_CHECKS.map((c) => ({ ...c, policyVersion: 'v1.0', passed: true, carried: noExposure() }))
  }
  if (version === 'v2.0') {
    return ALL_CHECKS // mix of pass/fail as defined
  }
  // v2.1 — tightest policy, fewer failures
  return ALL_CHECKS.map((c) => ({
    ...c,
    policyVersion: 'v2.1',
    passed: c.policyVersion === 'v2.1' ? c.passed : true,
    carried: c.policyVersion === 'v2.1' ? c.carried : noExposure(),
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
export { ALL_CHECKS, OLLY_CHECKS_V2, OLLY_CHECKS_V1, POSTURE_SUMMARY, FRAMEWORK_LIST, checksForVersion, DEMO_CURRENCY, buildPostureSummary }
