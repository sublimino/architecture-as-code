// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// SLCD-P1-3: the Go half of the codingagent.v1 contract freeze.
//
// Every test here runs against the GENERATED decoder in wire_gen.go, and every
// rejection case comes from the shared corpus at
// schemas/fixtures/reject/MANIFEST.json which the Python suite also reads. That
// sharing is the point: two suites each testing their own half of a contract go
// green while holding one blind spot between them.

package codingagent

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Paths are relative to this package directory, which is `go test`'s working
// directory. The canonical schema is deliberately NOT vendored into this module:
// a copy is the drift shape this card exists to remove.
const (
	schemaRel   = "../../agentmaxxing-host-sensor/schemas/coding-agent-telemetry.v1.schema.json"
	fixturesRel = "../../agentmaxxing-host-sensor/schemas/fixtures"
	generatorRel = "../../agentmaxxing-host-sensor/scripts/gen_wire_contract.py"
)

// ---------------------------------------------------------------------------
// Digest binding: schema moved, artefacts did not
// ---------------------------------------------------------------------------

func TestCodingAgentWireContract_SchemaDigest(t *testing.T) {
	raw, err := os.ReadFile(schemaRel)
	if err != nil {
		// Fatal, never Skip. A skip on a missing system-under-test turns a build
		// failure into a silent pass.
		t.Fatalf("canonical schema not readable at %s: %v", schemaRel, err)
	}
	sum := sha256.Sum256(raw)
	got := hex.EncodeToString(sum[:])
	if got != WireSchemaSHA256 {
		t.Fatalf("schema digest drift: wire_gen.go records %s but %s hashes to %s.\n"+
			"The schema changed without a regeneration. Run: make signalloom-wire-contract-emit",
			WireSchemaSHA256, schemaRel, got)
	}
}

func TestCodingAgentWireContract_LabelIsStructural(t *testing.T) {
	if WireContractLabel != "codingagent.v1" {
		t.Fatalf("contract label = %q, want codingagent.v1", WireContractLabel)
	}
	var schema map[string]any
	mustJSON(t, schemaRel, &schema)
	if schema["x-contract-label"] != WireContractLabel {
		t.Fatalf("schema label %v != generated label %q", schema["x-contract-label"], WireContractLabel)
	}
	if WireContractHeader != "X-SignalLoom-Contract" {
		t.Fatalf("contract header = %q", WireContractHeader)
	}
}

// ---------------------------------------------------------------------------
// The allow-list is the schema's, neither wider nor narrower
// ---------------------------------------------------------------------------

func TestCodingAgentWireContract_AllowListMatchesSchema(t *testing.T) {
	var schema struct {
		Properties map[string]json.RawMessage `json:"properties"`
		Defs       map[string]struct {
			Properties           map[string]json.RawMessage `json:"properties"`
			Required             []string                   `json:"required"`
			AdditionalProperties *bool                      `json:"additionalProperties"`
		} `json:"$defs"`
		AdditionalProperties *bool `json:"additionalProperties"`
	}
	mustJSON(t, schemaRel, &schema)

	if schema.AdditionalProperties == nil || *schema.AdditionalProperties {
		t.Fatal("envelope must declare additionalProperties:false")
	}
	prefixes := map[string]string{
		"process_info": "process", "kanban_info": "kanban", "metrics_info": "metrics",
		"tool_counts": "metrics.tool_counts", "network_info": "network",
	}
	want := []string{}
	for n := range schema.Properties {
		want = append(want, n)
	}
	for def, sub := range schema.Defs {
		if sub.AdditionalProperties == nil || *sub.AdditionalProperties {
			t.Fatalf("$defs.%s must declare additionalProperties:false", def)
		}
		p, ok := prefixes[def]
		if !ok {
			t.Fatalf("unmapped $defs key %q -- the contract gained an object this test does not know about", def)
		}
		for n := range sub.Properties {
			want = append(want, p+"."+n)
		}
	}
	sort.Strings(want)
	got := WireAllowedKeys()
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("generated allow-list diverges from the schema.\n got: %v\nwant: %v", got, want)
	}
	if len(got) != 41 {
		t.Fatalf("allow-list size = %d, want 41 -- a field was added or removed at freeze time", len(got))
	}
}

// ---------------------------------------------------------------------------
// Valid fixtures, built from P1-PRE's observed inventory
// ---------------------------------------------------------------------------

func validFixtures(t *testing.T) map[string][]byte {
	t.Helper()
	dir := filepath.Join(fixturesRel, "valid")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("valid fixture directory unreadable: %v", err)
	}
	out := map[string][]byte{}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			b, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				t.Fatalf("fixture %s unreadable: %v", e.Name(), err)
			}
			out[e.Name()] = b
		}
	}
	if len(out) < 2 {
		t.Fatalf("expected at least 2 valid fixtures, found %d -- a loader matching nothing reads as a pass", len(out))
	}
	return out
}

func TestCodingAgentWireContract_ValidFixturesDecode(t *testing.T) {
	for name, body := range validFixtures(t) {
		t.Run(name, func(t *testing.T) {
			ev, err := DecodeWire(body)
			if err != nil {
				t.Fatalf("valid fixture rejected: %v", err)
			}
			if ev.SchemaVersion != "1.0.0" {
				t.Fatalf("schema_version = %q", ev.SchemaVersion)
			}
			if ev.Harness == "" || ev.SessionID == "" {
				t.Fatal("required fields did not populate")
			}
		})
	}
}

// P1-PRE F1: `comm` is a 15-byte truncated field and is not a harness
// discriminator. The antigravity fixture carries comm="agy" precisely so the
// frozen contract is exercised by a record where the two disagree.
func TestCodingAgentWireContract_CommIsNotTheHarness(t *testing.T) {
	body, err := os.ReadFile(filepath.Join(fixturesRel, "valid", "antigravity-agy.json"))
	if err != nil {
		t.Fatalf("antigravity fixture unreadable: %v", err)
	}
	ev, err := DecodeWire(body)
	if err != nil {
		t.Fatalf("antigravity fixture rejected: %v", err)
	}
	if ev.Harness != "antigravity" {
		t.Fatalf("harness = %q, want antigravity", ev.Harness)
	}
	if ev.Process.Comm != "agy" {
		t.Fatalf("comm = %q, want agy (P1-PRE F1)", ev.Process.Comm)
	}
}

// ---------------------------------------------------------------------------
// Shared rejection corpus
// ---------------------------------------------------------------------------

type rejectCase struct {
	ID     string `json:"id"`
	Op     string `json:"op"`
	Path   string `json:"path"`
	Value  any    `json:"value"`
	Repeat int    `json:"repeat"`
	Raw    string `json:"raw"`
	Why    string `json:"why"`
}

type rejectManifest struct {
	Base  string       `json:"base"`
	Cases []rejectCase `json:"cases"`
}

func loadRejectManifest(t *testing.T) rejectManifest {
	t.Helper()
	var m rejectManifest
	mustJSON(t, filepath.Join(fixturesRel, "reject", "MANIFEST.json"), &m)
	if len(m.Cases) == 0 {
		t.Fatal("rejection corpus is empty -- a green run over zero cases is indistinguishable from a green run over passing ones")
	}
	return m
}

// applyMutation walks a dotted path and applies the case's op, returning the
// mutated document. Deliberately small and shared in shape with the Python
// applier, so neither language can quietly test a different corpus.
func applyMutation(t *testing.T, base map[string]any, c rejectCase) []byte {
	t.Helper()
	if c.Op == "raw" {
		return []byte(c.Raw)
	}
	doc := deepCopy(base).(map[string]any)
	parts := strings.Split(c.Path, ".")
	cur := doc
	for i, p := range parts {
		last := i == len(parts)-1
		if last {
			switch c.Op {
			case "delete":
				delete(cur, p)
			case "set":
				v := c.Value
				if s, ok := v.(string); ok && c.Repeat > 0 {
					v = strings.Repeat(s, c.Repeat)
				}
				cur[p] = v
			default:
				t.Fatalf("case %s: unknown op %q", c.ID, c.Op)
			}
			break
		}
		next, ok := cur[p].(map[string]any)
		if !ok {
			t.Fatalf("case %s: path segment %q is not an object", c.ID, p)
		}
		cur = next
	}
	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("case %s: remarshal failed: %v", c.ID, err)
	}
	return out
}

func deepCopy(v any) any {
	switch t := v.(type) {
	case map[string]any:
		m := make(map[string]any, len(t))
		for k, vv := range t {
			m[k] = deepCopy(vv)
		}
		return m
	case []any:
		s := make([]any, len(t))
		for i, vv := range t {
			s[i] = deepCopy(vv)
		}
		return s
	default:
		return v
	}
}

func TestCodingAgentWireContract_RejectsEveryCorpusCase(t *testing.T) {
	m := loadRejectManifest(t)
	var base map[string]any
	mustJSON(t, filepath.Join(fixturesRel, "reject", m.Base), &base)

	// The base must itself be accepted, or every rejection below proves nothing.
	baseBody, _ := json.Marshal(base)
	if _, err := DecodeWire(baseBody); err != nil {
		t.Fatalf("positive control failed: the corpus base is itself rejected (%v). "+
			"Every rejection assertion would then pass for the wrong reason.", err)
	}

	for _, c := range m.Cases {
		t.Run(c.ID, func(t *testing.T) {
			body := applyMutation(t, base, c)
			ev, err := DecodeWire(body)
			if err == nil {
				t.Fatalf("ACCEPTED but must be rejected (%s); decoded harness=%q", c.Why, ev.Harness)
			}
			// A rejection message is an export surface too.
			assertNoValueLeak(t, err.Error(), c)
		})
	}
}

// assertNoValueLeak checks that the refusal names the field and the rule, and
// does not quote the value it refused.
func assertNoValueLeak(t *testing.T, msg string, c rejectCase) {
	t.Helper()
	for _, needle := range []string{"REDACTED", "sk-ant-", "leak="} {
		if strings.Contains(msg, needle) {
			t.Fatalf("case %s: rejection message quotes the rejected value: %q", c.ID, msg)
		}
	}
	if !strings.HasPrefix(msg, "codingagent/wire:") {
		t.Fatalf("case %s: rejection message is not from the generated decoder: %q", c.ID, msg)
	}
}

// ---------------------------------------------------------------------------
// Systematic cross-language differential corpus
// ---------------------------------------------------------------------------

type diffCase struct {
	ID      string `json:"id"`
	Expect  string `json:"expect"`
	Why     string `json:"why"`
	Payload string `json:"payload"`
}

// TestCodingAgentWireContract_DifferentialCorpus is the test that covers what a
// hand-written reject-list structurally cannot.
//
// MANIFEST.json is a list of cases someone thought of. Every real asymmetry found
// on this card was one nobody thought of: Python's `$` matching before a trailing
// newline, Go's json.Number accepting a quoted number, encoding/json treating
// null as a no-op. None had a manifest case.
//
// This corpus instead enumerates every field against every adversarial value
// class, carries the COMPLETE payload text, and records the EXPECTED verdict.
// Both languages decode identical bytes and assert actual == expected --
// deliberately NOT go_verdict == py_verdict, because two decoders agreeing to
// accept something they should refuse is not agreement, it is a shared defect.
func TestCodingAgentWireContract_DifferentialCorpus(t *testing.T) {
	var corpus struct {
		CaseCount int        `json:"case_count"`
		Cases     []diffCase `json:"cases"`
	}
	mustJSON(t, filepath.Join(fixturesRel, "differential", "CORPUS.json"), &corpus)
	if len(corpus.Cases) == 0 {
		t.Fatal("differential corpus is empty -- a green run over zero cases proves nothing")
	}
	if len(corpus.Cases) != corpus.CaseCount {
		t.Fatalf("corpus declares %d cases but carries %d", corpus.CaseCount, len(corpus.Cases))
	}
	if len(corpus.Cases) < 400 {
		t.Fatalf("corpus shrank to %d cases; it enumerates every field against every "+
			"value class and should not get smaller without a field being removed", len(corpus.Cases))
	}

	accepted := 0
	for _, c := range corpus.Cases {
		actual := "accept"
		if _, err := DecodeWire([]byte(c.Payload)); err != nil {
			actual = "reject"
		} else {
			accepted++
		}
		if actual != c.Expect {
			t.Errorf("%s: expected %s, got %s\n  why: %s", c.ID, c.Expect, actual, c.Why)
		}
	}
	// Guard against the whole corpus being refused for an unrelated reason,
	// which would make every reject-case pass vacuously.
	if accepted == 0 {
		t.Fatal("no case was accepted, not even the positive control -- every rejection " +
			"assertion above passed for the wrong reason")
	}
}

// ---------------------------------------------------------------------------
// Cross-language round trip
// ---------------------------------------------------------------------------

// TestCodingAgentWireContract_CanonicalIsStable pins the canonical encoding of
// each valid fixture by digest. The Python suite pins the SAME digests. Comparing
// the two languages only to each other would pass if both were wrong in the same
// way; comparing each to a recorded constant does not.
func TestCodingAgentWireContract_CanonicalIsStable(t *testing.T) {
	want := map[string]string{}
	mustJSON(t, filepath.Join(fixturesRel, "canonical-digests.json"), &want)
	if len(want) < 2 {
		t.Fatal("canonical digest table has fewer than 2 entries")
	}
	for name, body := range validFixtures(t) {
		t.Run(name, func(t *testing.T) {
			ev, err := DecodeWire(body)
			if err != nil {
				t.Fatalf("fixture rejected: %v", err)
			}
			canon, err := ev.CanonicalJSON()
			if err != nil {
				t.Fatalf("canonical encode failed: %v", err)
			}
			sum := sha256.Sum256(canon)
			got := hex.EncodeToString(sum[:])
			exp, ok := want[name]
			if !ok {
				t.Fatalf("fixture %s has no recorded canonical digest", name)
			}
			if got != exp {
				t.Fatalf("canonical digest drift for %s:\n got %s\nwant %s\ncanonical bytes: %s", name, got, exp, canon)
			}
			// Structural checks on the canonical form itself.
			if bytes.HasSuffix(canon, []byte("\n")) {
				t.Fatal("canonical form must not end with a newline")
			}
			if bytes.Contains(canon, []byte(": ")) || bytes.Contains(canon, []byte(", ")) {
				t.Fatal("canonical form must carry no insignificant whitespace")
			}
			if err := sortedKeysAtEveryLevel(canon); err != nil {
				t.Fatalf("canonical form keys are not sorted at every level: %v", err)
			}
		})
	}
}

// TestCodingAgentWireContract_DecodesPythonEncoded closes the loop in the
// direction Go cannot check alone: bytes produced by the Python encoder, checked
// into the tree, must decode here to a value whose re-encoding is identical.
func TestCodingAgentWireContract_DecodesPythonEncoded(t *testing.T) {
	dir := filepath.Join(fixturesRel, "canonical")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("python-encoded canonical directory unreadable: %v", err)
	}
	n := 0
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".canonical.json") {
			continue
		}
		n++
		t.Run(e.Name(), func(t *testing.T) {
			body, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				t.Fatalf("unreadable: %v", err)
			}
			ev, err := DecodeWire(body)
			if err != nil {
				t.Fatalf("Python-encoded canonical bytes rejected by Go: %v", err)
			}
			back, err := ev.CanonicalJSON()
			if err != nil {
				t.Fatalf("re-encode failed: %v", err)
			}
			if !bytes.Equal(back, body) {
				t.Fatalf("Go re-encode differs from the Python-encoded input.\n go: %s\npy: %s", back, body)
			}
		})
	}
	if n < 2 {
		t.Fatalf("expected at least 2 Python-encoded canonical files, found %d", n)
	}
}

// TestCodingAgentWireContract_EmitGoEncoded regenerates the Go-encoded canonical
// bytes that the Python suite reads. Guarded, because a test that rewrites its
// own fixtures would launder an encoder regression into an updated file.
// Run with: SLCD_EMIT_GO_CANONICAL=1 go test ./codingagent/ -run EmitGoEncoded
func TestCodingAgentWireContract_EmitGoEncoded(t *testing.T) {
	if os.Getenv("SLCD_EMIT_GO_CANONICAL") != "1" {
		t.Skip("set SLCD_EMIT_GO_CANONICAL=1 to regenerate fixtures/go-encoded/")
	}
	dst := filepath.Join(fixturesRel, "go-encoded")
	if err := os.MkdirAll(dst, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range validFixtures(t) {
		ev, err := DecodeWire(body)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		canon, err := ev.CanonicalJSON()
		if err != nil {
			t.Fatal(err)
		}
		out := filepath.Join(dst, strings.TrimSuffix(name, ".json")+".canonical.json")
		if err := os.WriteFile(out, canon, 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s (%d bytes)", out, len(canon))
	}
}

// ---------------------------------------------------------------------------
// Routing gap: recorded as a test so it cannot be quietly assumed away
// ---------------------------------------------------------------------------

// TestCodingAgentWireContract_RoutingGapIsClosed asserts that the routing gap flagged in
// P1-3 is resolved by SLCD-P5-1:
// 1. Dashboard nginx location /api/ routes to fe-signalloom-api (preserving zero-trust NetworkPolicy).
// 2. signal-ingest registers the frozen WireEndpointPath (/api/v1/telemetry/coding-agents) in api/auth.go.
func TestCodingAgentWireContract_RoutingGapIsClosed(t *testing.T) {
	const nginxRel = "../../dashboard-signalloom/nginx.conf"
	conf, err := os.ReadFile(nginxRel)
	if err != nil {
		t.Fatalf("nginx.conf unreadable at %s: %v", nginxRel, err)
	}
	lines := strings.Split(string(conf), "\n")
	apiLine := -1
	for i, l := range lines {
		if strings.TrimSpace(l) == "location /api/ {" {
			apiLine = i + 1
			break
		}
	}
	if apiLine == -1 {
		t.Fatal("no `location /api/` block found in nginx.conf")
	}
	if apiLine != 130 {
		t.Fatalf("`location /api/` moved to line %d", apiLine)
	}
	window := strings.Join(lines[apiLine:apiLine+4], "\n")
	if !strings.Contains(window, "fe-signalloom-api") {
		t.Fatalf("the /api/ upstream is no longer fe-signalloom-api:\n%s", window)
	}

	// Route must be registered in signal-ingest api/auth.go
	authGo, err := os.ReadFile("../api/auth.go")
	if err != nil {
		t.Fatalf("api/auth.go unreadable: %v", err)
	}
	if !bytes.Contains(authGo, []byte(WireEndpointPath)) {
		t.Fatalf("api/auth.go must register %s", WireEndpointPath)
	}
}

// ---------------------------------------------------------------------------
// Drift check invoked from the test suite, not only from make
// ---------------------------------------------------------------------------

// TestCodingAgentWireContract_GeneratorCheckIsWired asserts the generator exists
// and declares the --check mode this suite's sibling make target depends on. The
// full --check run is exercised by the Python suite, which already has an
// interpreter; here we assert the mode is not silently removed.
func TestCodingAgentWireContract_GeneratorCheckIsWired(t *testing.T) {
	src, err := os.ReadFile(generatorRel)
	if err != nil {
		t.Fatalf("generator not found at %s: %v", generatorRel, err)
	}
	for _, needle := range []string{"--emit", "--check", "--classify", "def cmd_check"} {
		if !bytes.Contains(src, []byte(needle)) {
			t.Fatalf("generator no longer provides %q", needle)
		}
	}
	gen, err := os.ReadFile("wire_gen.go")
	if err != nil {
		t.Fatalf("generated Go unreadable: %v", err)
	}
	if !bytes.Contains(gen, []byte("DO NOT EDIT")) {
		t.Fatal("generated Go lost its DO NOT EDIT header")
	}
	if !bytes.Contains(gen, []byte(WireSchemaSHA256)) {
		t.Fatal("generated Go no longer embeds its schema digest")
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func mustJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s unreadable: %v", path, err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s is not valid JSON: %v", path, err)
	}
}

// sortedKeysAtEveryLevel walks the raw token stream. Unmarshalling into
// map[string]any would discard the very property under test, so this reads key
// order off the wire bytes themselves.
func sortedKeysAtEveryLevel(b []byte) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	// stack of "last key seen" per open object; empty string means none yet.
	var stack []string
	depth := 0
	expectKey := false
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		if d, ok := tok.(json.Delim); ok {
			switch d {
			case '{':
				stack = append(stack, "")
				depth++
				expectKey = true
				continue
			case '}':
				if len(stack) == 0 {
					return fmt.Errorf("unbalanced object at depth %d", depth)
				}
				stack = stack[:len(stack)-1]
				depth--
				expectKey = len(stack) > 0
				continue
			case '[', ']':
				expectKey = false
				continue
			}
		}
		if expectKey {
			key, ok := tok.(string)
			if !ok {
				return fmt.Errorf("object key is not a string")
			}
			prev := stack[len(stack)-1]
			if prev != "" && key <= prev {
				return fmt.Errorf("keys out of order at depth %d: %q follows %q", depth, key, prev)
			}
			stack[len(stack)-1] = key
			// The next token is this key's value; suppress key interpretation
			// unless the value turns out to be a container, handled above.
			expectKey = false
			var val json.RawMessage
			if err := dec.Decode(&val); err != nil {
				return fmt.Errorf("malformed value for key %q", key)
			}
			if err := sortedKeysAtEveryLevel(val); err != nil {
				return err
			}
			expectKey = len(stack) > 0
		}
	}
	return nil
}
