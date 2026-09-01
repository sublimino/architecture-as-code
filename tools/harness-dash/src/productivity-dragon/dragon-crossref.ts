import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { ProductivityDragonMatch, SessionMetadata } from '../types';

export interface DragonQuest {
  id: string;
  title: string;
  category: string;
  status: 'active' | 'completed' | 'queued';
  targetRepo?: string;
  keywords: string[];
  xpReward: number;
}

export class DragonCrossReferencer {
  private quests: DragonQuest[] = [];

  constructor(private vaultPath?: string) {
    this.seedDefaultQuests();
  }

  private seedDefaultQuests(): void {
    this.quests = [
      {
        id: 'quest-d2-fleet',
        title: 'D2 Fleet & GitOps Foundation Hardening',
        category: 'infrastructure',
        status: 'active',
        targetRepo: 'osramp-demo',
        keywords: ['fleet', 'flux', 'resourceset', 'zot', 'kind', 'bootstrap', 'spire', 'openbao', 'supercred'],
        xpReward: 50
      },
      {
        id: 'quest-signalloom-governance',
        title: 'Signal Loom AI Agent Governance Platform',
        category: 'ai-governance',
        status: 'active',
        targetRepo: 'osramp-demo',
        keywords: ['signalloom', 'dashboard', 'governance', 'spiffe', 'trust', 'afm', 'k8s-afm'],
        xpReward: 45
      },
      {
        id: 'quest-universal-harness',
        title: 'Universal AI CLI Harness & Multi-Device Session Tracking',
        category: 'tooling',
        status: 'active',
        targetRepo: 'osramp-demo',
        keywords: ['harness', 'tailscale-dash', 'controlroom', 'session', 'claude', 'agy', 'codex', 'cpai', 'omp', 'hermes'],
        xpReward: 60
      },
      {
        id: 'quest-pai-life-os',
        title: 'PAI 5.0 / 6.3 Life OS Architecture & Telos Alignment',
        category: 'core-ai',
        status: 'active',
        keywords: ['pai', 'telos', 'algorithm', 'pulse', 'da_identity', 'memory'],
        xpReward: 40
      }
    ];
  }

  /**
   * Scans Obsidian Vault for active Productivity Dragon quest notes if available
   */
  async loadFromVault(vaultPath: string): Promise<void> {
    if (!existsSync(vaultPath)) return;

    try {
      const dragonDir = path.join(vaultPath, 'Productivity Dragon');
      if (existsSync(dragonDir)) {
        const files = await fs.readdir(dragonDir);
        for (const file of files) {
          if (file.endsWith('.md')) {
            const content = await fs.readFile(path.join(dragonDir, file), 'utf-8');
            const titleMatch = content.match(/^#\s+(.+)$/m);
            const questTitle = titleMatch ? titleMatch[1].trim() : file.replace('.md', '');
            
            this.quests.push({
              id: `quest-${file.replace('.md', '').toLowerCase().replace(/[^a-z0-9]/g, '-')}`,
              title: questTitle,
              category: 'vault-quest',
              status: 'active',
              keywords: questTitle.toLowerCase().split(/\s+/).filter(w => w.length > 3),
              xpReward: 35
            });
          }
        }
      }
    } catch {
      // ignore vault scan errors
    }
  }

  /**
   * Cross-references a session with active Productivity Dragon quests
   */
  matchSession(session: SessionMetadata): ProductivityDragonMatch | undefined {
    const searchText = [
      session.title,
      session.summary,
      session.cwd,
      session.gitBranch || '',
      session.gitRepo || '',
      ...session.tags,
      ...session.titleHistory
    ].join(' ').toLowerCase();

    let bestMatch: DragonQuest | undefined;
    let highestScore = 0;

    for (const quest of this.quests) {
      let score = 0;
      if (quest.targetRepo && searchText.includes(quest.targetRepo.toLowerCase())) {
        score += 3;
      }
      for (const kw of quest.keywords) {
        if (searchText.includes(kw.toLowerCase())) {
          score += 2;
        }
      }

      if (score > highestScore && score >= 2) {
        highestScore = score;
        bestMatch = quest;
      }
    }

    if (bestMatch) {
      const confidence = Math.min(1.0, highestScore / 6);
      return {
        questId: bestMatch.id,
        questTitle: bestMatch.title,
        goalMatch: `Matched quest: ${bestMatch.title}`,
        xpEarned: Math.round(bestMatch.xpReward * confidence),
        confidenceScore: confidence,
        dragonNotePath: `Productivity Dragon/${bestMatch.title}.md`
      };
    }

    return undefined;
  }

  getQuests(): DragonQuest[] {
    return this.quests;
  }
}
