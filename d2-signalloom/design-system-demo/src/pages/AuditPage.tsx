import { Download, Search } from 'lucide-react'
import { auditEvents } from '../data/fixtures'
import { Badge, Button, Card, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function AuditPage() {
  return <>
    <PageHeader eyebrow="Assurance" title="Activity history" description="A chronological account of decisions, trust changes, and evidence—written for people, backed by exact subjects." actions={<><Provenance>Demo scenario · observed sequence</Provenance><Button variant="secondary"><Download size={16} /> Export JSON</Button></>} />
    <Card><SectionHeader title="Today" description="Four meaningful changes across the demo estate." /><div className="filter-bar"><label><Search size={16} /><span className="sr-only">Search history</span><input placeholder="Search actor, subject, or action…" /></label></div>
      <div className="audit-timeline">{auditEvents.map((event) => <article key={event.time}><time>{event.time}</time><span className={`audit-marker audit-marker--${event.tone}`} aria-hidden="true" /><div><div className="audit-title"><strong>{event.title}</strong><Badge tone={event.tone}>{event.actor}</Badge></div><code>{event.subject}</code><p>{event.detail}</p></div></article>)}</div>
    </Card>
  </>
}
