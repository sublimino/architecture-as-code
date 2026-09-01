import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata } from '../types';
import { BaseHarnessAdapter } from './base';

export class HermesAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'hermes';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('hermes') || filePath.includes('nous');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const hermesDir = path.join(dir, '.hermes', 'sessions');
      if (existsSync(hermesDir)) {
        try {
          const files = await fs.readdir(hermesDir);
          for (const f of files) discovered.push(path.join(hermesDir, f));
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
      const title = `Hermes Agent ${sessionId.slice(0, 8)}`;

      return {
        id: `hermes-${sessionId}`,
        harness: 'hermes',
        deviceId,
        hostname,
        title,
        titleHistory: [title],
        status: this.determineStatus(stat.mtime),
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: stat.mtime.toISOString(),
        cwd: process.env.HOME || '/',
        modelsUsed: ['hermes-3-llama-3.1-405b'],
        tokenUsage: { inputTokens: 15000, outputTokens: 2500, totalCostUsd: 0.012 },
        subagentCount: 0,
        subordinateActivities: [],
        summary: 'Hermes agent tool-calling and autonomous reasoning run',
        lastLines,
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['hermes', 'nous-research', 'autonomous'],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }
}
