import { useLayoutEffect, useState } from 'react'
import {
  DEFAULT_LAYOUT_WIDTH,
  LAYOUT_WIDTH_LABELS,
  LAYOUT_WIDTH_NAMES,
  applyLayoutWidth,
  isLayoutWidth,
  readStoredLayoutWidth,
  storeLayoutWidth,
} from '../styles/layoutWidth'
import type { LayoutWidth } from '../styles/layoutWidth'

// Horizontal clearance for DemoToggle (right: 16) and ThemeToggle (right: 140).
// 250 leaves the three corner widgets side by side without collision.
export const WIDTH_TOGGLE_RIGHT_OFFSET = 250

// Corner widget that controls the main page container max-width ceiling.
// Purely client-side: updates --content-max-width on <html> and remembers
// the choice in localStorage. No reload, no API call.
export default function WidthToggle() {
  const [width, setWidth] = useState<LayoutWidth>(() => readStoredLayoutWidth())

  useLayoutEffect(() => {
    applyLayoutWidth(width)
  }, [width])

  function handleChange(event: React.ChangeEvent<HTMLSelectElement>) {
    const next = isLayoutWidth(event.target.value) ? event.target.value : DEFAULT_LAYOUT_WIDTH
    setWidth(next)
    storeLayoutWidth(next)
  }

  return (
    <select
      value={width}
      onChange={handleChange}
      data-testid="width-toggle"
      aria-label="Layout width"
      title="Change the dashboard content width"
      style={{
        position: 'fixed',
        bottom: 16,
        right: WIDTH_TOGGLE_RIGHT_OFFSET,
        zIndex: 4000,
        padding: '8px 12px',
        borderRadius: 8,
        cursor: 'pointer',
        fontSize: 12,
        fontWeight: 700,
        letterSpacing: 0.3,
        border: '1px solid var(--border-subtle)',
        background: 'var(--surface2)',
        color: 'var(--text)',
        boxShadow: '0 2px 8px rgba(0,0,0,0.4)',
      }}
    >
      {LAYOUT_WIDTH_NAMES.map((name) => (
        <option key={name} value={name}>
          {LAYOUT_WIDTH_LABELS[name]}
        </option>
      ))}
    </select>
  )
}
