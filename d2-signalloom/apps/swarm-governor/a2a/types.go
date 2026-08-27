// Package a2a implements the Agent-to-Agent (A2A) protocol types.
//
// A2A uses JSON-RPC 2.0 with methods: tasks/send, tasks/get, tasks/cancel.
// Agent cards declare capabilities at /.well-known/agent-card.json.
package a2a

// AgentCard is the A2A agent card served at /.well-known/agent-card.json.
type AgentCard struct {
	Name         string       `json:"name"`
	Description  string       `json:"description,omitempty"`
	URL          string       `json:"url"`
	Version      string       `json:"version,omitempty"`
	Capabilities []Capability `json:"capabilities"`
	Skills       []Skill      `json:"skills,omitempty"`
}

// Capability describes a single thing an agent can do.
type Capability struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// Skill is a higher-level grouping of capabilities.
type Skill struct {
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	Tags        []string `json:"tags,omitempty"`
}

// Task is an A2A task sent via tasks/send.
type Task struct {
	ID           string            `json:"id"`
	Description  string            `json:"description"`
	Requirements []string          `json:"requirements,omitempty"`
	Input        map[string]any    `json:"input,omitempty"`
	Metadata     map[string]string `json:"metadata,omitempty"`
}

// TaskResult is returned by an agent after processing a task.
type TaskResult struct {
	TaskID  string         `json:"task_id"`
	Status  TaskStatus     `json:"status"`
	Output  map[string]any `json:"output,omitempty"`
	Error   string         `json:"error,omitempty"`
}

// TaskStatus represents the lifecycle state of a task.
type TaskStatus string

const (
	TaskStatusPending    TaskStatus = "pending"
	TaskStatusRunning    TaskStatus = "running"
	TaskStatusCompleted  TaskStatus = "completed"
	TaskStatusFailed     TaskStatus = "failed"
	TaskStatusCancelled  TaskStatus = "cancelled"
)

// JSONRPCRequest is a JSON-RPC 2.0 request envelope.
type JSONRPCRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	ID      string `json:"id"`
	Params  any    `json:"params"`
}

// JSONRPCResponse is a JSON-RPC 2.0 response envelope.
type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      string          `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *JSONRPCError   `json:"error,omitempty"`
}

// JSONRPCError is a JSON-RPC 2.0 error object.
type JSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}
