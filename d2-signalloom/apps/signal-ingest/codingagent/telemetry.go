// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package codingagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

// SchemaVersion is the current version of the CodingAgentTelemetry schema.
const SchemaVersion = "1.0.0"

// Harness represents the closed enum of known coding agent harnesses.
type Harness string

const (
	HarnessClaude      Harness = "claude"
	HarnessAntigravity Harness = "antigravity"
	HarnessCodex       Harness = "codex"
	HarnessCPAI        Harness = "cpai"
	HarnessOpenCode    Harness = "opencode"
	HarnessHermes      Harness = "hermes"
	HarnessAider       Harness = "aider"
	HarnessUnknown     Harness = "unknown"
)

// ValidHarnesses is the frozen set of allowlisted harness identifiers.
var ValidHarnesses = map[Harness]struct{}{
	HarnessClaude:      {},
	HarnessAntigravity: {},
	HarnessCodex:       {},
	HarnessCPAI:        {},
	HarnessOpenCode:    {},
	HarnessHermes:      {},
	HarnessAider:       {},
	HarnessUnknown:     {},
}

// ToolName represents the closed enum of known tool invocation categories.
type ToolName string

const (
	ToolViewFile           ToolName = "view_file"
	ToolWriteToFile        ToolName = "write_to_file"
	ToolReplaceFileContent ToolName = "replace_file_content"
	ToolRunCommand         ToolName = "run_command"
	ToolGrepSearch         ToolName = "grep_search"
	ToolFindByName         ToolName = "find_by_name"
	ToolListDir            ToolName = "list_dir"
	ToolReadURLContent     ToolName = "read_url_content"
	ToolSearchWeb          ToolName = "search_web"
	ToolInvokeSubagent     ToolName = "invoke_subagent"
	ToolSendMessage        ToolName = "send_message"
	ToolManageTask         ToolName = "manage_task"
	ToolAskQuestion        ToolName = "ask_question"
	ToolOtherCount         ToolName = "other_count"
)

// ValidToolNames is the frozen set of 13 known tool categories plus other_count.
var ValidToolNames = []ToolName{
	ToolViewFile,
	ToolWriteToFile,
	ToolReplaceFileContent,
	ToolRunCommand,
	ToolGrepSearch,
	ToolFindByName,
	ToolListDir,
	ToolReadURLContent,
	ToolSearchWeb,
	ToolInvokeSubagent,
	ToolSendMessage,
	ToolManageTask,
	ToolAskQuestion,
	ToolOtherCount,
}

// Validation regular expressions with strictly bounded character classes.
var (
	reHarness           = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
	reSessionID         = regexp.MustCompile(`^[a-f0-9]{64}$`)
	reComm              = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,16}$`)
	reTaskID            = regexp.MustCompile(`^[A-Z0-9_-]{1,64}$`)
	reShortcode         = regexp.MustCompile(`^[A-Z0-9]{2,16}$`)
	reRole              = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
	reInferenceEndpoint = regexp.MustCompile(`^[a-zA-Z0-9.-]{1,128}$`)
	reEntityID          = regexp.MustCompile(`^[a-z][a-z0-9-]{2,63}$`)
)

// ProcessInfo holds allowlisted Linux process metrics. Zero memory payload or cmdline arguments.
type ProcessInfo struct {
	PID      int    `json:"pid"`
	PPID     int    `json:"ppid"`
	Comm     string `json:"comm"`
	RSSBytes uint64 `json:"rss_bytes"`
	CPUTicks uint64 `json:"cpu_ticks"`
}

// KanbanInfo holds non-intrusive kanban runner task execution metadata.
type KanbanInfo struct {
	TaskID    string `json:"task_id"`
	Shortcode string `json:"shortcode"`
	Role      string `json:"role"`
	ElapsedS  uint64 `json:"elapsed_s"`
}

// ToolCounts is a fixed-arity vector of tool execution counts.
// Unrecognised or dynamic MCP tools are strictly routed to OtherCount.
type ToolCounts struct {
	ViewFile           uint64 `json:"view_file"`
	WriteToFile        uint64 `json:"write_to_file"`
	ReplaceFileContent uint64 `json:"replace_file_content"`
	RunCommand         uint64 `json:"run_command"`
	GrepSearch         uint64 `json:"grep_search"`
	FindByName         uint64 `json:"find_by_name"`
	ListDir            uint64 `json:"list_dir"`
	ReadURLContent     uint64 `json:"read_url_content"`
	SearchWeb          uint64 `json:"search_web"`
	InvokeSubagent     uint64 `json:"invoke_subagent"`
	SendMessage        uint64 `json:"send_message"`
	ManageTask         uint64 `json:"manage_task"`
	AskQuestion        uint64 `json:"ask_question"`
	OtherCount         uint64 `json:"other_count"`
}

// MetricsInfo holds step, token, and tool count metrics.
// TokensIn and TokensOut are 64-bit integers to prevent 32-bit integer overflow on long sessions.
type MetricsInfo struct {
	StepCount  uint64     `json:"step_count"`
	TokensIn   uint64     `json:"tokens_in"`
	TokensOut  uint64     `json:"tokens_out"`
	ToolCounts ToolCounts `json:"tool_counts"`
}

// NetworkInfo holds non-intrusive socket egress metadata without packet payload inspection.
type NetworkInfo struct {
	InferenceEndpoint string `json:"inference_endpoint"`
	EgressBytes       uint64 `json:"egress_bytes"`
}

// CodingAgentTelemetry is the top-level allowlisted telemetry event for autonomous coding agents.
type CodingAgentTelemetry struct {
	SchemaVersion string      `json:"schema_version"`
	Harness       Harness     `json:"harness"`
	SessionID     string      `json:"session_id"`
	Timestamp     string      `json:"timestamp"`
	ObservedAt    string      `json:"observed_at,omitempty"`
	TenantID      string      `json:"tenant_id,omitempty"`
	AgentID       string      `json:"agent_id,omitempty"`
	HostID        string      `json:"host_id,omitempty"`
	Process       ProcessInfo `json:"process"`
	Kanban        KanbanInfo  `json:"kanban"`
	Metrics       MetricsInfo `json:"metrics"`
	Network       NetworkInfo `json:"network"`
}

// NormalizeToolName maps raw tool names and aliases from transcripts/harnesses to a closed ToolName enum.
// Any unknown tool or customer-named MCP tool (e.g. mcp__server__tool) maps to ToolOtherCount.
func NormalizeToolName(raw string) ToolName {
	cleaned := strings.ToLower(strings.TrimSpace(raw))
	switch cleaned {
	case "view_file", "viewfile", "read_file", "readfile", "read", "view_image":
		return ToolViewFile
	case "write_to_file", "writetofile", "write_file", "writefile", "write":
		return ToolWriteToFile
	case "replace_file_content", "replacefilecontent", "edit_file", "editfile", "edit", "multiedit", "multi_edit":
		return ToolReplaceFileContent
	case "run_command", "runcommand", "execute_command", "bash", "shell", "exec":
		return ToolRunCommand
	case "grep_search", "grepsearch", "search_code", "grep", "ripgrep", "rg":
		return ToolGrepSearch
	case "find_by_name", "findbyname", "glob", "find", "fd", "list_files":
		return ToolFindByName
	case "list_dir", "listdir", "list_directory", "ls":
		return ToolListDir
	case "read_url_content", "readurlcontent", "fetch_web", "web_fetch", "webfetch":
		return ToolReadURLContent
	case "search_web", "searchweb", "web_search", "websearch":
		return ToolSearchWeb
	case "invoke_subagent", "invokesubagent", "spawn_agent", "agent", "subagent":
		return ToolInvokeSubagent
	case "send_message", "sendmessage", "message_agent", "msg":
		return ToolSendMessage
	case "manage_task", "managetask", "task_status", "kill_task":
		return ToolManageTask
	case "ask_question", "askquestion", "ask_user", "question":
		return ToolAskQuestion
	default:
		return ToolOtherCount
	}
}

// RecordTool increments the appropriate counter in ToolCounts based on normalized tool name.
func (tc *ToolCounts) RecordTool(rawName string) {
	tc.Increment(NormalizeToolName(rawName))
}

// Increment adds 1 to the named ToolName counter.
func (tc *ToolCounts) Increment(tool ToolName) {
	switch tool {
	case ToolViewFile:
		tc.ViewFile++
	case ToolWriteToFile:
		tc.WriteToFile++
	case ToolReplaceFileContent:
		tc.ReplaceFileContent++
	case ToolRunCommand:
		tc.RunCommand++
	case ToolGrepSearch:
		tc.GrepSearch++
	case ToolFindByName:
		tc.FindByName++
	case ToolListDir:
		tc.ListDir++
	case ToolReadURLContent:
		tc.ReadURLContent++
	case ToolSearchWeb:
		tc.SearchWeb++
	case ToolInvokeSubagent:
		tc.InvokeSubagent++
	case ToolSendMessage:
		tc.SendMessage++
	case ToolManageTask:
		tc.ManageTask++
	case ToolAskQuestion:
		tc.AskQuestion++
	default:
		tc.OtherCount++
	}
}

// ToMap converts ToolCounts into a standard key-value map.
func (tc ToolCounts) ToMap() map[string]uint64 {
	return map[string]uint64{
		"view_file":            tc.ViewFile,
		"write_to_file":        tc.WriteToFile,
		"replace_file_content": tc.ReplaceFileContent,
		"run_command":          tc.RunCommand,
		"grep_search":          tc.GrepSearch,
		"find_by_name":         tc.FindByName,
		"list_dir":             tc.ListDir,
		"read_url_content":     tc.ReadURLContent,
		"search_web":           tc.SearchWeb,
		"invoke_subagent":      tc.InvokeSubagent,
		"send_message":         tc.SendMessage,
		"manage_task":          tc.ManageTask,
		"ask_question":         tc.AskQuestion,
		"other_count":          tc.OtherCount,
	}
}

// DeriveSessionID reuses the SLDP pseudonym primitive for session privacy.
func DeriveSessionID(ring *pseudonym.KeyRing, tenantID, rawSessionID string) (string, error) {
	if ring == nil {
		return "", errors.New("codingagent: pseudonym KeyRing cannot be nil")
	}
	return ring.Pseudonym(tenantID, rawSessionID)
}

// Validate checks all fields of CodingAgentTelemetry against allowlist constraints.
// It fails closed: any violation returns a detailed error without silent truncation.
func (e *CodingAgentTelemetry) Validate() error {
	if e.SchemaVersion != SchemaVersion {
		return fmt.Errorf("codingagent: schema_version must be %q, got %q", SchemaVersion, e.SchemaVersion)
	}

	// Harness validation
	if len(e.Harness) == 0 || len(e.Harness) > 32 || !reHarness.MatchString(string(e.Harness)) {
		return fmt.Errorf("codingagent: harness must be 1-32 chars matching %s, got length %d (%q)", reHarness.String(), len(e.Harness), e.Harness)
	}
	if _, ok := ValidHarnesses[e.Harness]; !ok {
		return fmt.Errorf("codingagent: harness %q is not in allowlisted set", e.Harness)
	}

	// SessionID validation (exact 64-char hex SLDP pseudonym)
	if len(e.SessionID) != pseudonym.HexLen || !reSessionID.MatchString(e.SessionID) {
		return fmt.Errorf("codingagent: session_id must be exactly %d lowercase hex characters, got %q", pseudonym.HexLen, e.SessionID)
	}

	// Timestamp validation (RFC3339)
	ts := e.Timestamp
	if ts == "" && e.ObservedAt != "" {
		ts = e.ObservedAt
	}
	if ts == "" {
		return errors.New("codingagent: timestamp is required")
	}
	if len(ts) > 35 {
		return fmt.Errorf("codingagent: timestamp length %d exceeds max 35", len(ts))
	}
	if _, err := time.Parse(time.RFC3339Nano, ts); err != nil {
		if _, err2 := time.Parse(time.RFC3339, ts); err2 != nil {
			return fmt.Errorf("codingagent: invalid RFC3339 timestamp %q: %w", ts, err)
		}
	}

	// Optional entity ID validations
	if e.TenantID != "" && !reEntityID.MatchString(e.TenantID) {
		return fmt.Errorf("codingagent: invalid tenant_id %q", e.TenantID)
	}
	if e.AgentID != "" && !reEntityID.MatchString(e.AgentID) {
		return fmt.Errorf("codingagent: invalid agent_id %q", e.AgentID)
	}
	if e.HostID != "" && !reEntityID.MatchString(e.HostID) {
		return fmt.Errorf("codingagent: invalid host_id %q", e.HostID)
	}

	// Process validation
	if e.Process.PID < 1 || e.Process.PID > 4194304 {
		return fmt.Errorf("codingagent: process.pid %d out of bounds [1, 4194304]", e.Process.PID)
	}
	if e.Process.PPID < 0 || e.Process.PPID > 4194304 {
		return fmt.Errorf("codingagent: process.ppid %d out of bounds [0, 4194304]", e.Process.PPID)
	}
	if len(e.Process.Comm) == 0 || len(e.Process.Comm) > 16 || !reComm.MatchString(e.Process.Comm) {
		return fmt.Errorf("codingagent: process.comm %q invalid (length %d, must match %s)", e.Process.Comm, len(e.Process.Comm), reComm.String())
	}

	// Kanban validation
	if len(e.Kanban.TaskID) == 0 || len(e.Kanban.TaskID) > 64 || !reTaskID.MatchString(e.Kanban.TaskID) {
		return fmt.Errorf("codingagent: kanban.task_id %q invalid (length %d, must match %s)", e.Kanban.TaskID, len(e.Kanban.TaskID), reTaskID.String())
	}
	if len(e.Kanban.Shortcode) < 2 || len(e.Kanban.Shortcode) > 16 || !reShortcode.MatchString(e.Kanban.Shortcode) {
		return fmt.Errorf("codingagent: kanban.shortcode %q invalid (length %d, must match %s)", e.Kanban.Shortcode, len(e.Kanban.Shortcode), reShortcode.String())
	}
	if len(e.Kanban.Role) == 0 || len(e.Kanban.Role) > 32 || !reRole.MatchString(e.Kanban.Role) {
		return fmt.Errorf("codingagent: kanban.role %q invalid (length %d, must match %s)", e.Kanban.Role, len(e.Kanban.Role), reRole.String())
	}

	// Network validation
	if len(e.Network.InferenceEndpoint) == 0 || len(e.Network.InferenceEndpoint) > 128 || !reInferenceEndpoint.MatchString(e.Network.InferenceEndpoint) {
		return fmt.Errorf("codingagent: network.inference_endpoint %q invalid (length %d, must match %s)", e.Network.InferenceEndpoint, len(e.Network.InferenceEndpoint), reInferenceEndpoint.String())
	}

	return nil
}

// UnmarshalJSON validates and parses JSON bytes into CodingAgentTelemetry.
// It fails closed if unknown fields or invalid structures are present.
func UnmarshalJSON(data []byte) (*CodingAgentTelemetry, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("codingagent: invalid JSON: %w", err)
	}

	allowedKeys := map[string]struct{}{
		"schema_version": {},
		"harness":        {},
		"session_id":     {},
		"timestamp":      {},
		"observed_at":    {},
		"tenant_id":      {},
		"agent_id":       {},
		"host_id":        {},
		"process":        {},
		"kanban":         {},
		"metrics":        {},
		"network":        {},
	}

	for k := range raw {
		if _, ok := allowedKeys[k]; !ok {
			return nil, fmt.Errorf("codingagent: unknown or prohibited top-level field %q", k)
		}
	}

	var event CodingAgentTelemetry
	if err := json.Unmarshal(data, &event); err != nil {
		return nil, fmt.Errorf("codingagent: unmarshal failed: %w", err)
	}

	if err := event.Validate(); err != nil {
		return nil, err
	}

	return &event, nil
}
