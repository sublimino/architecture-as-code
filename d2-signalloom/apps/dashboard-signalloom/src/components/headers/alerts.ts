/**
 * Fixture data and the deep-link contract for the header candidates on
 * DesignSystemHeadersPage.
 *
 * WHY THIS FILE EXISTS SEPARATELY. The five headers are five arguments about
 * chrome, not five sets of data. If each carried its own alert list they would
 * be comparing different worlds, and the page's only real question — "which
 * arrangement handles the same six alerts best?" — would go unanswered. One
 * fixture, five presentations.
 *
 * THE DEEP-LINK CONTRACT is the load-bearing part and it is the thing most
 * products get wrong. An alert that says "3 controls are failing" and links to
 * /compliance has told the reader nothing they did not already know and has
 * handed them a search problem. A target here is three separate pieces, each
 * doing a job the other two cannot:
 *
 *   path    which resource. The route with the id already substituted —
 *           /compliance/eu-ai-act, never /compliance.
 *   query   what must be true for the row to be on screen at all. This is the
 *           piece that gets dropped, and dropping it is why deep links "work"
 *           in review and fail in use: you land on an unfiltered list sorted by
 *           name, the row is on page four, and the reader is back to searching.
 *   anchor  which row. So the page can scroll to it and highlight it, and so
 *           the URL still means something after it has been pasted into a
 *           ticket by someone who will open it next Tuesday.
 *
 * None of this needs a router to demonstrate, and deliberately does not use
 * one: `toHref` returns a string, the specimens render it into a plain <a
 * href>, and the test asserts the string. In the real app these become
 * <Link to={toHref(target)}>; the payload is identical either way, and keeping
 * the gallery router-free is what lets DesignSystemHeadersPage.test.tsx render
 * it with no providers at all — the same discipline DesignSystemPage keeps.
 */

/** Ordered worst-first. Sort keys, drawer grouping and the "highest" helper all rely on this order. */
export const SEVERITIES = ['critical', 'warning', 'info'] as const

export type Severity = (typeof SEVERITIES)[number]

export const SEVERITY_LABELS: Record<Severity, string> = {
  critical: 'Critical',
  warning: 'Warning',
  info: 'Info',
}

/**
 * The token each severity paints with.
 *
 * Named as tokens rather than colours because these are read straight into
 * `var(...)` at the call site — styles/cssVarUsage.test.ts fails the build for
 * a bare hex in an inline style, and for a `var(--x)` no theme declares.
 *
 * Colour is never the only carrier: every place one of these is used, the
 * severity word is rendered beside it or is in the control's accessible name.
 */
export const SEVERITY_TOKENS: Record<Severity, string> = {
  critical: '--error',
  warning: '--amber',
  info: '--cyan',
}

export interface AlertTarget {
  /** Route with the resource id already substituted. Never a bare list route. */
  path: string
  /** Filter state the landing page needs before the row is rendered at all. */
  query?: Record<string, string>
  /** Fragment naming the row, so the page can scroll to it and highlight it. */
  anchor?: string
}

export interface HeaderAlert {
  id: string
  severity: Severity
  /** What happened, in the reader's language. No error codes in the headline. */
  title: string
  /** The specific resource this is about — shown, so the link is checkable before it is followed. */
  resource: string
  /** Relative age. Fixed strings, not computed: a gallery that drifts by the minute is untestable. */
  age: string
  target: AlertTarget
  /** Where the reader ends up, in words. Used as the link's accessible name suffix. */
  destination: string
}

/**
 * Six alerts: two of each severity, so every grouping in every variant has
 * something to group. Deliberately spread across four different routes —
 * a fixture where everything lands on one page would make the deep-link
 * machinery look like decoration.
 */
export const ALERTS: HeaderAlert[] = [
  {
    id: 'alert-sbom-attestation',
    severity: 'critical',
    title: 'sbom-collector failed attestation verification',
    resource: 'agent/sbom-collector',
    age: '4m ago',
    target: {
      path: '/compliance/eu-ai-act',
      query: { control: 'ART-14-3', state: 'failing' },
      anchor: 'row-sbom-collector',
    },
    destination: 'EU AI Act control ART-14-3, sbom-collector row',
  },
  {
    id: 'alert-stale-credential',
    severity: 'critical',
    title: 'credential-rotator is presenting a 412-day-old key',
    resource: 'credential/cred-7741',
    age: '11m ago',
    target: {
      path: '/credential-inventory',
      query: { age: 'expired', owner: 'identity' },
      anchor: 'row-cred-7741',
    },
    destination: 'Credential Inventory, cred-7741 row',
  },
  {
    id: 'alert-undeclared-egress',
    severity: 'warning',
    title: 'egress-auditor reached an undeclared endpoint',
    resource: 'agent/egress-auditor',
    age: '38m ago',
    target: {
      path: '/network-tests',
      query: { probe: 'egress', result: 'blocked' },
      anchor: 'row-egress-auditor',
    },
    destination: 'Network Tests, blocked egress probes, egress-auditor row',
  },
  {
    id: 'alert-policy-drift',
    severity: 'warning',
    title: 'POL-118 has drifted from the ratified version',
    resource: 'policy/POL-118',
    age: '2h ago',
    target: {
      path: '/compliance/policies',
      query: { policy: 'POL-118', status: 'drifted' },
      anchor: 'row-pol-118',
    },
    destination: 'Policy Compliance, POL-118 row',
  },
  {
    id: 'alert-reassessment-due',
    severity: 'info',
    title: 'Quarterly EU AI Act reassessment opens on Monday',
    resource: 'framework/eu-ai-act',
    age: '1d ago',
    target: {
      path: '/compliance/eu-ai-act',
      anchor: 'section-reassessment',
    },
    destination: 'EU AI Act, reassessment section',
  },
  {
    id: 'alert-new-account',
    severity: 'info',
    title: 'New service account discovered in namespace network',
    resource: 'account/acct-3312',
    age: '1d ago',
    target: {
      path: '/discovery/accounts/acct-3312',
    },
    destination: 'Discovery, account acct-3312',
  },
]

/**
 * The anti-pattern, kept beside the real thing rather than described.
 *
 * This is the link every product ships first: correct, useless, and impossible
 * to argue with in review because it does navigate somewhere. Rendered next to
 * its deep equivalent in the Deep-linking section, which is the only way to
 * make the difference land — the two are one word apart in the markup and a
 * different job entirely for the reader.
 */
export const SHALLOW_TARGET: AlertTarget = { path: '/compliance' }

/** Serialise a target into the href a header actually renders. */
export function toHref(target: AlertTarget): string {
  const query = target.query
    ? `?${Object.entries(target.query)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join('&')}`
    : ''
  const anchor = target.anchor ? `#${target.anchor}` : ''
  return `${target.path}${query}${anchor}`
}

/**
 * The accessible name for a link to an alert.
 *
 * Spelt out rather than left to the anchor's text content, because the visible
 * text of an alert row is a headline ("sbom-collector failed attestation
 * verification") and the useful question for someone who cannot see where the
 * link points is "where will this take me?".
 *
 * The order is not decoration. The visible headline comes first, so the name
 * still opens with the words a speech-input user can see and would say — the
 * WCAG 2.5.3 rule that components/sidebarLabelInName.test.tsx exists to
 * enforce elsewhere in this app. The severity word is second because some call
 * sites render it inside the link (the command palette does), and a visible
 * word that is not in the accessible name is the same failure in miniature.
 * The destination is last because it is the only part the reader cannot see.
 */
export function alertLinkName(alert: HeaderAlert): string {
  return `${alert.title} — ${SEVERITY_LABELS[alert.severity]}, open ${alert.destination}`
}

/** Worst-first, then newest-first within a severity. Stable, so the tests can assert order. */
export function bySeverity(alerts: HeaderAlert[]): HeaderAlert[] {
  return [...alerts].sort((a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity))
}

/** The single alert a one-slot header has room for. Undefined when nothing is open. */
export function highestSeverity(alerts: HeaderAlert[]): HeaderAlert | undefined {
  return bySeverity(alerts)[0]
}

export function countBySeverity(alerts: HeaderAlert[]): Record<Severity, number> {
  return {
    critical: alerts.filter((a) => a.severity === 'critical').length,
    warning: alerts.filter((a) => a.severity === 'warning').length,
    info: alerts.filter((a) => a.severity === 'info').length,
  }
}

// ── Environment and identity fixture ─────────────────────────────────────────
//
// What a bank's operator is pointed at. Two of the five variants show this and
// three do not, and that difference is most of the argument between them: a
// cluster name in the chrome is either the thing that stops someone
// suspending an agent in prod, or it is a line of text nobody has read since
// their first week.

export interface HeaderEnvironment {
  tenant: string
  cluster: string
  region: string
  /** Whether the figures on screen are real. The app has a DemoToggle; a header is where its state belongs. */
  dataMode: 'Demo data' | 'Live data'
  superadmin: boolean
}

export const ENVIRONMENT: HeaderEnvironment = {
  tenant: 'Acme Insurance',
  cluster: 'prod-eu-west-1',
  region: 'eu-west-1',
  dataMode: 'Demo data',
  superadmin: true,
}

export const OPERATOR = {
  name: 'A. Martin',
  initial: 'A',
  role: 'Platform security',
}

// ── Breadcrumb fixture ───────────────────────────────────────────────────────
//
// Modelled on a route this app actually has (/compliance/:frameworkId), because
// a breadcrumb demonstrated on an invented three-level hierarchy proves the
// component works and proves nothing about whether this app needs one.

export interface Crumb {
  label: string
  href?: string
}

export const CRUMBS: Crumb[] = [
  { label: 'Compliance', href: '/compliance' },
  { label: 'EU AI Act', href: '/compliance/eu-ai-act' },
  { label: 'Article 14 · Human oversight' },
]

// ── Command palette fixture ──────────────────────────────────────────────────

export interface Command {
  id: string
  label: string
  /** The group it appears under. Also the word a reader would use to find it. */
  group: 'Go to' | 'Alerts' | 'Actions'
  hint?: string
  href?: string
}

export const COMMANDS: Command[] = [
  { id: 'cmd-agents', label: 'Agents', group: 'Go to', hint: 'g then a', href: '/agents' },
  { id: 'cmd-compliance', label: 'Compliance', group: 'Go to', hint: 'g then c', href: '/compliance' },
  { id: 'cmd-credentials', label: 'Credential Inventory', group: 'Go to', href: '/credential-inventory' },
  { id: 'cmd-network', label: 'Network Tests', group: 'Go to', href: '/network-tests' },
  { id: 'cmd-rotate', label: 'Rotate the API key', group: 'Actions', hint: 'confirms first' },
  { id: 'cmd-theme', label: 'Switch theme', group: 'Actions' },
  { id: 'cmd-export', label: 'Export the audit trail as CSV', group: 'Actions' },
]
