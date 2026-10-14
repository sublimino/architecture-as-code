import { useId, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { placeTooltip } from './HelpHint'
import './CompactOperationalTable.css'

const DISCLOSURE_WIDTH = 320

/** Opt-in density only: unrelated DashKit/DataTable consumers are unchanged. */
export function CompactOperationalTable({ label, children }: { label: string; children: ReactNode }) {
  return <div className="card compact-operational-table" role="region" aria-label={label} tabIndex={0}>
    <table>{children}</table>
  </div>
}

export function CompactEmail({ value }: { value: string }) {
  const at = value.indexOf('@')
  return <span className="compact-email">{at < 0 ? value : <>{value.slice(0, at)}<wbr />{value.slice(at)}</>}</span>
}

/** A non-mutating disclosure, portalled outside scrolling tables into its own document. */
export function CompactDisclosure({ label, summary, children, className = '', testId, retainContent = true }: {
  label: string; summary: ReactNode; children: ReactNode; className?: string; testId?: string; retainContent?: boolean
}) {
  const id = useId()
  const anchor = useRef<HTMLButtonElement>(null)
  const tip = useRef<HTMLDivElement>(null)
  const focused = useRef(false)
  const timer = useRef<ReturnType<typeof setTimeout>>()
  const [open, setOpen] = useState(false)
  const [position, setPosition] = useState({ top: 0, left: 8, width: DISCLOSURE_WIDTH })
  const cancelClose = () => { clearTimeout(timer.current) }
  const reveal = () => { cancelClose(); setOpen(true) }
  const leave = () => {
    cancelClose()
    if (!focused.current) timer.current = setTimeout(() => setOpen(false), 180)
  }

  useLayoutEffect(() => () => clearTimeout(timer.current), [])
  useLayoutEffect(() => {
    if (!open) return
    const doc = anchor.current?.ownerDocument
    const win = doc?.defaultView
    if (!doc || !win) return
    const measure = () => {
      if (!anchor.current || !tip.current) return
      const a = anchor.current.getBoundingClientRect()
      const t = tip.current.getBoundingClientRect()
      const next = placeTooltip(a, { ...t, width: DISCLOSURE_WIDTH, height: t.height }, { width: win.innerWidth, height: win.innerHeight })
      setPosition(prev => prev.top === next.top && prev.left === next.left && prev.width === next.width
        ? prev
        : { top: next.top, left: next.left, width: next.width })
    }
    const dismiss = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { cancelClose(); setOpen(false) }
    }
    measure()
    doc.addEventListener('keydown', dismiss)
    win.addEventListener('resize', measure)
    doc.addEventListener('scroll', measure, true)
    return () => {
      doc.removeEventListener('keydown', dismiss)
      win.removeEventListener('resize', measure)
      doc.removeEventListener('scroll', measure, true)
    }
  // A narrower committed width wraps the text: measure its new height before paint.
  // This layout pass also works in owner windows without ResizeObserver. Comparing
  // geometry above avoids state-update loops when resize/scroll reports no change.
  }, [open, children, position.width])

  const content = <>{children}</>
  return <span className={`compact-disclosure ${className}`}>
    <button ref={anchor} type="button" className="compact-disclosure-trigger" aria-label={label}
      aria-describedby={open ? id : undefined} aria-expanded={open} data-testid={testId}
      onMouseEnter={reveal} onMouseLeave={leave}
      onFocus={() => { focused.current = true; reveal() }}
      onBlur={e => {
        const next = e.relatedTarget as Node | null
        focused.current = !!next && !!tip.current?.contains(next)
        leave()
      }}
      onKeyDown={e => { e.stopPropagation(); if (e.key === 'Escape') { cancelClose(); setOpen(false) } }}
      onClick={e => { e.stopPropagation(); reveal() }}>
      {summary}
    </button>
    {/* Keep secondary data in the row's DOM when closed, but never repeat it visually. */}
    {!open && retainContent && <span hidden>{content}</span>}
    {open && anchor.current && createPortal(<div ref={tip} id={id} role="tooltip" tabIndex={0}
      className="compact-operational-tooltip" style={{ position: 'fixed', ...position }}
      onMouseEnter={cancelClose} onMouseLeave={leave}
      onFocus={() => { focused.current = true; cancelClose() }}
      onBlur={() => { focused.current = false; leave() }}
      onClick={e => e.stopPropagation()} onKeyDown={e => { e.stopPropagation(); if (e.key === 'Escape') { cancelClose(); setOpen(false) } }}>
      {content}
    </div>, anchor.current.ownerDocument.body)}
  </span>
}

export function relativeObservedTime(value: string | null | undefined, now = Date.now()): string {
  const time = value ? Date.parse(value) : NaN
  if (!Number.isFinite(time)) return 'Unknown'
  const age = now - time
  if (age < 0) return 'In future'
  if (age < 60_000) return 'just now'
  if (age < 3_600_000) return `${Math.floor(age / 60_000)}m ago`
  if (age < 86_400_000) return `${Math.floor(age / 3_600_000)}h ago`
  return `${Math.floor(age / 86_400_000)}d ago`
}

export function CompactObservedTime({ value, now, testId }: { value?: string | null; now?: number; testId?: string }) {
  const relative = relativeObservedTime(value, now)
  const valid = !!value && Number.isFinite(Date.parse(value))
  const exact = valid ? new Date(value).toLocaleString('en-GB', {
    day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short',
  }) : 'Unknown observation time'
  return <CompactDisclosure label={`Observation time details: ${relative}`} testId={testId}
    summary={valid ? <time dateTime={value!}>{relative}</time> : relative}>
    {valid ? <><div>{exact}</div><div>{value} (UTC: {new Date(value!).toISOString()})</div></> : exact}
  </CompactDisclosure>
}
