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
    this.baseURL = config.url.replace(/\/$/, "");
    this.authHeader =
      "Basic " +
      Buffer.from(`${config.email}:${config.apiKey}`).toString("base64");
  }

  private async request<T>(
    method: string,
    path: string,
    body?: Record<string, unknown>
  ): Promise<T> {
    const url = `${this.baseURL}/api/v1${path}`;
    const headers: Record<string, string> = {
      Authorization: this.authHeader,
    };

    const options: RequestInit = { method, headers };

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
    const result = await this.request<{ id: number }>("POST", "/messages", {
      type: "stream",
      to: stream,
      topic,
      content,
    });
    return result.id;
  }

  /** Edit an existing message (for streaming progress updates). */
  async editMessage(messageId: number, content: string): Promise<void> {
    await this.request("PATCH", `/messages/${messageId}`, { content });
  }

  /** Register an event queue for real-time events. */
  async registerEventQueue(eventTypes: string[]): Promise<EventQueue> {
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
    const params = new URLSearchParams({
      queue_id: queueId,
      last_event_id: lastEventId.toString(),
    });
    const result = await this.request<{ events: ZulipEvent[] }>(
      "GET",
      `/events?${params.toString()}`
    );
    return result.events;
  }
}
