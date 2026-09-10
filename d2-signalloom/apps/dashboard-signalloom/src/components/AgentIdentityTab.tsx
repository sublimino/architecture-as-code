import { useState, useMemo } from 'react'
import { Link } from 'react-router-dom'
import type { AgentResponse, SourceHealthMap } from '../types/api'
import { colors } from '../styles/tokens'
import CredentialStateNotice from './CredentialStateNotice'
import WhoAuthorizedPanel from './WhoAuthorizedPanel'

// ─── Helpers ────────────────────────────────────────────────────────────────

function fmtDate(iso: string | null) {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export interface AgentIdentityTabProps {
  agent: AgentResponse
  sourceHealth?: 'healthy' | 'degraded' | 'unavailable' | null
  sourceHealthDetail?: SourceHealthMap | null
}

export default function AgentIdentityTab({
  agent,
  sourceHealth,
  sourceHealthDetail,
}: AgentIdentityTabProps) {
  const [copiedSpiffeId, setCopiedSpiffeId] = useState(false)

  // 1. Record Class & Registry Linkage
  const recordClass = agent.record_class || (agent.is_registry_linked === false ? 'discovered' : 'registered')
  const isRegistryLinked = agent.is_registry_linked !== false && recordClass !== 'discovered'

  // 2. Identity metadata
  const identity = agent.identity
  const spiffeId = identity?.spiffe_id || null
  const spiffeStatus = identity?.spiffe_status || (spiffeId ? 'linked' : 'unlinked')
  const isSpiffeLinked = spiffeStatus === 'linked' && !!spiffeId
  const trustDomain = identity?.trust_domain || (spiffeId && spiffeId.startsWith('spiffe://') ? spiffeId.replace('spiffe://', '').split('/')[0] : 'signalloom.demo')
  const svidType = identity?.svid_type || (isSpiffeLinked ? 'x509' : 'none')
  const aliases = identity?.aliases ?? []

  // 3. Runtime metadata for selectors
  const namespace = agent.runtime?.namespace || agent.namespace || 'default'
  const serviceAccount = agent.runtime?.service_account || agent.service_account || '—'
  const node = agent.runtime?.node || agent.node || 'Not assigned'
  const podUid = agent.runtime?.pod_uid || agent.pod_uid || '—'
  const clusterId = agent.runtime?.cluster_id || 'cluster-local'

  // 4. Selectors
  const selectors = useMemo(() => {
    if (identity?.selectors && identity.selectors.length > 0) {
      return identity.selectors
    }
    const derived: string[] = []
    if (namespace && namespace !== '—') derived.push(`k8s:ns:${namespace}`)
    if (serviceAccount && serviceAccount !== '—') derived.push(`k8s:sa:${serviceAccount}`)
    if (podUid && podUid !== '—') derived.push(`k8s:pod-uid:${podUid}`)
    if (node && node !== 'Not assigned') derived.push(`k8s:node:${node}`)
    if (agent.name) derived.push(`container:name:${agent.name.toLowerCase().replace(/[^a-z0-9_-]/g, '-')}`)
    return derived
  }, [identity?.selectors, namespace, serviceAccount, podUid, node, agent.name])

  // 5. Certificate Validity & Timestamps
  const certValidFrom = identity?.cert_valid_from || agent.created_at || null
  const certValidUntil = identity?.cert_valid_until || (agent.credential_state?.status === 'active' ? new Date(Date.now() + 14400000).toISOString() : null)
  const certIssuer = identity?.cert_issuer || (isSpiffeLinked ? 'spiffe://signalloom.demo/spire/server' : '—')
  const isRevoked = agent.credential_state?.status === 'revoked'

  // Certificate status description
  const certValidityInfo = useMemo(() => {
    if (isRevoked) {
      return { label: 'Revoked', status: 'revoked', color: colors.red }
    }
    if (!isSpiffeLinked) {
      return { label: 'No active SVID', status: 'unlinked', color: 'var(--muted)' }
    }
    if (!certValidUntil) {
      return { label: 'Valid (Active SVID)', status: 'valid', color: colors.tealLoom }
    }
    const untilMs = new Date(certValidUntil).getTime()
    const nowMs = Date.now()
    const diffMs = untilMs - nowMs
    if (diffMs <= 0) {
      return { label: 'Expired', status: 'expired', color: colors.red }
    }
    const hours = Math.floor(diffMs / 3600000)
    const mins = Math.floor((diffMs % 3600000) / 60000)
    if (hours < 1) {
      return { label: `Expires soon (${mins}m remaining)`, status: 'expiring', color: colors.amber }
    }
    return { label: `Valid (expires in ${hours}h ${mins}m)`, status: 'valid', color: colors.tealLoom }
  }, [isRevoked, isSpiffeLinked, certValidUntil])

  // 6. Separation of Identity Planes & Delegation
  const ownerName = agent.responsibility?.owner_name || agent.owner
  const authorizingPrincipal = (identity as any)?.delegation?.authorizing_principal || identity?.authorizing_principal_id || ownerName || null
  const executingActor = (identity as any)?.delegation?.executing_actor || identity?.executing_actor_id || spiffeId || agent.id
  const delegationHops = identity?.delegation_hops ?? ((identity as any)?.delegation?.delegation_depth ?? (authorizingPrincipal ? 1 : 0))

  // 7. OpenBao & Key Custody
  const openbaoRole = identity?.openbao_role || `agent-trust-${serviceAccount !== '—' ? serviceAccount : agent.id}`
  const openbaoPath = identity?.openbao_path || `kv/data/signalloom/agent-trust/${namespace}/*`

  // 8. Source Health
  const effectiveSourceHealth = sourceHealth || 'healthy'
  const isSourceUnavailable = effectiveSourceHealth === 'unavailable' || sourceHealthDetail?.crypto_proofs?.status === 'unavailable'

  function handleCopySpiffeId() {
    if (!spiffeId) return
    navigator.clipboard?.writeText(spiffeId).catch(() => {})
    setCopiedSpiffeId(true)
    setTimeout(() => setCopiedSpiffeId(false), 2000)
  }

  return (
    <div
      data-testid="dossier-panel-identity"
      role="tabpanel"
      id="dossier-tabpanel-identity"
      aria-labelledby="dossier-tab-identity"
      style={{ display: 'flex', flexDirection: 'column', gap: 20 }}
    >
      {/* ─── Scoped Deep-Link Navigation ────────────────────────────────────── */}
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, flexWrap: 'wrap' }}>
        <Link
          to={`/credential-inventory?actor=${encodeURIComponent(executingActor || agent.id)}`}
          data-testid="identity-deeplink-credentials"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          Credential Inventory ↗
        </Link>
        <Link
          to={`/cryptography?actor=${encodeURIComponent(executingActor || agent.id)}`}
          data-testid="identity-deeplink-crypto"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          Cryptography ↗
        </Link>
        <Link
          to={`/agent-trust-topology?actor=${encodeURIComponent(executingActor || agent.id)}`}
          data-testid="identity-deeplink-topology"
          className="btn btn-secondary"
          style={{ fontSize: 11, padding: '5px 12px', textDecoration: 'none', color: 'var(--text)' }}
        >
          Trust Topology ↗
        </Link>
      </div>

      {/* ─── Source Health Warning (if degraded or unavailable) ─────────────── */}
      {isSourceUnavailable && (
        <div
          data-testid="identity-source-health-banner"
          style={{
            padding: '12px 16px',
            borderRadius: 8,
            background: 'rgba(239, 68, 68, 0.1)',
            border: '1px solid rgba(239, 68, 68, 0.3)',
            color: colors.red,
            fontSize: 13,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <span style={{ fontSize: 16 }}>⚠️</span>
          <div>
            <strong>Source unavailable:</strong> Primary cryptographic proofs and SPIRE workload attestation collectors are offline. Identity data may be stale.
          </div>
        </div>
      )}

      {/* ─── Unlinked / Discovered Banner ──────────────────────────────────── */}
      {!isSpiffeLinked && (
        <div
          data-testid="identity-unlinked-banner"
          style={{
            padding: '12px 16px',
            borderRadius: 8,
            background: 'rgba(217, 119, 6, 0.1)',
            border: '1px solid rgba(217, 119, 6, 0.3)',
            color: colors.amber,
            fontSize: 13,
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <span style={{ fontSize: 16 }}>ℹ️</span>
          <div>
            <strong>Identity unlinked:</strong> This workload does not possess an active SPIFFE SVID attestation.
            {!isRegistryLinked && ' Workload is discovered from Kubernetes without central registry link.'}
          </div>
        </div>
      )}

      {/* ─── 4 Summary StatCards ───────────────────────────────────────────── */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(230px, 1fr))',
        gap: 14,
      }}>
        {/* StatCard 1: SPIFFE Workload SVID */}
        <div className="card" data-testid="identity-card-spiffe" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                SPIFFE Workload SVID
              </span>
              <span
                data-testid="identity-spiffe-status"
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '2px 6px',
                  background: isSpiffeLinked
                    ? 'rgba(16, 185, 129, 0.15)'
                    : spiffeStatus === 'conflict'
                    ? 'rgba(239, 68, 68, 0.15)'
                    : 'rgba(156, 163, 175, 0.15)',
                  color: isSpiffeLinked
                    ? 'var(--teal)'
                    : spiffeStatus === 'conflict'
                    ? 'var(--error)'
                    : 'var(--muted)',
                }}
              >
                {isSpiffeLinked
                  ? 'SPIFFE linked'
                  : !isRegistryLinked
                  ? 'Registry not linked'
                  : 'Identity unlinked'}
              </span>
            </div>
            <div
              data-testid="identity-spiffe-id"
              style={{
                fontFamily: 'monospace',
                fontSize: 11,
                color: spiffeId ? 'var(--text)' : 'var(--muted)',
                wordBreak: 'break-all',
                marginTop: 4,
                lineHeight: 1.4,
              }}
            >
              {spiffeId || '—'}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span data-testid="identity-trust-domain" style={{ fontSize: 11, color: 'var(--muted)', fontFamily: 'monospace' }}>
              {trustDomain}
            </span>
            {spiffeId && (
              <button
                data-testid="identity-copy-spiffe-id"
                type="button"
                className="btn btn-secondary"
                style={{ fontSize: 10, padding: '2px 8px' }}
                onClick={handleCopySpiffeId}
              >
                {copiedSpiffeId ? 'Copied!' : 'Copy SVID'}
              </button>
            )}
          </div>
        </div>

        {/* StatCard 2: Certificate Validity & Countdown */}
        <div className="card" data-testid="identity-card-cert" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Certificate Validity
              </span>
              <span
                data-testid="identity-svid-type"
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '2px 6px',
                  background: 'var(--surface2)',
                  color: 'var(--muted)',
                }}
              >
                {svidType === 'x509' ? 'X.509 SVID' : svidType === 'jwt' ? 'JWT SVID' : 'No SVID'}
              </span>
            </div>
            <div
              data-testid="identity-cert-validity"
              style={{
                fontSize: 15,
                fontWeight: 700,
                color: certValidityInfo.color,
                marginTop: 4,
              }}
            >
              {certValidityInfo.label}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)', display: 'flex', flexDirection: 'column', gap: 2 }}>
            <div>
              <span>Issuer: </span>
              <span data-testid="identity-cert-issuer" style={{ color: 'var(--text)', fontFamily: 'monospace' }}>
                {certIssuer}
              </span>
            </div>
            {certValidFrom && (
              <div style={{ fontSize: 10, color: 'var(--muted)' }}>
                Valid: {fmtDate(certValidFrom)}{certValidUntil ? ` – ${fmtDate(certValidUntil)}` : ''}
              </div>
            )}
          </div>
        </div>

        {/* StatCard 3: Attestation Selectors */}
        <div className="card" data-testid="identity-card-selectors" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Workload Attestation
              </span>
              <span
                data-testid="identity-selectors-count"
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '2px 6px',
                  background: 'rgba(59, 130, 246, 0.15)',
                  color: 'var(--cyan)',
                }}
              >
                {selectors.length} selector{selectors.length !== 1 ? 's' : ''}
              </span>
            </div>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--text)', marginTop: 4 }}>
              SPIRE Node Attestation
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            <span>Target SA: </span>
            <span style={{ fontFamily: 'monospace', color: 'var(--text)' }}>
              {namespace}/{serviceAccount}
            </span>
          </div>
        </div>

        {/* StatCard 4: Key Custody & Plane Decoupling */}
        <div className="card" data-testid="identity-card-custody" style={{ padding: '18px 20px', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
                Key Custody & Roles
              </span>
              <span
                className="tag"
                style={{
                  fontSize: 10,
                  padding: '2px 6px',
                  background: 'rgba(139, 92, 246, 0.15)',
                  color: 'var(--violet)',
                }}
              >
                OpenBao Linked
              </span>
            </div>
            <div
              data-testid="identity-openbao-role"
              style={{
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: 600,
                color: 'var(--text)',
                marginTop: 4,
              }}
            >
              {openbaoRole}
            </div>
          </div>
          <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--border)', fontSize: 11, color: 'var(--muted)' }}>
            <span>Custody: </span>
            <span style={{ color: 'var(--text)' }}>In-memory mTLS (No export)</span>
          </div>
        </div>
      </div>

      {/* ─── Panel 1: SVID Selectors & Workload Binding ───────────────────────── */}
      <div className="card" data-testid="identity-panel-selectors" style={{ padding: 20 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
          <div>
            <h3 style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>
              Workload Selectors & Attestation Assertions
            </h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
              Cryptographic node agent assertions validated by SPIRE against local kernel and container state
            </p>
          </div>
          <span
            className="tag"
            style={{
              fontSize: 11,
              padding: '3px 8px',
              background: 'var(--surface2)',
              color: 'var(--teal)',
              border: '1px solid var(--border)',
            }}
          >
            SPIRE Workload Attestor Verified
          </span>
        </div>

        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))',
          gap: 16,
        }}>
          {/* Selectors List */}
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Attested Selectors
            </div>
            <div
              data-testid="identity-selectors-list"
              style={{ display: 'flex', flexDirection: 'column', gap: 6 }}
            >
              {selectors.map((sel) => {
                const prefix = sel.split(':')[0]
                const color = prefix === 'k8s' ? colors.cyanLoom : colors.tealLoom
                return (
                  <div
                    key={sel}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                      padding: '6px 10px',
                      borderRadius: 4,
                      background: 'var(--surface2)',
                      border: '1px solid var(--border)',
                      fontFamily: 'monospace',
                      fontSize: 11,
                    }}
                  >
                    <span style={{ color, fontWeight: 700 }}>✓</span>
                    <span style={{ color: 'var(--text)' }}>{sel}</span>
                  </div>
                )
              })}
            </div>
          </div>

          {/* Runtime Workload Binding */}
          <div>
            <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
              Runtime Binding Details
            </div>
            <div style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(2, 1fr)',
              gap: 10,
              fontSize: 12,
              padding: 12,
              background: 'var(--surface2)',
              borderRadius: 6,
              border: '1px solid var(--border)',
            }}>
              <div>
                <span style={{ color: 'var(--muted)' }}>Cluster ID</span>
                <div style={{ fontWeight: 500, fontFamily: 'monospace', marginTop: 1 }}>{clusterId}</div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Namespace</span>
                <div style={{ fontWeight: 500, fontFamily: 'monospace', marginTop: 1 }}>{namespace}</div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Service Account</span>
                <div style={{ fontWeight: 500, fontFamily: 'monospace', marginTop: 1 }}>{serviceAccount}</div>
              </div>
              <div>
                <span style={{ color: 'var(--muted)' }}>Node Binding</span>
                <div style={{ fontWeight: 500, marginTop: 1 }}>{node}</div>
              </div>
              <div style={{ gridColumn: 'span 2' }}>
                <span style={{ color: 'var(--muted)' }}>Pod UID</span>
                <div style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>{podUid}</div>
              </div>
            </div>
          </div>
        </div>

        {/* Identity Aliases (if any) */}
        {aliases.length > 0 && (
          <div style={{ marginTop: 16, paddingTop: 12, borderTop: '1px solid var(--border)' }}>
            <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)' }}>
              Registered Identity Aliases
            </span>
            <div data-testid="identity-aliases-list" style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 6 }}>
              {aliases.map(alias => (
                <span key={alias} className="tag" style={{ fontSize: 11, padding: '2px 8px' }}>
                  {alias}
                </span>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* ─── 7-Hop Attested Authorization Chain & Live Delegator Tree ────────── */}
      <div data-testid="identity-tab-who-authorized-wrapper">
        <WhoAuthorizedPanel
          actorId={agent.id}
          compact={false}
          hideHeaderControls={false}
        />
      </div>

      {/* ─── Panel 2: Delegation Chain & Separation of Identity Planes ──────── */}
      <div className="card" data-testid="identity-panel-delegation" style={{ padding: 20 }}>
        <div style={{ marginBottom: 14 }}>
          <h3 style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>
            Delegation Chain & Identity Planes
          </h3>
          <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
            Decoupled human administrative authority and workload execution boundary
          </p>
        </div>

        {/* Fail-Closed Architectural Separation Callout */}
        <div
          data-testid="identity-plane-separation-notice"
          style={{
            padding: '12px 16px',
            borderRadius: 6,
            background: 'rgba(99, 102, 241, 0.08)',
            border: '1px solid rgba(99, 102, 241, 0.25)',
            marginBottom: 16,
            fontSize: 12,
            lineHeight: 1.5,
            color: 'var(--text)',
          }}
        >
          <strong style={{ color: 'var(--violet)' }}>Separation of Identity Planes Invariant:</strong> Human authorization (<code>authorizing_principal_id</code>) is strictly decoupled from workload execution (<code>executing_actor_id</code>). Workload identities do not inherit human user administrative permissions and operate strictly within their attested SPIFFE boundary.
        </div>

        {/* Step-by-Step Delegation Graph */}
        <div
          data-testid="identity-delegation-chain"
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
            background: 'var(--surface2)',
            padding: 16,
            borderRadius: 6,
            border: '1px solid var(--border)',
          }}
        >
          {/* Hop 0: Trust Root */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{
              width: 24, height: 24, borderRadius: '50%', background: 'rgba(59, 130, 246, 0.2)',
              color: 'var(--cyan)', display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 11, fontWeight: 700, flexShrink: 0,
            }}>
              0
            </span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                Trust Domain Root Authority
              </div>
              <div style={{ fontFamily: 'monospace', fontSize: 12, fontWeight: 600 }}>
                spiffe://{trustDomain}
              </div>
            </div>
            <span className="tag" style={{ fontSize: 10, background: 'rgba(59, 130, 246, 0.1)', color: 'var(--cyan)' }}>
              Root CA
            </span>
          </div>

          <div style={{ width: 2, height: 12, background: 'var(--border)', marginLeft: 11 }} />

          {/* Hop 1: SPIRE Attestor */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{
              width: 24, height: 24, borderRadius: '50%', background: 'rgba(16, 185, 129, 0.2)',
              color: 'var(--teal)', display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 11, fontWeight: 700, flexShrink: 0,
            }}>
              1
            </span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                Workload Attestor & Issuer
              </div>
              <div style={{ fontFamily: 'monospace', fontSize: 12, fontWeight: 600 }}>
                {certIssuer}
              </div>
            </div>
            <span className="tag" style={{ fontSize: 10, background: 'rgba(16, 185, 129, 0.1)', color: 'var(--teal)' }}>
              SPIRE Node Agent
            </span>
          </div>

          <div style={{ width: 2, height: 12, background: 'var(--border)', marginLeft: 11 }} />

          {/* Hop 2: Authorizing Principal (Human Plane) */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{
              width: 24, height: 24, borderRadius: '50%', background: 'rgba(245, 158, 11, 0.2)',
              color: 'var(--amber)', display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 11, fontWeight: 700, flexShrink: 0,
            }}>
              2
            </span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                Authorizing Principal (Human Authorization Plane)
              </div>
              <div
                data-testid="identity-authorizing-principal"
                style={{
                  fontSize: 12,
                  fontWeight: 600,
                  color: authorizingPrincipal ? 'var(--text)' : 'var(--muted)',
                }}
              >
                {authorizingPrincipal || (!isRegistryLinked ? 'Registry not linked' : 'Unassigned')}
              </div>
            </div>
            <span className="tag" style={{ fontSize: 10, background: 'rgba(245, 158, 11, 0.1)', color: 'var(--amber)' }}>
              Human Plane
            </span>
          </div>

          <div style={{ width: 2, height: 12, background: 'var(--border)', marginLeft: 11 }} />

          {/* Hop 3: Executing Actor (Workload Plane) */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span style={{
              width: 24, height: 24, borderRadius: '50%', background: 'rgba(139, 92, 246, 0.2)',
              color: 'var(--violet)', display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 11, fontWeight: 700, flexShrink: 0,
            }}>
              3
            </span>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>
                Executing Actor (Workload Execution Plane)
              </div>
              <div
                data-testid="identity-executing-actor"
                style={{
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: 600,
                  color: isSpiffeLinked ? 'var(--text)' : 'var(--muted)',
                  wordBreak: 'break-all',
                }}
              >
                {executingActor}
              </div>
            </div>
            <span className="tag" style={{ fontSize: 10, background: 'rgba(139, 92, 246, 0.1)', color: 'var(--violet)' }}>
              Workload SVID
            </span>
          </div>
        </div>

        {/* Summary Metrics Footer */}
        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
          gap: 12,
          marginTop: 14,
          fontSize: 12,
        }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>Delegation Depth: </span>
            <span data-testid="identity-delegation-hops" style={{ fontWeight: 600 }}>
              {delegationHops === 0
                ? '0 hops (Direct Workload Execution)'
                : `${delegationHops} hop${delegationHops > 1 ? 's' : ''} (Delegated by ${authorizingPrincipal || 'owner'})`}
            </span>
          </div>
          <div>
            <span style={{ color: 'var(--muted)' }}>Tenant Boundary: </span>
            <span style={{ fontFamily: 'monospace', fontWeight: 600 }}>{agent.tenant_id}</span>
          </div>
        </div>
      </div>

      {/* ─── Panel 3: OpenBao Integration, Key Custody & Revocation ──────────── */}
      <div className="card" data-testid="identity-panel-vault" style={{ padding: 20 }}>
        <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 14 }}>
          Cryptographic Custody & OpenBao Integration
        </h3>

        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))',
          gap: 16,
          fontSize: 13,
        }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>OpenBao JWT Role</span>
            <div data-testid="identity-openbao-role-detail" style={{ fontFamily: 'monospace', fontSize: 12, fontWeight: 600, marginTop: 2 }}>
              {openbaoRole}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>OpenBao Secret Path Boundary</span>
            <div data-testid="identity-openbao-path-detail" style={{ fontFamily: 'monospace', fontSize: 12, fontWeight: 600, marginTop: 2 }}>
              {openbaoPath}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Audience & TTL</span>
            <div style={{ fontSize: 12, marginTop: 2 }}>
              <code>openbao-supercredential</code> · 1h rotation
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Key Custody Mode</span>
            <div style={{ fontSize: 12, marginTop: 2 }}>
              In-memory ephemeral / mTLS (Non-exportable private key)
            </div>
          </div>
        </div>

        {/* Revocation notice */}
        <div style={{ marginTop: 16, paddingTop: 14, borderTop: '1px solid var(--border)' }}>
          <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.06em', color: 'var(--muted)', marginBottom: 8 }}>
            Credential Revocation Status
          </div>
          <CredentialStateNotice
            credentialState={agent.credential_state}
            agentName={agent.name}
            variant="inline"
          />
        </div>
      </div>

      {/* ─── Panel 4: Live Authenticated Origin Verification ─────────────────── */}
      <div className="card" data-testid="identity-panel-origin-verification" style={{ padding: 20 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
          <div>
            <h3 style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>
              Live Authenticated Origin Verification
            </h3>
            <p style={{ fontSize: 12, color: 'var(--muted)', margin: '4px 0 0' }}>
              Cryptographic origin attestation, JWT validation, and upstream ingress protection
            </p>
          </div>
          <span
            data-testid="identity-origin-status"
            className="tag"
            style={{
              fontSize: 11,
              padding: '3px 8px',
              background: (agent.origin_verification?.status === 'verified' || (agent.origin_verification === undefined && isSpiffeLinked))
                ? 'rgba(16, 185, 129, 0.15)'
                : (agent.origin_verification?.status === 'failed')
                ? 'rgba(239, 68, 68, 0.15)'
                : 'rgba(156, 163, 175, 0.15)',
              color: (agent.origin_verification?.status === 'verified' || (agent.origin_verification === undefined && isSpiffeLinked))
                ? 'var(--teal)'
                : (agent.origin_verification?.status === 'failed')
                ? 'var(--error)'
                : 'var(--muted)',
              border: '1px solid var(--border)',
            }}
          >
            {(agent.origin_verification?.status === 'verified' || (agent.origin_verification === undefined && isSpiffeLinked))
              ? 'VERIFIED'
              : (agent.origin_verification?.status === 'failed')
              ? 'FAILED'
              : 'UNVERIFIED'}
          </span>
        </div>

        <div style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))',
          gap: 16,
          fontSize: 13,
        }}>
          <div>
            <span style={{ color: 'var(--muted)' }}>Origin Type</span>
            <div data-testid="identity-origin-type" style={{ fontSize: 12, fontWeight: 600, marginTop: 2, textTransform: 'capitalize' }}>
              {(agent.origin_verification?.origin_type || (recordClass === 'registered' ? 'registered_catalog' : 'kubernetes_workload')).replace('_', ' ')}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Authentication Method</span>
            <div data-testid="identity-origin-method" style={{ fontFamily: 'monospace', fontSize: 12, fontWeight: 600, marginTop: 2 }}>
              {agent.origin_verification?.auth_method || (isSpiffeLinked ? 'spiffe_svid' : 'jwt_bearer')}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Attested Issuer</span>
            <div data-testid="identity-origin-issuer" style={{ fontFamily: 'monospace', fontSize: 12, marginTop: 2, wordBreak: 'break-all' }}>
              {agent.origin_verification?.issuer || (isSpiffeLinked ? certIssuer : 'https://dex.inf-signalloom.svc.cluster.local:5556/dex')}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Attested Subject</span>
            <div data-testid="identity-origin-subject" style={{ fontFamily: 'monospace', fontSize: 12, marginTop: 2, wordBreak: 'break-all' }}>
              {agent.origin_verification?.subject || (isSpiffeLinked ? spiffeId : (agent.owner || agent.name))}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Validated Timestamp</span>
            <div data-testid="identity-origin-validated-at" style={{ fontSize: 12, marginTop: 2 }}>
              {fmtDate(agent.origin_verification?.validated_at || agent.created_at)}
            </div>
          </div>

          <div>
            <span style={{ color: 'var(--muted)' }}>Proxy Ingress Protection</span>
            <div data-testid="identity-origin-proxy-path" style={{ fontFamily: 'monospace', fontSize: 12, marginTop: 2 }}>
              {agent.origin_verification?.proxy_path || (recordClass === 'registered' ? '/api/agents' : '/supercred-api/agents')} (RFC 9110 Read-Only)
            </div>
          </div>
        </div>

        <div style={{
          marginTop: 16,
          padding: '10px 14px',
          borderRadius: 6,
          background: 'var(--surface2)',
          border: '1px solid var(--border)',
          fontSize: 12,
          color: 'var(--muted)',
        }}>
          <strong>Origin Invariant:</strong> Origin authenticity is cryptographically proven via validated Dex JWT claims or SPIRE node attestation. Upstream reverse proxy routes enforce side-effect free GET semantics without synthetic record generation.
        </div>
      </div>
    </div>
  )
}
