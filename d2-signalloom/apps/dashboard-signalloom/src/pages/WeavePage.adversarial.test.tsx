import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom'
import type { ReactNode } from 'react'
import WeavePage from './WeavePage'
import App from '../App'
import { weaveApi } from '../api/weaveApi'
import type { SignalObservation } from '../api/weaveApi'
import { fakeWeaveData } from '../api/fakeWeaveData'

// ─── Auth and Context Mocks ──────────────────────────────────────────────────

const auth = vi.hoisted(() => ({
  isAuthenticated: true,
  isLoading: false,
  user: { name: 'Test Operator', email: 'operator@signalloom.dev' } as Record<string, unknown> | null,
  getAccessTokenSilently: vi.fn().mockResolvedValue('adversarial-test-token'),
  loginWithRedirect: vi.fn(),
}))

vi.mock('../auth/oidc', () => ({
  useAuth0: () => auth,
}))

vi.mock('../auth/ProtectedRoute', () => ({
  default: ({ children }: { children: ReactNode }) => <>{children}</>,
}))

vi.mock('../components/Sidebar', () => ({
  default: () => <nav data-testid="sidebar" />,
  NAV: [
    { to: '/weave', label: 'The Weave', section: 'View', icon: 'weave' },
  ],
}))

vi.mock('../components/FloatingConfigControls', () => ({ default: () => null }))
vi.mock('../components/KeyboardShortcutsOverlay', () => ({ default: () => null }))
vi.mock('../components/SetupBanner', () => ({ default: () => null }))

// ─── Helpers ────────────────────────────────────────────────────────────────

function LocationTracker({ onLocation }: { onLocation: (loc: { pathname: string; search: string }) => void }) {
  const location = useLocation()
  onLocation(location)
  return <div data-testid="location-tracker">{location.pathname}</div>
}

describe('WeavePage Adversarial and Resiliency Suite', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.restoreAllMocks()
    auth.getAccessTokenSilently.mockResolvedValue('adversarial-test-token')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // ─── 1. Route Redirection Tests ──────────────────────────────────────────

  describe('Route Redirection & Backward Compatibility', () => {
    it('redirects /activity to /weave and renders WeavePage', async () => {
      let currentPath = ''

      render(
        <MemoryRouter initialEntries={['/activity']}>
          <LocationTracker onLocation={(loc) => { currentPath = loc.pathname }} />
          <App />
        </MemoryRouter>,
      )

      await waitFor(() => {
        expect(currentPath).toBe('/weave')
      })

      // Ensure WeavePage rendered with The Weave title
      await waitFor(() => {
        expect(screen.getByRole('heading', { level: 1, name: 'The Weave' })).toBeInTheDocument()
      })
    })

    it('preserves query parameters when navigating through Weave routes', async () => {
      let recordedLocation = { pathname: '', search: '' }

      render(
        <MemoryRouter initialEntries={['/weave?layer=network_egress&fidelity=definitive']}>
          <LocationTracker onLocation={(loc) => { recordedLocation = loc }} />
          <App />
        </MemoryRouter>,
      )

      await waitFor(() => {
        expect(recordedLocation.pathname).toBe('/weave')
        expect(recordedLocation.search).toBe('?layer=network_egress&fidelity=definitive')
      })
    })
  })

  // ─── 2. Real-Time Telemetry SSE Stream Resiliency ───────────────────────

  describe('SSE Stream Resiliency (weaveApi.createObservationsStream)', () => {
    it('connects to SSE endpoint with bearer token and query parameters', async () => {
      let requestedUrl = ''
      let requestedHeaders: HeadersInit | undefined

      const mockReadableStream = new ReadableStream({
        start(controller) {
          const encoder = new TextEncoder()
          controller.enqueue(encoder.encode('event: observation\ndata: {"id":"obs-sse-1","timestamp":"2026-09-28T12:00:00Z","layer":"network_egress","fidelity":"definitive","source":"ebpf-socket-sentinel","confidence":0.99,"raw_evidence_ref":"ev-1","description":"Test SSE observation"}\n\n'))
          controller.close()
        },
      })

      const mockFetch = vi.fn().mockImplementation((url: string, init?: RequestInit) => {
        requestedUrl = url
        requestedHeaders = init?.headers
        return Promise.resolve(new Response(mockReadableStream, {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }))
      })

      vi.stubGlobal('fetch', mockFetch)

      const received: SignalObservation[] = []
      const stream = weaveApi.createObservationsStream(
        'test-jwt-token',
        { layers: 'network_egress,endpoint_host', limit: 50, actor_id: 'actor-99' },
        (obs) => { received.push(obs) },
      )

      await waitFor(() => {
        expect(received.length).toBe(1)
        expect(received[0].id).toBe('obs-sse-1')
        expect(received[0].layer).toBe('network_egress')
      })

      expect(requestedUrl).toContain('/api/signals/observations/stream')
      expect(requestedUrl).toContain('layers=network_egress%2Cendpoint_host')
      expect(requestedUrl).toContain('limit=50')
      expect(requestedUrl).toContain('actor_id=actor-99')
      expect((requestedHeaders as Record<string, string>)?.Authorization).toBe('Bearer test-jwt-token')
      expect((requestedHeaders as Record<string, string>)?.Accept).toBe('text/event-stream')

      stream.disconnect()
    })

    it('resiliently handles chunk fragmentation across multiple stream buffers', async () => {
      const chunk1 = 'event: observation\ndata: {"id":"obs-frag-1","timestamp":"2026-09-28T12:00:00Z","lay'
      const chunk2 = 'er":"behavioural","fidelity":"strong","source":"agent-supervisor","confidence":0.85,"raw_evidence_ref":"ev-2","description":"Fragmented telemetry"}\n\n'

      const mockReadableStream = new ReadableStream({
        async start(controller) {
          const encoder = new TextEncoder()
          controller.enqueue(encoder.encode(chunk1))
          await new Promise((r) => setTimeout(r, 10))
          controller.enqueue(encoder.encode(chunk2))
          controller.close()
        },
      })

      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(mockReadableStream, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })))

      const received: SignalObservation[] = []
      const stream = weaveApi.createObservationsStream(
        'test-token',
        {},
        (obs) => { received.push(obs) },
      )

      await waitFor(() => {
        expect(received.length).toBe(1)
        expect(received[0].id).toBe('obs-frag-1')
        expect(received[0].layer).toBe('behavioural')
      })

      stream.disconnect()
    })

    it('silently tolerates and ignores malformed JSON payloads and unknown event types without crashing', async () => {
      const payload = [
        ': keep-alive heartbeat\n\n',
        'event: unknown_custom_type\ndata: {"arbitrary":"payload"}\n\n',
        'event: observation\ndata: NOT_VALID_JSON_CORRUPTED_BYTES\n\n',
        'event: observation\ndata: {"id":"obs-valid-after-corruption","timestamp":"2026-09-28T12:00:00Z","layer":"protocol","fidelity":"definitive","source":"spiffe-spire","confidence":1.0,"raw_evidence_ref":"ev-3","description":"Valid post-corrupt observation"}\n\n',
      ].join('')

      const mockReadableStream = new ReadableStream({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(payload))
          controller.close()
        },
      })

      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(mockReadableStream, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })))

      const received: SignalObservation[] = []
      const stream = weaveApi.createObservationsStream(
        'test-token',
        {},
        (obs) => { received.push(obs) },
      )

      await waitFor(() => {
        expect(received.length).toBe(1)
        expect(received[0].id).toBe('obs-valid-after-corruption')
      })

      stream.disconnect()
    })

    it('aborts underlying stream immediately on disconnect without throwing unhandled rejections', async () => {
      let aborted = false

      const mockReadableStream = new ReadableStream({
        start(controller) {
          // Keep stream indefinitely open
        },
        cancel() {
          aborted = true
        },
      })

      const mockFetch = vi.fn().mockImplementation((_url: string, init?: RequestInit) => {
        init?.signal?.addEventListener('abort', () => {
          aborted = true
        })
        return Promise.resolve(new Response(mockReadableStream, { status: 200 }))
      })

      vi.stubGlobal('fetch', mockFetch)

      const stream = weaveApi.createObservationsStream('token', {})
      expect(aborted).toBe(false)

      stream.disconnect()
      expect(aborted).toBe(true)
    })

    it('triggers onError callback on HTTP failure response (502 Bad Gateway)', async () => {
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('Bad Gateway', { status: 502 })))

      let capturedError: Error | null = null

      weaveApi.createObservationsStream(
        'token',
        {},
        undefined,
        (err) => { capturedError = err },
      )

      await waitFor(() => {
        expect(capturedError).not.toBeNull()
        expect(capturedError?.message).toContain('Stream connection failed: 502')
      })
    })

    it('triggers onError callback on network transport error', async () => {
      vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('Network connection dropped')))

      let capturedError: Error | null = null

      weaveApi.createObservationsStream(
        'token',
        {},
        undefined,
        (err) => { capturedError = err },
      )

      await waitFor(() => {
        expect(capturedError).not.toBeNull()
        expect(capturedError?.message).toContain('Network connection dropped')
      })
    })
  })

  // ─── 3. UI Copy & Clean Terminology Audit ────────────────────────────────

  describe('UI Copy and Terminology Verification', () => {
    it('ensures zero user-facing occurrences of Activity on WeavePage', async () => {
      vi.spyOn(weaveApi, 'getObservations').mockResolvedValue(fakeWeaveData.observations)
      vi.spyOn(weaveApi, 'getActors').mockResolvedValue(fakeWeaveData.actors)
      vi.spyOn(weaveApi, 'getCoverage').mockResolvedValue(fakeWeaveData.coverage)

      render(
        <MemoryRouter initialEntries={['/weave']}>
          <WeavePage />
        </MemoryRouter>,
      )

      await waitFor(() => {
        expect(screen.getByTestId('weave-page')).toBeInTheDocument()
      })

      // The main header must be The Weave
      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('The Weave')

      // No element inside WeavePage should contain standalone 'Activity' navigation or title
      const pageText = screen.getByTestId('weave-page').textContent ?? ''
      expect(pageText).not.toMatch(/\bActivity\b(?!\s*Timeline)/)
    })
  })
})
