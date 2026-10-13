#!/usr/bin/env bun
// d2-signalloom/test/fixtures/a2a-conformance-server.ts
//
// A minimal server speaking the subset of the A2A surface that kagent's
// controller exposes, so scripts/kagent-invoke.sh can be exercised against real
// HTTP — real curl, a real socket, a real port — rather than only against a
// stubbed curl binary.
//
// The stub in kagent-invoke.bats proves the script's logic. It cannot prove the
// script talks HTTP correctly, because the stub is not HTTP. This closes that
// gap. What neither can prove is that kagent's controller behaves this way; the
// shapes below are transcribed from upstream's own documented responses
// (kagent.dev/docs/kagent/examples/a2a-agents), not invented.
//
// Routes:
//   GET  /api/a2a/:namespace/:agent/.well-known/agent.json  -> agent card
//   POST /api/a2a/:namespace/:agent/                        -> JSON-RPC
//
// The scenario is selected by the A2A_SCENARIO env var, so one server covers
// every response shape the script must distinguish.
//
// Usage: A2A_SCENARIO=ok A2A_PORT=18099 bun a2a-conformance-server.ts

const port = Number(process.env.A2A_PORT ?? 18099);
const scenario = process.env.A2A_SCENARIO ?? "ok";

const card = {
  name: "kagent_k8s_reader",
  description: "Reads Kubernetes resources for cluster state queries",
  url: `http://127.0.0.1:${port}/api/a2a/fe-signalloom-agents/kagent-k8s-reader/`,
  version: "0.9.9",
  capabilities: { streaming: true, pushNotifications: false, stateTransitionHistory: true },
  defaultInputModes: ["text"],
  defaultOutputModes: ["text"],
  skills: [],
};

// Every shape below is a distinct failure mode that arrives as HTTP 200 and is
// only distinguishable by inspecting the body.
function reply(id: string, echoed: string): { status: number; body: unknown } {
  switch (scenario) {
    case "ok":
      return {
        status: 200,
        body: {
          jsonrpc: "2.0",
          id,
          result: {
            status: { state: "completed" },
            artifacts: [{ artifactId: "a1", parts: [{ kind: "text", text: `ECHO:${echoed}` }] }],
          },
        },
      };
    case "status-message":
      return {
        status: 200,
        body: {
          jsonrpc: "2.0",
          id,
          result: {
            status: {
              state: "completed",
              message: { role: "agent", parts: [{ kind: "text", text: `ECHO:${echoed}` }] },
            },
          },
        },
      };
    case "rpc-error":
      return {
        status: 200,
        body: {
          jsonrpc: "2.0",
          id,
          error: { code: -32603, message: "model call failed: invalid x-api-key" },
        },
      };
    case "task-failed":
      return {
        status: 200,
        body: {
          jsonrpc: "2.0",
          id,
          result: {
            status: {
              state: "failed",
              message: { role: "agent", parts: [{ kind: "text", text: "authentication_error" }] },
            },
          },
        },
      };
    case "empty-completed":
      return { status: 200, body: { jsonrpc: "2.0", id, result: { status: { state: "completed" } } } };
    case "html-200":
      return { status: 200, body: "<html><body>502 Bad Gateway</body></html>" };
    case "http-503":
      return { status: 503, body: "upstream connect error" };
    default:
      return { status: 500, body: { error: `unknown scenario ${scenario}` } };
  }
}

function jsonReply(req: Request, data: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  const headers = { "content-type": "application/json", ...extraHeaders };
  if (req.method === "HEAD") {
    return new Response(null, { status, headers });
  }
  return new Response(JSON.stringify(data), { status, headers });
}

function methodNotAllowed(req: Request, allow: string): Response {
  return jsonReply(req, { error: "Method Not Allowed" }, 405, { Allow: allow });
}

const server = Bun.serve({
  port,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname.endsWith("/.well-known/agent.json")) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        return methodNotAllowed(req, "GET, HEAD");
      }
      if (scenario === "no-card") {
        return jsonReply(req, { error: "not found" }, 404);
      }
      return jsonReply(req, card, 200);
    }

    // Match the documented prefix exactly. A server that answered any path
    // would let a malformed URL in the script pass unnoticed.
    const m = url.pathname.match(/^\/api\/a2a\/([^/]+)\/([^/]+)\/$/);
    if (!m) {
      return jsonReply(req, { error: "not found" }, 404);
    }
    if (req.method !== "POST") {
      return methodNotAllowed(req, "POST");
    }

    let id = "unknown";
    let echoed = "";
    try {
      const body = (await req.json()) as Record<string, unknown>;
      id = String(body.id ?? "unknown");
      const params = body.params as { message?: { parts?: Array<{ text?: string }> } } | undefined;
      echoed = params?.message?.parts?.[0]?.text ?? "";
      // Reject an envelope that is not what A2A specifies, rather than
      // answering anyway — otherwise a malformed request looks like success.
      if (body.jsonrpc !== "2.0" || body.method !== "message/send") {
        return jsonReply(
          req,
          { jsonrpc: "2.0", id, error: { code: -32600, message: "invalid A2A envelope" } },
          200,
        );
      }
    } catch {
      return jsonReply(
        req,
        { jsonrpc: "2.0", id, error: { code: -32700, message: "parse error" } },
        200,
      );
    }

    const r = reply(id, echoed);
    if (req.method === "HEAD") {
      const headers: Record<string, string> = typeof r.body === "string"
        ? { "content-type": "text/html; charset=utf-8" }
        : { "content-type": "application/json" };
      return new Response(null, { status: r.status, headers });
    }
    return typeof r.body === "string"
      ? new Response(r.body, { status: r.status, headers: { "content-type": "text/html" } })
      : jsonReply(req, r.body, r.status);
  },
});

card.url = `http://127.0.0.1:${server.port}/api/a2a/fe-signalloom-agents/kagent-k8s-reader/`;
console.log(`a2a-conformance-server listening on 127.0.0.1:${server.port} scenario=${scenario}`);
