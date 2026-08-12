import { Link } from 'react-router-dom'
import { ArrowRight, CheckCircle2, Clock3, ShieldAlert, Sparkles } from 'lucide-react'
import { agents, auditEvents, controls } from '../data/fixtures'
import { Badge, Card, Metric, PageHeader, Provenance, SectionHeader } from '../components/ui'

export default function OverviewPage() {
  return (
    <>
      <PageHeader eyebrow="Trust overview" title="Your estate, explained." description="See what changed, why it matters, and where the evidence lives—without translating the platform first." actions={<><Provenance /><Link className="button button--primary" to="/audit">Create evidence brief</Link></>} />
      <section className="decision-banner">
        <div className="decision-banner__icon"><ShieldAlert size={20} /></div>
        <div><span>Decision needed</span><h2>CardVault's credential should remain contained.</h2><p>Its rotation control failed eight minutes ago. The service path is blocked and evidence is ready for review.</p></div>
        <Link className="button button--primary" to="/topology">Trace the path <ArrowRight size={16} /></Link>
      </section>
      <div className="metric-grid">
        <Metric label="Estate posture" value="82%" detail="4 points higher this week" tone="healthy" />
        <Metric label="Needs review" value="2" detail="1 credential · 1 permission" tone="attention" />
        <Metric label="Protected paths" value="14" detail="Across 4 governed agents" tone="identity" />
        <Metric label="Evidence freshness" value="2m" detail="Last observed signal" tone="healthy" />
      </div>
      <div className="overview-grid">
        <Card className="focus-card">
          <SectionHeader title="What needs your attention" description="Ordered by consequence, not by subsystem." action={<Link to="/compliance">View controls <ArrowRight size={14} /></Link>} />
          <div className="attention-list">
            <Link to="/topology" className="attention-item">
              <span className="attention-item__icon attention-item__icon--critical"><ShieldAlert size={18} /></span>
              <span><strong>Credential rotation failed</strong><small>CardVault · Production · observed 8m ago</small></span>
              <Badge tone="critical">Contained</Badge><ArrowRight size={16} />
            </Link>
            <Link to="/rbac-analysis" className="attention-item">
              <span className="attention-item__icon attention-item__icon--attention"><Sparkles size={18} /></span>
              <span><strong>Permission path needs review</strong><small>Sandbox Agent · modeled from RBAC</small></span>
              <Badge tone="attention">Specialist</Badge><ArrowRight size={16} />
            </Link>
            <Link to="/compliance" className="attention-item">
              <span className="attention-item__icon attention-item__icon--healthy"><CheckCircle2 size={18} /></span>
              <span><strong>SOC 2 evidence is complete</strong><small>CC6.1 · 12 evidence items · fresh now</small></span>
              <Badge tone="healthy">Ready</Badge><ArrowRight size={16} />
            </Link>
          </div>
        </Card>
        <Card className="posture-card">
          <SectionHeader title="Trust posture" description="Four agents, one clear picture." />
          <div className="posture-visual" aria-label="82 percent trust posture"><div className="posture-ring"><span><strong>82</strong><small>/ 100</small></span></div></div>
          <div className="posture-breakdown">
            <span><i className="tone-dot tone-dot--healthy" />Trusted<strong>{agents.filter((a) => a.status === 'Trusted').length}</strong></span>
            <span><i className="tone-dot tone-dot--attention" />Needs review<strong>{agents.filter((a) => a.status === 'Needs review').length}</strong></span>
            <span><i className="tone-dot tone-dot--critical" />Contained<strong>{agents.filter((a) => a.status === 'Contained').length}</strong></span>
          </div>
        </Card>
      </div>
      <div className="overview-grid overview-grid--lower">
        <Card>
          <SectionHeader title="Control pulse" description="The reason behind the score." action={<Link to="/compliance">Open assurance</Link>} />
          <div className="control-list">{controls.slice(0, 3).map((control) => <div key={control.id}><Badge tone={control.tone}>{control.status}</Badge><span><strong>{control.name}</strong><small>{control.id} · {control.evidence}</small></span><strong>{control.affected ? `${control.affected} affected` : 'Clear'}</strong></div>)}</div>
        </Card>
        <Card>
          <SectionHeader title="Recent activity" description="A human-readable operational history." action={<Link to="/audit">Full history</Link>} />
          <div className="mini-timeline">{auditEvents.slice(0, 3).map((event) => <div key={event.time}><span className={`timeline-mark timeline-mark--${event.tone}`}><Clock3 size={12} /></span><span><strong>{event.title}</strong><small>{event.subject} · {event.time}</small></span></div>)}</div>
        </Card>
      </div>
    </>
  )
}
