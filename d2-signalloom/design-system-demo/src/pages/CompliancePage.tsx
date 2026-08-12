import { useState } from 'react'
import { controls } from '../data/fixtures'
import { Badge, Button, Card, DataTable, Metric, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function CompliancePage() {
  const [filter, setFilter] = useState<'All' | 'Needs attention'>('All')
  const visible = filter === 'All' ? controls : controls.filter((control) => control.status !== 'Passing')
  return <>
    <PageHeader eyebrow="Assurance" title="Controls & evidence" description="Move from posture to proof: see what failed, what it affects, and where the supporting evidence came from." actions={<><Provenance>Demo scenario · mixed provenance</Provenance><Button variant="primary">Export evidence brief</Button></>} />
    <div className="metric-grid"><Metric label="Control posture" value="87%" detail="34 of 39 passing" tone="healthy" /><Metric label="Failing" value="1" detail="Credential rotation" tone="critical" /><Metric label="Needs evidence" value="1" detail="Least-privilege access" tone="attention" /><Metric label="Fresh evidence" value="32" detail="Observed in last hour" tone="identity" /></div>
    <Card><SectionHeader title="Control register" description="Every state includes its reason and provenance." action={<div className="segmented" aria-label="Control filter"><button className={filter === 'All' ? 'active' : ''} onClick={() => setFilter('All')}>All</button><button className={filter === 'Needs attention' ? 'active' : ''} onClick={() => setFilter('Needs attention')}>Needs attention</button></div>} />
      <DataTable label="Control register" headers={['Control', 'Framework', 'State', 'Affected', 'Evidence']}>
        {visible.map((control) => <tr key={control.id}><td><strong>{control.name}</strong><small className="cell-sub">{control.id}</small></td><td>{control.framework}</td><td><Badge tone={control.tone}>{control.status}</Badge></td><td>{control.affected || '—'}</td><td>{control.evidence}</td></tr>)}
      </DataTable>
    </Card>
  </>
}
