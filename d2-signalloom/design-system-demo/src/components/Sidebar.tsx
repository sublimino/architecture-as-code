import { useEffect, useRef, useState } from 'react'
import { NavLink } from 'react-router-dom'
import {
  Activity, Bot, ChevronLeft, ChevronRight, CircleHelp, FileCheck2, Fingerprint,
  KeyRound, LayoutDashboard, LockKeyhole, Menu, Network, ScrollText, Settings,
  ShieldCheck, Sparkles, Waypoints, X,
} from 'lucide-react'
import { usePreferences } from '../state/preferences'
import { ThemeToggle } from './ThemeToggle'

type NavItem = { to: string; label: string; description: string; icon: typeof Bot; badge?: string }
type NavGroup = { label: string; admin?: boolean; items: NavItem[] }

export const navGroups: NavGroup[] = [
  { label: 'Overview', items: [
    { to: '/', label: 'Trust overview', description: 'What needs attention now?', icon: LayoutDashboard },
  ] },
  { label: 'Estate', items: [
    { to: '/agents', label: 'Agent health', description: 'Which workloads can we trust?', icon: Bot, badge: '4' },
    { to: '/topology', label: 'Trust topology', description: 'Why is this connection allowed?', icon: Waypoints },
  ] },
  { label: 'Assurance', items: [
    { to: '/compliance', label: 'Controls & evidence', description: 'Which controls need proof?', icon: FileCheck2, badge: '2' },
    { to: '/audit', label: 'Activity history', description: 'What changed and who changed it?', icon: ScrollText },
  ] },
  { label: 'Trust fabric', admin: true, items: [
    { to: '/cryptography', label: 'Trust foundations', description: 'Inspect keys and signing chains.', icon: KeyRound },
    { to: '/federated-services', label: 'Connected services', description: 'Inspect external trust systems.', icon: Network },
    { to: '/collusion-access', label: 'Risky access paths', description: 'Find combinations creating undue power.', icon: Fingerprint },
  ] },
  { label: 'Permissions', admin: true, items: [
    { to: '/rbac-analysis', label: 'Permission findings', description: 'Review machine-checked risks.', icon: ShieldCheck },
    { to: '/rbac-explorer', label: 'Permission map', description: 'Trace who can access what.', icon: LockKeyhole },
    { to: '/supercred', label: 'Credential lifecycle', description: 'Run a revocation scenario.', icon: Activity },
  ] },
]

export function Sidebar() {
  const [mobileOpen, setMobileOpen] = useState(false)
  const [collapsed, setCollapsed] = useState(false)
  const menuButtonRef = useRef<HTMLButtonElement>(null)
  const sidebarRef = useRef<HTMLElement>(null)
  const { superadmin, setSuperadmin } = usePreferences()

  useEffect(() => {
    if (!mobileOpen) return
    const sidebar = sidebarRef.current
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    sidebar?.querySelector<HTMLElement>('button, a, input')?.focus()
    const manageFocus = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setMobileOpen(false)
        menuButtonRef.current?.focus()
        return
      }
      if (event.key !== 'Tab' || !sidebar) return
      const candidates = Array.from(sidebar.querySelectorAll<HTMLElement>('button:not([disabled]), a[href], input:not([disabled])'))
      const visible = candidates.filter((element) => element.getClientRects().length > 0)
      const focusable = visible.length > 0 ? visible : candidates
      const first = focusable[0]
      const last = focusable.at(-1)
      if (!focusable.includes(document.activeElement as HTMLElement)) {
        event.preventDefault()
        ;(event.shiftKey ? last : first)?.focus()
        return
      }
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
      if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
    }
    document.addEventListener('keydown', manageFocus)
    return () => {
      document.body.style.overflow = previousOverflow
      document.removeEventListener('keydown', manageFocus)
    }
  }, [mobileOpen])

  return (
    <>
      <button ref={menuButtonRef} className="mobile-menu" onClick={() => { setCollapsed(false); setMobileOpen(true) }} aria-label="Open navigation" aria-expanded={mobileOpen}><Menu /></button>
      {mobileOpen ? <button className="sidebar-backdrop" aria-label="Dismiss navigation" onClick={() => setMobileOpen(false)} /> : null}
      <aside ref={sidebarRef} className={`sidebar ${mobileOpen ? 'sidebar--open' : ''} ${collapsed ? 'sidebar--collapsed' : ''}`} aria-label="Primary navigation" role={mobileOpen ? 'dialog' : undefined} aria-modal={mobileOpen || undefined}>
        <div className="sidebar__brand">
          <div className="brand-mark" aria-hidden="true"><span /></div>
          <div className="brand-copy"><strong>Signal Loom</strong><small>Governance, made legible</small></div>
          <button className="icon-button mobile-close" onClick={() => setMobileOpen(false)} aria-label="Close navigation"><X size={18} /></button>
        </div>
        <nav className="sidebar__nav">
          {navGroups.filter((group) => !group.admin || superadmin).map((group) => (
            <section className="nav-group" key={group.label} aria-labelledby={`nav-${group.label.replace(/\s/g, '-').toLowerCase()}`}>
              <h2 id={`nav-${group.label.replace(/\s/g, '-').toLowerCase()}`}>{group.label}{group.admin ? <span>Specialist</span> : null}</h2>
              {group.items.map(({ to, label, description, icon: Icon, badge }) => (
                <NavLink key={to} to={to} end={to === '/'} title={`${label} — ${description}`} onClick={() => setMobileOpen(false)} className={({ isActive }) => `nav-item ${isActive ? 'nav-item--active' : ''}`}>
                  <Icon size={18} aria-hidden="true" />
                  <span className="nav-item__copy"><strong>{label}</strong><small>{description}</small></span>
                  {badge ? <span className={`nav-badge ${label.includes('Controls') ? 'nav-badge--alert' : ''}`} aria-label={`${badge} items`}>{badge}</span> : null}
                </NavLink>
              ))}
            </section>
          ))}
        </nav>
        <div className="sidebar__footer">
          <label className="admin-toggle" title="Shows or hides specialist navigation. It does not grant permissions.">
            <span><Sparkles size={16} aria-hidden="true" /><span className="admin-toggle__copy"><strong>Superadmin</strong><small>Show specialist tools</small></span></span>
            <input type="checkbox" checked={superadmin} onChange={(event) => setSuperadmin(event.target.checked)} aria-describedby="admin-help" data-testid="superadmin-toggle" />
            <i aria-hidden="true" />
          </label>
          <p id="admin-help" className="sr-only">Shows or hides specialist navigation. It does not grant permissions.</p>
          <NavLink className="footer-link" to="/settings"><Settings size={16} /><span>Workspace settings</span></NavLink>
          <button className="footer-link" type="button"><CircleHelp size={16} /><span>Help & keyboard guide</span></button>
          <div className="sidebar__controls"><ThemeToggle /><button className="collapse-button" onClick={() => setCollapsed(!collapsed)} aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}>{collapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}<span>{collapsed ? '' : 'Collapse'}</span></button></div>
        </div>
      </aside>
    </>
  )
}
