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
  // W22: demo discovery fixtures seen on the live estate. They belong only in
  // fakeData.ts; anything else that needs them references the fixture.
  'Customer Support Triage Assistant',
  '12450',
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

  // The literal scan above cannot see the path W22 took: fakeData.ts itself was
  // served on the live estate, because the cluster image was built without
  // VITE_SL_ENV and demoMode.ts falls back to 'demo', so a browser with no
  // stored preference started in demo mode. Pin the build to a tier whose
  // default is live.
  it('builds the cluster image with an environment tier that defaults to live data', () => {
    const dockerfile = readFileSync(join(SRC_ROOT, '..', 'Dockerfile'), 'utf-8')
    const tier = dockerfile.match(/^ARG VITE_SL_ENV=(\S+)\s*$/m)?.[1]
    expect(tier, 'Dockerfile must declare ARG VITE_SL_ENV=<tier>').toBeDefined()
    expect(tier, 'the demo tier defaults every fresh browser to fixtures').not.toBe('demo')
    expect(dockerfile, 'the ARG must reach vite build').toMatch(/^RUN VITE_SL_ENV="\$VITE_SL_ENV" npx vite build$/m)
  })
})
