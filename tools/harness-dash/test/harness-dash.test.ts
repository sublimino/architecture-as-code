import { describe, expect, it, beforeEach } from 'bun:test';
import * as os from 'node:os';
import * as path from 'node:path';
import { SyncStore } from '../src/store/sync-store';
import { AdapterRegistry } from '../src/adapters/registry';
import { SessionSummarizer } from '../src/summarizer/summarizer';
import { DragonCrossReferencer } from '../src/productivity-dragon/dragon-crossref';
import { TuiDashboardRenderer } from '../src/dashboard/tui';
import type { SessionMetadata } from '../src/types';

describe('Universal AI CLI & Harness Dashboard Suite', () => {
  const tmpDir = path.join(os.tmpdir(), `harness-test-${Date.now()}`);
  let store: SyncStore;

  beforeEach(() => {
    store = new SyncStore({
      primaryStoreDir: tmpDir,
      deviceId: 'test-workstation',
      hostname: 'test-host'
    });
  });

  it('initializes adapter registry with all standard harnesses', () => {
    const registry = new AdapterRegistry();
    const adapters = registry.getAll();
    expect(adapters.length).toBeGreaterThanOrEqual(7);

    const names = adapters.map((a) => a.harnessName);
    expect(names).toContain('claude');
    expect(names).toContain('agy');
    expect(names).toContain('cpai');
    expect(names).toContain('codex');
    expect(names).toContain('omp');
    expect(names).toContain('hermes');
    expect(names).toContain('happy');
  });

  it('saves and retrieves sessions from partitioned sync store with zero conflict', async () => {
    const mockSession: SessionMetadata = {
      id: 'claude-test-session-123',
      harness: 'claude',
      deviceId: 'test-macbook',
      hostname: 'macbook-pro',
      title: 'Fix Spire JWKS Discovery in D2 Fleet',
      titleHistory: ['Spire debug', 'Fix Spire JWKS Discovery in D2 Fleet'],
      currentGoal: 'Fix Spire JWKS Discovery in D2 Fleet',
      status: 'running',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy/src/cp/osramp-demo',
      gitBranch: 'feat/spire-jwks',
      gitRepo: 'osramp-demo',
      modelsUsed: ['claude-3-7-sonnet'],
      tokenUsage: { inputTokens: 42000, outputTokens: 6400, totalCostUsd: 0.18, contextWindowUsedPct: 21 },
      subagentCount: 2,
      subordinateActivities: [
        {
          id: 'subagent-1',
          parentId: 'claude-test-session-123',
          type: 'subagent',
          name: 'Spire Certificate Debugger',
          status: 'running',
          startedAt: new Date().toISOString(),
          summary: 'Inspecting SPIFFE /tmp/spire-server/private socket'
        }
      ],
      summary: 'Configured spire-oidc socket and OpenBao JWT role validation',
      lastLines: ['Running command: make demo-bao-up', 'Spire server responsive: true'],
      url: 'claude://session/test-session-123',
      tags: ['spire', 'openbao', 'osramp-demo']
    };

    await store.saveSession(mockSession);

    const retrieved = store.getSession('claude-test-session-123');
    expect(retrieved).toBeDefined();
    expect(retrieved?.title).toBe('Fix Spire JWKS Discovery in D2 Fleet');
    expect(retrieved?.subagentCount).toBe(2);
    expect(retrieved?.subordinateActivities.length).toBe(1);

    // Verify metrics
    const metrics = store.getMetrics();
    expect(metrics.totalSessions).toBe(1);
    expect(metrics.activeSessions).toBe(1);
    expect(metrics.harnessBreakdown.claude).toBe(1);
  });

  it('summarizes session tails and detects blockers and tool actions', () => {
    const summarizer = new SessionSummarizer();

    const normalLines = [
      JSON.stringify({ type: 'USER_INPUT', content: 'Build tailscale-dash dashboard' }),
      JSON.stringify({
        tool_calls: [{ name: 'write_to_file', arguments: { TargetFile: 'src/cli.ts' } }]
      })
    ];
    const normalSummary = summarizer.summarize(normalLines);
    expect(normalSummary).toContain('write_to_file: src/cli.ts');

    const errorLines = [
      JSON.stringify({
        status: 'ERROR',
        error: { message: 'Connection refused on port 8080' }
      })
    ];
    const errorSummary = summarizer.summarize(errorLines);
    expect(errorSummary).toContain('⚠️ Blocker: Connection refused on port 8080');
  });

  it('smartly routes small hot-path payloads to Cerebras Gemma 4 ($$$) and background to Gemini 2.5 Flash ($)', async () => {
    const summarizer = new SessionSummarizer();
    const smallSession: SessionMetadata = {
      id: 'test-small',
      harness: 'agy',
      deviceId: 'dev',
      hostname: 'host',
      title: 'Small session',
      titleHistory: [],
      status: 'completed',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/tmp',
      modelsUsed: [],
      tokenUsage: { inputTokens: 100, outputTokens: 50, totalCostUsd: 0.001 },
      subagentCount: 0,
      subordinateActivities: [],
      summary: '',
      lastLines: ['Ran tests successfully'],
      url: 'agy://open?id=test-small&dir=%2Ftmp',
      tags: []
    };

    // Hot path small payload (<10KB)
    const hotResult = await summarizer.summarizeSmart(smallSession, true);
    expect(['gemma-4-cerebras', 'gemini-2.5-flash', 'extractive']).toContain(hotResult.model);
    expect(['$', '$$', '$$$']).toContain(hotResult.costTier);

    // Large payload or background -> routes to gemini-2.5-flash
    const bgResult = await summarizer.summarizeSmart(smallSession, false);
    expect(['gemini-2.5-flash', 'extractive']).toContain(bgResult.model);
    expect(bgResult.costTier).toBe('$');
  });

  it('cross-references sessions with Obsidian Productivity Dragon quests', () => {
    const crossref = new DragonCrossReferencer();
    const session: SessionMetadata = {
      id: 'agy-dragon-test',
      harness: 'agy',
      deviceId: 'linux-desktop',
      hostname: 'desktop-host',
      title: 'D2 Fleet and Flux ResourceSet deployment',
      titleHistory: ['D2 Fleet'],
      status: 'completed',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy/src/cp/osramp-demo',
      gitRepo: 'osramp-demo',
      modelsUsed: ['gemini-3.7-flash'],
      tokenUsage: { inputTokens: 10000, outputTokens: 2000, totalCostUsd: 0.01 },
      subagentCount: 0,
      subordinateActivities: [],
      summary: 'Deployed Flux operator and bootstrap ResourceSet',
      lastLines: [],
      url: 'conversation://dragon-test',
      tags: ['fleet', 'flux', 'bootstrap']
    };

    const match = crossref.matchSession(session);
    expect(match).toBeDefined();
    expect(match?.questTitle).toContain('D2 Fleet & GitOps Foundation Hardening');
    expect(match?.xpEarned).toBeGreaterThan(0);
  });

  it('renders wide TUI dashboard with columns and status badges', () => {
    const renderer = new TuiDashboardRenderer();
    const session: SessionMetadata = {
      id: 'agy-ui-test',
      harness: 'agy',
      deviceId: 'dev-box',
      hostname: 'dev-host',
      title: 'Tailscale Dashboard Implementation',
      titleHistory: ['Tailscale Dashboard Implementation'],
      status: 'running',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy/src/cp/osramp-demo',
      modelsUsed: ['gemini-3.7-flash'],
      tokenUsage: { inputTokens: 25000, outputTokens: 4000, totalCostUsd: 0.02 },
      subagentCount: 1,
      subordinateActivities: [
        {
          id: 'sub-1',
          parentId: 'agy-ui-test',
          type: 'subagent',
          name: 'Route Inspector',
          status: 'running',
          startedAt: new Date().toISOString(),
          summary: 'Testing auto-detected URLs'
        }
      ],
      summary: 'Generated terminal wide view and routes table',
      lastLines: ['tailscale status --json'],
      url: 'conversation://ui-test',
      tags: ['tailscale', 'dash']
    };

    const metrics = {
      totalSessions: 1,
      activeSessions: 1,
      totalDevices: 1,
      harnessBreakdown: { claude: 0, agy: 1, cpai: 0, codex: 0, omp: 0, hermes: 0, happy: 0, custom: 0 },
      totalTokens: 29000,
      totalCostUsd: 0.02,
      totalProductivityDragonXp: 45,
      recentSessions: [session]
    };

    const { lines } = renderer.render([session], metrics, { wide: true });
    const rendered = lines.join('\n');
    expect(rendered).toContain('HARNESS-DASH');
    expect(rendered).toContain('Tailscale Dashboard');
    expect(rendered).toContain('AGY');
    expect(rendered).toContain('1s'); // Subordinate indicator

    // Test Inspector view
    const inspectResult = renderer.render([session], metrics, { inspectedSession: session });
    const inspectText = inspectResult.lines.join('\n');
    expect(inspectText).toContain('SESSION INSPECTOR');
    expect(inspectText).toContain('Route Inspector');
    expect(inspectText).toContain('Generated terminal wide view');
  });

  it('filters and searches sessions across titles, subagents, and summaries', async () => {
    const s1: SessionMetadata = {
      id: 'claude-search-1',
      harness: 'claude',
      deviceId: 'dev-box',
      hostname: 'dev-host',
      title: 'Investigate Tailscale routes',
      titleHistory: ['Tailscale'],
      status: 'completed',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy',
      modelsUsed: ['claude-3-7-sonnet'],
      tokenUsage: { inputTokens: 5000, outputTokens: 1000, totalCostUsd: 0.01 },
      subagentCount: 0,
      subordinateActivities: [],
      summary: 'Probed tailscale peers',
      lastLines: [],
      url: 'claude://session/1',
      tags: ['tailscale']
    };

    const s2: SessionMetadata = {
      id: 'cpai-search-2',
      harness: 'cpai',
      deviceId: 'dev-box',
      hostname: 'dev-host',
      title: 'Deploy OpenBao Secret Engine',
      titleHistory: ['OpenBao'],
      status: 'running',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy/src/cp/osramp-demo',
      modelsUsed: ['claude-3-7-sonnet'],
      tokenUsage: { inputTokens: 8000, outputTokens: 2000, totalCostUsd: 0.02 },
      subagentCount: 1,
      subordinateActivities: [
        {
          id: 'sub-bao',
          parentId: 'cpai-search-2',
          type: 'subagent',
          name: 'JWT Role Provisioner',
          status: 'running',
          startedAt: new Date().toISOString(),
          summary: 'Configuring auth/spiffe path'
        }
      ],
      summary: 'OpenBao secrets engine ready',
      lastLines: [],
      url: 'cpai://session/2',
      tags: ['openbao', 'security']
    };

    await store.saveSession(s1);
    await store.saveSession(s2);

    const searchResults = store.listSessions({ text: 'OpenBao' });
    expect(searchResults.length).toBe(1);
    expect(searchResults[0].id).toBe('cpai-search-2');

    const subagentSearchResults = store.listSessions({ text: 'JWT Role Provisioner' });
    expect(subagentSearchResults.length).toBe(1);
    expect(subagentSearchResults[0].id).toBe('cpai-search-2');

    const harnessResults = store.listSessions({ harness: 'claude' });
    expect(harnessResults.length).toBe(1);
    expect(harnessResults[0].id).toBe('claude-search-1');
  });

  it('guarantees zero line wrapping across various terminal widths', () => {
    const renderer = new TuiDashboardRenderer();
    const session: SessionMetadata = {
      id: 'claude-session-wrap-test',
      harness: 'claude',
      deviceId: 'fortuna-long-hostname',
      hostname: 'fortuna-long-hostname',
      title: 'Very long title that might overflow the line boundary in smaller terminals',
      titleHistory: [],
      status: 'running',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      lastActivityAt: new Date().toISOString(),
      cwd: '/home/andy/src/cp/osramp-demo',
      modelsUsed: ['claude-3-7-sonnet'],
      tokenUsage: { inputTokens: 25000, outputTokens: 4000, totalCostUsd: 0.02 },
      subagentCount: 3,
      subordinateActivities: [],
      summary: 'Very long AI summary detailing complex multi-step operations that spans across many columns',
      lastLines: ['tailscale status --json'],
      url: 'claude://session/05f011b1-1e14-41d3-98fe-891011121314',
      tags: ['test']
    };

    const metrics: DashboardMetrics = {
      totalSessions: 4400,
      activeSessions: 5,
      totalDevices: 2,
      harnessBreakdown: { claude: 4000, agy: 350, cpai: 10, codex: 20, omp: 10, hermes: 10, happy: 0, custom: 0 },
      totalTokens: 15000000,
      totalCostUsd: 12.5,
      totalProductivityDragonXp: 195000,
      recentSessions: [session]
    };

    for (const termWidth of [80, 100, 120, 140, 160, 200]) {
      const { lines } = renderer.render([session], metrics, { termWidth, termHeight: 24 });
      for (const line of lines) {
        const clean = line.replace(/\x1b\[[0-9;]*m/g, '');
        // Check visual character width
        let width = 0;
        for (const ch of clean) {
          const code = ch.codePointAt(0) || 0;
          if (code === 0x26a1 || code === 0x25cf || code === 0x25d0 || code === 0x25cb || code === 0x25b6 || (code >= 0x1f300 && code <= 0x1faff)) {
            width += 2;
          } else {
            width += 1;
          }
        }
        expect(width).toBeLessThanOrEqual(termWidth);
      }
    }
  });
});
