import { describe, expect, it } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

// Regression guard for the agent-metadata fabrication defect (163b1b60c):
// these exact strings were hardcoded as "owner"/"org_id"/"workspace_id"
// fallbacks in the backend and then echoed by the dashboard. None of them
// may ever appear in dashboard source again, with two narrow exceptions:
//
//   1. `src/api/fakeData.ts` -- the dashboard's demo-mode fixture data,
//      served only behind `isDemoMode()` / `isConnectorsMockMode()`.
//   2. `*.test.ts(x)` files -- test fixtures are free to use arbitrary
//      example values (including, in one pre-existing unrelated test,
//      these exact strings as mock input), and a couple of this repo's own
//      tests reference these strings specifically to assert their absence.
//      That is not the defect this guards against; the component-level
//      tests (DiscoveredWorkloadDrawer.test.tsx) are what prove the
//      rendering path itself never fabricates.
const FORBIDDEN_LITERALS = [
  '1f9b3065-9e10-42e5-b2ac-e8f37a186b88',
  'wrkspc_01PFJfZsJrq5bUVWA2wWnyvm',
  'Andrew Martin (User)',
  'osramp.acme.local',
]

const SRC_ROOT = join(__dirname, '..')
const EXCLUDED_FILES = new Set(['api/fakeData.ts'])

function collectSourceFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    const stat = statSync(full)
    if (stat.isDirectory()) {
      collectSourceFiles(full, out)
      continue
    }
    if (!/\.(ts|tsx)$/.test(entry)) continue
    if (/\.test\.(ts|tsx)$/.test(entry)) continue
    const rel = relative(SRC_ROOT, full)
    if (EXCLUDED_FILES.has(rel)) continue
    out.push(full)
  }
  return out
}

describe('no fabricated agent-metadata literals in dashboard source', () => {
  it('never reintroduces the hardcoded owner/org/workspace/trust-domain literals', () => {
    const offenders: string[] = []
    for (const file of collectSourceFiles(SRC_ROOT)) {
      const text = readFileSync(file, 'utf-8')
      for (const literal of FORBIDDEN_LITERALS) {
        if (text.includes(literal)) {
          offenders.push(`${relative(SRC_ROOT, file)}: ${JSON.stringify(literal)}`)
        }
      }
    }
    expect(offenders, `fabricated literal(s) found in dashboard source:\n  ${offenders.join('\n  ')}`).toEqual([])
  })
})
