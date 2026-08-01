/**
 * Tests for the AFM import converter and the hand-rolled YAML emitter.
 *
 * The emitter is hand-rolled on purpose — this repo's premise is supply-chain
 * security, so a YAML library is not an acceptable dependency for a feature
 * that only ever writes a small, well-known document shape. That trade is only
 * defensible if the emitter is properly pinned down, so the load-bearing
 * assertion here is a round-trip property: emit YAML, parse it back with the
 * minimal parser below, and deep-equal the source object.
 *
 * The parser covers exactly the subset `emitYaml` produces: nested block maps,
 * block sequences of scalars and of maps, inline `[]` / `{}`, double-quoted
 * scalars with escapes, and plain scalars resolved the way YAML would resolve
 * them. Resolving plain scalars (rather than treating everything as a string)
 * is deliberate — it is what makes the round-trip catch a missing quote around
 * a value like `yes` or `123`.
 */
import { describe, expect, it } from 'vitest'
import type { RBACData } from './afmApi'
import { convertRbacToAfmImport, emitYaml } from './afmYaml'

// ── Minimal YAML parser (test-only) ────────────────────────────────────────

type YamlNode = string | number | boolean | null | YamlNode[] | { [key: string]: YamlNode }

interface SourceLine {
  indent: number
  content: string
}

// The emitter never quotes keys, and every key it writes is a plain identifier.
const KEY_PATTERN = /^([A-Za-z_][A-Za-z0-9_.-]*):(?:[ ](.*))?$/

function toSourceLines(text: string): SourceLine[] {
  return text
    .split('\n')
    .filter(raw => raw.trim().length > 0)
    // trimStart only — a quoted scalar may legitimately end in whitespace
    // before its closing quote, and trimEnd would not touch that, but keeping
    // the line verbatim after the indent makes that explicit.
    .map(raw => ({ indent: raw.length - raw.trimStart().length, content: raw.trimStart() }))
}

function isSequenceEntry(line: SourceLine): boolean {
  return line.content.startsWith('- ') || line.content === '-'
}

/**
 * True when the line at `index` opens a block belonging to the key that was
 * just read. A nested map is always more indented than its key; a nested block
 * sequence may sit at the same indent as its key, which is legal YAML and is
 * what the emitter produces for the first key of a sequence entry.
 */
function opensNestedBlock(lines: SourceLine[], index: number, keyIndent: number): boolean {
  if (index >= lines.length) return false
  const line = lines[index]
  if (line.indent > keyIndent) return true
  return line.indent === keyIndent && isSequenceEntry(line)
}

function parseDoubleQuoted(text: string): string {
  if (text.length < 2 || !text.startsWith('"') || !text.endsWith('"')) {
    throw new Error(`malformed quoted scalar: ${text}`)
  }
  const body = text.slice(1, -1)
  let out = ''
  for (let i = 0; i < body.length; i += 1) {
    if (body[i] !== '\\') {
      out += body[i]
      continue
    }
    const escape = body[i + 1]
    i += 1
    switch (escape) {
      case 'n': out += '\n'; break
      case 't': out += '\t'; break
      case 'r': out += '\r'; break
      case '"': out += '"'; break
      case '\\': out += '\\'; break
      case 'x':
        out += String.fromCharCode(parseInt(body.slice(i + 1, i + 3), 16))
        i += 2
        break
      case 'u':
        out += String.fromCharCode(parseInt(body.slice(i + 1, i + 5), 16))
        i += 4
        break
      default:
        throw new Error(`unsupported escape \\${escape} in ${text}`)
    }
  }
  return out
}

function parseScalarText(text: string): YamlNode {
  if (text === '[]') return []
  if (text === '{}') return {}
  if (text.startsWith('"')) return parseDoubleQuoted(text)
  if (/^(?:null|~)$/i.test(text)) return null
  if (/^(?:true|yes|on)$/i.test(text)) return true
  if (/^(?:false|no|off)$/i.test(text)) return false
  if (/^[+-]?\d+$/.test(text)) return Number(text)
  if (/^[+-]?(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) return Number(text)
  return text
}

function parseBlock(lines: SourceLine[], index: number, indent: number): [YamlNode, number] {
  return isSequenceEntry(lines[index])
    ? parseSequence(lines, index, indent)
    : parseMapping(lines, index, indent)
}

function parseMapping(lines: SourceLine[], index: number, indent: number): [Record<string, YamlNode>, number] {
  const map: Record<string, YamlNode> = {}
  let i = index

  while (i < lines.length && lines[i].indent === indent && !isSequenceEntry(lines[i])) {
    const match = KEY_PATTERN.exec(lines[i].content)
    if (!match) throw new Error(`unparsable mapping line: ${lines[i].content}`)
    const [, key, inlineValue] = match
    i += 1

    if (inlineValue !== undefined && inlineValue !== '') {
      map[key] = parseScalarText(inlineValue)
      continue
    }
    if (opensNestedBlock(lines, i, indent)) {
      const [value, next] = parseBlock(lines, i, lines[i].indent)
      map[key] = value
      i = next
      continue
    }
    // A bare `key:` with nothing under it. The emitter never produces this,
    // so treat it as an explicit null rather than silently dropping the key.
    map[key] = null
  }

  return [map, i]
}

/** Parses a sequence entry that opens a map inline, e.g. `- name: frontend`. */
function parseInlineMappingEntry(
  lines: SourceLine[],
  index: number,
  childIndent: number,
  match: RegExpExecArray,
): [Record<string, YamlNode>, number] {
  const [, key, inlineValue] = match
  const map: Record<string, YamlNode> = {}
  let i = index + 1

  if (inlineValue !== undefined && inlineValue !== '') {
    map[key] = parseScalarText(inlineValue)
  } else if (opensNestedBlock(lines, i, childIndent)) {
    const [value, next] = parseBlock(lines, i, lines[i].indent)
    map[key] = value
    i = next
  } else {
    map[key] = null
  }

  const [remaining, next] = parseMapping(lines, i, childIndent)
  return [Object.assign(map, remaining), next]
}

function parseSequence(lines: SourceLine[], index: number, indent: number): [YamlNode[], number] {
  const items: YamlNode[] = []
  let i = index

  while (i < lines.length && lines[i].indent === indent && isSequenceEntry(lines[i])) {
    const rest = lines[i].content === '-' ? '' : lines[i].content.slice(2)

    if (rest === '') {
      i += 1
      if (i >= lines.length || lines[i].indent <= indent) {
        throw new Error('sequence entry with no value')
      }
      const [value, next] = parseBlock(lines, i, lines[i].indent)
      items.push(value)
      i = next
      continue
    }

    const match = KEY_PATTERN.exec(rest)
    if (match) {
      const [entry, next] = parseInlineMappingEntry(lines, i, indent + 2, match)
      items.push(entry)
      i = next
      continue
    }

    items.push(parseScalarText(rest))
    i += 1
  }

  return [items, i]
}

function parseYaml(text: string): YamlNode {
  const lines = toSourceLines(text)
  if (lines.length === 0) return null
  const [value, next] = parseBlock(lines, 0, lines[0].indent)
  if (next !== lines.length) {
    throw new Error(`unconsumed YAML from line ${next}: ${lines[next].content}`)
  }
  return value
}

/** Emit then parse. Every round-trip assertion in this file goes through here. */
function roundTrip(value: unknown): YamlNode {
  return parseYaml(emitYaml(value))
}

// ── Fixtures ───────────────────────────────────────────────────────────────

const CLUSTER = { id: 'local', name: 'Local Cluster' }

const rbacFixture: RBACData = {
  subjects: [
    { name: 'frontend', kind: 'ServiceAccount', namespace: 'apps' },
    { name: 'kustomize-controller', kind: 'ServiceAccount', namespace: 'flux-system' },
    { name: 'lonely', kind: 'ServiceAccount', namespace: 'other' },
  ],
  roles: [
    {
      name: 'secret-reader',
      scope: 'Namespace',
      namespace: 'apps',
      rules: [{ verbs: ['get', 'list'], apiGroups: [''], resources: ['secrets'] }],
    },
    {
      name: 'flux-applier',
      scope: 'Namespace',
      namespace: 'flux-system',
      rules: [{ verbs: ['create'], apiGroups: ['apps'], resources: ['deployments'] }],
    },
    {
      name: 'system:masters',
      scope: 'Cluster',
      rules: [{ verbs: ['*'], apiGroups: ['*'], resources: ['*'] }],
    },
  ],
  bindings: [
    {
      name: 'frontend-reader',
      scope: 'Namespace',
      namespace: 'apps',
      roleRef: 'secret-reader',
      subjects: [{ name: 'frontend', kind: 'ServiceAccount', namespace: 'apps' }],
    },
    {
      name: 'flux-global',
      scope: 'Cluster',
      roleRef: 'system:masters',
      subjects: [{ name: 'kustomize-controller', kind: 'ServiceAccount', namespace: 'flux-system' }],
    },
  ],
}

const emptyRbac: RBACData = { subjects: [], roles: [], bindings: [] }

function roleNames(value: { rbac: { roles: Array<{ name: string }> } }): string[] {
  return value.rbac.roles.map(role => role.name)
}

// ── Converter ──────────────────────────────────────────────────────────────

describe('convertRbacToAfmImport', () => {
  it('produces the AFM import object shape used by scripts/rbac-to-afm.py', () => {
    const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'all')

    expect(Object.keys(result)).toEqual(['id', 'name', 'rbac'])
    expect(result.id).toBe('local')
    expect(result.name).toBe('Local Cluster')
    expect(Object.keys(result.rbac)).toEqual(['subjects', 'roles', 'bindings'])
  })

  it('omits namespace on cluster-scoped roles and keeps it on namespace-scoped roles', () => {
    const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'all')

    const clusterRole = result.rbac.roles.find(role => role.name === 'system:masters')
    const namespacedRole = result.rbac.roles.find(role => role.name === 'secret-reader')

    expect(clusterRole).toBeDefined()
    expect(clusterRole).not.toHaveProperty('namespace')
    expect(namespacedRole?.namespace).toBe('apps')
  })

  it('passes everything through for the "all" sentinel', () => {
    const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'all')

    expect(roleNames(result)).toEqual(['secret-reader', 'flux-applier', 'system:masters'])
    expect(result.rbac.bindings).toHaveLength(2)
    expect(result.rbac.subjects).toHaveLength(3)
  })

  it('retains cluster-scoped roles and bindings under every namespace selection', () => {
    for (const namespace of ['apps', 'flux-system', 'other']) {
      const result = convertRbacToAfmImport(rbacFixture, CLUSTER, namespace)

      expect(roleNames(result)).toContain('system:masters')
      expect(result.rbac.bindings.map(binding => binding.name)).toContain('flux-global')
    }
  })

  it('excludes roles and bindings belonging to a different namespace', () => {
    const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'apps')

    expect(roleNames(result)).toEqual(['secret-reader', 'system:masters'])
    expect(result.rbac.bindings.map(binding => binding.name)).toEqual(['frontend-reader', 'flux-global'])
  })

  it('retains a subject from another namespace when a retained binding references it', () => {
    const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'apps')
    const names = result.rbac.subjects.map(subject => subject.name)

    // frontend lives in `apps`; kustomize-controller does not, but the retained
    // cluster-scoped binding flux-global references it, so it must survive.
    expect(names).toContain('frontend')
    expect(names).toContain('kustomize-controller')
    // `lonely` is in another namespace and no retained binding references it.
    expect(names).not.toContain('lonely')
  })
})

// ── AFM cluster-import contract ────────────────────────────────────────────

/**
 * There are THREE implementations of the AFM cluster-import contract in this
 * repo, and they must agree:
 *
 *   1. `convertRbacToAfmImport` here (browser, read-only — generates YAML for
 *      the operator to paste into KubeSec-AFM);
 *   2. `scripts/rbac-to-afm.py::convert` (CLI, for `kubectl -o json` input);
 *   3. the inline Python in `d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml`
 *      (the CronJob that POSTs to `/clusters/import` every 30 minutes).
 *
 * This block pins the contract from the TypeScript side so a drift in (1)
 * fails here rather than as an HTTP 400 from AFM. It is deliberately about
 * *shape*, since that is the part all three share.
 */
describe('AFM cluster-import contract', () => {
  const result = convertRbacToAfmImport(rbacFixture, CLUSTER, 'all')

  it('has exactly the top-level contract keys, in order', () => {
    expect(Object.keys(result)).toEqual(['id', 'name', 'rbac'])
    expect(Object.keys(result.rbac)).toEqual(['subjects', 'roles', 'bindings'])
  })

  it('emits roles with name, scope and rules, and namespace only when namespaced', () => {
    for (const role of result.rbac.roles) {
      expect(role.scope === 'Cluster' || role.scope === 'Namespace').toBe(true)
      expect(Array.isArray(role.rules)).toBe(true)
      expect('namespace' in role).toBe(role.scope === 'Namespace')
      for (const rule of role.rules) {
        expect(Object.keys(rule).sort()).toEqual(['apiGroups', 'resources', 'verbs'])
      }
    }
  })

  it('emits bindings with a roleRef flattened to the role name', () => {
    for (const binding of result.rbac.bindings) {
      expect(typeof binding.roleRef).toBe('string')
      expect(binding.scope === 'Cluster' || binding.scope === 'Namespace').toBe(true)
      expect('namespace' in binding).toBe(binding.scope === 'Namespace')
      expect(Array.isArray(binding.subjects)).toBe(true)
    }
    expect(result.rbac.bindings.map(binding => binding.roleRef))
      .toEqual(['secret-reader', 'system:masters'])
  })

  it('emits subjects carrying only name, kind and an optional namespace', () => {
    for (const subject of [...result.rbac.subjects, ...result.rbac.bindings.flatMap(b => b.subjects)]) {
      expect(typeof subject.name).toBe('string')
      expect(typeof subject.kind).toBe('string')
      expect(Object.keys(subject).every(key => ['name', 'kind', 'namespace'].includes(key))).toBe(true)
    }
  })
})

// ── Emitter round-trip ─────────────────────────────────────────────────────

describe('emitYaml round-trip', () => {
  it('round-trips a full AFM import object', () => {
    const value = convertRbacToAfmImport(rbacFixture, CLUSTER, 'all')

    expect(roundTrip(value)).toEqual(value)
  })

  it('round-trips a namespace-filtered AFM import object', () => {
    const value = convertRbacToAfmImport(rbacFixture, CLUSTER, 'apps')

    expect(roundTrip(value)).toEqual(value)
  })

  it('round-trips empty RBAC data rather than throwing', () => {
    const value = convertRbacToAfmImport(emptyRbac, CLUSTER, 'all')

    expect(() => emitYaml(value)).not.toThrow()
    expect(emitYaml(value)).toContain('subjects: []')
    expect(roundTrip(value)).toEqual(value)
  })

  it('emits an empty rules array as [] and reads it back as an empty array', () => {
    const value = convertRbacToAfmImport(
      { subjects: [], roles: [{ name: 'no-rules', scope: 'Cluster', rules: [] }], bindings: [] },
      CLUSTER,
      'all',
    )

    expect(emitYaml(value)).toContain('rules: []')
    expect(roundTrip(value)).toEqual(value)
  })

  it('emits nested maps, arrays of scalars and arrays of maps', () => {
    const yaml = emitYaml(convertRbacToAfmImport(rbacFixture, CLUSTER, 'all'))

    expect(yaml).toContain('rbac:')            // nested map
    expect(yaml).toContain('- name: frontend') // array of maps
    expect(yaml).toContain('- get')            // array of scalars
    expect(yaml.startsWith('---')).toBe(false)
  })

  it('round-trips an empty map', () => {
    expect(roundTrip({ meta: {} })).toEqual({ meta: {} })
  })
})

// ── Quoting ────────────────────────────────────────────────────────────────

describe('emitYaml quoting', () => {
  it('keeps a system: prefixed role name intact', () => {
    // `system:masters` has a colon NOT followed by a space, which is a legal
    // plain scalar in YAML, so it should survive unquoted.
    expect(roundTrip({ name: 'system:masters' })).toEqual({ name: 'system:masters' })
  })

  it('quotes a wildcard verb so it is not read as an alias', () => {
    const yaml = emitYaml({ verbs: ['*'] })

    expect(yaml).toContain('"*"')
    expect(roundTrip({ verbs: ['*'] })).toEqual({ verbs: ['*'] })
  })

  it('quotes a resource name with a trailing space', () => {
    const value = { resources: ['secrets '] }

    expect(emitYaml(value)).toContain('"secrets "')
    expect(roundTrip(value)).toEqual(value)
  })

  it('quotes the string "yes" so it does not re-read as a boolean', () => {
    const value = { verb: 'yes' }

    expect(emitYaml(value)).toContain('"yes"')
    expect(roundTrip(value)).toEqual(value)
    expect(roundTrip(value)).not.toEqual({ verb: true })
  })

  it('quotes the string "123" so it does not re-read as a number', () => {
    const value = { name: '123' }

    expect(emitYaml(value)).toContain('"123"')
    expect(roundTrip(value)).toEqual(value)
    expect(roundTrip(value)).not.toEqual({ name: 123 })
  })

  it('leaves real numbers, booleans and null unquoted', () => {
    const value = { count: 123, enabled: true, disabled: false, missing: null }

    expect(emitYaml(value)).toContain('count: 123')
    expect(emitYaml(value)).toContain('enabled: true')
    expect(roundTrip(value)).toEqual(value)
  })

  it('quotes strings YAML would otherwise mis-read', () => {
    const value = {
      comment: '#not-a-comment',
      inlineComment: 'role # pivot',
      mapping: 'key: value',
      trailingColon: 'name:',
      empty: '',
      leading: ' padded',
      anchor: '&anchor',
      tag: '!tag',
      directive: '%directive',
      alias: '*alias',
      block: '|block',
      fold: '>fold',
      at: '@handle',
      tick: '`tick',
      dash: '-dash',
      nullish: 'null',
      tilde: '~',
    }

    expect(roundTrip(value)).toEqual(value)
  })

  it('escapes control characters, quotes and backslashes', () => {
    const value = { text: 'line1\nline2\ttabbed\r"quoted"\\backslash\u0001' }

    expect(roundTrip(value)).toEqual(value)
  })

  it('round-trips RBAC data whose strings are all awkward at once', () => {
    const awkward: RBACData = {
      subjects: [{ name: '123', kind: 'yes', namespace: 'true' }],
      roles: [
        {
          name: 'system:masters',
          scope: 'Cluster',
          rules: [{ verbs: ['*'], apiGroups: [''], resources: ['secrets ', '#hash', 'a: b'] }],
        },
        { name: '*', scope: 'Namespace', namespace: 'no', rules: [] },
      ],
      bindings: [
        {
          name: '@binding',
          scope: 'Cluster',
          roleRef: 'system:masters',
          subjects: [{ name: '123', kind: 'yes', namespace: 'true' }],
        },
      ],
    }
    const value = convertRbacToAfmImport(awkward, { id: 'local', name: 'Cluster: primary' }, 'all')

    expect(roundTrip(value)).toEqual(value)
  })
})
