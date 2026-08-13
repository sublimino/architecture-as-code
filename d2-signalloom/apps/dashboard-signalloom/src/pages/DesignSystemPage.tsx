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
 *    true, and eight defaulted loaders is a screen reader reading eight
 *    simultaneous "Churning" announcements at anyone who opens this page. The
 *    six LoadingState specimens do own regions, because LoadingState has no
 *    `announce` opt-out; six is a deliberate ceiling, asserted exactly in the
 *    test rather than left to drift. See the note rendered in that section.
 *
 * 2. COLOURS. styles/cssVarUsage.test.ts forbids bare hex in inline styles and
 *    forbids referencing a `var(--x)` that no theme declares. The swatches below
 *    are built from CSS_VAR_NAMES itself rather than a hand-kept list, so the
 *    palette here cannot fall behind themes.ts, and the hex values shown are
 *    read from THEMES — displayed as text, never as a style value.
 */
import { useState, type CSSProperties, type ReactNode } from 'react'
import PixelLoader, { type PixelLoaderVariant } from '../components/PixelLoader'
import LoadingState from '../components/LoadingState'
import ErrorState from '../components/ErrorState'
import EmptyState from '../components/EmptyState'
import StatusBadge from '../components/StatusBadge'
import HelpHint from '../components/HelpHint'
import DataTable, { type Column } from '../components/DataTable'
import DonutChart from '../components/DonutChart'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import CredentialStateNotice from '../components/CredentialStateNotice'
import { Pill, StatCard, Section as DashSection, Table as DashTable, td as dashTd } from '../components/DashKit'
import { colors } from '../styles/tokens'
import { CSS_VAR_NAMES, THEMES, THEME_LABELS, THEME_NAMES, type CssVarName } from '../styles/themes'

// ── Loader gallery ───────────────────────────────────────────────────────────

/**
 * The loader variants, by name.
 *
 * `Loom` is being added to PixelLoader in a parallel branch and does not exist
 * in this file's copy of `PixelLoaderVariant` yet. Naming it as a plain string
 * and widening at the call site (see `asVariant`) keeps this file compiling both
 * before and after that lands, and needs no edit when it does. Until it lands,
 * PixelLoader falls back to its Drive pattern for an unknown name — so the
 * specimen renders and is labelled Loom, it just animates as Drive for now.
 */
const LOADER_VARIANTS: readonly { name: string; blurb: string }[] = [
  { name: 'Drive', blurb: 'Square cells, chevron wavefront driving right. The default.' },
  { name: 'Dots', blurb: 'The same wavefront with circular cells. Softer beside body text.' },
  { name: 'Orbit', blurb: 'A comet lapping the perimeter; the centre cell stays dark.' },
  { name: 'Loom', blurb: 'Low-fi animation of the Signal Loom woven-diamond mark.' },
]

const LOADER_SIZES = ['sm', 'md'] as const

/**
 * Widen a name to the variant union.
 *
 * A downcast from `string`, not a cross-cast from a literal — so a name the
 * union does not yet carry (`Loom`) is accepted today without `@ts-expect-error`
 * and without this file having to be touched the moment it is added.
 */
function asVariant(name: string): PixelLoaderVariant {
  return name as PixelLoaderVariant
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
  note,
  children,
  minWidth = 220,
}: {
  caption: string
  captionTestId?: string
  note?: string
  children: ReactNode
  minWidth?: number
}) {
  return (
    <div style={{ ...cardStyle, minWidth, flex: '0 1 auto' }}>
      <div
        data-testid={captionTestId}
        style={{
          fontSize: 11,
          fontWeight: 600,
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
          color: 'var(--muted)',
          marginBottom: 10,
        }}
      >
        {caption}
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

// ── Page ─────────────────────────────────────────────────────────────────────

export default function DesignSystemPage() {
  // Local, so the interactive specimens are actually interactive rather than
  // frozen screenshots. Nothing here escapes the page.
  const [retryCount, setRetryCount] = useState(0)

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
        when="Use for work long enough that a spinner stops helping — it names what is running and counts elapsed seconds, so a slow step is distinguishable from a hung one. md owns its own line; sm sits inside a 12px one."
      >
        <div style={rowStyle}>
          {LOADER_VARIANTS.map(({ name, blurb }) => (
            <Specimen
              key={name}
              caption={name}
              captionTestId={`ds-loader-caption-${name}`}
              note={blurb}
              minWidth={260}
            >
              <div style={{ display: 'grid', gap: 12 }}>
                {LOADER_SIZES.map((size) => (
                  <div key={size} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <code style={{ fontSize: 10.5, color: 'var(--dim)', width: 22 }}>{size}</code>
                    {/* announce={false} on every gallery instance — see the file
                        header. The default is true, and eight defaulted loaders
                        is eight simultaneous announcements on page load. */}
                    <PixelLoader
                      variant={asVariant(name)}
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
        </div>
        <Caveat>
          Accessibility note, and the reason this page can exist at all: <code>announce</code> defaults
          to <code>true</code>, which is right for a lone loader and wrong for a gallery. All eight
          instances above pass <code>announce={'{false}'}</code>. Pass it whenever the host is already a
          live region — <code>LoadingState</code> does exactly that.
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
        when="More rows than fit on a screen, and the reader needs to sort them. Client-side only — it sorts and paginates the array you hand it, so do not give it ten thousand rows. Columns carrying a help string grow a “?” in the header."
      >
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
