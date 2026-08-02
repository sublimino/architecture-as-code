interface Segment {
  value: number
  color: string
  label: string
}

interface Props {
  segments: Segment[]
  label?: string
  sublabel?: string
  size?: number
}

export default function DonutChart({ segments, label, sublabel, size = 140 }: Props) {
  const R = (size / 2) * 0.78
  const C = 2 * Math.PI * R
  const cx = size / 2
  const cy = size / 2
  const sw = size * 0.114

  const total = segments.reduce((s, seg) => s + seg.value, 0)

  let offset = 0
  const arcs = segments.map((seg) => {
    const dash = total > 0 ? (seg.value / total) * C : 0
    const gap = C - dash
    const startOffset = offset
    offset += dash
    return { ...seg, dash, gap, startOffset }
  })

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12 }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
        {/* Track */}
        <circle
          cx={cx} cy={cy} r={R}
          fill="none"
          stroke="var(--surface2)"
          strokeWidth={sw}
        />
        {total === 0 ? null : arcs.map((arc, i) =>
          arc.value === 0 ? null : (
            <circle
              key={i}
              cx={cx} cy={cy} r={R}
              fill="none"
              stroke={arc.color}
              strokeWidth={sw}
              strokeDasharray={`${arc.dash} ${arc.gap}`}
              strokeDashoffset={C / 4 - arc.startOffset}
              strokeLinecap="butt"
            />
          )
        )}
        {/* Center text */}
        {label && (
          <text
            x={cx} y={cy - (sublabel ? 6 : 0)}
            textAnchor="middle" dominantBaseline="middle"
            fill="var(--text)"
            fontSize={size * 0.16}
            fontWeight="700"
            fontFamily="Arial, sans-serif"
          >
            {label}
          </text>
        )}
        {sublabel && (
          <text
            x={cx} y={cy + size * 0.12}
            textAnchor="middle" dominantBaseline="middle"
            fill="var(--muted)"
            fontSize={size * 0.09}
            fontFamily="Arial, sans-serif"
          >
            {sublabel}
          </text>
        )}
      </svg>
      {/* Legend */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', justifyContent: 'center' }}>
        {segments.map((seg, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 12, color: 'var(--muted)' }}>
            <span style={{ width: 10, height: 10, borderRadius: 2, background: seg.color, display: 'inline-block' }} />
            <span>{seg.label}: <strong style={{ color: 'var(--text)' }}>{seg.value}</strong></span>
          </div>
        ))}
      </div>
    </div>
  )
}
