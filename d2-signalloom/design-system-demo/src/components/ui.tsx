import type { ButtonHTMLAttributes, HTMLAttributes, ReactNode } from 'react'
import { ChevronRight } from 'lucide-react'

export function Button({ variant = 'secondary', className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'secondary' | 'ghost' | 'danger' }) {
  return <button className={`button button--${variant} ${className}`.trim()} {...props} />
}

export function Card({ className = '', ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`card ${className}`.trim()} {...props} />
}

export function Badge({ tone = 'neutral', children }: { tone?: string; children: ReactNode }) {
  return <span className={`badge badge--${tone}`}><span aria-hidden="true" className="badge__dot" />{children}</span>
}

export function Metric({ label, value, detail, tone = 'neutral' }: { label: string; value: string; detail: string; tone?: string }) {
  return (
    <Card className="metric">
      <div className="metric__top"><span>{label}</span><span className={`signal signal--${tone}`} aria-hidden="true" /></div>
      <strong>{value}</strong>
      <small>{detail}</small>
    </Card>
  )
}

export function PageHeader({ eyebrow, title, description, actions, breadcrumb }: { eyebrow: string; title: string; description: string; actions?: ReactNode; breadcrumb?: string }) {
  return (
    <header className="page-header">
      <div className="breadcrumbs" aria-label="Breadcrumb">
        <span>Signal Loom</span><ChevronRight size={13} aria-hidden="true" /><span>{breadcrumb ?? eyebrow}</span>
      </div>
      <div className="page-header__row">
        <div>
          <span className="eyebrow">{eyebrow}</span>
          <h1>{title}</h1>
          <p>{description}</p>
        </div>
        {actions ? <div className="page-header__actions">{actions}</div> : null}
      </div>
    </header>
  )
}

export function SectionHeader({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return (
    <div className="section-header">
      <div><h2>{title}</h2>{description ? <p>{description}</p> : null}</div>
      {action}
    </div>
  )
}

export function Provenance({ children = 'Demo scenario · fixture-tested' }: { children?: ReactNode }) {
  return <div className="provenance"><span className="provenance__pulse" aria-hidden="true" />{children}</div>
}

export function DataTable({ headers, children, label }: { headers: string[]; children: ReactNode; label: string }) {
  return (
    <div className="table-wrap">
      <table aria-label={label}>
        <thead><tr>{headers.map((header) => <th key={header}>{header}</th>)}</tr></thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  )
}
