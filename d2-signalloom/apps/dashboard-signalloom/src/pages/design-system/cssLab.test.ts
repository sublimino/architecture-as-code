import { describe, expect, it } from 'vitest'
import { THEMES } from '../../styles/themes'
import {
  CSS_LAB_STORAGE_KEY,
  buildBaseThemeCss,
  buildCssExport,
  buildTokenOverrideCss,
  createDefaultDraft,
  parseCssLabDraft,
  validateCustomCss,
  validateTokenValue,
} from './cssLab'

describe('CSS Lab helpers', () => {
  it('uses a dedicated versioned browser-local storage key', () => {
    expect(CSS_LAB_STORAGE_KEY).toBe('signalloom.design-system.css-lab.v1')
  })

  it('falls back safely for malformed and stale drafts', () => {
    expect(parseCssLabDraft('{broken')).toEqual(createDefaultDraft())
    expect(parseCssLabDraft(JSON.stringify({ version: 0, theme: 'light' }))).toEqual(createDefaultDraft())
  })

  it('keeps valid fields while discarding unknown draft values', () => {
    expect(parseCssLabDraft(JSON.stringify({
      version: 1,
      theme: 'light',
      preview: 'headers',
      viewport: 'mobile',
      customCss: '.card { color: hotpink; }',
      tokenOverrides: { '--text': 'papayawhip', '--unknown': 'red', '--bg': 42 },
    }))).toEqual({
      version: 1,
      theme: 'light',
      preview: 'headers',
      viewport: 'mobile',
      customCss: '.card { color: hotpink; }',
      tokenOverrides: { '--text': 'papayawhip' },
    })
  })

  it('rejects CSS capable of issuing network requests', () => {
    expect(validateCustomCss('@import "https://example.test/a.css";').ok).toBe(false)
    expect(validateCustomCss('@im/**/port "https://example.test/a.css";').ok).toBe(false)
    expect(validateCustomCss('.card { background: url(/tracking.gif); }').ok).toBe(false)
    expect(validateCustomCss('.card { content: "url(/not-a-request)"; }')).toEqual({ ok: true })
  })

  it('rejects structurally invalid CSS and accepts local declarations', () => {
    expect(validateCustomCss('.card { color: red;').ok).toBe(false)
    expect(validateCustomCss('this is not CSS').ok).toBe(false)
    expect(validateCustomCss('.card { color red; }').ok).toBe(false)
    expect(validateCustomCss('.card { color: var(--text); }').ok).toBe(true)
  })

  it('rejects bad-string newlines that could mask executable network declarations', () => {
    for (const newline of ['\n', '\r', '\f', '\r\n']) {
      const bypass = `.card { --a: "${newline}; background-image: url(https://example.test/pixel); --b: "${newline}; }`
      expect(validateCustomCss(bypass)).toMatchObject({ ok: false, error: expect.stringMatching(/newline/i) })
    }
    expect(validateCustomCss('.card { content: "a\\\nb"; }')).toEqual({ ok: true })
    expect(validateCustomCss('.card { content: "a\\\r\nb"; }')).toEqual({ ok: true })
  })

  it('rejects unbalanced delimiters, strings and comments', () => {
    expect(validateCustomCss('.card { color: rgb(1 2 3; }').ok).toBe(false)
    expect(validateCustomCss('.card[data-state="open" { color: red; }').ok).toBe(false)
    expect(validateCustomCss('.card { content: "open; }').ok).toBe(false)
    expect(validateCustomCss('.card { color: red; /* open }').ok).toBe(false)
  })

  it('does not treat comment markers inside quoted strings as comments', () => {
    expect(validateCustomCss('.card { content: "/* not a comment */"; }')).toEqual({ ok: true })
  })

  it('accepts supported nested and descriptor at-rules', () => {
    expect(validateCustomCss('@media (max-width: 40rem) { .card { display: grid; } }')).toEqual({ ok: true })
    expect(validateCustomCss('@supports (display: grid) { .card { display: grid; } }')).toEqual({ ok: true })
    expect(validateCustomCss('@keyframes pulse { from { opacity: 0; } 50% { opacity: .5; } to { opacity: 1; } }')).toEqual({ ok: true })
    expect(validateCustomCss('@font-face { font-family: Lab; src: local("Arial"); }')).toEqual({ ok: true })
  })

  it('clearly rejects unsupported at-rules', () => {
    expect(validateCustomCss('@layer lab { .card { color: red; } }')).toMatchObject({
      ok: false,
      error: expect.stringMatching(/unsupported/i),
    })
  })

  it('blocks network requests and rule injection in token values', () => {
    expect(validateTokenValue('url(https://example.test/pixel)')).toMatchObject({ ok: false })
    expect(validateTokenValue('red; } @import "https://example.test/a.css"')).toMatchObject({ ok: false })
    expect(validateTokenValue('color-mix(in srgb, red 20%, black)')).toEqual({ ok: true })
    expect(validateTokenValue('rgb(10 20 30')).toMatchObject({ ok: false })
  })

  it('exports base then custom CSS then token overrides', () => {
    const custom = ':root { --text: hotpink; --bg: papayawhip; }'
    const result = buildCssExport('light', { '--text': 'rebeccapurple' }, custom)
    expect(result).toContain(`--bg: ${THEMES.light['--bg']};`)
    expect(result).toContain('--text: rebeccapurple;')
    expect(result.indexOf(buildBaseThemeCss('light'))).toBeLessThan(result.indexOf(custom))
    expect(result.indexOf(custom)).toBeLessThan(result.indexOf(buildTokenOverrideCss({ '--text': 'rebeccapurple' })))
  })
})
