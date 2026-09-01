import { existsSync, readFileSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { SessionMetadata, SummaryInfo, SummaryModelTier } from '../types';

export class SessionSummarizer {
  private cerebrasApiKey?: string;

  constructor() {
    this.cerebrasApiKey = this.resolveCerebrasApiKey();
  }

  private resolveCerebrasApiKey(): string | undefined {
    if (process.env.CEREBRAS_API_KEY && process.env.CEREBRAS_API_KEY.trim().length > 0) {
      return process.env.CEREBRAS_API_KEY.trim();
    }
    const envPath = path.join(os.homedir(), '.hermes', '.env');
    if (existsSync(envPath)) {
      try {
        const content = readFileSync(envPath, 'utf-8');
        const match = content.match(/CEREBRAS_API_KEY=([^\r\n]+)/);
        if (match && match[1]) {
          return match[1].trim();
        }
      } catch {
        // ignore
      }
    }
    return undefined;
  }

  /**
   * Fast extractive summarizer for session tails (0ms latency fallback)
   */
  summarize(lastLines: string[], defaultTitle?: string): string {
    if (!lastLines || lastLines.length === 0) {
      return defaultTitle ? `Session: ${defaultTitle}` : 'Empty session';
    }

    const toolActions: string[] = [];
    const filesModified: string[] = [];
    const errors: string[] = [];
    let latestGoal = '';

    for (const rawLine of lastLines) {
      const line = rawLine.trim();
      if (!line) continue;

      try {
        const obj = JSON.parse(line);
        // Extract Claude / AGY / OpenAI format properties
        if (obj.tool_calls && Array.isArray(obj.tool_calls)) {
          for (const call of obj.tool_calls) {
            const name = call.name || 'tool';
            const target = call.arguments?.TargetFile || call.arguments?.CommandLine || call.arguments?.toolSummary;
            if (target) toolActions.push(`${name}: ${String(target).slice(0, 40)}`);
          }
        }
        if (obj.type === 'tool_use') {
          const name = obj.name || 'tool';
          const file = obj.input?.target_file || obj.input?.path || obj.input?.command;
          if (file) toolActions.push(`${name}: ${String(file).slice(0, 40)}`);
        }
        if (obj.type === 'USER_INPUT' || obj.role === 'user') {
          latestGoal = typeof obj.content === 'string' ? obj.content.slice(0, 80) : '';
        }
        if (obj.error || (obj.status && obj.status === 'ERROR')) {
          errors.push(obj.error?.message || 'Error occurred');
        }
      } catch {
        // Plain text lines
        if (line.toLowerCase().includes('error:') || line.toLowerCase().includes('failed:')) {
          errors.push(line.slice(0, 80));
        } else if (line.startsWith('$ ') || line.startsWith('Running ')) {
          toolActions.push(line.slice(0, 50));
        }
      }
    }

    if (errors.length > 0) {
      return `⚠️ Blocker: ${errors[errors.length - 1]} | Recent: ${toolActions.slice(-2).join(' → ') || 'Investigating'}`;
    }

    if (toolActions.length > 0) {
      const uniqueActions = Array.from(new Set(toolActions)).slice(-3);
      return `Executed: ${uniqueActions.join(' → ')}`;
    }

    if (latestGoal) {
      return `Targeting: ${latestGoal}`;
    }

    return defaultTitle || 'Active AI session';
  }

  /**
   * Smart router for AI summaries:
   * - Small payloads (<10 KB) on hot path -> Gemma 4 at Cerebras ($$$ • ~15ms)
   * - Background / larger payloads -> Gemini 2.5 Flash via aichat ($ • budget & high quality)
   */
  async summarizeSmart(session: SessionMetadata, isHotPath: boolean = false): Promise<SummaryInfo> {
    const rawContext = (session.lastLines || []).join('\n');
    const payloadSize = Buffer.byteLength(rawContext, 'utf-8');

    if (isHotPath && payloadSize < 10 * 1024) {
      try {
        return await this.summarizeWithModel(session, 'gemma-4-cerebras');
      } catch {
        return await this.summarizeWithModel(session, 'gemini-2.5-flash');
      }
    }

    return await this.summarizeWithModel(session, 'gemini-2.5-flash');
  }

  /**
   * Executes summarization with a specifically requested model tier
   */
  async summarizeWithModel(session: SessionMetadata, model: SummaryModelTier): Promise<SummaryInfo> {
    const start = Date.now();
    const rawContext = (session.lastLines || []).join('\n');
    const payloadSize = Buffer.byteLength(rawContext, 'utf-8');
    const prompt = `Session Title: "${session.title}" (Harness: ${session.harness}, Dir: ${session.cwd})\nRecent Log Snippet:\n${rawContext.slice(-3500)}`;

    if (model === 'gemma-4-cerebras') {
      try {
        const text = await this.runCerebrasGemma4(prompt);
        const latencyMs = Date.now() - start;
        return {
          text,
          model: 'gemma-4-cerebras',
          modelLabel: 'Gemma 4 (Cerebras WSE)',
          costTier: '$$$',
          latencyMs,
          generatedAt: new Date().toISOString(),
          prompt,
          payloadSize
        };
      } catch (err: any) {
        console.warn(`[Summarizer] Cerebras Gemma 4 failed: ${err.message}, falling back to Gemini 2.5 Flash`);
      }
    }

    if (model === 'antigravity') {
      try {
        const text = await this.runAntigravity(prompt);
        const latencyMs = Date.now() - start;
        return {
          text,
          model: 'antigravity',
          modelLabel: 'Antigravity Pro',
          costTier: '$$',
          latencyMs,
          generatedAt: new Date().toISOString(),
          prompt,
          payloadSize
        };
      } catch (err: any) {
        console.warn(`[Summarizer] Antigravity model failed: ${err.message}, falling back to Gemini 2.5 Flash`);
      }
    }

    if (model === 'gemini-2.5-flash') {
      try {
        const text = await this.runGeminiFlash25(prompt);
        const latencyMs = Date.now() - start;
        return {
          text,
          model: 'gemini-2.5-flash',
          modelLabel: 'Gemini 2.5 Flash',
          costTier: '$',
          latencyMs,
          generatedAt: new Date().toISOString(),
          prompt,
          payloadSize
        };
      } catch (err: any) {
        console.warn(`[Summarizer] Gemini 2.5 Flash failed: ${err.message}, falling back to extractive`);
      }
    }

    // Extractive fallback
    const extractive = this.summarize(session.lastLines, session.title);
    return {
      text: extractive,
      model: 'extractive',
      modelLabel: 'Extractive Heuristic',
      costTier: '$',
      latencyMs: Date.now() - start,
      generatedAt: new Date().toISOString(),
      prompt,
      payloadSize
    };
  }

  /**
   * Cerebras WSE Ultra-Fast Inference (<20ms) with Gemma 4
   */
  private async runCerebrasGemma4(prompt: string): Promise<string> {
    const apiKey = this.cerebrasApiKey || this.resolveCerebrasApiKey();
    if (!apiKey) {
      throw new Error('CEREBRAS_API_KEY not found in environment or ~/.hermes/.env');
    }

    const res = await fetch('https://api.cerebras.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: 'gemma-4-31b',
        messages: [
          {
            role: 'system',
            content: 'You are a high-signal AI engineering summarizer. Output a concise 1-2 sentence summary of the session: the core goal, major actions executed, and current status. Be direct and avoid boilerplate.'
          },
          {
            role: 'user',
            content: prompt
          }
        ],
        max_tokens: 150,
        temperature: 0.2
      })
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Cerebras API returned ${res.status}: ${errText}`);
    }

    const data: any = await res.json();
    const content = data.choices?.[0]?.message?.content?.trim();
    if (!content) {
      throw new Error('Empty response from Cerebras Gemma 4');
    }
    return content;
  }

  /**
   * Gemini 2.5 Flash via aichat (very cheap, good quality for background tasks)
   */
  private async runGeminiFlash25(prompt: string): Promise<string> {
    const proc = Bun.spawn([
      'aichat',
      '--no-stream',
      '-m',
      'gemini-flash-2.5',
      `Summarize this AI coding session in 1-2 concise sentences (focus on goal, actions, status):\n\n${prompt}`
    ], {
      stdout: 'pipe',
      stderr: 'pipe'
    });

    const output = await new Response(proc.stdout).text();
    const cleanOutput = output
      .replace(/[\u2800-\u28FF\s]*Generating[.\s]*/g, '')
      .replace(/^['"]|['"]$/g, '')
      .trim();

    if (!cleanOutput || cleanOutput.length < 5) {
      throw new Error('aichat gemini-flash-2.5 returned empty output');
    }
    return cleanOutput;
  }

  /**
   * Antigravity / Gemini Pro via aichat (deep analysis and reasoning)
   */
  private async runAntigravity(prompt: string): Promise<string> {
    const proc = Bun.spawn([
      'aichat',
      '--no-stream',
      '-m',
      'gemini-pro',
      `Perform a deep synthesis and summarize this AI agent session in 1-2 precise engineering sentences:\n\n${prompt}`
    ], {
      stdout: 'pipe',
      stderr: 'pipe'
    });

    const output = await new Response(proc.stdout).text();
    const cleanOutput = output
      .replace(/[\u2800-\u28FF\s]*Generating[.\s]*/g, '')
      .replace(/^['"]|['"]$/g, '')
      .trim();

    if (!cleanOutput || cleanOutput.length < 5) {
      throw new Error('aichat gemini-pro returned empty output');
    }
    return cleanOutput;
  }

  /**
   * Generates a condensed high-level markdown card suitable for Obsidian or Productivity Dragon
   */
  generateMarkdownCard(session: SessionMetadata): string {
    const modelTag = session.summaryInfo 
      ? ` [Model: ${session.summaryInfo.modelLabel} (${session.summaryInfo.costTier})]`
      : '';

    const lines: string[] = [
      `### [[${session.title}]]`,
      `- **Harness**: \`${session.harness}\` | **Device**: \`${session.deviceId}\` (\`${session.hostname}\`)`,
      `- **Status**: ${session.status.toUpperCase()} | **Last Activity**: ${new Date(session.lastActivityAt).toLocaleString()}`,
      `- **CWD**: \`${session.cwd}\` ${session.gitBranch ? `(git: \`${session.gitBranch}\`)` : ''}`,
      `- **Tokens**: ${session.tokenUsage.inputTokens.toLocaleString()} in / ${session.tokenUsage.outputTokens.toLocaleString()} out ($${session.tokenUsage.totalCostUsd})`,
      `- **AI Summary**${modelTag}: ${session.summary}`
    ];

    if (session.subordinateActivities.length > 0) {
      lines.push(`- **Subordinates & Forks (${session.subordinateActivities.length})**:`);
      for (const sub of session.subordinateActivities) {
        lines.push(`  - [${sub.type.toUpperCase()}] **${sub.name}** — ${sub.summary || sub.status}`);
      }
    }

    if (session.productivityDragon) {
      lines.push(`- **Productivity Dragon**: [[${session.productivityDragon.questTitle || 'Quest'}]] (+${session.productivityDragon.xpEarned || 10} XP)`);
    }

    lines.push(`- **Deep Link**: [Resume Session](${session.url})\n`);
    return lines.join('\n');
  }
}
