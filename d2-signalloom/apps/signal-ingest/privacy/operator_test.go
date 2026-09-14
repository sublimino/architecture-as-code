package privacy

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestOperatorRegistryRejectsMalformedEntries(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")
	good := []Operator{
		{ID: alice.id, PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
		{ID: bob.id, PublicKey: bob.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
	}
	// Sanity first, or every negative case below is vacuous.
	if _, err := NewOperatorRegistry(good); err != nil {
		t.Fatalf("the well-formed registry was rejected; every negative case below is vacuous: %v", err)
	}

	cases := map[string][]Operator{
		"empty registry": {},
		"nil registry":   nil,
		"empty operator id": {
			{ID: "", PublicKey: alice.public}, {ID: bob.id, PublicKey: bob.public},
		},
		"duplicate operator id": {
			{ID: "op-alice", PublicKey: alice.public}, {ID: "op-alice", PublicKey: bob.public},
		},
		"short public key": {
			{ID: alice.id, PublicKey: alice.public[:16]}, {ID: bob.id, PublicKey: bob.public},
		},
		"missing public key": {
			{ID: alice.id}, {ID: bob.id, PublicKey: bob.public},
		},
		"malformed base64 key": {
			{ID: alice.id, PublicKeyB64: "!!!not-base64!!!"}, {ID: bob.id, PublicKey: bob.public},
		},
	}
	for name, ops := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := NewOperatorRegistry(ops); err == nil {
				t.Fatalf("registry accepted %s", name)
			}
		})
	}
}

// TestOperatorRegistryIsBounded is the anti-theatre assertion.
//
// "Two distinct approvals" is satisfiable by any two members of the authorised set, so an unbounded
// set turns dual authorisation into a recruitment problem rather than a security control. The
// boundary is exercised from both sides: at the limit must succeed, one over must fail. Testing
// only the rejecting side would pass for a registry that rejected everything.
func TestOperatorRegistryIsBounded(t *testing.T) {
	build := func(n int) []Operator {
		out := make([]Operator, 0, n)
		for i := 0; i < n; i++ {
			op := newTestOperator(t, string(rune('a'+i%26))+"-"+itoa(i))
			out = append(out, Operator{ID: op.id, PublicKey: op.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}})
		}
		return out
	}
	atLimit, err := NewOperatorRegistry(build(MaxOperators))
	if err != nil {
		t.Fatalf("a registry of exactly MaxOperators=%d was rejected: %v", MaxOperators, err)
	}
	if atLimit.Len() != MaxOperators {
		t.Errorf("registry reports %d entries, want %d", atLimit.Len(), MaxOperators)
	}
	if _, err := NewOperatorRegistry(build(MaxOperators + 1)); err == nil {
		t.Fatalf("a registry of %d entries was accepted; MaxOperators=%d is not enforced and dual authorisation is satisfiable by scale",
			MaxOperators+1, MaxOperators)
	}
}

// TestOperatorRegistryLookupDistinguishesAbsentFromZeroValued guards the two-value return.
//
// A bare Operator return would make an unregistered ID indistinguishable from a registered one
// holding no capabilities, and those must produce different errors: one is "you are not authorised
// to be here at all", the other is "you are, but not for this".
func TestOperatorRegistryLookupDistinguishesAbsentFromZeroValued(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	uncapable := newTestOperator(t, "op-readonly")
	reg, err := NewOperatorRegistry([]Operator{
		{ID: alice.id, PublicKey: alice.public, Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
		{ID: uncapable.id, PublicKey: uncapable.public}, // registered, no capabilities
	})
	if err != nil {
		t.Fatalf("build registry: %v", err)
	}

	if _, ok := reg.Lookup("op-nobody"); ok {
		t.Error("an unregistered id was found in the registry")
	}
	op, ok := reg.Lookup(uncapable.id)
	if !ok {
		t.Fatal("a registered operator was not found")
	}
	if op.Can(CapabilityGrantErasureOverride) {
		t.Error("an operator with no capabilities reports holding the override capability")
	}

	if _, err := reg.authorise("op-nobody"); err == nil {
		t.Error("authorise accepted an unregistered operator")
	} else if !strings.Contains(err.Error(), "not in the authorised registry") {
		t.Errorf("unregistered operator produced the wrong error: %v", err)
	}
	if _, err := reg.authorise(uncapable.id); err == nil {
		t.Error("authorise accepted an operator lacking the capability")
	}
	if _, err := reg.authorise(alice.id); err != nil {
		t.Errorf("authorise rejected a capable registered operator: %v", err)
	}
}

// TestOperatorRegistryFromEnvFailsClosed covers the configuration path.
//
// An absent variable must be an error, never an empty permissive registry. A service that boots
// with no authorised operators and calls that "nobody can override" sounds safe until you notice
// it also means the deployment was misconfigured and nobody was told.
func TestOperatorRegistryFromEnvFailsClosed(t *testing.T) {
	alice := newTestOperator(t, "op-alice")
	bob := newTestOperator(t, "op-bob")

	t.Run("absent variable errors", func(t *testing.T) {
		t.Setenv(OperatorRegistryEnvVar, "")
		reg, err := OperatorRegistryFromEnv()
		if err == nil {
			t.Fatal("an absent operator registry variable produced a registry instead of an error")
		}
		if reg != nil {
			t.Error("an error path still returned a registry")
		}
	})

	t.Run("malformed json errors", func(t *testing.T) {
		t.Setenv(OperatorRegistryEnvVar, "{not json")
		if _, err := OperatorRegistryFromEnv(); err == nil {
			t.Fatal("malformed JSON produced a registry instead of an error")
		}
	})

	t.Run("empty json array errors", func(t *testing.T) {
		t.Setenv(OperatorRegistryEnvVar, "[]")
		if _, err := OperatorRegistryFromEnv(); err == nil {
			t.Fatal("an empty JSON array produced an empty registry instead of an error")
		}
	})

	// The positive case, so the block above cannot pass for a function that always errors.
	t.Run("well-formed json loads", func(t *testing.T) {
		raw, err := json.Marshal([]Operator{
			{ID: alice.id, PublicKeyB64: base64.StdEncoding.EncodeToString(alice.public), Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
			{ID: bob.id, PublicKeyB64: base64.StdEncoding.EncodeToString(bob.public), Capabilities: []OperatorCapability{CapabilityGrantErasureOverride}},
		})
		if err != nil {
			t.Fatalf("marshal fixture: %v", err)
		}
		t.Setenv(OperatorRegistryEnvVar, string(raw))
		reg, err := OperatorRegistryFromEnv()
		if err != nil {
			t.Fatalf("a well-formed registry failed to load: %v", err)
		}
		if reg.Len() != 2 {
			t.Fatalf("loaded %d operators, want 2", reg.Len())
		}
		got, ok := reg.Lookup(alice.id)
		if !ok {
			t.Fatal("alice is missing from the loaded registry")
		}
		if len(got.PublicKey) != ed25519.PublicKeySize {
			t.Errorf("loaded key is %d bytes, want %d", len(got.PublicKey), ed25519.PublicKeySize)
		}
		// The decoded key must actually be alice's, not merely well-formed. A base64 decode that
		// silently produced the wrong bytes would pass a length check.
		if string(got.PublicKey) != string(alice.public) {
			t.Error("the loaded public key does not match the configured one")
		}
		if !got.Can(CapabilityGrantErasureOverride) {
			t.Error("capabilities did not survive JSON loading")
		}
	})
}

// TestOperatorRegistryIDsAreSorted keeps posture output stable.
func TestOperatorRegistryIDsAreSorted(t *testing.T) {
	c := newTestOperator(t, "op-carol")
	a := newTestOperator(t, "op-alice")
	b := newTestOperator(t, "op-bob")
	reg := registryOf(t, c, a, b)
	got := reg.IDs()
	want := []string{"op-alice", "op-bob", "op-carol"}
	if len(got) != len(want) {
		t.Fatalf("IDs() returned %d entries, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("IDs() = %v, want %v", got, want)
		}
	}
}

// itoa avoids importing strconv for one call in a loop.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
