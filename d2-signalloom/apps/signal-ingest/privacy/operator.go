package privacy

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
)

// MaxOperators bounds the number of operators who may hold override-granting authority.
//
// The bound is the control, not the number. "Two distinct approvals" is satisfiable by any two
// members of the authorised set, so an unbounded set makes dual authorisation theatre: at a
// thousand members, two willing signatures are a recruitment problem rather than a security one.
// Thirty-two is set to comfortably exceed a real second-line/legal/DPO roster across time zones
// while staying small enough that every member is individually accountable and the list can be
// read in one screen during an audit. It is deliberately a compile-time constant: a configurable
// bound is a bound an operator under pressure can raise.
const MaxOperators = 32

// OperatorCapability names an authority an operator may hold.
type OperatorCapability string

const (
	// CapabilityGrantErasureOverride permits the operator to co-sign a retention exception that
	// overrides a legal hold. Holding a place in the registry is not sufficient; the capability
	// must be granted explicitly, so that read-only or break-glass identities can be registered
	// without acquiring override authority as a side effect.
	CapabilityGrantErasureOverride OperatorCapability = "erasure:grant_override"
)

// Operator is a named human authorised to act on retention exceptions.
type Operator struct {
	// ID is the operator's stable identity, recorded verbatim in every decision they authorise.
	ID string `json:"id"`

	// PublicKey is the operator's Ed25519 verification key.
	PublicKey ed25519.PublicKey `json:"-"`

	// PublicKeyB64 is the base64 (standard encoding) form used for JSON configuration.
	PublicKeyB64 string `json:"public_key"`

	// Capabilities is the set of authorities granted to this operator.
	Capabilities []OperatorCapability `json:"capabilities"`
}

// Can reports whether the operator holds capability c.
func (o Operator) Can(c OperatorCapability) bool {
	for _, held := range o.Capabilities {
		if held == c {
			return true
		}
	}
	return false
}

// OperatorRegistry is the bounded, explicitly-enumerated set of operators.
//
// There is no "add" method. The registry is immutable after construction so that the set of people
// who can authorise evidence destruction cannot grow during the incident in which someone wants it
// to.
type OperatorRegistry struct {
	byID map[string]Operator
}

var (
	// ErrOperatorNotRegistered is returned when an approval names an operator absent from the
	// registry.
	ErrOperatorNotRegistered = errors.New("operator is not in the authorised registry")

	// ErrOperatorLacksCapability is returned when a registered operator lacks the capability the
	// action requires.
	ErrOperatorLacksCapability = errors.New("operator is registered but lacks the erasure override capability")
)

// NewOperatorRegistry builds an immutable registry from an explicit operator list.
//
// Every validation here refuses rather than repairs. A registry that silently drops a malformed
// entry is a registry whose size nobody can predict, and a registry that accepts an empty ID has a
// member whose approvals cannot be attributed to anyone.
func NewOperatorRegistry(operators []Operator) (*OperatorRegistry, error) {
	if len(operators) == 0 {
		return nil, errors.New("operator registry must not be empty: an empty registry cannot satisfy dual authorisation and must not be constructable as a permissive default")
	}
	if len(operators) > MaxOperators {
		return nil, fmt.Errorf("operator registry has %d entries, exceeding MaxOperators=%d: an unbounded authorised set makes dual authorisation satisfiable by scale", len(operators), MaxOperators)
	}
	byID := make(map[string]Operator, len(operators))
	// byKey catches the same defect the id check catches, via the other identifier.
	//
	// Rejecting a duplicate ID and then accepting a duplicate PUBLIC KEY enforces the distinctness
	// rule against names while leaving it unenforced against people. Two entries with different ids
	// and one key — say "alice" and "alice-oncall", which is ordinary configuration drift rather
	// than an attack — let one human sign twice under two identities. Both signatures verify
	// against the same registered key, `seen` holds two distinct entries, and MinApprovals is
	// satisfied by one person. The registry is the only place this can be caught, because by
	// verification time the two approvals are genuinely distinct.
	byKey := make(map[string]string, len(operators))
	for i, op := range operators {
		if op.ID == "" {
			return nil, fmt.Errorf("operator %d has an empty id: an approval that cannot be attributed to a named person is not an approval", i)
		}
		if _, dup := byID[op.ID]; dup {
			return nil, fmt.Errorf("duplicate operator id %q: two registry entries sharing an id would let one person satisfy the distinctness rule twice", op.ID)
		}
		key := op.PublicKey
		if len(key) == 0 && op.PublicKeyB64 != "" {
			decoded, err := base64.StdEncoding.DecodeString(op.PublicKeyB64)
			if err != nil {
				return nil, fmt.Errorf("operator %q public key is not valid base64: %w", op.ID, err)
			}
			key = ed25519.PublicKey(decoded)
		}
		if len(key) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("operator %q public key is %d bytes, want %d", op.ID, len(key), ed25519.PublicKeySize)
		}
		op.PublicKey = key
		op.PublicKeyB64 = base64.StdEncoding.EncodeToString(key)
		if other, dup := byKey[op.PublicKeyB64]; dup {
			return nil, fmt.Errorf("operators %q and %q share a public key: one human enrolled under two identities satisfies dual authorisation alone", other, op.ID)
		}
		byKey[op.PublicKeyB64] = op.ID
		byID[op.ID] = op
	}
	return &OperatorRegistry{byID: byID}, nil
}

// Lookup returns the operator with the given ID.
//
// The second return value distinguishes "absent" from "present but zero-valued". Returning a bare
// Operator would make an unregistered ID indistinguishable from a registered one with no
// capabilities, and the two must produce different errors.
func (r *OperatorRegistry) Lookup(id string) (Operator, bool) {
	if r == nil {
		return Operator{}, false
	}
	op, ok := r.byID[id]
	return op, ok
}

// Len returns the number of registered operators.
func (r *OperatorRegistry) Len() int {
	if r == nil {
		return 0
	}
	return len(r.byID)
}

// IDs returns every registered operator ID in sorted order, for posture reporting and audit.
func (r *OperatorRegistry) IDs() []string {
	if r == nil {
		return nil
	}
	out := make([]string, 0, len(r.byID))
	for id := range r.byID {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// authorise resolves an operator ID to a registry entry holding the override capability.
func (r *OperatorRegistry) authorise(id string) (Operator, error) {
	op, ok := r.Lookup(id)
	if !ok {
		return Operator{}, fmt.Errorf("%w: %q", ErrOperatorNotRegistered, id)
	}
	if !op.Can(CapabilityGrantErasureOverride) {
		return Operator{}, fmt.Errorf("%w: %q", ErrOperatorLacksCapability, id)
	}
	return op, nil
}

// OperatorRegistryEnvVar names the environment variable carrying the JSON operator registry. The
// shape mirrors SIGNAL_AUTH_BINDINGS so that operators configuring this service meet one format,
// not two.
const OperatorRegistryEnvVar = "SIGNAL_ERASURE_OPERATORS"

// OperatorRegistryFromEnv loads the registry from OperatorRegistryEnvVar.
//
// An absent variable is an error, not an empty registry. This is the same fail-closed reasoning as
// identity.NewEncryptorFromKeyString refusing a passthrough encryptor on an empty key: a service
// that boots with no authorised operators and treats that as "nobody can override" sounds safe
// until you notice it also means the deployment was misconfigured and nobody was told.
func OperatorRegistryFromEnv() (*OperatorRegistry, error) {
	raw := os.Getenv(OperatorRegistryEnvVar)
	if raw == "" {
		return nil, fmt.Errorf("%s is required: the set of operators authorised to override a legal hold must be explicitly configured", OperatorRegistryEnvVar)
	}
	var operators []Operator
	if err := json.Unmarshal([]byte(raw), &operators); err != nil {
		return nil, fmt.Errorf("parse %s: %w", OperatorRegistryEnvVar, err)
	}
	return NewOperatorRegistry(operators)
}
