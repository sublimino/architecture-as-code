import { Maximize2 } from 'lucide-react'
import { useState } from 'react'
import { TrustGraph } from '../components/TrustGraph'
import { Button, PageHeader, Provenance } from '../components/ui'

export default function TopologyPage() {
  const [expanded, setExpanded] = useState(false)
  return <><PageHeader eyebrow="Estate" title="Trust topology" description="Trace the smallest relevant path, inspect why access exists, and distinguish observation from modelled context." actions={<><Provenance>Observed signals + modeled policy</Provenance><Button variant="secondary" onClick={() => setExpanded(true)} aria-expanded={expanded}><Maximize2 size={16} /> Full screen</Button></>} /><div className={expanded ? 'topology-stage topology-stage--expanded' : 'topology-stage'}>{expanded ? <Button className="topology-stage__close" onClick={() => setExpanded(false)}>Exit full screen</Button> : null}<TrustGraph /></div></>
}
