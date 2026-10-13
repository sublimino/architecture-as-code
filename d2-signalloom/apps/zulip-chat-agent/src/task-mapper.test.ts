import { describe, expect, it } from "bun:test";
import { TaskMapper, MAX_SESSIONS, MAX_TASKS_PER_SESSION } from "./task-mapper";

describe("TaskMapper", () => {
  it("parses valid commands from mentions", () => {
    const mapper = new TaskMapper();
    const bot = "ZulipBot";

    const res1 = mapper.parseCommand("@**ZulipBot** scan cluster-a", bot);
    expect(res1).not.toBeNull();
    expect(res1?.command).toBe("scan");
    expect(res1?.args).toBe("cluster-a");

    const res2 = mapper.parseCommand("@ZulipBot help", bot);
    expect(res2).not.toBeNull();
    expect(res2?.command).toBe("help");
    expect(res2?.args).toBe("");

    const res3 = mapper.parseCommand("@**zulipbot** deploy staging --tag v1.0", bot);
    expect(res3).not.toBeNull();
    expect(res3?.command).toBe("deploy");
    expect(res3?.args).toBe("staging --tag v1.0");
  });

  it("returns null for non-mentions or unknown commands", () => {
    const mapper = new TaskMapper();
    const bot = "ZulipBot";

    expect(mapper.parseCommand("hello there", bot)).toBeNull();
    expect(mapper.parseCommand("@**ZulipBot** unknown-command", bot)).toBeNull();
  });

  it("manages session lifecycle and tasks", () => {
    const mapper = new TaskMapper();
    const session = mapper.getSession("incident-123", 42);

    expect(session.topic).toBe("incident-123");
    expect(session.streamId).toBe(42);
    expect(mapper.activeTasks(session).length).toBe(0);

    const task1 = mapper.createTask(session, "scan");
    expect(task1.id).toBe("task-000001");
    expect(task1.status).toBe("pending");
    expect(mapper.activeTasks(session).length).toBe(1);

    mapper.updateTask(task1, "running");
    expect(task1.status).toBe("running");
    expect(task1.completedAt).toBeUndefined();

    mapper.updateTask(task1, "completed", "all clear");
    expect(task1.status).toBe("completed");
    expect(task1.result).toBe("all clear");
    expect(task1.completedAt).toBeDefined();
    expect(mapper.activeTasks(session).length).toBe(0);
  });

  it("bounds sessions to MAX_SESSIONS and evicts oldest inactive session", () => {
    const mapper = new TaskMapper();

    // Fill up to MAX_SESSIONS
    for (let i = 0; i < MAX_SESSIONS; i++) {
      const s = mapper.getSession(`topic-${i}`, 1);
      // Give first session an old lastActivity
      if (i === 0) {
        s.lastActivity = new Date(Date.now() - 100000);
      }
    }
    expect(mapper.allSessions().length).toBe(MAX_SESSIONS);

    // Creating one more session triggers eviction of topic-0
    mapper.getSession("topic-overflow", 1);
    expect(mapper.allSessions().length).toBe(MAX_SESSIONS);

    // topic-0 should have been evicted
    const all = mapper.allSessions();
    expect(all.some((s) => s.topic === "topic-0")).toBe(false);
    expect(all.some((s) => s.topic === "topic-overflow")).toBe(true);
  });

  it("prunes inactive sessions older than maxAge", () => {
    const mapper = new TaskMapper();
    const oldSession = mapper.getSession("old-topic", 1);
    oldSession.lastActivity = new Date(Date.now() - 500000);

    const freshSession = mapper.getSession("fresh-topic", 1);

    const pruned = mapper.pruneInactiveSessions(300000); // 300s
    expect(pruned).toBe(1);
    expect(mapper.allSessions().length).toBe(1);
    expect(mapper.allSessions()[0].topic).toBe("fresh-topic");
  });

  it("bounds tasks per session to MAX_TASKS_PER_SESSION", () => {
    const mapper = new TaskMapper();
    const session = mapper.getSession("busy-topic", 1);

    for (let i = 0; i < MAX_TASKS_PER_SESSION + 15; i++) {
      const task = mapper.createTask(session, "status");
      if (i < 10) {
        mapper.updateTask(task, "completed", "done");
      }
    }

    expect(session.tasks.length).toBe(MAX_TASKS_PER_SESSION);
  });
});
