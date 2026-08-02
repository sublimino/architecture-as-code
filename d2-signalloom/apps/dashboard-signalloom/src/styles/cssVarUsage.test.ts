import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, extname } from 'node:path'
import { CSS_VAR_NAMES } from './themes'

// Regression guard for the class of bug fixed in DemoToggle (`var(--card,
// #1a1a1a)`): `--card` was referenced nowhere else, declared by no theme and
// no :root block, so its fallback silently won forever and the button
// rendered invisibly under Light. Any `var(--x)` reference whose `--x` isn't
// declared somewhere is the same trap waiting to fire — a colour that "looks
// fine" in whichever theme the author was staring at and is broken (or just
// permanently wrong) in the other two.
//
// Declared = the union of the theme-switched variables (CSS_VAR_NAMES, which
// every theme in themes.ts must supply per themes.test.ts) and the
// structural/motion variables declared once in global.css's :root block
// (--dim, --radius, --radius-sm, --motion-fast, etc. — real tokens that are
// intentionally NOT theme-switched, so they live in :root only).

const SRC_DIR = join(__dirname, '..')
const SCAN_EXTENSIONS = new Set(['.ts', '.tsx', '.css'])
const SKIP_DIRS = new Set(['node_modules', 'dist'])

function stripComments(source: string): string {
  // Block comments (CSS and TS/TSX) then line comments (TS/TSX only — this
  // codebase's CSS has no `//` inside string/url values, so stripping both
  // uniformly is safe and avoids maintaining two code paths).
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
}

function collectFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue
    const full = join(dir, entry)
    const info = statSync(full)
    if (info.isDirectory()) {
      collectFiles(full, out)
    } else if (SCAN_EXTENSIONS.has(extname(entry)) && !entry.endsWith('.test.ts') && !entry.endsWith('.test.tsx')) {
      out.push(full)
    }
  }
  return out
}

// Parses the `:root { ... }` block in global.css for every `--name:`
// declaration. Read from disk (not hand-copied) so this test tracks
// global.css automatically — themes.test.ts already guards that the Dark
// theme in themes.ts stays byte-for-byte identical to this block.
function declaredInGlobalCssRoot(): Set<string> {
  const css = stripComments(readFileSync(join(SRC_DIR, 'styles', 'global.css'), 'utf8'))
  const rootMatch = css.match(/:root\s*\{([\s\S]*?)\}/)
  if (!rootMatch) throw new Error('Could not find a :root block in global.css')
  const names = new Set<string>()
  for (const m of rootMatch[1].matchAll(/(--[a-zA-Z0-9-]+)\s*:/g)) {
    names.add(m[1])
  }
  return names
}

function usedVarNames(files: string[]): Map<string, string[]> {
  const usages = new Map<string, string[]>()
  for (const file of files) {
    const content = stripComments(readFileSync(file, 'utf8'))
    for (const m of content.matchAll(/var\(\s*(--[a-zA-Z0-9-]+)/g)) {
      const name = m[1]
      const list = usages.get(name) ?? []
      list.push(file)
      usages.set(name, list)
    }
  }
  return usages
}

describe('CSS custom property usage', () => {
  it('every var(--x) reference in src resolves to a declared token', () => {
    const declared = new Set<string>([...CSS_VAR_NAMES, ...declaredInGlobalCssRoot()])
    const files = collectFiles(SRC_DIR)
    const usages = usedVarNames(files)

    const undeclared = [...usages.keys()].filter((name) => !declared.has(name)).sort()

    if (undeclared.length > 0) {
      const detail = undeclared
        .map((name) => `  ${name} used in:\n${(usages.get(name) ?? []).map((f) => `    ${f}`).join('\n')}`)
        .join('\n')
      throw new Error(
        `Found var(--x) reference(s) to undeclared custom properties. Each of these silently falls ` +
          `back to its CSS default (or renders unset) in every theme — this is exactly the ` +
          `\`var(--card, #1a1a1a)\` bug DemoToggle shipped with, where the fallback always won and the ` +
          `button was invisible under Light. Declare the token in every theme (themes.ts) or in ` +
          `global.css's :root block, or stop referencing it.\n${detail}`,
      )
    }

    expect(undeclared).toEqual([])
  })

  it('sanity check: the scanner actually walks the components and pages directories', () => {
    const files = collectFiles(SRC_DIR)
    expect(files.some((f) => f.includes('/components/'))).toBe(true)
    expect(files.some((f) => f.includes('/pages/'))).toBe(true)
  })
})
