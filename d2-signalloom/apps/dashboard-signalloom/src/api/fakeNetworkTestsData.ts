// Fake network-tests (netassert) fixtures for demo mode.
//
// Separated from fakeData.ts for the same reason as fakeComplianceData.ts —
// keeps the main fixture file from growing unbounded. Test definitions mirror
// d2-signalloom/test/netassert-signalloom.yaml and server.py's
// NETWORK_TEST_DEFINITIONS 1:1.
//
// Demo mode simulates a real scan's timing rather than flipping instantly:
// POST /network-tests/scan puts every test into 'running' and schedules a
// return to 'complete' ~1.4s later, so the Scan Now button's in-progress
// state is genuinely exercised offline, not just in the live path.

import type { NetworkTestListResponse, NetworkTestResult, NetworkTestScanResponse } from '../types/api'

const BASE_LAST_RUN = '2026-08-01T10:20:52Z'
const SCAN_DURATION_MS = 1400

type Definition = Omit<NetworkTestResult, 'result' | 'evidence' | 'lastRun'>

const DEFINITIONS: Definition[] = [
  { name: 'dashboard-to-api-allowed', expectedExit: 0, targetPort: 8000,
    src: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    dst: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    description: 'Dashboard to API backend (nginx /api proxy)' },
  { name: 'dashboard-to-dex-allowed', expectedExit: 0, targetPort: 5556,
    src: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'dex' },
    description: 'Dashboard to Dex (OIDC discovery/auth/token)' },
  { name: 'api-to-postgresql-allowed', expectedExit: 0, targetPort: 5432,
    src: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'postgresql' },
    description: 'API to PostgreSQL (persistence)' },
  { name: 'api-to-redis-allowed', expectedExit: 0, targetPort: 6379,
    src: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'redis' },
    description: 'API to Redis (cache)' },
  { name: 'api-to-minio-allowed', expectedExit: 0, targetPort: 9000,
    src: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'minio' },
    description: 'API to MinIO (report storage)' },
  { name: 'agents-to-api-denied', expectedExit: 1, targetPort: 8000,
    src: { namespace: 'fe-signalloom-agents', name: 'agent-patsy' },
    dst: { namespace: 'fe-signalloom', name: 'fe-signalloom' },
    description: 'Agent pods MUST NOT reach the API backend directly' },
  { name: 'agents-to-dashboard-denied', expectedExit: 1, targetPort: 8080,
    src: { namespace: 'fe-signalloom-agents', name: 'agent-patsy' },
    dst: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    description: 'Agent pods MUST NOT reach the dashboard' },
  { name: 'agents-to-postgresql-denied', expectedExit: 1, targetPort: 5432,
    src: { namespace: 'fe-signalloom-agents', name: 'agent-patsy' },
    dst: { namespace: 'inf-signalloom', name: 'postgresql' },
    description: 'Agent pods MUST NOT reach PostgreSQL directly' },
  { name: 'dashboard-to-postgresql-denied', expectedExit: 1, targetPort: 5432,
    src: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'postgresql' },
    description: 'Dashboard MUST NOT reach PostgreSQL directly (only via API)' },
  { name: 'dashboard-to-redis-denied', expectedExit: 1, targetPort: 6379,
    src: { namespace: 'fe-signalloom', name: 'dashboard-signalloom' },
    dst: { namespace: 'inf-signalloom', name: 'redis' },
    description: 'Dashboard MUST NOT reach Redis directly' },
]

let scanning = false
let lastRun = BASE_LAST_RUN
let scanTimer: ReturnType<typeof setTimeout> | undefined

export function networkTestsFixture(): NetworkTestListResponse {
  return {
    tests: DEFINITIONS.map((d) => ({
      ...d,
      result: scanning ? 'running' : 'pass',
      evidence: scanning ? 'scan in progress (demo)' : `netassert TAP: ok - ${d.name}`,
      lastRun,
    })),
    scanStatus: scanning ? 'running' : 'complete',
  }
}

export function networkTestsScanFixture(): NetworkTestScanResponse {
  scanning = true
  if (scanTimer) clearTimeout(scanTimer)
  scanTimer = setTimeout(() => {
    scanning = false
    lastRun = new Date().toISOString()
  }, SCAN_DURATION_MS)
  return { job: 'netassert-run-demo', status: 'started' }
}

/** Test-only: reset module state between vitest runs. */
export function _resetNetworkTestsFixtureForTests(): void {
  scanning = false
  lastRun = BASE_LAST_RUN
  if (scanTimer) clearTimeout(scanTimer)
  scanTimer = undefined
}
