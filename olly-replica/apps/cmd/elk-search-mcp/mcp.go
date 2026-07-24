// MCP protocol endpoint: JSON-RPC 2.0 over HTTP, the transport an MCP client
// speaks. The same tool logic backs both this and the REST endpoints in
// main.go/tools.go; this layer adds initialize, tools/list, and tools/call so
// the sentinel connects as an MCP client. Each tools/call dispatches through
// the existing handler, so the scope check, query caps, and audit line all run.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
)

const mcpProtocolVersion = "2024-11-05"

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func writeRPCResult(w http.ResponseWriter, id json.RawMessage, result any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func writeRPCError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"jsonrpc": "2.0", "id": id, "error": rpcError{Code: code, Message: msg},
	})
}

// toolSchemas gives each tool a minimal JSON Schema for tools/list. app_id is
// the common argument; elk_search_logs and the trace/drift tools also take a
// query and window.
func toolSchemas() []map[string]any {
	common := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"app_id":             map[string]any{"type": "string"},
			"query":              map[string]any{"type": "string"},
			"trace_id":           map[string]any{"type": "string"},
			"index_pattern":      map[string]any{"type": "string"},
			"size":               map[string]any{"type": "integer"},
			"time_range_minutes": map[string]any{"type": "integer"},
		},
	}
	names := make([]string, 0, len(scopeFor))
	for n := range scopeFor {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]map[string]any, 0, len(names))
	for _, n := range names {
		out = append(out, map[string]any{
			"name":        n,
			"description": "Read-only. EEMS scope: " + scopeFor[n],
			"inputSchema": common,
			"annotations": map[string]any{"readOnlyHint": true, "scope": scopeFor[n]},
		})
	}
	return out
}

// handleMCP serves the JSON-RPC endpoint. toolHandlers maps a tool name to the
// REST handler that already implements it; tools/call replays the arguments
// through that handler and wraps its JSON output in an MCP content block.
func (s *server) handleMCP(toolHandlers map[string]http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var req rpcRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
			writeRPCError(w, nil, -32700, "parse error: "+err.Error())
			return
		}
		switch req.Method {
		case "initialize":
			writeRPCResult(w, req.ID, map[string]any{
				"protocolVersion": mcpProtocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "olly-mcp", "version": "0.1.0"},
			})
		case "notifications/initialized":
			w.WriteHeader(http.StatusAccepted)
		case "tools/list":
			writeRPCResult(w, req.ID, map[string]any{"tools": toolSchemas()})
		case "tools/call":
			var params struct {
				Name      string          `json:"name"`
				Arguments json.RawMessage `json:"arguments"`
			}
			if err := json.Unmarshal(req.Params, &params); err != nil {
				writeRPCError(w, req.ID, -32602, "invalid params: "+err.Error())
				return
			}
			handler, ok := toolHandlers[params.Name]
			if !ok {
				writeRPCError(w, req.ID, -32601, "unknown tool: "+params.Name)
				return
			}
			// COIN entitlement: the bearer must carry this tool's EEMS scope.
			if ctxID, err := s.authorize(r, scopeFor[params.Name]); err != nil {
				audit(params.Name, "deny", fmt.Sprintf(`"reason":%q,"authz_ctx_id":%q`, err.Error(), ctxID))
				writeRPCError(w, req.ID, -32001, "authz denied: "+err.Error())
				return
			}
			args := params.Arguments
			if len(args) == 0 {
				args = []byte("{}")
			}
			// Replay through the existing handler so the scope check, caps, and
			// audit run exactly as on the REST path.
			rec := httptest.NewRecorder()
			inner := httptest.NewRequest(http.MethodPost, "/tools/"+params.Name, bytes.NewReader(args))
			inner.Header.Set("Content-Type", "application/json")
			handler(rec, inner)
			out := rec.Body.Bytes()
			isErr := rec.Code >= 300
			writeRPCResult(w, req.ID, map[string]any{
				"content": []map[string]any{{"type": "text", "text": string(out)}},
				"isError": isErr,
			})
		default:
			writeRPCError(w, req.ID, -32601, "method not found: "+req.Method)
		}
	}
}
