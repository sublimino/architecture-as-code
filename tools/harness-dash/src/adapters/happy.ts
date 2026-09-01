import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata } from '../types';
import { BaseHarnessAdapter } from './base';

export class HappyAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'happy';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('happy') || filePath.includes('.happy');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const happyDir = path.join(dir, '.happy', 'sessions');
      if (existsSync(happyDir)) {
        try {
          const files = await fs.readdir(happyDir);
          for (const f of files) discovered.push(path.join(happyDir, f));
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
      const lastLines = await this.tailSession(filePath, 60);
      const title = `Happy Session ${sessionId.slice(0, 8)}`;

      return {
        id: `happy-${sessionId}`,
        harness: 'happy',
        deviceId,
        hostname,
        title,
        titleHistory: [title],
        status: this.determineStatus(stat.mtime),
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: stat.mtime.toISOString(),
        cwd: process.env.HOME || '/',
        modelsUsed: ['claude-3-7-sonnet'],
        tokenUsage: { inputTokens: 11000, outputTokens: 1800, totalCostUsd: 0.01 },
        subagentCount: 0,
        subordinateActivities: [],
        summary: 'Happy CLI local pair-programming session',
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['happy', 'pair-programming'],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }
}
