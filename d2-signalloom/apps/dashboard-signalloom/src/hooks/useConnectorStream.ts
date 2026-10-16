// One connector event stream per tab, shared by every view that shows remote
// agent state (RemoteEnvironmentPage, the Settings connector badges).
//
// For each subscribed provider the store holds the last remote-agents
// snapshot with stream events applied on top. Every time the stream opens,
// first time included, the snapshots are fetched again, so nothing missed
// while disconnected (or before the first connect) can silently drift. Events
// that arrive while a snapshot is in flight are replayed over it once it
// lands. Demo mode opens no stream and reads the demo fixture through the
// mode-gated connectors client; flipping the mode drops everything and
// starts over.

import { useEffect, useRef, useSyncExternalStore } from 'react'
import {
  connectorErrorMessage,
  connectorsApi,
  connectorStreamUrl,
  isConnectorsMockMode,
  type ConnectorStreamEvent,
  type ConnectorSyncState,
  type RemoteAgent,
} from '../api/connectorsClient'
import { openConnectorStream, type ConnectorStreamHandle } from '../api/connectorStream'
import { subscribeDemoMode } from '../api/demoMode'
import { useAuth0 } from '../auth/oidc'

export interface StreamConnection {
  /** idle: nobody subscribed. demo: demo mode, no stream by design. */
  status: 'idle' | 'demo' | 'connecting' | 'open' | 'reconnecting'
  error: string | null
  retryInMs: number | null
}

export interface RemoteAgentsView {
  status: 'loading' | 'ready' | 'not_configured' | 'error'
  error: string | null
  connectorId: string | null
  syncState: ConnectorSyncState | null
  agents: RemoteAgent[]
}

export interface ConnectorStreamState {
  connection: StreamConnection
  providers: Record<string, RemoteAgentsView>
}

const LOADING: RemoteAgentsView = { status: 'loading', error: null, connectorId: null, syncState: null, agents: [] }
const IDLE: StreamConnection = { status: 'idle', error: null, retryInMs: null }
const INITIAL: ConnectorStreamState = { connection: IDLE, providers: {} }

type ProviderStreamEvent = Exclude<ConnectorStreamEvent, { type: 'stream.reset' }>

function applyEvent(view: RemoteAgentsView, ev: ProviderStreamEvent): RemoteAgentsView {
  switch (ev.type) {
    case 'remote_agent.upserted': {
      const i = view.agents.findIndex((a) => a.external_id === ev.agent.external_id)
      const agents = i === -1 ? [...view.agents, ev.agent] : view.agents.map((a, j) => (j === i ? ev.agent : a))
      return { ...view, agents }
    }
    case 'remote_agent.gone':
      return {
        ...view,
        agents: view.agents.map((a) => (a.external_id === ev.external_id ? { ...a, gone_at: ev.gone_at } : a)),
      }
    case 'connector.sync_state':
      return { ...view, syncState: ev.sync_state }
  }
}

function createConnectorStreamStore() {
  let state: ConnectorStreamState = INITIAL
  const listeners = new Set<() => void>()
  const refs = new Map<string, number>()
  // Snapshot fetches in flight, with the events seen since the earliest began.
  const inflight = new Map<string, { seq: number; buffer: ProviderStreamEvent[] }>()
  let getToken: (() => Promise<string>) | null = null
  let stream: ConnectorStreamHandle | null = null
  let streamId = 0
  let unsubDemo: (() => void) | null = null
  let options: { initialRetryMs?: number } = {}
  let epoch = 0
  let seq = 0

  const emit = (next: ConnectorStreamState) => {
    state = next
    listeners.forEach((l) => l())
  }
  const setProvider = (id: string, view: RemoteAgentsView) =>
    emit({ ...state, providers: { ...state.providers, [id]: view } })
  const setConnection = (connection: StreamConnection) => emit({ ...state, connection })

  function load(providerId: string) {
    const mySeq = ++seq
    const myEpoch = epoch
    inflight.set(providerId, { seq: mySeq, buffer: inflight.get(providerId)?.buffer ?? [] })
    const current = () => myEpoch === epoch && inflight.get(providerId)?.seq === mySeq
    void (async () => {
      try {
        if (!getToken) throw new Error('Not signed in.')
        const snap = await connectorsApi.listRemoteAgents(await getToken(), providerId)
        if (!current()) return
        const { buffer } = inflight.get(providerId)!
        inflight.delete(providerId)
        if (!snap) {
          setProvider(providerId, { ...LOADING, status: 'not_configured' })
          return
        }
        let view: RemoteAgentsView = {
          status: 'ready',
          error: null,
          connectorId: snap.connector_id,
          syncState: snap.sync_state,
          agents: snap.agents,
        }
        for (const ev of buffer) if (ev.connector_id === snap.connector_id) view = applyEvent(view, ev)
        setProvider(providerId, view)
      } catch (err) {
        if (!current()) return
        inflight.delete(providerId)
        const prev = state.providers[providerId] ?? LOADING
        setProvider(providerId, {
          ...prev,
          status: 'error',
          error: connectorErrorMessage(err, 'Could not load remote agents.'),
        })
      }
    })()
  }

  function onEvent(ev: ConnectorStreamEvent) {
    if (ev.type === 'stream.reset') {
      // The server could not replay what we missed: refetch every snapshot.
      refs.forEach((_n, providerId) => load(providerId))
      return
    }
    const view = state.providers[ev.provider_id]
    if (!view) return
    if (view.connectorId && ev.connector_id !== view.connectorId) {
      // A different connector now backs this provider: our snapshot is stale.
      if (!inflight.has(ev.provider_id)) load(ev.provider_id)
      return
    }
    inflight.get(ev.provider_id)?.buffer.push(ev)
    setProvider(ev.provider_id, applyEvent(view, ev))
  }

  function ensureRunning() {
    if (refs.size === 0 || stream || state.connection.status === 'demo') return
    if (isConnectorsMockMode()) {
      setConnection({ status: 'demo', error: null, retryInMs: null })
      return
    }
    const id = ++streamId
    const mine = () => id === streamId
    setConnection({ status: 'connecting', error: null, retryInMs: null })
    stream = openConnectorStream({
      url: connectorStreamUrl(),
      getToken: () => (getToken ? getToken() : Promise.reject(new Error('Not signed in.'))),
      initialRetryMs: options.initialRetryMs,
      onEvent: (ev) => mine() && onEvent(ev),
      onOpen: () => {
        if (!mine()) return
        setConnection({ status: 'open', error: null, retryInMs: null })
        refs.forEach((_n, providerId) => load(providerId))
      },
      onDrop: ({ error, retryInMs }) => {
        if (mine()) setConnection({ status: 'reconnecting', error, retryInMs })
      },
    })
  }

  function stopStream() {
    streamId++
    stream?.close()
    stream = null
  }

  function onModeFlip() {
    epoch++
    inflight.clear()
    stopStream()
    const providers: Record<string, RemoteAgentsView> = {}
    refs.forEach((_n, providerId) => (providers[providerId] = LOADING))
    emit({ connection: IDLE, providers })
    ensureRunning()
    refs.forEach((_n, providerId) => load(providerId))
  }

  return {
    getState: () => state,
    listen(listener: () => void) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    /** Test seam: shorten reconnect delays. */
    configure(next: { initialRetryMs?: number }) {
      options = { ...options, ...next }
    },
    subscribe(providerId: string, tokenGetter: () => Promise<string>): () => void {
      getToken = tokenGetter
      if (refs.size === 0) unsubDemo = subscribeDemoMode(onModeFlip)
      const n = (refs.get(providerId) ?? 0) + 1
      refs.set(providerId, n)
      if (n === 1) {
        if (!state.providers[providerId]) setProvider(providerId, LOADING)
        load(providerId)
      }
      ensureRunning()
      let done = false
      return () => {
        if (done) return
        done = true
        const left = (refs.get(providerId) ?? 1) - 1
        if (left > 0) refs.set(providerId, left)
        else refs.delete(providerId)
        if (refs.size === 0) {
          stopStream()
          unsubDemo?.()
          unsubDemo = null
          setConnection(IDLE)
        }
      }
    },
    reset() {
      epoch++
      stopStream()
      unsubDemo?.()
      unsubDemo = null
      refs.clear()
      inflight.clear()
      getToken = null
      options = {}
      emit(INITIAL)
    },
  }
}

export const connectorStreamStore = createConnectorStreamStore()

/** The backend's poll interval, from its own last and next poll times; null when unobserved. */
export function pollIntervalLabel(s: Pick<ConnectorSyncState, 'last_poll_at' | 'next_poll_at'>): string | null {
  if (!s.last_poll_at || !s.next_poll_at) return null
  const secs = Math.round((Date.parse(s.next_poll_at) - Date.parse(s.last_poll_at)) / 1000)
  if (!Number.isFinite(secs) || secs <= 0) return null
  return secs < 90 ? `${secs} s` : `${Math.round(secs / 60)} min`
}

/**
 * Upstream sync mode as a short phrase: what the backend is doing, not the browser.
 * Backend modes (remote_agent_sync): poll | poll+stream | backoff.
 */
export function syncModeLabel(s: ConnectorSyncState): string {
  if (s.mode === 'stream') return 'Live (provider stream)'
  if (s.mode === 'webhook') return 'Live (provider webhooks)'
  const every = pollIntervalLabel(s)
  if (s.mode === 'poll') return every ? `Polling every ${every}` : 'Polling'
  if (s.mode === 'poll+stream') return every ? `Live sessions + polling every ${every}` : 'Live sessions + polling'
  if (s.mode === 'backoff') {
    const n = s.consecutive_failures
    return typeof n === 'number' && n > 0
      ? `Backing off after errors (${n} consecutive failure${n === 1 ? '' : 's'})`
      : 'Backing off after errors'
  }
  return `Sync mode: ${s.mode}`
}


/** Remote agents and sync state for one provider, kept live by the shared stream. */
export function useRemoteAgents(providerId: string | null): { view: RemoteAgentsView; connection: StreamConnection } {
  const { getAccessTokenSilently } = useAuth0()
  const tokenRef = useRef(getAccessTokenSilently)
  useEffect(() => {
    tokenRef.current = getAccessTokenSilently
  }, [getAccessTokenSilently])
  useEffect(() => {
    if (!providerId) return undefined
    return connectorStreamStore.subscribe(providerId, () => tokenRef.current())
  }, [providerId])
  const s = useSyncExternalStore(connectorStreamStore.listen, connectorStreamStore.getState)
  return { view: (providerId && s.providers[providerId]) || LOADING, connection: s.connection }
}
