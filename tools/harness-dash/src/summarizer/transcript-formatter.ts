export interface TranscriptEntry {
  index: number;
  timestamp?: string;
  role: 'user' | 'assistant' | 'tool_call' | 'tool_result' | 'system' | 'error';
  title: string;
  content: string;
  toolName?: string;
  toolArgs?: Record<string, any> | string;
  toolResult?: string;
  status?: 'success' | 'error' | 'pending';
  rawJson?: string;
}

export class TranscriptFormatter {
  /**
   * Parses raw log lines (JSONL or plain text) into structured, typed transcript entries
   */
  parseEntries(rawLines: string[]): TranscriptEntry[] {
    const entries: TranscriptEntry[] = [];
    let entryIdx = 0;

    for (const rawLine of rawLines) {
      const line = rawLine.trim();
      if (!line) continue;

      try {
        const obj = JSON.parse(line);
        entryIdx++;

        // 1. Antigravity format (type: USER_INPUT, PLANNER_RESPONSE, GENERIC, tool_calls)
        if (obj.type === 'USER_INPUT' || obj.source === 'USER_EXPLICIT') {
          entries.push({
            index: entryIdx,
            timestamp: obj.created_at,
            role: 'user',
            title: 'User Prompt',
            content: typeof obj.content === 'string' ? obj.content : JSON.stringify(obj.content, null, 2),
            rawJson: line
          });
          continue;
        }

        if (obj.tool_calls && Array.isArray(obj.tool_calls)) {
          for (const call of obj.tool_calls) {
            const toolName = call.name || 'tool';
            const args = call.arguments || call.args || {};
            const target = args.TargetFile || args.CommandLine || args.AbsolutePath || args.toolSummary || args.Query || args.SearchDirectory || args.target_file || args.path || args.command || '';
            const cleanTarget = typeof target === 'string' ? target.replace(/^["']|["']$/g, '') : '';
            entries.push({
              index: entryIdx,
              timestamp: obj.created_at,
              role: 'tool_call',
              title: `Tool Call: ${toolName}`,
              toolName,
              toolArgs: args,
              content: cleanTarget || JSON.stringify(args, null, 2),
              rawJson: line
            });
          }
        }

        if (obj.type === 'PLANNER_RESPONSE') {
          const text = obj.content || obj.thinking || '';
          if (text) {
            entries.push({
              index: entryIdx,
              timestamp: obj.created_at,
              role: 'assistant',
              title: 'Assistant Response',
              content: text,
              rawJson: line
            });
          }
          continue;
        }

        // 2. Claude Code format (type: tool_use, tool_result, user, assistant)
        if (obj.type === 'tool_use') {
          const toolName = obj.name || 'tool';
          const input = obj.input || {};
          const target = input.target_file || input.path || input.command || input.pattern || '';
          entries.push({
            index: entryIdx,
            timestamp: obj.timestamp,
            role: 'tool_call',
            title: `Tool Call: ${toolName}`,
            toolName,
            toolArgs: input,
            content: target ? String(target) : JSON.stringify(input, null, 2),
            rawJson: line
          });
          continue;
        }

        if (obj.type === 'tool_result') {
          entries.push({
            index: entryIdx,
            timestamp: obj.timestamp,
            role: 'tool_result',
            title: `Tool Result: ${obj.tool_use_id || 'Output'}`,
            content: typeof obj.content === 'string' ? obj.content : JSON.stringify(obj.content, null, 2),
            status: obj.is_error ? 'error' : 'success',
            rawJson: line
          });
          continue;
        }

        if (obj.role === 'user') {
          entries.push({
            index: entryIdx,
            timestamp: obj.timestamp,
            role: 'user',
            title: 'User Instruction',
            content: typeof obj.content === 'string' ? obj.content : JSON.stringify(obj.content, null, 2),
            rawJson: line
          });
          continue;
        }

        if (obj.role === 'assistant') {
          entries.push({
            index: entryIdx,
            timestamp: obj.timestamp,
            role: 'assistant',
            title: 'Assistant Thought / Reply',
            content: typeof obj.content === 'string' ? obj.content : JSON.stringify(obj.content, null, 2),
            rawJson: line
          });
          continue;
        }

        if (obj.error || obj.status === 'ERROR') {
          entries.push({
            index: entryIdx,
            timestamp: obj.created_at || obj.timestamp,
            role: 'error',
            title: 'System Error',
            content: obj.error?.message || obj.message || JSON.stringify(obj, null, 2),
            status: 'error',
            rawJson: line
          });
          continue;
        }

        // Generic JSON fallback
        entries.push({
          index: entryIdx,
          timestamp: obj.created_at || obj.timestamp,
          role: obj.type === 'GENERIC' ? 'tool_result' : 'assistant',
          title: obj.type || 'Event',
          content: obj.content ? String(obj.content) : JSON.stringify(obj, null, 2),
          rawJson: line
        });
      } catch {
        // Plain text lines (e.g. bash commands or log output)
        entryIdx++;
        const isError = line.toLowerCase().includes('error:') || line.toLowerCase().includes('failed:');
        const isCmd = line.startsWith('$ ') || line.startsWith('Running ') || line.startsWith('bun ') || line.startsWith('make ');

        entries.push({
          index: entryIdx,
          role: isError ? 'error' : isCmd ? 'tool_call' : 'system',
          title: isError ? 'Error Output' : isCmd ? 'Shell Command' : 'Log Output',
          content: line,
          status: isError ? 'error' : 'success',
          rawJson: line
        });
      }
    }

    return entries;
  }

  /**
   * Formats entries into human-readable HTML kanban stream
   */
  formatToHtml(entries: TranscriptEntry[]): string {
    if (entries.length === 0) {
      return '<div class="p-6 text-center text-xs text-slate-500 glass-card rounded-xl font-mono">No transcript events recorded yet.</div>';
    }

    const cards = entries.map((entry) => {
      switch (entry.role) {
        case 'user':
          return `
            <div class="p-4 rounded-xl bg-blue-950/40 border border-blue-800/60 text-xs shadow-sm transition hover:border-blue-700">
              <div class="flex items-center justify-between gap-2 mb-2">
                <span class="font-bold text-blue-300 flex items-center gap-1.5 font-mono text-[11px]">
                  👤 USER INSTRUCTION #${entry.index}
                </span>
                ${entry.timestamp ? `<span class="text-[10px] text-slate-500 font-mono">${new Date(entry.timestamp).toLocaleTimeString()}</span>` : ''}
              </div>
              <div class="text-slate-100 whitespace-pre-wrap leading-relaxed font-sans select-text">${this.escapeHtml(entry.content)}</div>
            </div>
          `;

        case 'assistant':
          return `
            <div class="p-4 rounded-xl bg-slate-900/90 border border-slate-800 text-xs shadow-sm transition hover:border-slate-700">
              <div class="flex items-center justify-between gap-2 mb-2">
                <span class="font-bold text-teal-300 flex items-center gap-1.5 font-mono text-[11px]">
                  🤖 ASSISTANT RESPONSE #${entry.index}
                </span>
                ${entry.timestamp ? `<span class="text-[10px] text-slate-500 font-mono">${new Date(entry.timestamp).toLocaleTimeString()}</span>` : ''}
              </div>
              <div class="text-slate-200 whitespace-pre-wrap leading-relaxed font-mono text-[11.5px] select-text">${this.escapeHtml(entry.content)}</div>
            </div>
          `;

        case 'tool_call':
          const toolBadgeColor = entry.toolName === 'run_command' ? 'bg-amber-950 text-amber-300 border-amber-800/70'
            : entry.toolName?.includes('file') ? 'bg-indigo-950 text-indigo-300 border-indigo-800/70'
            : 'bg-purple-950 text-purple-300 border-purple-800/70';

          return `
            <div class="p-3.5 rounded-xl bg-[#090e17] border border-slate-800/90 text-xs shadow-inner transition hover:border-slate-700">
              <div class="flex items-center justify-between gap-2 mb-1.5">
                <div class="flex items-center gap-2">
                  <span class="px-2 py-0.5 rounded font-mono font-bold text-[10.5px] border ${toolBadgeColor}">
                    🔧 ${this.escapeHtml(entry.toolName || 'tool_call')}
                  </span>
                  <span class="text-[10px] text-slate-400 font-mono">#${entry.index}</span>
                </div>
                ${entry.timestamp ? `<span class="text-[10px] text-slate-500 font-mono">${new Date(entry.timestamp).toLocaleTimeString()}</span>` : ''}
              </div>
              <div class="font-mono text-slate-300 text-[11.5px] bg-[#05080f] p-2.5 rounded-lg border border-slate-900 overflow-x-auto leading-relaxed select-text">
                ${this.escapeHtml(entry.content)}
              </div>
            </div>
          `;

        case 'tool_result':
          const isErr = entry.status === 'error';
          const resultBadge = isErr 
            ? '<span class="text-[10px] font-mono px-2 py-0.5 rounded bg-red-950 text-red-300 border border-red-800">✖ FAILED</span>'
            : '<span class="text-[10px] font-mono px-2 py-0.5 rounded bg-emerald-950 text-emerald-300 border border-emerald-800">✓ SUCCESS</span>';

          return `
            <div class="p-3.5 rounded-xl bg-[#070b12] border ${isErr ? 'border-red-900/50' : 'border-slate-800/70'} text-xs">
              <div class="flex items-center justify-between gap-2 mb-1.5">
                <span class="text-[10.5px] font-mono font-bold text-slate-400 flex items-center gap-1.5">
                  📋 TOOL RESULT #${entry.index}
                </span>
                ${resultBadge}
              </div>
              <pre class="font-mono text-slate-400 text-[11px] bg-[#04060a] p-2.5 rounded-lg border border-slate-900/90 overflow-x-auto max-h-48 leading-relaxed select-text">${this.escapeHtml(entry.content)}</pre>
            </div>
          `;

        case 'error':
          return `
            <div class="p-3.5 rounded-xl bg-red-950/40 border border-red-800/60 text-xs">
              <div class="font-bold text-red-300 flex items-center gap-2 mb-1 text-[11px] font-mono">
                ⚠️ ERROR #${entry.index}
              </div>
              <div class="font-mono text-red-200 text-[11px] select-text">${this.escapeHtml(entry.content)}</div>
            </div>
          `;

        default:
          return `
            <div class="p-3 rounded-xl bg-slate-900/60 border border-slate-800/60 text-xs font-mono text-slate-400 select-text">
              ${this.escapeHtml(entry.content)}
            </div>
          `;
      }
    }).join('');

    return `<div class="space-y-3">${cards}</div>`;
  }

  /**
   * Formats entries into human-readable ANSI terminal output for TUI single pane
   */
  formatToAnsi(entries: TranscriptEntry[], maxWidth: number = 120): string[] {
    const lines: string[] = [];
    const C_RESET = '\x1b[0m';
    const C_BOLD = '\x1b[1m';
    const C_DIM = '\x1b[2m';
    const C_CYAN = '\x1b[36m';
    const C_GREEN = '\x1b[32m';
    const C_YELLOW = '\x1b[33m';
    const C_MAGENTA = '\x1b[35m';
    const C_RED = '\x1b[31m';
    const C_BLUE = '\x1b[34m';

    for (const entry of entries) {
      switch (entry.role) {
        case 'user':
          lines.push(`${C_BOLD}${C_BLUE}👤 USER [#${entry.index}]:${C_RESET}`);
          for (const l of entry.content.split('\n')) {
            lines.push(`  ${C_BOLD}${l.slice(0, maxWidth - 4)}${C_RESET}`);
          }
          lines.push('');
          break;

        case 'assistant':
          lines.push(`${C_BOLD}${C_CYAN}🤖 ASSISTANT [#${entry.index}]:${C_RESET}`);
          for (const l of entry.content.split('\n').slice(0, 8)) {
            lines.push(`  ${C_DIM}${l.slice(0, maxWidth - 4)}${C_RESET}`);
          }
          lines.push('');
          break;

        case 'tool_call':
          lines.push(`${C_BOLD}${C_YELLOW}🔧 TOOL CALL [${entry.toolName || 'tool'}] [#${entry.index}]:${C_RESET}`);
          for (const l of entry.content.split('\n').slice(0, 3)) {
            lines.push(`  ${C_YELLOW}▶ ${l.slice(0, maxWidth - 6)}${C_RESET}`);
          }
          lines.push('');
          break;

        case 'tool_result':
          const isErr = entry.status === 'error';
          const badge = isErr ? `${C_RED}✖ FAILED${C_RESET}` : `${C_GREEN}✓ SUCCESS${C_RESET}`;
          lines.push(`${C_BOLD}${C_MAGENTA}📋 RESULT [#${entry.index}] ${badge}:${C_RESET}`);
          for (const l of entry.content.split('\n').slice(0, 4)) {
            lines.push(`  ${C_DIM}${l.slice(0, maxWidth - 4)}${C_RESET}`);
          }
          lines.push('');
          break;

        case 'error':
          lines.push(`${C_BOLD}${C_RED}⚠️ ERROR [#${entry.index}]:${C_RESET}`);
          lines.push(`  ${C_RED}${entry.content.slice(0, maxWidth - 4)}${C_RESET}`);
          lines.push('');
          break;

        default:
          lines.push(`  ${C_DIM}${entry.content.slice(0, maxWidth - 4)}${C_RESET}`);
          break;
      }
    }

    return lines;
  }

  private escapeHtml(str: string): string {
    return (str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }
}
