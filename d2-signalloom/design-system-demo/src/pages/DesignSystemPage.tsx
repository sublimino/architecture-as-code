import { Badge, Button, Card, Metric, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function DesignSystemPage() {
  return <>
    <PageHeader eyebrow="System" title="Design system" description="Reusable primitives built around evidence, consequence, and calm operational clarity." actions={<Provenance>Static component showcase</Provenance>} />
    <Card><SectionHeader title="Actions" description="Four variants, one predictable interaction language." /><div className="showcase-row"><Button variant="primary">Primary action</Button><Button variant="secondary">Secondary</Button><Button variant="ghost">Ghost action</Button><Button variant="danger">Destructive</Button></div></Card>
    <Card><SectionHeader title="Status language" description="Color reinforces text; it never carries meaning alone." /><div className="showcase-row"><Badge tone="healthy">Trusted</Badge><Badge tone="attention">Needs review</Badge><Badge tone="critical">Contained</Badge><Badge tone="identity">Modeled</Badge><Badge>Unknown</Badge></div></Card>
    <div className="metric-grid metric-grid--three"><Metric label="Decision metric" value="82%" detail="Consequence in context" tone="healthy" /><Metric label="Evidence count" value="18" detail="Observed and modeled" tone="identity" /><Metric label="Open findings" value="2" detail="One action required" tone="attention" /></div>
  </>
}
