#!/usr/bin/env bun
import * as os from 'node:os';
import * as path from 'node:path';
import { SyncStore } from './store/sync-store';
import { TuiDashboardRenderer } from './dashboard/tui';
import { WebDashboardServer } from './dashboard/web-server';
import type { HarnessType, SearchQuery, SessionMetadata } from './types';

async function main() {
  const args = process.argv.slice(2);
  const hostname = os.hostname();
  const deviceId = process.env.HARNESS_DEVICE_ID || hostname;

  const storeDir =
    process.env.HARNESS_STORE_DIR ||
    path.join(process.env.HOME || '/home/andy', 'Dropbox', 'codex-vitae', 'ai-sessions');

  const vaultDir =
    process.env.OBSIDIAN_VAULT_DIR ||
    path.join(process.env.HOME || '/home/andy', 'Dropbox', 'codex-vitae');

  const store = new SyncStore({
    primaryStoreDir: storeDir,
    obsidianVaultDir: vaultDir,
    deviceId,
    hostname
  });

  // Fast pre-load from cache
  await store.loadCached();

  // Parse arguments
  let mode: 'interactive_tui' | 'static_tui' | 'web' | 'json' | 'export' | 'tail' | 'get' | 'help' = 'interactive_tui';
  let searchText: string | undefined;
  let harnessFilter: HarnessType | undefined;
  let deviceFilter: string | undefined;
  let webPort = 3838;
  let targetSessionId: string | undefined;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--web' || arg === '--server') {
      mode = 'web';
    } else if (arg === '-w' || arg === '--watch') {
      // -w / --watch = Live interactive TUI monitor (matching tailscale-dash -w)
      mode = 'interactive_tui';
    } else if (arg === '--static' || arg === '--table') {
      mode = 'static_tui';
    } else if (arg === '--json' || arg === '-j') {
      mode = 'json';
    } else if (arg === '--export-obsidian' || arg === '--obsidian') {
      mode = 'export';
    } else if (arg === '--port' || arg === '-p') {
      webPort = parseInt(args[++i], 10) || 3838;
    } else if (arg === '--search' || arg === '-s') {
      searchText = args[++i];
    } else if (arg === '--harness') {
      harnessFilter = args[++i] as HarnessType;
    } else if (arg === '--device') {
      deviceFilter = args[++i];
    } else if (arg === 'tail') {
      mode = 'tail';
      targetSessionId = args[++i];
    } else if (arg === 'get') {
      mode = 'get';
      targetSessionId = args[++i];
    } else if (arg === '--help' || arg === '-h' || arg === 'help') {
      mode = 'help';
    }
  }

  if (mode === 'help') {
    printHelp();
    process.exit(0);
  }

  // Run initial async scan
  await store.scanLocalHarnesses();

  if (mode === 'web') {
    store.startBackgroundScanner(5000);
    const server = new WebDashboardServer(store, webPort);
    const res = await server.start();
    if (res.isExisting) {
      console.log(`\x1b[1m\x1b[36m⚡ HARNESS DASHBOARD WEB SERVER ALREADY RUNNING\x1b[0m`);
      console.log(`  Access dashboard at: \x1b[1m\x1b[32m${res.url}\x1b[0m`);
      return;
    }

    console.log(`\x1b[1m\x1b[36m⚡ HARNESS DASHBOARD WEB SERVER RUNNING\x1b[0m`);
    console.log(`  Access dashboard at: \x1b[1m\x1b[32m${res.url}\x1b[0m`);
    console.log(`  Syncing sessions across devices and Obsidian Productivity Dragon...`);
    console.log(`  Press Ctrl+C to stop.`);

    // Keep server process running persistently
    await new Promise(() => {});
    return;
  }

  if (mode === 'export') {
    console.log(`Exporting session cards to Obsidian Productivity Dragon...`);
    const files = await store.exportToObsidian();
    console.log(`✓ Successfully exported ${files.length} session cards.`);
    for (const f of files.slice(0, 5)) {
      console.log(`  - ${f}`);
    }
    if (files.length > 5) {
      console.log(`  ... and ${files.length - 5} more.`);
    }
    return;
  }

  if (mode === 'tail' && targetSessionId) {
    const session = store.getSession(targetSessionId);
    if (!session) {
      console.error(`Session '${targetSessionId}' not found.`);
      process.exit(1);
    }
    console.log(`\x1b[1m--- Last Transcript Snippet: ${session.title} (${session.id}) ---\x1b[0m`);
    for (const l of session.lastLines) {
      console.log(l);
    }
    return;
  }

  if (mode === 'get' && targetSessionId) {
    const session = store.getSession(targetSessionId);
    if (!session) {
      console.error(`Session '${targetSessionId}' not found.`);
      process.exit(1);
    }
    console.log(JSON.stringify(session, null, 2));
    return;
  }

  const query: SearchQuery = {
    text: searchText,
    harness: harnessFilter,
    deviceId: deviceFilter
  };

  if (mode === 'json') {
    const sessions = store.listSessions(query);
    console.log(JSON.stringify(sessions, null, 2));
    return;
  }

  const renderer = new TuiDashboardRenderer();

  // If stdout is not a TTY (piped to another command) or explicit static requested
  if (!process.stdout.isTTY || mode === 'static_tui') {
    const sessions = store.listSessions(query);
    const metrics = store.getMetrics();
    const { lines } = renderer.render(sessions, metrics, { searchQuery: searchText });
    console.log(lines.join('\n'));
    return;
  }

  // Default: Full Interactive TUI Dashboard (matching tailscale-dash)
  await renderer.runInteractive(store, query);
}

function printHelp() {
  console.log(`
\x1b[1m\x1b[36mHARNESS-DASH\x1b[0m — Universal Multi-Device AI Session & Activity Control Room

\x1b[1mUSAGE:\x1b[0m
  harness-dash [OPTIONS] [COMMAND]

\x1b[1mDEFAULT:\x1b[0m
  harness-dash         Interactive Full TUI Dashboard with key controls:
                       [↑/↓, j/k] Select   [Enter] Inspect Last Lines & Subordinates
                       [/] Live Search     [w] Open Web UI
                       [o] Export Obsidian [q] Quit

\x1b[1mOPTIONS:\x1b[0m
  -w, --watch          Live continuous interactive TUI monitor (matches tailscale-dash -w)
  --web, --server      Launch or connect to the Web Control Room dashboard server
  --port <PORT>        Port for the web dashboard server (default: 3838)
  --static             Print static one-shot terminal table (non-interactive)
  --search, -s <TEXT>  Search session titles, summaries, commands, subagents
  --harness <NAME>     Filter by harness (claude, agy, cpai, codex, omp, hermes, happy)
  --device <DEVICE>    Filter by device ID or hostname
  --export-obsidian    Export markdown session cards into Obsidian vault
  --json, -j           Output session list as JSON
  --help, -h           Show this help message

\x1b[1mCOMMANDS:\x1b[0m
  tail <SESSION_ID>    View the last lines of a session transcript
  get <SESSION_ID>     Inspect full session metadata and subordinate tree
`);
}

main().catch((err) => {
  console.error('Fatal harness-dash error:', err);
  process.exit(1);
});
