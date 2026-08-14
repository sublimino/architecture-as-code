/**
 * RBAC Analysis — KubeSec-AFM embedded dashboard.
 *
 * Iframes the KubeSec-AFM Next.js dashboard through the nginx reverse proxy at
 * /dashboard/. Same-origin — AFM's asset paths (/dashboard/_next/...) resolve
 * naturally. The iframe loads the full AFM UI: cluster list, RBAC graph,
 * escalation analysis, collusion detection, and remediation recommendations.
 *
 * ── Why there is no DataTable here ──────────────────────────────────────────
 * There are no rows on this page to put in one. Its entire data surface is two
 * scalars — the code /afm/health answered with, and the length of
 * /afm/clusters — plus an iframe. `clustersRes` is consumed by `.length` and
 * `selectMostRecentImport` and is never rendered; `localClusters` is the only
 * array in this component's state and only ever reaches the screen as an
 * addend in the count on the status line. The rows a reader of an RBAC page
 * actually wants (escalation paths, shared-role pivots, min-cut priorities)
 * are rendered by AFM's own Next.js app inside the frame, which is a different
 * application; the importer panel below turns subjects, roles and bindings
 * into YAML rather than into a table. Adding a table here would mean inventing
 * data to fill it, so the design-system work went into the vocabulary and the
 * controls instead.
 */
import { useCallback, useEffect, useState, type CSSProperties } from 'react'
import PixelLoader from '../components/PixelLoader'
import ButtonWait from '../components/ButtonWait'
import ErrorState from '../components/ErrorState'
import HelpHint from '../components/HelpHint'
import { tint } from '../components/StatusBadge'
import { ProofConsole, type Proof } from '../components/ProofConsole'
import { useAuth0 } from '../auth/oidc'
import { isDemoMode } from '../api/demoMode'
import RbacImporterPanel from '../components/RbacImporterPanel'
import AddClusterModal, { type NewClusterEntry } from '../components/AddClusterModal'
import { afmDashboardUrl, selectMostRecentImport } from '../api/afmYaml'
import { curlPipeJq } from './proofQuery'

const AFM_DASHBOARD = '/dashboard/'
const AFM_HEALTH = '/afm/health'
const AFM_CLUSTERS = '/afm/clusters'

interface AfmStatus {
  reachable: boolean
  clusterCount: number | null
  checkedAt: Date | null
  /**
   * The status code /afm/health actually answered with, kept so the
   * "AFM connected" claim beside it can be checked rather than believed.
   * `null` means the request never completed, so there is no code to show —
   * which is a different thing from a code that says no.
   */
  healthStatus: number | null
}

/**
 * "How do we know AFM is connected?", answered from the two requests this page
 * really issued and from nothing else.
 *
 * Both routes are called unauthenticated by `checkHealth` below (they are the
 * nginx-proxied `/afm/*` surface, not `/api/*`), so neither command carries a
 * bearer header — a proof that would not run as written is worse than none.
 *
 * A request that never completed yields NO proof rather than an invented one.
 * curl would print its own failure there and this page did not record it, and
 * "unreachable" is exactly the verdict a reader is most entitled to check, so
 * guessing at it is the worst place in the app to guess.
 */
export function afmReachabilityProofs(status: AfmStatus): Proof[] {
  const proofs: Proof[] = []
  if (status.healthStatus !== null) {
    proofs.push({
      label: 'Reachability',
      // -o /dev/null -w '%{http_code}' is the shell spelling of `res.ok`:
      // it prints the code and nothing else.
      command: `curl -s -o /dev/null -w '%{http_code}\\n' ${AFM_HEALTH}`,
      detail: String(status.healthStatus),
    })
  }
  if (status.clusterCount !== null) {
    proofs.push({
      label: 'Clusters',
      command: curlPipeJq({ path: AFM_CLUSTERS, filter: 'length' }),
      detail: String(status.clusterCount),
    })
  }
  return proofs
}

/** The header row's shared size. The only thing still local to these controls. */
const COMPACT_BTN: CSSProperties = { fontSize: 12, padding: '5px 12px' }

/**
 * Reserved so Reload does not resize when its label becomes a loader.
 *
 * ButtonWait reserves 78px for the grid and the elapsed figure, and this
 * button's own padding adds 24 — so the busy state is wider than the word
 * "Reload" and the header row would shuffle sideways at both transitions
 * without this. Same reasoning, and the same fix, as NetworkTestsPage's
 * SCAN_BUTTON_W: a toolbar that jumps mid-probe reads to a room as a fault,
 * which on the page whose whole subject is "is AFM up" is the worst possible
 * false signal.
 */
const RELOAD_BTN_W = 104

/**
 * The two mode banners, which held the last hardcoded colours on this page.
 *
 * They carried `rgba(245,158,11,…)` and `rgba(6,182,212,…)` — the Dark theme's
 * amber and cyan, frozen as literals. The text sitting on them is
 * `var(--amber)` and `var(--cyan)`, which do follow the theme, so under Light
 * and Andy the fill and the text it was supposed to tint were two different
 * hues by construction. `tint()` is the helper StatusBadge, CredentialStateNotice
 * and four other pages already use, so the fill is now derived from the same
 * token as the text. The alphas are carried over unchanged: this fixes which
 * colour, not how much of it.
 *
 * Longhand border properties rather than the shorthand, per the lesson recorded
 * in HelpHint: a `border` shorthand carrying a custom property is unreadable to
 * jsdom, which would make the tint untestable outside a real browser.
 */
const NOTICE_BASE: CSSProperties = {
  borderRadius: 6, padding: '8px 14px', marginBottom: 10,
  fontSize: 12, borderWidth: 1, borderStyle: 'solid',
}
const DEMO_NOTICE: CSSProperties = {
  ...NOTICE_BASE,
  background: tint('var(--amber)', 0.08),
  borderColor: tint('var(--amber)', 0.25),
  color: 'var(--amber)',
}
const LIVE_NOTICE: CSSProperties = {
  ...NOTICE_BASE,
  background: tint('var(--cyan)', 0.06),
  borderColor: tint('var(--cyan)', 0.2),
  color: 'var(--cyan)',
}

/**
 * The proof disclosure, matching the row-level one on Network Tests and the
 * per-step one on the Credential Lifecycle card rather than `.btn`: it is a
 * quiet secondary affordance under a 12px status line, and a full-size button
 * there would outrank the claim it belongs to.
 */
const PROOF_BTN: CSSProperties = {
  fontSize: 10, padding: '3px 8px', borderRadius: 4, cursor: 'pointer',
  border: '1px solid var(--border)', background: 'transparent', color: 'var(--muted)',
}

export default function RbacAnalysisPage() {
  const { getAccessTokenSilently } = useAuth0()
  const [iframeLoaded, setIframeLoaded] = useState(false)
  const [status, setStatus] = useState<AfmStatus>({ reachable: false, clusterCount: null, checkedAt: null, healthStatus: null })
  const [showProof, setShowProof] = useState(false)
  const [iframeKey, setIframeKey] = useState(0)
  const [showAddCluster, setShowAddCluster] = useState(false)
  // Reflects the explicit Reload only, never the mount probe: a wait belongs to
  // the control that was pressed, and on mount no control was pressed.
  const [reloading, setReloading] = useState(false)
  const [localClusters, setLocalClusters] = useState<NewClusterEntry[]>([])
  // Which cluster the embed opens on. AFM selects nothing by default, so an
  // unparameterised /dashboard/ renders an empty frame and every import looks
  // like it never arrived.
  const [embedClusterId, setEmbedClusterId] = useState<string | null>(null)

  const checkHealth = useCallback(async () => {
    try {
      const [health, clustersRes] = await Promise.all([
        // The status code is kept, not just `ok`: it is what the proof beside
        // the indicator shows, and it is also the difference between "the
        // service said no" and "nothing answered".
        fetch(AFM_HEALTH).then(r => ({ ok: r.ok, status: r.status })),
        fetch(AFM_CLUSTERS).then(r => r.ok ? r.json() : null).catch(() => null),
      ])
      setStatus({
        reachable: health.ok,
        clusterCount: Array.isArray(clustersRes) ? clustersRes.length : null,
        checkedAt: new Date(),
        healthStatus: health.status,
      })
      if (Array.isArray(clustersRes)) {
        const ids = clustersRes.filter((c: unknown): c is { id: string } =>
          typeof (c as { id?: unknown })?.id === 'string')
        setEmbedClusterId(selectMostRecentImport(ids))
      }
    } catch {
      // Nothing answered, so there is no status code to show and no proof to
      // offer — see afmReachabilityProofs.
      setStatus({ reachable: false, clusterCount: null, checkedAt: new Date(), healthStatus: null })
    }
  }, [])

  useEffect(() => { checkHealth() }, [checkHealth])

  void getAccessTokenSilently

  const demo = isDemoMode()

  const handleAddCluster = (entry: NewClusterEntry) => {
    setLocalClusters(prev => [...prev, entry])
  }

  // In live mode, show "Host Cluster" + any locally-added clusters.
  // In demo mode, show all AFM clusters as-is.
  const effectiveClusterCount = demo
    ? status.clusterCount
    : status.clusterCount !== null
      ? 1 + localClusters.length
      : null

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: 'calc(100vh - 56px - 28px)', minHeight: 500 }}>
      {/* Header bar */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12, flexWrap: 'wrap', gap: 8 }}>
        <div>
          <h1 style={{ fontSize: 22, fontWeight: 700, marginBottom: 4 }}>RBAC Analysis</h1>
          {/* Three terms in one sentence that a reader cannot decode from the
              sentence: what an escalation path is, what makes two individually
              harmless identities dangerous together, and what a min-cut is a
              cut OF. Anchored to the words themselves rather than collected
              into one hint on the heading — the canon's specimen is a term
              followed by its "?", and a reader who already knows two of the
              three should not have to open an explanation of all three.
              lineHeight is the one concession: an 18px affordance set in a 13px
              paragraph needs the extra leading or consecutive rows collide. */}
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, maxWidth: 700, lineHeight: 1.7 }}>
            KubeSec-AFM — formal-methods RBAC privilege escalation{' '}
            <HelpHint label="What privilege escalation means" testId="rbac-hint-escalation">
              A path by which an identity that is not cluster-admin can become one, using only the
              permissions it already holds. The commonest edge is a wildcard verb: a Role granting
              &ldquo;*&rdquo; on secrets lets its holder read the credentials of everything else, and
              &ldquo;*&rdquo; on rolebindings lets it simply grant itself the rest. Z3 searches for
              the whole chain, not the single grant.
            </HelpHint>
            {' '}&amp; collusion{' '}
            <HelpHint label="What collusion means" testId="rbac-hint-collusion">
              Two or more identities that are each harmless alone and reach admin together — one can
              create a binding, another can be named as its subject. No single account looks
              over-privileged in review, which is precisely why this is the class that an audit of one
              identity at a time cannot find.
            </HelpHint>
            {' '}analysis powered by Z3 bounded model checking. Select a cluster below to explore attack
            paths, shared-role pivot points, and min-cut remediation{' '}
            <HelpHint label="What min-cut remediation means" testId="rbac-hint-mincut">
              The smallest set of role bindings whose removal breaks every escalation path that was
              found — a cut through the permission graph. It ranks what to revoke first; it is not a
              claim that whatever survives the cut is safe.
            </HelpHint>
            {' '}priorities.
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {/* Status indicators */}
          <div style={{ display: 'flex', gap: 12, fontSize: 12, color: 'var(--muted)' }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
              <span style={{
                width: 8, height: 8, borderRadius: '50%',
                background: status.reachable ? 'var(--teal)' : 'var(--error)',
              }} />
              AFM {status.reachable ? 'connected' : 'unreachable'}
            </span>
            {effectiveClusterCount !== null && (
              <span data-testid="cluster-count">
                {!demo && effectiveClusterCount >= 1
                  ? <>Host Cluster{localClusters.length > 0 ? ` + ${localClusters.length} remote` : ''}</>
                  : <>{effectiveClusterCount} cluster{effectiveClusterCount !== 1 ? 's' : ''}</>
                }
              </span>
            )}
            {/* One hint for the whole line, because both claims on it are the
                same kind of claim and neither of them says what it means. It
                is deliberately not a restatement of the proof below: the proof
                shows the two commands and what they returned, this says what a
                200 does and does not entitle a reader to conclude. Placed
                outside the cluster-count span so the count stays exactly the
                string it was. */}
            <HelpHint label="What the AFM status line means" testId="rbac-hint-afm-status">
              &ldquo;Connected&rdquo; means /afm/health answered 200 a moment ago. It does not mean any
              cluster has been analysed, or that the last analysis succeeded. The figure beside it is
              what AFM holds in demo mode; in live mode it is this cluster plus any remote added in
              this browser tab. Open &ldquo;How do we know?&rdquo; below for both commands verbatim.
            </HelpHint>
          </div>
          {/* Three controls, one shape. `.btn-secondary` already declares its
              own fill, text colour and border, so the cyan border-and-colour
              pair that used to sit here was overriding half a variant with an
              inline copy of a different one — and getting the hover state
              (which only moves --surface2 to --border-subtle) for free while
              leaving its own border static. Only the size, which the whole
              header row shares, is still local. */}
          <button
            type="button"
            data-testid="add-cluster-btn"
            onClick={() => setShowAddCluster(true)}
            className="btn btn-secondary"
            style={COMPACT_BTN}
          >
            + Add Cluster
          </button>
          {/* The control whose effect is least guessable on the page: it looks
              like it enrols a cluster with the analysis platform and it does
              not. Stated here rather than inside the modal because the reader
              who needs it is the one deciding whether to open it. */}
          <HelpHint label="What Add Cluster does" testId="rbac-hint-add-cluster">
            Registers a remote cluster in this browser tab only. No request is sent to AFM and nothing
            is persisted — the entry adds to the count on this line, and refreshing the browser
            discards it.
          </HelpHint>
          {/* The wait belongs inside the control the reader just pressed, which
              is ButtonWait's exact remit and the same treatment NetworkTestsPage
              gives its header-row Scan. Reload issues the same two requests
              checkHealth always issued, in the same order; the only thing added
              is that the button now says it is doing so. Against an AFM that is
              slow or down that is the difference between a dead control and a
              probe in flight, on the one page whose subject is whether AFM is
              up. `reloading` is set by this handler alone, so the mount probe
              renders exactly as it did before. */}
          <button
            type="button"
            data-testid="afm-reload-btn"
            disabled={reloading}
            aria-busy={reloading}
            onClick={async () => {
              setIframeLoaded(false)
              setIframeKey(k => k + 1)
              setReloading(true)
              try {
                await checkHealth()
              } finally {
                setReloading(false)
              }
            }}
            className="btn btn-secondary"
            style={{ ...COMPACT_BTN, minWidth: RELOAD_BTN_W, justifyContent: 'center' }}
          >
            {reloading
              ? <ButtonWait testId="afm-reload-wait" label="Reloading" />
              : 'Reload'}
          </button>
          {/* An anchor, still — it opens a new tab and must stay
              middle-clickable — but wearing the shared class rather than a
              hand-drawn border plus two JS mouse handlers that reimplemented
              :hover. `.btn`'s focus-visible outline comes with it, which the
              hand-rolled version never had: it was reachable by keyboard and
              gave no sign of it. */}
          <a
            href={AFM_DASHBOARD}
            target="_blank"
            rel="noopener noreferrer"
            className="btn btn-secondary"
            style={{ ...COMPACT_BTN, textDecoration: 'none' }}
          >
            Open full ↗
          </a>
        </div>
      </div>

      {/* The status line above asserts the platform is connected and how many
          clusters it holds. Both come from two requests this page made a
          moment ago, so both can be re-run. */}
      {status.checkedAt && (
        <div style={{ marginBottom: 10 }}>
          <button
            type="button"
            data-testid="afm-proof-toggle"
            onClick={() => setShowProof(v => !v)}
            style={PROOF_BTN}
          >
            {showProof ? 'Hide proof' : 'How do we know?'}
          </button>
          {showProof && (
            <ProofConsole proofs={afmReachabilityProofs(status)} testId="afm-proof-console" />
          )}
        </div>
      )}

      {/* Demo mode banner */}
      {demo && (
        <div data-testid="demo-mode-notice" style={DEMO_NOTICE}>
          Demo mode — AFM is running with seeded sample clusters. Switch to live mode
          for real cluster RBAC analysis.
        </div>
      )}

      {/* Live mode host cluster indicator */}
      {!demo && status.reachable && (
        <div data-testid="host-cluster-indicator" style={LIVE_NOTICE}>
          Live mode — analysing Host Cluster via Flux. Add remote clusters to extend analysis.
        </div>
      )}

      <RbacImporterPanel
        onImported={(clusterId) => {
          // Point the embed at what was just sent and force a reload: the
          // iframe will not re-navigate on a src change alone once loaded.
          setEmbedClusterId(clusterId)
          setIframeLoaded(false)
          setIframeKey((k) => k + 1)
        }}
      />

      {showAddCluster && (
        <AddClusterModal
          onAdd={handleAddCluster}
          onClose={() => setShowAddCluster(false)}
        />
      )}

      {/* The whole panel failed and there is nothing to show, which is
          ErrorState's exact remit — so the icon, the heading, the message and
          the Retry are the shared ones rather than this page's fourth private
          spelling of them. It also brings the 401 rule with it: a session that
          expired gets "Log in" instead of a Retry that is guaranteed to
          reproduce the refusal.

          The remediation block stays. ErrorState takes a message, not a
          fragment, and "here is the command that fixes this" is the most
          useful thing on the screen — dropping it to fit the component would
          be the migration paying for consistency with the reader's time. */}
      {!status.reachable && status.checkedAt && (
        <div style={{
          flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center',
          justifyContent: 'center',
        }} data-testid="afm-unreachable">
          <ErrorState
            message="KubeSec-AFM platform is not reachable."
            onRetry={() => { checkHealth(); setIframeKey(k => k + 1) }}
          />
          <p style={{ fontSize: 13, color: 'var(--muted)', textAlign: 'center', maxWidth: 440, margin: '0 0 12px' }}>
            Deploy the AFM platform and seed it with cluster data:
          </p>
          <div style={{
            display: 'flex', flexDirection: 'column', gap: 6,
            background: 'var(--surface2)', padding: '14px 20px', borderRadius: 8,
            fontFamily: 'monospace', fontSize: 12, color: 'var(--cyan)',
          }}>
            <span>make demo-k8s-afm-up</span>
            <span style={{ color: 'var(--muted)' }}># Then reload this page</span>
          </div>
        </div>
      )}

      {/* Loading spinner */}
      {status.reachable && !iframeLoaded && (
        <div style={{
          position: 'absolute', inset: 0, top: 80,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--muted)', fontSize: 13, zIndex: 0,
        }}>
          <PixelLoader testId="afm-iframe-loading" label="Loading KubeSec-AFM dashboard" />
        </div>
      )}

      {/* AFM iframe */}
      {status.reachable && (
        <iframe
          key={iframeKey}
          src={afmDashboardUrl(embedClusterId, AFM_DASHBOARD)}
          title="KubeSec-AFM Dashboard"
          data-testid="afm-iframe"
          style={{
            flex: 1,
            width: '100%',
            border: '1px solid var(--border-subtle)',
            borderRadius: 8,
            background: 'var(--bg)',
          }}
          onLoad={() => setIframeLoaded(true)}
        />
      )}
    </div>
  )
}
