import type { DashboardMetrics, HarnessType, SearchQuery, SessionMetadata, SubordinateActivity, SummaryModelTier } from '../types';
import type { SyncStore } from '../store/sync-store';
import { SessionSummarizer } from '../summarizer/summarizer';

// ── Text & ANSI Formatting Helpers (Matching tailscale-dash) ────────────────────

export function stripAnsi(str: string): string {
  return str.replace(/\x1b\[[0-9;]*m|\x1b\]8;;.*?\x1b\\|\x1b\]8;;.*?\x07/g, '');
}

export function charWidth(char: string): number {
  const code = char.codePointAt(0) || 0;
  if (
    code === 0x26a1 || // ⚡
    code === 0x23f3 || // ⏳
    code === 0x2705 || // ✅
    code === 0x274c || // ❌
    code === 0x231b || // ⌛
    code === 0x25cf || // ●
    code === 0x25d0 || // ◐
    code === 0x25cb || // ○
    code === 0x25b6 || // ▶
    code === 0x1f409 || // 🐉
    (code >= 0x1f300 && code <= 0x1faff) || // Emoji blocks
    (code >= 0x1100 && code <= 0x11ff) || // Hangul
    (code >= 0x2e80 && code <= 0xa4cf) || // CJK
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe10 && code <= 0xfe19) ||
    (code >= 0xfe30 && code <= 0xfe6f) ||
    (code >= 0xff00 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6)
  ) {
    return 2;
  }
  return 1;
}

export function strWidth(str: string): number {
  const clean = stripAnsi(str);
  let width = 0;
  for (const char of clean) {
    width += charWidth(char);
  }
  return width;
}

export function pad(str: string, width: number, align: 'left' | 'right' = 'left'): string {
  const w = strWidth(str);
  const padding = ' '.repeat(Math.max(0, width - w));
  return align === 'left' ? str + padding : padding + str;
}

export function truncateVisible(str: string, maxLen: number): string {
  const clean = stripAnsi(str);
  if (strWidth(clean) <= maxLen) return str;
  let cur = '';
  let curWidth = 0;
  for (const char of clean) {
    const w = charWidth(char);
    if (curWidth + w > maxLen - 1) break;
    cur += char;
    curWidth += w;
  }
  return cur + '…';
}

// ── Column Definition ──────────────────────────────────────────────────────────

interface ColumnSpec {
  id: string;
  header: string;
  width: number;
}

const HARNESS_LIST: (HarnessType | '')[] = ['', 'claude', 'agy', 'cpai', 'codex', 'omp', 'hermes', 'happy'];

interface ColumnSpecInternal {
  id: string;
  header: string;
  minWidth: number;
  baseWidth: number;
  maxWidth: number;
  weight: number;
  hideAtWidth?: number;
}

export class TuiDashboardRenderer {
  // ANSI Color codes
  private readonly C_RESET = '\x1b[0m';
  private readonly C_BOLD = '\x1b[1m';
  private readonly C_DIM = '\x1b[2m';
  private readonly C_CYAN = '\x1b[36m';
  private readonly C_GREEN = '\x1b[32m';
  private readonly C_YELLOW = '\x1b[33m';
  private readonly C_BLUE = '\x1b[34m';
  private readonly C_MAGENTA = '\x1b[35m';
  private readonly C_RED = '\x1b[31m';
  private readonly C_BG_DARK = '\x1b[48;5;235m';
  private readonly C_BG_SELECT = '\x1b[48;5;238m';

  public computeColumns(termWidth: number, isWide: boolean = true): ColumnSpec[] {
    const specs: ColumnSpecInternal[] = [
      { id: 'cursor', header: '  ', minWidth: 2, baseWidth: 2, maxWidth: 2, weight: 0 },
      { id: 'status', header: 'STATUS', minWidth: 9, baseWidth: 9, maxWidth: 9, weight: 0 },
      { id: 'device', header: 'DEVICE', minWidth: 8, baseWidth: 12, maxWidth: 14, weight: 1, hideAtWidth: 110 },
      { id: 'harness', header: 'HARNESS', minWidth: 7, baseWidth: 8, maxWidth: 8, weight: 0 },
      { id: 'title', header: 'TITLE / GOAL', minWidth: 20, baseWidth: 32, maxWidth: 48, weight: 4 },
      { id: 'sub', header: 'SUB', minWidth: 4, baseWidth: 4, maxWidth: 4, weight: 0 },
      { id: 'summary', header: 'LAST ACTION / SUMMARY', minWidth: 18, baseWidth: 26, maxWidth: 44, weight: 3, hideAtWidth: 85 },
      { id: 'age', header: 'AGE', minWidth: 7, baseWidth: 8, maxWidth: 8, weight: 0 },
      { id: 'link', header: 'LINK', minWidth: 18, baseWidth: 24, maxWidth: 36, weight: 3, hideAtWidth: 125 }
    ];

    // Filter columns based on terminal width
    const visible = specs.filter((c) => !c.hideAtWidth || termWidth >= c.hideAtWidth);
    const gaps = visible.length - 1;
    // Leave 2 columns safety buffer at terminal edge to strictly prevent emulator line wrap
    const availWidth = Math.max(termWidth - gaps - 2, 35);

    const baseTotal = visible.reduce((sum, c) => sum + c.baseWidth, 0);
    const minTotal = visible.reduce((sum, c) => sum + c.minWidth, 0);
    const maxTotal = visible.reduce((sum, c) => sum + c.maxWidth, 0);

    const widths = new Map<string, number>();

    if (availWidth <= minTotal) {
      for (const c of visible) widths.set(c.id, c.minWidth);
    } else if (availWidth <= baseTotal) {
      // Compress smoothly between min and base
      const factor = (availWidth - minTotal) / (baseTotal - minTotal || 1);
      for (const c of visible) {
        const w = Math.round(c.minWidth + (c.baseWidth - c.minWidth) * factor);
        widths.set(c.id, w);
      }
    } else {
      // Base width + distribute extra proportionally according to weights
      for (const c of visible) widths.set(c.id, c.baseWidth);
      const extra = Math.min(availWidth - baseTotal, maxTotal - baseTotal);
      const totalWeight = visible.reduce((sum, c) => sum + (c.maxWidth > c.baseWidth ? c.weight : 0), 0);

      if (totalWeight > 0 && extra > 0) {
        let allocatedExtra = 0;
        for (const c of visible) {
          if (c.maxWidth > c.baseWidth) {
            const share = Math.floor((c.weight / totalWeight) * extra);
            const newW = Math.min(c.baseWidth + share, c.maxWidth);
            widths.set(c.id, newW);
            allocatedExtra += (newW - c.baseWidth);
          }
        }
        // Distribute any remainder to title column
        const remainder = extra - allocatedExtra;
        if (remainder > 0 && widths.has('title')) {
          widths.set('title', (widths.get('title') || 32) + remainder);
        }
      }
    }

    return visible.map((c) => ({
      id: c.id,
      header: c.header,
      width: widths.get(c.id) || c.baseWidth
    }));
  }

  /**
   * Static render for pipe or single-shot display
   */
  render(
    sessions: SessionMetadata[],
    metrics: DashboardMetrics,
    options: {
      wide?: boolean;
      showSubordinates?: boolean;
      selectedIndex?: number;
      inspectedSession?: SessionMetadata | null;
      searchQuery?: string;
      termWidth?: number;
      termHeight?: number;
      scrollOffset?: number;
      statusMsg?: string;
      activeHarness?: string;
    } = {}
  ): { lines: string[]; totalWidth: number } {
    const lines: string[] = [];
    const termWidth = options.termWidth || (process.stdout.columns || 140);
    const termHeight = options.termHeight || (process.stdout.rows || 24);
    const isWide = options.wide ?? termWidth >= 120;
    const selectedIdx = options.selectedIndex ?? -1;
    const cols = this.computeColumns(termWidth, isWide);
    const totalWidth = cols.reduce((sum, c) => sum + c.width, 0) + (cols.length - 1);

    // Header Banner
    lines.push(this.formatBanner(metrics, options.activeHarness, termWidth));

    // Summary KPI Bar
    lines.push(this.formatKpiBar(metrics, termWidth));

    if (options.statusMsg) {
      lines.push(`${this.C_BOLD}${this.C_GREEN}✓ ${truncateVisible(options.statusMsg, termWidth - 4)}${this.C_RESET}`);
    } else if (options.searchQuery) {
      lines.push(`${this.C_YELLOW}🔍 Search: "${truncateVisible(options.searchQuery, termWidth - 20)}" (Esc to clear)${this.C_RESET}`);
    }
    lines.push('');

    // If inspecting a single session in detail (Single Pane Modal)
    if (options.inspectedSession) {
      const inspectLines = this.formatInspector(options.inspectedSession, totalWidth, termHeight);
      lines.push(...inspectLines);
      return { lines, totalWidth };
    }

    // Table Header
    const headerCells = cols.map((c) => pad(`${this.C_BOLD}${c.header}${this.C_RESET}`, c.width));
    lines.push(headerCells.join(' '));
    lines.push(this.formatDivider(totalWidth, termWidth));

    // Vertical Viewport Slicing for Single-Pane Finesse
    const maxVisibleRows = Math.max(4, termHeight - lines.length - 3);
    const scrollOffset = options.scrollOffset || 0;
    const visibleSessions = sessions.slice(scrollOffset, scrollOffset + maxVisibleRows);

    if (sessions.length === 0) {
      lines.push(`${this.C_DIM}  (No active or recorded AI sessions match current criteria)${this.C_RESET}`);
    } else {
      for (let i = 0; i < visibleSessions.length; i++) {
        const actualIdx = scrollOffset + i;
        const session = visibleSessions[i];
        const isSelected = actualIdx === selectedIdx;
        lines.push(this.formatSessionRow(session, cols, isSelected));
      }
    }

    // Pad empty rows to maintain stable height
    while (lines.length < termHeight - 2) {
      lines.push('');
    }

    lines.push(this.formatDivider(totalWidth, termWidth));
    const rangeInfo = sessions.length > 0 ? ` [${Math.min(sessions.length, scrollOffset + 1)}-${Math.min(sessions.length, scrollOffset + maxVisibleRows)} of ${sessions.length}]` : '';
    lines.push(this.formatFooter(rangeInfo, termWidth));

    return { lines, totalWidth };
  }

  private formatBanner(metrics: DashboardMetrics, activeHarness?: string, termWidth: number = 140): string {
    const harnessTag = activeHarness ? ` ${this.C_MAGENTA}[Filter: ${activeHarness.toUpperCase()}]${this.C_RESET}` : '';
    if (termWidth < 70) {
      return `${this.C_BOLD}${this.C_CYAN}⚡ HARNESS-DASH${this.C_RESET} ${this.C_GREEN}[ONLINE]${this.C_RESET}${harnessTag}`;
    }
    return `${this.C_BOLD}${this.C_CYAN}⚡ HARNESS-DASH${this.C_RESET} ${this.C_DIM}— Universal AI Control Room${this.C_RESET} ${this.C_GREEN}[ONLINE]${this.C_RESET}${harnessTag}`;
  }

  private formatKpiBar(metrics: DashboardMetrics, termWidth: number = 140): string {
    const formattedTokens = metrics.totalTokens >= 1_000_000
      ? `${(metrics.totalTokens / 1_000_000).toFixed(1)}M`
      : metrics.totalTokens.toLocaleString();

    const formattedXp = metrics.totalProductivityDragonXp >= 1000
      ? `+${Math.round(metrics.totalProductivityDragonXp / 1000)}k XP`
      : `+${metrics.totalProductivityDragonXp} XP`;

    if (termWidth >= 160) {
      return (
        `${this.C_BG_DARK}  ` +
        `Sessions: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} (${this.C_GREEN}${metrics.activeSessions} active${this.C_RESET}) | ` +
        `Devices: ${this.C_BOLD}${this.C_MAGENTA}${metrics.totalDevices}${this.C_RESET} | ` +
        `Tokens: ${this.C_BOLD}${formattedTokens}${this.C_RESET} ($${metrics.totalCostUsd.toFixed(2)}) | ` +
        `Dragon XP: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET} | ` +
        `Harnesses: ${this.C_DIM}claude:${metrics.harnessBreakdown.claude} agy:${metrics.harnessBreakdown.agy} cpai:${metrics.harnessBreakdown.cpai} codex:${metrics.harnessBreakdown.codex} omp:${metrics.harnessBreakdown.omp} hermes:${metrics.harnessBreakdown.hermes}${this.C_RESET}`
      );
    }

    if (termWidth >= 120) {
      return (
        `${this.C_BG_DARK}  ` +
        `Sessions: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} (${this.C_GREEN}${metrics.activeSessions} active${this.C_RESET}) | ` +
        `Devices: ${this.C_BOLD}${this.C_MAGENTA}${metrics.totalDevices}${this.C_RESET} | ` +
        `Tokens: ${this.C_BOLD}${formattedTokens}${this.C_RESET} ($${metrics.totalCostUsd.toFixed(2)}) | ` +
        `Dragon XP: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET} | ` +
        `${this.C_DIM}cl:${metrics.harnessBreakdown.claude} agy:${metrics.harnessBreakdown.agy} cp:${metrics.harnessBreakdown.cpai}${this.C_RESET}`
      );
    }

    if (termWidth >= 95) {
      return (
        `${this.C_BG_DARK}  ` +
        `Sessions: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} (${this.C_GREEN}${metrics.activeSessions} act${this.C_RESET}) | ` +
        `Devices: ${this.C_BOLD}${this.C_MAGENTA}${metrics.totalDevices}${this.C_RESET} | ` +
        `Tokens: ${this.C_BOLD}${formattedTokens}${this.C_RESET} ($${metrics.totalCostUsd.toFixed(2)}) | ` +
        `Dragon: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET}`
      );
    }

    return (
      `${this.C_BG_DARK} ` +
      `Sess: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} | ` +
      `Act: ${this.C_GREEN}${metrics.activeSessions}${this.C_RESET} | ` +
      `Tokens: ${this.C_BOLD}${formattedTokens}${this.C_RESET} | ` +
      `XP: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET}`
    );
  }

  private formatDivider(width: number, termWidth: number = 140): string {
    const len = Math.min(width, termWidth - 1);
    return `${this.C_DIM}${'-'.repeat(Math.max(40, len))}${this.C_RESET}`;
  }

  private formatSessionRow(session: SessionMetadata, cols: ColumnSpec[], isSelected: boolean = false): string {
    const bg = isSelected ? this.C_BG_SELECT : '';
    const reset = this.C_RESET;

    const cells = cols.map((col) => {
      switch (col.id) {
        case 'cursor':
          return isSelected ? `${this.C_BOLD}${this.C_CYAN}▶ ${reset}` : '  ';
        case 'status':
          return pad(this.getStatusBadge(session.status), col.width);
        case 'device': {
          const dev = truncateVisible(session.deviceId || session.hostname || 'local', col.width);
          return pad(`${this.C_DIM}${dev}${reset}`, col.width);
        }
        case 'harness':
          return pad(this.getHarnessBadge(session.harness), col.width);
        case 'title': {
          const clean = truncateVisible(session.title, col.width);
          return pad(`${this.C_BOLD}${clean}${reset}`, col.width);
        }
        case 'sub': {
          const count = session.subagentCount > 0 ? `${this.C_YELLOW}${session.subagentCount}s${reset}` : `${this.C_DIM}-${reset}`;
          return pad(count, col.width, 'right');
        }
        case 'summary': {
          const sum = truncateVisible(session.summary || 'Active session', col.width);
          return pad(`${this.C_DIM}${sum}${reset}`, col.width);
        }
        case 'age': {
          const age = this.formatAge(new Date(session.lastActivityAt));
          return pad(`${this.C_DIM}${age}${reset}`, col.width);
        }
        case 'link': {
          const rawLink = truncateVisible(session.url, col.width);
          return pad(`${this.C_CYAN}${rawLink}${reset}`, col.width);
        }
        default:
          return pad('', col.width);
      }
    });

    return `${bg}${cells.join(' ')}${reset}`;
  }

  private formatInspector(session: SessionMetadata, width: number, termHeight: number): string[] {
    const lines: string[] = [];
    lines.push(`${this.C_BOLD}${this.C_CYAN}═══ SESSION INSPECTOR: ${session.title} (${session.id}) ═══${this.C_RESET}`);
    lines.push(`  • ${this.C_BOLD}Harness:${this.C_RESET} ${session.harness.toUpperCase()} | ${this.C_BOLD}Status:${this.C_RESET} ${session.status.toUpperCase()} | ${this.C_BOLD}Device:${this.C_RESET} ${session.deviceId} (${session.hostname})`);
    lines.push(`  • ${this.C_BOLD}Directory:${this.C_RESET} ${session.cwd} ${session.gitBranch ? `(git: ${session.gitBranch})` : ''}`);
    lines.push(`  • ${this.C_BOLD}Tokens:${this.C_RESET} ${session.tokenUsage.inputTokens.toLocaleString()} in / ${session.tokenUsage.outputTokens.toLocaleString()} out ($${session.tokenUsage.totalCostUsd})`);
    lines.push(`  • ${this.C_BOLD}Deep Link:${this.C_RESET} ${this.C_CYAN}${session.url}${this.C_RESET}`);

    if (session.titleHistory && session.titleHistory.length > 1) {
      lines.push(`  • ${this.C_BOLD}Title Evolution:${this.C_RESET} ${session.titleHistory.join(' → ')}`);
    }

    if (session.productivityDragon) {
      lines.push(`  • ${this.C_BOLD}🐉 Productivity Dragon:${this.C_RESET} [[${session.productivityDragon.questTitle}]] (+${session.productivityDragon.xpEarned} XP)`);
    }

    const modelBadge = session.summaryInfo
      ? ` [Model: ${session.summaryInfo.modelLabel} (${session.summaryInfo.costTier})${session.summaryInfo.latencyMs ? ` • ${session.summaryInfo.latencyMs}ms` : ''}]`
      : ' [Model: Gemini 2.5 Flash ($)]';

    lines.push('');
    lines.push(`${this.C_BOLD}AI Summary${this.C_CYAN}${modelBadge}${this.C_RESET}:`);
    lines.push(`  ${this.C_YELLOW}${session.summary || 'No summary generated'}${this.C_RESET}`);

    if (session.subordinateActivities && session.subordinateActivities.length > 0) {
      lines.push('');
      lines.push(`${this.C_BOLD}Subordinates & Subagents (${session.subordinateActivities.length}):${this.C_RESET}`);
      for (const sub of session.subordinateActivities.slice(0, 4)) {
        lines.push(`  - [${sub.type.toUpperCase()}] ${this.C_BOLD}${sub.name}${this.C_RESET} (${sub.status}) — ${sub.summary || ''}`);
      }
    }

    lines.push('');
    lines.push(`${this.C_BOLD}Last Transcript Snippet:${this.C_RESET}`);
    lines.push(this.formatDivider(width));
    
    const availableSnippetRows = Math.max(3, termHeight - lines.length - 4);
    if (session.lastLines && session.lastLines.length > 0) {
      for (const l of session.lastLines.slice(-availableSnippetRows)) {
        lines.push(`  ${this.C_DIM}${truncateVisible(l, width - 4)}${this.C_RESET}`);
      }
    } else {
      lines.push(`  ${this.C_DIM}(No transcript snippet available)${this.C_RESET}`);
    }

    while (lines.length < termHeight - 2) {
      lines.push('');
    }

    lines.push(this.formatDivider(width));
    lines.push(`${this.C_BOLD}${this.C_MAGENTA}Re-run Prompt:${this.C_RESET} [1] Gemma 4 @ Cerebras ($$$)  [2] Antigravity ($$)  [3] Gemini 2.5 ($)  |  ${this.C_DIM}[Esc/Enter] Back${this.C_RESET}`);
    return lines;
  }

  private getStatusBadge(status: string): string {
    switch (status) {
      case 'running':
        return `${this.C_GREEN}● ACTIVE${this.C_RESET}`;
      case 'idle':
        return `${this.C_YELLOW}◐ IDLE${this.C_RESET}`;
      case 'failed':
        return `${this.C_RED}✖ FAILED${this.C_RESET}`;
      default:
        return `${this.C_DIM}○ DONE${this.C_RESET}`;
    }
  }

  private getHarnessBadge(harness: string): string {
    switch (harness) {
      case 'claude':
        return `${this.C_YELLOW}Claude${this.C_RESET}`;
      case 'agy':
        return `${this.C_BLUE}AGY${this.C_RESET}`;
      case 'cpai':
        return `${this.C_CYAN}CPAI${this.C_RESET}`;
      case 'codex':
        return `${this.C_GREEN}Codex${this.C_RESET}`;
      case 'omp':
        return `${this.C_MAGENTA}OMP${this.C_RESET}`;
      case 'hermes':
        return `${this.C_RED}Hermes${this.C_RESET}`;
      case 'happy':
        return `${this.C_CYAN}Happy${this.C_RESET}`;
      default:
        return `${this.C_DIM}Custom${this.C_RESET}`;
    }
  }

  private formatAge(date: Date): string {
    const diffSec = Math.floor((Date.now() - date.getTime()) / 1000);
    if (diffSec < 60) return `${diffSec}s ago`;
    const diffMin = Math.floor(diffSec / 60);
    if (diffMin < 60) return `${diffMin}m ago`;
    const diffHr = Math.floor(diffMin / 60);
    if (diffHr < 24) return `${diffHr}h ago`;
    const diffDays = Math.floor(diffHr / 24);
    return `${diffDays}d ago`;
  }

  private formatFooter(rangeInfo: string, termWidth: number = 140): string {
    if (termWidth < 95) {
      return `${this.C_DIM}[↑/↓] Nav  [Enter] View  [/] Search  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
    }
    if (termWidth < 125) {
      return `${this.C_DIM}[↑/↓, j/k] Nav  [Enter] Inspect  [/] Search  [Tab] Harness  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
    }
    return `${this.C_DIM}Keys: [↑/↓, j/k] Navigate  [Enter/i] Inspect  [/] Search  [Tab/h] Harness  [w] Web  [o] Obsidian  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
  }

  /**
   * Interactive Full Terminal Single-Pane Application (Matching tailscale-dash)
   */
  async runInteractive(store: SyncStore, initialQuery: SearchQuery = {}): Promise<void> {
    let currentQuery = { ...initialQuery };
    let selectedIdx = 0;
    let scrollOffset = 0;
    let inspectedSession: SessionMetadata | null = null;
    let isSearching = false;
    let searchBuffer = currentQuery.text || '';
    let harnessIdx = 0;
    let statusMsg = '';
    let statusTimer: ReturnType<typeof setTimeout> | null = null;
    let prevBuffer: string[] = [];
    let isRunning = true;

    // Switch to alternate screen buffer & hide cursor
    process.stdout.write('\x1b[?1049h\x1b[H\x1b[?25l');

    const setStatus = (msg: string, durationMs = 3000) => {
      statusMsg = msg;
      if (statusTimer) clearTimeout(statusTimer);
      renderFrame();
      statusTimer = setTimeout(() => {
        statusMsg = '';
        renderFrame();
      }, durationMs);
    };

    const cleanup = () => {
      if (!isRunning) return;
      isRunning = false;
      if (statusTimer) clearTimeout(statusTimer);
      store.stopBackgroundScanner();
      // Restore normal screen buffer & show cursor
      process.stdout.write('\x1b[?1049l\x1b[?25h');
      if (process.stdin.isTTY) {
        try {
          process.stdin.setRawMode(false);
        } catch {}
        process.stdin.pause();
      }
    };

    process.on('SIGINT', () => { cleanup(); process.exit(0); });
    process.on('SIGTERM', () => { cleanup(); process.exit(0); });
    process.on('exit', () => cleanup());

    const renderFrame = () => {
      if (!isRunning) return;

      const termWidth = process.stdout.columns || 140;
      const termHeight = process.stdout.rows || 24;
      const sessions = store.listSessions(currentQuery);
      const metrics = store.getMetrics();

      if (selectedIdx >= sessions.length) {
        selectedIdx = Math.max(0, sessions.length - 1);
      }

      const maxVisibleRows = Math.max(4, termHeight - 8);
      // Auto-adjust scroll offset to keep selected row in viewport
      if (selectedIdx < scrollOffset) {
        scrollOffset = selectedIdx;
      } else if (selectedIdx >= scrollOffset + maxVisibleRows) {
        scrollOffset = selectedIdx - maxVisibleRows + 1;
      }

      const result = this.render(sessions, metrics, {
        selectedIndex: selectedIdx,
        inspectedSession,
        searchQuery: currentQuery.text,
        termWidth,
        termHeight,
        scrollOffset,
        statusMsg,
        activeHarness: currentQuery.harness
      });

      const nextLines = result.lines;
      let output = '';

      // Differential screen rendering (zero flicker)
      for (let i = 0; i < Math.min(nextLines.length, termHeight); i++) {
        if (prevBuffer[i] !== nextLines[i]) {
          output += `\x1b[${i + 1};1H${nextLines[i]}\x1b[K`;
        }
      }

      // Clear any remaining lines
      for (let i = nextLines.length; i < prevBuffer.length && i < termHeight; i++) {
        output += `\x1b[${i + 1};1H\x1b[K`;
      }

      if (isSearching) {
        const searchRow = Math.min(3, termHeight);
        output += `\x1b[${searchRow};1H\x1b[1m\x1b[33mSearch > \x1b[0m${searchBuffer}\x1b[5m_\x1b[0m\x1b[K`;
      }

      if (output.length > 0) {
        process.stdout.write(output);
      }

      prevBuffer = [...nextLines];
    };

    // Resize listener
    process.stdout.on('resize', () => {
      prevBuffer = [];
      process.stdout.write('\x1b[2J\x1b[H');
      renderFrame();
    });

    // Listen for background updates
    store.onSessionUpdate(() => {
      if (!isSearching) renderFrame();
    });

    // Start background polling
    store.startBackgroundScanner(3000);
    setInterval(() => {
      if (!isSearching && !inspectedSession) renderFrame();
    }, 2000);

    // Setup raw keyboard input
    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
      process.stdin.resume();
      process.stdin.setEncoding('utf-8');

      process.stdin.on('data', (key: string) => {
        if (isSearching) {
          if (key === '\r' || key === '\n') {
            isSearching = false;
            currentQuery.text = searchBuffer;
            selectedIdx = 0;
            scrollOffset = 0;
            prevBuffer = [];
            renderFrame();
          } else if (key === '\u001b' || key === '\u0003') {
            isSearching = false;
            searchBuffer = '';
            currentQuery.text = undefined;
            prevBuffer = [];
            renderFrame();
          } else if (key === '\u007f' || key === '\b') {
            searchBuffer = searchBuffer.slice(0, -1);
            currentQuery.text = searchBuffer || undefined;
            renderFrame();
          } else if (key.length === 1 && key >= ' ') {
            searchBuffer += key;
            currentQuery.text = searchBuffer;
            renderFrame();
          }
          return;
        }

        // Ctrl+C or q to exit
        if (key === '\u0003' || key === 'q' || key === 'Q') {
          cleanup();
          process.exit(0);
        }

        // Inspector mode keys
        if (inspectedSession) {
          if (key === '1' || key === '2' || key === '3') {
            const modelTier: SummaryModelTier = key === '1' ? 'gemma-4-cerebras' : key === '2' ? 'antigravity' : 'gemini-2.5-flash';
            const modelLabel = key === '1' ? 'Gemma 4 @ Cerebras ($$$ • Ultra Fast)' : key === '2' ? 'Antigravity ($$ • Deep Analysis)' : 'Gemini 2.5 Flash ($ • Budget)';
            setStatus(`⚡ Re-running prompt with ${modelLabel}...`, 10000);
            const summarizer = new SessionSummarizer();
            summarizer.summarizeWithModel(inspectedSession, modelTier).then(async (summaryInfo) => {
              if (inspectedSession) {
                inspectedSession.summary = summaryInfo.text;
                inspectedSession.summaryInfo = summaryInfo;
                await store.saveSession(inspectedSession);
                setStatus(`✓ Summarized with ${summaryInfo.modelLabel} (${summaryInfo.costTier}) in ${summaryInfo.latencyMs}ms`);
                prevBuffer = [];
                renderFrame();
              }
            }).catch((err) => {
              setStatus(`⚠️ Summarization error: ${err.message}`);
            });
            return;
          }

          if (key === '\u001b' || key === '\r' || key === '\n' || key === ' ' || key === 'i') {
            inspectedSession = null;
            prevBuffer = [];
            process.stdout.write('\x1b[2J\x1b[H');
            renderFrame();
            return;
          }
        }

        const sessions = store.listSessions(currentQuery);

        // Navigation
        if (key === '\u001b[A' || key === 'k' || key === 'K') {
          // Up
          selectedIdx = Math.max(0, selectedIdx - 1);
          renderFrame();
        } else if (key === '\u001b[B' || key === 'j' || key === 'J') {
          // Down
          selectedIdx = Math.min(Math.max(0, sessions.length - 1), selectedIdx + 1);
          renderFrame();
        } else if (key === '\u001b[5~' || key === '\u0002') {
          // Page Up
          selectedIdx = Math.max(0, selectedIdx - 10);
          renderFrame();
        } else if (key === '\u001b[6~' || key === '\u0006') {
          // Page Down
          selectedIdx = Math.min(Math.max(0, sessions.length - 1), selectedIdx + 10);
          renderFrame();
        } else if (key === 'g') {
          // Top
          selectedIdx = 0;
          renderFrame();
        } else if (key === 'G') {
          // Bottom
          selectedIdx = Math.max(0, sessions.length - 1);
          renderFrame();
        } else if (key === '\r' || key === '\n' || key === ' ' || key === 'i') {
          // Inspect session
          if (sessions[selectedIdx]) {
            inspectedSession = sessions[selectedIdx];
            prevBuffer = [];
            process.stdout.write('\x1b[2J\x1b[H');
            renderFrame();
          }
        } else if (key === '/') {
          // Search
          isSearching = true;
          searchBuffer = '';
          renderFrame();
        } else if (key === '\t' || key === 'h') {
          // Cycle harness filter
          harnessIdx = (harnessIdx + 1) % HARNESS_LIST.length;
          currentQuery.harness = HARNESS_LIST[harnessIdx] || undefined;
          selectedIdx = 0;
          scrollOffset = 0;
          prevBuffer = [];
          renderFrame();
        } else if (key === '\u001b') {
          // Esc: clear filter
          currentQuery.text = undefined;
          currentQuery.harness = undefined;
          searchBuffer = '';
          inspectedSession = null;
          prevBuffer = [];
          renderFrame();
        } else if (key === 'r') {
          setStatus('Refreshing sessions across all harnesses...');
          store.scanLocalHarnesses().then((n) => {
            setStatus(`Scan complete: indexed ${n} sessions`, 2500);
          });
        } else if (key === 'o') {
          store.exportToObsidian().then((files) => {
            setStatus(`Exported ${files.length} cards to Obsidian Productivity Dragon!`, 3000);
          });
        } else if (key === 'w') {
          const preferredUrl = 'http://localhost:3838';
          try {
            Bun.spawn(['xdg-open', preferredUrl], { stdout: 'ignore', stderr: 'ignore' });
            setStatus(`Opened Web Control Room at ${preferredUrl}`, 2500);
          } catch {
            setStatus(`Web UI running at ${preferredUrl}`, 2500);
          }
        }
      });
    }

    renderFrame();
  }
}
