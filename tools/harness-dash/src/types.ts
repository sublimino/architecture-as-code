/**
 * Universal AI CLI & Harness Types
 * Supports: happy, claude, codex, cpai, omp, hermes, agy, custom
 */

export type HarnessType =
  | 'claude'
  | 'agy'
  | 'codex'
  | 'cpai'
  | 'omp'
  | 'hermes'
  | 'happy'
  | 'custom';

export type SessionStatus =
  | 'running'
  | 'idle'
  | 'completed'
  | 'failed'
  | 'paused';

export type SubordinateActivityType =
  | 'subagent'
  | 'background_task'
  | 'tool_loop'
  | 'branch_fork'
  | 'eval_step';

export interface SubordinateActivity {
  id: string;
  parentId: string;
  type: SubordinateActivityType;
  name: string;
  role?: string;
  status: SessionStatus;
  startedAt: string;
  completedAt?: string;
  durationMs?: number;
  summary?: string;
  transcriptSnippet?: string[];
  url?: string;
  model?: string;
  forkableFromStep?: number;
}

export interface TokenUsageMetrics {
  inputTokens: number;
  outputTokens: number;
  totalCostUsd: number;
  contextWindowUsedPct?: number;
}

export interface ProductivityDragonMatch {
  questId?: string;
  questTitle?: string;
  goalMatch?: string;
  xpEarned?: number;
  dragonNotePath?: string;
  confidenceScore: number;
}

export type SummaryModelTier =
  | 'gemma-4-cerebras'
  | 'gemini-2.5-flash'
  | 'antigravity'
  | 'extractive';

export interface SummaryInfo {
  text: string;
  model: SummaryModelTier;
  modelLabel: string;
  costTier: '$' | '$$' | '$$$';
  latencyMs?: number;
  generatedAt: string;
  prompt?: string;
  payloadSize?: number;
}

export interface SessionMetadata {
  id: string;
  harness: HarnessType;
  deviceId: string;
  hostname: string;
  title: string;
  titleHistory: string[];
  currentGoal?: string;
  status: SessionStatus;
  createdAt: string;
  updatedAt: string;
  lastActivityAt: string;
  cwd: string;
  gitBranch?: string;
  gitRepo?: string;
  modelsUsed: string[];
  tokenUsage: TokenUsageMetrics;
  subagentCount: number;
  subordinateActivities: SubordinateActivity[];
  summary: string;
  summaryInfo?: SummaryInfo;
  lastLines: string[];
  url: string;
  obsidianNotePath?: string;
  productivityDragon?: ProductivityDragonMatch;
  tags: string[];
  rawLogPath?: string;
}

export interface SearchQuery {
  text?: string;
  harness?: HarnessType;
  deviceId?: string;
  status?: SessionStatus;
  minDate?: string;
  maxDate?: string;
  tags?: string[];
  limit?: number;
  offset?: number;
}

export interface HarnessAdapter {
  readonly harnessName: HarnessType;
  detect(path: string): Promise<boolean>;
  discoverSessions(searchDirs: string[]): Promise<string[]>;
  parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null>;
  tailSession(filePath: string, lineCount?: number): Promise<string[]>;
  getLaunchUrl(session: SessionMetadata): string;
}

export interface SyncStoreConfig {
  primaryStoreDir: string;
  obsidianVaultDir?: string;
  obsidianDailyNotesDir?: string;
  deviceId: string;
  hostname: string;
  asyncScanIntervalMs?: number;
}

export interface DashboardMetrics {
  totalSessions: number;
  activeSessions: number;
  totalDevices: number;
  harnessBreakdown: Record<HarnessType, number>;
  totalTokens: number;
  totalCostUsd: number;
  totalProductivityDragonXp: number;
  recentSessions: SessionMetadata[];
}
