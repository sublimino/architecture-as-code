/**
 * Credential Inventory — the canonical operator view of every workload identity
 * on the platform and the credentials minted from it.
 *
 * Extracted from the SuperCred demo page, where it was the strongest section
 * but was reachable only by walking a demo. Here it is a first-class superadmin
 * surface with a real data path.
 *
 * ## Data path
 *
 *  1. `GET /supercred-api/agents` — live pod discovery through the integration
 *     proxy. Namespace + `spec.serviceAccountName` yield the real SPIFFE ID
 *     SPIRE's k8s workload registrar issues.
 *  2. `GET /api/health/crypto` — the live SPIFFE→OpenBao proof Jobs. A failed
 *     positive proof marks the OpenBao lease failed instead of green.
 *  3. Repo manifests (via `credentialInventory.ts`) supply the OpenBao role and
 *     policy binding, which pod metadata cannot know.
 *  4. Demo fixtures — only when demo mode is on, or the live path is down. The
 *     source banner and per-row provenance tags say which is in play.
 *
 * Nothing here is presented as measured unless it was measured; see the
 * provenance discussion in `credentialInventory.ts`.
 *
 * ## Filtering
 *
 * Both tables carry the same three controls — search, lifecycle, provenance —
 * in DataTable's `toolbar` slot, and both hand DataTable an already-narrowed
 * array. Two rules hold across them:
 *
 *  - A filter narrows the TABLE and nothing else. The summary cards, the
 *    unregistered banner and the proof console keep reading the full set,
 *    because a headline count that moved when someone typed in a search box
 *    would be misreporting the estate.
 *  - A filter matching nothing is always undoable. The toolbar renders on
 *    DataTable's empty branch by construction, so the control that emptied the
 *    table cannot disappear along with the rows.
 */
import { useState, useEffect, useCallback, useMemo, type CSSProperties, type ReactNode } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import { LIVE_POLL_MS } from '../api/pollInterval'
import DataTable, { type Column } from '../components/DataTable'
import EmptyState from '../components/EmptyState'
import HelpHint from '../components/HelpHint'
import LoadingState from '../components/LoadingState'
import StatusBadge from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { colors } from '../styles/tokens'
import {
  TRUST_DOMAIN,
  CONFIG_REGISTRATION_ENTRIES,
  DEMO_REGISTRATION_ENTRIES,
  deriveEntriesFromAgents,
  mergeEntries,
  credentialsForEntry,
  summariseCredentials,
  effectiveStatus,
  type CredentialRecord,
  type CredentialStatus,
  type IdentityState,
  type Provenance,
  type RegistrationEntry,
  type RuntimeAgentIdentity,
} from '../data/credentialInventory'

// Same endpoint SuperCredPage uses — see the routing note on its SUPERCRED_API
// constant for why this is not under /api/.
const SUPERCRED_API = '/supercred-api'

/** The proof that asserts a correct SPIFFE identity CAN reach OpenBao. */
const POSITIVE_PROOF = 'bao-spire-positive-proof'

type SourceMode = 'live' | 'demo'

interface LoadedState {
  entries: RegistrationEntry[]
  source: SourceMode
  /** Why the live path was abandoned, when it was. */
  reason: string | null
  baoExchangeProven?: boolean
  /**
   * The calls this page actually made, and what they answered.
   *
   * The provenance banner says "Live" or "Demo data" — a summary of a data path
   * the reader has to take on trust. The same standard the Credential Lifecycle
   * card is held to applies here: an engineer must be able to open the claim,
   * read the literal request behind it, and rerun it. Recorded during the load
   * so it reports what happened, not what was supposed to happen.
   */
  proofs: Proof[]
}

// ─── Presentation ───────────────────────────────────────────────────────────

// Local, and deliberately not DashKit's `td`: that one carries
// `whiteSpace: 'nowrap'`, and the Scope column here is a long OpenBao path that
// has to wrap. The header row is DashKit's, which is where the duplication
// actually mattered.
const td: CSSProperties = { padding: '9px 14px', fontSize: 13, color: 'var(--text)' }

/**
 * Columns for the Workload Identities table.
 *
 * DataTable, not DashKit's static Table, and the filter below is what changed
 * the answer. The old note here argued that two-to-six rows do not need sorting
 * or pagination, which was true and still is — `hidePaginationWhenSinglePage`
 * keeps the pager away. What a static table cannot do is carry a `toolbar`, and
 * the moment this table gained a filter the hand-rolled arrangement became the
 * exact bug DataTable's `toolbar`/`emptyState` pair exists to prevent: the
 * EmptyState here used to sit AFTER `</Table>`, so a filter matching nothing
 * would have stranded the reader with no control to undo it. Adding a filter to
 * a DashKit Table would have meant changing DashKit, which is shared.
 *
 * Three columns carry a hint, and each is a term whose meaning is not in its
 * label:
 *
 *  - Selectors describes a mechanism rather than a value, and it is the
 *    mechanism the whole page rests on.
 *  - Source is the most load-bearing distinction on the page — measured versus
 *    declared — and its three values are slugs, not sentences. The per-row
 *    badge carries a `title`, but that only reaches a reader who already
 *    suspects the row.
 *  - State reads as self-evident and is not. "pending" here means the manifests
 *    never asked for this identity, so no SVID was ever issued; read as "still
 *    starting up" it says the opposite of what it means.
 *
 * The rest — SPIFFE ID, Workload, OpenBao role, Policy path — either name
 * themselves or are already explained by the badge titles in their cells.
 */
const IDENTITY_COLUMNS: Column<RegistrationEntry>[] = [
  { key: 'spiffeId', label: 'SPIFFE ID', sortable: true },
  { key: 'workload', label: 'Workload', sortable: true },
  {
    key: 'selectors',
    label: 'Selectors',
    help: 'What SPIRE checks about a running pod before it will hand that pod an identity — here, its namespace and its Kubernetes service account. A workload that does not match cannot obtain the credential even if it knows the name of it.',
  },
  { key: 'baoRole', label: 'OpenBao role', sortable: true },
  { key: 'baoPolicyPath', label: 'Policy path', sortable: true },
  {
    key: 'provenance',
    label: 'Source',
    sortable: true,
    help: 'How this row got here. "live" — the pod was observed running in the cluster. "config" — the SPIRE/OpenBao manifests declare this identity, but nothing on this page has seen it running. "demo" — fixture data, because the live path was unavailable. Only a live row was measured; the other two are claims about intent.',
  },
  {
    key: 'state',
    label: 'State',
    sortable: true,
    help: 'Whether this identity can be used right now. "active" — declared, and a credential can be minted from it. "revoked" — the platform withdrew it, so every credential minted from it is dead. "pending" — the manifests do not declare this identity at all, so no SVID was ever issued for it. Pending is not a workload that is about to start.',
  },
]

/**
 * The shared button, shrunk. `.btn .btn-secondary` brings the themed fill,
 * border and the measured focus ring; only the size is local, exactly as
 * DataTable's pagination controls do it. The bespoke transparent button this
 * replaces had no focus treatment of its own beyond the global fallback.
 */
const PROOF_BUTTON: CSSProperties = { fontSize: 11, padding: '3px 10px', marginTop: 8 }

const PROVENANCE_HINT: Record<Provenance, string> = {
  live: 'Observed in-cluster via agent discovery',
  config: 'Declared in the SPIRE/OpenBao manifests — registration expected, not observed',
  demo: 'Fixture data — the live path was unavailable',
}


interface StatHelp {
  /** Must contain the words it explains — see ToolbarSelect on WCAG 2.5.3. */
  label: string
  testId: string
  text: string
}

function StatCard({ label, value, sub, accent, testId, help }: {
  label: string; value: string; sub: string; accent: string; testId: string
  /**
   * A hint on the SUB-LINE, not the card title.
   *
   * The one figure on this page that hides a threshold is "expiring within
   * 15m", and 15 is a number the reader has no way to derive. It also decides
   * a colour twelve rows further down — the Expires cell turns amber over the
   * same boundary — so explaining it here is what makes that colour legible.
   * The Expires column header itself stays bare: a "?" restating "Expires"
   * would be noise, which is the standing rule this page's tests enforce.
   */
  help?: StatHelp
}) {
  return (
    <div className="card" style={{ flex: 1, minWidth: 170, padding: '16px 18px' }}>
      <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>{label}</div>
      <div data-testid={testId} style={{ fontSize: 26, fontWeight: 700, color: accent, lineHeight: 1 }}>{value}</div>
      <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
        {sub}
        {help && (
          <HelpHint label={help.label} testId={help.testId} tone={accent}>{help.text}</HelpHint>
        )}
      </div>
    </div>
  )
}

// ─── Filter toolbar ─────────────────────────────────────────────────────────

/**
 * ONE FILTER VOCABULARY, BOTH TABLES.
 *
 * The two tables here describe the same subject at two altitudes — an identity,
 * and the credentials minted from it — so a reader who learns the controls on
 * one has learned them on the other. Both get the same four things in the same
 * order: free-text search, the lifecycle select, the provenance select, then a
 * count and a clear. Nothing is a filter on one table and a sort on the other.
 *
 * They live in DataTable's `toolbar` slot rather than in the section heading
 * where the status select used to sit, and that is the whole point of the move:
 * DataTable renders the toolbar on the empty branch by construction, so a
 * filter that matches nothing cannot take away the control that would undo it.
 * The predicate stays here — each table hands DataTable an already-narrowed
 * array, exactly as the Design System's "Realistic" specimen does.
 */
const TOOLBAR_CONTROL: CSSProperties = {
  fontSize: 12,
  padding: '5px 9px',
  color: 'var(--text)',
  background: 'var(--surface2)',
  border: '1px solid var(--border)',
  borderRadius: 4,
  fontFamily: 'inherit',
}

const IDENTITY_STATE_OPTIONS: ReadonlyArray<'all' | IdentityState> = ['all', 'active', 'revoked', 'pending']
const CREDENTIAL_STATUS_OPTIONS: ReadonlyArray<'all' | CredentialStatus> = ['all', 'active', 'expired', 'revoked', 'failed', 'pending']
const SOURCE_OPTIONS: ReadonlyArray<'all' | Provenance> = ['all', 'live', 'config', 'demo']

/** Search has no visible label, which is why it needs an `aria-label` at all. */
function ToolbarSearch({ label, placeholder, value, onChange, testId }: {
  label: string; placeholder: string; value: string
  onChange: (next: string) => void; testId: string
}) {
  return (
    <input
      type="search"
      aria-label={label}
      placeholder={placeholder}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      data-testid={testId}
      style={{ ...TOOLBAR_CONTROL, minWidth: 230 }}
    />
  )
}

/**
 * A select whose visible word is inside its accessible name, on purpose.
 *
 * An `aria-label` REPLACES the wrapping `<label>`'s text as the accessible
 * name, so "Filter identities by state" has to contain the visible "State" or a
 * speech-input user saying "State" reaches nothing. That is WCAG 2.5.3, and it
 * is the invariant components/sidebarLabelInName.test.tsx exists to catch — the
 * name is composed rather than written out so it cannot drift from the label.
 */
function ToolbarSelect({ label, subject, value, options, onChange, testId }: {
  label: string
  subject: string
  value: string
  options: readonly string[]
  onChange: (next: string) => void
  testId: string
}) {
  return (
    <label style={{ fontSize: 12, color: 'var(--muted)', display: 'flex', alignItems: 'center', gap: 6 }}>
      {label}
      <select
        data-testid={testId}
        aria-label={`Filter ${subject} by ${label.toLowerCase()}`}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={TOOLBAR_CONTROL}
      >
        {options.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </label>
  )
}

/**
 * The count, and the escape hatch beside it.
 *
 * "Clear filters" appears only while something is filtered, which is the one
 * conditional-control pattern DataTable's own notes permit: it is conditioned
 * on the OTHER controls' values, never on its own, so using it cannot make it
 * vanish in a state the user then cannot leave. It renders inside the toolbar,
 * which means it survives on the empty branch — undoing a filter that matched
 * nothing is one click from the panel that says nothing matched.
 */
function ToolbarCount({ shown, total, noun, onClear, testId }: {
  shown: number; total: number; noun: string
  onClear: (() => void) | null; testId: string
}) {
  return (
    <>
      <span data-testid={testId} style={{ fontSize: 11.5, color: 'var(--muted)' }}>
        {shown} of {total} {noun} shown
      </span>
      {onClear && (
        <button
          type="button"
          className="btn btn-secondary"
          onClick={onClear}
          data-testid={`${testId}-clear`}
          style={{ fontSize: 11, padding: '3px 10px' }}
        >
          Clear filters
        </button>
      )}
    </>
  )
}

/** The strip itself, so both tables are spaced and grouped identically. */
function Toolbar({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div
      role="group"
      aria-label={label}
      style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}
    >
      {children}
    </div>
  )
}

/** Absolute timestamps only — a relative "in 4 minutes" goes stale in a screenshot. */
function shortTime(iso: string): string {
  return iso.replace('T', ' ').replace(/\.\d+Z$/, 'Z')
}

// ─── Page ───────────────────────────────────────────────────────────────────

export default function CredentialInventoryPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [state, setState] = useState<LoadedState | null>(null)
  // Two tables, the same three controls each. Kept as six pieces of page state
  // rather than one object because DataTable is handed an already-narrowed
  // array per table and the two narrowings share nothing but their shape.
  const [identitySearch, setIdentitySearch] = useState('')
  const [identityState, setIdentityState] = useState<'all' | IdentityState>('all')
  const [identitySource, setIdentitySource] = useState<'all' | Provenance>('all')
  const [credentialSearch, setCredentialSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<'all' | CredentialStatus>('all')
  const [credentialSource, setCredentialSource] = useState<'all' | Provenance>('all')
  const [proofOpen, setProofOpen] = useState(false)
  const [unregisteredProofOpen, setUnregisteredProofOpen] = useState(false)

  // Frozen at mount. Every TTL, expiry and rotation figure derives from this one
  // instant, so a re-render cannot make two rows disagree about "now".
  const now = useMemo(() => new Date(), [])

  const load = useCallback(async () => {
    // Declared per call, never accumulated across polls: a console showing the
    // union of every request this tab has ever made would say nothing about the
    // rows currently on screen.
    const manifestProof: Proof = {
      label: 'Registration entries (manifests)',
      command: "rg -n 'spiffe://' d2-signalloom/apps/dashboard-signalloom/src/data/credentialInventory.ts",
      detail: `${CONFIG_REGISTRATION_ENTRIES.length} entries declared in the SPIRE/OpenBao manifests. `
        + 'These are DECLARED, not observed — a row tagged "config" says the platform intends this '
        + 'identity to exist, and nothing more.',
    }

    if (isDemoMode()) {
      setState({
        entries: DEMO_REGISTRATION_ENTRIES,
        source: 'demo',
        reason: 'Demo mode is on',
        proofs: [{
          label: 'Data source',
          command: 'localStorage.getItem("demoMode")   // ?demo=1 sets this',
          detail: 'Demo mode is on, so no cluster call was made. Every figure on this page is a '
            + 'fixture — nothing here was measured.',
        }],
      })
      return
    }

    // The crypto proof is advisory — its absence must not cost us the inventory,
    // so it is settled independently of the discovery call.
    let baoExchangeProven: boolean | undefined
    let cryptoDetail: string
    try {
      const token = await getAccessTokenSilently()
      const health = await api.health.crypto(token)
      const positive = health.proofs.find((p) => p.name === POSITIVE_PROOF)
      if (positive && positive.status !== 'pending') baoExchangeProven = positive.status === 'passed'
      cryptoDetail = positive
        ? `${POSITIVE_PROOF}: ${positive.status}`
        : `no ${POSITIVE_PROOF} in the response — lease status left as declared, not marked failed`
    } catch (err) {
      // No proof signal — leave the lease status untouched rather than guessing.
      cryptoDetail = `request failed (${err instanceof Error ? err.message : 'unknown error'}) — `
        + 'the lease status below is unproven, not disproven'
    }
    const cryptoProof: Proof = {
      label: 'OpenBao exchange proof',
      command: `curl -s -H "Authorization: Bearer $TOKEN" /api/health/crypto   # ${POSITIVE_PROOF}`,
      detail: cryptoDetail,
    }

    const discoveryCommand = `curl -s ${SUPERCRED_API}/agents`
    try {
      const res = await fetch(`${SUPERCRED_API}/agents`)
      if (!res.ok) throw new Error(`Agent discovery failed: ${res.status}`)
      const data = await res.json()
      const agents: RuntimeAgentIdentity[] = data.agents ?? []
      // Cross-checked against the registration set: a pod running an
      // unregistered service account holds no SVID, and must not be painted as
      // an active identity.
      const live = deriveEntriesFromAgents(agents, CONFIG_REGISTRATION_ENTRIES)
      setState({
        entries: mergeEntries(CONFIG_REGISTRATION_ENTRIES, live),
        source: 'live',
        reason: null,
        baoExchangeProven,
        proofs: [
          {
            label: 'Agent discovery',
            command: discoveryCommand,
            detail: `HTTP ${res.status} — ${agents.length} pod(s) discovered in-cluster, `
              + `${live.length} of which resolve to a workload identity:\n`
              + (agents.map((a) => `  ${a.namespace ?? '?'}/${a.name ?? a.id} (sa: ${a.service_account ?? '?'})`).join('\n')
                 || '  (none)'),
          },
          cryptoProof,
          manifestProof,
        ],
      })
    } catch (err) {
      const reason = err instanceof Error ? err.message : 'Agent discovery failed'
      setState({
        entries: DEMO_REGISTRATION_ENTRIES,
        source: 'demo',
        reason,
        proofs: [
          {
            label: 'Agent discovery',
            command: discoveryCommand,
            detail: `${reason}\n\nNo pod was observed, so the table below fell back to fixtures. `
              + 'That is a failure to look, not a finding that nothing is deployed.',
          },
          cryptoProof,
          manifestProof,
        ],
      })
    }
  }, [getAccessTokenSilently])

  useEffect(() => {
    void load()
    // Watched by the demo audience in a second window — see api/pollInterval.ts.
    //
    // Phase 2 mints the credential chain and lands it here, and this page had
    // no refresh at all: it fetched once on mount and then showed that first
    // answer forever. `load` replaces the whole state in one setState and
    // raises no spinner, so a background poll is invisible until the data
    // actually changes.
    const t = setInterval(() => { void load() }, LIVE_POLL_MS)
    return () => clearInterval(t)
  }, [load])

  // Memoised so the `?? []` fallback does not mint a new array identity on
  // every render and invalidate everything downstream of it.
  const entries = useMemo(() => state?.entries ?? [], [state])
  const credentials = useMemo(
    () => entries.flatMap((entry) => credentialsForEntry(entry, { now, baoExchangeProven: state?.baoExchangeProven })),
    [entries, now, state?.baoExchangeProven],
  )
  const summary = useMemo(() => summariseCredentials(credentials, now), [credentials, now])
  const unregistered = useMemo(() => entries.filter((e) => !e.registered), [entries])

  /**
   * The proof behind the amber banner, and the one on this page where getting
   * it wrong would be worse than omitting it.
   *
   * `registered` is decided by `deriveEntriesFromAgents` doing
   * `new Set(CONFIG_REGISTRATION_ENTRIES.map(e => e.spiffeId)).has(id)` — a
   * comparison against a constant transcribed from the repo manifests. There is
   * no SPIRE call anywhere in this page's data path, so the console shows the
   * comparison that ran and names the command that would actually answer the
   * SPIRE question as one nobody executed. Inventing a plausible
   * `spire-server entry show` transcript here would turn an honest banner into
   * a fabricated one, which is the failure mode this console exists to prevent.
   */
  const unregisteredProof = useMemo<Proof>(() => {
    const declared = CONFIG_REGISTRATION_ENTRIES.map((e) => `  ${e.spiffeId}`).join('\n')
    const absent = unregistered.map((e) => `  ${e.spiffeId} — ${e.workload}`).join('\n')
    return {
      label: 'Registration check',
      command: 'CONFIG_REGISTRATION_ENTRIES.map(e => e.spiffeId).includes(discoveredId)'
        + '   // in-browser, src/data/credentialInventory.ts',
      detail: 'Set membership against the registration entries declared in this repo\'s '
        + 'SPIRE/OpenBao manifests. No SPIRE server was contacted.\n\n'
        + `Declared (${CONFIG_REGISTRATION_ENTRIES.length}):\n${declared}\n\n`
        + `Discovered and absent from that list (${unregistered.length}):\n${absent || '  (none)'}\n\n`
        + 'What this does NOT establish: whether SPIRE currently holds an entry for these IDs. '
        + 'That question is answered by `spire-server entry show -spiffeID <id>` against the '
        + 'SPIRE server, and this dashboard has no path to run it. The finding above is that the '
        + 'manifests do not ask for these identities.',
    }
  }, [unregistered])

  // ── Filtering ─────────────────────────────────────────────────────────────
  //
  // Both predicates narrow the TABLE only. The summary cards, the unregistered
  // banner and the proof console all keep reading the full `entries` and
  // `credentials`: a filter is a question about what to look at, never a claim
  // that the rest stopped existing, and a page whose headline count moved when
  // you typed in a search box would be lying about the estate.

  const visibleIdentities = useMemo(() => {
    const q = identitySearch.trim().toLowerCase()
    return entries.filter((e) => {
      if (identityState !== 'all' && e.state !== identityState) return false
      if (identitySource !== 'all' && e.provenance !== identitySource) return false
      if (!q) return true
      // Every column the reader can see, so a search that misses is a search
      // that genuinely found nothing rather than one that looked in one field.
      return [e.spiffeId, e.workload, e.baoRole ?? '', e.baoPolicyPath ?? '', ...e.selectors]
        .some((field) => field.toLowerCase().includes(q))
    })
  }, [entries, identitySearch, identityState, identitySource])

  const visibleCredentials = useMemo(() => {
    const q = credentialSearch.trim().toLowerCase()
    return credentials.filter((c) => {
      // `effectiveStatus`, not `c.status` — the stored status predates `now`,
      // and an active credential whose expiry has passed must answer the
      // Expired filter. Unchanged from the select this replaced.
      if (statusFilter !== 'all' && effectiveStatus(c, now) !== statusFilter) return false
      if (credentialSource !== 'all' && c.provenance !== credentialSource) return false
      if (!q) return true
      return [c.workload, c.kind, c.issuer, c.scope]
        .some((field) => field.toLowerCase().includes(q))
    })
  }, [credentials, credentialSearch, statusFilter, credentialSource, now])

  const identityFiltered = identitySearch !== '' || identityState !== 'all' || identitySource !== 'all'
  const credentialFiltered = credentialSearch !== '' || statusFilter !== 'all' || credentialSource !== 'all'

  const clearIdentityFilters = useCallback(() => {
    setIdentitySearch('')
    setIdentityState('all')
    setIdentitySource('all')
  }, [])

  const clearCredentialFilters = useCallback(() => {
    setCredentialSearch('')
    setStatusFilter('all')
    setCredentialSource('all')
  }, [])

  const sourceColor = state?.source === 'live' ? 'var(--teal)' : 'var(--amber)'

  return (
    <div style={{ paddingBottom: 40 }}>
      <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>Credential Inventory</h1>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, maxWidth: 760 }}>
        Every workload identity in trust domain{' '}
        <code data-testid="trust-domain" style={{ color: 'var(--cyan)' }}>{TRUST_DOMAIN}</code>{' '}
        and the credentials minted from it — SPIFFE SVID, OpenBao dynamic lease, and the
        downstream service token. No static long-lived secrets: every row here expires.
      </p>

      {/* Provenance banner — which data path produced this page. */}
      <div
        data-testid="credential-inventory-source"
        className="card"
        style={{
          padding: '12px 16px', marginBottom: 20, fontSize: 13,
          borderLeft: `3px solid ${sourceColor}`, lineHeight: 1.6,
        }}
      >
        {state === null ? (
          <LoadingState status="loading" label="credential inventory" testId="credential-inventory-load-state" />
        ) : state.source === 'live' ? (
          <>
            <strong style={{ color: sourceColor }}>Live</strong>
            <span style={{ color: 'var(--muted)' }}>
              {' '}— identities observed in-cluster via agent discovery, overlaid on the SPIRE/OpenBao
              manifests. Rows tagged <em>config</em> are declared but not observed.
            </span>
          </>
        ) : (
          <>
            <strong style={{ color: sourceColor }}>Demo data</strong>
            <span style={{ color: 'var(--muted)' }}>
              {' '}— the live path was not used{state.reason ? `: ${state.reason}` : ''}. Figures below are
              fixtures, not measurements.
            </span>
          </>
        )}

        {/* Same disclosure the Credential Lifecycle card offers, same console.
            The banner above is a summary of a data path; this is the data path. */}
        {state !== null && state.proofs.length > 0 && (
          <>
            <button
              type="button"
              className="btn btn-secondary"
              data-testid="inventory-disclose-proof"
              onClick={() => setProofOpen((v) => !v)}
              style={PROOF_BUTTON}
            >
              {proofOpen
                ? 'Hide proof'
                : state.proofs.length > 1
                  ? `How do we know? (${state.proofs.length} checks)`
                  : 'How do we know?'}
            </button>
            {proofOpen && <ProofConsole proofs={state.proofs} testId="inventory-proof-console" />}
          </>
        )}
      </div>

      {/* Summary */}
      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', marginBottom: 26 }}>
        <StatCard testId="summary-workloads" label="Workload identities" value={String(summary.workloads)} sub="distinct SPIFFE IDs" accent="var(--violet)" />
        <StatCard testId="summary-total" label="Credentials" value={String(summary.total)} sub="across all issuers" accent="var(--cyan)" />
        <StatCard
          testId="summary-active"
          label="Active"
          value={String(summary.active)}
          sub={`${summary.expiringSoon} expiring within 15m`}
          accent="var(--teal)"
          help={{
            label: 'What expiring within 15m means',
            testId: 'summary-expiring-help',
            text: 'Credentials whose expiry is less than 15 minutes away. Nothing is wrong with them — the platform re-mints a credential before it lapses, and this is the same 15-minute boundary that turns the Expires column amber further down, so a row and this count can never disagree. It is notice of which rows are about to change, not a fault.',
          }}
        />
        <StatCard testId="summary-revoked" label="Revoked" value={String(summary.revoked)} sub="lease terminated" accent="var(--error)" />
        <StatCard testId="summary-failed" label="Failed" value={String(summary.failed)} sub="exchange did not complete" accent="var(--amber)" />
      </div>

      {/* Unregistered workloads — a pod whose identity the manifests never ask
          for. The heading used to read "with no SPIRE registration entry",
          which asserts a fact about SPIRE that this page has never gone and
          checked: `registered` is a set-membership test against the hardcoded
          CONFIG_REGISTRATION_ENTRIES, and nothing here queries a SPIRE server.
          The table below was already honest about that (rows tagged `config`,
          "registration expected, not observed") while this banner was not. */}
      {unregistered.length > 0 && (
        <div
          data-testid="unregistered-warning"
          className="card"
          style={{
            padding: '14px 18px', marginBottom: 24, fontSize: 13, lineHeight: 1.6,
            borderLeft: '3px solid var(--amber)',
          }}
        >
          <strong style={{ color: colors.amber }}>
            {unregistered.length} discovered workload{unregistered.length === 1 ? '' : 's'} not in the declared registration manifest
          </strong>
          <div style={{ color: 'var(--muted)', marginTop: 4 }}>
            Their SPIFFE IDs do not appear in the registration entries this repo&rsquo;s SPIRE/OpenBao
            manifests declare. No SPIRE server was queried, so read this as &ldquo;the platform never
            asked for this identity&rdquo; rather than &ldquo;SPIRE has confirmed it issued none&rdquo;.
            Where the manifests are the source of truth the two coincide: with no entry there is no
            SVID, and the workload holds no credential this platform can rotate or revoke. Register
            the identity, or move the workload onto a service account that has one.
          </div>
          {/* Stays a list, and is the one region on this page that does not get
              a filter. It presents two fields per item, so it LOOKS like a
              third table, but it is an enumeration inside a warning and the
              difference decides the answer: the heading above states a count,
              and a filter under it could shrink the list while the count held,
              so a security finding would under-report itself on screen. That
              is the failure mode this whole page is written against.

              Nor is it redundant with the Workload Identities table's filters,
              which was the tempting reason to drop it. This list enumerates
              `!registered`, and no single select up there reproduces that set:
              revocation outranks pending in `deriveEntriesFromAgents`, so a
              stunned pod that was never registered reads `revoked`, not
              `pending`. That pod — unregistered AND cut off — is the one an
              operator most needs, and a filter would be the thing that hid it.
              Guarded by a test of the same name. */}
          <ul style={{ margin: '8px 0 0', paddingLeft: 18, color: 'var(--muted)', fontSize: 12 }}>
            {unregistered.map((entry) => (
              <li key={entry.spiffeId} data-testid={`unregistered-${entry.spiffeId}`}>
                <code style={{ color: 'var(--amber)' }}>{entry.spiffeId}</code> — {entry.workload}
              </li>
            ))}
          </ul>
          <button
            type="button"
            className="btn btn-secondary"
            data-testid="unregistered-disclose-proof"
            onClick={() => setUnregisteredProofOpen((v) => !v)}
            style={PROOF_BUTTON}
          >
            {unregisteredProofOpen ? 'Hide proof' : 'How do we know?'}
          </button>
          {unregisteredProofOpen && (
            <ProofConsole proofs={[unregisteredProof]} testId="unregistered-proof-console" />
          )}
        </div>
      )}

      {/* Workload identities */}
      <section style={{ marginBottom: 26 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>Workload Identities</h2>
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>SPIRE registration entries and their OpenBao binding</span>
        </div>
        <DataTable<RegistrationEntry>
          columns={IDENTITY_COLUMNS}
          data={visibleIdentities}
          pageSize={25}
          testIdPrefix="identity"
          toolbar={
            <Toolbar label="Filter workload identities">
              <ToolbarSearch
                label="Search workload identities"
                placeholder="Search SPIFFE ID, workload, role or path…"
                value={identitySearch}
                onChange={setIdentitySearch}
                testId="identity-search"
              />
              <ToolbarSelect
                label="State"
                subject="identities"
                value={identityState}
                options={IDENTITY_STATE_OPTIONS}
                onChange={(v) => setIdentityState(v as 'all' | IdentityState)}
                testId="identity-state-filter"
              />
              <ToolbarSelect
                label="Source"
                subject="identities"
                value={identitySource}
                options={SOURCE_OPTIONS}
                onChange={(v) => setIdentitySource(v as 'all' | Provenance)}
                testId="identity-source-filter"
              />
              <ToolbarCount
                shown={visibleIdentities.length}
                total={entries.length}
                noun="identities"
                onClear={identityFiltered ? clearIdentityFilters : null}
                testId="identity-count"
              />
            </Toolbar>
          }
          /**
           * Three states, and conflating any two of them would misreport the
           * cluster. `undefined` while `state` is null keeps a load that has
           * not answered from rendering as a finding. Beyond that, "discovery
           * found nothing" and "you filtered everything out" are different
           * facts and get different words — the second one is recoverable and
           * says so, one click from the control that caused it.
           */
          emptyState={state === null ? undefined : entries.length === 0 ? (
            <EmptyState
              kicker="No workload identities found"
              body="The discovery call answered, and it listed no pod that resolves to a workload identity."
            />
          ) : (
            <EmptyState
              kicker="No identity matches those filters"
              body={`All ${entries.length} discovered ${entries.length === 1 ? 'identity is' : 'identities are'} still here. Clear filters, just above, puts them back.`}
            />
          )}
          renderRow={(entry) => (
            <tr key={entry.spiffeId} data-testid={`identity-row-${entry.spiffeId}`} style={{ borderBottom: '1px solid var(--border)' }}>
              <td style={td}><code style={{ color: 'var(--cyan)', fontSize: 12 }}>{entry.spiffeId}</code></td>
              <td style={td}>{entry.workload}</td>
              <td style={{ ...td, color: 'var(--muted)', fontSize: 11 }}>
                {entry.selectors.map((s) => <div key={s}>{s}</div>)}
              </td>
              <td style={{ ...td, fontSize: 12 }}>
                {entry.baoRole ?? <span style={{ color: 'var(--muted)' }}>—</span>}
              </td>
              <td style={{ ...td, fontSize: 12 }}>
                {entry.baoPolicyPath
                  ? <code style={{ color: 'var(--violet)', fontSize: 12 }}>{entry.baoPolicyPath}</code>
                  : <span style={{ color: 'var(--muted)' }}>—</span>}
              </td>
              <td style={td}>
                <StatusBadge
                  status={entry.provenance}
                  variant="provenance"
                  testId={`identity-provenance-${entry.spiffeId}`}
                  title={PROVENANCE_HINT[entry.provenance]}
                />
              </td>
              <td style={td}>
                <StatusBadge
                  status={entry.state}
                  variant="credential"
                  testId={`identity-state-${entry.spiffeId}`}
                />
              </td>
            </tr>
          )}
        />
      </section>

      {/* Credentials */}
      <section>
        {/* The status select used to live on this line, floated right of the
            subtitle. It now sits in the toolbar with its two new siblings —
            same control, same testid, same aria-label, one altitude down — so
            that both tables carry their filters in the same place and so that
            filtering to nothing cannot take the control away with the rows. */}
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>Credentials</h2>
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>SVID → OpenBao lease → service token</span>
        </div>
        <DataTable<CredentialRecord>
          columns={[
            { key: 'workload', label: 'Workload', sortable: true },
            {
              key: 'kind',
              label: 'Kind',
              sortable: true,
              help: 'Which link in the chain this row is. An x509-svid is the identity SPIRE issues to a workload. An openbao-lease is the short-lived secret the workload exchanged that identity for. A service-token is what it then presents to the application.',
            },
            { key: 'issuer', label: 'Issuer', sortable: true },
            {
              key: 'scope',
              label: 'Scope',
              help: 'The only thing this credential can open — the OpenBao path or audience it was minted for. Holding a valid credential does not grant anything outside its scope.',
            },
            { key: 'status', label: 'Status', sortable: true },
            { key: 'expiresAt', label: 'Expires', sortable: true },
            {
              key: 'ttlSeconds',
              label: 'TTL',
              sortable: true,
              help: 'How long this credential stays valid from the moment it was issued, in seconds. Expires is the resulting instant. A short TTL is the control: a stolen credential is worthless within minutes.',
            },
            {
              key: 'rotationCount',
              label: 'Rotations',
              sortable: true,
              help: 'How many times this credential has been re-minted since it was first issued. A rising count is the design working, not a fault — short-lived credentials are meant to be replaced rather than kept.',
            },
            { key: 'provenance', label: 'Source', sortable: true },
          ]}
          data={visibleCredentials}
          pageSize={25}
          testIdPrefix="credential-inventory"
          toolbar={
            <Toolbar label="Filter credentials">
              <ToolbarSearch
                label="Search credentials"
                placeholder="Search workload, kind, issuer or scope…"
                value={credentialSearch}
                onChange={setCredentialSearch}
                testId="credential-search"
              />
              <ToolbarSelect
                label="Status"
                subject="credentials"
                value={statusFilter}
                options={CREDENTIAL_STATUS_OPTIONS}
                onChange={(v) => setStatusFilter(v as 'all' | CredentialStatus)}
                testId="credential-status-filter"
              />
              <ToolbarSelect
                label="Source"
                subject="credentials"
                value={credentialSource}
                options={SOURCE_OPTIONS}
                onChange={(v) => setCredentialSource(v as 'all' | Provenance)}
                testId="credential-source-filter"
              />
              <ToolbarCount
                shown={visibleCredentials.length}
                total={credentials.length}
                noun="credentials"
                onClear={credentialFiltered ? clearCredentialFilters : null}
                testId="credential-count"
              />
            </Toolbar>
          }
          /* Same three-state reasoning as the identities table above: nothing
             at all while the load is unanswered, and otherwise words that say
             which of the two zeroes this is. */
          emptyState={state === null ? undefined : credentials.length === 0 ? (
            <EmptyState
              kicker="No credentials to show"
              body="No workload identity on this page has a credential minted from it."
            />
          ) : (
            <EmptyState
              kicker="No credential matches those filters"
              body={`All ${credentials.length} credentials are still here. Clear filters, just above, puts them back.`}
            />
          )}
          renderRow={(cred) => {
            const status = effectiveStatus(cred, now)
            const expiringSoon = status === 'active' && Date.parse(cred.expiresAt) - now.getTime() <= 15 * 60_000
            return (
              <tr key={cred.id} data-testid={`credential-row-${cred.id}`} style={{ borderBottom: '1px solid var(--border)' }}>
                <td style={td}>{cred.workload}</td>
                <td style={{ ...td, fontSize: 12 }}><code style={{ color: 'var(--violet)' }}>{cred.kind}</code></td>
                <td style={{ ...td, color: 'var(--muted)', fontSize: 12 }}>{cred.issuer}</td>
                <td style={{ ...td, fontSize: 11, wordBreak: 'break-all' }}>{cred.scope}</td>
                <td style={td}>
                  <StatusBadge status={status} variant="credential" testId={`credential-status-${cred.id}`} />
                </td>
                <td style={{ ...td, color: expiringSoon ? colors.amber : 'var(--muted)', fontSize: 11, whiteSpace: 'nowrap' }}>
                  {cred.revokedAt ? `revoked ${shortTime(cred.revokedAt)}` : shortTime(cred.expiresAt)}
                </td>
                <td style={{ ...td, color: 'var(--muted)', fontSize: 12 }}>{cred.ttlSeconds}s</td>
                <td style={{ ...td, textAlign: 'center' }}>{cred.rotationCount}</td>
                <td style={td}>
                  <StatusBadge status={cred.provenance} variant="provenance" title={PROVENANCE_HINT[cred.provenance]} />
                </td>
              </tr>
            )
          }}
        />
      </section>
    </div>
  )
}
