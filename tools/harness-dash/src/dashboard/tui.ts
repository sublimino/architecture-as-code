import type { DashboardMetrics, HarnessType, SearchQuery, SessionMetadata, SubordinateActivity, SummaryModelTier } from '../types';
import type { SyncStore } from '../store/sync-store';
import { SessionSummarizer } from '../summarizer/summarizer';
import { TranscriptFormatter } from '../summarizer/transcript-formatter';
import type { AppTokenMetrics } from '../summarizer/app-token-tracker';

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
      isSummarizing?: boolean;
      summarizingModelLabel?: string;
      spinnerFrame?: number;
      showHelpModal?: boolean;
      searchQuery?: string;
      termWidth?: number;
      termHeight?: number;
      scrollOffset?: number;
      statusMsg?: string;
      activeHarness?: string;
      appMetrics?: AppTokenMetrics;
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
    lines.push(this.formatKpiBar(metrics, options.appMetrics, termWidth));

    if (options.statusMsg) {
      lines.push(`${this.C_BOLD}${this.C_GREEN}✓ ${truncateVisible(options.statusMsg, termWidth - 4)}${this.C_RESET}`);
    } else if (options.searchQuery) {
      lines.push(`${this.C_YELLOW}🔍 Search: "${truncateVisible(options.searchQuery, termWidth - 20)}" (Esc to clear)${this.C_RESET}`);
    }
    lines.push('');

    // If displaying Help Cheatsheet Modal
    if (options.showHelpModal) {
      const helpLines = this.formatHelpModal(totalWidth, termHeight);
      lines.push(...helpLines);
      return { lines, totalWidth };
    }

    // If inspecting a single session in detail (Single Pane Modal)
    if (options.inspectedSession) {
      const inspectLines = this.formatInspectorModal(options.inspectedSession, totalWidth, termHeight, options);
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

  private formatter = new TranscriptFormatter();

  private formatKpiBar(metrics: DashboardMetrics, appMetrics?: AppTokenMetrics, termWidth: number = 140): string {
    const formattedTokens = metrics.totalTokens >= 1_000_000
      ? `${(metrics.totalTokens / 1_000_000).toFixed(1)}M`
      : metrics.totalTokens.toLocaleString();

    const formattedXp = metrics.totalProductivityDragonXp >= 1000
      ? `+${Math.round(metrics.totalProductivityDragonXp / 1000)}k XP`
      : `+${metrics.totalProductivityDragonXp} XP`;

    const appSpendStr = appMetrics
      ? ` | App AI Spend: ${this.C_BOLD}${this.C_YELLOW}$${appMetrics.totalCostUsd.toFixed(4)}${this.C_RESET} (${this.C_GREEN}${appMetrics.totalCalls} on-demand calls${this.C_RESET})`
      : '';

    if (termWidth >= 160) {
      return (
        `${this.C_BG_DARK}  ` +
        `Sessions: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} (${this.C_GREEN}${metrics.activeSessions} active${this.C_RESET}) | ` +
        `Devices: ${this.C_BOLD}${this.C_MAGENTA}${metrics.totalDevices}${this.C_RESET} | ` +
        `Workload: ${this.C_BOLD}${formattedTokens}${this.C_RESET} ($${metrics.totalCostUsd.toFixed(2)}) | ` +
        `Dragon XP: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET}` +
        appSpendStr + ` | ` +
        `Harnesses: ${this.C_DIM}claude:${metrics.harnessBreakdown.claude} agy:${metrics.harnessBreakdown.agy} cpai:${metrics.harnessBreakdown.cpai} codex:${metrics.harnessBreakdown.codex} omp:${metrics.harnessBreakdown.omp} hermes:${metrics.harnessBreakdown.hermes}${this.C_RESET}`
      );
    }

    if (termWidth >= 120) {
      return (
        `${this.C_BG_DARK}  ` +
        `Sessions: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} (${this.C_GREEN}${metrics.activeSessions} active${this.C_RESET}) | ` +
        `Workload: ${this.C_BOLD}${formattedTokens}${this.C_RESET} ($${metrics.totalCostUsd.toFixed(2)})` +
        appSpendStr + ` | ` +
        `XP: ${this.C_BOLD}${this.C_YELLOW}${formattedXp}${this.C_RESET}`
      );
    }

    return (
      `${this.C_BG_DARK} ` +
      `Sess: ${this.C_BOLD}${this.C_CYAN}${metrics.totalSessions}${this.C_RESET} | ` +
      `Act: ${this.C_GREEN}${metrics.activeSessions}${this.C_RESET} | ` +
      `Workload: ${this.C_BOLD}${formattedTokens}${this.C_RESET}` +
      appSpendStr
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
          const dev = session.deviceId || session.hostname || 'local';
          return pad(`${this.C_DIM}${truncateVisible(dev, col.width)}${reset}`, col.width);
        }
        case 'harness':
          return pad(this.getHarnessBadge(session.harness), col.width);
        case 'title': {
          const t = session.title || 'Untitled';
          return pad(`${this.C_BOLD}${truncateVisible(t, col.width)}${reset}`, col.width);
        }
        case 'sub': {
          const count = session.subagentCount > 0 ? session.subagentCount : (session.subordinateActivities?.length || 0);
          const val = count > 0 ? `${this.C_YELLOW}${count}s${reset}` : `${this.C_DIM}-${reset}`;
          return pad(val, col.width, 'right');
        }
        case 'summary': {
          const sum = session.summary || 'Active session';
          return pad(`${this.C_DIM}${truncateVisible(sum, col.width)}${reset}`, col.width);
        }
        case 'age': {
          const age = this.formatAge(new Date(session.lastActivityAt));
          return pad(`${this.C_DIM}${age}${reset}`, col.width);
        }
        case 'link': {
          const rawUrl = session.url || '';
          return pad(`${this.C_CYAN}${truncateVisible(rawUrl, col.width)}${reset}`, col.width);
        }
        default:
          return pad('', col.width);
      }
    });

    return `${bg}${cells.join(' ')}${reset}`;
  }

  private formatInspectorModal(
    session: SessionMetadata,
    width: number,
    termHeight: number = 40,
    options?: { isSummarizing?: boolean; summarizingModelLabel?: string; spinnerFrame?: number }
  ): string[] {
    const lines: string[] = [];
    const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    const spinner = SPINNER_FRAMES[(options?.spinnerFrame || 0) % SPINNER_FRAMES.length];

    let modelBadge: string;
    if (options?.isSummarizing) {
      modelBadge = `${this.C_BOLD}${this.C_YELLOW}${spinner} Synthesizing with ${options?.summarizingModelLabel || 'Gemini 2.5 Flash ($)'}...${this.C_RESET}`;
    } else if (session.summaryInfo) {
      modelBadge = `${this.C_BOLD}${this.C_YELLOW}✨ ${session.summaryInfo.modelLabel} (${session.summaryInfo.costTier})${session.summaryInfo.latencyMs ? ` • ${session.summaryInfo.latencyMs}ms` : ''}${session.summaryInfo.inputTokens !== undefined ? ` • ${session.summaryInfo.inputTokens} in / ${session.summaryInfo.outputTokens} out ($${session.summaryInfo.costUsd?.toFixed(6) || '0.000000'})` : ''}${this.C_RESET}`
    } else {
      modelBadge = `${this.C_DIM}Extractive Heuristic ($0.00)${this.C_RESET}`;
    }

    lines.push(`${this.C_BOLD}${this.C_CYAN}══ SESSION INSPECTOR ═════════════════════════════════════════════════════════════════${this.C_RESET}`);
    lines.push(`  ID:       ${this.C_BOLD}${session.id}${this.C_RESET} (${this.getHarnessBadge(session.harness)})`);
    lines.push(`  Title:    ${this.C_BOLD}${session.title}${this.C_RESET}`);
    lines.push(`  Status:   ${this.getStatusBadge(session.status)} | Updated: ${new Date(session.lastActivityAt).toLocaleString()}`);
    lines.push(`  CWD:      ${this.C_YELLOW}${session.cwd}${this.C_RESET}${session.gitBranch ? ` [${this.C_GREEN}branch: ${session.gitBranch}${this.C_RESET}]` : ''}`);
    lines.push(`  Link:     ${this.C_CYAN}${session.url}${this.C_RESET}`);
    lines.push(`  Tokens:   ${session.tokenUsage.inputTokens.toLocaleString()} in / ${session.tokenUsage.outputTokens.toLocaleString()} out (${this.C_GREEN}$${session.tokenUsage.totalCostUsd}${this.C_RESET})`);
    
    if (session.productivityDragon) {
      lines.push(`  Dragon:   ${this.C_MAGENTA}🐉 ${session.productivityDragon.questTitle || 'Active Quest'}${this.C_RESET} (${this.C_YELLOW}+${session.productivityDragon.xpEarned} XP${this.C_RESET})`);
    }

    lines.push('');
    lines.push(`${this.C_BOLD}AI Summary (${modelBadge}):${this.C_RESET}`);
    if (options?.isSummarizing) {
      lines.push(`  ${this.C_BOLD}${this.C_YELLOW}${spinner} Analyzing recent log snippet and synthesizing on-demand AI summary...${this.C_RESET}`);
    } else {
      lines.push(`  ${this.C_CYAN}${session.summary || 'No summary available'}${this.C_RESET}`);
    }

    if (session.subordinateActivities && session.subordinateActivities.length > 0) {
      lines.push('');
      lines.push(`${this.C_BOLD}Subordinates & Subagents (${session.subordinateActivities.length}):${this.C_RESET}`);
      for (const sub of session.subordinateActivities.slice(0, 4)) {
        lines.push(`  - [${sub.type.toUpperCase()}] ${this.C_BOLD}${sub.name}${this.C_RESET} (${sub.status}) — ${sub.summary || ''}`);
      }
    }

    lines.push('');
    lines.push(`${this.C_BOLD}Session Transcript Events (Kanban Formatted):${this.C_RESET}`);
    lines.push(this.formatDivider(width));
    
    const availableSnippetRows = Math.max(4, termHeight - lines.length - 4);
    if (session.lastLines && session.lastLines.length > 0) {
      const entries = this.formatter.parseEntries(session.lastLines);
      const ansiLines = this.formatter.formatToAnsi(entries, width - 4);
      for (const l of ansiLines.slice(-availableSnippetRows)) {
        lines.push(`  ${l}`);
      }
    } else {
      lines.push(`  ${this.C_DIM}(No transcript events recorded yet)${this.C_RESET}`);
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

  private formatHelpModal(width: number, termHeight: number = 40): string[] {
    const lines: string[] = [];
    lines.push(`${this.C_BOLD}${this.C_CYAN}══ ⚡ HARNESS-DASH HELP & CHEATSHEET [?] ═══════════════════════════════════════════${this.C_RESET}`);
    lines.push('');
    lines.push(`  ${this.C_BOLD}${this.C_YELLOW}NAVIGATION:${this.C_RESET}`);
    lines.push(`    ${this.C_BOLD}↑ / k${this.C_RESET} or ${this.C_BOLD}↓ / j${this.C_RESET}       Navigate session list up and down`);
    lines.push(`    ${this.C_BOLD}PgUp / PgDn${this.C_RESET}         Jump 10 rows up / down`);
    lines.push(`    ${this.C_BOLD}g / G${this.C_RESET}               Jump to top / bottom of session list`);
    lines.push(`    ${this.C_BOLD}Enter / i / Space${this.C_RESET}   Inspect selected session in detail (lazy-loads log)`);
    lines.push(`    ${this.C_BOLD}Esc / q${this.C_RESET}             Close modal / Clear search / Quit`);
    lines.push('');
    lines.push(`  ${this.C_BOLD}${this.C_YELLOW}SEARCH & FILTERING:${this.C_RESET}`);
    lines.push(`    ${this.C_BOLD}/${this.C_RESET}                   Interactive live search (title, goal, cwd, summary)`);
    lines.push(`    ${this.C_BOLD}Tab / h${this.C_RESET}             Cycle harness filter (All → Claude → AGY → CPAI...)`);
    lines.push(`    ${this.C_BOLD}r${this.C_RESET}                   Trigger instant background harness rescan`);
    lines.push('');
    lines.push(`  ${this.C_BOLD}${this.C_YELLOW}ON-DEMAND AI SUMMARIZATION (INSPECTOR MODAL):${this.C_RESET}`);
    lines.push(`    ${this.C_BOLD}1${this.C_RESET}                   Re-run summary with ${this.C_BOLD}Gemma 4 @ Cerebras${this.C_RESET} ($$$ • Fast ~300ms)`);
    lines.push(`    ${this.C_BOLD}2${this.C_RESET}                   Re-run summary with ${this.C_BOLD}Antigravity Pro${this.C_RESET} ($$ • Deep Analysis)`);
    lines.push(`    ${this.C_BOLD}3${this.C_RESET}                   Re-run summary with ${this.C_BOLD}Gemini 2.5 Flash${this.C_RESET} ($ • Budget ~790ms)`);
    lines.push('');
    lines.push(`  ${this.C_BOLD}${this.C_YELLOW}INTEGRATIONS & WEB:${this.C_RESET}`);
    lines.push(`    ${this.C_BOLD}w${this.C_RESET}                   Open Web Control Room in browser (http://localhost:3838)`);
    lines.push(`    ${this.C_BOLD}o${this.C_RESET}                   Export session cards to Obsidian Productivity Dragon`);
    lines.push(`    ${this.C_BOLD}?${this.C_RESET}                   Toggle this help cheatsheet popup`);
    lines.push('');
    lines.push(this.formatDivider(width));
    lines.push(`  ${this.C_BOLD}${this.C_CYAN}Token Economy:${this.C_RESET} Background scanning is 100% heuristic ($0.00). AI models run only on inspection.`);
    lines.push(`  ${this.C_DIM}[Press ?, Esc, Enter, or Space to return to dashboard]${this.C_RESET}`);

    while (lines.length < termHeight - 2) {
      lines.push('');
    }

    return lines;
  }

  private formatFooter(rangeInfo: string, termWidth: number = 140): string {
    if (termWidth < 95) {
      return `${this.C_DIM}[↑/↓] Nav  [Enter] View  [/] Search  [?] Help  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
    }
    if (termWidth < 125) {
      return `${this.C_DIM}[↑/↓, j/k] Nav  [Enter] Inspect  [/] Search  [Tab] Harness  [?] Help  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
    }
    return `${this.C_DIM}Keys: [↑/↓, j/k] Navigate  [Enter/i] Inspect  [/] Search  [Tab/h] Harness  [?] Help  [w] Web  [o] Obsidian  [q] Quit${this.C_RESET}${this.C_BOLD}${this.C_CYAN}${rangeInfo}${this.C_RESET}`;
  }

  /**
   * Interactive Full Terminal Single-Pane Application (Matching tailscale-dash)
   */
  async runInteractive(store: SyncStore, initialQuery: SearchQuery = {}): Promise<void> {
    const summarizer = new SessionSummarizer();
    let currentQuery = { ...initialQuery };
    let selectedIdx = 0;
    let scrollOffset = 0;
    let inspectedSession: SessionMetadata | null = null;
    let isSummarizing = false;
    let summarizingModelLabel = '';
    let spinnerFrame = 0;
    let spinnerInterval: ReturnType<typeof setInterval> | null = null;
    let isShowingHelp = false;
    let isSearching = false;
    let searchBuffer = currentQuery.text || '';
    let harnessIdx = 0;
    let statusMsg = '';
    let statusTimer: ReturnType<typeof setTimeout> | null = null;
    let prevBuffer: string[] = [];
    let isRunning = true;

    // Switch to alternate screen buffer & hide cursor
    process.stdout.write('\x1b[?1049h\x1b[H\x1b[?25l');

    const cleanup = () => {
      isRunning = false;
      if (statusTimer) clearTimeout(statusTimer);
      if (spinnerInterval) clearInterval(spinnerInterval);
      // Restore main screen buffer & show cursor
      process.stdout.write('\x1b[?25h\x1b[?1049l');
      if (process.stdin.isTTY) {
        try {
          process.stdin.setRawMode(false);
          process.stdin.pause();
        } catch {}
      }
    };

    const setStatus = (msg: string, durationMs: number = 3500) => {
      statusMsg = msg;
      if (statusTimer) clearTimeout(statusTimer);
      statusTimer = setTimeout(() => {
        statusMsg = '';
        renderFrame();
      }, durationMs);
      renderFrame();
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
      const appMetrics = summarizer.tokenTracker.getMetrics();

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
        isSummarizing,
        summarizingModelLabel,
        spinnerFrame,
        showHelpModal: isShowingHelp,
        searchQuery: currentQuery.text,
        termWidth,
        termHeight,
        scrollOffset,
        statusMsg,
        activeHarness: currentQuery.harness,
        appMetrics
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
      if (!isSearching && !isShowingHelp && !isSummarizing) renderFrame();
    });

    // Start background polling
    store.startBackgroundScanner(3000);
    setInterval(() => {
      if (!isSearching && !inspectedSession && !isShowingHelp && !isSummarizing) renderFrame();
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

        // Toggle / Close Help Modal
        if (key === '?') {
          isShowingHelp = !isShowingHelp;
          prevBuffer = [];
          process.stdout.write('\x1b[2J\x1b[H');
          renderFrame();
          return;
        }

        if (isShowingHelp) {
          if (key === '\u001b' || key === '\r' || key === '\n' || key === ' ' || key === 'q' || key === 'Q') {
            isShowingHelp = false;
            prevBuffer = [];
            process.stdout.write('\x1b[2J\x1b[H');
            renderFrame();
            return;
          }
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
            
            isSummarizing = true;
            summarizingModelLabel = modelLabel;
            spinnerFrame = 0;
            if (!spinnerInterval) {
              spinnerInterval = setInterval(() => {
                spinnerFrame++;
                renderFrame();
              }, 80);
            }
            setStatus(`⚡ Re-running prompt with ${modelLabel}...`, 15000);
            renderFrame();

            summarizer.summarizeWithModel(inspectedSession, modelTier, true).then(async (summaryInfo) => {
              isSummarizing = false;
              if (spinnerInterval) {
                clearInterval(spinnerInterval);
                spinnerInterval = null;
              }
              if (inspectedSession) {
                inspectedSession.summary = summaryInfo.text;
                inspectedSession.summaryInfo = summaryInfo;
                await store.saveSession(inspectedSession);
                const tokStr = summaryInfo.inputTokens !== undefined
                  ? ` • ${summaryInfo.inputTokens} in / ${summaryInfo.outputTokens} out ($${summaryInfo.costUsd?.toFixed(6)})`
                  : '';
                setStatus(`✓ Summarized with ${summaryInfo.modelLabel} (${summaryInfo.costTier}) in ${summaryInfo.latencyMs}ms${tokStr}`, 8000);
                prevBuffer = [];
                renderFrame();
              }
            }).catch((err) => {
              isSummarizing = false;
              if (spinnerInterval) {
                clearInterval(spinnerInterval);
                spinnerInterval = null;
              }
              setStatus(`⚠️ Summarization error: ${err.message}`);
              renderFrame();
            });
            return;
          }

          if (key === '\u001b' || key === '\r' || key === '\n' || key === ' ' || key === 'i') {
            inspectedSession = null;
            isSummarizing = false;
            if (spinnerInterval) {
              clearInterval(spinnerInterval);
              spinnerInterval = null;
            }
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
          // Inspect session (lazy-load full transcript on demand)
          if (sessions[selectedIdx]) {
            const targetSess = sessions[selectedIdx];
            inspectedSession = targetSess;

            // If session only has raw title or default summary, trigger on-demand AI summary with spinner
            if (!targetSess.summaryInfo || targetSess.summaryInfo.model === 'extractive') {
              isSummarizing = true;
              summarizingModelLabel = 'Gemini 2.5 Flash ($)';
              spinnerFrame = 0;
              if (!spinnerInterval) {
                spinnerInterval = setInterval(() => {
                  spinnerFrame++;
                  renderFrame();
                }, 80);
              }
            }

            store.getSessionTranscript(targetSess.id, 200).then(async (tData) => {
              if (inspectedSession && inspectedSession.id === targetSess.id) {
                inspectedSession.lastLines = tData.rawLines;

                // Synthesize summary if needed
                if (isSummarizing) {
                  try {
                    const summaryInfo = await summarizer.summarizeWithModel(inspectedSession, 'gemini-2.5-flash');
                    inspectedSession.summary = summaryInfo.text;
                    inspectedSession.summaryInfo = summaryInfo;
                    await store.saveSession(inspectedSession);
                  } catch {
                    // fallback
                  } finally {
                    isSummarizing = false;
                    if (spinnerInterval) {
                      clearInterval(spinnerInterval);
                      spinnerInterval = null;
                    }
                  }
                }

                prevBuffer = [];
                renderFrame();
              }
            }).catch(() => {
              isSummarizing = false;
              if (spinnerInterval) {
                clearInterval(spinnerInterval);
                spinnerInterval = null;
              }
            });

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
