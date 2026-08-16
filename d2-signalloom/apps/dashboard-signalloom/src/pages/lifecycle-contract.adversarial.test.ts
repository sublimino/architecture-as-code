/**
 * Adversarial tests: lifecycle state contract between dashboard and API.
 *
 * The dashboard's VALID_NEXT_STATES map and the API's VALID_LIFECYCLE_STATES
 * must agree on the vocabulary. A state the API produces but the dashboard
 * doesn't know about shows no transition options (the user is stuck). A state
 * the dashboard offers but the API doesn't recognise gets a 400.
 *
 * These tests parse the source files directly because the contract is between
 * two separately-deployed components — runtime testing would require both
 * running, while static analysis catches the drift at build time.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'node:fs'
import * as path from 'node:path'

// ─── Extract VALID_NEXT_STATES keys from AgentDetailPage.tsx ──────────────────

function extractValidNextStatesKeys(): string[] {
  const filePath = path.resolve(__dirname, 'AgentDetailPage.tsx')
  const source = fs.readFileSync(filePath, 'utf-8')

  // Find the VALID_NEXT_STATES block
  const match = source.match(/const VALID_NEXT_STATES[^=]*=\s*\{([\s\S]*?)\n\}/)
  if (!match) throw new Error('Could not find VALID_NEXT_STATES in AgentDetailPage.tsx')

  // Extract the keys (state names) — they appear as bare identifiers or quoted strings
  // at the start of lines like: `  registered: [...]`
  const keys: string[] = []
  const block = match[1]
  for (const line of block.split('\n')) {
    const keyMatch = line.match(/^\s+['"]?(\w+)['"]?\s*:/)
    if (keyMatch) keys.push(keyMatch[1])
  }
  return keys
}

// ─── The canonical lifecycle vocabulary (from api_compat.py) ──────────────────

// These are the states the API's VALID_LIFECYCLE_STATES frozenset permits.
// Must stay in step with api_compat.py and migration 009_agent_lifecycle_states.sql.
const API_VALID_LIFECYCLE_STATES = new Set([
  'registered',
  'enrolled',
  'active',
  'suspended',
  'revoked',
  'decommissioned',
])

// ─── Extract lifecycle_state values from fakeData.ts ──────────────────────────

function extractFakeDataLifecycleStates(): string[] {
  const filePath = path.resolve(__dirname, '..', 'api', 'fakeData.ts')
  const source = fs.readFileSync(filePath, 'utf-8')

  const states: string[] = []
  const regex = /lifecycle_state:\s*['"](\w+)['"]/g
  let m
  while ((m = regex.exec(source)) !== null) {
    states.push(m[1])
  }
  return [...new Set(states)]
}

describe('Lifecycle state contract: dashboard <-> API', () => {
  const dashboardStates = extractValidNextStatesKeys()

  it('VALID_NEXT_STATES covers every API lifecycle state', () => {
    // Every state the API can produce must have an entry in the dashboard's
    // transition map, even if it's an empty array (terminal states).
    const missing = [...API_VALID_LIFECYCLE_STATES].filter(s => !dashboardStates.includes(s))
    expect(missing).toEqual([])
  })

  it('VALID_NEXT_STATES contains only valid API lifecycle states', () => {
    // Every state the dashboard knows about must be a state the API recognises.
    // A dashboard key the API doesn't know about would silently show transitions
    // that the API would reject with 400.
    const invalid = dashboardStates.filter(s => !API_VALID_LIFECYCLE_STATES.has(s))
    expect(invalid).toEqual([])
  })

  it('registered state has transition options', () => {
    // The API creates agents in "registered" state (POST /api/agents, _synth_agent).
    // Without an entry in VALID_NEXT_STATES, registered agents show no transition
    // buttons and the user is stuck.
    expect(dashboardStates).toContain('registered')
  })

  it('terminal states have empty transition arrays', () => {
    // Both terminal states must be present but with empty arrays.
    const filePath = path.resolve(__dirname, 'AgentDetailPage.tsx')
    const source = fs.readFileSync(filePath, 'utf-8')

    // Extract the full VALID_NEXT_STATES block
    const match = source.match(/const VALID_NEXT_STATES[^=]*=\s*(\{[\s\S]*?\n\})/)
    expect(match).not.toBeNull()

    const block = match![1]
    // Verify revoked and decommissioned have empty arrays
    expect(block).toMatch(/revoked:\s*\[\]/)
    expect(block).toMatch(/decommissioned:\s*\[\]/)
  })
})

describe('Lifecycle state contract: fakeData <-> API', () => {
  const fakeDataStates = extractFakeDataLifecycleStates()

  it('all fakeData lifecycle_state values are valid API states', () => {
    // fakeData creates agents with lifecycle_state values. If any of them
    // are not in the API's vocabulary, the demo mode produces agents that
    // the transition validation would reject.
    const invalid = fakeDataStates.filter(s => !API_VALID_LIFECYCLE_STATES.has(s))
    expect(invalid).toEqual([])
  })
})
