import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import SyncStatusPill from './SyncStatusPill'

describe('SyncStatusPill', () => {
  it('renders the label and carries the tone through the alpha-ramp token, not a computed colour', () => {
    render(<SyncStatusPill tone="teal" label="Synced" testId="pill-teal" />)
    const el = screen.getByTestId('pill-teal')
    expect(el).toHaveTextContent('Synced')
    // Regression guard mirroring Settings.test.tsx: a shared pill must still
    // emit the literal alpha-ramp border token, not a color-mix() computation,
    // or the existing "valid token border" assertion in Settings.test.tsx breaks.
    expect(el.getAttribute('style')).toContain('var(--teal-border)')
    expect(el).toHaveClass('tag')
  })

  it('uses --text for amber-tone labels instead of the failing-contrast accent', () => {
    render(<SyncStatusPill tone="amber" label="Not yet scanned" testId="pill-amber" />)
    const el = screen.getByTestId('pill-amber')
    // --amber on --amber-bg measures 3.20:1 in dark (below the 4.5:1 AA floor
    // for 11px text) per the design-system audit, rule 11. The label must be
    // --text; colour is carried by the dot instead.
    expect(el.getAttribute('style')).toContain('color: var(--text)')
    expect(el.getAttribute('style')).not.toContain('color: var(--amber)')
    expect(screen.getByTestId('pill-amber')).toHaveTextContent('Not yet scanned')
  })

  it('uses --text for red-tone labels instead of the failing-contrast accent', () => {
    render(<SyncStatusPill tone="red" label="Disconnected" testId="pill-red" />)
    const el = screen.getByTestId('pill-red')
    expect(el.getAttribute('style')).toContain('color: var(--text)')
    expect(el.getAttribute('style')).not.toContain('color: var(--error)')
  })

  it('renders a decorative colour dot only for amber and red tones', () => {
    render(<SyncStatusPill tone="red" label="Error" testId="pill-red-dot" />)
    const dot = screen.getByTestId('pill-red-dot').querySelector('[aria-hidden="true"]')
    expect(dot).toBeTruthy()

    render(<SyncStatusPill tone="teal" label="Live" testId="pill-teal-dot" />)
    const noDot = screen.getByTestId('pill-teal-dot').querySelector('[aria-hidden="true"]')
    expect(noDot).toBeNull()
  })

  it('keeps accent-coloured text for teal, cyan, violet and muted tones (not flagged by the audit)', () => {
    render(<SyncStatusPill tone="cyan" label="Live" testId="pill-cyan" />)
    expect(screen.getByTestId('pill-cyan').getAttribute('style')).toContain('color: var(--cyan)')

    render(<SyncStatusPill tone="muted" label="Checking…" testId="pill-muted" />)
    expect(screen.getByTestId('pill-muted').getAttribute('style')).toContain('color: var(--muted)')
  })

  it('passes through title, role and aria-live for live-updating badges', () => {
    render(<SyncStatusPill tone="red" label="Sync error: boom" testId="pill-live" title="boom" role="status" ariaLive="polite" />)
    const el = screen.getByTestId('pill-live')
    expect(el).toHaveAttribute('title', 'boom')
    expect(el).toHaveAttribute('role', 'status')
    expect(el).toHaveAttribute('aria-live', 'polite')
  })

  it('merges a caller style override (e.g. RemoteSyncBadge truncation) without losing the tone', () => {
    render(<SyncStatusPill tone="teal" label="Live" testId="pill-style" style={{ maxWidth: 260 }} />)
    const el = screen.getByTestId('pill-style')
    expect(el.getAttribute('style')).toContain('max-width: 260px')
    expect(el.getAttribute('style')).toContain('var(--teal-border)')
  })
})
