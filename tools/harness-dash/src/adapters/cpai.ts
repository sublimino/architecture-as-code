import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata, SubordinateActivity } from '../types';
import { BaseHarnessAdapter } from './base';

export class CpaiAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'cpai';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('cpai') || filePath.includes('aichat');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const candidates = [
        path.join(dir, '.cpai', 'sessions'),
        path.join(dir, '.config', 'aichat', 'sessions'),
        path.join(dir, 'src', 'cp', 'cpai-cli', 'sessions')
      ];
      for (const c of candidates) {
        if (existsSync(c)) {
          try {
            const files = await fs.readdir(c);
            for (const f of files) {
              if (f.endsWith('.json') || f.endsWith('.yaml') || f.endsWith('.jsonl')) {
                discovered.push(path.join(c, f));
              }
            }
          } catch {
            // ignore
          }
        }
      }
    }
    return discovered;
  }

  async parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null> {
    if (!existsSync(filePath)) return null;

    try {
      const stat = await fs.stat(filePath);
      const sessionId = path.basename(filePath, path.extname(filePath));
      const lastLines = await this.tailSession(filePath, 100);
      
      let title = `CPAI Workflow ${sessionId.slice(0, 8)}`;
      const titleHistory: string[] = [];
      const subordinateActivities: SubordinateActivity[] = [];
      let summary = 'CPAI conversation and agent workflow';
      let lastActivityDate = stat.mtime;
      let cwd = process.env.HOME || '/';
      const tags = new Set<string>(['cpai', 'opencode', 'controlplane']);

      const modelsUsed = new Set<string>();
      let inputTokens = 0;
      let outputTokens = 0;
      let totalCostUsd = 0;
      let contextWindowUsedPct = 0;

      for (const line of lastLines) {
        try {
          const parsed = JSON.parse(line);
          if (parsed.session_name || parsed.title) {
            title = this.cleanTitle(parsed.session_name || parsed.title);
            titleHistory.push(title);
          }
          if (parsed.summary) summary = parsed.summary;
          if (typeof parsed.cwd === 'string' && parsed.cwd.trim()) {
            cwd = parsed.cwd.trim();
          } else if (typeof parsed.working_directory === 'string' && parsed.working_directory.trim()) {
            cwd = parsed.working_directory.trim();
          }
          if (Array.isArray(parsed.subordinate_activities)) {
            for (const sub of parsed.subordinate_activities) {
              if (sub && typeof sub === 'object' && typeof sub.name === 'string') {
                subordinateActivities.push(sub as SubordinateActivity);
              }
            }
          } else if (Array.isArray(parsed.subagents)) {
            for (const sub of parsed.subagents) {
              if (sub && typeof sub === 'object' && typeof sub.name === 'string') {
                subordinateActivities.push(sub as SubordinateActivity);
              }
            }
          }
          if (Array.isArray(parsed.tags)) {
            for (const t of parsed.tags) {
              if (typeof t === 'string' && t.trim()) tags.add(t.trim());
            }
          }
          if (parsed.timestamp) {
            const d = new Date(parsed.timestamp);
            if (!isNaN(d.getTime())) lastActivityDate = d;
          }
          if (typeof parsed.model === 'string' && parsed.model) {
            modelsUsed.add(parsed.model);
          } else if (Array.isArray(parsed.models)) {
            for (const m of parsed.models) {
              if (typeof m === 'string' && m) modelsUsed.add(m);
            }
          }
          if (parsed.token_usage || parsed.usage) {
            const u = parsed.token_usage || parsed.usage;
            if (typeof u.input_tokens === 'number') inputTokens += u.input_tokens;
            if (typeof u.output_tokens === 'number') outputTokens += u.output_tokens;
            if (typeof u.total_cost_usd === 'number') totalCostUsd += u.total_cost_usd;
            if (typeof u.context_window_used_pct === 'number') contextWindowUsedPct = u.context_window_used_pct;
          }
          if (typeof parsed.input_tokens === 'number') inputTokens += parsed.input_tokens;
          if (typeof parsed.output_tokens === 'number') outputTokens += parsed.output_tokens;
        } catch {
          // ignore
        }
      }

      const status = this.determineStatus(lastActivityDate);

      return {
        id: `cpai-${sessionId}`,
        harness: 'cpai',
        deviceId,
        hostname,
        title,
        titleHistory,
        currentGoal: title,
        status,
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: lastActivityDate.toISOString(),
        cwd,
        modelsUsed: Array.from(modelsUsed),
        tokenUsage: {
          inputTokens,
          outputTokens,
          totalCostUsd,
          contextWindowUsedPct
        },
        subagentCount: subordinateActivities.length,
        subordinateActivities,
        summary,
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: Array.from(tags),
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }

  getLaunchUrl(session: SessionMetadata): string {
    return `cpai://session/${session.id.replace(/^cpai-/, '')}`;
  }
}
