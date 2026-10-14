import { describe, it, expect, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { render, screen, fireEvent, within, cleanup } from '@testing-library/react'
import { CompactDisclosure, CompactEmail, CompactObservedTime, relativeObservedTime } from './CompactOperationalTable'

describe('compact operational inventory primitives', () => {
  it('preserves copyable email text and offers a break only before @', () => {
    const email = 'very.long-local.part@example.com'
    const { container } = render(<CompactEmail value={email} />)
    expect(container.textContent).toBe(email)
    expect(container.querySelectorAll('wbr')).toHaveLength(1)
    expect(container.querySelector('wbr')?.previousSibling?.textContent).toBe('very.long-local.part')
    expect(container.querySelector('wbr')?.nextSibling?.textContent).toBe('@example.com')
  })

  it('reports known, missing, invalid and future observations honestly', () => {
    const now = Date.parse('2026-10-14T12:00:00Z')
    expect(relativeObservedTime('2026-10-14T11:55:00Z', now)).toBe('5m ago')
    expect(relativeObservedTime('2026-10-14T10:00:00Z', now)).toBe('2h ago')
    expect(relativeObservedTime('2026-10-12T12:00:00Z', now)).toBe('2d ago')
    expect(relativeObservedTime(null, now)).toBe('Unknown')
    expect(relativeObservedTime('not a time', now)).toBe('Unknown')
    expect(relativeObservedTime('2026-10-14T12:05:00Z', now)).toBe('In future')
    expect(relativeObservedTime('', now)).toBe('Unknown')
    expect(relativeObservedTime('2026-10-14T11:59:59Z', now)).toBe('just now')
    expect(relativeObservedTime('2026-10-14T11:59:00Z', now)).toBe('1m ago')
  })

  it('exposes exact observation and timezone on focus, dismisses with Escape', () => {
    render(<CompactObservedTime value="2026-10-14T11:55:00Z" now={Date.parse('2026-10-14T12:00:00Z')} />)
    const trigger = screen.getByRole('button', { name: /observation time/i })
    expect(trigger).toHaveTextContent('5m ago')
    fireEvent.focus(trigger)
    expect(screen.getByRole('tooltip')).toHaveTextContent('2026-10-14T11:55:00Z')
    expect(screen.getByRole('tooltip')).toHaveTextContent(/UTC/)
    fireEvent.keyDown(trigger, { key: 'Escape' })
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    fireEvent.mouseMove(trigger)
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    cleanup()
  })

  it('is hoverable, focusable, persistent across pointer travel and never a mutation', () => {
    const mutate = vi.fn()
    render(<div onClick={mutate}><CompactDisclosure label="Runtime details" summary="kagent">Full runtime metadata</CompactDisclosure></div>)
    const trigger = screen.getByRole('button', { name: 'Runtime details' })
    fireEvent.mouseEnter(trigger)
    const tooltip = screen.getByRole('tooltip')
    expect(tooltip).toHaveTextContent('Full runtime metadata')
    fireEvent.mouseLeave(trigger, { relatedTarget: tooltip })
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    fireEvent.click(trigger)
    expect(mutate).not.toHaveBeenCalled()
    fireEvent.focus(trigger)
    fireEvent.mouseLeave(trigger)
    expect(screen.getByRole('tooltip')).toBeInTheDocument()
    fireEvent.keyDown(trigger, { key: 'Escape' })
    expect(screen.queryByRole('tooltip')).not.toBeInTheDocument()
    cleanup()
  })

  it('portals into the anchor ownerDocument, clamps there and cleans up listeners', () => {
    const frame = document.createElement('iframe')
    document.body.append(frame)
    const doc = frame.contentDocument!
    const host = doc.createElement('div')
    doc.body.append(host)
    const { unmount } = render(<CompactDisclosure label="Details" summary="More">Frame evidence</CompactDisclosure>, { container: host })
    const trigger = within(host).getByRole('button', { name: 'Details' })
    fireEvent.focus(trigger)
    const tip = within(doc.body).getByRole('tooltip')
    expect(tip.ownerDocument).toBe(doc)
    expect(tip.parentElement).toBe(doc.body)
    expect(document.body.querySelector('[role="tooltip"]')).toBeNull()
    expect(parseFloat(tip.style.left)).toBeGreaterThanOrEqual(8)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(within(doc.body).getByRole('tooltip')).toBeInTheDocument()
    fireEvent.keyDown(doc, { key: 'Escape' })
    expect(within(doc.body).queryByRole('tooltip')).not.toBeInTheDocument()
    unmount()
    frame.remove()
  })

  it.each([255, 320])('remeasures wrapped height after clamping to a %spx owner viewport without ResizeObserver', width => {
    const frame = document.createElement('iframe')
    document.body.append(frame)
    const doc = frame.contentDocument!
    const win = doc.defaultView!
    Object.defineProperties(win, {
      innerWidth: { configurable: true, value: width },
      innerHeight: { configurable: true, value: 320 },
      ResizeObserver: { configurable: true, value: undefined },
    })
    const host = doc.createElement('div')
    doc.body.append(host)
    const measured: { width: number; height: number }[] = []
    const rect = (left: number, top: number, width: number, height: number): DOMRect => ({
      x: left, y: top, left, top, width, height, right: left + width, bottom: top + height, toJSON: () => ({}),
    })
    const bounds = vi.spyOn(win.HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
      if (this.getAttribute('role') === 'tooltip') {
        const renderedWidth = parseFloat(this.style.width)
        const height = renderedWidth < 320 ? 220 : 50
        measured.push({ width: renderedWidth, height })
        return rect(parseFloat(this.style.left), parseFloat(this.style.top), renderedWidth, height)
      }
      return rect(win.innerWidth - 43, 288, 35, 20)
    })
    const { unmount } = render(<CompactDisclosure label="Long evidence" summary="Details">{'Long operational evidence with ownership, kernel observations and exact timestamps. '.repeat(12)}</CompactDisclosure>, { container: host })
    try {
      fireEvent.focus(within(host).getByRole('button', { name: 'Long evidence' }))
      const tip = within(doc.body).getByRole('tooltip')
      expect(measured[0]).toEqual({ width: 320, height: 50 })
      expect(measured).toContainEqual({ width: width - 16, height: 220 })
      expect(parseFloat(tip.style.width)).toBe(width - 16)
      expect(parseFloat(tip.style.top)).toBe(62)
      expect(parseFloat(tip.style.top) + 220).toBeLessThanOrEqual(win.innerHeight - 8)
      expect(measured.length).toBeLessThanOrEqual(3)

      // Growing the viewport restores the preferred width, then measures its shorter height.
      Object.defineProperty(win, 'innerWidth', { configurable: true, value: 390 })
      fireEvent(win, new win.Event('resize'))
      expect(parseFloat(tip.style.width)).toBe(320)
      expect(parseFloat(tip.style.top)).toBe(232)
      expect(measured[measured.length - 1]).toEqual({ width: 320, height: 50 })
      const stableMeasurements = measured.length
      fireEvent(win, new win.Event('resize'))
      expect(measured.length).toBe(stableMeasurements + 1)
    } finally {
      unmount()
      bounds.mockRestore()
      frame.remove()
    }
  })

  it('keeps density opt-in, fluid fixed-layout and essential columns reachable at narrow widths', () => {
    const css = readFileSync('src/components/CompactOperationalTable.css', 'utf8')
    expect(css).toContain('table-layout: fixed')
    expect(css).toContain('max-width: 1080px')
    expect(css).not.toMatch(/min-width:\s*(?:1100|1362)px/)
    expect(css).toContain('@container (max-width: 900px)')
    expect(css).toContain('.compact-agent-details { display: none; }')
    const pillRule = css.match(/\.compact-operational-table \.tag,[^{]*\{([^}]*)\}/)?.[1]
    expect(pillRule).toBeDefined()
    expect(pillRule).toMatch(/(?:^|[;\n])\s*height:\s*20px;/)
    expect(pillRule).toContain('white-space: nowrap !important;')
    expect(css).not.toMatch(/\.compact-warning[^}]*white-space:\s*normal/)
    expect(css).toContain('.compact-operational-table th:nth-child(7) { width: 9%; }')
    expect(css).toContain('.compact-operational-table th:nth-child(8) { width: 9%; }')
    expect(css).toContain('min-width: 75px;')
    expect(css).toContain('min-width: 80px;')
    expect(css).toContain('.compact-row-details { display: inline-block; }')
    expect(css).toContain('@container (max-width: 600px)')
    expect(css).toContain('@container (max-width: 240px)')
    expect(css).toContain('.compact-actions .compact-claim { grid-column: 1 / -1; }')
    expect(css).toContain('grid-template-columns: minmax(0, 1fr) 90px')
    expect(css).toContain('.compact-operational-table td:nth-child(8) { grid-column: 2; grid-row: 1 / 5; }')
    expect(css).toContain('@media (pointer: coarse)')
    expect(css).toContain('min-height: 44px')
    expect(css).not.toMatch(/(?:^|\n)(?:\.tag|\.btn|table|td|th)\s*[{,]/)
  })

  it.each([null, 'invalid'])('renders unknown observation explicitly for %s without fabricating a time', value => {
    render(<CompactObservedTime value={value} />)
    const trigger = screen.getByRole('button', { name: /Observation time/ })
    expect(trigger).toHaveTextContent('Unknown')
    expect(trigger.querySelector('time')).toBeNull()
    fireEvent.focus(trigger)
    expect(screen.getByRole('tooltip')).toHaveTextContent('Unknown observation time')
    expect(screen.getByRole('tooltip').querySelector('time')).toBeNull()
  })
})
