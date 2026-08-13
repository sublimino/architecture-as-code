/**
 * RBAC Analysis — KubeSec-AFM embedded dashboard.
 *
 * Iframes the KubeSec-AFM Next.js dashboard through the nginx reverse proxy at
 * /dashboard/. Same-origin — AFM's asset paths (/dashboard/_next/...) resolve
 * naturally. The iframe loads the full AFM UI: cluster list, RBAC graph,
 * escalation analysis, collusion detection, and remediation recommendations.
 */
import { useCallback, useEffect, useState, type CSSProperties } from 'react'
import PixelLoader from '../components/PixelLoader'
import ErrorState from '../components/ErrorState'
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
          <p style={{ fontSize: 13, color: 'var(--muted)', margin: 0, maxWidth: 700 }}>
            KubeSec-AFM — formal-methods RBAC privilege escalation &amp; collusion analysis
            powered by Z3 bounded model checking. Select a cluster below to explore attack paths,
            shared-role pivot points, and min-cut remediation priorities.
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
          <button
            type="button"
            onClick={() => { setIframeLoaded(false); setIframeKey(k => k + 1); checkHealth() }}
            className="btn btn-secondary"
            style={COMPACT_BTN}
          >
            Reload
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
        <div style={{
          background: 'rgba(245,158,11,0.08)', border: '1px solid rgba(245,158,11,0.25)',
          borderRadius: 6, padding: '8px 14px', marginBottom: 10,
          fontSize: 12, color: 'var(--amber)',
        }}>
          Demo mode — AFM is running with seeded sample clusters. Switch to live mode
          for real cluster RBAC analysis.
        </div>
      )}

      {/* Live mode host cluster indicator */}
      {!demo && status.reachable && (
        <div data-testid="host-cluster-indicator" style={{
          background: 'rgba(6,182,212,0.06)', border: '1px solid rgba(6,182,212,0.2)',
          borderRadius: 6, padding: '8px 14px', marginBottom: 10,
          fontSize: 12, color: 'var(--cyan)',
        }}>
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
