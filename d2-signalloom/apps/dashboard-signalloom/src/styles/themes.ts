// Single source of truth for every selectable colour theme.
//
// Adding a fourth theme means editing this file only: extend the ThemeName
// union, add its label to THEME_LABELS, add its full variable map to THEMES.
// Every theme supplies a value for all of the CSS custom properties declared
// in global.css's :root block — no theme is allowed to fall back to another's
// values — so a future theme can restyle the whole sheet, not just an accent.

export const CSS_VAR_NAMES = [
  '--bg',
  '--surface',
  '--surface2',
  '--border',
  '--border-subtle',
  '--cyan',
  '--violet',
  '--teal',
  '--amber',
  '--error',
  '--text',
  '--muted',
  '--dim',
  '--slate-gray',
  '--warning',
  '--on-accent',
] as const

export type CssVarName = (typeof CSS_VAR_NAMES)[number]

export type ThemeName = 'dark' | 'light' | 'andy'

/** Selection order in the dropdown. */
export const THEME_NAMES: readonly ThemeName[] = ['dark', 'light', 'andy']

export const THEME_LABELS: Record<ThemeName, string> = {
  dark: 'Dark',
  light: 'Light',
  andy: 'Andy',
}

export const DEFAULT_THEME: ThemeName = 'dark'

export const THEME_STORAGE_KEY = 'signalloom.theme'

export const THEMES: Record<ThemeName, Record<CssVarName, string>> = {
  // Byte-for-byte the palette shipped in global.css's :root block. Changing a
  // value here without changing global.css (or vice versa) fails themes.test.ts.
  dark: {
    '--bg': '#020617',
    '--surface': '#0F172A',
    '--surface2': '#1E293B',
    '--border': '#1E293B',
    '--border-subtle': '#334155',
    '--cyan': '#06B6D4',
    '--violet': '#8B5CF6',
    '--teal': '#10B981',
    '--amber': '#D97706',
    '--error': '#DC2626',
    '--text': '#F8FAFC',
    '--muted': '#94A3B8',
    '--dim': '#64748B',
    '--slate-gray': '#475569',
    '--warning': '#D97706',
    '--on-accent': '#FFFFFF',
  },
  // Near-white surfaces with darkened accents so links, tags and chart series
  // stay legible against white.
  light: {
    '--bg': '#FFFFFF',
    '--surface': '#F8FAFC',
    '--surface2': '#F1F5F9',
    '--border': '#D9E2EC',
    '--border-subtle': '#B6C2CF',
    '--cyan': '#0E7490',
    '--violet': '#6D28D9',
    '--teal': '#047857',
    '--amber': '#B45309',
    '--error': '#B91C1C',
    '--text': '#0F172A',
    '--muted': '#475569',
    '--dim': '#64748B',
    '--slate-gray': '#64748B',
    '--warning': '#B45309',
    '--on-accent': '#FFFFFF',
  },
  // The Signal Loom brand palette, on an indigo-black ground.
  //
  // Derived from public/brand/signal-loom-logo.png rather than invented. The
  // lattice is 3D-shaded, so sampling it naively returns near-black and
  // near-white; filtering to genuinely chromatic pixels (HLS saturation >=
  // 0.25, lightness 0.18-0.78) leaves a hue ramp that sweeps monotonically
  // across the diamond: 251 -> 230 -> 203 -> 184 -> 168 degrees. Every hue
  // below is a point on that ramp, so --cyan is literally the logo's cyan
  // band and not a name that lies.
  //
  //   --violet  258deg  the left corner
  //   --cyan    192deg  the cyan band, and the primary accent
  //   --teal    162deg  the right corner
  //   neutrals  228deg  the periwinkle midpoint, at very low lightness, so the
  //                     chrome carries the brand before any accent is drawn
  //
  // This REPLACES a red-on-black theme. That palette had a defect worth
  // naming, because three files still carry workarounds for it: --cyan,
  // --teal, --violet and --error were all inside a 16-degree band (--teal and
  // --error were the same hue to one decimal place), so four semantic channels
  // rendered as one colour. Worst-case hue separation here is 29.9 degrees.
  //
  // Accent luminance is boxed on both sides and the values were solved for,
  // not chosen. Every accent is used BOTH as text on a dark ground and as a
  // fill under white --on-accent, and those pull opposite ways: text on
  // --surface2 (the lightest ground) wants luminance up, white-on-fill wants it
  // down. Each accent here is the most saturated sRGB colour at its brand hue
  // that lands inside that box. Measured worst cases: accent-as-text 4.56:1
  // (--error on --surface2), white-on-fill 2.63:1 (--cyan, against the 2:1
  // floor tokens.test.ts enforces), --dim on --surface2 4.66:1.
  //
  // --error stays red. That is semantics, not branding: red for failure is
  // reinforced by every OS and every other surface in this product, and
  // spending it on palette coherence would be a real regression. It is the one
  // token deliberately off the brand ramp. Its exact value is the deepest red
  // that still clears 4.5:1 as text, which is what maximises .btn-danger's
  // white label: that measures 3.62:1, up from 3.00:1 at a lighter red. Still
  // under AA for a normal-size label — see the note in headers/primitives.tsx,
  // which refuses white-on-red for the unread pill for exactly this reason.
  andy: {
    '--bg': '#080A14',
    '--surface': '#0F1321',
    '--surface2': '#191E31',
    '--border': '#262D47',
    '--border-subtle': '#3C4569',
    '--cyan': '#00ADD9',
    '--violet': '#AB86FF',
    '--teal': '#00A977',
    '--amber': '#D98A00',
    '--error': '#FF352E',
    '--text': '#EFF1F8',
    '--muted': '#A6ADC9',
    '--dim': '#7E87A9',
    '--slate-gray': '#5E678D',
    '--warning': '#D98A00',
    '--on-accent': '#FFFFFF',
  },
}

export function isThemeName(value: unknown): value is ThemeName {
  return typeof value === 'string' && (THEME_NAMES as readonly string[]).includes(value)
}

/**
 * Paint a theme onto the document root: a `data-theme` hook for CSS selectors
 * plus the variable values as inline custom properties, which outrank the
 * :root block in global.css. Purely local — no reload, no network.
 */
export function applyTheme(name: ThemeName): void {
  const root = document.documentElement
  const vars = THEMES[name]
  root.setAttribute('data-theme', name)
  for (const key of CSS_VAR_NAMES) {
    root.style.setProperty(key, vars[key])
  }
}

export function readStoredTheme(): ThemeName {
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
    return isThemeName(stored) ? stored : DEFAULT_THEME
  } catch {
    // Storage blocked (private mode / disabled cookies) — fall back to default.
    return DEFAULT_THEME
  }
}

export function storeTheme(name: ThemeName): void {
  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, name)
  } catch {
    // Storage blocked — the selection stays session-only.
  }
}
