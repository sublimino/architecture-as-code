import type { Binding, RBACData, Role, Subject } from './afmApi'

export interface AfmClusterImport {
  id: string
  name: string
  rbac: {
    subjects: Subject[]
    roles: Role[]
    bindings: Binding[]
  }
}

type YamlScalar = string | number | boolean | null
type YamlValue = YamlScalar | YamlValue[] | { [key: string]: YamlValue | undefined }

const INDENT = '  '
const PREFERRED_KEY_ORDER = ['id', 'name', 'rbac', 'subjects', 'roles', 'bindings', 'scope', 'namespace', 'rules', 'roleRef', 'verbs', 'apiGroups', 'resources', 'kind']
const BOOLEAN_PATTERN = /^(?:true|false|yes|no|on|off)$/i
const NULL_PATTERN = /^(?:null|~)$/i
const SPECIAL_FLOAT_PATTERN = /^[+-]?\.(?:inf|nan)$/i
const INTEGER_PATTERN = /^[+-]?[0-9][0-9_]*$/
const OCTAL_HEX_PATTERN = /^[+-]?0(?:o[0-7_]+|x[0-9a-f_]+)$/i
const FLOAT_PATTERN = /^[+-]?(?:(?:[0-9][0-9_]*)?\.[0-9_]+|[0-9][0-9_]*\.)(?:[eE][+-]?[0-9_]+)?$|^[+-]?[0-9][0-9_]*[eE][+-]?[0-9_]+$/

function isYamlRecord(value: unknown): value is Record<string, YamlValue | undefined> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isScalar(value: unknown): value is YamlScalar {
  return value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'
}

function isNamespaceScope(scope: string): boolean {
  return scope === 'Namespace'
}

function normaliseSubject(subject: Subject): Subject {
  const normalised: Subject = { name: subject.name, kind: subject.kind }
  if (subject.namespace) {
    normalised.namespace = subject.namespace
  }
  return normalised
}

function normaliseRole(role: Role): Role {
  const normalised: Role = {
    name: role.name,
    scope: role.scope,
    rules: role.rules.map(rule => ({
      verbs: [...rule.verbs],
      apiGroups: [...rule.apiGroups],
      resources: [...rule.resources],
    })),
  }

  if (isNamespaceScope(role.scope) && role.namespace) {
    normalised.namespace = role.namespace
  }

  return normalised
}

function normaliseBinding(binding: Binding): Binding {
  const normalised: Binding = {
    name: binding.name,
    scope: binding.scope,
    roleRef: binding.roleRef,
    subjects: binding.subjects.map(normaliseSubject),
  }

  if (isNamespaceScope(binding.scope) && binding.namespace) {
    normalised.namespace = binding.namespace
  }

  return normalised
}

function looksLikeYamlKeyword(value: string): boolean {
  return BOOLEAN_PATTERN.test(value)
    || NULL_PATTERN.test(value)
    || SPECIAL_FLOAT_PATTERN.test(value)
    || INTEGER_PATTERN.test(value)
    || OCTAL_HEX_PATTERN.test(value)
    || FLOAT_PATTERN.test(value)
}

function containsControlCharacter(value: string): boolean {
  // Matching control characters is the whole point of this guard — they must be
  // escaped rather than emitted raw into a YAML plain scalar.
  // eslint-disable-next-line no-control-regex
  return /[\u0000-\u001f\u007f-\u009f]/.test(value)
}

function shouldQuoteString(value: string): boolean {
  if (value.length === 0) {
    return true
  }

  if (/^\s|\s$/.test(value)) {
    return true
  }

  if (value.includes(': ') || value.endsWith(':')) {
    return true
  }

  if (value.startsWith('#') || value.includes(' #')) {
    return true
  }

  if (/^[*&!|>%@`'"\-?,[\]{}]/.test(value)) {
    return true
  }

  if (value.includes('\n') || value.includes('\t') || value.includes('\r') || containsControlCharacter(value)) {
    return true
  }

  return looksLikeYamlKeyword(value)
}

function escapeDoubleQuotedString(value: string): string {
  let escaped = ''

  for (const char of value) {
    switch (char) {
      case '\\':
        escaped += '\\\\'
        break
      case '"':
        escaped += '\\"'
        break
      case '\n':
        escaped += '\\n'
        break
      case '\t':
        escaped += '\\t'
        break
      case '\r':
        escaped += '\\r'
        break
      default: {
        const codePoint = char.codePointAt(0)
        if (codePoint === undefined) {
          escaped += char
        } else if (codePoint < 0x20 || (codePoint >= 0x7f && codePoint <= 0x9f)) {
          escaped += codePoint <= 0xff
            ? `\\x${codePoint.toString(16).padStart(2, '0')}`
            : `\\u${codePoint.toString(16).padStart(4, '0')}`
        } else {
          escaped += char
        }
      }
    }
  }

  return `"${escaped}"`
}

function emitScalar(value: YamlScalar): string {
  if (typeof value === 'string') {
    return shouldQuoteString(value) ? escapeDoubleQuotedString(value) : value
  }
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : escapeDoubleQuotedString(String(value))
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false'
  }
  return 'null'
}

function compareKeys(left: string, right: string): number {
  const leftIndex = PREFERRED_KEY_ORDER.indexOf(left)
  const rightIndex = PREFERRED_KEY_ORDER.indexOf(right)

  if (leftIndex !== -1 || rightIndex !== -1) {
    if (leftIndex === -1) {
      return 1
    }
    if (rightIndex === -1) {
      return -1
    }
    return leftIndex - rightIndex
  }

  return left.localeCompare(right)
}

function orderedEntries(value: Record<string, YamlValue | undefined>): Array<[string, YamlValue | undefined]> {
  return Object.entries(value).sort(([left], [right]) => compareKeys(left, right))
}

function emitArray(values: YamlValue[], depth: number): string {
  if (values.length === 0) {
    return '[]'
  }

  return values.map((value) => {
    const prefix = `${INDENT.repeat(depth)}-`
    if (isScalar(value)) {
      return `${prefix} ${emitScalar(value)}`
    }

    if (Array.isArray(value)) {
      if (value.length === 0) {
        return `${prefix} []`
      }
      return `${prefix}\n${emitArray(value, depth + 1)}`
    }

    const entries = orderedEntries(value)
    if (entries.length === 0) {
      return `${prefix} {}`
    }

    const [firstKey, firstValue] = entries[0]
    const firstLine = emitKeyValue(firstKey, firstValue, depth, true)
    const remainingLines = entries.slice(1).map(([key, childValue]) => emitKeyValue(key, childValue, depth + 1, false))
    return [firstLine, ...remainingLines].join('\n')
  }).join('\n')
}

function emitObject(value: Record<string, YamlValue | undefined>, depth: number): string {
  const entries = orderedEntries(value)

  if (entries.length === 0) {
    return '{}'
  }

  return entries.map(([key, childValue]) => emitKeyValue(key, childValue, depth, false)).join('\n')
}

function emitKeyValue(key: string, value: YamlValue | undefined, depth: number, isSequenceEntry: boolean): string {
  const lineIndent = INDENT.repeat(depth)
  const prefix = isSequenceEntry ? `${lineIndent}- ${key}:` : `${lineIndent}${key}:`
  const normalisedValue = value === undefined ? null : value

  // A sequence entry's `- ` marker pushes its first key two columns right, so
  // that key's nested block has to start two deeper again to stay clear of it.
  // Without this, a nested block sequence merely looks inconsistent (legal, but
  // it reads oddly next to sibling keys) and a nested MAP becomes genuinely
  // ambiguous — its children would land in the same column as their own key
  // and re-read as siblings.
  const childDepth = isSequenceEntry ? depth + 2 : depth + 1

  if (isScalar(normalisedValue)) {
    return `${prefix} ${emitScalar(normalisedValue)}`
  }

  if (Array.isArray(normalisedValue)) {
    if (normalisedValue.length === 0) {
      return `${prefix} []`
    }
    return `${prefix}\n${emitArray(normalisedValue, childDepth)}`
  }

  const entries = orderedEntries(normalisedValue)
  if (entries.length === 0) {
    return `${prefix} {}`
  }
  return `${prefix}\n${emitObject(normalisedValue, childDepth)}`
}

/**
 * Generate a unique cluster import ID: `signalloom-{compact-ISO}-{random4}`
 * e.g. `signalloom-20260803T143022-a7f2`
 */
export function generateImportId(now = new Date()): string {
  const stamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, '')
  const rand = Math.random().toString(16).slice(2, 6).padEnd(4, '0')
  return `signalloom-${stamp}-${rand}`
}

/**
 * Generate a human-readable cluster import name.
 * e.g. `SignalLoom Import 2026-08-03T14:30:22Z`
 * When a namespace filter is active: `SignalLoom Import 2026-08-03T14:30:22Z (ns: kube-system)`
 */
export function generateImportName(namespace: string, now = new Date()): string {
  const iso = now.toISOString().replace(/\.\d{3}Z$/, 'Z')
  const suffix = namespace !== 'all' ? ` (ns: ${namespace})` : ''
  return `SignalLoom Import ${iso}${suffix}`
}

export function convertRbacToAfmImport(
  rbac: RBACData,
  cluster: { id: string; name: string },
  namespace: string,
): AfmClusterImport {
  const includeAllNamespaces = namespace === 'all'
  const roles = includeAllNamespaces
    ? rbac.roles.map(normaliseRole)
    : rbac.roles.filter(role => role.scope === 'Cluster' || role.namespace === namespace).map(normaliseRole)
  const bindings = includeAllNamespaces
    ? rbac.bindings.map(normaliseBinding)
    : rbac.bindings.filter(binding => binding.scope === 'Cluster' || binding.namespace === namespace).map(normaliseBinding)

  const retainedBindingSubjects = new Set<string>()
  bindings.forEach(binding => {
    binding.subjects.forEach(subject => retainedBindingSubjects.add(`${subject.kind}/${subject.name}`))
  })

  const subjects = includeAllNamespaces
    ? rbac.subjects.map(normaliseSubject)
    : rbac.subjects
      .filter(subject => subject.namespace === namespace || retainedBindingSubjects.has(`${subject.kind}/${subject.name}`))
      .map(normaliseSubject)

  return {
    id: cluster.id,
    name: cluster.name,
    rbac: {
      subjects,
      roles,
      bindings,
    },
  }
}

export function emitYaml(value: unknown): string {
  if (isScalar(value)) {
    return emitScalar(value)
  }

  if (Array.isArray(value)) {
    return emitArray(value as YamlValue[], 0)
  }

  if (isYamlRecord(value)) {
    return emitObject(value, 0)
  }

  throw new Error(`Unsupported YAML value type: ${typeof value}`)
}
