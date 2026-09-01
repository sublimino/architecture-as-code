import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { SummaryModelTier } from '../types';

export interface AppModelUsageStats {
  calls: number;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  totalLatencyMs: number;
}

export interface AppTokenMetrics {
  totalCalls: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalCostUsd: number;
  lastCallAt?: string;
  byModel: Record<SummaryModelTier, AppModelUsageStats>;
}

export interface AppTokenRecord {
  id: string;
  timestamp: string;
  model: SummaryModelTier;
  modelLabel: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  latencyMs: number;
  sessionId?: string;
}

export class AppTokenTracker {
  private metrics: AppTokenMetrics;
  private storagePath: string;
  private listeners = new Set<(metrics: AppTokenMetrics) => void>();

  constructor(customPath?: string) {
    this.storagePath =
      customPath ||
      path.join(os.homedir(), '.cache', 'harness-dash', 'app-token-metrics.json');
    this.metrics = this.loadMetrics();
  }

  private initEmptyMetrics(): AppTokenMetrics {
    return {
      totalCalls: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      totalCostUsd: 0,
      byModel: {
        'gemma-4-cerebras': { calls: 0, inputTokens: 0, outputTokens: 0, costUsd: 0, totalLatencyMs: 0 },
        'gemini-2.5-flash': { calls: 0, inputTokens: 0, outputTokens: 0, costUsd: 0, totalLatencyMs: 0 },
        'antigravity': { calls: 0, inputTokens: 0, outputTokens: 0, costUsd: 0, totalLatencyMs: 0 },
        'extractive': { calls: 0, inputTokens: 0, outputTokens: 0, costUsd: 0, totalLatencyMs: 0 }
      }
    };
  }

  private loadMetrics(): AppTokenMetrics {
    if (existsSync(this.storagePath)) {
      try {
        const raw = readFileSync(this.storagePath, 'utf-8');
        const data = JSON.parse(raw);
        return {
          ...this.initEmptyMetrics(),
          ...data,
          byModel: {
            ...this.initEmptyMetrics().byModel,
            ...(data.byModel || {})
          }
        };
      } catch {
        // Fallback to fresh metrics on parse error
      }
    }
    return this.initEmptyMetrics();
  }

  private saveMetrics(): void {
    try {
      const dir = path.dirname(this.storagePath);
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true });
      }
      writeFileSync(this.storagePath, JSON.stringify(this.metrics, null, 2), 'utf-8');
    } catch {
      // ignore write errors in restricted envs
    }
  }

  /**
   * Calculate exact cost per model tier
   */
  calculateCost(model: SummaryModelTier, inputTokens: number, outputTokens: number): number {
    switch (model) {
      case 'gemma-4-cerebras':
        // Cerebras Gemma 4 WSE: ~$0.60 per 1M tokens ($0.0006 / 1k)
        return Number(((inputTokens * 0.0006 + outputTokens * 0.0006) / 1000).toFixed(6));
      case 'gemini-2.5-flash':
        // Gemini 2.5 Flash: $0.075 / 1M in ($0.000075 / 1k), $0.30 / 1M out ($0.0003 / 1k)
        return Number(((inputTokens * 0.000075 + outputTokens * 0.0003) / 1000).toFixed(6));
      case 'antigravity':
        // Gemini 2.5 Pro / Antigravity: $1.25 / 1M in ($0.00125 / 1k), $5.00 / 1M out ($0.005 / 1k)
        return Number(((inputTokens * 0.00125 + outputTokens * 0.005) / 1000).toFixed(6));
      case 'extractive':
      default:
        return 0;
    }
  }

  /**
   * Records a model call made by harness-dash for on-demand summarization
   */
  recordCall(
    model: SummaryModelTier,
    inputTokens: number,
    outputTokens: number,
    latencyMs: number,
    sessionId?: string
  ): AppTokenRecord {
    const costUsd = this.calculateCost(model, inputTokens, outputTokens);
    const now = new Date().toISOString();

    this.metrics.totalCalls += 1;
    this.metrics.totalInputTokens += inputTokens;
    this.metrics.totalOutputTokens += outputTokens;
    this.metrics.totalCostUsd = Number((this.metrics.totalCostUsd + costUsd).toFixed(6));
    this.metrics.lastCallAt = now;

    if (!this.metrics.byModel[model]) {
      this.metrics.byModel[model] = { calls: 0, inputTokens: 0, outputTokens: 0, costUsd: 0, totalLatencyMs: 0 };
    }

    const modelStats = this.metrics.byModel[model];
    modelStats.calls += 1;
    modelStats.inputTokens += inputTokens;
    modelStats.outputTokens += outputTokens;
    modelStats.costUsd = Number((modelStats.costUsd + costUsd).toFixed(6));
    modelStats.totalLatencyMs += latencyMs;

    this.saveMetrics();
    this.notifyListeners();

    const modelLabels: Record<SummaryModelTier, string> = {
      'gemma-4-cerebras': 'Gemma 4 (Cerebras WSE)',
      'gemini-2.5-flash': 'Gemini 2.5 Flash',
      'antigravity': 'Antigravity Pro',
      'extractive': 'Extractive Heuristic'
    };

    return {
      id: `call-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      timestamp: now,
      model,
      modelLabel: modelLabels[model] || model,
      inputTokens,
      outputTokens,
      costUsd,
      latencyMs,
      sessionId
    };
  }

  getMetrics(): AppTokenMetrics {
    return { ...this.metrics };
  }

  onUpdate(callback: (metrics: AppTokenMetrics) => void): () => void {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }

  private notifyListeners(): void {
    const copy = this.getMetrics();
    for (const listener of this.listeners) {
      try {
        listener(copy);
      } catch {
        // ignore
      }
    }
  }

  reset(): void {
    this.metrics = this.initEmptyMetrics();
    this.saveMetrics();
    this.notifyListeners();
  }
}
