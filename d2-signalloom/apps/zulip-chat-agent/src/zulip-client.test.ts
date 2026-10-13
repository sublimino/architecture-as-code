import { describe, expect, it, mock, beforeEach, afterEach } from "bun:test";
import { ZulipClient } from "./zulip-client";

describe("ZulipClient", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  describe("Constructor Validation", () => {
    it("throws on null or non-object config", () => {
      // @ts-expect-error test invalid input
      expect(() => new ZulipClient(null)).toThrow("ZulipConfig must be a non-null object");
      // @ts-expect-error test invalid input
      expect(() => new ZulipClient("bad")).toThrow("ZulipConfig must be a non-null object");
    });

    it("throws on empty or missing URL", () => {
      expect(() => new ZulipClient({ url: "", email: "a@b.com", apiKey: "key" })).toThrow(
        "ZulipConfig.url must be a non-empty string"
      );
      expect(() => new ZulipClient({ url: "   ", email: "a@b.com", apiKey: "key" })).toThrow(
        "ZulipConfig.url must be a non-empty string"
      );
    });

    it("throws on invalid URL protocol or unparseable URL", () => {
      expect(() => new ZulipClient({ url: "not-a-url", email: "a@b.com", apiKey: "key" })).toThrow(
        "Invalid Zulip URL"
      );
      expect(() => new ZulipClient({ url: "ftp://zulip.example.com", email: "a@b.com", apiKey: "key" })).toThrow(
        "Invalid Zulip URL protocol"
      );
      expect(() => new ZulipClient({ url: "javascript:alert(1)", email: "a@b.com", apiKey: "key" })).toThrow(
        "Invalid Zulip URL protocol"
      );
      expect(() => new ZulipClient({ url: "file:///etc/passwd", email: "a@b.com", apiKey: "key" })).toThrow(
        "Invalid Zulip URL protocol"
      );
    });

    it("throws on missing or invalid email", () => {
      expect(() => new ZulipClient({ url: "https://zulip.example.com", email: "", apiKey: "key" })).toThrow(
        "ZulipConfig.email must be a non-empty string"
      );
      expect(() => new ZulipClient({ url: "https://zulip.example.com", email: "a@b.com\r\nInjected: Header", apiKey: "key" })).toThrow(
        "ZulipConfig.email must not contain newlines or null bytes"
      );
    });

    it("throws on missing or invalid apiKey", () => {
      expect(() => new ZulipClient({ url: "https://zulip.example.com", email: "a@b.com", apiKey: "" })).toThrow(
        "ZulipConfig.apiKey must be a non-empty string"
      );
      expect(() => new ZulipClient({ url: "https://zulip.example.com", email: "a@b.com", apiKey: "key\n" })).toThrow(
        "ZulipConfig.apiKey must not contain newlines or null bytes"
      );
    });

    it("creates instance with valid parameters", () => {
      const client = new ZulipClient({
        url: "https://zulip.example.com/",
        email: "bot@example.com",
        apiKey: "secret-token",
      });
      expect(client).toBeDefined();
    });
  });

  describe("sendMessage", () => {
    it("validates stream and topic strings", async () => {
      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      expect(client.sendMessage("", "topic", "hello")).rejects.toThrow("stream must be a non-empty string");
      expect(client.sendMessage("stream", "", "hello")).rejects.toThrow("topic must be a non-empty string");
      // @ts-expect-error invalid content type
      expect(client.sendMessage("stream", "topic", null)).rejects.toThrow("content must be a string");
    });

    it("successfully sends message and returns ID", async () => {
      globalThis.fetch = mock(async () => {
        return new Response(JSON.stringify({ result: "success", id: 1042 }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      });

      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      const id = await client.sendMessage("dev-stream", "status-check", "All systems nominal");
      expect(id).toBe(1042);
    });
  });

  describe("editMessage", () => {
    it("validates messageId is strictly positive safe integer", async () => {
      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      expect(client.editMessage(0, "content")).rejects.toThrow("Invalid messageId");
      expect(client.editMessage(-1, "content")).rejects.toThrow("Invalid messageId");
      expect(client.editMessage(NaN, "content")).rejects.toThrow("Invalid messageId");
      expect(client.editMessage(Infinity, "content")).rejects.toThrow("Invalid messageId");
      expect(client.editMessage(1.5, "content")).rejects.toThrow("Invalid messageId");
      // @ts-expect-error invalid content type
      expect(client.editMessage(10, null)).rejects.toThrow("content must be a string");
    });

    it("successfully sends PATCH for valid messageId", async () => {
      let capturedMethod = "";
      let capturedUrl = "";

      globalThis.fetch = mock(async (reqOrUrl, options) => {
        capturedMethod = options?.method ?? "";
        capturedUrl = String(reqOrUrl);
        return new Response(JSON.stringify({ result: "success" }), { status: 200 });
      });

      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      await client.editMessage(1042, "Updated progress: 50%");
      expect(capturedMethod).toBe("PATCH");
      expect(capturedUrl).toBe("https://zulip.example.com/api/v1/messages/1042");
    });
  });

  describe("registerEventQueue and getEvents", () => {
    it("validates eventTypes array", async () => {
      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });
      // @ts-expect-error invalid eventTypes
      expect(client.registerEventQueue(null)).rejects.toThrow("eventTypes must be an array of strings");
    });

    it("registers event queue successfully", async () => {
      globalThis.fetch = mock(async () => {
        return new Response(
          JSON.stringify({
            result: "success",
            queue_id: "q-12345",
            last_event_id: 50,
          }),
          { status: 200 }
        );
      });

      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      const q = await client.registerEventQueue(["message"]);
      expect(q.queue_id).toBe("q-12345");
      expect(q.last_event_id).toBe(50);
    });

    it("validates queueId and lastEventId in getEvents", async () => {
      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      expect(client.getEvents("", 0)).rejects.toThrow("queueId must be a non-empty string");
      expect(client.getEvents("q-1", -2)).rejects.toThrow("Invalid lastEventId");
      expect(client.getEvents("q-1", NaN)).rejects.toThrow("Invalid lastEventId");
      expect(client.getEvents("q-1", Infinity)).rejects.toThrow("Invalid lastEventId");
    });

    it("polls events with safe parameters", async () => {
      globalThis.fetch = mock(async () => {
        return new Response(
          JSON.stringify({
            result: "success",
            events: [
              {
                type: "message",
                id: 51,
                message: { id: 200, type: "stream", subject: "test", content: "hi" },
              },
            ],
          }),
          { status: 200 }
        );
      });

      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      const events = await client.getEvents("q-12345", -1);
      expect(events.length).toBe(1);
      expect(events[0].id).toBe(51);
    });
  });

  describe("Error Handling", () => {
    it("throws descriptive error when server returns non-ok status", async () => {
      globalThis.fetch = mock(async () => {
        return new Response("Unauthorized request", { status: 401 });
      });

      const client = new ZulipClient({
        url: "https://zulip.example.com",
        email: "bot@example.com",
        apiKey: "token",
      });

      expect(client.sendMessage("stream", "topic", "hello")).rejects.toThrow(
        "Zulip API POST /messages returned 401: Unauthorized request"
      );
    });
  });
});
