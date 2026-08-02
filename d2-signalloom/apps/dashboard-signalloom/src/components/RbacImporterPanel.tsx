import { useCallback, useEffect, useRef, useState } from 'react'
import {
  deriveNamespaces,
  fetchJsonOrThrow,
  parseClusterList,
  parseRbacData,
  type ClusterMeta,
  type RBACData,
} from '../api/afmApi'
import { convertRbacToAfmImport, emitYaml } from '../api/afmYaml'
import { isDemoMode } from '../api/demoMode'

type CopyFeedback =
  | { tone: 'success'; message: string }
  | { tone: 'hint'; message: string }

function toInlineErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof DOMException && error.name === 'AbortError') {
    return `${fallback} The AFM request timed out after 15 seconds.`
  }
  if (error instanceof Error && error.message) {
    return error.message
  }
  return fallback
}

async function readClusters(): Promise<ClusterMeta[]> {
  return parseClusterList(await fetchJsonOrThrow('/clusters'))
}

async function readClusterRbac(clusterId: string): Promise<RBACData> {
  const path = `/clusters/${encodeURIComponent(clusterId)}/rbac`
  try {
    return parseRbacData(await fetchJsonOrThrow(path))
  } catch (error) {
    // Keep the failing path in the message — the parser only knows the shape.
    const detail = error instanceof Error ? error.message : String(error)
    throw new Error(`${detail} (from ${path})`)
  }
}

export default function RbacImporterPanel() {
  const [clusters, setClusters] = useState<ClusterMeta[]>([])
  const [selectedClusterId, setSelectedClusterId] = useState('')
  const [selectedNamespace, setSelectedNamespace] = useState('all')
  const [namespaces, setNamespaces] = useState<string[]>([])
  const [yamlText, setYamlText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [copyFeedback, setCopyFeedback] = useState<CopyFeedback | null>(null)
  const [isLoadingClusters, setIsLoadingClusters] = useState(true)
  const [isLoadingRbac, setIsLoadingRbac] = useState(false)

  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const requestSequenceRef = useRef(0)
  const copyResetTimeoutRef = useRef<number | null>(null)

  const demo = isDemoMode()

  // In live mode, show only the host cluster (relabel the local/first cluster).
  // In demo mode, show all AFM clusters as-is.
  const displayClusters = demo
    ? clusters
    : clusters.length > 0
      ? [{ id: (clusters.find(c => c.id === 'local') ?? clusters[0]).id, name: 'Host Cluster' }]
      : []

  const selectedCluster = displayClusters.find(cluster => cluster.id === selectedClusterId) ?? null
  const hasClusters = displayClusters.length > 0
  const fetchDisabled = isLoadingClusters || isLoadingRbac || selectedCluster === null

  const clearCopyResetTimeout = useCallback(() => {
    if (copyResetTimeoutRef.current !== null) {
      window.clearTimeout(copyResetTimeoutRef.current)
      copyResetTimeoutRef.current = null
    }
  }, [])

  const resetCopyFeedback = useCallback(() => {
    clearCopyResetTimeout()
    setCopyFeedback(null)
  }, [clearCopyResetTimeout])

  const queueCopiedReset = useCallback(() => {
    clearCopyResetTimeout()
    copyResetTimeoutRef.current = window.setTimeout(() => {
      setCopyFeedback(null)
      copyResetTimeoutRef.current = null
    }, 2000)
  }, [clearCopyResetTimeout])

  const isCurrentRequest = useCallback((sequence: number): boolean => {
    return requestSequenceRef.current === sequence
  }, [])

  const preloadNamespaces = useCallback(async (cluster: ClusterMeta, sequence: number) => {
    setIsLoadingRbac(true)

    try {
      const rbac = await readClusterRbac(cluster.id)
      if (!isCurrentRequest(sequence)) {
        return
      }

      setNamespaces(deriveNamespaces(rbac))
      setError(null)
    } catch (nextError: unknown) {
      if (!isCurrentRequest(sequence)) {
        return
      }

      setNamespaces([])
      setError(toInlineErrorMessage(nextError, `Unable to load RBAC namespaces for ${cluster.name}.`))
    } finally {
      if (isCurrentRequest(sequence)) {
        setIsLoadingRbac(false)
      }
    }
  }, [isCurrentRequest])

  useEffect(() => {
    let disposed = false

    async function loadInitialData() {
      const sequence = ++requestSequenceRef.current

      setIsLoadingClusters(true)
      setIsLoadingRbac(false)
      setError(null)
      setYamlText('')
      setNamespaces([])
      setSelectedNamespace('all')
      resetCopyFeedback()

      try {
        const nextClusters = await readClusters()
        if (disposed || !isCurrentRequest(sequence)) {
          return
        }

        setClusters(nextClusters)
        setIsLoadingClusters(false)

        if (nextClusters.length === 0) {
          setSelectedClusterId('')
          return
        }

        const defaultCluster = nextClusters.find(cluster => cluster.id === 'local') ?? nextClusters[0]
        setSelectedClusterId(defaultCluster.id)
        await preloadNamespaces(defaultCluster, sequence)
      } catch (nextError: unknown) {
        if (disposed || !isCurrentRequest(sequence)) {
          return
        }

        setClusters([])
        setSelectedClusterId('')
        setNamespaces([])
        setError(toInlineErrorMessage(nextError, 'Unable to load AFM clusters.'))
        setIsLoadingClusters(false)
        setIsLoadingRbac(false)
      }
    }

    void loadInitialData()

    return () => {
      disposed = true
      requestSequenceRef.current += 1
      clearCopyResetTimeout()
    }
  }, [clearCopyResetTimeout, isCurrentRequest, preloadNamespaces, resetCopyFeedback])

  async function handleClusterChange(nextClusterId: string) {
    const nextCluster = clusters.find(cluster => cluster.id === nextClusterId) ?? null

    setSelectedClusterId(nextClusterId)
    setSelectedNamespace('all')
    setYamlText('')
    setNamespaces([])
    setError(null)
    resetCopyFeedback()

    if (nextCluster === null) {
      setError('The selected AFM cluster is unavailable.')
      return
    }

    const sequence = ++requestSequenceRef.current
    await preloadNamespaces(nextCluster, sequence)
  }

  async function handleGenerateYaml() {
    resetCopyFeedback()
    setError(null)

    if (selectedCluster === null) {
      setYamlText('')
      if (hasClusters) {
        setError('Select an AFM cluster before generating YAML.')
      } else {
        setError('No AFM clusters are available for import.')
      }
      return
    }

    const sequence = ++requestSequenceRef.current
    setIsLoadingRbac(true)

    try {
      const rbac = await readClusterRbac(selectedCluster.id)
      if (!isCurrentRequest(sequence)) {
        return
      }

      const nextNamespaces = deriveNamespaces(rbac)
      const effectiveNamespace = selectedNamespace === 'all' || nextNamespaces.includes(selectedNamespace)
        ? selectedNamespace
        : 'all'

      setNamespaces(nextNamespaces)
      if (effectiveNamespace !== selectedNamespace) {
        setSelectedNamespace('all')
      }

      const afmImport = convertRbacToAfmImport(rbac, selectedCluster, effectiveNamespace)
      setYamlText(emitYaml(afmImport))
    } catch (nextError: unknown) {
      if (!isCurrentRequest(sequence)) {
        return
      }

      setYamlText('')
      setError(toInlineErrorMessage(nextError, `Unable to generate YAML for ${selectedCluster.name}.`))
    } finally {
      if (isCurrentRequest(sequence)) {
        setIsLoadingRbac(false)
      }
    }
  }

  async function handleCopy() {
    if (!yamlText) {
      return
    }

    resetCopyFeedback()

    const textarea = textareaRef.current
    const copyHint = 'Clipboard unavailable. Press Ctrl+C to copy the selected YAML.'

    if (!navigator.clipboard?.writeText) {
      if (textarea) {
        textarea.focus()
        textarea.select()
      }
      setCopyFeedback({ tone: 'hint', message: copyHint })
      return
    }

    try {
      await navigator.clipboard.writeText(yamlText)
      setCopyFeedback({ tone: 'success', message: 'Copied' })
      queueCopiedReset()
    } catch {
      if (textarea) {
        textarea.focus()
        textarea.select()
      }
      setCopyFeedback({ tone: 'hint', message: copyHint })
    }
  }

  return (
    <div
      data-testid="rbac-importer"
      style={{
        background: 'var(--surface2)',
        border: '1px solid var(--border-subtle)',
        borderRadius: 8,
        padding: 12,
        marginBottom: 12,
      }}
    >
      <div style={{ marginBottom: 10 }}>
        <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>RBAC importer</div>
        <div style={{ fontSize: 12, color: 'var(--muted)' }}>
          Generate AFM import YAML here, then paste it into KubeSec-AFM cluster upload to start the graph walk.
        </div>
      </div>

      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'flex-end', marginBottom: 10 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <label style={{ fontSize: 12, color: 'var(--muted)' }}>Cluster</label>
          {displayClusters.length > 1 && (
            <select
              value={selectedClusterId}
              onChange={event => void handleClusterChange(event.target.value)}
              data-testid="importer-cluster-select"
              disabled={isLoadingClusters || isLoadingRbac}
              style={{ width: 220 }}
            >
              {displayClusters.map(cluster => (
                <option key={cluster.id} value={cluster.id}>
                  {cluster.name} ({cluster.id})
                </option>
              ))}
            </select>
          )}
          {displayClusters.length === 1 && (
            <div
              data-testid="importer-cluster-select"
              style={{
                minWidth: 220,
                padding: '6px 10px',
                borderRadius: 6,
                border: '1px solid var(--border-subtle)',
                background: 'rgba(255,255,255,0.02)',
                fontSize: 13,
              }}
            >
              {displayClusters[0].name} ({displayClusters[0].id})
            </div>
          )}
          {displayClusters.length === 0 && (
            <div style={{ minWidth: 220, fontSize: 12, color: 'var(--muted)' }}>
              {isLoadingClusters ? 'Loading AFM clusters…' : 'No AFM clusters available yet.'}
            </div>
          )}
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <label style={{ fontSize: 12, color: 'var(--muted)' }}>Namespace</label>
          <select
            value={selectedNamespace}
            onChange={event => setSelectedNamespace(event.target.value)}
            data-testid="importer-namespace-select"
            disabled={!hasClusters || isLoadingRbac}
            style={{ width: 200 }}
          >
            <option value="all">All namespaces</option>
            {namespaces.map(namespace => (
              <option key={namespace} value={namespace}>
                {namespace}
              </option>
            ))}
          </select>
        </div>

        <button
          type="button"
          className="btn btn-secondary"
          data-testid="importer-fetch"
          disabled={fetchDisabled}
          onClick={() => void handleGenerateYaml()}
          style={{ fontSize: 12, padding: '5px 12px' }}
        >
          {isLoadingRbac ? 'Generating…' : 'Generate YAML'}
        </button>
      </div>

      {!hasClusters && !isLoadingClusters && (
        <div style={{ fontSize: 12, color: 'var(--muted)', marginBottom: 10 }}>
          Import a cluster into KubeSec-AFM first, then return here to generate YAML for graph analysis.
        </div>
      )}

      {error && (
        <div data-testid="importer-error" style={{ fontSize: 12, color: 'var(--error)', marginBottom: 10 }}>
          {error}
        </div>
      )}

      {copyFeedback && (
        <div
          style={{
            fontSize: 12,
            color: copyFeedback.tone === 'success' ? 'var(--cyan)' : 'var(--muted)',
            marginBottom: 10,
          }}
        >
          {copyFeedback.message}
        </div>
      )}

      <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', flexWrap: 'wrap' }}>
        <textarea
          ref={textareaRef}
          data-testid="importer-yaml"
          value={yamlText}
          readOnly
          rows={10}
          spellCheck={false}
          placeholder="Generate YAML for a cluster, then paste it into KubeSec-AFM cluster upload."
          style={{
            flex: '1 1 560px',
            width: '100%',
            minHeight: 150,
            resize: 'vertical',
            fontFamily: 'monospace',
            fontSize: 12,
            lineHeight: 1.5,
            background: 'rgba(255,255,255,0.02)',
            color: 'inherit',
            border: '1px solid var(--border-subtle)',
            borderRadius: 6,
            padding: '10px 12px',
          }}
        />

        <button
          type="button"
          className="btn btn-primary"
          data-testid="importer-copy"
          disabled={!yamlText}
          onClick={() => void handleCopy()}
          style={{ minWidth: 110 }}
        >
          Copy
        </button>
      </div>
    </div>
  )
}
