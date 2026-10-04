// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package awslogs_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// SLAWS D5: "Read-only assumed role. Signal Loom never writes into the customer
// account." The role carries exactly three permissions.
//
// That decision lives in a markdown template a customer's cloud team copies into
// their own account, which makes it the one artefact in this repository that is
// executed by someone else, on infrastructure we cannot see, with no test of their
// own. Nothing else would notice it drifting: adding `s3:PutObject` to the template
// breaks no build, fails no test, and is invisible in review the moment the diff is
// more than a few lines. The next customer provisions a role that can write.
//
// So the document is parsed and asserted like code. The assertions are on the JSON
// policy documents it embeds, not on its prose, because the JSON is what gets pasted
// into IAM.

// trustDocPath is the template, relative to the repository root.
const trustDocRelPath = "docs/signalloom/slaws-kusari-trust-policy.md"

// allowedDataPlaneActions is the complete, closed set from D5 and proposal §2.1.
//
// It is a literal rather than a pattern on purpose: a pattern like "no write verbs"
// would accept `s3:GetObjectVersion`, `s3:ListBucket` or `sqs:GetQueueAttributes`,
// all of which are read-only and all of which widen what Signal Loom can see beyond
// what the proposal told the customer it would.
var allowedDataPlaneActions = []string{
	"s3:GetObject",
	"sqs:DeleteMessage",
	"sqs:ReceiveMessage",
}

// trustAction is the only action a statement with a Principal may carry.
const trustAction = "sts:AssumeRole"

// writeVerb matches an action that could mutate the customer's account. It is defence
// in depth behind the set equality below: the set catches a replaced action, this
// catches a second policy block being appended with one.
var writeVerb = regexp.MustCompile(`(?i):(put|delete|create|update|write|send|set|modify|tag|untag|attach|detach|replicate|restore|abort|upload|copy|bypass)`)

// policyDocument is the subset of an IAM policy these assertions read.
type policyDocument struct {
	Version   string `json:"Version"`
	Statement []struct {
		Effect    string          `json:"Effect"`
		Action    json.RawMessage `json:"Action"`
		Principal json.RawMessage `json:"Principal"`
		Resource  json.RawMessage `json:"Resource"`
		Condition struct {
			StringEquals map[string]string `json:"StringEquals"`
		} `json:"Condition"`
	} `json:"Statement"`
}

// stringOrSlice decodes the IAM shorthand where a field is either a string or an
// array of strings. Treating only one shape would let the other slip past: writing
// `"Action": ["s3:GetObject", "s3:PutObject"]` where a string was expected would
// decode to nothing and assert nothing.
func stringOrSlice(t *testing.T, raw json.RawMessage) []string {
	t.Helper()
	if len(raw) == 0 {
		return nil
	}
	var one string
	if err := json.Unmarshal(raw, &one); err == nil {
		return []string{one}
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err == nil {
		return many
	}
	t.Fatalf("Action/Resource is neither a string nor an array of strings: %s", raw)
	return nil
}

func TestTrustDocument_GrantsExactlyTheThreeReadOnlyActions(t *testing.T) {
	path := findTrustDoc(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}

	blocks := jsonBlocks(string(raw))
	if len(blocks) < 2 {
		t.Fatalf("%s holds %d JSON blocks, want at least 2 (the trust policy and the permission policy); "+
			"the parser below is matching nothing, so these assertions would pass vacuously", trustDocRelPath, len(blocks))
	}

	var (
		dataPlane     []string
		trustStmts    int
		permitStmts   int
		sawExternalID bool
	)

	for i, block := range blocks {
		var doc policyDocument
		if err := json.Unmarshal([]byte(block), &doc); err != nil {
			t.Fatalf("JSON block %d in %s does not parse as an IAM policy: %v\n%s", i, trustDocRelPath, err, block)
		}
		if len(doc.Statement) == 0 {
			t.Errorf("JSON block %d has no Statement", i)
			continue
		}

		for j, stmt := range doc.Statement {
			where := fmt.Sprintf("block %d statement %d", i, j)
			actions := stringOrSlice(t, stmt.Action)
			if len(actions) == 0 {
				t.Errorf("%s names no Action", where)
				continue
			}

			if len(stmt.Principal) > 0 {
				// A trust statement: who may assume the role.
				trustStmts++
				for _, a := range actions {
					if a != trustAction {
						t.Errorf("%s is a trust statement carrying action %q, want only %q", where, a, trustAction)
					}
				}
				// D5's confused-deputy protection is half document, half code
				// (ErrExternalIDRequired). Without the condition here, the collector's
				// refusal to assume without an external ID enforces nothing: the
				// customer's role would accept an assumption that omitted it.
				if v, ok := stmt.Condition.StringEquals["sts:ExternalId"]; ok && v != "" {
					sawExternalID = true
				}
				continue
			}

			// A permission statement: what the role may do.
			permitStmts++
			for _, a := range actions {
				if a == "*" || strings.HasSuffix(a, ":*") {
					t.Errorf("%s grants the wildcard action %q", where, a)
					continue
				}
				dataPlane = append(dataPlane, a)
			}
			for _, r := range stringOrSlice(t, stmt.Resource) {
				if r == "*" {
					t.Errorf("%s grants its actions on every resource (%q); D5 scopes them to the log bucket and queue", where, r)
				}
			}
		}
	}

	if trustStmts == 0 {
		t.Error("no trust statement found; the template no longer says who may assume the role")
	}
	if permitStmts == 0 {
		t.Error("no permission statement found; these assertions would pass vacuously")
	}
	if !sawExternalID {
		t.Error("the trust policy no longer conditions on sts:ExternalId; " +
			"awslogs.ErrExternalIDRequired then enforces nothing, because the customer's role " +
			"would accept an assumption that omitted the external ID (D5, ISC-59)")
	}

	// The set must be exactly the three. Not a subset, not a superset: a missing
	// action breaks the collector, an extra one breaks the promise made to the
	// customer.
	sort.Strings(dataPlane)
	got := dedupe(dataPlane)
	if strings.Join(got, ",") != strings.Join(allowedDataPlaneActions, ",") {
		t.Errorf("%s grants %v, want exactly %v (SLAWS D5: read-only, three actions, no writes)",
			trustDocRelPath, got, allowedDataPlaneActions)
	}

	// Defence in depth: catches a write action arriving in a block this parser's set
	// comparison somehow did not reach.
	for _, a := range dataPlane {
		if isAllowedAction(a) {
			continue
		}
		if writeVerb.MatchString(a) {
			t.Errorf("%s grants the write action %q; Signal Loom never writes into the customer account (D5)", trustDocRelPath, a)
		}
	}
}

func isAllowedAction(action string) bool {
	for _, a := range allowedDataPlaneActions {
		if a == action {
			return true
		}
	}
	return false
}

func dedupe(sorted []string) []string {
	out := make([]string, 0, len(sorted))
	for i, s := range sorted {
		if i == 0 || s != sorted[i-1] {
			out = append(out, s)
		}
	}
	return out
}

// jsonBlocks returns the contents of every ```json fenced block.
var jsonFence = regexp.MustCompile("(?s)```json\\s*\\n(.*?)\\n```")

func jsonBlocks(markdown string) []string {
	matches := jsonFence.FindAllStringSubmatch(markdown, -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, m[1])
	}
	return out
}

// findTrustDoc walks up from the package directory until it finds the document.
//
// Walking beats a fixed `../../../../../` because that count is silently wrong the
// moment anything in the path is renamed — and a test that cannot find its fixture
// should fail loudly, not be quietly skipped.
func findTrustDoc(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		candidate := filepath.Join(dir, trustDocRelPath)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("could not find %s by walking up from the package directory; "+
				"the read-only trust template is a P3-GOV deliverable and must exist", trustDocRelPath)
		}
		dir = parent
	}
}
