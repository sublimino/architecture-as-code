// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package codingagent_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/codingagent"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

func validTestEvent() *codingagent.CodingAgentTelemetry {
	return &codingagent.CodingAgentTelemetry{
		SchemaVersion: "1.0.0",
		Harness:       codingagent.HarnessClaude,
		SessionID:     "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e",
		Timestamp:     "2026-09-15T02:00:00Z",
		Process: codingagent.ProcessInfo{
			PID:      1234,
			PPID:     1,
			Comm:     "claude",
			RSSBytes: 104857600,
			CPUTicks: 450,
		},
		Kanban: codingagent.KanbanInfo{
			TaskID:    "SLCD-P1-1",
			Shortcode: "SLCD",
			Role:      "implementation",
			ElapsedS:  120,
		},
		Metrics: codingagent.MetricsInfo{
			StepCount: 14,
			TokensIn:  125000,
			TokensOut: 4200,
			ToolCounts: codingagent.ToolCounts{
				ViewFile:   8,
				RunCommand: 3,
			},
		},
		Network: codingagent.NetworkInfo{
			InferenceEndpoint: "api.anthropic.com",
			EgressBytes:       45000,
		},
	}
}

func TestCodingAgentTelemetry_Valid(t *testing.T) {
	event := validTestEvent()
	if err := event.Validate(); err != nil {
		t.Fatalf("expected valid event, got error: %v", err)
	}

	data, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("failed to marshal event: %v", err)
	}

	unmarshaled, err := codingagent.UnmarshalJSON(data)
	if err != nil {
		t.Fatalf("failed to unmarshal valid event: %v", err)
	}

	if unmarshaled.Harness != codingagent.HarnessClaude {
		t.Errorf("expected harness %s, got %s", codingagent.HarnessClaude, unmarshaled.Harness)
	}
}

func TestCodingAgentTelemetry_ToolCountsFixedArity(t *testing.T) {
	var tc codingagent.ToolCounts

	// Record standard tools
	tc.RecordTool("view_file")
	tc.RecordTool("read_file")
	tc.RecordTool("run_command")
	tc.RecordTool("grep")
	tc.RecordTool("ask_question")

	if tc.ViewFile != 2 {
		t.Errorf("expected ViewFile == 2, got %d", tc.ViewFile)
	}
	if tc.RunCommand != 1 {
		t.Errorf("expected RunCommand == 1, got %d", tc.RunCommand)
	}
	if tc.GrepSearch != 1 {
		t.Errorf("expected GrepSearch == 1, got %d", tc.GrepSearch)
	}
	if tc.AskQuestion != 1 {
		t.Errorf("expected AskQuestion == 1, got %d", tc.AskQuestion)
	}

	// Record arbitrary MCP tool names - must be routed to OtherCount
	tc.RecordTool("mcp__custom_postgres__query")
	tc.RecordTool("mcp__kubernetes__apply")
	tc.RecordTool("random_unrecognized_tool")

	if tc.OtherCount != 3 {
		t.Errorf("expected OtherCount == 3, got %d", tc.OtherCount)
	}

	m := tc.ToMap()
	if len(m) != 14 {
		t.Fatalf("expected exactly 14 keys in tool counts map, got %d", len(m))
	}
	for _, expectedKey := range codingagent.ValidToolNames {
		if _, ok := m[string(expectedKey)]; !ok {
			t.Errorf("missing expected tool count key %q in ToMap()", expectedKey)
		}
	}
}

func TestCodingAgentTelemetry_PseudonymSessionID(t *testing.T) {
	rootKey := []byte("01234567890123456789012345678901")
	ring, err := pseudonym.NewKeyRing(rootKey, 1)
	if err != nil {
		t.Fatalf("failed to create keyring: %v", err)
	}

	sessionID, err := codingagent.DeriveSessionID(ring, "tenant-alpha", "session-guid-1234")
	if err != nil {
		t.Fatalf("failed to derive pseudonym session ID: %v", err)
	}

	if len(sessionID) != 64 {
		t.Fatalf("expected 64 character hex pseudonym, got length %d: %q", len(sessionID), sessionID)
	}
	if !pseudonym.IsPseudonym(sessionID) {
		t.Fatalf("derived session ID is not a valid pseudonym: %q", sessionID)
	}

	event := validTestEvent()
	event.SessionID = sessionID
	if err := event.Validate(); err != nil {
		t.Fatalf("event with derived pseudonym failed validation: %v", err)
	}

	// Negative tests for session_id
	event.SessionID = "too-short"
	if err := event.Validate(); err == nil {
		t.Error("expected short session_id to fail validation, got nil")
	}

	event.SessionID = strings.Repeat("g", 64) // Non-hex
	if err := event.Validate(); err == nil {
		t.Error("expected non-hex session_id to fail validation, got nil")
	}
}

func TestCodingAgentTelemetry_Negative_Crafted10KBHarness(t *testing.T) {
	event := validTestEvent()
	crafted10KB := strings.Repeat("a", 10240)
	event.Harness = codingagent.Harness(crafted10KB)

	err := event.Validate()
	if err == nil {
		t.Fatal("CRITICAL SECURITY FAILURE: 10KB harness string was accepted without error")
	}
	if !strings.Contains(err.Error(), "harness") {
		t.Errorf("expected error message mentioning harness length/format, got: %v", err)
	}
}

func TestCodingAgentTelemetry_Negative_OffEnumHarness(t *testing.T) {
	event := validTestEvent()
	event.Harness = "malicious_harness"

	err := event.Validate()
	if err == nil {
		t.Fatal("expected off-enum harness to fail validation, got nil")
	}
	if !strings.Contains(err.Error(), "not in allowlisted set") {
		t.Errorf("expected error mentioning allowlisted set, got: %v", err)
	}
}

func TestCodingAgentTelemetry_Negative_ProhibitedAndUnknownFields(t *testing.T) {
	validJSON := `{
		"schema_version": "1.0.0",
		"harness": "claude",
		"session_id": "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e",
		"timestamp": "2026-09-15T02:00:00Z",
		"process": {"pid": 1234, "ppid": 1, "comm": "claude", "rss_bytes": 104857600, "cpu_ticks": 450},
		"kanban": {"task_id": "SLCD-P1-1", "shortcode": "SLCD", "role": "implementation", "elapsed_s": 120},
		"metrics": {"step_count": 14, "tokens_in": 125000, "tokens_out": 4200, "tool_counts": {"view_file": 8, "run_command": 3, "write_to_file": 0, "replace_file_content": 0, "grep_search": 0, "find_by_name": 0, "list_dir": 0, "read_url_content": 0, "search_web": 0, "invoke_subagent": 0, "send_message": 0, "manage_task": 0, "ask_question": 0, "other_count": 0}},
		"network": {"inference_endpoint": "api.anthropic.com", "egress_bytes": 45000}
	}`

	// Verify valid unmarshals
	if _, err := codingagent.UnmarshalJSON([]byte(validJSON)); err != nil {
		t.Fatalf("valid JSON failed unmarshal: %v", err)
	}

	// Prohibited fields injection
	prohibitedFields := []string{
		`"prompt_text": "secret user prompt"`,
		`"completion_text": "model response text"`,
		`"file_contents": "def leaked(): pass"`,
		`"cmdline": "curl -u admin:secret"`,
		`"credentials": "sk-ant-12345"`,
		`"token": "bearer-token-val"`,
		`"arbitrary_custom_key": "data"`,
	}

	for _, injection := range prohibitedFields {
		badJSON := strings.Replace(validJSON, `"network":`, injection+`,"network":`, 1)
		_, err := codingagent.UnmarshalJSON([]byte(badJSON))
		if err == nil {
			t.Errorf("CRITICAL SECURITY FAILURE: unmarshal accepted prohibited/unknown field injection: %s", injection)
		}
	}
}

func TestCodingAgentTelemetry_Negative_FieldBounds(t *testing.T) {
	// Comm too long (>16 chars)
	e1 := validTestEvent()
	e1.Process.Comm = "very_long_process_comm_name"
	if err := e1.Validate(); err == nil {
		t.Error("expected comm > 16 chars to fail validation, got nil")
	}

	// Comm with invalid characters
	e2 := validTestEvent()
	e2.Process.Comm = "bad;rm -rf /"
	if err := e2.Validate(); err == nil {
		t.Error("expected comm with bad characters to fail validation, got nil")
	}

	// TaskID too long (>64 chars)
	e3 := validTestEvent()
	e3.Kanban.TaskID = strings.Repeat("A", 65)
	if err := e3.Validate(); err == nil {
		t.Error("expected task_id > 64 chars to fail validation, got nil")
	}

	// Shortcode invalid
	e4 := validTestEvent()
	e4.Kanban.Shortcode = "X" // < 2 chars
	if err := e4.Validate(); err == nil {
		t.Error("expected short shortcode to fail validation, got nil")
	}

	// Inference endpoint with path/query injection
	e5 := validTestEvent()
	e5.Network.InferenceEndpoint = "api.anthropic.com/v1/messages?key=secret"
	if err := e5.Validate(); err == nil {
		t.Error("expected endpoint with URL path/query to fail validation, got nil")
	}

	// PID out of bounds
	e6 := validTestEvent()
	e6.Process.PID = 0
	if err := e6.Validate(); err == nil {
		t.Error("expected PID 0 to fail validation, got nil")
	}
}

func TestCodingAgentTelemetry_SchemaConformance_Allowlist(t *testing.T) {
	schemaPath := filepath.Join("..", "..", "agentmaxxing-host-sensor", "schemas", "coding-agent-telemetry.v1.schema.json")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("failed to read JSON schema at %s: %v", schemaPath, err)
	}

	var schema map[string]interface{}
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatalf("failed to parse JSON schema: %v", err)
	}

	props, ok := schema["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("schema missing properties object")
	}

	// Inspect Go struct fields of CodingAgentTelemetry via reflection
	structType := reflect.TypeOf(codingagent.CodingAgentTelemetry{})
	goFields := make(map[string]bool)
	for i := 0; i < structType.NumField(); i++ {
		field := structType.Field(i)
		jsonTag := field.Tag.Get("json")
		tagName := strings.Split(jsonTag, ",")[0]
		if tagName != "" && tagName != "-" {
			goFields[tagName] = true
		}
	}

	// Fail if Go struct has fields not defined in JSON schema
	for goField := range goFields {
		if _, ok := props[goField]; !ok {
			t.Fatalf("SCHEMA CONFORMANCE FAILURE: Go struct field %q has no matching definition in JSON schema allowlist", goField)
		}
	}

	// Check tool counts properties in JSON schema match ToolCounts struct
	defs, ok := schema["$defs"].(map[string]interface{})
	if !ok {
		t.Fatalf("schema missing $defs object")
	}
	tcDef, ok := defs["tool_counts"].(map[string]interface{})
	if !ok {
		t.Fatalf("schema missing $defs/tool_counts object")
	}
	tcProps, ok := tcDef["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("tool_counts missing properties object")
	}

	tcStructType := reflect.TypeOf(codingagent.ToolCounts{})
	tcGoFields := make(map[string]bool)
	for i := 0; i < tcStructType.NumField(); i++ {
		field := tcStructType.Field(i)
		jsonTag := field.Tag.Get("json")
		tagName := strings.Split(jsonTag, ",")[0]
		if tagName != "" && tagName != "-" {
			tcGoFields[tagName] = true
		}
	}

	// Fail if Go ToolCounts has fields not in JSON schema tool_counts
	for tcField := range tcGoFields {
		if _, ok := tcProps[tcField]; !ok {
			t.Fatalf("SCHEMA CONFORMANCE FAILURE: Go ToolCounts field %q has no matching property in JSON schema", tcField)
		}
	}
	// Fail if JSON schema has tool_counts properties not in Go ToolCounts
	for tcProp := range tcProps {
		if !tcGoFields[tcProp] {
			t.Fatalf("SCHEMA CONFORMANCE FAILURE: JSON schema tool_counts property %q is missing from Go ToolCounts struct", tcProp)
		}
	}
}
