import { useCallback, useEffect, useRef, useState } from 'react'
import {
  deriveNamespaces,
  fetchJsonOrThrow,
  parseClusterList,
  parseRbacData,
  postClusterImport,
  type ClusterMeta,
  type RBACData,
} from '../api/afmApi'
import { convertRbacToAfmImport, emitYaml, generateImportId, generateImportName } from '../api/afmYaml'
import type { AfmClusterImport } from '../api/afmYaml'
import { isDemoMode } from '../api/demoMode'
import PixelLoader from './PixelLoader'

// ─── Waiting ────────────────────────────────────────────────────────────────
//
// All three waits here talk to AFM across a proxy with a fifteen-second
// timeout, and all three used to say one unchanging word. Each now carries the
// pixel grid and a live elapsed figure, so a slow AFM and a hung one stop
// looking identical.
//
// The two button loaders get an explicit width and their buttons a min-width
// that already fits the busy state. The figure gains a character at 10.0s and
// again at 1m 0.0s, and this control row sits next to two selects — a button
// that grows mid-request drags them sideways under the cursor.

/** Grid + gap + a one-word label at 13px + gap + the figure at its longest. */
const LABELLED_LOADER_W = 144
const SEND_LOADER_W = 124
const LOADER_GAP = 6
const GENERATE_BUTTON_W = 170
/** Copy shares it so the two-button stack keeps one edge while Send is busy. */
const SEND_BUTTON_W = 150

type InlineFeedback =
  | { tone: 'success'; message: string }
  | { tone: 'hint'; message: string }
  | { tone: 'error'; message: string }

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

export default function RbacImporterPanel({ onImported }: { onImported?: (clusterId: string) => void } = {}) {
  const [clusters, setClusters] = useState<ClusterMeta[]>([])
  const [selectedClusterId, setSelectedClusterId] = useState('')
  const [selectedNamespace, setSelectedNamespace] = useState('all')
  const [namespaces, setNamespaces] = useState<string[]>([])
  const [yamlText, setYamlText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [copyFeedback, setCopyFeedback] = useState<InlineFeedback | null>(null)
  const [sendFeedback, setSendFeedback] = useState<InlineFeedback | null>(null)
  const [isLoadingClusters, setIsLoadingClusters] = useState(true)
  const [isLoadingRbac, setIsLoadingRbac] = useState(false)
  const [isSending, setIsSending] = useState(false)

  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const requestSequenceRef = useRef(0)
  const copyResetTimeoutRef = useRef<number | null>(null)
  const sendResetTimeoutRef = useRef<number | null>(null)
  const lastImportPayloadRef = useRef<AfmClusterImport | null>(null)

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

  const clearSendResetTimeout = useCallback(() => {
    if (sendResetTimeoutRef.current !== null) {
      window.clearTimeout(sendResetTimeoutRef.current)
      sendResetTimeoutRef.current = null
    }
  }, [])

  const resetCopyFeedback = useCallback(() => {
    clearCopyResetTimeout()
    setCopyFeedback(null)
  }, [clearCopyResetTimeout])

  const resetSendFeedback = useCallback(() => {
    clearSendResetTimeout()
    setSendFeedback(null)
  }, [clearSendResetTimeout])

  const queueCopiedReset = useCallback(() => {
    clearCopyResetTimeout()
    copyResetTimeoutRef.current = window.setTimeout(() => {
      setCopyFeedback(null)
      copyResetTimeoutRef.current = null
    }, 2000)
  }, [clearCopyResetTimeout])

  const queueSendReset = useCallback(() => {
    clearSendResetTimeout()
    sendResetTimeoutRef.current = window.setTimeout(() => {
      setSendFeedback(null)
      sendResetTimeoutRef.current = null
    }, 3000)
  }, [clearSendResetTimeout])

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
      resetSendFeedback()
      lastImportPayloadRef.current = null

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
      clearSendResetTimeout()
    }
  }, [clearCopyResetTimeout, clearSendResetTimeout, isCurrentRequest, preloadNamespaces, resetCopyFeedback, resetSendFeedback])

  async function handleClusterChange(nextClusterId: string) {
    const nextCluster = clusters.find(cluster => cluster.id === nextClusterId) ?? null

    setSelectedClusterId(nextClusterId)
    setSelectedNamespace('all')
    setYamlText('')
    setNamespaces([])
    setError(null)
    resetCopyFeedback()
    resetSendFeedback()
    lastImportPayloadRef.current = null

    if (nextCluster === null) {
      setError('The selected AFM cluster is unavailable.')
      return
    }

    const sequence = ++requestSequenceRef.current
    await preloadNamespaces(nextCluster, sequence)
  }

  async function handleGenerateYaml() {
    resetCopyFeedback()
    resetSendFeedback()
    setError(null)
    lastImportPayloadRef.current = null

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

      const now = new Date()
      const afmImport = convertRbacToAfmImport(rbac, selectedCluster, effectiveNamespace)
      afmImport.id = generateImportId(now)
      afmImport.name = generateImportName(effectiveNamespace, now)

      lastImportPayloadRef.current = afmImport
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

  async function handleSendToAfm() {
    const payload = lastImportPayloadRef.current
    if (!payload) {
      return
    }

    resetSendFeedback()
    setIsSending(true)

    try {
      await postClusterImport(payload)
      setSendFeedback({ tone: 'success', message: `Sent ${payload.id} to AFM — showing it below` })
      // Tell the page which cluster to show. Without this the import lands in
      // AFM correctly and stays invisible, which is indistinguishable from a
      // failed send.
      onImported?.(payload.id)
      queueSendReset()
    } catch (sendError: unknown) {
      setSendFeedback({
        tone: 'error',
        message: toInlineErrorMessage(sendError, 'Failed to send RBAC data to AFM.'),
      })
    } finally {
      setIsSending(false)
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
              {/* A panel-level wait with a line to itself, so it keeps the full
                  sentence rather than going compact the way the buttons do. */}
              {isLoadingClusters
                ? (
                  <PixelLoader
                    testId="importer-clusters-loader"
                    label="Loading AFM clusters"
                    style={{ gap: LOADER_GAP }}
                  />
                )
                : 'No AFM clusters available yet.'}
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
          style={{
            fontSize: 12, padding: '5px 12px', minWidth: GENERATE_BUTTON_W,
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          }}
        >
          {isLoadingRbac
            ? <PixelLoader testId="importer-generate-loader" label="Generating" style={{ width: LABELLED_LOADER_W, gap: LOADER_GAP }} />
            : 'Generate YAML'}
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

      {sendFeedback && (
        <div
          data-testid="importer-send-feedback"
          style={{
            fontSize: 12,
            color: sendFeedback.tone === 'success' ? 'var(--cyan)' : sendFeedback.tone === 'error' ? 'var(--error)' : 'var(--muted)',
            marginBottom: 10,
          }}
        >
          {sendFeedback.message}
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

        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <button
            type="button"
            className="btn btn-primary"
            data-testid="importer-copy"
            disabled={!yamlText}
            onClick={() => void handleCopy()}
            style={{ minWidth: SEND_BUTTON_W }}
          >
            Copy
          </button>

          <button
            type="button"
            className="btn btn-secondary"
            data-testid="importer-send"
            disabled={!lastImportPayloadRef.current || isSending}
            onClick={() => void handleSendToAfm()}
            style={{
              minWidth: SEND_BUTTON_W, fontSize: 12, padding: '5px 12px',
              display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            }}
          >
            {isSending
              ? <PixelLoader testId="importer-send-loader" label="Sending" style={{ width: SEND_LOADER_W, gap: LOADER_GAP }} />
              : 'Send to AFM'}
          </button>
        </div>
      </div>
    </div>
  )
}
