// zulip-chat-agent: Interactive ChatOps bot for Zulip.
//
// Joins a Zulip stream, receives task commands via @-mentions, maps tasks
// to Zulip topics, and streams execution progress via in-place message editing.
//
// Long-running, multi-turn conversational. Maintains session state per topic.

import { ZulipClient, type ZulipMessage } from "./zulip-client";
import { TaskMapper, type Command } from "./task-mapper";

const BOT_NAME = process.env.ZULIP_BOT_NAME ?? "swarm-bot";
const ZULIP_URL = process.env.ZULIP_URL ?? "";
const ZULIP_EMAIL = process.env.ZULIP_EMAIL ?? "";
const ZULIP_API_KEY = process.env.ZULIP_API_KEY ?? "";
const ZULIP_STREAM = process.env.ZULIP_STREAM ?? "cpai-swarms";
const POLL_INTERVAL_MS = 1000;

if (!ZULIP_URL || !ZULIP_EMAIL || !ZULIP_API_KEY) {
  console.error(
    "Missing required env vars: ZULIP_URL, ZULIP_EMAIL, ZULIP_API_KEY"
  );
  process.exit(1);
}

const client = new ZulipClient({
  url: ZULIP_URL,
  email: ZULIP_EMAIL,
  apiKey: ZULIP_API_KEY,
});

const mapper = new TaskMapper();

/** Handle an incoming message from the event stream. */
async function handleMessage(msg: ZulipMessage): Promise<void> {
  // Ignore our own messages.
  if (msg.sender_email === ZULIP_EMAIL) return;

  // Only process stream messages in our stream.
  if (msg.type !== "stream") return;

  const parsed = mapper.parseCommand(msg.content, BOT_NAME);
  if (!parsed) return;

  const session = mapper.getSession(msg.subject, msg.stream_id ?? 0);
  const task = mapper.createTask(session, parsed.command);

  console.log(
    `[${task.id}] command=${parsed.command} args="${parsed.args}" topic="${msg.subject}"`
  );

  // Send initial acknowledgement.
  const ackId = await client.sendMessage(
    ZULIP_STREAM,
    msg.subject,
    formatTaskStart(task.id, parsed.command, parsed.args)
  );
  task.messageId = ackId;
  mapper.updateTask(task, "running");

  // Simulate task execution with progress updates.
  try {
    const result = await executeCommand(parsed.command, parsed.args, async (progress: string) => {
      // Edit the message in-place to show progress.
      await client.editMessage(
        ackId,
        formatTaskProgress(task.id, parsed.command, progress)
      );
    });

    mapper.updateTask(task, "completed", result);
    await client.editMessage(
      ackId,
      formatTaskComplete(task.id, parsed.command, result)
    );
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    mapper.updateTask(task, "failed", errMsg);
    await client.editMessage(
      ackId,
      formatTaskFailed(task.id, parsed.command, errMsg)
    );
  }
}

/** Execute a command and report progress. */
async function executeCommand(
  command: Command,
  args: string,
  onProgress: (progress: string) => Promise<void>
): Promise<string> {
  switch (command) {
    case "help":
      return [
        "**Available commands:**",
        "- `scan <target>` — Scan a target for vulnerabilities",
        "- `audit <scope>` — Run security audit",
        "- `deploy <env>` — Trigger deployment pipeline",
        "- `status` — Show active tasks",
        "- `cancel` — Cancel running tasks",
        "- `help` — Show this help",
      ].join("\n");

    case "status": {
      const sessions = mapper.allSessions();
      const lines = sessions.map((s) => {
        const active = mapper.activeTasks(s);
        return `- **${s.topic}**: ${active.length} active, ${s.tasks.length} total`;
      });
      return lines.length > 0 ? lines.join("\n") : "No active sessions.";
    }

    case "scan":
      await onProgress("Discovering targets...");
      await sleep(1000);
      await onProgress("Scanning for CVEs...");
      await sleep(1500);
      await onProgress("Correlating findings...");
      await sleep(1000);
      return `Scan complete for \`${args || "default"}\`. Found **3** high, **7** medium, **12** low vulnerabilities.`;

    case "audit":
      await onProgress("Initialising audit scope...");
      await sleep(1000);
      await onProgress("Checking RBAC policies...");
      await sleep(1500);
      await onProgress("Checking network policies...");
      await sleep(1500);
      await onProgress("Checking supply chain attestations...");
      await sleep(1000);
      return `Audit complete for \`${args || "cluster"}\`. **2** critical findings, **5** warnings.`;

    case "deploy":
      await onProgress("Validating deployment manifest...");
      await sleep(1000);
      await onProgress("Requesting approval from deploy gate...");
      await sleep(2000);
      return `Deployment to \`${args || "staging"}\` queued. Awaiting HITL approval.`;

    case "cancel": {
      const session = mapper.allSessions().find((s) =>
        mapper.activeTasks(s).length > 0
      );
      if (!session) return "No active tasks to cancel.";
      const active = mapper.activeTasks(session);
      for (const t of active) {
        mapper.updateTask(t, "failed", "Cancelled by user");
      }
      return `Cancelled ${active.length} task(s).`;
    }

    default:
      return `Unknown command: \`${command}\``;
  }
}

function formatTaskStart(id: string, cmd: string, args: string): string {
  return `:robot: **Task ${id}** | \`${cmd}${args ? " " + args : ""}\`\n:hourglass: Starting...`;
}

function formatTaskProgress(id: string, cmd: string, progress: string): string {
  return `:robot: **Task ${id}** | \`${cmd}\`\n:arrows_counterclockwise: ${progress}`;
}

function formatTaskComplete(id: string, cmd: string, result: string): string {
  return `:robot: **Task ${id}** | \`${cmd}\` :white_check_mark:\n\n${result}`;
}

function formatTaskFailed(id: string, cmd: string, error: string): string {
  return `:robot: **Task ${id}** | \`${cmd}\` :x:\n\n**Error:** ${error}`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Main event loop: register queue, long-poll for events. */
async function main(): Promise<void> {
  console.log(`zulip-chat-agent starting — stream=${ZULIP_STREAM} bot=${BOT_NAME}`);

  let running = true;
  const shutdown = () => {
    console.log("Shutting down...");
    running = false;
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  let queue: { queue_id: string; last_event_id: number } | null = null;
  while (running && !queue) {
    try {
      queue = await client.registerEventQueue(["message"]);
      console.log(`Event queue registered: ${queue.queue_id}`);
    } catch (err) {
      console.error("Initial connection to Zulip failed, retrying in 10s:", err);
      await sleep(10000);
    }
  }

  if (!running || !queue) return;
  let lastEventId = queue.last_event_id;

  while (running) {
    try {
      const events = await client.getEvents(queue.queue_id, lastEventId);
      for (const event of events) {
        lastEventId = event.id;
        if (event.type === "message" && event.message) {
          await handleMessage(event.message);
        }
      }
    } catch (err) {
      console.error("Event poll error:", err);
      // Back off on error, then re-register.
      await sleep(5000);
      try {
        const newQueue = await client.registerEventQueue(["message"]);
        lastEventId = newQueue.last_event_id;
        console.log(`Re-registered event queue: ${newQueue.queue_id}`);
      } catch (reErr) {
        console.error("Failed to re-register queue:", reErr);
        await sleep(POLL_INTERVAL_MS * 10);
      }
    }
  }

  console.log("Stopped.");
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
