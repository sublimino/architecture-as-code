import type { HarnessAdapter, HarnessType } from '../types';
import { ClaudeAdapter } from './claude';
import { AgyAdapter } from './agy';
import { CpaiAdapter } from './cpai';
import { CodexAdapter } from './codex';
import { OmpAdapter } from './omp';
import { HermesAdapter } from './hermes';
import { HappyAdapter } from './happy';

export class AdapterRegistry {
  private adapters: Map<HarnessType, HarnessAdapter> = new Map();

  constructor() {
    this.register(new ClaudeAdapter());
    this.register(new AgyAdapter());
    this.register(new CpaiAdapter());
    this.register(new CodexAdapter());
    this.register(new OmpAdapter());
    this.register(new HermesAdapter());
    this.register(new HappyAdapter());
  }

  register(adapter: HarnessAdapter): void {
    this.adapters.set(adapter.harnessName, adapter);
  }

  get(harness: HarnessType): HarnessAdapter | undefined {
    return this.adapters.get(harness);
  }

  getAll(): HarnessAdapter[] {
    return Array.from(this.adapters.values());
  }

  async detectAdapter(filePath: string): Promise<HarnessAdapter | undefined> {
    for (const adapter of this.adapters.values()) {
      if (await adapter.detect(filePath)) {
        return adapter;
      }
    }
    return undefined;
  }
}
