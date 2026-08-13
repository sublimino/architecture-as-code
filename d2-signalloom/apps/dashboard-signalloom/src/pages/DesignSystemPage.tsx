/**
 * Design System & Component Library — the internal, superadmin-visible index of
 * what this dashboard is built out of.
 *
 * Why it exists. The app's visual language lives in two places that nothing
 * joins up: the theme-switched custom properties in styles/themes.ts, and about
 * thirty components under src/components/ whose intended use is documented only
 * in their own header comments. Ten pages have each independently decided what
 * an error looks like. This page is the single surface where the tokens and the
 * components are visible side by side, so "is there already a thing for this"
 * is a question with an answer.
 *
 * What it is not. It is not a live view of anything. Every specimen below is
 * driven by fixed props declared in this file — no API client, no auth context,
 * no router. That is deliberate and it is load-bearing: a gallery that needs a
 * cluster to render is a gallery nobody opens, and DesignSystemPage.test.tsx
 * renders it with no providers at all precisely to keep it that way.
 *
 * Two things worth knowing before you edit it.
 *
 * 1. LIVE REGIONS. This is the only page in the app that mounts many
 *    waiting-indicators at once, which makes it the only page where the count
 *    of ARIA live regions is a design problem rather than an afterthought. Each
 *    gallery PixelLoader therefore passes `announce={false}` — the default is
 *    true, and nine defaulted loaders is a screen reader reading nine
 *    simultaneous "Churning" announcements at anyone who opens this page. The
 *    six LoadingState specimens do own regions, because LoadingState has no
 *    `announce` opt-out; six is a deliberate ceiling, asserted exactly in the
 *    test rather than left to drift. See the note rendered in that section.
 *    ButtonWait owns no region by design and adds none here — the roster is
 *    seven regions before and after that section, asserted by name in the test.
 *
 * 2. COLOURS. styles/cssVarUsage.test.ts forbids bare hex in inline styles and
 *    forbids referencing a `var(--x)` that no theme declares. The swatches below
 *    are built from CSS_VAR_NAMES itself rather than a hand-kept list, so the
 *    palette here cannot fall behind themes.ts, and the hex values shown are
 *    read from THEMES — displayed as text, never as a style value.
 */
import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react'
import PixelLoader, { type PixelLoaderVariant } from '../components/PixelLoader'
import LoadingState from '../components/LoadingState'
import ErrorState from '../components/ErrorState'
import EmptyState from '../components/EmptyState'
import StatusBadge from '../components/StatusBadge'
import HelpHint from '../components/HelpHint'
import DataTable, { type Column } from '../components/DataTable'
import DonutChart from '../components/DonutChart'
import { ProofConsole, type Proof, type ProofStreamPhase } from '../components/ProofConsole'
import type { DemoRunLogChunk } from '../api/demoRunner'
import CredentialStateNotice from '../components/CredentialStateNotice'
import { Pill, StatCard, Section as DashSection, Table as DashTable, td as dashTd } from '../components/DashKit'
import { colors } from '../styles/tokens'
import { CSS_VAR_NAMES, THEMES, THEME_LABELS, THEME_NAMES, type CssVarName } from '../styles/themes'
import ButtonWait from '../components/ButtonWait'

// ── Loader gallery ───────────────────────────────────────────────────────────

/**
 * The loader variants, in the order a reader should meet them.
 *
 * Loom is first and carries the "default" badge because the question anyone
 * opening this page actually has is "what do I get if I write `<PixelLoader />`
 * and pass nothing?". A gallery that answers that only by ordering has not
 * answered it — so the answer is stated in the section's when-to-use line, shown
 * as a badge on the Loom specimen, and demonstrated by a ninth specimen below
 * the four that passes no `variant` at all.
 *
 * The other three are alternatives: reached by naming them, and each with a
 * reason you would.
 */
const LOADER_VARIANTS: readonly { name: PixelLoaderVariant; blurb: string; isDefault?: boolean }[] = [
  {
    name: 'Loom',
    blurb: 'Low-fi animation of the Signal Loom woven-diamond mark. What you get when you pass no variant.',
    isDefault: true,
  },
  { name: 'Drive', blurb: 'Square cells, chevron wavefront driving right. Reach for it beside dense telemetry, where the mark reads as decoration.' },
  { name: 'Dots', blurb: 'The same wavefront with circular cells. Softer beside body text.' },
  { name: 'Orbit', blurb: 'A comet lapping the perimeter; the centre cell stays dark.' },
]

const LOADER_SIZES = ['sm', 'md'] as const


/**
 * Both buttons in the ButtonWait pair share this.
 *
 * The fixed `minWidth` is the specimen's actual claim: a control that grows or
 * shrinks when its work starts drags the rest of the row with it, and on a
 * toolbar that means the button under the pointer moves out from under it. The
 * test asserts both buttons carry the same one, because "it does not resize" is
 * a property worth failing on rather than eyeballing.
 */
const WAIT_BUTTON_STYLE: CSSProperties = {
  minWidth: 190,
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 8,
}

// ── Specimen data ────────────────────────────────────────────────────────────

const BADGE_SPECIMENS: { variant: 'lifecycle' | 'risk' | 'privilege' | 'violation' | 'compliance' | 'nhi'; statuses: string[] }[] = [
  { variant: 'lifecycle', statuses: ['enrolled', 'active', 'suspended', 'revoked'] },
  { variant: 'risk', statuses: ['minimal_risk', 'limited_risk', 'high_risk', 'unacceptable_risk', 'gpai'] },
  { variant: 'privilege', statuses: ['standard', 'elevated', 'domain_admin', 'enterprise_admin'] },
  { variant: 'violation', statuses: ['new', 'acknowledged', 'resolved'] },
  { variant: 'compliance', statuses: ['pass', 'fail', 'pending', 'reassessment_requested'] },
  { variant: 'nhi', statuses: ['discovered', 'enrollment_requested', 'dismissed'] },
]

interface DemoRow {
  agent: string
  namespace: string
  findings: number
  state: string
}

const TABLE_ROWS: DemoRow[] = [
  { agent: 'ingest-worker', namespace: 'signalloom', findings: 0, state: 'active' },
  { agent: 'policy-evaluator', namespace: 'signalloom', findings: 2, state: 'suspended' },
  { agent: 'attestation-signer', namespace: 'supply-chain', findings: 0, state: 'active' },
  { agent: 'sbom-collector', namespace: 'supply-chain', findings: 5, state: 'revoked' },
  { agent: 'drift-detector', namespace: 'platform', findings: 1, state: 'active' },
  { agent: 'credential-rotator', namespace: 'platform', findings: 0, state: 'enrolled' },
  { agent: 'egress-auditor', namespace: 'network', findings: 3, state: 'suspended' },
  { agent: 'mesh-probe', namespace: 'network', findings: 0, state: 'active' },
  { agent: 'log-shipper', namespace: 'observability', findings: 0, state: 'active' },
  { agent: 'trace-sampler', namespace: 'observability', findings: 1, state: 'active' },
  { agent: 'quota-reaper', namespace: 'platform', findings: 0, state: 'active' },
  { agent: 'cert-renewer', namespace: 'platform', findings: 0, state: 'enrolled' },
]

const TABLE_COLUMNS: Column<DemoRow>[] = [
  { key: 'agent', label: 'Agent', sortable: true },
  { key: 'namespace', label: 'Namespace', sortable: true },
  {
    key: 'findings',
    label: 'Open findings',
    sortable: true,
    help: 'Controls this agent currently fails. Zero is a pass, not an absence of data.',
  },
  { key: 'state', label: 'State' },
]

/**
 * The second DataTable specimen: the configuration a real page needs.
 *
 * AgentsPage.tsx line 3 has carried `// TODO: migrate table to DataTable (1
 * table with search/lifecycle filtering)` since the filter interaction was
 * written by hand. The reason it has not moved is that nothing showed what the
 * migrated version looks like — the only worked example of DataTable was the
 * four-column one above, which answers none of the questions AgentsPage has:
 * where does the search box live, who owns the filter state, what happens to
 * the page number when a filter cuts the rows out from under it.
 *
 * So this specimen is that answer, at the same shape: seven columns, every one
 * sortable, StatusBadge in two of them, a `pageSize` small enough that the pager
 * is a visible part of the example rather than a code path you have to trust.
 *
 * The division of labour is the thing to take away. DataTable sorts and
 * paginates; the page owns search and filtering and hands down an already-narrow
 * array. DataTable notices the length change and resets to page 1 by itself
 * (see its `usePrevious` guard), which is the bug you would otherwise ship —
 * filtering to three rows while sitting on page 2 and rendering nothing.
 */
interface FleetRow {
  agent: string
  type: string
  owner: string
  state: string
  findings: number
  posture: number
  lastActivity: string
}

/** Deliberately not in alphabetical or numeric order — a sort you cannot see is not a demonstration. */
const FLEET_ROWS: FleetRow[] = [
  { agent: 'policy-evaluator', type: 'evaluator', owner: 'platform-eng', state: 'active', findings: 2, posture: 71, lastActivity: '12s ago' },
  { agent: 'sbom-collector', type: 'collector', owner: 'supply-chain', state: 'revoked', findings: 5, posture: 34, lastActivity: '4h ago' },
  { agent: 'ingest-worker', type: 'worker', owner: 'platform-eng', state: 'active', findings: 0, posture: 96, lastActivity: '3s ago' },
  { agent: 'drift-detector', type: 'detector', owner: 'platform-eng', state: 'active', findings: 1, posture: 88, lastActivity: '41s ago' },
  { agent: 'attestation-signer', type: 'signer', owner: 'supply-chain', state: 'active', findings: 0, posture: 99, lastActivity: '8s ago' },
  { agent: 'credential-rotator', type: 'rotator', owner: 'identity', state: 'enrolled', findings: 0, posture: 62, lastActivity: 'never' },
  { agent: 'egress-auditor', type: 'auditor', owner: 'network', state: 'suspended', findings: 3, posture: 45, lastActivity: '2m ago' },
  { agent: 'mesh-probe', type: 'prober', owner: 'network', state: 'active', findings: 0, posture: 93, lastActivity: '5s ago' },
  { agent: 'log-shipper', type: 'shipper', owner: 'observability', state: 'active', findings: 0, posture: 90, lastActivity: '1s ago' },
  { agent: 'trace-sampler', type: 'sampler', owner: 'observability', state: 'active', findings: 1, posture: 84, lastActivity: '6s ago' },
  { agent: 'quota-reaper', type: 'reaper', owner: 'platform-eng', state: 'active', findings: 0, posture: 78, lastActivity: '30s ago' },
  { agent: 'cert-renewer', type: 'renewer', owner: 'identity', state: 'enrolled', findings: 0, posture: 66, lastActivity: 'never' },
  { agent: 'secret-syncer', type: 'syncer', owner: 'identity', state: 'suspended', findings: 4, posture: 39, lastActivity: '18m ago' },
  { agent: 'image-scanner', type: 'scanner', owner: 'supply-chain', state: 'active', findings: 2, posture: 74, lastActivity: '22s ago' },
]

const FLEET_COLUMNS: Column<FleetRow>[] = [
  { key: 'agent', label: 'Agent', sortable: true },
  { key: 'type', label: 'Type', sortable: true },
  { key: 'owner', label: 'Owner', sortable: true },
  { key: 'state', label: 'State', sortable: true },
  {
    key: 'findings',
    label: 'Open findings',
    sortable: true,
    help: 'Controls this agent currently fails. Zero is a pass, not an absence of data.',
  },
  {
    key: 'posture',
    label: 'Posture',
    sortable: true,
    help: 'Percentage of applicable controls passing. Sorts numerically, so the worst offenders are one click away.',
  },
  { key: 'lastActivity', label: 'Last activity', sortable: true },
]

/** `all` first, then the lifecycle states in the order an agent moves through them. */
const FLEET_STATES = ['all', 'enrolled', 'active', 'suspended', 'revoked'] as const

/** Posture at or above this renders a passing compliance badge. Presentational only. */
const POSTURE_PASS_THRESHOLD = 70

const DONUT_SEGMENTS = [
  { value: 46, color: colors.tealLoom, label: 'Passing' },
  { value: 12, color: colors.amber, label: 'Warning' },
  { value: 5, color: colors.red, label: 'Failing' },
]

const PROOFS: Proof[] = [
  {
    label: 'Identity',
    command: 'kubectl -n signalloom exec deploy/policy-engine -- spire-agent api fetch x509',
    detail: 'SPIFFE ID:\tspiffe://signalloom.svc.cluster.local/ns/signalloom/sa/policy-engine\nSVID Valid After:\t2026-08-13 03:11:04 +0000 UTC\nSVID Valid Until:\t2026-08-13 04:11:04 +0000 UTC',
  },
  {
    label: 'Egress',
    command: 'kubectl -n signalloom exec deploy/policy-engine -- nc -z -w2 api.example.com 443',
    detail: 'nc: connect to api.example.com port 443 (tcp) timed out: Operation now in progress\ncommand terminated with exit code 1',
  },
]

// ── ProofConsole streaming demo ──────────────────────────────────────────────
//
// SIMULATED, AND THAT IS THE POINT. There is no streaming endpoint in this
// backend: no server-sent events route, no `text/event-stream` response, no
// EventSource and no ReadableStream reader anywhere in the app. This section
// exists so the decision to build one can be made from something visible
// rather than from a description, which is why it is on the design-system page
// and nowhere else.
//
// What it simulates is the pattern that DOES exist. `fetchDemoRunLog(runId,
// offset)` returns a `DemoRunLogChunk` and is how the Instructor Controls run
// log fills in today. `pollFixture` below returns that same type — imported,
// not redeclared, so this claim is checked by the compiler rather than
// asserted in a comment — and the hook applies the same append rule: position
// each chunk by its absolute offset instead of concatenating, so a duplicate
// or out-of-order chunk overwrites the bytes it already wrote rather than
// doubling them.

/** How often the fake poll fires. Named so the copy on screen cannot drift from it. */
const POLL_INTERVAL_MS = 350

/**
 * How much the fake poll returns each time.
 *
 * Bytes, not lines, and deliberately not a multiple of the line length: an
 * offset read returns a slice of a file, so partial lines arrive and the last
 * line on screen is often half a line. A fixture that emitted whole lines would
 * be a prettier demo of something that is not what happens.
 */
const BYTES_PER_POLL = 64

const STREAM_COMMAND =
  'kubectl -n signalloom exec deploy/policy-engine -- collect-evidence --step 6 --follow'

const STREAM_FIXTURE = [
  '[evidence] step 6 · platform response to a failed control',
  '[evidence] resolving credential cardvault-agent in ns signalloom',
  '[evidence] ✓ lease found: kv/signalloom/cardvault-agent',
  '[evidence] revoking the lease',
  '[evidence] ✓ bao kv delete returned 204',
  '[evidence] annotating pod agent-cardvault-7d9f4b8c6-x2klm',
  '[evidence] ✓ signalloom.io/state=stunned applied',
  '[evidence] applying networkpolicy deny-cardvault-egress',
  '[evidence] ✓ networkpolicy created',
  '[evidence] re-probing egress from the stunned pod',
  '[evidence] nc: connect to api.example.com port 443 timed out',
  '[evidence] ✓ egress refused, blast radius contained',
  '[evidence] 3 of 3 platform responses verified',
].join('\n')

/** Where the stalled specimen died. Mid-line, because that is where a stream dies. */
const STALLED_DETAIL = STREAM_FIXTURE.slice(0, 268)

/**
 * One fake poll.
 *
 * Typed as `DemoRunLogChunk` on purpose: if the real chunk shape changes, this
 * demo stops compiling instead of quietly documenting a shape the API no longer
 * returns.
 */
function pollFixture(log: string, offset: number): DemoRunLogChunk {
  const next = Math.min(log.length, offset + BYTES_PER_POLL)
  return {
    run_id: 'simulated-there-is-no-run',
    offset,
    next_offset: next,
    chunk: log.slice(offset, next),
    truncated: false,
    eof: next >= log.length,
  }
}

/**
 * Drives the live specimen: polls the fixture on a timer until it reports eof.
 *
 * `replay` bumps a key rather than mutating in place, so a second run starts
 * from a genuinely empty console instead of appending to the first one — the
 * mistake that makes a replayed demo look like it produced twice the output.
 */
function useSimulatedProofStream(log: string): {
  detail: string
  phase: ProofStreamPhase
  replay: () => void
} {
  const [detail, setDetail] = useState('')
  const [phase, setPhase] = useState<ProofStreamPhase>('streaming')
  const [run, setRun] = useState(0)

  useEffect(() => {
    setDetail('')
    setPhase('streaming')
    let offset = 0
    const timer = setInterval(() => {
      const chunk = pollFixture(log, offset)
      offset = chunk.next_offset
      setDetail((prev) => {
        // The real poller's rule, reproduced rather than approximated. A chunk
        // is positioned by its absolute offset: one that starts beyond what we
        // hold is a gap and is dropped (the next poll re-reads from where we
        // are), and one that starts behind is a repeat and overwrites itself
        // instead of appearing twice.
        if (chunk.offset > prev.length) return prev
        return prev.slice(0, chunk.offset) + chunk.chunk
      })
      if (chunk.eof) {
        clearInterval(timer)
        setPhase('complete')
      }
    }, POLL_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [log, run])

  return { detail, phase, replay: () => setRun((n) => n + 1) }
}

const STALLED_PROOF: Proof[] = [
  {
    label: 'Platform response',
    command: STREAM_COMMAND,
    detail: STALLED_DETAIL,
    stream: 'stalled',
    streamNote: 'No output for 45s and the runner stopped answering. The last line is where it stopped, not where it finished.',
  },
]

const disclaimerStyle: CSSProperties = {
  display: 'flex',
  gap: 12,
  alignItems: 'flex-start',
  border: '1px solid var(--amber)',
  borderRadius: 6,
  background: 'color-mix(in srgb, var(--amber) 8%, transparent)',
  padding: '10px 12px',
  marginBottom: 16,
  maxWidth: 820,
  fontSize: 12.5,
  lineHeight: 1.55,
  color: 'var(--muted)',
}

const disclaimerTag: CSSProperties = {
  flexShrink: 0,
  // --text, not --amber, and this one was measured rather than eyeballed.
  // Amber on --surface is 5.60:1 in Dark and 4.80:1 in Light but only 3.82:1 in
  // Andy, which is under AA for a 10px bold word — and this is the single word
  // on the section that most needs to be read rather than scanned. The amber
  // moves to the border, where 3.82:1 clears the 3:1 that non-text UI has to
  // meet, and the word itself is then 17:1 or better in all three themes.
  color: 'var(--text)',
  border: '1px solid var(--amber)',
  borderRadius: 3,
  padding: '1px 7px',
  fontSize: 10,
  fontWeight: 700,
  letterSpacing: '0.08em',
  textTransform: 'uppercase',
}

/** Matches the ButtonWait specimen above: the control must not resize when work starts. */
const REPLAY_BUTTON_STYLE: CSSProperties = {
  minWidth: 132,
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 8,
}

const REVOKED_CREDENTIAL = {
  status: 'revoked' as const,
  reason: 'compliance-failure: securityContext.runAsNonRoot not set',
  revoked_at: '2026-08-12T09:41:00Z',
}

/**
 * Everything under src/components/ that this page does NOT render, and why.
 *
 * An omission with no reason beside it reads as an oversight, and the next
 * person re-litigates it. Two honest categories: components that own a
 * full-screen overlay (rendering one here would cover the gallery), and
 * components that reach for an API client, an auth token or an app context and
 * so cannot be driven by fixed props.
 */
const NOT_SHOWN: { name: string; reason: string }[] = [
  { name: 'Sidebar', reason: 'Needs the router, the auth context and a live failing-controls count; it is the app shell, not a specimen.' },
  { name: 'TopNav', reason: 'Reads the OIDC profile from useAuth0 — renders empty without a signed-in user.' },
  { name: 'AddClusterModal', reason: 'Full-screen overlay. Rendering it here would sit on top of the gallery.' },
  { name: 'ConfirmDialog', reason: 'Full-screen overlay, and meaningless without the destructive action it guards.' },
  { name: 'ConsentModal', reason: 'Full-screen overlay; accepting posts document versions to the consent API.' },
  { name: 'CookieSettingsModal', reason: 'Full-screen overlay; reads and writes cookie preferences through api/client with a bearer token.' },
  { name: 'ApiKeyRevealModal', reason: 'Full-screen overlay driven by AppContext.apiKeyReveal — there is no key to reveal here.' },
  { name: 'ApiKeyRotateModal', reason: 'Full-screen overlay; confirming rotates a real credential.' },
  { name: 'KeyboardShortcutsOverlay', reason: 'Full-screen overlay bound to a global key handler; open it anywhere with "?".' },
  { name: 'HelpModal', reason: 'Full-screen overlay; fetches help content from api/client.' },
  { name: 'DemoToggle / ThemeToggle', reason: 'Position-fixed app-shell controls rendered once by App.tsx. A second copy would overlap the real one.' },
  { name: 'CredentialEvidencePanel', reason: 'Fetches evidence bundles from api/credentialEvidence for a specific credential.' },
  { name: 'RbacImporterPanel', reason: 'Uploads and parses a live RBAC dump through api/afmApi.' },
  { name: 'SuperCredInstructorPanel', reason: 'Drives a live demo runner against a cluster via api/demoRunner.' },
  { name: 'CredentialActionsMenu / TriageMenu', reason: 'Row-anchored popovers whose actions mutate the row they hang off; nothing to anchor to here.' },
  { name: 'OpenFindingsPanel', reason: 'Derives its content from an AgentPosture[] fetched by the posture page — a fake array would document the fake, not the component.' },
  { name: 'fleet/ and trust/ subtrees', reason: 'React Flow and gauge canvases that size themselves from real layout; they belong on their own pages, not in a grid of small boxes.' },
  { name: 'onboarding/ subtree', reason: 'Wizard steps that only make sense in sequence, sharing the wizard’s step state.' },
]

// ── Layout helpers ───────────────────────────────────────────────────────────

const cardStyle: CSSProperties = {
  border: '1px solid var(--border)',
  borderRadius: 6,
  background: 'var(--surface)',
  padding: 14,
}

function Group({
  id,
  title,
  when,
  children,
}: {
  id: string
  title: string
  when: string
  children: ReactNode
}) {
  return (
    <section data-testid={`ds-section-${id}`} style={{ marginBottom: 38 }}>
      {/* The heading carries its own testid because a specimen can bring its
          own h2 along — DashKit's Section does — and a query by role alone
          then matches two headings inside one group. */}
      <h2 data-testid={`ds-heading-${id}`} style={{ fontSize: 16, fontWeight: 700, color: 'var(--text)', margin: '0 0 3px' }}>
        {title}
      </h2>
      <p
        data-testid={`ds-when-${id}`}
        style={{ fontSize: 12.5, color: 'var(--muted)', margin: '0 0 14px', maxWidth: 780, lineHeight: 1.5 }}
      >
        {when}
      </p>
      {children}
    </section>
  )
}

/** A labelled box around one specimen, so it is obvious where it starts and ends. */
function Specimen({
  caption,
  captionTestId,
  badge,
  badgeTestId,
  note,
  children,
  minWidth = 220,
}: {
  caption: string
  captionTestId?: string
  /** A short word in the corner of the caption — "default", and nothing longer. */
  badge?: string
  badgeTestId?: string
  note?: string
  children: ReactNode
  minWidth?: number
}) {
  return (
    <div style={{ ...cardStyle, minWidth, flex: '0 1 auto' }}>
      <div
        data-testid={captionTestId}
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          gap: 8,
          fontSize: 11,
          fontWeight: 600,
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
          color: 'var(--muted)',
          marginBottom: 10,
        }}
      >
        <span>{caption}</span>
        {badge && (
          <span
            data-testid={badgeTestId}
            style={{
              // Cyan on a cyan tint rather than a solid fill: black-on-accent
              // fails contrast in the Andy theme, and this badge has to be
              // legible in all three.
              color: 'var(--cyan)',
              background: 'color-mix(in srgb, var(--cyan) 12%, transparent)',
              border: '1px solid color-mix(in srgb, var(--cyan) 25%, transparent)',
              borderRadius: 3,
              padding: '1px 6px',
              fontSize: 10,
              letterSpacing: '0.05em',
            }}
          >
            {badge}
          </span>
        )}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 10, minHeight: 24 }}>
        {children}
      </div>
      {note && (
        <p style={{ fontSize: 11.5, color: 'var(--muted)', margin: '10px 0 0', lineHeight: 1.45 }}>{note}</p>
      )}
    </div>
  )
}

const rowStyle: CSSProperties = { display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'flex-start' }

/** A boxed aside for a caveat the reader needs before they trust what they see. */
function Caveat({ children }: { children: ReactNode }) {
  return (
    <p
      style={{
        borderLeft: '2px solid var(--amber)',
        paddingLeft: 10,
        margin: '12px 0 0',
        fontSize: 12,
        color: 'var(--muted)',
        lineHeight: 1.5,
        maxWidth: 780,
      }}
    >
      {children}
    </p>
  )
}

/**
 * A heading for one example inside a section that carries several.
 *
 * h3, not h2: `Group` already owns the section's h2, and the page's test asserts
 * the section heading is an H2 found by testid. A second h2 in the same group
 * would make that query ambiguous — the same trap the Group heading's testid was
 * added for.
 */
function ExampleHeading({ id, title, blurb }: { id: string; title: string; blurb: string }) {
  return (
    <>
      <h3 data-testid={`ds-example-heading-${id}`} style={{ fontSize: 13, fontWeight: 700, color: 'var(--text)', margin: '0 0 3px' }}>
        {title}
      </h3>
      <p style={{ fontSize: 12, color: 'var(--muted)', margin: '0 0 12px', maxWidth: 780, lineHeight: 1.5 }}>{blurb}</p>
    </>
  )
}

// ── Page ─────────────────────────────────────────────────────────────────────

export default function DesignSystemPage() {
  // Local, so the interactive specimens are actually interactive rather than
  // frozen screenshots. Nothing here escapes the page.
  const [retryCount, setRetryCount] = useState(0)

  // Search and lifecycle filtering for the complex DataTable specimen. They live
  // here, not in DataTable, and that is the point the specimen is making: the
  // page narrows the array, DataTable sorts and paginates whatever it is given.
  const [fleetSearch, setFleetSearch] = useState('')
  const [fleetState, setFleetState] = useState<(typeof FLEET_STATES)[number]>('all')

  const fleetRows = useMemo(() => {
    const q = fleetSearch.trim().toLowerCase()
    return FLEET_ROWS.filter((row) => {
      if (fleetState !== 'all' && row.state !== fleetState) return false
      if (!q) return true
      return (
        row.agent.toLowerCase().includes(q) ||
        row.owner.toLowerCase().includes(q) ||
        row.type.toLowerCase().includes(q)
      )
    })
  }, [fleetSearch, fleetState])

  // The streaming demo. Starts on mount so the section is showing what it
  // claims to show to anyone who opens the page, and replays on demand for
  // anyone who arrived after it finished.
  const liveStream = useSimulatedProofStream(STREAM_FIXTURE)
  const liveProofs: Proof[] = useMemo(
    () => [
      {
        label: 'Platform response',
        command: STREAM_COMMAND,
        detail: liveStream.detail,
        stream: liveStream.phase,
      },
    ],
    [liveStream.detail, liveStream.phase],
  )

  const fleetStateCounts = useMemo(
    () =>
      Object.fromEntries(
        FLEET_STATES.map((state) => [
          state,
          state === 'all' ? FLEET_ROWS.length : FLEET_ROWS.filter((row) => row.state === state).length,
        ]),
      ) as Record<(typeof FLEET_STATES)[number], number>,
    [],
  )

  return (
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Design System &amp; Component Library</h1>
      <p style={{ color: 'var(--muted)', fontSize: 13, marginTop: 0, marginBottom: 26, maxWidth: 820, lineHeight: 1.55 }}>
        Every shared token and every component that can be rendered from fixed props, in one place, so
        the next page does not reinvent one. Internal and superadmin-only — clarity over polish. Nothing
        below talks to the API: every specimen is driven by constants in this file.
      </p>

      {/* ── Tokens ─────────────────────────────────────────────────────────── */}
      <Group
        id="tokens"
        title="Colour tokens"
        when="Use a token, never a hex. All sixteen switch with the theme, so a literal colour is correct in exactly one of Dark, Light and Andy and wrong in the other two — styles/cssVarUsage.test.ts fails the build for bare hex in inline styles, and for any custom property referenced but declared by no theme."
      >
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
          {CSS_VAR_NAMES.map((name: CssVarName) => (
            <div key={name} data-testid={`ds-token-${name}`} style={{ ...cardStyle, width: 176, padding: 10 }}>
              <div
                style={{
                  height: 34,
                  borderRadius: 4,
                  // Built from CSS_VAR_NAMES itself, so the swatch set cannot fall
                  // behind themes.ts. The interpolation is why cssVarUsage.test.ts
                  // does not see a literal `var(--x)` here — every name in it is
                  // by definition one of the declared ones.
                  background: `var(${name})`,
                  border: '1px solid var(--border-subtle)',
                }}
              />
              <code style={{ display: 'block', fontSize: 11.5, color: 'var(--text)', marginTop: 8 }}>{name}</code>
              <div style={{ marginTop: 6, display: 'grid', gap: 2 }}>
                {THEME_NAMES.map((theme) => (
                  <div key={theme} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10.5, color: 'var(--muted)' }}>
                    <span>{THEME_LABELS[theme]}</span>
                    <code>{THEMES[theme][name]}</code>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </Group>

      {/* ── PixelLoader ────────────────────────────────────────────────────── */}
      <Group
        id="pixel-loader"
        title="PixelLoader"
        when="Use for work long enough that a spinner stops helping — it names what is running and counts elapsed seconds, so a slow step is distinguishable from a hung one. Render it with no variant prop and you get Loom, the default; the other three are alternatives you have to ask for by name. md owns its own line; sm sits inside a 12px one."
      >
        <div style={rowStyle}>
          {LOADER_VARIANTS.map(({ name, blurb, isDefault }) => (
            <Specimen
              key={name}
              caption={name}
              captionTestId={`ds-loader-caption-${name}`}
              badge={isDefault ? 'default' : undefined}
              badgeTestId={isDefault ? 'ds-loader-default-badge' : undefined}
              note={blurb}
              minWidth={260}
            >
              <div style={{ display: 'grid', gap: 12 }}>
                {LOADER_SIZES.map((size) => (
                  <div key={size} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <code style={{ fontSize: 10.5, color: 'var(--dim)', width: 22 }}>{size}</code>
                    {/* announce={false} on every gallery instance — see the file
                        header. The default is true, and nine defaulted loaders
                        is nine simultaneous announcements on page load. */}
                    <PixelLoader
                      variant={name}
                      size={size}
                      label={name}
                      announce={false}
                      testId={`ds-loader-${name}-${size}`}
                    />
                  </div>
                ))}
              </div>
            </Specimen>
          ))}
          {/* The default, demonstrated rather than described. Passing no
              `variant` here is the whole specimen: whatever PixelLoader's
              default is, this is it, and it cannot drift out of step with the
              component the way a sentence can. */}
          <Specimen
            caption="no variant prop"
            captionTestId="ds-loader-caption-default"
            note="Rendered as <PixelLoader label='Churning' /> — no variant passed. Compare it against the Loom specimen: they are the same loader."
            minWidth={260}
          >
            <PixelLoader label="Churning" announce={false} testId="ds-loader-default" />
          </Specimen>
        </div>
        <Caveat>
          Accessibility note, and the reason this page can exist at all: <code>announce</code> defaults
          to <code>true</code>, which is right for a lone loader and wrong for a gallery. All nine
          instances above pass <code>announce={'{false}'}</code>. Pass it whenever the host is already a
          live region — <code>LoadingState</code> does exactly that.
        </Caveat>
      </Group>

      {/* ── ButtonWait ─────────────────────────────────────────────────────── */}
      <Group
        id="button-wait"
        title="ButtonWait"
        when="A wait that happens inside an interactive control. Three constraints come with that position and none of them are negotiable: there is no room for a label, the control must not change size when the work starts, and it must not own a live region — the button already has an accessible name and a disabled state, and a region inside it talks over both."
      >
        <div style={rowStyle}>
          <Specimen
            caption="idle"
            minWidth={260}
            note="The control at rest. Note the width — it is fixed, and the loading state below has to match it."
          >
            <button className="btn btn-secondary" data-testid="ds-buttonwait-idle" style={WAIT_BUTTON_STYLE}>
              Rotate credential
            </button>
          </Specimen>
          <Specimen
            caption="waiting"
            minWidth={260}
            note="Same label, same width, disabled, plus an 8px indicator. Nothing moves; the row around it does not reflow."
          >
            <button
              className="btn btn-secondary"
              data-testid="ds-buttonwait-loading"
              disabled
              style={WAIT_BUTTON_STYLE}
            >
              <ButtonWait testId="ds-buttonwait-indicator" label="Rotating credential" />
              Rotate credential
            </button>
          </Specimen>
        </div>
        <Caveat>
          Which of the three to reach for, and it is decided by where the wait lives rather than by how
          long it lasts.{' '}
          <strong>
            <code>ButtonWait</code>
          </strong>{' '}
          — the wait is inside a control the user just pressed: no label, fixed size, no live region,
          because the button is already the thing being announced.{' '}
          <strong>
            <code>PixelLoader</code>
          </strong>{' '}
          — the wait is a named piece of work in the body of the page: it says what is running and counts
          the seconds, so a slow step is distinguishable from a hung one.{' '}
          <strong>
            <code>LoadingState</code>
          </strong>{' '}
          — the wait is a whole fetch: all four phases including idle and a retryable error, and it owns
          the live region for everything nested inside it.
        </Caveat>
      </Group>

      {/* ── LoadingState ───────────────────────────────────────────────────── */}
      <Group
        id="loading-state"
        title="LoadingState"
        when="The default way to render a fetch. Four phases, and idle is the point: “never loaded” is not the same as “loaded and found nothing”. inline is a strip beside a heading; block is a centred panel for an empty viewport."
      >
        <div style={rowStyle}>
          <Specimen caption="inline · idle" minWidth={300}>
            <LoadingState status="idle" label="agents" testId="ds-loadingstate-inline-idle" />
          </Specimen>
          <Specimen caption="inline · loading" minWidth={300}>
            <LoadingState status="loading" label="agents" testId="ds-loadingstate-inline-loading" />
          </Specimen>
          <Specimen caption="inline · success" minWidth={300}>
            <LoadingState status="success" label="agents" testId="ds-loadingstate-inline-success" />
          </Specimen>
          <Specimen caption="inline · error" minWidth={300} note={`Retry pressed ${retryCount} time(s).`}>
            <LoadingState
              status="error"
              label="agents"
              error="Request failed with status code 502"
              onRetry={() => setRetryCount((n) => n + 1)}
              testId="ds-loadingstate-inline-error"
            />
          </Specimen>
          <Specimen caption="block · loading" minWidth={340}>
            <LoadingState status="loading" label="compliance data" variant="block" testId="ds-loadingstate-block-loading" />
          </Specimen>
          <Specimen caption="block · error" minWidth={340}>
            <LoadingState
              status="error"
              label="compliance data"
              error="upstream evaluator returned no policy set"
              variant="block"
              testId="ds-loadingstate-block-error"
            />
          </Specimen>
        </div>
        <Caveat>
          Six specimens, not more, and that is a budget rather than a coincidence. Unlike PixelLoader,
          LoadingState has no <code>announce</code> opt-out — every instance is a live region by
          construction, and the success and error phases re-render a relative timestamp every second
          inside it. Six is what this page can carry without becoming noise; the test asserts the exact
          count so a seventh has to be a decision. Worth considering giving LoadingState the same
          <code> announce</code> escape hatch PixelLoader already has.
        </Caveat>
      </Group>

      {/* ── ErrorState ─────────────────────────────────────────────────────── */}
      <Group
        id="error-state"
        title="ErrorState"
        when="A whole panel failed and there is nothing to show. isAuthError(message) picks the branch: a 401 gets “Log in”, because retrying a refused request just reproduces the refusal — everything else gets Retry."
      >
        <div style={rowStyle}>
          <div data-testid="ds-errorstate-retry" style={{ ...cardStyle, flex: '1 1 320px' }}>
            <ErrorState message="Evaluator timed out after 30s." onRetry={() => setRetryCount((n) => n + 1)} />
          </div>
          <div data-testid="ds-errorstate-auth" style={{ ...cardStyle, flex: '1 1 320px' }}>
            {/* onLogin is overridden so the specimen cannot navigate the page
                away when someone presses it out of curiosity. */}
            <ErrorState
              message="Request failed with status code 401"
              onLogin={() => setRetryCount((n) => n + 1)}
            />
          </div>
        </div>
      </Group>

      {/* ── EmptyState ─────────────────────────────────────────────────────── */}
      <Group
        id="empty-state"
        title="EmptyState"
        when="The query succeeded and the answer is nothing. Never use it for a failure — a healthy zero and a fetch that never ran must not look alike."
      >
        <div style={rowStyle}>
          <div style={{ ...cardStyle, flex: '1 1 320px' }}>
            <EmptyState kicker="No agents match this filter" body="Clear the namespace filter to see all twelve." />
          </div>
          <div style={{ ...cardStyle, flex: '1 1 320px' }}>
            <EmptyState tone="amber" kicker="No policy set loaded" body="Connect a cluster to evaluate compliance." />
          </div>
        </div>
      </Group>

      {/* ── StatusBadge ────────────────────────────────────────────────────── */}
      <Group
        id="status-badge"
        title="StatusBadge"
        when="One enum value in a table cell. Pass the variant so the colour comes from the right map — without it the lookup falls through every map in order and the first match wins, which is fine until two domains share a word."
      >
        <div style={{ display: 'grid', gap: 10 }}>
          {BADGE_SPECIMENS.map(({ variant, statuses }) => (
            <div key={variant} style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <code style={{ fontSize: 11, color: 'var(--dim)', width: 92 }}>{variant}</code>
              {statuses.map((status) => (
                <StatusBadge key={status} status={status} variant={variant} />
              ))}
            </div>
          ))}
        </div>
      </Group>

      {/* ── HelpHint ───────────────────────────────────────────────────────── */}
      <Group
        id="help-hint"
        title="HelpHint"
        when="A term whose meaning is not in its label. Hover or focus the “?”. It self-places to stay on screen, so it is safe at a viewport edge or inside a scrolling panel. tone recolours only the affordance — a coloured popup would read as an error rather than an explanation."
      >
        <div style={rowStyle}>
          <Specimen caption="default (cyan)" minWidth={220}>
            <span style={{ fontSize: 13, color: 'var(--text)' }}>Blast radius</span>
            <HelpHint label="What blast radius means" testId="ds-hint-default">
              How much of the cluster this identity could reach if it were fully compromised.
            </HelpHint>
          </Specimen>
          <Specimen caption="tone=var(--error)" minWidth={220} note="Tie the hint to a destructive control it sits beside.">
            <span style={{ fontSize: 13, color: 'var(--text)' }}>Revoke credentials</span>
            <HelpHint label="What revoke means" tone="var(--error)" testId="ds-hint-error">
              Immediately invalidates the agent&rsquo;s SVID. In-flight requests fail; there is no undo.
            </HelpHint>
          </Specimen>
          <Specimen caption="tone=var(--amber)" minWidth={220}>
            <span style={{ fontSize: 13, color: 'var(--text)' }}>Modelled, not observed</span>
            <HelpHint label="What modelled means" tone="var(--amber)" testId="ds-hint-amber">
              Derived from configuration rather than seen at runtime. Treat as a hypothesis.
            </HelpHint>
          </Specimen>
        </div>
      </Group>

      {/* ── DataTable ──────────────────────────────────────────────────────── */}
      <Group
        id="data-table"
        title="DataTable"
        when="More rows than fit on a screen, and the reader needs to sort them. Client-side only — it sorts and paginates the array you hand it, so do not give it ten thousand rows. Columns carrying a help string grow a “?” in the header. Two examples below, because the gap between them is where every question about this component actually lives: the minimum that works, and the configuration a real page needs. Both are the same component. There is no separate filtered variant, and the caveat under them says why."
      >
        <div data-testid="ds-datatable-simple-example">
          <ExampleHeading
            id="datatable-simple"
            title="Minimum viable"
            blurb="Four columns, three of them sortable, one page control. This is the whole API surface you need for a table that is just a list — hand it columns, data and a row renderer and stop."
          />
          <DataTable
            columns={TABLE_COLUMNS}
            data={TABLE_ROWS}
            pageSize={10}
            testIdPrefix="ds-datatable"
            renderRow={(row: DemoRow, i: number) => (
              <tr key={`${row.agent}-${i}`} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={DataTable.td}>{row.agent}</td>
                <td style={DataTable.td}>{row.namespace}</td>
                <td style={DataTable.td}>{row.findings}</td>
                <td style={DataTable.td}><StatusBadge status={row.state} variant="lifecycle" /></td>
              </tr>
            )}
          />
        </div>

        <div data-testid="ds-datatable-complex-example" style={{ marginTop: 30 }}>
          <ExampleHeading
            id="datatable-complex"
            title="Realistic — the shape AgentsPage needs"
            blurb="The same component with two more optional props. Seven sortable columns, StatusBadge in two of them, pageSize 5 so the pager is part of the example, and a toolbar slot carrying search and lifecycle chips whose state and predicate still belong to this page. This is what the TODO on AgentsPage.tsx line 3 is asking for, written out."
          />
          <DataTable
            columns={FLEET_COLUMNS}
            data={fleetRows}
            pageSize={5}
            testIdPrefix="ds-datatable-complex"
            // The advanced form, and it is the same component with two more
            // optional props rather than a second component. `toolbar` is a
            // slot: the search state, the chips and the predicate all still
            // live in this page, and DataTable is handed an already-narrowed
            // array. What it owns is the position of the strip and — the part
            // worth having — the guarantee that the strip outlives the table
            // when a filter matches nothing.
            toolbar={
              <div
                style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
                role="group"
                aria-label="Filter the DataTable example"
              >
                <input
                  type="search"
                  aria-label="Search the DataTable example"
                  placeholder="Search agent, type or owner…"
                  value={fleetSearch}
                  onChange={(e) => setFleetSearch(e.target.value)}
                  data-testid="ds-datatable-complex-search"
                  style={{
                    fontSize: 12,
                    padding: '5px 9px',
                    minWidth: 230,
                    color: 'var(--text)',
                    background: 'var(--surface2)',
                    border: '1px solid var(--border)',
                    borderRadius: 4,
                  }}
                />
                {FLEET_STATES.map((state) => {
                  const selected = fleetState === state
                  return (
                    <button
                      key={state}
                      type="button"
                      onClick={() => setFleetState(state)}
                      aria-pressed={selected}
                      data-testid={`ds-datatable-complex-filter-${state}`}
                      style={{
                        fontSize: 11.5,
                        padding: '4px 9px',
                        borderRadius: 4,
                        cursor: 'pointer',
                        // Selected is a tinted fill plus a full-strength border, not
                        // a solid accent fill: text on solid amber or cyan fails AA
                        // in at least one of the three themes.
                        color: selected ? 'var(--cyan)' : 'var(--muted)',
                        background: selected ? 'color-mix(in srgb, var(--cyan) 12%, transparent)' : 'var(--surface2)',
                        border: `1px solid ${selected ? 'color-mix(in srgb, var(--cyan) 45%, transparent)' : 'var(--border)'}`,
                      }}
                    >
                      {state} <span style={{ color: 'var(--dim)' }}>{fleetStateCounts[state]}</span>
                    </button>
                  )
                })}
                <span data-testid="ds-datatable-complex-count" style={{ fontSize: 11.5, color: 'var(--muted)' }}>
                  {fleetRows.length} of {FLEET_ROWS.length} shown
                </span>
              </div>
            }
            emptyState={
              <EmptyState
                kicker="Nothing matches that search"
                body="Clear the search box or pick a different lifecycle state."
              />
            }
            renderRow={(row: FleetRow, i: number) => (
              <tr
                key={`${row.agent}-${i}`}
                data-testid="ds-datatable-complex-row"
                style={{ borderBottom: '1px solid var(--border)' }}
              >
                <td style={DataTable.td}>{row.agent}</td>
                <td style={DataTable.td}>{row.type}</td>
                <td style={DataTable.td}>{row.owner}</td>
                <td style={DataTable.td}><StatusBadge status={row.state} variant="lifecycle" /></td>
                <td style={DataTable.td}>{row.findings}</td>
                <td style={DataTable.td}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                    <span>{row.posture}%</span>
                    <StatusBadge
                      status={row.posture >= POSTURE_PASS_THRESHOLD ? 'pass' : 'fail'}
                      variant="compliance"
                    />
                  </span>
                </td>
                <td style={DataTable.td}>{row.lastActivity}</td>
              </tr>
            )}
          />
        </div>

        <Caveat>
          <strong>One component, not two.</strong> The two specimens above differ in configuration, not
          in kind: same <code>DataTable</code>, and the second one passes two optional props the first
          one omits. There is no <code>DataTableFiltered</code> and there should not be one. What
          genuinely differs between a plain table and a filtered one is the predicate, and the predicate
          is the one thing that can never be shared. AgentsPage searches name, owner and type;
          CredentialInventoryPage filters on a status computed against the clock. A component that owned
          &ldquo;search&rdquo; would hand every caller one opinion about a word they each define
          differently, and the escape hatch for the callers it did not fit would be a prop that switches
          it off, which is two behaviors in one component: exactly where a fork lands, only later.
        </Caveat>
        <Caveat>
          <strong>So what the props share is the chrome and one bug.</strong> <code>toolbar</code> is a
          slot that positions the strip identically on every table and reads none of it; the page still
          owns the state and hands down an already-narrowed array. <code>emptyState</code> replaces the
          table when nothing matches. Passing both is what fixes the bug, and the bug is the reason this
          is a prop rather than something a page stacks by hand: write{' '}
          <code>rows.length === 0 ? &lt;EmptyState/&gt; : &lt;DataTable/&gt;</code> and the filter control
          that emptied the table disappears with it, leaving the user no way to undo it short of a
          reload. Inside DataTable the toolbar renders on the empty branch by construction, so a caller
          cannot get it wrong. Try it: search this example for something that matches nothing. The one
          thing DataTable already owned across that boundary is the page reset, which changes the array
          length under it and returns to page 1 by itself.
        </Caveat>
      </Group>

      {/* ── DonutChart ─────────────────────────────────────────────────────── */}
      <Group
        id="donut-chart"
        title="DonutChart"
        when="A single proportion worth reading at a glance — three or four segments, no more. Hand-rolled SVG, no charting dependency; reach for Recharts only when you need axes."
      >
        <div style={rowStyle}>
          <Specimen caption="63 controls" minWidth={200}>
            <DonutChart segments={DONUT_SEGMENTS} label="63" sublabel="controls" />
          </Specimen>
          <Specimen caption="size=100" minWidth={200}>
            <DonutChart segments={DONUT_SEGMENTS} label="74%" sublabel="passing" size={100} />
          </Specimen>
        </div>
      </Group>

      {/* ── ProofConsole ───────────────────────────────────────────────────── */}
      <Group
        id="proof-console"
        title="ProofConsole"
        when="Show the command and its verbatim output, so a claim on screen can be checked rather than believed. One proof renders bare; several grow a tab strip."
      >
        <ProofConsole proofs={PROOFS} testId="ds-proof-console" />
      </Group>

      {/* ── ProofConsole streaming demo ────────────────────────────────────── */}
      <Group
        id="streaming-proof"
        title="ProofConsole streaming demo"
        when="What an incrementally filled proof looks like, shown here so the choice to build one can be made from something visible. A finished proof and a half-collected one are different claims and must not render alike, so Proof.stream says which. It is optional: omit it and the console renders exactly what it always did, which is what every current caller gets."
      >
        <div data-testid="ds-stream-disclaimer" style={disclaimerStyle}>
          <span style={disclaimerTag}>Simulated</span>
          <div>
            <strong style={{ color: 'var(--text)' }}>
              There is no streaming endpoint in this backend.
            </strong>{' '}
            No server-sent events route, no <code>text/event-stream</code> response, no{' '}
            <code>EventSource</code> and no <code>ReadableStream</code> reader anywhere in the app. The
            console below is filled by a fixture in this file that hands out {BYTES_PER_POLL}-byte slices
            of a fixed string every {POLL_INTERVAL_MS}ms. Nothing here reaches the network.
            <br />
            <br />
            What it simulates is the pattern that does exist and is already in production:{' '}
            <strong style={{ color: 'var(--text)' }}>offset polling</strong>.{' '}
            <code>fetchDemoRunLog(runId, offset)</code> in <code>src/api/demoRunner.ts</code> returns{' '}
            <code>{'{ offset, next_offset, chunk, eof }'}</code> and is how the Instructor Controls run
            log fills in today. The fixture returns that same <code>DemoRunLogChunk</code> type, so the
            cadence you are watching is the cadence a real implementation would have, and the append rule
            is the same one: each chunk is positioned by its absolute offset rather than concatenated, so
            a duplicate or out-of-order chunk overwrites itself instead of doubling.
          </div>
        </div>

        <div data-testid="ds-stream-live-example">
          <ExampleHeading
            id="stream-live"
            title="Streaming, then complete"
            blurb="Press Replay to watch it fill again. While the stream is open the console carries the house wait treatment, PixelLoader at sm in the default Loom variant, which counts elapsed seconds; a stream that has produced nothing for ninety seconds is probably not going to, and the figure is the thing that tells you. The Replay control is disabled and carries a ButtonWait while the run is live, because a wait inside a control the user just pressed is that component and not this one."
          />
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
            <button
              type="button"
              className="btn btn-secondary"
              data-testid="ds-stream-replay"
              disabled={liveStream.phase === 'streaming'}
              onClick={liveStream.replay}
              style={REPLAY_BUTTON_STYLE}
            >
              {liveStream.phase === 'streaming' && (
                <ButtonWait testId="ds-stream-replay-wait" label="Collecting proof" />
              )}
              Replay
            </button>
            <span data-testid="ds-stream-phase" style={{ fontSize: 11.5, color: 'var(--muted)' }}>
              phase: <code>{liveStream.phase}</code>
            </span>
          </div>
          {/* announce: this is the console the reader is waiting on, so it is
              the one that gets the region. See the caveat below. */}
          <ProofConsole proofs={liveProofs} testId="ds-stream-live" announce />
        </div>

        <div data-testid="ds-stream-stalled-example" style={{ marginTop: 26 }}>
          <ExampleHeading
            id="stream-stalled"
            title="Stalled"
            blurb="The state a happy-path demo hides, and the one that decides whether this is safe to ship. Output stopped arriving and the run never finished, so the console says Stopped in words rather than by a caret that quietly went missing, and it says what it knows about why. The bytes on screen are real output; they are just not all of it."
          />
          <ProofConsole proofs={STALLED_PROOF} testId="ds-stream-stalled" />
        </div>

        <Caveat>
          <strong>Live regions, and this is the part that decides whether streaming is safe on a real
          page.</strong> An auto-appending console is the worst case: every chunk is a DOM change, and a
          region wrapped around the log body reads the run out loud line by line over whatever the user
          was doing. So the body is never a live region under any setting. What <code>announce</code>{' '}
          opts into is one polite region carrying the phase sentence alone. It is visually hidden, because
          the loader and the status word already say it to anyone who can see them. It sits beside the
          status row rather than around it, because PixelLoader rewrites its elapsed figure ten times a
          second and a region around that would announce ten times a second. And it is mounted from the
          first render rather than created on completion, because a region born at the same instant as
          its content is announced unreliably or not at all.
        </Caveat>
        <Caveat>
          <code>announce</code> defaults to <strong>false</strong>, so CredentialEvidencePanel and the
          Credential Inventory page are untouched. The live specimen above passes it; the stalled one does
          not, because a frozen specimen has nothing to announce. Net effect on this page is exactly one
          new region, taking the roster from seven to eight, and the eighth is named in the test rather
          than counted.
        </Caveat>
        <Caveat>
          <strong>Before wiring this into a page, note what already exists.</strong>{' '}
          <code>StreamingLogBlock</code> is the heavier treatment of the same problem: line numbers so a
          room can be pointed at a line, a 200-line bound on the DOM, a Copy button that hands over the
          raw untailed bytes, and a caret at the live edge. <code>SuperCredInstructorPanel</code> already
          drives it from <code>fetchDemoRunLog</code>, which is the working proof that the offset-polling
          path is enough. Streaming a ProofConsole is for the short case: a handful of lines that are
          evidence for one claim. A full multi-thousand-line run log wants the block, not this. Choosing
          this component for that job is the mistake this note exists to prevent.
        </Caveat>
      </Group>

      {/* ── CredentialStateNotice ──────────────────────────────────────────── */}
      <Group
        id="credential-state-notice"
        title="CredentialStateNotice"
        when="Says why an agent cannot authenticate, next to the agent. Renders nothing at all when the state is absent — absent is not the same as fine, and inventing “active” would be a lie."
      >
        <div style={rowStyle}>
          <Specimen caption="revoked · panel" minWidth={340}>
            <CredentialStateNotice credentialState={REVOKED_CREDENTIAL} agentName="sbom-collector" variant="panel" />
          </Specimen>
          <Specimen caption="active · inline" minWidth={220}>
            <CredentialStateNotice credentialState={{ status: 'active' }} />
          </Specimen>
        </div>
        <Caveat>
          Found by building this page: the revoked branch is a live region
          (<code>role=&quot;status&quot;</code>, <code>aria-live=&quot;polite&quot;</code>) with a
          hard-coded <code>data-testid</code> and no way to switch either off. That is the right default
          — on the audience window the notice appears with no user action, so it has to announce itself —
          but it means the specimen above is the seventh live region on this page, and two of these in
          one table would announce twice. Same escape hatch as PixelLoader&rsquo;s{' '}
          <code>announce</code> would fix it. The page&rsquo;s test asserts the full live-region roster
          by name, so this is counted rather than tolerated.
        </Caveat>
      </Group>

      {/* ── DashKit ────────────────────────────────────────────────────────── */}
      <Group
        id="dash-kit"
        title="DashKit"
        when="Presentational primitives for the mock trust dashboards — Pill, StatCard, Section and Table. Use DataTable instead when rows need sorting or pagination; DashKit's Table is a static one."
      >
        <div style={{ ...rowStyle, marginBottom: 14 }}>
          <StatCard label="Federated services" value="14" sub="across 3 trust domains" accent={colors.cyanLoom} />
          <StatCard label="Degraded" value="2" sub="mesh probe failing" accent={colors.amber} />
          <StatCard label="Blocked" value="1" sub="policy denied egress" accent={colors.red} />
        </div>
        <Specimen caption="Pill" minWidth={320} note="Pill takes the label itself and colours it by a lookup — an unknown label falls back to muted rather than throwing.">
          {['active', 'degraded', 'blocked', 'pending', 'unknown-label'].map((label) => (
            <Pill key={label} label={label} />
          ))}
        </Specimen>
        <div style={{ marginTop: 16 }}>
          <DashSection title="Trust domains (example)" hint="static table, no sorting">
            <DashTable headers={['Domain', 'Services', { label: 'Posture', help: 'Worst posture across the services in this domain.' }]}>
              <tr style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={dashTd}>signalloom.svc.cluster.local</td>
                <td style={dashTd}>9</td>
                <td style={dashTd}><Pill label="healthy" /></td>
              </tr>
              <tr>
                <td style={dashTd}>supply-chain.svc.cluster.local</td>
                <td style={dashTd}>5</td>
                <td style={dashTd}><Pill label="degraded" /></td>
              </tr>
            </DashTable>
          </DashSection>
        </div>
        <Caveat>
          Known defect, surfaced by putting these side by side: <code>DashKit.hex()</code> concatenates
          an alpha suffix onto its argument, but the <code>PILL</code> map now holds{' '}
          <code>var(--teal)</code>-style tokens rather than hex literals — so the background computes to{' '}
          <code>var(--teal)1f</code>, which is not a colour, and every Pill above renders with no fill at
          all. The text colour is unaffected, which is why it has gone unnoticed. Fixing it belongs in
          DashKit, not here; <code>StatusBadge.tint()</code> shows the working pattern
          (<code>color-mix</code>).
        </Caveat>
      </Group>

      {/* ── Coverage ledger ────────────────────────────────────────────────── */}
      <Group
        id="not-shown"
        title="Not shown on this page"
        when="What the gallery leaves out, and why. A component library page that silently omits half the library is worse than one that admits what it could not render — these are the components that need an overlay, a router, an auth token or a live API to mean anything."
      >
        <div style={{ ...cardStyle, padding: 0, overflow: 'hidden' }}>
          {NOT_SHOWN.map(({ name, reason }, i) => (
            <div
              key={name}
              data-testid={`ds-skipped-${name.split(' ')[0]}`}
              style={{
                display: 'flex',
                gap: 14,
                padding: '9px 14px',
                fontSize: 12.5,
                lineHeight: 1.5,
                borderTop: i === 0 ? undefined : '1px solid var(--border)',
              }}
            >
              <code style={{ color: 'var(--text)', flex: '0 0 230px' }}>{name}</code>
              <span style={{ color: 'var(--muted)' }}>{reason}</span>
            </div>
          ))}
        </div>
      </Group>
    </div>
  )
}
