import type { SyncStore } from '../store/sync-store';
import type { HarnessType, SearchQuery, SessionMetadata, SummaryModelTier } from '../types';
import { SessionSummarizer } from '../summarizer/summarizer';

export class WebDashboardServer {
  private sseClients = new Set<ReadableStreamDefaultController>();
  private summarizer = new SessionSummarizer();

  constructor(private store: SyncStore, private preferredPort: number = 3838) {
    this.store.onSessionUpdate((session) => {
      this.broadcastSse({ type: 'session_update', session });
    });
    this.summarizer.tokenTracker.onUpdate((appMetrics) => {
      this.broadcastSse({ type: 'app_metrics_update', appMetrics });
    });
  }

  private broadcastSse(data: unknown): void {
    const payload = `data: ${JSON.stringify(data)}\n\n`;
    for (const client of this.sseClients) {
      try {
        client.enqueue(new TextEncoder().encode(payload));
      } catch {
        this.sseClients.delete(client);
      }
    }
  }

  async start(): Promise<{ url: string; port: number; isExisting: boolean; stop: () => void }> {
    // Check if an existing harness-dash server is already answering on the preferred port
    try {
      const ping = await fetch(`http://localhost:${this.preferredPort}/api/metrics`, { signal: AbortSignal.timeout(600) });
      if (ping.ok) {
        return {
          url: `http://localhost:${this.preferredPort}`,
          port: this.preferredPort,
          isExisting: true,
          stop: () => {}
        };
      }
    } catch {
      // not running, proceed to bind
    }

    // Find an available port starting from preferredPort
    let currentPort = this.preferredPort;
    let server: any = null;
    let attempts = 0;

    while (attempts < 10 && !server) {
      try {
        server = Bun.serve({
          port: currentPort,
          fetch: async (req) => {
            const url = new URL(req.url);

            const corsHeaders = {
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
              'Access-Control-Allow-Headers': 'Content-Type'
            };

            if (req.method === 'OPTIONS') {
              return new Response(null, { headers: corsHeaders });
            }

            // SSE Endpoint
            if (url.pathname === '/api/stream') {
              const stream = new ReadableStream({
                start: (controller) => {
                  this.sseClients.add(controller);
                  const initial = {
                    type: 'init',
                    metrics: this.store.getMetrics(),
                    appMetrics: this.summarizer.tokenTracker.getMetrics()
                  };
                  controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(initial)}\n\n`));
                },
                cancel: (controller) => {
                  this.sseClients.delete(controller);
                }
              });

              return new Response(stream, {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'text/event-stream',
                  'Cache-Control': 'no-cache',
                  Connection: 'keep-alive'
                }
              });
            }

            // REST API: Metrics
            if (url.pathname === '/api/metrics') {
              return Response.json(this.store.getMetrics(), { headers: corsHeaders });
            }

            // REST API: App Token Tracker Metrics
            if (url.pathname === '/api/app-metrics') {
              return Response.json(this.summarizer.tokenTracker.getMetrics(), { headers: corsHeaders });
            }

            // REST API: List Sessions (ultra-fast lightweight summaries with top 100 limit and server-side search)
            if (url.pathname === '/api/sessions') {
              const text = url.searchParams.get('q') || undefined;
              const harness = (url.searchParams.get('harness') as HarnessType) || undefined;
              const deviceId = url.searchParams.get('device') || undefined;
              const status = url.searchParams.get('status') as any;
              const limit = url.searchParams.has('limit') ? parseInt(url.searchParams.get('limit')!, 10) : 100;
              const offset = url.searchParams.has('offset') ? parseInt(url.searchParams.get('offset')!, 10) : 0;

              const query: SearchQuery = { text, harness, deviceId, status, limit, offset };
              const summaries = this.store.listSummaries(query);
              const totalCount = this.store.listSessions({ text, harness, deviceId, status }).length;
              return Response.json({ sessions: summaries, totalCount, limit, offset }, { headers: corsHeaders });
            }

            // REST API: Lazy Transcript Loader with Human-Readable Kanban Parsing
            if (url.pathname.startsWith('/api/sessions/') && url.pathname.endsWith('/transcript') && req.method === 'GET') {
              const id = decodeURIComponent(url.pathname.replace('/api/sessions/', '').replace('/transcript', ''));
              const tail = url.searchParams.has('tail') ? parseInt(url.searchParams.get('tail')!, 10) : 200;
              try {
                const transcriptData = await this.store.getSessionTranscript(id, tail);
                return Response.json(transcriptData, { headers: corsHeaders });
              } catch (err: any) {
                return Response.json({ error: err.message }, { status: 404, headers: corsHeaders });
              }
            }

            // REST API: Re-run Prompt / Summarize Session with specified model tier
            if (url.pathname.startsWith('/api/sessions/') && url.pathname.endsWith('/summarize') && req.method === 'POST') {
              const id = decodeURIComponent(url.pathname.replace('/api/sessions/', '').replace('/summarize', ''));
              const session = this.store.getSession(id);
              if (!session) {
                return Response.json({ error: 'Session not found' }, { status: 404, headers: corsHeaders });
              }

              const body = await req.json().catch(() => ({}));
              const requestedModel = (url.searchParams.get('model') || body.model || 'gemini-2.5-flash') as SummaryModelTier;

              const summaryInfo = await this.summarizer.summarizeWithModel(session, requestedModel);
              session.summary = summaryInfo.text;
              session.summaryInfo = summaryInfo;
              await this.store.saveSession(session);

              return Response.json({ success: true, session, summaryInfo }, { headers: corsHeaders });
            }

            // REST API: Single Session Detail
            if (url.pathname.startsWith('/api/sessions/')) {
              const id = decodeURIComponent(url.pathname.replace('/api/sessions/', ''));
              const session = this.store.getSession(id);
              if (!session) {
                return Response.json({ error: 'Session not found' }, { status: 404, headers: corsHeaders });
              }
              return Response.json(session, { headers: corsHeaders });
            }

            // REST API: Export to Obsidian
            if (url.pathname === '/api/export/obsidian' && req.method === 'POST') {
              const exported = await this.store.exportToObsidian();
              return Response.json({ success: true, count: exported.length, files: exported }, { headers: corsHeaders });
            }

            // Default: Render HTML UI
            return new Response(this.renderHtml(), {
              headers: { 'Content-Type': 'text/html; charset=utf-8' }
            });
          }
        });
      } catch (err: any) {
        if (err?.code === 'EADDRINUSE' || err?.message?.includes('port in use')) {
          currentPort++;
          attempts++;
        } else {
          throw err;
        }
      }
    }

    if (!server) {
      throw new Error(`Could not bind harness-dash server after 10 port attempts (tried ${this.preferredPort}-${currentPort})`);
    }

    const serverUrl = `http://localhost:${server.port}`;
    return {
      url: serverUrl,
      port: server.port,
      isExisting: false,
      stop: () => server.stop()
    };
  }

  private renderHtml(): string {
    return `<!DOCTYPE html>
<html lang="en" class="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI Control Room & Universal Harness Dashboard</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: 'class',
      theme: {
        extend: {
          colors: {
            brand: {
              50: '#f0fdfa',
              400: '#2dd4bf',
              500: '#14b8a6',
              600: '#0d9488',
              900: '#134e4a'
            },
            darkbg: '#080c14',
            darksurface: '#0f172a',
            darkcard: '#131b2e',
            darkcardhover: '#1a243d',
            darkborder: '#1e293b'
          }
        }
      }
    }
  </script>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap');
    
    html, body {
      background-color: #080c14;
      color: #f1f5f9;
      font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
      margin: 0;
      padding: 0;
    }
    
    code, pre, .font-mono {
      font-family: 'JetBrains Mono', monospace;
    }

    /* Custom Sleek Scrollbar */
    ::-webkit-scrollbar {
      width: 7px;
      height: 7px;
    }
    ::-webkit-scrollbar-track {
      background: rgba(15, 23, 42, 0.4);
      border-radius: 8px;
    }
    ::-webkit-scrollbar-thumb {
      background: rgba(148, 163, 184, 0.25);
      border-radius: 8px;
    }
    ::-webkit-scrollbar-thumb:hover {
      background: rgba(45, 212, 191, 0.5);
    }
    * {
      scrollbar-width: thin;
      scrollbar-color: rgba(148, 163, 184, 0.25) rgba(15, 23, 42, 0.4);
    }

    .glass-card {
      background: rgba(19, 27, 46, 0.85);
      backdrop-filter: blur(16px);
      border: 1px solid rgba(255, 255, 255, 0.07);
      box-shadow: 0 4px 20px -2px rgba(0, 0, 0, 0.4);
    }

    .session-card {
      background: rgba(19, 27, 46, 0.6);
      border: 1px solid rgba(255, 255, 255, 0.06);
      transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
    }
    .session-card:hover {
      background: rgba(26, 36, 61, 0.9);
      border-color: rgba(45, 212, 191, 0.4);
      transform: translateY(-1px);
      box-shadow: 0 8px 24px -4px rgba(0, 0, 0, 0.5);
    }
    .session-card.selected {
      background: rgba(20, 184, 166, 0.08);
      border-color: #2dd4bf;
      box-shadow: 0 0 0 1px #2dd4bf, 0 8px 28px -4px rgba(20, 184, 166, 0.2);
    }

    .badge-running { background: rgba(34, 197, 94, 0.15); color: #4ade80; border: 1px solid rgba(34, 197, 94, 0.35); }
    .badge-idle { background: rgba(234, 179, 8, 0.15); color: #facc15; border: 1px solid rgba(234, 179, 8, 0.35); }
    .badge-completed { background: rgba(148, 163, 184, 0.12); color: #94a3b8; border: 1px solid rgba(148, 163, 184, 0.2); }
    .badge-failed { background: rgba(239, 68, 68, 0.15); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.35); }
  </style>
</head>
<body class="min-h-screen flex flex-col selection:bg-teal-500/30 selection:text-teal-200">
  <!-- Top Navigation Header -->
  <header class="border-b border-slate-800/80 bg-[#0c1220]/90 backdrop-blur-xl sticky top-0 z-50 px-8 py-4 flex items-center justify-between gap-4 flex-wrap">
    <div class="flex items-center gap-4">
      <div class="w-10 h-10 rounded-xl bg-teal-500/15 border border-teal-500/30 flex items-center justify-center text-teal-400 font-bold text-lg shadow-inner">
        ⚡
      </div>
      <div>
        <div class="flex items-center gap-3">
          <h1 class="text-lg font-extrabold tracking-tight text-white">
            HARNESS DASHBOARD
          </h1>
          <span class="text-[11px] px-2.5 py-0.5 rounded-full bg-teal-950/90 text-teal-300 border border-teal-700/60 font-mono font-medium tracking-wide">
            v1.0.0 • ONLINE
          </span>
        </div>
        <p class="text-xs text-slate-400 mt-0.5">Universal Multi-Device Session Control Room & Productivity Dragon Tracker</p>
      </div>
    </div>

    <!-- App Internal Model Spend Tracker HUD -->
    <div id="app-token-hud" class="px-3.5 py-1.5 rounded-xl bg-slate-900/90 border border-slate-800 flex items-center gap-3 text-xs font-mono shadow-inner">
      <div class="flex items-center gap-1.5 text-amber-300 font-semibold">
        <span class="animate-pulse">⚡</span>
        <span class="text-slate-300">App AI Spend:</span>
        <span id="hud-app-cost" class="text-white font-bold">$0.0000</span>
      </div>
      <span class="text-slate-700">|</span>
      <div class="text-slate-400 text-[11px]">
        <span id="hud-app-calls" class="text-slate-200 font-bold">0</span> calls
        (<span id="hud-app-tokens">0</span> tok)
      </div>
      <span class="text-slate-700">|</span>
      <div class="flex items-center gap-1.5 text-[10.5px]">
        <span id="hud-gemma-calls" class="px-1.5 py-0.5 rounded bg-amber-950/80 text-amber-300 border border-amber-800/60 font-bold">⚡ Cerebras: 0</span>
        <span id="hud-agy-calls" class="px-1.5 py-0.5 rounded bg-purple-950/80 text-purple-300 border border-purple-800/60 font-bold">🔮 AGY: 0</span>
        <span id="hud-gemini-calls" class="px-1.5 py-0.5 rounded bg-teal-950/80 text-teal-300 border border-teal-800/60 font-bold">🌿 Gemini: 0</span>
      </div>
    </div>

    <!-- Header Actions -->
    <div class="flex items-center gap-3">
      <button onclick="exportObsidian()" class="px-4 py-2 rounded-lg text-xs font-semibold bg-purple-950/80 hover:bg-purple-900 text-purple-200 border border-purple-700/50 flex items-center gap-2 transition shadow-sm hover:shadow-purple-950/50 cursor-pointer">
        <span class="text-sm">🐉</span> Sync Obsidian
      </button>
      <button onclick="refreshData()" class="px-3.5 py-2 rounded-lg text-xs font-semibold bg-slate-800/90 hover:bg-slate-700 text-slate-200 border border-slate-700 flex items-center gap-2 transition cursor-pointer">
        <span>🔄</span> Refresh
      </button>
    </div>
  </header>

  <!-- Main Responsive Container -->
  <main class="flex-1 max-w-[1600px] w-full mx-auto px-8 py-8 space-y-8">
    <!-- Top KPI Metric Cards -->
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-5" id="kpi-strip">
      <div class="glass-card rounded-2xl p-5 border-l-4 border-l-teal-500">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Active Sessions</div>
        <div class="text-3xl font-extrabold text-white mt-2 flex items-baseline gap-2">
          <span id="metric-active" class="text-teal-400">-</span>
          <span class="text-sm text-slate-400 font-normal" id="metric-total">/ - total</span>
        </div>
        <div class="text-[11px] text-slate-500 mt-1">Across all connected machines</div>
      </div>

      <div class="glass-card rounded-2xl p-5 border-l-4 border-l-purple-500">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Connected Devices</div>
        <div class="text-3xl font-extrabold text-white mt-2" id="metric-devices">-</div>
        <div class="text-[11px] text-slate-500 mt-1">Workstations, laptops, cloud VMs</div>
      </div>

      <div class="glass-card rounded-2xl p-5 border-l-4 border-l-amber-500">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400">Total Tokens & Cost</div>
        <div class="text-3xl font-extrabold text-white mt-2 flex items-baseline gap-2">
          <span id="metric-tokens">-</span>
          <span class="text-sm text-amber-400 font-medium" id="metric-cost">($-)</span>
        </div>
        <div class="text-[11px] text-slate-500 mt-1">Multi-model cumulative consumption</div>
      </div>

      <div class="glass-card rounded-2xl p-5 border-l-4 border-l-fuchsia-500">
        <div class="text-xs font-semibold uppercase tracking-wider text-fuchsia-300 flex items-center gap-1.5">
          <span>🐉</span> Productivity Dragon
        </div>
        <div class="text-3xl font-extrabold text-fuchsia-400 mt-2" id="metric-xp">+0 XP</div>
        <div class="text-[11px] text-slate-500 mt-1">Attributed milestone progress</div>
      </div>
    </div>

    <!-- Search & Filter Controls -->
    <div class="glass-card rounded-2xl p-5 flex flex-col md:flex-row gap-5 justify-between items-center">
      <!-- Search Input -->
      <div class="relative w-full md:w-[480px]">
        <div class="absolute inset-y-0 left-0 pl-3.5 flex items-center pointer-events-none text-slate-400">
          🔍
        </div>
        <input
          type="text"
          id="search-input"
          oninput="handleSearch(this.value)"
          placeholder="Search titles, summaries, commands, subagents, files..."
          class="w-full bg-[#0c1220]/90 border border-slate-700/80 rounded-xl pl-10 pr-4 py-2.5 text-sm text-white placeholder-slate-500 focus:outline-none focus:border-teal-400 focus:ring-1 focus:ring-teal-400 font-mono transition"
        />
      </div>

      <!-- Harness Filter Pills -->
      <div class="flex items-center gap-2 flex-wrap" id="harness-filters">
        <button onclick="setHarnessFilter('')" class="filter-btn active px-3.5 py-1.5 rounded-lg text-xs font-bold bg-teal-500 text-slate-950 shadow-sm" data-harness="">All Harnesses</button>
        <button onclick="setHarnessFilter('claude')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="claude">Claude</button>
        <button onclick="setHarnessFilter('agy')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="agy">AGY</button>
        <button onclick="setHarnessFilter('cpai')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="cpai">CPAI</button>
        <button onclick="setHarnessFilter('codex')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="codex">Codex</button>
        <button onclick="setHarnessFilter('omp')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="omp">OMP</button>
        <button onclick="setHarnessFilter('hermes')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="hermes">Hermes</button>
        <button onclick="setHarnessFilter('happy')" class="filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition" data-harness="happy">Happy</button>
      </div>
    </div>

    <!-- Main Content Grid -->
    <div class="grid grid-cols-1 xl:grid-cols-12 gap-8 items-start">
      <!-- Left Column: Sessions Feed (7 Cols) -->
      <div class="xl:col-span-7 space-y-4">
        <div class="flex justify-between items-center px-1">
          <h2 class="text-base font-bold text-white tracking-tight flex items-center gap-2">
            <span>Sessions Feed</span>
            <span class="text-xs px-2 py-0.5 rounded-md bg-slate-800 text-teal-400 font-mono font-medium" id="session-count">0</span>
          </h2>
          <div class="text-xs text-slate-400 font-mono">Ordered by most recent activity</div>
        </div>

        <!-- Scrollable Session Cards Container -->
        <div class="space-y-3.5 max-h-[calc(100vh-320px)] min-h-[580px] overflow-y-auto pr-2 overscroll-contain" id="session-list">
          <div class="p-12 text-center text-sm text-slate-500 glass-card rounded-2xl">
            Loading sessions across harnesses and devices...
          </div>
        </div>
      </div>

      <!-- Right Column: Inspector Panel (5 Cols, Sticky) -->
      <div class="xl:col-span-5 glass-card rounded-2xl p-6 h-[calc(100vh-280px)] min-h-[640px] sticky top-24 flex flex-col">
        <!-- Inspector Header -->
        <div class="border-b border-slate-800/80 pb-4 mb-4 flex justify-between items-center">
          <div>
            <h3 class="text-sm font-bold text-white uppercase tracking-wider">Session Inspector</h3>
            <p class="text-[11px] text-slate-400">Deep telemetry, transcript & fork actions</p>
          </div>
          <span id="inspect-harness-badge" class="text-xs font-mono font-bold px-2.5 py-1 rounded-md bg-slate-800 text-teal-300 border border-slate-700">
            SELECT A SESSION
          </span>
        </div>

        <!-- Inspector Body (Scrollable with Sleek Scrollbar) -->
        <div id="inspector-body" class="flex-1 overflow-y-auto space-y-5 pr-2">
          <div class="text-slate-500 text-center py-24 px-6">
            <div class="text-3xl mb-2 opacity-60">👈</div>
            <div class="font-medium text-slate-300">No session selected</div>
            <div class="text-xs text-slate-500 mt-1">Select any session on the left to inspect its live transcript snippet, title evolution, and subordinate activity.</div>
          </div>
        </div>
      </div>
    </div>
  </main>

  <script>
    let allSessions = [];
    let totalServerCount = 0;
    let currentOffset = 0;
    const pageSize = 100;
    let currentHarnessFilter = '';
    let currentSearchText = '';
    let selectedSessionId = null;
    let isLoading = false;
    let searchDebounce = null;

    async function loadMetrics() {
      try {
        const res = await fetch('/api/metrics');
        const data = await res.json();
        document.getElementById('metric-active').textContent = data.activeSessions;
        document.getElementById('metric-total').textContent = \`/ \${data.totalSessions} total\`;
        document.getElementById('metric-devices').textContent = data.totalDevices;
        document.getElementById('metric-tokens').textContent = (data.totalTokens || 0).toLocaleString();
        document.getElementById('metric-cost').textContent = \`($\${data.totalCostUsd.toFixed(2)})\`;
        document.getElementById('metric-xp').textContent = \`+\${data.totalProductivityDragonXp} XP\`;
      } catch (e) {
        console.error('Error loading metrics', e);
      }
    }

    async function loadSessions(reset = false) {
      if (isLoading) return;
      isLoading = true;

      if (reset) {
        currentOffset = 0;
        allSessions = [];
      }

      try {
        const params = new URLSearchParams();
        if (currentHarnessFilter) params.set('harness', currentHarnessFilter);
        if (currentSearchText) params.set('q', currentSearchText);
        params.set('limit', pageSize.toString());
        params.set('offset', currentOffset.toString());

        const res = await fetch('/api/sessions?' + params.toString());
        const data = await res.json();

        const newSessions = Array.isArray(data) ? data : (data.sessions || []);
        totalServerCount = Array.isArray(data) ? data.length : (data.totalCount || newSessions.length);

        if (reset) {
          allSessions = newSessions;
        } else {
          allSessions = [...allSessions, ...newSessions];
        }

        currentOffset = allSessions.length;
        renderSessions();
      } catch (e) {
        console.error('Error loading sessions', e);
      } finally {
        isLoading = false;
      }
    }

    function renderSessions(displayList = allSessions, isLocalFiltered = false) {
      const container = document.getElementById('session-list');
      if (isLocalFiltered) {
        document.getElementById('session-count').textContent = \`🔍 \${displayList.length} local / querying server...\`;
      } else {
        document.getElementById('session-count').textContent = \`\${allSessions.length} of \${totalServerCount}\`;
      }

      if (displayList.length === 0) {
        container.innerHTML = '<div class="p-12 text-center text-sm text-slate-500 glass-card rounded-2xl">No sessions match current filter.</div>';
        return;
      }

      // If no session selected yet, auto-select first
      if (!selectedSessionId && displayList.length > 0) {
        selectedSessionId = displayList[0].id;
      }

      const hasMore = !isLocalFiltered && allSessions.length < totalServerCount;

      const cardsHtml = displayList.map(s => {
        const isSelected = s.id === selectedSessionId;
        const subCount = s.subagentCount > 0 ? \`<span class="text-[11px] px-2 py-0.5 rounded-full bg-purple-950 text-purple-300 border border-purple-800/60 font-semibold">\${s.subagentCount} sub</span>\` : '';
        const dragonBadge = s.productivityDragon ? \`<span class="text-[11px] px-2 py-0.5 rounded-full bg-fuchsia-950 text-fuchsia-300 border border-fuchsia-800/50 font-medium">🐉 +\${s.productivityDragon.xpEarned} XP</span>\` : '';
        
        return \`
          <div onclick="selectSession('\${s.id}')" class="session-card rounded-2xl p-5 cursor-pointer \${isSelected ? 'selected' : ''}">
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-center gap-2.5 flex-wrap">
                <span class="text-[11px] font-bold px-2.5 py-0.5 rounded-full font-mono uppercase badge-\${s.status}">\${s.status}</span>
                <span class="text-[11px] font-mono font-bold px-2.5 py-0.5 rounded-full bg-slate-800 text-teal-300 border border-slate-700">\${s.harness.toUpperCase()}</span>
                <span class="text-xs font-mono text-slate-400">\${s.deviceId || s.hostname}</span>
                \${subCount}
                \${dragonBadge}
              </div>
              <span class="text-xs text-slate-400 font-mono whitespace-nowrap">\${formatAge(s.lastActivityAt)}</span>
            </div>
            
            <h4 class="text-base font-bold text-white mt-2.5 leading-snug tracking-tight">\${escapeHtml(s.title)}</h4>
            <p class="text-xs text-slate-300 mt-1.5 line-clamp-2 leading-relaxed font-normal">\${escapeHtml(s.summary || 'Active AI session')}</p>

            \${renderSubordinatesInline(s)}
          </div>
        \`;
      }).join('');

      const loadMoreBtn = hasMore ? \`
        <div class="pt-2 text-center">
          <button onclick="loadSessions(false)" class="px-5 py-2.5 rounded-xl text-xs font-bold bg-slate-800 hover:bg-slate-700 text-teal-300 border border-slate-700/80 transition w-full shadow-sm">
            Load More Sessions (+100) — \${totalServerCount - allSessions.length} remaining
          </button>
        </div>
      \` : '';

      container.innerHTML = cardsHtml + loadMoreBtn;

      if (selectedSessionId) {
        const found = displayList.find(s => s.id === selectedSessionId) || allSessions.find(s => s.id === selectedSessionId);
        if (found) renderInspector(found);
      }
    }

    function renderSubordinatesInline(session) {
      if (!session.subordinateActivities || session.subordinateActivities.length === 0) return '';
      return \`
        <div class="mt-3.5 pt-3 border-t border-slate-800/80 space-y-1.5">
          \${session.subordinateActivities.slice(0, 3).map(sub => \`
            <div class="text-xs text-slate-400 flex items-center gap-2">
              <span class="text-purple-400 font-mono font-bold">└─▶ [\${sub.type.toUpperCase()}]</span>
              <span class="text-slate-200 font-medium truncate">\${escapeHtml(sub.name)}</span>
              <span class="text-slate-500 truncate text-[11px]">\${escapeHtml(sub.summary || '')}</span>
            </div>
          \`).join('')}
          \${session.subordinateActivities.length > 3 ? \`<div class="text-[11px] text-slate-500 pl-4">+ \${session.subordinateActivities.length - 3} more subordinate activities</div>\` : ''}
        </div>
      \`;
    }

    function selectSession(id) {
      selectedSessionId = id;
      renderSessions();
      const session = allSessions.find(s => s.id === id);
      if (session) renderInspector(session);
    }

    function renderInspector(s) {
      document.getElementById('inspect-harness-badge').textContent = s.harness.toUpperCase();
      const body = document.getElementById('inspector-body');

      const titleHistoryHtml = s.titleHistory && s.titleHistory.length > 1 
        ? \`<div class="p-3 rounded-xl bg-slate-900/70 border border-slate-800 space-y-1 text-xs">
             <div class="text-slate-400 font-bold uppercase tracking-wider text-[10px]">Title History:</div>
             \${s.titleHistory.map(t => \`<div class="font-mono text-slate-300 pl-2 border-l-2 border-teal-500/50">• \${escapeHtml(t)}</div>\`).join('')}
           </div>\`
        : '';

      const lastLinesHtml = s.lastLines && s.lastLines.length > 0
        ? \`<pre class="bg-[#080c14] p-4 rounded-xl text-xs font-mono text-slate-200 overflow-x-auto max-h-60 leading-relaxed border border-slate-800/90 shadow-inner">\${escapeHtml(s.lastLines.join('\\n'))}</pre>\`
        : '<div class="text-xs text-slate-500 p-3 bg-slate-900/40 rounded-xl border border-slate-800">No transcript snippet available.</div>';

      const dragonHtml = s.productivityDragon
        ? \`<div class="p-3.5 rounded-xl bg-purple-950/40 border border-purple-800/60 text-xs text-purple-200">
             <div class="font-bold flex items-center gap-2 text-purple-300 text-sm">🐉 \${escapeHtml(s.productivityDragon.questTitle || 'Quest')}</div>
             <div class="mt-1 text-purple-300 font-mono text-[11px]">Reward: +\${s.productivityDragon.xpEarned} XP • Confidence: \${Math.round(s.productivityDragon.confidenceScore * 100)}%</div>
           </div>\`
        : '';

      body.innerHTML = \`
        <div>
          <div class="text-[11px] text-slate-400 font-mono truncate">\${s.id}</div>
          <h3 class="text-lg font-extrabold text-white mt-1 leading-snug">\${escapeHtml(s.title)}</h3>
        </div>

        \${titleHistoryHtml}

        <div class="flex items-center gap-3">
          <a href="\${s.url}" class="px-4 py-2 rounded-xl text-xs font-bold bg-teal-500 hover:bg-teal-400 text-slate-950 flex items-center gap-2 transition shadow-md shadow-teal-950/50">
            🚀 Open in \${s.harness.toUpperCase()}
          </a>
          <button onclick="forkSession('\${s.id}')" class="px-4 py-2 rounded-xl text-xs font-semibold bg-slate-800 hover:bg-slate-700 text-slate-200 border border-slate-700 transition">
            🌿 Fork Worktree
          </button>
        </div>

        \${dragonHtml}

        <div class="space-y-2 text-xs text-slate-300 bg-slate-900/80 p-3.5 rounded-xl border border-slate-800">
          <div><span class="text-slate-400 font-medium">Directory:</span> <code class="text-teal-300 font-mono ml-1">\${escapeHtml(s.cwd)}</code></div>
          \${s.gitBranch ? \`<div><span class="text-slate-400 font-medium">Git Branch:</span> <code class="text-amber-300 font-mono ml-1">\${escapeHtml(s.gitBranch)}</code></div>\` : ''}
          <div><span class="text-slate-400 font-medium">Deep Link:</span> <code class="text-cyan-300 font-mono ml-1 text-[11px]">\${escapeHtml(s.url)}</code></div>
          <div><span class="text-slate-400 font-medium">Token Usage:</span> <span class="text-slate-200 font-mono ml-1">\${s.tokenUsage.inputTokens.toLocaleString()} in / \${s.tokenUsage.outputTokens.toLocaleString()} out ($ \${s.tokenUsage.totalCostUsd})</span></div>
        </div>

        <div>
          <div class="flex items-center justify-between mb-2">
            <div class="text-xs font-bold text-slate-400 uppercase tracking-wider">AI Summary</div>
            <span id="summary-model-badge" class="text-[11px] font-mono px-2.5 py-0.5 rounded-full \${s.summaryInfo && s.summaryInfo.costTier === '$$$' ? 'bg-amber-950 text-amber-300 border border-amber-800/60 font-semibold' : s.summaryInfo && s.summaryInfo.costTier === '$$' ? 'bg-purple-950 text-purple-300 border border-purple-800/60 font-semibold' : 'bg-teal-950 text-teal-300 border border-teal-800/60 font-semibold'}">
              ✨ \${s.summaryInfo ? \`\${escapeHtml(s.summaryInfo.modelLabel)} (\${s.summaryInfo.costTier})\${s.summaryInfo.latencyMs ? \` • \${s.summaryInfo.latencyMs}ms\` : ''}\${s.summaryInfo.inputTokens !== undefined ? \` • \${s.summaryInfo.inputTokens} in / \${s.summaryInfo.outputTokens} out ($\${s.summaryInfo.costUsd ? s.summaryInfo.costUsd.toFixed(6) : '0.000000'})\` : ''}\` : 'Extractive Heuristic ($0.00)'}
            </span>
          </div>
          <div id="summary-content-box" class="p-4 rounded-xl bg-slate-900/90 border border-slate-800 text-xs text-slate-200 leading-relaxed font-normal shadow-inner">
            \${escapeHtml(s.summary || 'Active session')}
          </div>
          <div class="mt-3 pt-2.5 border-t border-slate-800/80 flex items-center gap-2 flex-wrap">
            <span class="text-[11px] font-medium text-slate-400">Re-run prompt with:</span>
            <button onclick="reSummarize('\${s.id}', 'gemma-4-cerebras')" class="px-2.5 py-1 rounded-lg text-[11px] font-bold bg-amber-950/80 hover:bg-amber-900 text-amber-300 border border-amber-800/60 transition shadow-sm flex items-center gap-1 cursor-pointer">
              ⚡ Gemma 4 @ Cerebras ($$$ • Fast)
            </button>
            <button onclick="reSummarize('\${s.id}', 'antigravity')" class="px-2.5 py-1 rounded-lg text-[11px] font-bold bg-purple-950/80 hover:bg-purple-900 text-purple-300 border border-purple-800/60 transition shadow-sm flex items-center gap-1 cursor-pointer">
              🔮 Antigravity ($$ • Deep)
            </button>
            <button onclick="reSummarize('\${s.id}', 'gemini-2.5-flash')" class="px-2.5 py-1 rounded-lg text-[11px] font-bold bg-teal-950/80 hover:bg-teal-900 text-teal-300 border border-teal-800/60 transition shadow-sm flex items-center gap-1 cursor-pointer">
              🌿 Gemini 2.5 Flash ($ • Budget)
            </button>
          </div>
        </div>

        <div>
          <div class="flex items-center justify-between mb-2">
            <div class="text-xs font-bold text-slate-400 uppercase tracking-wider">Session Transcript (Lazy Loaded)</div>
            <!-- Transcript Filter Tabs -->
            <div class="flex items-center gap-1 bg-[#05080f] p-1 rounded-xl border border-slate-800 text-[11px] font-mono">
              <button onclick="setTranscriptTab('formatted')" id="tab-btn-formatted" class="px-2.5 py-1 rounded-lg text-white bg-slate-800 font-bold transition shadow-sm cursor-pointer">👁️ Kanban</button>
              <button onclick="setTranscriptTab('user')" id="tab-btn-user" class="px-2.5 py-1 rounded-lg text-slate-400 hover:text-white transition cursor-pointer">👤 Prompts</button>
              <button onclick="setTranscriptTab('tools')" id="tab-btn-tools" class="px-2.5 py-1 rounded-lg text-slate-400 hover:text-white transition cursor-pointer">🔧 Tools</button>
              <button onclick="setTranscriptTab('raw')" id="tab-btn-raw" class="px-2.5 py-1 rounded-lg text-slate-400 hover:text-white transition cursor-pointer">📄 Raw JSONL</button>
            </div>
          </div>
          <div id="transcript-container" class="max-h-[500px] overflow-y-auto space-y-2.5 pr-1">
            <div class="p-8 text-center text-xs text-teal-300 animate-pulse font-mono glass-card rounded-2xl border border-teal-500/20">
              ⚡ Loading session transcript on-demand...
            </div>
          </div>
        </div>
      \`;

      loadTranscript(s.id);
    }

    let currentTranscriptData = null;
    let currentTranscriptTab = 'formatted';

    async function loadTranscript(sessionId) {
      const container = document.getElementById('transcript-container');
      if (!container) return;
      container.innerHTML = \`<div class="p-8 text-center text-xs text-teal-300 animate-pulse font-mono glass-card rounded-2xl border border-teal-500/20">
        ⚡ Loading session transcript for \${sessionId}...
      </div>\`;

      try {
        const res = await fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/transcript?tail=200');
        if (!res.ok) throw new Error('Transcript not found');
        const data = await res.json();
        currentTranscriptData = data;
        renderTranscriptTabContent();
      } catch (err) {
        container.innerHTML = \`<div class="p-6 text-center text-xs text-slate-500 glass-card rounded-xl font-mono">
          No live transcript available on disk (\${err.message}).
        </div>\`;
      }
    }

    function setTranscriptTab(tab) {
      currentTranscriptTab = tab;
      ['formatted', 'user', 'tools', 'raw'].forEach(t => {
        const btn = document.getElementById('tab-btn-' + t);
        if (btn) {
          if (t === tab) {
            btn.className = 'px-2.5 py-1 rounded-lg text-white bg-teal-500 font-bold text-slate-950 transition shadow-sm cursor-pointer';
          } else {
            btn.className = 'px-2.5 py-1 rounded-lg text-slate-400 hover:text-white transition cursor-pointer';
          }
        }
      });
      renderTranscriptTabContent();
    }

    function renderTranscriptTabContent() {
      const container = document.getElementById('transcript-container');
      if (!container || !currentTranscriptData) return;

      const { entries, rawLines, formattedHtml } = currentTranscriptData;

      if (currentTranscriptTab === 'formatted') {
        container.innerHTML = formattedHtml || '<div class="p-6 text-center text-xs text-slate-500">No events found.</div>';
        return;
      }

      if (currentTranscriptTab === 'user') {
        const userEntries = (entries || []).filter(e => e.role === 'user');
        if (userEntries.length === 0) {
          container.innerHTML = '<div class="p-6 text-center text-xs text-slate-500 glass-card rounded-xl font-mono">No user prompt events in recent snippet.</div>';
          return;
        }
        container.innerHTML = userEntries.map(e => \`
          <div class="p-4 rounded-xl bg-blue-950/40 border border-blue-800/60 text-xs shadow-sm space-y-1.5">
            <div class="flex items-center justify-between text-[11px] font-bold text-blue-300 font-mono">
              <span>👤 User Instruction #\${e.index}</span>
              \${e.timestamp ? \`<span class="text-[10px] text-slate-500">\${new Date(e.timestamp).toLocaleTimeString()}</span>\` : ''}
            </div>
            <div class="text-slate-100 whitespace-pre-wrap leading-relaxed select-text">\${escapeHtml(e.content)}</div>
          </div>
        \`).join('');
        return;
      }

      if (currentTranscriptTab === 'tools') {
        const toolEntries = (entries || []).filter(e => e.role === 'tool_call' || e.role === 'tool_result');
        if (toolEntries.length === 0) {
          container.innerHTML = '<div class="p-6 text-center text-xs text-slate-500 glass-card rounded-xl font-mono">No tool executions recorded in recent snippet.</div>';
          return;
        }
        container.innerHTML = toolEntries.map(e => \`
          <div class="p-3.5 rounded-xl bg-[#090e17] border border-slate-800/90 text-xs shadow-inner space-y-1.5">
            <div class="flex items-center justify-between text-[11px] font-mono">
              <span class="font-bold text-amber-300">🔧 \${escapeHtml(e.title)}</span>
              <span class="text-[10px] text-slate-500 font-mono">#\${e.index}</span>
            </div>
            <div class="font-mono text-slate-300 text-[11px] bg-[#04070e] p-2.5 rounded-lg border border-slate-900 overflow-x-auto select-text">\${escapeHtml(e.content)}</div>
          </div>
        \`).join('');
        return;
      }

      if (currentTranscriptTab === 'raw') {
        const text = (rawLines || []).join('\\n');
        container.innerHTML = \`<pre class="bg-[#05080f] p-4 rounded-xl text-[11px] font-mono text-slate-300 overflow-x-auto max-h-[460px] leading-relaxed border border-slate-800 select-text">\${escapeHtml(text)}</pre>\`;
        return;
      }
    }

    async function loadAppMetrics() {
      try {
        const res = await fetch('/api/app-metrics');
        const data = await res.json();
        updateAppHud(data);
      } catch (e) {
        console.error('Error loading app metrics', e);
      }
    }

    function updateAppHud(appMetrics) {
      if (!appMetrics) return;
      document.getElementById('hud-app-cost').textContent = '$' + (appMetrics.totalCostUsd || 0).toFixed(4);
      document.getElementById('hud-app-calls').textContent = (appMetrics.totalCalls || 0).toLocaleString();
      document.getElementById('hud-app-tokens').textContent = ((appMetrics.totalInputTokens || 0) + (appMetrics.totalOutputTokens || 0)).toLocaleString();

      const gemma = appMetrics.byModel?.['gemma-4-cerebras']?.calls || 0;
      const agy = appMetrics.byModel?.['antigravity']?.calls || 0;
      const gemini = appMetrics.byModel?.['gemini-2.5-flash']?.calls || 0;

      document.getElementById('hud-gemma-calls').textContent = '⚡ Cerebras: ' + gemma;
      document.getElementById('hud-agy-calls').textContent = '🔮 AGY: ' + agy;
      document.getElementById('hud-gemini-calls').textContent = '🌿 Gemini: ' + gemini;
    }

    async function reSummarize(sessionId, model) {
      const box = document.getElementById('summary-content-box');
      const badge = document.getElementById('summary-model-badge');
      if (badge) {
        badge.innerHTML = \`<span class="inline-flex items-center gap-1.5"><svg class="animate-spin h-3 w-3 text-teal-400" viewBox="0 0 24 24" fill="none"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg> Synthesizing...</span>\`;
      }
      if (box) {
        box.innerHTML = \`<div class="flex items-center gap-3 text-teal-300 font-mono text-xs py-2">
          <svg class="animate-spin h-4 w-4 text-teal-400 shrink-0" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
          <span class="animate-pulse">Synthesizing AI summary with \${model}...</span>
        </div>\`;
      }
      try {
        const res = await fetch('/api/sessions/' + encodeURIComponent(sessionId) + '/summarize?model=' + encodeURIComponent(model), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' }
        });
        const data = await res.json();
        if (data.success && data.session) {
          const idx = allSessions.findIndex(s => s.id === sessionId);
          if (idx !== -1) {
            allSessions[idx] = data.session;
            renderSessions();
            renderInspector(data.session);
          }
          loadAppMetrics();
        }
      } catch (err) {
        console.error('Error re-summarizing', err);
        if (box) box.textContent = 'Failed to re-run prompt: ' + err;
      }
    }

    function handleSearch(val) {
      currentSearchText = val;
      const term = val.trim().toLowerCase();

      // 1. Instant 0ms in-memory live filter over loaded sessions
      if (term) {
        const localMatches = allSessions.filter(s => {
          const inTitle = (s.title || '').toLowerCase().includes(term);
          const inSummary = (s.summary || '').toLowerCase().includes(term);
          const inHarness = (s.harness || '').toLowerCase().includes(term);
          const inDevice = (s.deviceId || s.hostname || '').toLowerCase().includes(term);
          const inCwd = (s.cwd || '').toLowerCase().includes(term);
          const inSub = (s.subordinateActivities || []).some(sub => 
            (sub.name || '').toLowerCase().includes(term) || (sub.summary || '').toLowerCase().includes(term)
          );
          return inTitle || inSummary || inHarness || inDevice || inCwd || inSub;
        });
        renderSessions(localMatches, true);
      } else {
        renderSessions(allSessions, false);
      }

      // 2. Parallel debounced server dispatch (250ms) for global search
      if (searchDebounce) clearTimeout(searchDebounce);
      searchDebounce = setTimeout(() => {
        loadSessions(true);
      }, 250);
    }

    function setHarnessFilter(harness) {
      currentHarnessFilter = harness;
      document.querySelectorAll('.filter-btn').forEach(btn => {
        if (btn.getAttribute('data-harness') === harness) {
          btn.className = 'filter-btn active px-3.5 py-1.5 rounded-lg text-xs font-bold bg-teal-500 text-slate-950 shadow-sm';
        } else {
          btn.className = 'filter-btn px-3.5 py-1.5 rounded-lg text-xs font-semibold bg-slate-800 text-slate-300 hover:bg-slate-700 hover:text-white transition';
        }
      });
      loadSessions(true);
    }

    async function exportObsidian() {
      try {
        const res = await fetch('/api/export/obsidian', { method: 'POST' });
        const data = await res.json();
        alert(\`Synced \${data.count} session cards to Obsidian Productivity Dragon!\`);
      } catch (e) {
        alert('Failed to sync to Obsidian: ' + e);
      }
    }

    function forkSession(id) {
      alert(\`Forking session \${id} into a new isolated subagent worktree...\`);
    }

    function refreshData() {
      loadMetrics();
      loadSessions(true);
    }

    function formatAge(dateStr) {
      const diffSec = Math.floor((Date.now() - new Date(dateStr).getTime()) / 1000);
      if (diffSec < 60) return \`\${diffSec}s ago\`;
      const diffMin = Math.floor(diffSec / 60);
      if (diffMin < 60) return \`\${diffMin}m ago\`;
      const diffHr = Math.floor(diffMin / 60);
      if (diffHr < 24) return \`\${diffHr}h ago\`;
      return \`\${Math.floor(diffHr / 24)}d ago\`;
    }

    function escapeHtml(str) {
      if (!str) return '';
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    // Connect SSE Stream
    const sse = new EventSource('/api/stream');
    sse.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'init') {
          if (msg.appMetrics) updateAppHud(msg.appMetrics);
          loadMetrics();
          loadSessions(false);
        } else if (msg.type === 'app_metrics_update') {
          if (msg.appMetrics) updateAppHud(msg.appMetrics);
        } else if (msg.type === 'session_update') {
          loadMetrics();
          loadSessions(false);
        }
      } catch (e) {}
    };

    // Auto load more when scrolling near bottom
    const listEl = document.getElementById('session-list');
    listEl.addEventListener('scroll', () => {
      if (listEl.scrollTop + listEl.clientHeight >= listEl.scrollHeight - 100) {
        if (allSessions.length < totalServerCount && !isLoading) {
          loadSessions(false);
        }
      }
    });

    // Initial load
    loadMetrics();
    loadAppMetrics();
    loadSessions(true);
  </script>
</body>
</html>`;
  }
}

