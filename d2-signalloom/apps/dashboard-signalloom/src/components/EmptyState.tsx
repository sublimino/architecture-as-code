interface Props {
  icon?: string
  title: string
  body?: string
}

export default function EmptyState({ icon = '📭', title, body }: Props) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '60px 24px', gap: 12, color: 'var(--muted)' }}>
      <span style={{ fontSize: 40 }}>{icon}</span>
      <p style={{ fontSize: 15, fontWeight: 600, color: 'var(--text)' }}>{title}</p>
      {body && <p style={{ fontSize: 13, maxWidth: 360, textAlign: 'center' }}>{body}</p>}
    </div>
  )
}
