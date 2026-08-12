import { useMemo, useState } from 'react'
import { Search, SlidersHorizontal } from 'lucide-react'
import { agents } from '../data/fixtures'
import { Badge, Button, Card, DataTable, Metric, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function AgentsPage() {
  const [query, setQuery] = useState('')
  const filtered = useMemo(() => agents.filter((agent) => `${agent.name} ${agent.owner} ${agent.environment}`.toLowerCase().includes(query.toLowerCase())), [query])
  return (
    <>
      <PageHeader eyebrow="Estate" title="Agent health" description="Understand which workloads are trusted, which need attention, and the reason behind each state." actions={<><Provenance /><Button variant="primary">Register agent</Button></>} />
      <div className="metric-grid metric-grid--three"><Metric label="Governed agents" value="4" detail="Across 2 environments" tone="identity" /><Metric label="Currently trusted" value="2" detail="No active control failures" tone="healthy" /><Metric label="Action required" value="2" detail="One contained, one review" tone="attention" /></div>
      <Card>
        <SectionHeader title="Governed estate" description="Search and inspect the current static scenario." />
        <div className="filter-bar"><label><Search size={16} /><span className="sr-only">Search agents</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search agents, owners, environments…" /></label><Button variant="secondary"><SlidersHorizontal size={16} /> Filters</Button></div>
        <DataTable label="Governed agents" headers={['Agent', 'Environment', 'Trust posture', 'Controls', 'Last observed']}>
          {filtered.map((agent) => <tr key={agent.id}><td><div className="entity-cell"><span className={`avatar avatar--${agent.tone}`}>{agent.name.slice(0, 2).toUpperCase()}</span><span><strong>{agent.name}</strong><small>{agent.owner}</small></span></div></td><td>{agent.environment}</td><td><Badge tone={agent.tone}>{agent.status}</Badge><span className="posture-inline">{agent.posture}/100</span></td><td>{agent.controls}</td><td>{agent.lastSeen}</td></tr>)}
        </DataTable>
      </Card>
    </>
  )
}
