import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, extname } from 'node:path'

// `.btn-sm` was used by 7+ call sites (SyncLogsModal, Settings,
// RemoteEnvironmentPage, IdpLinkageStep) as a "compact button" modifier and
// had no rule anywhere in global.css, so every one of those buttons silently
// rendered at full `.btn` size and each call site patched the gap with its
// own inline `fontSize`/`padding` pair (design-system audit, rule 5).
//
// Two things decide whether the fix actually landed: the class must exist
// with the shape call sites expect, and the inline duplicates it was
// standing in for must be gone — a class that exists but is never used
// unshadowed by an inline override is the same dead class with extra steps.

const CSS = readFileSync(join(__dirname, 'global.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
const SRC_DIR = join(__dirname, '..')
const SCAN_EXTENSIONS = new Set(['.tsx', '.ts'])
const SKIP_DIRS = new Set(['node_modules', 'dist'])

function collectFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue
    const full = join(dir, entry)
    const info = statSync(full)
    if (info.isDirectory()) collectFiles(full, out)
    else if (SCAN_EXTENSIONS.has(extname(entry)) && !entry.endsWith('.test.ts') && !entry.endsWith('.test.tsx')) {
      out.push(full)
    }
  }
  return out
}

describe('.btn-sm token', () => {
  it('is declared in global.css with a real padding and font-size', () => {
    const match = CSS.match(/\.btn-sm\s*\{([^}]*)\}/)
    expect(match, '.btn-sm must be declared in global.css').not.toBeNull()
    expect(match![1]).toMatch(/padding:\s*5px 12px/)
    expect(match![1]).toMatch(/font-size:\s*12px/)
  })

  it('has no call site that still pastes the fontSize/padding pair .btn-sm now supplies', () => {
    // The dead-class symptom: `className="... btn-sm"` paired with an inline
    // `style={{ fontSize: 12, padding: '5px 12px', ... }}` on the same
    // element. A real hit here means a call site is still duplicating what
    // the class now does, which is exactly the bug this rule fixes.
    const offences: string[] = []
    for (const file of collectFiles(SRC_DIR)) {
      const source = readFileSync(file, 'utf8')
      const lines = source.split('\n')
      for (let i = 0; i < lines.length; i += 1) {
        if (!/btn-sm/.test(lines[i])) continue
        // The className and its style={{...}} companion sit within a few
        // lines of each other at every known call site in this codebase.
        const window = lines.slice(i, i + 6).join('\n')
        if (/fontSize:\s*12/.test(window) && /padding:\s*['"]5px 12px['"]/.test(window)) {
          offences.push(`${file}:${i + 1}`)
        }
      }
    }
    expect(offences).toEqual([])
  })
})
