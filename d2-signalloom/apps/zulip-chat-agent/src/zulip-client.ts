// Typed Zulip API client for the chat agent.
//
// Implements: send message, edit message, register event queue, poll events.
// Uses Zulip's REST API with basic auth (email + API key).

export interface ZulipConfig {
  url: string;
  email: string;
  apiKey: string;
}

export interface ZulipMessage {
  id: number;
  sender_id: number;
  sender_email: string;
  sender_full_name: string;
  type: "stream" | "private";
  stream_id?: number;
  subject: string;
  content: string;
  timestamp: number;
}

export interface ZulipEvent {
  type: string;
  id: number;
  message?: ZulipMessage;
}

export interface EventQueue {
  queue_id: string;
  last_event_id: number;
}

export class ZulipClient {
  private readonly baseURL: string;
  private readonly authHeader: string;

  constructor(private config: ZulipConfig) {
    if (!config || typeof config !== "object") {
      throw new TypeError("ZulipConfig must be a non-null object");
    }
    if (!config.url || typeof config.url !== "string" || !config.url.trim()) {
      throw new TypeError("ZulipConfig.url must be a non-empty string");
    }
    let parsed: URL;
    try {
      parsed = new URL(config.url);
    } catch {
      throw new TypeError(`Invalid Zulip URL: ${config.url}`);
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new TypeError(
        `Invalid Zulip URL protocol: ${parsed.protocol} (must be http: or https:)`
      );
    }
    if (!parsed.hostname) {
      throw new TypeError("Invalid Zulip URL: hostname must be non-empty");
    }

    if (!config.email || typeof config.email !== "string" || !config.email.trim()) {
      throw new TypeError("ZulipConfig.email must be a non-empty string");
    }
    if (/[\r\n\x00]/.test(config.email)) {
      throw new TypeError("ZulipConfig.email must not contain newlines or null bytes");
    }

    if (!config.apiKey || typeof config.apiKey !== "string" || !config.apiKey.trim()) {
      throw new TypeError("ZulipConfig.apiKey must be a non-empty string");
    }
    if (/[\r\n\x00]/.test(config.apiKey)) {
      throw new TypeError("ZulipConfig.apiKey must not contain newlines or null bytes");
    }

    this.baseURL = `${parsed.origin}${parsed.pathname}`.replace(/\/$/, "");
    this.authHeader =
      "Basic " +
      Buffer.from(`${config.email.trim()}:${config.apiKey.trim()}`).toString("base64");
  }

  private async request<T>(
    method: string,
    path: string,
    body?: Record<string, unknown>,
    timeoutMs: number = 15000
  ): Promise<T> {
    const url = `${this.baseURL}/api/v1${path}`;
    const headers: Record<string, string> = {
      Authorization: this.authHeader,
    };

    const options: RequestInit = {
      method,
      headers,
      signal: AbortSignal.timeout(timeoutMs),
    };

    if (body) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      const params = new URLSearchParams();
      for (const [key, value] of Object.entries(body)) {
        params.set(key, typeof value === "string" ? value : JSON.stringify(value));
      }
      options.body = params.toString();
    }

    const resp = await fetch(url, options);
    if (!resp.ok) {
      const text = await resp.text();
      throw new Error(`Zulip API ${method} ${path} returned ${resp.status}: ${text}`);
    }

    return resp.json() as Promise<T>;
  }

  /** Send a message to a stream topic. */
  async sendMessage(stream: string, topic: string, content: string): Promise<number> {
    if (!stream || typeof stream !== "string" || !stream.trim()) {
      throw new TypeError("stream must be a non-empty string");
    }
    if (!topic || typeof topic !== "string" || !topic.trim()) {
      throw new TypeError("topic must be a non-empty string");
    }
    if (typeof content !== "string") {
      throw new TypeError("content must be a string");
    }

    const result = await this.request<{ id: number }>("POST", "/messages", {
      type: "stream",
      to: stream.trim(),
      topic: topic.trim(),
      content,
    });
    return result.id;
  }

  /** Edit an existing message (for streaming progress updates). */
  async editMessage(messageId: number, content: string): Promise<void> {
    if (typeof messageId !== "number" || !Number.isSafeInteger(messageId) || messageId <= 0) {
      throw new TypeError(`Invalid messageId: ${messageId} (must be a strictly positive integer)`);
    }
    if (typeof content !== "string") {
      throw new TypeError("content must be a string");
    }

    await this.request("PATCH", `/messages/${messageId}`, { content });
  }

  /** Register an event queue for real-time events. */
  async registerEventQueue(eventTypes: string[]): Promise<EventQueue> {
    if (!Array.isArray(eventTypes)) {
      throw new TypeError("eventTypes must be an array of strings");
    }

    const result = await this.request<{
      queue_id: string;
      last_event_id: number;
    }>("POST", "/register", {
      event_types: eventTypes,
    });
    return {
      queue_id: result.queue_id,
      last_event_id: result.last_event_id,
    };
  }

  /** Long-poll for events from a registered queue. */
  async getEvents(queueId: string, lastEventId: number): Promise<ZulipEvent[]> {
    if (!queueId || typeof queueId !== "string" || !queueId.trim()) {
      throw new TypeError("queueId must be a non-empty string");
    }
    if (typeof lastEventId !== "number" || !Number.isSafeInteger(lastEventId) || lastEventId < -1) {
      throw new TypeError(`Invalid lastEventId: ${lastEventId} (must be a safe integer >= -1)`);
    }

    const params = new URLSearchParams({
      queue_id: queueId.trim(),
      last_event_id: lastEventId.toString(),
    });
    const result = await this.request<{ events: ZulipEvent[] }>(
      "GET",
      `/events?${params.toString()}`,
      undefined,
      90000
    );
    return result.events;
  }
}
