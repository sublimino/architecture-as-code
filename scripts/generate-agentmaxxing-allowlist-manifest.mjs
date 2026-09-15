#!/usr/bin/env node
/**
 * @file generate-agentmaxxing-allowlist-manifest.mjs
 * @description Build-time script to extract allowlist sets and SHA-256 content digest
 * from d2-signalloom/apps/agentmaxxing-host-sensor/filter.py into a committed JSON manifest.
 *
 * Usage:
 *   node scripts/generate-agentmaxxing-allowlist-manifest.mjs           # Generate/update manifest
 *   node scripts/generate-agentmaxxing-allowlist-manifest.mjs --check   # CI staleness check (exit 0 fresh, exit 1 stale)
 *   node scripts/generate-agentmaxxing-allowlist-manifest.mjs --help    # Show usage
 *
 * Exit Codes:
 *   0 - Success / Fresh (matches filter.py)
 *   1 - Stale / Drift detected (--check mode)
 *   2 - Execution error (missing dependencies, missing source files, invalid arguments)
 */

import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// Resolve repository root relative to script location
const REPO_ROOT = path.resolve(__dirname, '..')
const FILTER_PY_PATH = path.join(
  REPO_ROOT,
  'd2-signalloom',
  'apps',
  'agentmaxxing-host-sensor',
  'filter.py'
)
const MANIFEST_OUTPUT_PATH = path.join(
  REPO_ROOT,
  'd2-signalloom',
  'apps',
  'dashboard-signalloom',
  'src',
  'data',
  'agentmaxxing-allowlist-manifest.json'
)

/**
 * Check python3 availability.
 * Fails with exit code 2 if python3 is not found.
 */
function verifyPython3Available() {
  try {
    const versionBuf = execFileSync('python3', ['--version'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      encoding: 'utf-8',
    })
    return versionBuf.trim()
  } catch (err) {
    console.error(
      '[allowlist-manifest] FATAL: Python 3 interpreter (python3) is required to introspect filter.py allowlists but was not found in PATH.'
    )
    console.error(`[allowlist-manifest] Error details: ${err.message}`)
    process.exit(2)
  }
}

/**
 * Compute SHA-256 of filter.py content.
 */
function computeFilterSha256(filePath) {
  if (!fs.existsSync(filePath)) {
    console.error(`[allowlist-manifest] FATAL: filter.py source not found at: ${filePath}`)
    process.exit(2)
  }
  const fileBytes = fs.readFileSync(filePath)
  return crypto.createHash('sha256').update(fileBytes).digest('hex')
}

/**
 * Introspect filter.py using Python to extract exact allowlist sets.
 */
function extractAllowlistsFromPython(filterPyPath) {
  const sensorDir = path.dirname(filterPyPath)
  const pythonScript = `
import sys, json
from pathlib import Path

sensor_dir = Path(${JSON.stringify(sensorDir)}).resolve()
if str(sensor_dir) not in sys.path:
    sys.path.insert(0, str(sensor_dir))

try:
    import filter as f
except Exception as e:
    sys.stderr.write(f"Failed to import filter module: {e}\\n")
    sys.exit(2)

manifest_data = {
    "allowlisted_process_attributes": sorted(list(f.ALLOWLISTED_PROCESS_ATTRIBUTES)),
    "extended_process_attributes": sorted(list(f.EXTENDED_PROCESS_ATTRIBUTES)),
    "allowlisted_envelope_fields": sorted(list(f.ALLOWLISTED_ENVELOPE_FIELDS)),
    "allowlisted_coding_agent_envelope_fields": sorted(list(f.ALLOWLISTED_CODING_AGENT_ENVELOPE_FIELDS)),
    "allowlisted_coding_agent_process_fields": sorted(list(f.ALLOWLISTED_CODING_AGENT_PROCESS_FIELDS)),
    "allowlisted_coding_agent_kanban_fields": sorted(list(f.ALLOWLISTED_CODING_AGENT_KANBAN_FIELDS)),
    "allowlisted_coding_agent_metrics_fields": sorted(list(f.ALLOWLISTED_CODING_AGENT_METRICS_FIELDS)),
    "allowlisted_coding_agent_network_fields": sorted(list(f.ALLOWLISTED_CODING_AGENT_NETWORK_FIELDS)),
    "prohibited_export_keys": sorted(list(f.PROHIBITED_EXPORT_KEYS)),
}
sys.stdout.write(json.dumps(manifest_data))
`

  try {
    const stdout = execFileSync('python3', ['-c', pythonScript], {
      stdio: ['pipe', 'pipe', 'pipe'],
      encoding: 'utf-8',
    })
    return JSON.parse(stdout.trim())
  } catch (err) {
    console.error('[allowlist-manifest] FATAL: Python introspection of filter.py failed.')
    if (err.stderr) console.error(`[allowlist-manifest] stderr: ${err.stderr}`)
    process.exit(2)
  }
}

/**
 * Generate complete manifest data object.
 */
function buildManifest() {
  const pyVersion = verifyPython3Available()
  const filterSha256 = computeFilterSha256(FILTER_PY_PATH)
  const extracted = extractAllowlistsFromPython(FILTER_PY_PATH)

  // Relative path for deterministic reproducibility across checkouts
  const relSourcePath = path.relative(REPO_ROOT, FILTER_PY_PATH)

  return {
    schema_version: '1.0.0',
    source_file: relSourcePath,
    filter_sha256: filterSha256,
    python_extractor: pyVersion,
    allowlisted_process_attributes: extracted.allowlisted_process_attributes,
    extended_process_attributes: extracted.extended_process_attributes,
    allowlisted_envelope_fields: extracted.allowlisted_envelope_fields,
    allowlisted_coding_agent_envelope_fields: extracted.allowlisted_coding_agent_envelope_fields,
    allowlisted_coding_agent_process_fields: extracted.allowlisted_coding_agent_process_fields,
    allowlisted_coding_agent_kanban_fields: extracted.allowlisted_coding_agent_kanban_fields,
    allowlisted_coding_agent_metrics_fields: extracted.allowlisted_coding_agent_metrics_fields,
    allowlisted_coding_agent_network_fields: extracted.allowlisted_coding_agent_network_fields,
    prohibited_export_keys: extracted.prohibited_export_keys,
  }
}

/**
 * Compare two sets/arrays for equality.
 */
function areArraysEqual(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return false
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}

/**
 * Perform CI freshness check.
 */
function checkManifest() {
  if (!fs.existsSync(MANIFEST_OUTPUT_PATH)) {
    console.error(
      `[allowlist-manifest] ERROR: Manifest does not exist at ${MANIFEST_OUTPUT_PATH}.\nRun 'node scripts/generate-agentmaxxing-allowlist-manifest.mjs' to create it.`
    )
    process.exit(1)
  }

  let existing
  try {
    const raw = fs.readFileSync(MANIFEST_OUTPUT_PATH, 'utf-8')
    existing = JSON.parse(raw)
  } catch (err) {
    console.error(
      `[allowlist-manifest] ERROR: Manifest at ${MANIFEST_OUTPUT_PATH} is malformed: ${err.message}`
    )
    process.exit(1)
  }

  const current = buildManifest()

  const digestsMatch = existing.filter_sha256 === current.filter_sha256
  const processMatch = areArraysEqual(
    existing.allowlisted_process_attributes,
    current.allowlisted_process_attributes
  )
  const envelopeMatch = areArraysEqual(
    existing.allowlisted_envelope_fields,
    current.allowlisted_envelope_fields
  )
  const prohibitedMatch = areArraysEqual(
    existing.prohibited_export_keys,
    current.prohibited_export_keys
  )

  if (!digestsMatch || !processMatch || !envelopeMatch || !prohibitedMatch) {
    console.error('[allowlist-manifest] ERROR: Manifest is STALE relative to filter.py.')
    if (!digestsMatch) {
      console.error(`  - filter.py SHA-256 current:  ${current.filter_sha256}`)
      console.error(`  - Manifest filter_sha256:     ${existing.filter_sha256}`)
    }
    if (!processMatch) {
      console.error('  - ALLOWLISTED_PROCESS_ATTRIBUTES set changed')
    }
    if (!envelopeMatch) {
      console.error('  - ALLOWLISTED_ENVELOPE_FIELDS set changed')
    }
    if (!prohibitedMatch) {
      console.error('  - PROHIBITED_EXPORT_KEYS set changed')
    }
    console.error(
      "\nRemediation: Run 'node scripts/generate-agentmaxxing-allowlist-manifest.mjs' to regenerate."
    )
    process.exit(1)
  }

  console.log(
    `[allowlist-manifest] OK: Manifest is FRESH and matches filter.py (SHA-256: ${current.filter_sha256})`
  )
  process.exit(0)
}

/**
 * Generate and write manifest to disk.
 */
function writeManifest() {
  const manifest = buildManifest()
  const outDir = path.dirname(MANIFEST_OUTPUT_PATH)
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true })
  }

  const formatted = JSON.stringify(manifest, null, 2) + '\n'
  fs.writeFileSync(MANIFEST_OUTPUT_PATH, formatted, 'utf-8')

  console.log(
    `[allowlist-manifest] Successfully generated allowlist manifest:`
  )
  console.log(`  - Target:       ${MANIFEST_OUTPUT_PATH}`)
  console.log(`  - Source:       ${manifest.source_file}`)
  console.log(`  - SHA-256:      ${manifest.filter_sha256}`)
  console.log(`  - Process Keys: ${manifest.allowlisted_process_attributes.length}`)
  console.log(`  - Envelope Keys:${manifest.allowlisted_envelope_fields.length}`)
  console.log(`  - Prohibited:   ${manifest.prohibited_export_keys.length}`)
  process.exit(0)
}

function printUsage() {
  console.log(`Usage: node scripts/generate-agentmaxxing-allowlist-manifest.mjs [options]

Options:
  --check       Validate that the on-disk manifest matches current filter.py (exits 0 on match, 1 on drift)
  --generate    Generate and write the manifest to disk (default)
  --help, -h    Show this help message
`)
  process.exit(0)
}

function main() {
  const args = process.argv.slice(2)
  if (args.includes('--help') || args.includes('-h')) {
    printUsage()
  } else if (args.includes('--check')) {
    checkManifest()
  } else if (args.length === 0 || args.includes('--generate')) {
    writeManifest()
  } else {
    console.error(`[allowlist-manifest] Unknown option: ${args.join(' ')}`)
    printUsage()
  }
}

main()
