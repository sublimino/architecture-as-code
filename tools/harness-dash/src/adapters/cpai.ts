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

      for (const line of lastLines) {
        try {
          const parsed = JSON.parse(line);
          if (parsed.session_name || parsed.title) {
            title = this.cleanTitle(parsed.session_name || parsed.title);
            titleHistory.push(title);
          }
          if (parsed.summary) summary = parsed.summary;
          if (parsed.timestamp) {
            const d = new Date(parsed.timestamp);
            if (!isNaN(d.getTime())) lastActivityDate = d;
          }
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
        cwd: process.env.HOME || '/',
        modelsUsed: ['claude-3-7-sonnet', 'deepseek-r1'],
        tokenUsage: {
          inputTokens: 28000,
          outputTokens: 4100,
          totalCostUsd: 0.038,
          contextWindowUsedPct: 22
        },
        subagentCount: subordinateActivities.length,
        subordinateActivities,
        summary,
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['cpai', 'opencode', 'controlplane'],
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
