// Task mapper: maps incoming Zulip messages to tasks and tracks per-topic state.
//
// Each Zulip topic becomes a task session. Commands are extracted from
// @-mentions and dispatched to the appropriate handler.

export interface TaskSession {
  topic: string;
  streamId: number;
  tasks: TaskEntry[];
  createdAt: Date;
  lastActivity: Date;
}

export interface TaskEntry {
  id: string;
  command: string;
  status: "pending" | "running" | "completed" | "failed";
  messageId?: number;
  result?: string;
  createdAt: Date;
  completedAt?: Date;
}

// Supported commands the bot recognises from @-mentions.
const COMMANDS = [
  "scan",
  "audit",
  "deploy",
  "status",
  "help",
  "cancel",
] as const;

export type Command = (typeof COMMANDS)[number];

export class TaskMapper {
  private sessions = new Map<string, TaskSession>();
  private nextTaskId = 0;

  /** Get or create a session for a topic. */
  getSession(topic: string, streamId: number): TaskSession {
    const key = `${streamId}:${topic}`;
    let session = this.sessions.get(key);
    if (!session) {
      session = {
        topic,
        streamId,
        tasks: [],
        createdAt: new Date(),
        lastActivity: new Date(),
      };
      this.sessions.set(key, session);
    }
    session.lastActivity = new Date();
    return session;
  }

  /** Parse a command from a message content string. */
  parseCommand(content: string, botName: string): { command: Command; args: string } | null {
    // Look for @**botName** or @botName patterns.
    const mentionPattern = new RegExp(
      `@\\*\\*${escapeRegex(botName)}\\*\\*\\s+(.+)|@${escapeRegex(botName)}\\s+(.+)`,
      "i"
    );
    const match = content.match(mentionPattern);
    if (!match) return null;

    const commandStr = (match[1] || match[2] || "").trim();
    const parts = commandStr.split(/\s+/);
    const cmd = parts[0]?.toLowerCase();

    if (!isCommand(cmd)) return null;

    return {
      command: cmd,
      args: parts.slice(1).join(" "),
    };
  }

  /** Create a new task entry within a session. */
  createTask(session: TaskSession, command: string): TaskEntry {
    this.nextTaskId++;
    const task: TaskEntry = {
      id: `task-${String(this.nextTaskId).padStart(6, "0")}`,
      command,
      status: "pending",
      createdAt: new Date(),
    };
    session.tasks.push(task);
    return task;
  }

  /** Update a task's status and optionally its result. */
  updateTask(
    task: TaskEntry,
    status: TaskEntry["status"],
    result?: string
  ): void {
    task.status = status;
    if (result !== undefined) task.result = result;
    if (status === "completed" || status === "failed") {
      task.completedAt = new Date();
    }
  }

  /** Get active (non-terminal) tasks for a session. */
  activeTasks(session: TaskSession): TaskEntry[] {
    return session.tasks.filter(
      (t) => t.status === "pending" || t.status === "running"
    );
  }

  /** Get all sessions (for status reporting). */
  allSessions(): TaskSession[] {
    return Array.from(this.sessions.values());
  }
}

function isCommand(s: string | undefined): s is Command {
  return COMMANDS.includes(s as Command);
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
