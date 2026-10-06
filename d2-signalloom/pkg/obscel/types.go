package obscel

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"
	"time"
)

// ObsVar is the single CEL variable name every observation rule evaluates over.
const ObsVar = "obs"

// Sources written back into the signal store by the pipeline (D3).
const (
	SourceFinding  = "policy_finding"
	SourceDecision = "policy_decision"
)

// Mode is the staged-enforcement mode of a bundle (§3, D2).
type Mode string

const (
	ModeShadow  Mode = "shadow"
	ModeWarn    Mode = "warn"
	ModeEnforce Mode = "enforce"
)

// Observation is the projection of a signal-ingest model.Observation that CEL sees.
// It is deliberately decoupled from the app type so this module imports neither app.
type Observation struct {
	ID         string            `json:"id"`
	Timestamp  time.Time         `json:"timestamp"`
	Layer      string            `json:"layer"`
	Source     string            `json:"source"`
	Fidelity   string            `json:"fidelity"`
	Confidence float64           `json:"confidence"`
	TenantID   string            `json:"tenant_id"`
	Actor      string            `json:"actor"`
	Labels     map[string]string `json:"labels"`
}

// Rule is a stage-1 predicate.
type Rule struct {
	ID         string `yaml:"id" json:"id"`
	Name       string `yaml:"name" json:"name"`
	Expression string `yaml:"expression" json:"expression"`
	Severity   string `yaml:"severity" json:"severity"`
}

// Window is a stage-2 counter declared in the bundle, never in CEL.
type Window struct {
	ID        string        `yaml:"id" json:"id"`
	OverRule  string        `yaml:"over_rule" json:"over_rule"`
	Key       []string      `yaml:"key" json:"key"`
	Window    time.Duration `yaml:"window" json:"window"`
	Threshold int           `yaml:"threshold" json:"threshold"`
	Severity  string        `yaml:"severity" json:"severity"`
}

// Bundle is the versioned file under policy/bundles/<tenant>/ (D6).
type Bundle struct {
	ID       string              `yaml:"id" json:"id"`
	TenantID string              `yaml:"tenant_id" json:"tenant_id"`
	Version  string              `yaml:"version" json:"version"`
	Mode     Mode                `yaml:"mode" json:"mode"`
	Vars     map[string][]string `yaml:"vars" json:"vars"`

	// ActorVars names the entries of Vars that hold ACTOR IDENTITIES, so they can
	// be pseudonymised at load with the same key obs.actor is pseudonymised with
	// (PseudonymiseActorVars). A list that is not named here is left verbatim.
	//
	// It is an explicit declaration rather than a naming convention (`*_actors`)
	// because a name is a claim and this needs to be a fact: a var that holds
	// actors but is not named here keeps its cleartext values, so
	// `obs.actor in vars.X` can never be true, so the NEGATIVE form every shipped
	// rule uses is always true and the allowlisted identity fires on every
	// record. Counts stay equal between live and replay, so the replay oracle
	// reports parity while the detection is inverted -- the one failure shape
	// nothing downstream can see.
	//
	// What makes the declaration safe is that forgetting it is a LOAD-TIME
	// REFUSAL, not a silent miss: Conform rejects any rule that compares
	// obs.actor against a var absent from this list. The convention could not
	// offer that, and it would additionally mangle a var that merely happened to
	// be named `*_actors` without holding actors.
	ActorVars []string `yaml:"actor_vars" json:"actor_vars"`

	Rules   []Rule   `yaml:"rules" json:"rules"`
	Windows []Window `yaml:"windows" json:"windows"`
}

// Finding is stage-1 output. Its ID and Timestamp are derived (see package doc).
type Finding struct {
	ID            string            `json:"id"`
	Timestamp     time.Time         `json:"timestamp"`
	TenantID      string            `json:"tenant_id"`
	Actor         string            `json:"actor"`
	RuleID        string            `json:"rule_id"`
	BundleID      string            `json:"bundle_id"`
	BundleVersion string            `json:"bundle_version"`
	Severity      string            `json:"severity"`
	SourceObsID   string            `json:"source_observation_id"`
	Labels        map[string]string `json:"labels"`
}

// Decision is stage-2 output.
type Decision struct {
	ID            string    `json:"id"`
	Timestamp     time.Time `json:"timestamp"`
	TenantID      string    `json:"tenant_id"`
	Actor         string    `json:"actor"`
	WindowID      string    `json:"window_id"`
	RuleID        string    `json:"rule_id"`
	BundleID      string    `json:"bundle_id"`
	BundleVersion string    `json:"bundle_version"`
	Severity      string    `json:"severity"`
	Mode          Mode      `json:"mode"`
	FindingIDs    []string  `json:"finding_ids"`
	Count         int       `json:"count"`
}

// Evaluator is the in-process stage-1 contract both apps code against (ISC-40).
type Evaluator interface {
	// EvaluateObservation returns zero or more findings. It never returns an error for
	// a rule that evaluates false; errors are evaluator faults and must not block a write.
	EvaluateObservation(obs Observation, b *Bundle) ([]Finding, error)
}

// FindingID derives the canonical finding identifier.
func FindingID(tenantID, ruleID, bundleVersion, sourceObsID string) string {
	sum := sha256.Sum256([]byte(tenantID + "|" + ruleID + "|" + bundleVersion + "|" + sourceObsID))
	return hex.EncodeToString(sum[:])
}

// DecisionID derives the canonical decision identifier from the sorted finding IDs.
func DecisionID(tenantID, ruleID, windowKey string, findingIDs []string) string {
	ids := append([]string(nil), findingIDs...)
	sort.Strings(ids)
	sum := sha256.Sum256([]byte(tenantID + "|" + ruleID + "|" + windowKey + "|" + strings.Join(ids, ",")))
	return hex.EncodeToString(sum[:])
}

// SortedLabelKeys returns label keys in canonical order.
func SortedLabelKeys(labels map[string]string) []string {
	keys := make([]string, 0, len(labels))
	for k := range labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// CanonicalFinding is the allowlisted projection the replay oracle compares.
// Store-assigned fields never appear here.
func CanonicalFinding(f Finding) string {
	var b strings.Builder
	b.WriteString(f.ID)
	b.WriteString("|")
	b.WriteString(f.Timestamp.UTC().Format(time.RFC3339Nano))
	b.WriteString("|")
	b.WriteString(f.TenantID)
	b.WriteString("|")
	b.WriteString(f.Actor)
	b.WriteString("|")
	b.WriteString(f.RuleID)
	b.WriteString("|")
	b.WriteString(f.BundleID)
	b.WriteString("@")
	b.WriteString(f.BundleVersion)
	b.WriteString("|")
	b.WriteString(f.Severity)
	b.WriteString("|")
	b.WriteString(f.SourceObsID)
	for _, k := range SortedLabelKeys(f.Labels) {
		b.WriteString("|")
		b.WriteString(k)
		b.WriteString("=")
		b.WriteString(f.Labels[k])
	}
	return b.String()
}
