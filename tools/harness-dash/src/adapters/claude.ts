import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata, SubordinateActivity } from '../types';
import { BaseHarnessAdapter } from './base';

export class ClaudeAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'claude';

  async detect(filePath: string): Promise<boolean> {
    return filePath.includes('.claude') || filePath.endsWith('history.jsonl') || filePath.includes('projects');
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const claudeProjects = path.join(dir, '.claude', 'projects');
      if (existsSync(claudeProjects)) {
        try {
          const entries = await fs.readdir(claudeProjects, { withFileTypes: true });
          for (const entry of entries) {
            if (entry.isDirectory()) {
              const projectDir = path.join(claudeProjects, entry.name);
              const sessionFiles = await fs.readdir(projectDir);
              for (const f of sessionFiles) {
                if (f.endsWith('.jsonl') || f.endsWith('.json')) {
                  discovered.push(path.join(projectDir, f));
                }
              }
            }
          }
        } catch {
          // ignore read errors
        }
      }

      const claudeHistory = path.join(dir, '.claude', 'history.jsonl');
      if (existsSync(claudeHistory)) {
        discovered.push(claudeHistory);
      }
    }
    return discovered;
  }

  async parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null> {
    if (!existsSync(filePath)) return null;

    try {
      const stat = await fs.stat(filePath);
      const sessionId = path.basename(filePath, path.extname(filePath));
      const lastLines = await this.tailSession(filePath, 150);
      
      let title = `Claude Session ${sessionId.slice(0, 8)}`;
      const titleHistory: string[] = [];
      const subordinateActivities: SubordinateActivity[] = [];
      const modelsUsed = new Set<string>(['claude-3-7-sonnet', 'claude-3-5-sonnet']);
      let cwd = process.env.HOME || '/';
      let gitBranch: string | undefined;
      let lastActivityDate = stat.mtime;
      let inputTokens = 0;
      let outputTokens = 0;
      let totalCostUsd = 0;
      let summary = 'Active Claude session working on codebase tasks';

      for (const line of lastLines) {
        try {
          const parsed = JSON.parse(line);

          // 1. Title / User Prompt extraction across Claude Code formats
          let rawPrompt = '';
          if (parsed.title || parsed.session_name || parsed.custom_title) {
            rawPrompt = parsed.title || parsed.session_name || parsed.custom_title;
          } else if (parsed.type === 'last-prompt' && parsed.lastPrompt) {
            rawPrompt = parsed.lastPrompt;
          } else if (parsed.display && typeof parsed.display === 'string' && !parsed.display.startsWith('--') && !parsed.display.startsWith('/')) {
            rawPrompt = parsed.display;
          } else if (parsed.prompt && typeof parsed.prompt === 'string') {
            rawPrompt = parsed.prompt;
          } else if (parsed.type === 'user' || parsed.message?.role === 'user' || parsed.role === 'user') {
            const content = parsed.message?.content || parsed.content;
            if (typeof content === 'string') {
              rawPrompt = content;
            } else if (Array.isArray(content)) {
              const textBlock = content.find((c: any) => c.type === 'text' || typeof c === 'string');
              if (textBlock) {
                rawPrompt = typeof textBlock === 'string' ? textBlock : textBlock.text || '';
              }
            }
          }

          if (rawPrompt) {
            const clean = this.cleanTitle(rawPrompt);
            if (clean && clean.length > 3 && !clean.startsWith('--') && !clean.startsWith('@PAI') && !titleHistory.includes(clean)) {
              titleHistory.push(clean);
              title = clean;
            }
          }

          if (parsed.cwd) cwd = parsed.cwd;
          if (parsed.gitBranch) gitBranch = parsed.gitBranch;
          if (parsed.model) modelsUsed.add(parsed.model);
          if (parsed.timestamp) {
            const d = new Date(parsed.timestamp);
            if (!isNaN(d.getTime())) lastActivityDate = d;
          }

          // Detect subagents / tasks / tool calls
          if (parsed.type === 'tool_use' && parsed.name === 'Agent') {
            subordinateActivities.push({
              id: `claude-subagent-${subordinateActivities.length + 1}`,
              parentId: sessionId,
              type: 'subagent',
              name: parsed.input?.role || 'Subagent',
              role: parsed.input?.role,
              status: 'completed',
              startedAt: parsed.timestamp || stat.mtime.toISOString(),
              summary: parsed.input?.prompt?.slice(0, 100) || 'Delegated agent task'
            });
          }

          if (parsed.usage) {
            inputTokens += parsed.usage.input_tokens || 0;
            outputTokens += parsed.usage.output_tokens || 0;
          }
        } catch {
          // not json line
        }
      }

      // If no explicit prompt in tail, synthesize from workspace project & git branch
      const projectName = path.basename(cwd);
      if (title.startsWith('Claude Session') && projectName && projectName !== '.' && projectName !== '/' && projectName !== 'andy') {
        title = gitBranch && gitBranch !== 'HEAD' ? `${projectName} [${gitBranch}]` : projectName;
      }

      totalCostUsd = (inputTokens * 0.000003) + (outputTokens * 0.000015);

      const status = this.determineStatus(lastActivityDate);

      return {
        id: `claude-${sessionId}`,
        harness: 'claude',
        deviceId,
        hostname,
        title,
        titleHistory,
        currentGoal: titleHistory[titleHistory.length - 1] || title,
        status,
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: lastActivityDate.toISOString(),
        cwd,
        gitBranch,
        gitRepo: path.basename(cwd),
        modelsUsed: Array.from(modelsUsed),
        tokenUsage: {
          inputTokens,
          outputTokens,
          totalCostUsd: Number(totalCostUsd.toFixed(4)),
          contextWindowUsedPct: Math.min(100, Math.round((inputTokens / 200000) * 100))
        },
        subagentCount: subordinateActivities.length,
        subordinateActivities,
        summary,
        lastLines: lastLines.slice(-50),
        url: this.getLaunchUrl({ id: sessionId, cwd, hostname } as SessionMetadata),
        tags: ['claude', 'anthropic', path.basename(cwd)],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }
}
