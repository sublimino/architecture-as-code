import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import type {
  DashboardMetrics,
  HarnessType,
  SearchQuery,
  SessionMetadata,
  SessionStatus,
  SyncStoreConfig
} from '../types';
import { AdapterRegistry } from '../adapters/registry';
import { SessionSummarizer } from '../summarizer/summarizer';
import { DragonCrossReferencer } from '../productivity-dragon/dragon-crossref';

export class SyncStore {
  private sessions: Map<string, SessionMetadata> = new Map();
  private registry = new AdapterRegistry();
  private summarizer = new SessionSummarizer();
  private dragonCrossref: DragonCrossReferencer;
  private isScanning = false;
  private scanTimer?: ReturnType<typeof setInterval>;
  private listeners: Array<(session: SessionMetadata) => void> = [];

  constructor(private config: SyncStoreConfig) {
    this.dragonCrossref = new DragonCrossReferencer(config.obsidianVaultDir);
    this.ensureDirs();
  }

  private async ensureDirs(): Promise<void> {
    try {
      if (!existsSync(this.config.primaryStoreDir)) {
        await fs.mkdir(this.config.primaryStoreDir, { recursive: true });
      }
    } catch {
      // Fallback to local cache directory if primaryStoreDir is read-only / sandboxed
      const fallbackDir = path.join(process.cwd(), '.cache', 'ai-sessions');
      try {
        if (!existsSync(fallbackDir)) {
          await fs.mkdir(fallbackDir, { recursive: true });
        }
        this.config.primaryStoreDir = fallbackDir;
      } catch {
        // Fallback to /tmp
        this.config.primaryStoreDir = path.join(os.tmpdir(), 'ai-sessions');
        try {
          await fs.mkdir(this.config.primaryStoreDir, { recursive: true });
        } catch {}
      }
    }
  }

  onSessionUpdate(callback: (session: SessionMetadata) => void): () => void {
    this.listeners.push(callback);
    return () => {
      this.listeners = this.listeners.filter((cb) => cb !== callback);
    };
  }

  private notify(session: SessionMetadata): void {
    for (const listener of this.listeners) {
      try {
        listener(session);
      } catch {}
    }
  }

  /**
   * Fast initial load: reads all pre-cached session json files from the partitioned store
   */
  async loadCached(): Promise<SessionMetadata[]> {
    if (!existsSync(this.config.primaryStoreDir)) return [];

    try {
      const deviceDirs = await fs.readdir(this.config.primaryStoreDir, { withFileTypes: true });
      for (const dev of deviceDirs) {
        if (!dev.isDirectory()) continue;
        const devPath = path.join(this.config.primaryStoreDir, dev.name);
        const harnessDirs = await fs.readdir(devPath, { withFileTypes: true });
        
        for (const h of harnessDirs) {
          if (!h.isDirectory()) continue;
          const hPath = path.join(devPath, h.name);
          const sessionFiles = await fs.readdir(hPath);

          for (const sFile of sessionFiles) {
            if (sFile.endsWith('.json')) {
              try {
                const fullPath = path.join(hPath, sFile);
                const raw = await fs.readFile(fullPath, 'utf-8');
                const session: SessionMetadata = JSON.parse(raw);
                this.sessions.set(session.id, session);
              } catch {
                // skip corrupted cache
              }
            }
          }
        }
      }
    } catch {
      // ignore
    }

    return this.listSessions();
  }

  /**
   * Save a session into the partitioned device store atomically
   */
  async saveSession(session: SessionMetadata): Promise<void> {
    // Cross-reference with Productivity Dragon
    if (!session.productivityDragon) {
      session.productivityDragon = this.dragonCrossref.matchSession(session);
    }

    this.sessions.set(session.id, session);
    this.notify(session);

    try {
      const devDir = path.join(this.config.primaryStoreDir, session.deviceId, session.harness);
      await fs.mkdir(devDir, { recursive: true });
      
      const filePath = path.join(devDir, `${session.id}.json`);
      const tmpPath = `${filePath}.tmp.${Date.now()}`;
      
      await fs.writeFile(tmpPath, JSON.stringify(session, null, 2), 'utf-8');
      await fs.rename(tmpPath, filePath);
    } catch {
      // Memory store already updated; disk cache write failure is non-fatal in sandboxed mode
    }
  }

  /**
   * Async heavy scan across local search directories
   */
  async scanLocalHarnesses(searchDirs?: string[]): Promise<number> {
    if (this.isScanning) return 0;
    this.isScanning = true;

    const baseDirs = searchDirs && searchDirs.length > 0
      ? searchDirs
      : [
          process.env.HOME || '/home/andy',
          path.join(process.env.HOME || '/home/andy', 'src'),
          path.join(process.env.HOME || '/home/andy', '.gemini'),
          path.join(process.env.HOME || '/home/andy', '.claude')
        ];

    let foundCount = 0;

    try {
      const adapters = this.registry.getAll();
      for (const adapter of adapters) {
        try {
          const files = await adapter.discoverSessions(baseDirs);
          for (const file of files) {
            try {
              const session = await adapter.parseSession(
                file,
                this.config.deviceId,
                this.config.hostname
              );
              if (session) {
                // Generate refined AI summary from last lines if needed
                if (!session.summary || session.summary.startsWith('Active')) {
                  session.summary = this.summarizer.summarize(session.lastLines, session.title);
                }
                await this.saveSession(session);
                foundCount++;
              }
            } catch {
              // skip parse error
            }
          }
        } catch {
          // skip adapter discovery error
        }
      }
    } finally {
      this.isScanning = false;
    }

    return foundCount;
  }

  startBackgroundScanner(intervalMs: number = 10000): void {
    if (this.scanTimer) clearInterval(this.scanTimer);
    // Initial async scan
    this.scanLocalHarnesses().catch(() => {});
    this.scanTimer = setInterval(() => {
      this.scanLocalHarnesses().catch(() => {});
    }, intervalMs);
  }

  stopBackgroundScanner(): void {
    if (this.scanTimer) {
      clearInterval(this.scanTimer);
      this.scanTimer = undefined;
    }
  }

  getSession(id: string): SessionMetadata | undefined {
    return this.sessions.get(id);
  }

  listSessions(query?: SearchQuery): SessionMetadata[] {
    let result = Array.from(this.sessions.values());

    if (query) {
      if (query.harness) {
        result = result.filter((s) => s.harness === query.harness);
      }
      if (query.deviceId) {
        result = result.filter((s) => s.deviceId === query.deviceId || s.hostname === query.deviceId);
      }
      if (query.status) {
        result = result.filter((s) => s.status === query.status);
      }
      if (query.tags && query.tags.length > 0) {
        result = result.filter((s) => query.tags!.some((t) => s.tags.includes(t)));
      }
      if (query.text) {
        const needle = query.text.toLowerCase();
        result = result.filter((s) => {
          return (
            s.title.toLowerCase().includes(needle) ||
            s.summary.toLowerCase().includes(needle) ||
            s.cwd.toLowerCase().includes(needle) ||
            s.id.toLowerCase().includes(needle) ||
            s.titleHistory.some((t) => t.toLowerCase().includes(needle)) ||
            (s.gitBranch && s.gitBranch.toLowerCase().includes(needle)) ||
            (s.productivityDragon?.questTitle && s.productivityDragon.questTitle.toLowerCase().includes(needle)) ||
            s.subordinateActivities.some((sub) => sub.name.toLowerCase().includes(needle) || (sub.summary && sub.summary.toLowerCase().includes(needle)))
          );
        });
      }
    }

    // Default sort: newest lastActivityAt first
    result.sort((a, b) => new Date(b.lastActivityAt).getTime() - new Date(a.lastActivityAt).getTime());

    if (query?.offset) {
      result = result.slice(query.offset);
    }
    if (query?.limit) {
      result = result.slice(0, query.limit);
    }

    return result;
  }

  getMetrics(): DashboardMetrics {
    const list = this.listSessions();
    const activeSessions = list.filter((s) => s.status === 'running').length;
    const devices = new Set(list.map((s) => s.deviceId || s.hostname));
    
    const breakdown: Record<HarnessType, number> = {
      claude: 0,
      agy: 0,
      codex: 0,
      cpai: 0,
      omp: 0,
      hermes: 0,
      happy: 0,
      custom: 0
    };

    let totalTokens = 0;
    let totalCostUsd = 0;
    let totalXp = 0;

    for (const s of list) {
      if (breakdown[s.harness] !== undefined) {
        breakdown[s.harness]++;
      } else {
        breakdown.custom++;
      }
      totalTokens += (s.tokenUsage.inputTokens + s.tokenUsage.outputTokens);
      totalCostUsd += s.tokenUsage.totalCostUsd;
      if (s.productivityDragon?.xpEarned) {
        totalXp += s.productivityDragon.xpEarned;
      }
    }

    return {
      totalSessions: list.length,
      activeSessions,
      totalDevices: devices.size,
      harnessBreakdown: breakdown,
      totalTokens,
      totalCostUsd: Number(totalCostUsd.toFixed(4)),
      totalProductivityDragonXp: totalXp,
      recentSessions: list.slice(0, 10)
    };
  }

  /**
   * Export all sessions to Obsidian-compatible Markdown notes
   */
  async exportToObsidian(targetDir?: string): Promise<string[]> {
    const outDir = targetDir || this.config.obsidianDailyNotesDir || path.join(this.config.primaryStoreDir, 'obsidian-export');
    await fs.mkdir(outDir, { recursive: true });

    const exportedFiles: string[] = [];
    const sessions = this.listSessions();

    for (const session of sessions) {
      const card = this.summarizer.generateMarkdownCard(session);
      const safeTitle = session.title.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 50);
      const fileName = `${new Date(session.lastActivityAt).toISOString().slice(0, 10)} - ${session.harness} - ${safeTitle}.md`;
      const filePath = path.join(outDir, fileName);
      
      await fs.writeFile(filePath, card, 'utf-8');
      exportedFiles.push(filePath);
    }

    return exportedFiles;
  }
}
