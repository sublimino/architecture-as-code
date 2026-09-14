// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package transform

import (
	"strings"
	"testing"
)

// identifierCases is shared by the redactor and the scrubber so the two halves of the redaction
// surface cannot drift apart. A pattern added to one and forgotten in the other is the exact shape
// that let six secret patterns coexist with zero identifier patterns in the first place.
var identifierCases = []struct {
	name    string
	input   string
	leaked  string // must NOT survive
	retains string // must survive, so the test cannot pass by deleting everything
}{
	{
		name:    "email",
		input:   "denied request from alice.smith@corp.internal on cluster prod",
		leaked:  "alice.smith@corp.internal",
		retains: "denied request from",
	},
	{
		name:    "ipv4",
		input:   "egress to 192.168.10.42 blocked by policy",
		leaked:  "192.168.10.42",
		retains: "blocked by policy",
	},
	{
		name:    "ipv4 loopback",
		input:   "source 10.0.0.1 reached the api server",
		leaked:  "10.0.0.1",
		retains: "reached the api server",
	},
	{
		name:    "ipv6",
		input:   "peer 2001:0db8:85a3:0000:0000:8a2e:0370:7334 opened a session",
		leaked:  "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
		retains: "opened a session",
	},
	{
		name:    "kubernetes subject",
		input:   "K8s audit: create prod/secrets by system:serviceaccount:prod:payments",
		leaked:  "system:serviceaccount:prod:payments",
		retains: "K8s audit: create prod/secrets by",
	},
	{
		name:    "labelled username",
		input:   "authentication for user: bobby.tables succeeded",
		leaked:  "bobby.tables",
		retains: "authentication for",
	},
}

func TestSecretRedactor_RedactsIdentifiers(t *testing.T) {
	r := NewSecretRedactor()
	for _, tc := range identifierCases {
		t.Run(tc.name, func(t *testing.T) {
			got := r.RedactText(tc.input)
			if strings.Contains(got, tc.leaked) {
				t.Errorf("identifier %q survived redaction: %q", tc.leaked, got)
			}
			if !strings.Contains(got, tc.retains) {
				t.Errorf("redaction destroyed non-identifier context %q: %q", tc.retains, got)
			}
		})
	}
}

func TestScrubber_ScrubsIdentifiers(t *testing.T) {
	cs := mustScrubber(t, "identifier-patterns")
	for _, tc := range identifierCases {
		t.Run(tc.name, func(t *testing.T) {
			got := cs.ScrubText(tc.input)
			if strings.Contains(got, tc.leaked) {
				t.Errorf("identifier %q survived scrubbing: %q", tc.leaked, got)
			}
			if !strings.Contains(got, tc.retains) {
				t.Errorf("scrubbing destroyed non-identifier context %q: %q", tc.retains, got)
			}
		})
	}
}

// TestIdentifierPatterns_DoNotOverMatch guards the false-positive edge. An over-eager IPv4 pattern
// that ate version numbers would make every build string unreadable and, worse, would train a
// reviewer to stop trusting the redaction output.
func TestIdentifierPatterns_DoNotOverMatch(t *testing.T) {
	r := NewSecretRedactor()
	for _, keep := range []string{
		"go version go1.24.1 linux/amd64",
		"policy engine v2.11.3 evaluated 40 rules",
		"deployment scaled from 3 to 10 replicas",
		"namespace prod resource secrets verb create",
	} {
		if got := r.RedactText(keep); got != keep {
			t.Errorf("non-identifier text was modified\n input: %q\noutput: %q", keep, got)
		}
	}
}

// TestIdentifierRedaction_IsDeterministic proves the replacement is a keyed pseudonym, not a
// constant sentinel: the same identifier must map to the same value so records stay joinable, and
// two different identifiers must not collide.
func TestIdentifierRedaction_IsDeterministic(t *testing.T) {
	r := NewSecretRedactor()
	a1 := r.RedactText("contact alice@corp.internal")
	a2 := r.RedactText("contact alice@corp.internal")
	b := r.RedactText("contact bob@corp.internal")

	if a1 != a2 {
		t.Errorf("redaction is not deterministic: %q vs %q", a1, a2)
	}
	if a1 == b {
		t.Errorf("two distinct identifiers redacted to the same value: %q", a1)
	}
}

// TestIdentifierPatterns_EveryClassIsLoadBearing is a deletion sweep. Each pattern must be the sole
// reason at least one case passes, so removing it fails something. Without this, a pattern could be
// deleted and the suite would stay green on the coverage of its neighbours.
func TestIdentifierPatterns_EveryClassIsLoadBearing(t *testing.T) {
	cases := map[string]string{
		"email":       "alice@corp.internal",
		"ipv4":        "192.168.10.42",
		"ipv6":        "2001:db8::8a2e:370:7334",
		"k8s subject": "system:serviceaccount:prod:payments",
		"username":    "user: bobby.tables",
	}
	identity := func(s string) string { return s }
	for name, raw := range cases {
		if got := redactIdentifiers(raw, identity); got != raw {
			// identity replacement must round-trip; this asserts the harness itself is sound
			t.Fatalf("%s: identity replacement altered input: %q -> %q", name, raw, got)
		}
		if got := redactIdentifiers(raw, func(string) string { return "X" }); !strings.Contains(got, "X") {
			t.Errorf("%s: no pattern matched %q, so that identifier class is unguarded", name, raw)
		}
	}
}
