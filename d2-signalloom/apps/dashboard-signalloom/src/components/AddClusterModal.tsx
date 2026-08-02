/**
 * AddClusterModal — UI-only modal for connecting a remote Kubernetes cluster.
 *
 * Supports three connection methods: Kubeconfig, Service Account, and API
 * Endpoint. On submit, the cluster is added to a local in-memory list (no
 * backend call). A success toast confirms the add.
 */
import { useState } from 'react'

type ConnectionMethod = 'kubeconfig' | 'service-account' | 'api-endpoint'

export interface NewClusterEntry {
  name: string
  method: ConnectionMethod
  /** Kubeconfig path, SA token, or API URL depending on method. */
  connectionValue: string
  /** API token — only used when method is 'api-endpoint'. */
  apiToken?: string
}

interface Props {
  onAdd: (entry: NewClusterEntry) => void
  onClose: () => void
}

const connectionLabels: Record<ConnectionMethod, string> = {
  kubeconfig: 'Kubeconfig',
  'service-account': 'Service Account',
  'api-endpoint': 'API Endpoint',
}

const connectionPlaceholders: Record<ConnectionMethod, string> = {
  kubeconfig: '/path/to/kubeconfig.yaml',
  'service-account': 'eyJhbGciOiJSUzI1NiIs...',
  'api-endpoint': 'https://k8s-api.example.com:6443',
}

const connectionHelp: Record<ConnectionMethod, string> = {
  kubeconfig: 'Path to a kubeconfig file with cluster credentials.',
  'service-account': 'A long-lived ServiceAccount bearer token.',
  'api-endpoint': 'The Kubernetes API server URL and a bearer token for authentication.',
}

export default function AddClusterModal({ onAdd, onClose }: Props) {
  const [name, setName] = useState('')
  const [method, setMethod] = useState<ConnectionMethod>('kubeconfig')
  const [connectionValue, setConnectionValue] = useState('')
  const [apiToken, setApiToken] = useState('')
  const [success, setSuccess] = useState(false)

  const canSubmit = name.trim().length > 0 && connectionValue.trim().length > 0
    && (method !== 'api-endpoint' || apiToken.trim().length > 0)

  function handleSubmit() {
    if (!canSubmit) return

    onAdd({
      name: name.trim(),
      method,
      connectionValue: connectionValue.trim(),
      apiToken: method === 'api-endpoint' ? apiToken.trim() : undefined,
    })

    setSuccess(true)
    setTimeout(() => onClose(), 1500)
  }

  return (
    <div
      data-testid="add-cluster-modal"
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.53)',
        backdropFilter: 'blur(6px)', display: 'flex', alignItems: 'center',
        justifyContent: 'center', zIndex: 2000,
      }}
      onClick={e => { if (e.target === e.currentTarget) onClose() }}
    >
      <div
        className="card slide-up"
        style={{ width: 520, maxWidth: '95vw', padding: 28 }}
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-cluster-title"
      >
        <h2
          id="add-cluster-title"
          style={{ fontSize: 17, fontWeight: 700, marginBottom: 4 }}
        >
          Add Cluster
        </h2>
        <p style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 20 }}>
          Connect a remote Kubernetes cluster for RBAC analysis.
        </p>

        {success ? (
          <div
            data-testid="add-cluster-success"
            style={{
              padding: '16px 20px', borderRadius: 8,
              background: 'rgba(16,185,129,0.08)', border: '1px solid rgba(16,185,129,0.25)',
              color: 'var(--teal)', fontSize: 14, textAlign: 'center',
            }}
          >
            Cluster "{name}" added successfully.
          </div>
        ) : (
          <>
            {/* Cluster name */}
            <div style={{ marginBottom: 16 }}>
              <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>
                Cluster Name
              </label>
              <input
                data-testid="add-cluster-name"
                type="text"
                value={name}
                onChange={e => setName(e.target.value)}
                placeholder="production-eu-west-1"
                style={{
                  width: '100%', padding: '8px 12px', borderRadius: 6,
                  border: '1px solid var(--border)', background: 'var(--surface2)',
                  color: 'var(--text)', fontSize: 13, boxSizing: 'border-box',
                }}
              />
            </div>

            {/* Connection method */}
            <div style={{ marginBottom: 16 }}>
              <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>
                Connection Method
              </label>
              <select
                data-testid="add-cluster-method"
                value={method}
                onChange={e => {
                  setMethod(e.target.value as ConnectionMethod)
                  setConnectionValue('')
                  setApiToken('')
                }}
                style={{
                  width: '100%', padding: '8px 12px', borderRadius: 6,
                  border: '1px solid var(--border)', background: 'var(--surface2)',
                  color: 'var(--text)', fontSize: 13, boxSizing: 'border-box',
                }}
              >
                {(Object.keys(connectionLabels) as ConnectionMethod[]).map(m => (
                  <option key={m} value={m}>{connectionLabels[m]}</option>
                ))}
              </select>
              <div style={{ fontSize: 11, color: 'var(--dim)', marginTop: 4 }}>
                {connectionHelp[method]}
              </div>
            </div>

            {/* Connection value */}
            <div style={{ marginBottom: method === 'api-endpoint' ? 16 : 20 }}>
              <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>
                {method === 'kubeconfig' ? 'Kubeconfig Path' : method === 'service-account' ? 'SA Token' : 'API URL'}
              </label>
              <input
                data-testid="add-cluster-value"
                type="text"
                value={connectionValue}
                onChange={e => setConnectionValue(e.target.value)}
                placeholder={connectionPlaceholders[method]}
                style={{
                  width: '100%', padding: '8px 12px', borderRadius: 6,
                  border: '1px solid var(--border)', background: 'var(--surface2)',
                  color: 'var(--text)', fontSize: 13, fontFamily: 'monospace',
                  boxSizing: 'border-box',
                }}
              />
            </div>

            {/* API token — only for api-endpoint method */}
            {method === 'api-endpoint' && (
              <div style={{ marginBottom: 20 }}>
                <label style={{ fontSize: 12, color: 'var(--muted)', display: 'block', marginBottom: 4 }}>
                  Bearer Token
                </label>
                <input
                  data-testid="add-cluster-token"
                  type="password"
                  value={apiToken}
                  onChange={e => setApiToken(e.target.value)}
                  placeholder="eyJhbGciOiJSUzI1NiIs..."
                  style={{
                    width: '100%', padding: '8px 12px', borderRadius: 6,
                    border: '1px solid var(--border)', background: 'var(--surface2)',
                    color: 'var(--text)', fontSize: 13, fontFamily: 'monospace',
                    boxSizing: 'border-box',
                  }}
                />
              </div>
            )}

            {/* Actions */}
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button className="btn btn-secondary" onClick={onClose}>
                Cancel
              </button>
              <button
                data-testid="add-cluster-submit"
                className="btn btn-primary"
                disabled={!canSubmit}
                onClick={handleSubmit}
                style={{ minWidth: 120 }}
              >
                Add Cluster
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
