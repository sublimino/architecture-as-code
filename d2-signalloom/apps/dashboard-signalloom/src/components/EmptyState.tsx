type Tone = 'teal' | 'cyan' | 'violet' | 'amber' | 'red'

const TONE_COLOR: Record<Tone, string> = {
  teal: 'var(--teal)',
  cyan: 'var(--cyan)',
  violet: 'var(--violet)',
  amber: 'var(--amber)',
  red: 'var(--error)',
}

interface Props {
  kicker: string
  body?: string
  tone?: Tone
}

export default function EmptyState({ kicker, body, tone = 'teal' }: Props) {
  const color = TONE_COLOR[tone]
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '60px 24px', gap: 8, textAlign: 'center' }}>
      <p className="kicker" style={{ color }}>
        <span aria-hidden="true">● </span>{kicker}
      </p>
      {body && <p style={{ fontSize: 12.5, color: 'var(--muted)', maxWidth: 360 }}>{body}</p>}
    </div>
  )
}
