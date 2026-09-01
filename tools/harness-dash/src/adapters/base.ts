import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessAdapter, HarnessType, SessionMetadata, SessionStatus, SubordinateActivity } from '../types';

export function buildCanonicalAiUri(harness: string, sessionId: string, cwd?: string, hostname?: string): string {
  const cleanId = sessionId.replace(new RegExp(`^${harness}-`), '');
  const dirParam = cwd ? `&dir=${encodeURIComponent(cwd)}` : '';
  const hostParam = hostname && hostname !== 'localhost' ? `&host=${encodeURIComponent(hostname)}` : '';
  return `${harness}://open?id=${cleanId}${dirParam}${hostParam}`;
}

export abstract class BaseHarnessAdapter implements HarnessAdapter {
  abstract readonly harnessName: HarnessType;

  abstract detect(filePath: string): Promise<boolean>;
  abstract discoverSessions(searchDirs: string[]): Promise<string[]>;
  abstract parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null>;

  /**
   * Fast tail: reads last N lines of a file without loading entire large logs into memory
   */
  async tailSession(filePath: string, lineCount: number = 200): Promise<string[]> {
    if (!existsSync(filePath)) {
      return [];
    }

    try {
      const stats = await fs.stat(filePath);
      const fileSize = stats.size;
      if (fileSize === 0) return [];

      // Read max 512KB from the end of the file
      const bufferSize = Math.min(fileSize, 512 * 1024);
      const buffer = Buffer.alloc(bufferSize);
      const fd = await fs.open(filePath, 'r');
      
      try {
        await fd.read(buffer, 0, bufferSize, fileSize - bufferSize);
      } finally {
        await fd.close();
      }

      const content = buffer.toString('utf-8');
      const lines = content.split('\n').filter((l) => l.trim().length > 0);
      return lines.slice(-lineCount);
    } catch {
      return [];
    }
  }

  getLaunchUrl(session: SessionMetadata): string {
    return buildCanonicalAiUri(this.harnessName, session.id, session.cwd, session.hostname);
  }

  protected determineStatus(lastActivityDate: Date, isError: boolean = false): SessionStatus {
    if (isError) return 'failed';
    const now = Date.now();
    const diffMs = now - lastActivityDate.getTime();
    
    // If updated in the last 3 minutes, treat as running/active
    if (diffMs < 3 * 60 * 1000) {
      return 'running';
    }
    // If updated within 30 minutes, idle
    if (diffMs < 30 * 60 * 1000) {
      return 'idle';
    }
    return 'completed';
  }

  protected cleanTitle(raw: string): string {
    if (!raw) return 'Untitled Session';
    return raw
      .replace(/<\/?(USER_REQUEST|ADDITIONAL_METADATA|SYSTEM_MESSAGE|system|context)[^>]*>/gi, '')
      .replace(/<[^>]+>/g, '')
      .replace(/--append-system-prompt-file[^\n]*/g, '')
      .replace(/@PAI\/[^\n]*/g, '')
      .replace(/^[-*•]\s+/g, '')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 120);
  }
}
