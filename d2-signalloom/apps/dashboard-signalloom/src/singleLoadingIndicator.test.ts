import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, extname, relative } from 'node:path'

// One loading indicator in the product: the Signal Loom mark (PixelLoader,
// reached directly or through LoadingState). Everything else is drift.
//
// This is a source scan rather than a render assertion on purpose. The bug it
// fences off was never a broken component — App and OnboardingWizard each had
// a perfectly working private `Spinner`, and the damage was that there were
// two of them and neither was the brand. A render test only ever covers the
// surfaces someone remembered to write a test for; the next private copy will
// be in the file nobody thought to check. Grepping the tree catches it wherever
// it lands, which is the only way this stays fixed.
//
// If this test fails on a file you are writing: you want PixelLoader (single
// phase — a Suspense fallback, a gate) or LoadingState (a surface that can
// also succeed or fail in place). Both are in src/components.

const SRC_DIR = __dirname
const SCAN_EXTENSIONS = new Set(['.ts', '.tsx', '.css'])
const SKIP_DIRS = new Set(['node_modules', 'dist'])

/**
 * Markers of a hand-rolled rotating ring. Deliberately narrow: each one is
 * something a spinner does and almost nothing else does, so a hit is a real
 * finding and not a style this happens to dislike. `borderTopColor` is
 * absent for exactly that reason — a coloured top border is ordinary.
 */
const FORBIDDEN: { pattern: RegExp; what: string }[] = [
  { pattern: /rotate\(\s*360deg\s*\)/, what: 'a full-turn rotation (rotating ring)' },
  { pattern: /rotate\(\s*1turn\s*\)/, what: 'a full-turn rotation (rotating ring)' },
  { pattern: /@keyframes\s+[\w-]*spin/i, what: 'a spin keyframe' },
  { pattern: /loading-spinner|loading-spin\b/, what: 'the retired loading-spinner class' },
]

// Tests are excluded, same as cssVarUsage.test.ts does: the suites that assert
// the ring is gone have to name the ring to look for it, and a guard that
// trips on its own evidence is no guard at all. Only shipped source is scanned.
function collectFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) collectFiles(full, out)
    else if (
      SCAN_EXTENSIONS.has(extname(entry)) &&
      !entry.endsWith('.test.ts') &&
      !entry.endsWith('.test.tsx')
    ) {
      out.push(full)
    }
  }
  return out
}

describe('one loading indicator', () => {
  it('has no hand-rolled rotating spinner anywhere in src', () => {
    const offences: string[] = []
    for (const file of collectFiles(SRC_DIR)) {
      const source = readFileSync(file, 'utf8')
      for (const { pattern, what } of FORBIDDEN) {
        const line = source.split('\n').findIndex((l) => pattern.test(l))
        if (line !== -1) offences.push(`${relative(SRC_DIR, file)}:${line + 1} — ${what}`)
      }
    }
    expect(offences).toEqual([])
  })
})
