import { Link, useLocation } from 'react-router-dom'
import { ArrowRight, Braces, CheckCircle2, ExternalLink, GitBranch, ShieldAlert } from 'lucide-react'
import { Badge, Card, Metric, PageHeader, Provenance, SectionHeader } from '../components/ui'

const CONTENT: Record<string, { eyebrow: string; title: string; description: string; question: string }> = {
  '/cryptography': { eyebrow: 'Trust fabric', title: 'Trust foundations', description: 'Inspect the keys, certificates, and signing chains that establish workload identity.', question: 'Can every production identity trace to a healthy root?' },
  '/federated-services': { eyebrow: 'Trust fabric', title: 'Connected services', description: 'Understand external systems participating in the estate’s trust decisions.', question: 'Which external boundaries can influence this service?' },
  '/collusion-access': { eyebrow: 'Trust fabric', title: 'Risky access paths', description: 'Find combinations of roles and identities that create more power than intended.', question: 'Which combinations create an unintended path?' },
  '/rbac-analysis': { eyebrow: 'Permissions', title: 'Permission findings', description: 'Review machine-checked permission risks, translated into concise human proof.', question: 'What is the smallest proof of this permission risk?' },
  '/rbac-explorer': { eyebrow: 'Permissions', title: 'Permission map', description: 'Trace who can access what, through which roles, and why.', question: 'Why can this workload reach that resource?' },
  '/supercred': { eyebrow: 'Demonstrations', title: 'Credential lifecycle', description: 'Follow one credential from issue to revocation, then see the operational consequence.', question: 'Did revocation change the path everywhere it should?' },
}

export default function SpecialistPage() {
  const location = useLocation()
  const content = CONTENT[location.pathname] ?? CONTENT['/rbac-analysis']
  return <>
    <PageHeader eyebrow={content.eyebrow} title={content.title} description={content.description} actions={<Provenance>Static specialist scenario</Provenance>} />
    <section className="question-banner"><span>Investigation question</span><h2>{content.question}</h2></section>
    <div className="metric-grid metric-grid--three"><Metric label="Findings" value="3" detail="One requires action" tone="attention" /><Metric label="Evidence" value="18" detail="Observed and modeled" tone="identity" /><Metric label="Last evaluated" value="2m" detail="Against policy v34" tone="healthy" /></div>
    <div className="specialist-grid">
      <Card><SectionHeader title="High-confidence finding" description="Plain language first; exact proof stays attached." /><div className="finding"><div className="finding__head"><ShieldAlert size={20} /><span><strong>Service account can escalate through role binding</strong><small>Production · fe-signalloom · High confidence</small></span><Badge tone="critical">High</Badge></div><p>CardVault can bind the maintenance role, which grants secret read access outside its normal payment scope.</p><div className="proof"><Braces size={17} /><code>cardvault → bind roles → maintenance → get secrets</code></div><div className="finding__actions"><Link className="button button--primary" to="/topology">Open focused map</Link><Link className="button button--secondary" to="/audit">View source evidence <ExternalLink size={14} /></Link></div></div></Card>
      <Card><SectionHeader title="Evidence chain" description="Every conclusion remains traceable." /><ol className="evidence-chain"><li><CheckCircle2 /><span><strong>Subject identified</strong><small>ServiceAccount/cardvault</small></span></li><li><GitBranch /><span><strong>Relationship modeled</strong><small>RoleBinding/maintenance</small></span></li><li><ShieldAlert /><span><strong>Consequence proved</strong><small>Secret access outside payment scope</small></span></li></ol><Link className="text-link" to="/audit">View related activity <ArrowRight size={14} /></Link></Card>
    </div>
  </>
}
