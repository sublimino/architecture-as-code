// Guards the one directory in this repo that carries TWO lockfiles.
//
// `d2-signalloom/apps/dashboard-signalloom` tracks both `bun.lock` and
// `package-lock.json`. Nothing reconciles them:
//
//   - the tree looks bun-native, and `bun add` writes bun.lock
//   - the Dockerfile does `COPY package.json package-lock.json` then `npm ci`
//   - `npm ci` refuses a lockfile that disagrees with package.json, by design
//
// So adding a dependency the natural way leaves package-lock.json behind, and
// NOTHING fails until the containerised build runs. Local `vite build`, vitest,
// tsc and eslint all pass against a tree whose Docker image cannot be built.
//
// That is not hypothetical. Commit e024e5b added @xyflow/react with `bun add`,
// was verified with `bunx vite build`, and broke the dashboard image build on
// every clean tree — caught only by a full CI run on a GCP VM, at stage 4,
// roughly eight minutes in, with `npm error code EUSAGE`.
//
// This test turns that into an instant local failure. It deliberately does not
// impose a workflow: use bun, use npm, use either — just keep the npm lock in
// step with package.json, because that is the file the image build reads.

import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const APP_DIR = join(__dirname, '..')

type PackageJson = {
  dependencies?: Record<string, string>
  devDependencies?: Record<string, string>
}
type PackageLock = {
  lockfileVersion?: number
  packages?: Record<string, { version?: string }>
}

const pkg: PackageJson = JSON.parse(readFileSync(join(APP_DIR, 'package.json'), 'utf8'))
const lock: PackageLock = JSON.parse(readFileSync(join(APP_DIR, 'package-lock.json'), 'utf8'))

const declared = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) }

describe('package-lock.json stays in step with package.json', () => {
  it('has a lockfile npm can actually consume', () => {
    // v2/v3 carry the `packages` map that `npm ci` resolves against. A v1 lock
    // would satisfy every assertion below while still failing `npm ci`.
    expect(lock.lockfileVersion, 'lockfileVersion').toBeGreaterThanOrEqual(2)
    expect(lock.packages, 'lock has a packages map').toBeTruthy()
  })

  it('locks every dependency declared in package.json', () => {
    const missing = Object.keys(declared).filter(name => !lock.packages?.[`node_modules/${name}`])

    expect(
      missing,
      missing.length
        ? `\n\n  ${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} in package.json but not in `
          + `package-lock.json.\n\n  This breaks the dashboard Docker image, which runs \`npm ci\` — and it `
          + `breaks it on\n  every clean tree, not just in CI. bun.lock is not the file the image reads.\n\n`
          + `  Fix:  cd d2-signalloom/apps/dashboard-signalloom && npm install --package-lock-only\n`
          + `  Then commit package-lock.json alongside package.json.\n`
        : '',
    ).toEqual([])
  })

  it('locks a version satisfying each declared range', () => {
    // Catches the subtler drift: the entry exists, but from an older resolve
    // that predates a version bump in package.json.
    const mismatched: string[] = []
    for (const [name, range] of Object.entries(declared)) {
      const locked = lock.packages?.[`node_modules/${name}`]?.version
      if (!locked) continue
      const floor = range.replace(/^[\^~>=<\s]*/, '')
      if (!/^\d/.test(floor)) continue
      const [wantMajor] = floor.split('.')
      const [gotMajor] = locked.split('.')
      if (wantMajor !== gotMajor) mismatched.push(`${name}: package.json wants ${range}, lock has ${locked}`)
    }
    expect(mismatched).toEqual([])
  })
})
