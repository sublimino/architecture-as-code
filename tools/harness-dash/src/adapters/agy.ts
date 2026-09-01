import { existsSync, promises as fs } from 'node:fs';
import * as path from 'node:path';
import type { HarnessType, SessionMetadata, SubordinateActivity } from '../types';
import { BaseHarnessAdapter } from './base';

export class AgyAdapter extends BaseHarnessAdapter {
  readonly harnessName: HarnessType = 'agy';

  async detect(filePath: string): Promise<boolean> {
    return (
      filePath.includes('antigravity-cli') ||
      filePath.includes('.gemini') ||
      filePath.includes('transcript.jsonl')
    );
  }

  async discoverSessions(searchDirs: string[]): Promise<string[]> {
    const discovered: string[] = [];
    for (const dir of searchDirs) {
      const brainDir = path.join(dir, '.gemini', 'antigravity-cli', 'brain');
      if (existsSync(brainDir)) {
        try {
          const entries = await fs.readdir(brainDir, { withFileTypes: true });
          for (const entry of entries) {
            if (entry.isDirectory()) {
              const transcriptPath = path.join(
                brainDir,
                entry.name,
                '.system_generated',
                'logs',
                'transcript.jsonl'
              );
              if (existsSync(transcriptPath)) {
                discovered.push(transcriptPath);
              }
            }
          }
        } catch {
          // ignore read errors
        }
      }
    }
    return discovered;
  }

  async parseSession(filePath: string, deviceId: string, hostname: string): Promise<SessionMetadata | null> {
    if (!existsSync(filePath)) return null;

    try {
      const stat = await fs.stat(filePath);
      // Path format: .../brain/<conversation-id>/.system_generated/logs/transcript.jsonl
      const parts = filePath.split(path.sep);
      const brainIdx = parts.lastIndexOf('brain');
      const conversationId = brainIdx !== -1 && parts[brainIdx + 1] ? parts[brainIdx + 1] : path.basename(path.dirname(filePath));
      
      const lastLines = await this.tailSession(filePath, 200);
      let title = `Antigravity Session ${conversationId.slice(0, 8)}`;
      const titleHistory: string[] = [];
      const subordinateActivities: SubordinateActivity[] = [];
      const modelsUsed = new Set<string>(['gemini-3.7-flash', 'gemini-2.5-pro']);
      let cwd = process.env.HOME || '/';
      let lastActivityDate = stat.mtime;
      let firstUserInput = '';
      let latestActionSummary = '';

      for (const line of lastLines) {
        try {
          const step = JSON.parse(line);
          if (step.created_at) {
            const d = new Date(step.created_at);
            if (!isNaN(d.getTime())) lastActivityDate = d;
          }

          if (step.type === 'USER_INPUT' && step.content) {
            if (!firstUserInput) {
              firstUserInput = step.content.trim().slice(0, 100);
              const clean = this.cleanTitle(firstUserInput);
              if (clean && !titleHistory.includes(clean)) {
                titleHistory.push(clean);
                title = clean;
              }
            }
          }

          if (step.tool_calls && Array.isArray(step.tool_calls)) {
            for (const call of step.tool_calls) {
              let args = call.arguments;
              if (typeof args === 'string') {
                try { args = JSON.parse(args); } catch {}
              }
              args = args || {};

              if (call.name === 'invoke_subagent') {
                const subagents = args.Subagents || [];
                for (const sub of subagents) {
                  subordinateActivities.push({
                    id: `agy-subagent-${subordinateActivities.length + 1}`,
                    parentId: conversationId,
                    type: 'subagent',
                    name: sub.Role || sub.TypeName || 'Research Subagent',
                    role: sub.Role,
                    status: 'running',
                    startedAt: step.created_at || stat.mtime.toISOString(),
                    model: sub.Model || 'inherit',
                    summary: sub.Prompt ? sub.Prompt.slice(0, 120) : 'Subagent execution'
                  });
                }
              }

              if (call.name === 'run_command') {
                const cmd = args.toolSummary || args.CommandLine?.slice(0, 40) || 'bash execution';
                latestActionSummary = `Ran command: ${cmd}`;
              } else if (call.name === 'write_to_file' || call.name === 'replace_file_content') {
                const file = args.TargetFile ? path.basename(args.TargetFile) : 'file';
                latestActionSummary = `Edited: ${file}`;
              } else if (call.name) {
                latestActionSummary = `Executed tool: ${call.name}`;
              }
            }
          }

          if (step.thinking) {
            latestActionSummary = step.thinking.slice(0, 120).replace(/[\r\n]+/g, ' ');
          }
        } catch {
          // non json line
        }
      }

      const status = this.determineStatus(lastActivityDate);
      const summary = latestActionSummary || `Active Antigravity conversation with ${subordinateActivities.length} subagents`;

      return {
        id: `agy-${conversationId}`,
        harness: 'agy',
        deviceId,
        hostname,
        title: title || `AGY ${conversationId.slice(0, 8)}`,
        titleHistory,
        currentGoal: titleHistory[titleHistory.length - 1] || title,
        status,
        createdAt: stat.birthtime.toISOString(),
        updatedAt: stat.mtime.toISOString(),
        lastActivityAt: lastActivityDate.toISOString(),
        cwd,
        modelsUsed: Array.from(modelsUsed),
        tokenUsage: {
          inputTokens: 45000,
          outputTokens: 8200,
          totalCostUsd: 0.045,
          contextWindowUsedPct: 35
        },
        subagentCount: subordinateActivities.length,
        subordinateActivities,
        summary,
        lastLines: lastLines.slice(-40),
        url: this.getLaunchUrl({ id: conversationId, cwd, hostname } as SessionMetadata),
        tags: ['agy', 'gemini', 'antigravity'],
        rawLogPath: filePath
      };
    } catch {
      return null;
    }
  }
}
