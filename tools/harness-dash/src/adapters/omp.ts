import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata } from '../types';
import { BaseHarnessAdapter } from './base';

export class OmpAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'omp';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('.omp') || filePath.includes('openmodelprompt') || filePath.includes('oh-my-prompt');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const ompDir = path.join(dir, '.omp', 'sessions');
      if (existsSync(ompDir)) {
        try {
          const files = await fs.readdir(ompDir);
          for (const f of files) discovered.push(path.join(ompDir, f));
        } catch {}
      }
    }
    return discovered;
  }

  async parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null> {
    if (!existsSync(filePath)) return null;

    try {
      const stat = await fs.stat(filePath);
      const sessionId = path.basename(filePath, path.extname(filePath));
      const lastLines = await this.tailSession(filePath, 50);
      const title = `OMP Session ${sessionId.slice(0, 8)}`;

      return {
        id: `omp-${sessionId}`,
        harness: 'omp',
        deviceId,
        hostname,
        title,
        titleHistory: [title],
        status: this.determineStatus(stat.mtime),
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: stat.mtime.toISOString(),
        cwd: process.env.HOME || '/',
        cwd,
        modelsUsed: ['claude-3-5-haiku', 'gpt-4o-mini'],
        tokenUsage: { inputTokens: 8000, outputTokens: 1200, totalCostUsd: 0.005 },
        subagentCount: 0,
        subordinateActivities: [],
        summary: 'OpenModelPrompt templated multi-model session',
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['omp', 'pi', 'agent'],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }

  getLaunchUrl(session: SessionMetadata): string {
    return `omp://session/${session.id.replace(/^omp-/, '')}`;
  }
}
