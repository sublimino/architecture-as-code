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
 */
import { useState, useEffect, useCallback, useMemo, type CSSProperties } from 'react'
import { useAuth0 } from '../auth/oidc'
import { api } from '../api/client'
import { isDemoMode } from '../api/demoMode'
import { LIVE_POLL_MS } from '../api/pollInterval'
import DataTable from '../components/DataTable'
import HelpHint from '../components/HelpHint'
import LoadingState from '../components/LoadingState'
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

const th: CSSProperties = { padding: '9px 14px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600, fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em', whiteSpace: 'nowrap' }
const td: CSSProperties = { padding: '9px 14px', fontSize: 13, color: 'var(--text)' }

/**
 * Column headers for the Workload Identities table.
 *
 * Only "Selectors" carries a hint. It is the one column that describes a
 * mechanism rather than a value, and it is the mechanism the whole page rests
 * on — everything else here (SPIFFE ID, Workload, OpenBao role, Policy path)
 * either names itself or is already explained by the tag titles in its cells.
 */
const IDENTITY_HEADERS: { label: string; help?: string; testId?: string }[] = [
  { label: 'SPIFFE ID' },
  { label: 'Workload' },
  {
    label: 'Selectors',
    help: 'What SPIRE checks about a running pod before it will hand that pod an identity — here, its namespace and its Kubernetes service account. A workload that does not match cannot obtain the credential even if it knows the name of it.',
    testId: 'identity-selectors-help',
  },
  { label: 'OpenBao role' },
  { label: 'Policy path' },
  { label: 'Source' },
  { label: 'State' },
]

function tint(cssVar: string, opacity: number) {
  return `color-mix(in srgb, ${cssVar} ${Math.round(opacity * 100)}%, transparent)`
}

const STATUS_COLOR: Record<CredentialStatus, string> = {
  active: 'var(--teal)',
  pending: 'var(--cyan)',
  expired: 'var(--amber)',
  failed: 'var(--error)',
  revoked: 'var(--error)',
}

const PROVENANCE_COLOR: Record<Provenance, string> = {
  live: 'var(--teal)',
  config: 'var(--cyan)',
  demo: 'var(--amber)',
}

const PROVENANCE_HINT: Record<Provenance, string> = {
  live: 'Observed in-cluster via agent discovery',
  config: 'Declared in the SPIRE/OpenBao manifests — registration expected, not observed',
  demo: 'Fixture data — the live path was unavailable',
}

function Tag({ label, color, testId, title }: { label: string; color: string; testId?: string; title?: string }) {
  return (
    <span
      data-testid={testId}
      title={title}
      className="tag"
      style={{ background: tint(color, 0.12), color, whiteSpace: 'nowrap' }}
    >
      {label}
    </span>
  )
}

function StatCard({ label, value, sub, accent, testId }: { label: string; value: string; sub: string; accent: string; testId: string }) {
  return (
    <div className="card" style={{ flex: 1, minWidth: 170, padding: '16px 18px' }}>
      <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginBottom: 8 }}>{label}</div>
      <div data-testid={testId} style={{ fontSize: 26, fontWeight: 700, color: accent, lineHeight: 1 }}>{value}</div>
      <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 6 }}>{sub}</div>
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
  const [statusFilter, setStatusFilter] = useState<'all' | CredentialStatus>('all')
  const [proofOpen, setProofOpen] = useState(false)

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

  const visibleCredentials = useMemo(
    () => (statusFilter === 'all'
      ? credentials
      : credentials.filter((c) => effectiveStatus(c, now) === statusFilter)),
    [credentials, statusFilter, now],
  )

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
              data-testid="inventory-disclose-proof"
              onClick={() => setProofOpen((v) => !v)}
              style={{
                fontSize: 11, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
                marginTop: 8, border: '1px solid var(--border)',
                background: 'transparent', color: 'inherit', fontFamily: 'inherit',
              }}
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
        <StatCard testId="summary-active" label="Active" value={String(summary.active)} sub={`${summary.expiringSoon} expiring within 15m`} accent="var(--teal)" />
        <StatCard testId="summary-revoked" label="Revoked" value={String(summary.revoked)} sub="lease terminated" accent="var(--error)" />
        <StatCard testId="summary-failed" label="Failed" value={String(summary.failed)} sub="exchange did not complete" accent="var(--amber)" />
      </div>

      {/* Unregistered workloads — a pod running without any workload identity. */}
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
            {unregistered.length} discovered workload{unregistered.length === 1 ? '' : 's'} with no SPIRE registration entry
          </strong>
          <div style={{ color: 'var(--muted)', marginTop: 4 }}>
            These pods are running without a workload identity — no SVID is issued for them, so they
            hold no credential this platform can rotate or revoke. Register the identity, or move the
            workload onto a service account that has one.
          </div>
          <ul style={{ margin: '8px 0 0', paddingLeft: 18, color: 'var(--muted)', fontSize: 12 }}>
            {unregistered.map((entry) => (
              <li key={entry.spiffeId} data-testid={`unregistered-${entry.spiffeId}`}>
                <code style={{ color: 'var(--amber)' }}>{entry.spiffeId}</code> — {entry.workload}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Workload identities */}
      <section style={{ marginBottom: 26 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>Workload Identities</h2>
          <span style={{ fontSize: 12, color: 'var(--muted)' }}>SPIRE registration entries and their OpenBao binding</span>
        </div>
        <div className="card" style={{ padding: 0, overflow: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: 'var(--surface2)', borderBottom: '1px solid var(--border)' }}>
                {IDENTITY_HEADERS.map((h) => (
                  <th key={h.label} style={th}>
                    {h.help ? (
                      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
                        {h.label}
                        <HelpHint label={`What ${h.label} means`} testId={h.testId}>{h.help}</HelpHint>
                      </span>
                    ) : h.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
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
                    <Tag
                      testId={`identity-provenance-${entry.spiffeId}`}
                      label={entry.provenance}
                      color={PROVENANCE_COLOR[entry.provenance]}
                      title={PROVENANCE_HINT[entry.provenance]}
                    />
                  </td>
                  <td style={td}>
                    <Tag
                      testId={`identity-state-${entry.spiffeId}`}
                      label={entry.state}
                      color={entry.state === 'revoked' ? 'var(--error)' : entry.state === 'pending' ? 'var(--cyan)' : 'var(--teal)'}
                    />
                  </td>
                </tr>
              ))}
              {entries.length === 0 && state !== null && (
                <tr>
                  <td colSpan={7} style={{ ...td, color: 'var(--muted)', textAlign: 'center', padding: '18px 14px' }}>
                    No workload identities found.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {/* Credentials */}
      <section>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 10, flexWrap: 'wrap' }}>
          <h2 style={{ fontSize: 16, fontWeight: 700 }}>Credentials</h2>
          <span style={{ fontSize: 12, color: 'var(--muted)', flex: 1 }}>SVID → OpenBao lease → service token</span>
          <label style={{ fontSize: 12, color: 'var(--muted)', display: 'flex', alignItems: 'center', gap: 6 }}>
            Status
            <select
              data-testid="credential-status-filter"
              aria-label="Filter credentials by status"
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value as 'all' | CredentialStatus)}
              style={{
                background: 'var(--surface)', color: 'var(--text)',
                border: '1px solid var(--border)', borderRadius: 6,
                padding: '4px 8px', fontSize: 12, fontFamily: 'inherit',
              }}
            >
              {['all', 'active', 'expired', 'revoked', 'failed', 'pending'].map((s) => (
                <option key={s} value={s}>{s}</option>
              ))}
            </select>
          </label>
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
                  <Tag testId={`credential-status-${cred.id}`} label={status} color={STATUS_COLOR[status]} />
                </td>
                <td style={{ ...td, color: expiringSoon ? colors.amber : 'var(--muted)', fontSize: 11, whiteSpace: 'nowrap' }}>
                  {cred.revokedAt ? `revoked ${shortTime(cred.revokedAt)}` : shortTime(cred.expiresAt)}
                </td>
                <td style={{ ...td, color: 'var(--muted)', fontSize: 12 }}>{cred.ttlSeconds}s</td>
                <td style={{ ...td, textAlign: 'center' }}>{cred.rotationCount}</td>
                <td style={td}>
                  <Tag label={cred.provenance} color={PROVENANCE_COLOR[cred.provenance]} title={PROVENANCE_HINT[cred.provenance]} />
                </td>
              </tr>
            )
          }}
        />
      </section>
    </div>
  )
}
