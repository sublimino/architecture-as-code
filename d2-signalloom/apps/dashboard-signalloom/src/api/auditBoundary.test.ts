import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { join, extname, dirname, resolve, relative } from 'node:path'
import { tmpdir } from 'node:os'
import { createRequire } from 'node:module'

// The TypeScript compiler is already a devDependency (it is what `bun run
// typecheck` runs); this borrows its parser rather than adding one. A regex
// sweep was the obvious cheaper option and is the wrong one here: the thing
// being detected is an *object literal in argument position*, which regexes
// cannot see the boundaries of, and a guard that mis-parses is a guard that
// goes quietly green.
//
// Required rather than imported: `typescript` is CommonJS, and an ESM default
// import of it resolves to a namespace object with no enum members under this
// toolchain — `ts.ScriptTarget` comes back undefined at runtime while still
// typechecking clean. The type side is a separate type-only import, which is
// erased and so cannot hit the same interop problem.
const ts = createRequire(join(__dirname, 'auditBoundary.test.ts'))(
  'typescript',
) as typeof import('typescript')
import type * as TS from 'typescript'

// Structural guard for the boundary Andy stated as: actions that require audit
// are persisted by the API that owns the action, never by the front-end. The
// browser's only legitimate relationship with the audit trail is *reading* it.
//
// This exists because the dashboard did the opposite twice. First in
// SuperCredInstructorPanel.tsx, where recordStunAudit() POSTed the audit event
// from the browser after a demo phase succeeded, with agent_name, namespace and
// reason as string literals in the TSX — so it would have written
// "compliance-failure: securityContext not set" whether or not that was the
// reason. Then, after that was deleted, the same pattern was found still live
// one file over in SuperCredPage.tsx, sending `reason` and `outcome` on the
// real operator path.
//
// Three failure modes, all reachable: the instructor closes the tab and no
// record exists; the token expires mid-demo (Dex runs storage: memory and
// regenerates signing keys on every `make public`, so a 401 there is routine)
// and the audit silently fails; or someone drives the action outside the UI and
// nothing is recorded. The cluster is mutated in every one of them.
//
// Deleting the two call sites fixes today. This stops tomorrow.

const SRC_DIR = join(__dirname, '..')
const SCAN_EXTENSIONS = new Set(['.ts', '.tsx'])
const SKIP_DIRS = new Set(['node_modules', 'dist'])

/**
 * Property names that assert *who did it, why, and what happened* — the claims
 * only the server is entitled to make, because only the server observed them.
 *
 * Deliberately excludes the locator fields (`agent_name`, `namespace`) and the
 * action's own inputs (`policyVersion`, `frameworks`, `subject`, `urgency`).
 * Naming which agent in which namespace to act on is the client's job; the
 * client saying what the outcome was is not. It also excludes `status` and
 * `result`, which are far too common in ordinary request bodies to carry the
 * meaning this guard is about.
 */
const NARRATIVE_KEYS = new Set([
  'actor',
  'performed_by',
  'principal',
  'reason',
  'justification',
  'outcome',
  'event_type',
  'event',
  'audit_event',
  'detail',
  'from_state',
  'to_state',
  'prior_state',
  'previous_state',
  'timestamp',
  'occurred_at',
  'recorded_at',
  'logged_at',
])

const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

/** `/audit`, `/api/audit`, `/audit/events.csv`, `/audit?page=1` — not `/audited-thing`. */
const AUDIT_PATH = /\/audit(\/|\?|$)/

export interface AuditBoundaryViolation {
  /** Path relative to the scanned root, so the message is the same on any machine. */
  file: string
  line: number
  kind: 'narrates-audit-event' | 'writes-to-audit-endpoint'
  detail: string
}

function collectFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) {
      collectFiles(full, out)
    } else if (SCAN_EXTENSIONS.has(extname(entry)) && !/\.test\.tsx?$/.test(entry)) {
      // Tests are excluded because a test cannot ship browser behaviour: the
      // fixtures in stunActivity.test.ts and demoActivity.test.ts construct
      // audit payloads precisely to prove the app does not.
      out.push(full)
    }
  }
  return out
}

/**
 * Which modules actually reach the network.
 *
 * Computed from the source, never listed. The equivalent guard on the backend
 * missed an entire module because its file list was written by hand, and the
 * list was correct on the day it was written. `fakeData.ts` and
 * `demoActivity.ts` fall out of this as non-transport on their own merits —
 * they construct audit events all day, but they are the demo-mode stand-in for
 * a backend that is not there, and they never send anything. That is a real
 * architectural distinction rather than an exemption, which is why it is
 * derived rather than declared.
 */
function classifyTransportModules(files: string[]): Map<string, boolean> {
  const transport = new Map<string, boolean>()
  for (const file of files) {
    const source = readFileSync(file, 'utf8')
    transport.set(file, /\bfetch\s*\(/.test(source) || /\baxios\b/.test(source))
  }
  return transport
}

function resolveRelativeImport(fromFile: string, spec: string): string | null {
  if (!spec.startsWith('.')) return null
  const base = resolve(dirname(fromFile), spec)
  for (const candidate of [base + '.ts', base + '.tsx', join(base, 'index.ts'), join(base, 'index.tsx')]) {
    try {
      if (statSync(candidate).isFile()) return candidate
    } catch {
      /* not this extension */
    }
  }
  return null
}

/** The identifier a call chain hangs off: `api.agents.stun(...)` -> `api`. */
function calleeRoot(expression: TS.Expression): string | null {
  let current: TS.Expression = expression
  while (
    ts.isPropertyAccessExpression(current) ||
    ts.isElementAccessExpression(current) ||
    ts.isCallExpression(current) ||
    ts.isNonNullExpression(current) ||
    ts.isParenthesizedExpression(current)
  ) {
    current = current.expression
  }
  return ts.isIdentifier(current) ? current.text : null
}

/** Every property name in an object literal, including nested ones. */
function propertyNames(node: TS.ObjectLiteralExpression, into = new Set<string>()): Set<string> {
  for (const prop of node.properties) {
    if (prop.name && (ts.isIdentifier(prop.name) || ts.isStringLiteral(prop.name))) {
      into.add(prop.name.text)
    }
    // Nested, so `{ method: 'POST', data: { reason } }` is not a blind spot.
    // A spread of a variable built elsewhere would still slip past — the AST
    // cannot see the shape of `{ ...payload }`. That is a known limit and an
    // accepted one: this guard is here to stop the pattern being written back
    // in by hand, not to survive someone determined to route around it.
    if (ts.isPropertyAssignment(prop)) {
      for (const nested of literalsWithin(prop.initializer)) propertyNames(nested, into)
    }
  }
  return into
}

/** Object literals reachable from an expression, unwrapping `JSON.stringify(...)`. */
function literalsWithin(expression: TS.Expression): TS.ObjectLiteralExpression[] {
  if (ts.isObjectLiteralExpression(expression)) return [expression]
  if (
    ts.isCallExpression(expression) &&
    ts.isPropertyAccessExpression(expression.expression) &&
    expression.expression.name.text === 'stringify'
  ) {
    return expression.arguments.flatMap(arg => literalsWithin(arg))
  }
  return []
}

/** The HTTP verb a request-config literal declares, if it declares one. */
function declaredMethod(literals: TS.ObjectLiteralExpression[]): string | null {
  for (const literal of literals) {
    for (const prop of literal.properties) {
      if (
        ts.isPropertyAssignment(prop) &&
        prop.name &&
        ts.isIdentifier(prop.name) &&
        prop.name.text === 'method' &&
        ts.isStringLiteralLike(prop.initializer)
      ) {
        return prop.initializer.text.toUpperCase()
      }
    }
  }
  return null
}

/**
 * Find every place the browser narrates or writes an audit event.
 *
 * `root` is a parameter rather than a constant so the positive-control test can
 * point it at a fixture tree. A guard nobody has watched fail is not a guard.
 */
export function findAuditBoundaryViolations(root: string): AuditBoundaryViolation[] {
  const files = collectFiles(root)
  const isTransport = classifyTransportModules(files)
  const violations: AuditBoundaryViolation[] = []

  for (const file of files) {
    const text = readFileSync(file, 'utf8')
    const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true)

    // Local names bound to something that reaches the network.
    const transportNames = new Set<string>(['fetch', 'axios'])
    source.forEachChild(node => {
      if (!ts.isImportDeclaration(node) || !ts.isStringLiteral(node.moduleSpecifier)) return
      const spec = node.moduleSpecifier.text
      const target = resolveRelativeImport(file, spec)
      const reachesNetwork = (target !== null && isTransport.get(target) === true) || spec === 'axios'
      if (!reachesNetwork) return
      const clause = node.importClause
      if (!clause) return
      if (clause.name) transportNames.add(clause.name.text)
      if (clause.namedBindings) {
        if (ts.isNamespaceImport(clause.namedBindings)) {
          transportNames.add(clause.namedBindings.name.text)
        } else {
          for (const element of clause.namedBindings.elements) transportNames.add(element.name.text)
        }
      }
    })

    // Inside a transport module, its own request helpers count too — `req` in
    // client.ts, `fleetFetch` in fleetApi.ts, `postJson` in demoRunner.ts. Only
    // functions whose body reaches the network qualify, which is what keeps
    // ordinary local calls (`setState`, `proofs.push`) out of scope.
    if (isTransport.get(file) === true) {
      source.forEachChild(node => {
        if (ts.isFunctionDeclaration(node) && node.name && node.body) {
          if (/\bfetch\s*\(|\baxios\b|\.request\s*\(/.test(node.body.getText(source))) {
            transportNames.add(node.name.text)
          }
        }
        if (ts.isVariableStatement(node)) {
          for (const decl of node.declarationList.declarations) {
            if (!ts.isIdentifier(decl.name) || !decl.initializer) continue
            if (!ts.isArrowFunction(decl.initializer) && !ts.isFunctionExpression(decl.initializer)) continue
            if (/\bfetch\s*\(|\baxios\b|\.request\s*\(/.test(decl.initializer.getText(source))) {
              transportNames.add(decl.name.text)
            }
          }
        }
      })
    }

    const relativePath = relative(root, file)
    const lineOf = (node: TS.Node) =>
      source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1

    const visit = (node: TS.Node): void => {
      if (ts.isCallExpression(node)) {
        const root_ = calleeRoot(node.expression)
        if (root_ !== null && transportNames.has(root_)) {
          const literals = node.arguments.flatMap(arg => literalsWithin(arg))

          for (const literal of literals) {
            const narrated = [...propertyNames(literal)].filter(name => NARRATIVE_KEYS.has(name)).sort()
            if (narrated.length > 0) {
              violations.push({
                file: relativePath,
                line: lineOf(literal),
                kind: 'narrates-audit-event',
                detail: `${node.expression.getText(source)} is sent ${narrated.join(', ')} — the server records what it observed, not what the browser claims`,
              })
            }
          }

          // Writing to the audit trail directly, whatever the body looks like.
          const method = declaredMethod(literals)
          if (method !== null && MUTATING_METHODS.has(method)) {
            for (const arg of node.arguments) {
              // `.text` rather than `.getText()`: the source text carries the
              // surrounding quotes, so `'/api/audit'` would never match a
              // pattern anchored on the end of the path. A template's `.text`
              // covers only its first chunk, which is where a path prefix
              // lives — `\`/api/audit/${id}\`` matches on `/api/audit/`.
              const path = ts.isStringLiteralLike(arg)
                ? arg.text
                : ts.isTemplateExpression(arg)
                  ? arg.head.text
                  : null
              if (path === null || !AUDIT_PATH.test(path)) continue
              violations.push({
                file: relativePath,
                line: lineOf(arg),
                kind: 'writes-to-audit-endpoint',
                detail: `${method} ${path} — the audit trail is read-only to the browser`,
              })
            }
          }
        }
      }
      node.forEachChild(visit)
    }
    visit(source)
  }

  return violations.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line)
}

describe('audit boundary — the dashboard never writes or narrates an audit event', () => {
  it('finds no front-end audit narration anywhere in src', () => {
    // Asserted against the resolved value, not against a non-zero exit or an
    // inequality with a known-bad string: the failure message has to name the
    // file and the fields, and an empty array has to be the only thing that
    // passes.
    expect(findAuditBoundaryViolations(SRC_DIR)).toEqual([])
  })

  it('scans a plausible share of the tree, so an empty result means something', () => {
    // The way this guard dies silently is the walk returning nothing — a
    // renamed directory, a thrown statSync, an extension that stopped
    // matching. Then `toEqual([])` above passes forever while covering zero
    // files. This is the tripwire for that.
    const files = collectFiles(SRC_DIR)
    expect(files.length).toBeGreaterThan(100)
    const transport = [...classifyTransportModules(files)].filter(([, yes]) => yes)
    expect(transport.length).toBeGreaterThan(5)
  })

  describe('positive control', () => {
    // Proof the detector detects. Both historical shapes are reconstructed
    // here: the deleted recordStunAudit() verbatim (a bare fetch to the stun
    // endpoint carrying reason and outcome), and the indirect form found live
    // in SuperCredPage.tsx (the same narrative handed to the API client).
    const withFixtureTree = (files: Record<string, string>): AuditBoundaryViolation[] => {
      const dir = mkdtempSync(join(tmpdir(), 'audit-boundary-'))
      try {
        for (const [name, content] of Object.entries(files)) {
          writeFileSync(join(dir, name), content)
        }
        return findAuditBoundaryViolations(dir)
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    }

    const apiClientModule = `
      import axios from 'axios'
      const http = axios.create({ baseURL: '' })
      export const api = {
        agents: {
          stun: (token: string, id: string, body: unknown) =>
            http.request({ url: '/api/agents/' + id + '/stun', method: 'POST', data: body }),
        },
      }
    `

    it('catches the deleted recordStunAudit() if it is written back in', () => {
      const violations = withFixtureTree({
        'Panel.tsx': `
          export async function recordStunAudit(token: string): Promise<void> {
            const response = await fetch('/api/agents/agent-cardvault/stun', {
              method: 'POST',
              headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
              body: JSON.stringify({
                agent_name: 'Cardvault Agent',
                namespace: 'fe-signalloom-agents',
                reason: 'compliance-failure: securityContext not set',
                outcome: 'stunned',
              }),
            })
            if (!response.ok) throw new Error('audit endpoint returned HTTP ' + response.status)
          }
        `,
      })

      expect(violations).toHaveLength(1)
      expect(violations[0].file).toBe('Panel.tsx')
      expect(violations[0].kind).toBe('narrates-audit-event')
      expect(violations[0].detail).toContain('outcome, reason')
    })

    it('catches the narrative when it is handed to the API client instead', () => {
      const violations = withFixtureTree({
        'client.ts': apiClientModule,
        'Page.tsx': `
          import { api } from './client'
          export async function stun(token: string, id: string, message: string) {
            await api.agents.stun(token, id, {
              agent_name: 'Cardvault Agent',
              namespace: 'fe-signalloom',
              reason: message,
              outcome: 'stunned',
            })
          }
        `,
      })

      expect(violations.map(v => `${v.file}:${v.kind}`)).toEqual(['Page.tsx:narrates-audit-event'])
      expect(violations[0].detail).toContain('outcome, reason')
    })

    it('catches a POST to the audit endpoint even with an innocent body', () => {
      const violations = withFixtureTree({
        'Writer.ts': `
          export async function write(note: string) {
            await fetch('/api/audit', { method: 'POST', body: JSON.stringify({ note }) })
          }
        `,
      })

      expect(violations.map(v => `${v.file}:${v.kind}`)).toEqual(['Writer.ts:writes-to-audit-endpoint'])
    })

    it('leaves reading the audit trail, and ordinary request bodies, alone', () => {
      const violations = withFixtureTree({
        'client.ts': apiClientModule,
        'Reader.ts': `
          export async function read() {
            await fetch('/api/audit?page=1')
            await fetch('/api/audit/events.csv?from=x')
          }
        `,
        'Scan.tsx': `
          import { api } from './client'
          export async function scan(token: string, id: string) {
            // Naming what to act on is the client's job; claiming what happened is not.
            await api.agents.stun(token, id, { agent_name: 'Cardvault Agent', namespace: 'fe-signalloom' })
          }
        `,
      })

      expect(violations).toEqual([])
    })
  })
})
