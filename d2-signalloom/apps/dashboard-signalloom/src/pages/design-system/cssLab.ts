import {
  CSS_VAR_NAMES,
  DEFAULT_THEME,
  THEMES,
  isThemeName,
  type CssVarName,
  type ThemeName,
} from '../../styles/themes'

export const CSS_LAB_STORAGE_KEY = 'signalloom.design-system.css-lab.v1'
export const MAX_CUSTOM_CSS_LENGTH = 100_000
const MAX_DRAFT_LENGTH = 250_000
const MAX_TOKEN_VALUE_LENGTH = 2_048

export type CssLabPreview = 'gallery' | 'headers'
export type CssLabViewport = 'desktop' | 'mobile'

export interface CssLabDraft {
  version: 1
  theme: ThemeName
  preview: CssLabPreview
  viewport: CssLabViewport
  customCss: string
  tokenOverrides: Partial<Record<CssVarName, string>>
}

export function createDefaultDraft(): CssLabDraft {
  return {
    version: 1,
    theme: DEFAULT_THEME,
    preview: 'gallery',
    viewport: 'desktop',
    customCss: '',
    tokenOverrides: {},
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function parseCssLabDraft(raw: string | null): CssLabDraft {
  if (!raw || raw.length > MAX_DRAFT_LENGTH) return createDefaultDraft()
  try {
    const value: unknown = JSON.parse(raw)
    if (!isRecord(value) || value.version !== 1) return createDefaultDraft()

    const theme = isThemeName(value.theme) ? value.theme : DEFAULT_THEME
    const preview: CssLabPreview = value.preview === 'headers' ? 'headers' : 'gallery'
    const viewport: CssLabViewport = value.viewport === 'mobile' ? 'mobile' : 'desktop'
    const candidateCss = typeof value.customCss === 'string' ? value.customCss : ''
    const customCss = validateCustomCss(candidateCss).ok ? candidateCss : ''
    const tokenOverrides: CssLabDraft['tokenOverrides'] = {}
    if (isRecord(value.tokenOverrides)) {
      for (const name of CSS_VAR_NAMES) {
        const candidate = value.tokenOverrides[name]
        if (typeof candidate === 'string' && candidate.trim() && validateTokenValue(candidate).ok) {
          tokenOverrides[name] = candidate
        }
      }
    }
    return { version: 1, theme, preview, viewport, customCss, tokenOverrides }
  } catch {
    return createDefaultDraft()
  }
}

export interface CssValidationResult {
  ok: boolean
  error?: string
}

interface MaskedCss {
  structural: string
  network: string
}

class CssSyntaxError extends Error {}

function maskStringsAndComments(css: string): MaskedCss {
  let structural = ''
  let network = ''
  let quote = ''
  let inComment = false

  for (let index = 0; index < css.length; index += 1) {
    const character = css[index]
    const next = css[index + 1]
    if (inComment) {
      structural += ' '
      if (character === '*' && next === '/') {
        structural += ' '
        index += 1
        inComment = false
      }
      continue
    }
    if (quote) {
      if (character === '\n' || character === '\r' || character === '\f') {
        throw new CssSyntaxError('Invalid CSS: unescaped newline in a quoted string.')
      }
      structural += ' '
      network += ' '
      if (character === '\\') {
        if (next === undefined) throw new CssSyntaxError('Invalid CSS: unterminated string escape.')
        structural += ' '
        network += ' '
        index += 1
        if (next === '\r' && css[index + 1] === '\n') {
          structural += ' '
          network += ' '
          index += 1
        }
      } else if (character === quote) {
        quote = ''
      }
      continue
    }
    if (character === '/' && next === '*') {
      structural += '  '
      index += 1
      inComment = true
      continue
    }
    if (character === '"' || character === "'") {
      structural += 'x'
      network += ' '
      quote = character
      continue
    }
    if (character === '\\') {
      throw new CssSyntaxError('Escaped CSS identifiers are unsupported because they can disguise network functions.')
    }
    structural += character
    network += character
  }
  if (inComment) throw new CssSyntaxError('Invalid CSS: unterminated comment.')
  if (quote) throw new CssSyntaxError('Invalid CSS: unterminated quoted string.')
  return { structural, network }
}

function validateBalancedDelimiters(css: string): void {
  const stack: string[] = []
  for (const character of css) {
    if (character === '(' || character === '[') stack.push(character)
    if (character === ')' || character === ']') {
      const expected = character === ')' ? '(' : '['
      if (stack.pop() !== expected) throw new CssSyntaxError(`Invalid CSS: unmatched ${character}.`)
    }
  }
  if (stack.length > 0) throw new CssSyntaxError(`Invalid CSS: unmatched ${stack[stack.length - 1]}.`)
}

function skipWhitespace(css: string, start: number, end: number): number {
  let position = start
  while (position < end && /\s/.test(css[position])) position += 1
  return position
}

function findRuleOpener(css: string, start: number, end: number): number {
  let parentheses = 0
  let brackets = 0
  for (let position = start; position < end; position += 1) {
    const character = css[position]
    if (character === '(') parentheses += 1
    else if (character === ')') parentheses -= 1
    else if (character === '[') brackets += 1
    else if (character === ']') brackets -= 1
    else if (parentheses === 0 && brackets === 0 && (character === '{' || character === ';')) return position
  }
  return -1
}

function findClosingBrace(css: string, open: number, end: number): number {
  let depth = 1
  for (let position = open + 1; position < end; position += 1) {
    if (css[position] === '{') depth += 1
    else if (css[position] === '}') depth -= 1
    if (depth === 0) return position
  }
  return -1
}

function splitDeclarations(css: string, start: number, end: number): Array<[number, number]> {
  const ranges: Array<[number, number]> = []
  let segmentStart = start
  let parentheses = 0
  let brackets = 0
  for (let position = start; position < end; position += 1) {
    const character = css[position]
    if (character === '{' || character === '}') {
      throw new CssSyntaxError('Invalid CSS: nested rules are unsupported inside a declaration block.')
    }
    if (character === '(') parentheses += 1
    else if (character === ')') parentheses -= 1
    else if (character === '[') brackets += 1
    else if (character === ']') brackets -= 1
    else if (character === ';' && parentheses === 0 && brackets === 0) {
      ranges.push([segmentStart, position])
      segmentStart = position + 1
    }
  }
  ranges.push([segmentStart, end])
  return ranges
}

function validateDeclarations(css: string, start: number, end: number): void {
  for (const [rangeStart, rangeEnd] of splitDeclarations(css, start, end)) {
    const segment = css.slice(rangeStart, rangeEnd).trim()
    if (!segment) continue
    let parentheses = 0
    let brackets = 0
    let colon = -1
    for (let offset = 0; offset < segment.length; offset += 1) {
      const character = segment[offset]
      if (character === '(') parentheses += 1
      else if (character === ')') parentheses -= 1
      else if (character === '[') brackets += 1
      else if (character === ']') brackets -= 1
      else if (character === ':' && parentheses === 0 && brackets === 0) {
        colon = offset
        break
      }
    }
    if (colon < 1) throw new CssSyntaxError(`Invalid CSS declaration "${segment}": expected a colon.`)
    const property = segment.slice(0, colon).trim()
    const value = segment.slice(colon + 1).trim()
    if (!/^(?:--[\w-]+|-?[A-Za-z][\w-]*)$/.test(property)) {
      throw new CssSyntaxError(`Invalid CSS property "${property}".`)
    }
    if (!value) throw new CssSyntaxError(`Invalid CSS declaration "${property}": expected a value.`)
  }
}

const KEYFRAME_SELECTOR = /^(?:(?:from|to|\d+(?:\.\d+)?%)(?:\s*,\s*(?:from|to|\d+(?:\.\d+)?%))*)$/i

function validateKeyframes(css: string, start: number, end: number): void {
  let position = start
  while ((position = skipWhitespace(css, position, end)) < end) {
    const open = findRuleOpener(css, position, end)
    if (open < 0 || css[open] !== '{') throw new CssSyntaxError('Invalid keyframes rule: expected a step block.')
    const selector = css.slice(position, open).trim()
    if (!KEYFRAME_SELECTOR.test(selector)) throw new CssSyntaxError(`Invalid keyframe selector "${selector}".`)
    const close = findClosingBrace(css, open, end)
    if (close < 0) throw new CssSyntaxError('Invalid keyframes rule: unmatched opening brace.')
    validateDeclarations(css, open + 1, close)
    position = close + 1
  }
}

function validateRuleList(css: string, start: number, end: number): void {
  let position = start
  while ((position = skipWhitespace(css, position, end)) < end) {
    if (css[position] === '}') throw new CssSyntaxError('Invalid CSS: unexpected closing brace.')
    const open = findRuleOpener(css, position, end)
    if (open < 0) throw new CssSyntaxError(`Invalid CSS rule "${css.slice(position, end).trim()}": expected an opening brace.`)
    const header = css.slice(position, open).trim()
    if (css[open] === ';') {
      const name = header.match(/^@([\w-]+)/)?.[1]
      throw new CssSyntaxError(name ? `Unsupported CSS at-rule @${name}.` : `Invalid CSS statement "${header}".`)
    }
    if (!header) throw new CssSyntaxError('Invalid CSS: rule selector is empty.')
    const close = findClosingBrace(css, open, end)
    if (close < 0) throw new CssSyntaxError('Invalid CSS: unmatched opening brace.')

    if (header.startsWith('@')) {
      const match = header.match(/^@([\w-]+)([\s\S]*)$/)
      if (!match) throw new CssSyntaxError(`Invalid CSS at-rule "${header}".`)
      const name = match[1].toLowerCase()
      const prelude = match[2].trim()
      if (name === 'media' || name === 'supports') {
        if (!prelude) throw new CssSyntaxError(`Invalid @${name} rule: expected a condition.`)
        validateRuleList(css, open + 1, close)
      } else if (name === 'keyframes' || /^-[a-z]+-keyframes$/.test(name)) {
        if (!prelude) throw new CssSyntaxError('Invalid @keyframes rule: expected a name.')
        validateKeyframes(css, open + 1, close)
      } else if (name === 'font-face') {
        if (prelude) throw new CssSyntaxError('Invalid @font-face rule: unexpected prelude.')
        validateDeclarations(css, open + 1, close)
      } else {
        throw new CssSyntaxError(`Unsupported CSS at-rule @${name}.`)
      }
    } else {
      validateDeclarations(css, open + 1, close)
    }
    position = close + 1
  }
}

/** Conservative, dependency-free validation for the CSS subset supported by the lab. */
export function validateCustomCss(css: string): CssValidationResult {
  try {
    if (css.length > MAX_CUSTOM_CSS_LENGTH) {
      return { ok: false, error: `Custom CSS is limited to ${MAX_CUSTOM_CSS_LENGTH.toLocaleString()} characters.` }
    }
    const masked = maskStringsAndComments(css)
    if (/@\s*import\b|\b(?:url|image-set|src)\s*\(/i.test(masked.network)) {
      return { ok: false, error: 'Network-capable CSS (@import, url(), image-set(), src(), or escaped identifiers) is not allowed.' }
    }
    validateBalancedDelimiters(masked.structural)
    validateRuleList(masked.structural, 0, masked.structural.length)
    return { ok: true }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : 'Invalid CSS.' }
  }
}

export function validateTokenValue(value: string): CssValidationResult {
  if (!value.trim()) return { ok: true }
  if (value.length > MAX_TOKEN_VALUE_LENGTH) {
    return { ok: false, error: `Token values are limited to ${MAX_TOKEN_VALUE_LENGTH.toLocaleString()} characters.` }
  }
  const networkCheck = validateCustomCss(`:root { --css-lab-value: ${value}; }`)
  if (!networkCheck.ok) return networkCheck
  if (/[;{}]/.test(value)) {
    return { ok: false, error: 'Token values cannot contain rule delimiters.' }
  }
  return { ok: true }
}

export function resolvedThemeValues(
  theme: ThemeName,
  overrides: CssLabDraft['tokenOverrides'],
): Record<CssVarName, string> {
  return Object.fromEntries(
    CSS_VAR_NAMES.map((name) => [name, overrides[name]?.trim() || THEMES[theme][name]]),
  ) as Record<CssVarName, string>
}

export function buildCssExport(
  theme: ThemeName,
  overrides: CssLabDraft['tokenOverrides'],
  customCss: string,
): string {
  return [
    `/* Signal Loom CSS Lab · ${theme} base · browser-local export */`,
    buildBaseThemeCss(theme),
    customCss.trim(),
    buildTokenOverrideCss(overrides),
  ].filter(Boolean).join('\n\n') + '\n'
}

function buildRootCss(values: Partial<Record<CssVarName, string>>): string {
  const declarations = CSS_VAR_NAMES
    .filter((name) => values[name]?.trim())
    .map((name) => `  ${name}: ${values[name]!.trim()};`)
    .join('\n')
  return declarations ? `:root {\n${declarations}\n}` : ''
}

export function buildBaseThemeCss(theme: ThemeName): string {
  return buildRootCss(THEMES[theme])
}

export function buildTokenOverrideCss(overrides: CssLabDraft['tokenOverrides']): string {
  return buildRootCss(overrides)
}
