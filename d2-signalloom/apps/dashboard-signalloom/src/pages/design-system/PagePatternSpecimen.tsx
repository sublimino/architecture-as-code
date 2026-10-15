import React, { useState } from 'react'
import { PagePattern, PageHeader, PageLoader } from '../../components/common/PagePattern'
import NotFoundPage from '../NotFoundPage'
import LoadingState from '../../components/LoadingState'
import ErrorState from '../../components/ErrorState'
import EmptyState from '../../components/EmptyState'

export type PagePatternDemoState =
  | 'healthy'
  | 'route-loading'
  | 'in-page-loading'
  | 'error'
  | 'empty'
  | 'not-found'

export function PagePatternSpecimen(): React.JSX.Element {
  const [activeState, setActiveState] = useState<PagePatternDemoState>('healthy')
  const [retryNotice, setRetryNotice] = useState<string | null>(null)

  const buttonStyle = (state: PagePatternDemoState): React.CSSProperties => ({
    padding: '6px 12px',
    fontSize: 12,
    borderRadius: 4,
    border: '1px solid var(--border)',
    background: activeState === state ? 'var(--accent, #00d2ff)' : 'var(--surface)',
    color: activeState === state ? '#000' : 'var(--text)',
    fontWeight: activeState === state ? 600 : 400,
    cursor: 'pointer',
    transition: 'all 0.15s ease',
  })

  return (
    <div data-testid="ds-page-patterns-specimen" style={{ width: '100%' }}>
      <p style={{ fontSize: 13, color: 'var(--muted)', marginBottom: 16, lineHeight: 1.5 }}>
        Canonical page pattern governing all views in Signal Loom. Select a lifecycle state
        below to observe how route-level gating, initial loading (honoring user settings),
        in-page loading states, error recovery, empty datasets, and terminal error pages behave.
      </p>

      {/* State Switcher Bar */}
      <div
        data-testid="ds-page-pattern-switcher"
        style={{
          display: 'flex',
          gap: 8,
          marginBottom: 20,
          flexWrap: 'wrap',
          alignItems: 'center',
          padding: '10px 14px',
          background: 'var(--surface2, rgba(255,255,255,0.03))',
          borderRadius: 6,
          border: '1px solid var(--border)',
        }}
      >
        <span style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', color: 'var(--muted)', marginRight: 4 }}>
          State:
        </span>
        <button
          type="button"
          data-testid="btn-pattern-healthy"
          style={buttonStyle('healthy')}
          onClick={() => {
            setActiveState('healthy')
            setRetryNotice(null)
          }}
        >
          Healthy Content
        </button>
        <button
          type="button"
          data-testid="btn-pattern-route-loading"
          style={buttonStyle('route-loading')}
          onClick={() => {
            setActiveState('route-loading')
            setRetryNotice(null)
          }}
        >
          Route Loading (PixelLoader)
        </button>
        <button
          type="button"
          data-testid="btn-pattern-in-page-loading"
          style={buttonStyle('in-page-loading')}
          onClick={() => {
            setActiveState('in-page-loading')
            setRetryNotice(null)
          }}
        >
          In-Page Loading (LoadingState)
        </button>
        <button
          type="button"
          data-testid="btn-pattern-error"
          style={buttonStyle('error')}
          onClick={() => {
            setActiveState('error')
            setRetryNotice(null)
          }}
        >
          Error with Retry
        </button>
        <button
          type="button"
          data-testid="btn-pattern-empty"
          style={buttonStyle('empty')}
          onClick={() => {
            setActiveState('empty')
            setRetryNotice(null)
          }}
        >
          Empty Dataset
        </button>
        <button
          type="button"
          data-testid="btn-pattern-not-found"
          style={buttonStyle('not-found')}
          onClick={() => {
            setActiveState('not-found')
            setRetryNotice(null)
          }}
        >
          Terminal 404 (NotFoundPage)
        </button>
      </div>

      {retryNotice && (
        <div
          data-testid="pattern-retry-notice"
          style={{
            marginBottom: 12,
            padding: '6px 12px',
            fontSize: 12,
            borderRadius: 4,
            background: 'rgba(0, 210, 255, 0.1)',
            color: 'var(--cyan, #00d2ff)',
            border: '1px solid var(--cyan, #00d2ff)',
          }}
        >
          {retryNotice}
        </div>
      )}

      {/* Specimen Frame */}
      <div
        data-testid="ds-page-pattern-stage"
        style={{
          border: '1px solid var(--border)',
          borderRadius: 8,
          background: 'var(--surface)',
          padding: 24,
          minHeight: 280,
        }}
      >
        {activeState === 'healthy' && (
          <PagePattern
            title="Agent Governance"
            eyebrow="Estate"
            description="Live monitored agent workloads with SPIFFE attestation, CEL admission controls, and cryptographic audit proofs."
            hint="Agents in this estate report status heartbeats every 2.5s."
            actions={
              <>
                <button type="button" className="btn btn-secondary" style={{ fontSize: 12 }}>
                  Export JSON
                </button>
                <button type="button" className="btn btn-primary" style={{ fontSize: 12 }}>
                  Register Agent
                </button>
              </>
            }
          >
            <div
              data-testid="pattern-demo-content"
              style={{
                display: 'grid',
                gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
                gap: 14,
                marginTop: 16,
              }}
            >
              <div className="card" style={{ padding: 16 }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                  Governed Agents
                </div>
                <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4, color: 'var(--text)' }}>
                  12 Active
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  100% compliant with CIS v1.8.0
                </div>
              </div>

              <div className="card" style={{ padding: 16 }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                  Cryptographic Trust
                </div>
                <div style={{ fontSize: 24, fontWeight: 700, marginTop: 4, color: 'var(--teal, #00c853)' }}>
                  SPIFFE Linked
                </div>
                <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 4 }}>
                  OpenBao SVID leases active
                </div>
              </div>
            </div>
          </PagePattern>
        )}

        {activeState === 'route-loading' && (
          <PageLoader label="Loading Agents" minHeight={220} announce={false} testId="specimen-route-loader" />
        )}

        {activeState === 'in-page-loading' && (
          <div>
            <PageHeader
              title="Agent Governance"
              eyebrow="Estate"
              description="Live monitored agent workloads with SPIFFE attestation."
            />
            {/* Mock in-page LoadingState styling without adding extra live region to gallery roster */}
            <div
              data-testid="ds-pattern-mock-loading"
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                padding: '40px 20px',
                border: '1px dashed var(--border)',
                borderRadius: 6,
                background: 'var(--surface2)',
                color: 'var(--muted)',
                fontSize: 13,
                gap: 10,
              }}
            >
              <span style={{ fontWeight: 600 }}>Refreshing…</span>
              <span>Fetching latest telemetry from eBPF Sentinel</span>
            </div>
          </div>
        )}

        {activeState === 'error' && (
          <div>
            <PageHeader
              title="Agent Governance"
              eyebrow="Estate"
              description="Live monitored agent workloads with SPIFFE attestation."
            />
            <ErrorState
              message="Upstream policy-engine service timed out after 30s. Connection reset by peer."
              onRetry={() => setRetryNotice('Retry invoked: reconnecting to policy-engine...')}
            />
          </div>
        )}

        {activeState === 'empty' && (
          <div>
            <PageHeader
              title="Agent Governance"
              eyebrow="Estate"
              description="Live monitored agent workloads with SPIFFE attestation."
            />
            <EmptyState
              kicker="No agent workloads found"
              body="No agents currently match the active namespace and framework filters. Clear your filters or enroll a new agent."
            />
          </div>
        )}

        {activeState === 'not-found' && (
          <NotFoundPage />
        )}
      </div>
    </div>
  )
}

export default PagePatternSpecimen
