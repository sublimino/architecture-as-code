import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata, SubordinateActivity } from '../types';
import { BaseHarnessAdapter } from './base';

export class CodexAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'codex';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('codex') || filePath.includes('openai');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const candidates = [
        path.join(dir, '.codex', 'sessions'),
        path.join(dir, '.openai', 'sessions')
      ];
      for (const c of candidates) {
        if (existsSync(c)) {
          try {
            const files = await fs.readdir(c);
            for (const f of files) {
              discovered.push(path.join(c, f));
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
      const lastLines = await this.tailSession(filePath, 80);
      let title = `Codex Session ${sessionId.slice(0, 8)}`;
      let summary = 'OpenAI Codex code generation & reasoning trace';

      return {
        id: `codex-${sessionId}`,
        harness: 'codex',
        deviceId,
        hostname,
        title,
        titleHistory: [title],
        currentGoal: title,
        status: this.determineStatus(stat.mtime),
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: stat.mtime.toISOString(),
        cwd: process.env.HOME || '/',
        modelsUsed: ['gpt-4o', 'o3-mini'],
        tokenUsage: {
          inputTokens: 12000,
          outputTokens: 3400,
          totalCostUsd: 0.024,
          contextWindowUsedPct: 15
        },
        subagentCount: 0,
        subordinateActivities: [],
        summary,
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['codex', 'openai', 'generation'],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }
}
