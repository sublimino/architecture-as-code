// Package policy implements the Signal Loom declarative security-invariant
// compiler. A single canonical manifest (config/security-invariants.yaml) is
// parsed into an InvariantSet and compiled into two enforcement tiers:
//
//	Tier 1 (cluster) — Kubernetes ValidatingAdmissionPolicy CEL expressions
//	Tier 0 (host)    — nono Landlock sandbox profiles
//
// Both emitters are pure functions of the same normalised rule set, which is
// what makes the cross-tier equivalence oracle in equivalence.go meaningful
// rather than decorative.
//
// See docs/signalloom/cel-landlock-policy-compiler.md for the architecture.
package policy

import (
	"fmt"
	"path"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// APIVersion and Kind are the only accepted values for an invariant manifest.
const (
	APIVersion = "signalloom.io/v1alpha1"
	Kind       = "SecurityInvariants"
)

// Compiler limits. These are named constants rather than magic numbers so a
// reader can see the whole safety envelope in one place.
const (
	// DefaultMaxPathDepth caps how many segments a declared filesystem path may
	// carry. Deep paths are both a Landlock rule-count risk on older kernels and
	// a readability problem in generated CEL.
	DefaultMaxPathDepth = 12

	// DefaultMaxExprDepth caps CEL abstract-syntax-tree height. The cel-go
	// checker recurses over the tree, so an unbounded expression is a stack
	// overflow waiting for a large rule set.
	DefaultMaxExprDepth = 32

	// DefaultMaxExprNodes caps total AST node count, which is the closest
	// structural proxy for admission-time evaluation cost.
	DefaultMaxExprNodes = 4096

	// DefaultMaxComprehensionDepth caps *nested* comprehensions. Each nesting
	// level multiplies evaluation cost, so three is the practical ceiling for an
	// admission-path expression (volumes x containers x mounts).
	DefaultMaxComprehensionDepth = 3

	// DefaultLandlockABI is the Landlock ABI level the generated profiles target.
	DefaultLandlockABI = 5

	// DefaultFailurePolicy is applied to generated ValidatingAdmissionPolicy
	// objects when the manifest does not override it.
	DefaultFailurePolicy = "Fail"
)

// Access is the permission level granted to a filesystem path. It forms a
// lattice under the bitmask returned by Mask: none < read|write < readwrite.
type Access string

// The closed set of access levels. Any other value is a parse error.
const (
	AccessNone      Access = "none"
	AccessRead      Access = "read"
	AccessWrite     Access = "write"
	AccessReadWrite Access = "readwrite"
)

// Mask returns the bitmask form of an access level. Bit 0 is read, bit 1 is
// write. Working in masks rather than string comparison is what lets Permits
// express "at least as permissive as" without a special case per pair.
func (a Access) Mask() int {
	switch a {
	case AccessRead:
		return 1
	case AccessWrite:
		return 2
	case AccessReadWrite:
		return 3
	default:
		return 0
	}
}

// Permits reports whether a grants everything b grants.
func (a Access) Permits(b Access) bool {
	return a.Mask()&b.Mask() == b.Mask()
}

// Valid reports whether a is a member of the closed access enumeration.
func (a Access) Valid() bool {
	switch a {
	case AccessNone, AccessRead, AccessWrite, AccessReadWrite:
		return true
	}
	return false
}

// Action is the verdict a process or network rule expresses.
type Action string

// The closed set of actions.
const (
	ActionAllow Action = "allow"
	ActionDeny  Action = "deny"
)

// Valid reports whether act is a member of the closed action enumeration.
func (act Action) Valid() bool { return act == ActionAllow || act == ActionDeny }

// Severity classifies an invariant for reporting. It has no effect on emission.
type Severity string

// The closed set of severities.
const (
	SeverityCritical Severity = "critical"
	SeverityHigh     Severity = "high"
	SeverityMedium   Severity = "medium"
	SeverityLow      Severity = "low"
)

// Valid reports whether s is a member of the closed severity enumeration.
func (s Severity) Valid() bool {
	switch s {
	case SeverityCritical, SeverityHigh, SeverityMedium, SeverityLow:
		return true
	}
	return false
}

// Target names an enforcement tier an invariant compiles to.
type Target string

// The closed set of targets.
const (
	TargetVAP      Target = "vap"
	TargetLandlock Target = "landlock"
)

// Valid reports whether t is a member of the closed target enumeration.
func (t Target) Valid() bool { return t == TargetVAP || t == TargetLandlock }

// Direction distinguishes outbound from inbound network rules.
type Direction string

// The closed set of directions.
const (
	DirectionConnect Direction = "connect"
	DirectionListen  Direction = "listen"
)

// Valid reports whether d is a member of the closed direction enumeration.
func (d Direction) Valid() bool { return d == DirectionConnect || d == DirectionListen }

// Metadata identifies an invariant manifest.
type Metadata struct {
	Name        string `yaml:"name" json:"name"`
	Version     string `yaml:"version" json:"version"`
	Description string `yaml:"description,omitempty" json:"description,omitempty"`
}

// Defaults carries manifest-wide compiler settings. A zero field means "use the
// package default"; Applied returns the resolved view.
type Defaults struct {
	MaxPathDepth          int    `yaml:"maxPathDepth,omitempty" json:"maxPathDepth,omitempty"`
	MaxExprDepth          int    `yaml:"maxExprDepth,omitempty" json:"maxExprDepth,omitempty"`
	MaxExprNodes          int    `yaml:"maxExprNodes,omitempty" json:"maxExprNodes,omitempty"`
	MaxComprehensionDepth int    `yaml:"maxComprehensionDepth,omitempty" json:"maxComprehensionDepth,omitempty"`
	LandlockABI           int    `yaml:"landlockAbi,omitempty" json:"landlockAbi,omitempty"`
	FailurePolicy         string `yaml:"failurePolicy,omitempty" json:"failurePolicy,omitempty"`
}

// Applied resolves zero fields to their package defaults.
func (d Defaults) Applied() Defaults {
	out := d
	if out.MaxPathDepth == 0 {
		out.MaxPathDepth = DefaultMaxPathDepth
	}
	if out.MaxExprDepth == 0 {
		out.MaxExprDepth = DefaultMaxExprDepth
	}
	if out.MaxExprNodes == 0 {
		out.MaxExprNodes = DefaultMaxExprNodes
	}
	if out.MaxComprehensionDepth == 0 {
		out.MaxComprehensionDepth = DefaultMaxComprehensionDepth
	}
	if out.LandlockABI == 0 {
		out.LandlockABI = DefaultLandlockABI
	}
	if out.FailurePolicy == "" {
		out.FailurePolicy = DefaultFailurePolicy
	}
	return out
}

// FilesystemRule grants (or withholds) access to an absolute path. Paths are
// directory-recursive: a rule on /a covers /a/b/c unless a more specific rule
// says otherwise.
type FilesystemRule struct {
	Path   string `yaml:"path" json:"path"`
	Access Access `yaml:"access" json:"access"`
	Note   string `yaml:"note,omitempty" json:"note,omitempty"`
}

// ProcessRule permits or forbids execution of a binary, optionally forbidding
// specific first arguments (which is how "git commit yes, git push no" is
// expressed without forking git).
type ProcessRule struct {
	Binary     string   `yaml:"binary" json:"binary"`
	Action     Action   `yaml:"action" json:"action"`
	DeniedArgs []string `yaml:"deniedArgs,omitempty" json:"deniedArgs,omitempty"`
	Note       string   `yaml:"note,omitempty" json:"note,omitempty"`
}

// NetworkRule permits or forbids egress to a domain and/or port.
type NetworkRule struct {
	Domain    string    `yaml:"domain,omitempty" json:"domain,omitempty"`
	Port      int       `yaml:"port,omitempty" json:"port,omitempty"`
	Action    Action    `yaml:"action" json:"action"`
	Direction Direction `yaml:"direction,omitempty" json:"direction,omitempty"`
	Note      string    `yaml:"note,omitempty" json:"note,omitempty"`
}

// Invariant is one named security statement, which may carry rules for any
// combination of the three rule domains.
type Invariant struct {
	ID          string           `yaml:"id" json:"id"`
	Title       string           `yaml:"title" json:"title"`
	Description string           `yaml:"description,omitempty" json:"description,omitempty"`
	Severity    Severity         `yaml:"severity" json:"severity"`
	Targets     []Target         `yaml:"targets" json:"targets"`
	Filesystem  []FilesystemRule `yaml:"filesystem,omitempty" json:"filesystem,omitempty"`
	Process     []ProcessRule    `yaml:"process,omitempty" json:"process,omitempty"`
	Network     []NetworkRule    `yaml:"network,omitempty" json:"network,omitempty"`
}

// InvariantSet is the root of an invariant manifest.
type InvariantSet struct {
	APIVersion string      `yaml:"apiVersion" json:"apiVersion"`
	Kind       string      `yaml:"kind" json:"kind"`
	Metadata   Metadata    `yaml:"metadata" json:"metadata"`
	Defaults   Defaults    `yaml:"defaults,omitempty" json:"defaults,omitempty"`
	Invariants []Invariant `yaml:"invariants" json:"invariants"`
}

// ParseError names the manifest location that failed so the operator does not
// have to bisect a YAML file by hand.
type ParseError struct {
	Where  string
	Detail string
}

func (e *ParseError) Error() string {
	if e.Where == "" {
		return e.Detail
	}
	return fmt.Sprintf("%s: %s", e.Where, e.Detail)
}

func perr(where, format string, args ...any) *ParseError {
	return &ParseError{Where: where, Detail: fmt.Sprintf(format, args...)}
}

// Parse decodes an invariant manifest with strict field checking and then
// validates it. Unknown keys are an error: a manifest with a misspelled field
// silently losing a rule is exactly the failure this compiler exists to remove.
func Parse(data []byte) (*InvariantSet, error) {
	dec := yaml.NewDecoder(strings.NewReader(string(data)))
	dec.KnownFields(true)

	var set InvariantSet
	if err := dec.Decode(&set); err != nil {
		return nil, perr("manifest", "yaml decode: %v", err)
	}
	if err := set.Validate(); err != nil {
		return nil, err
	}
	return &set, nil
}

// forbiddenPathRunes are rejected in declared paths. Glob metacharacters are
// refused outright rather than escaped: nono treats a path as a literal prefix,
// so a '*' that looks like a wildcard to the author is a silent no-op grant, and
// a '*' that some future loader *does* expand is an unintended widening.
const forbiddenPathRunes = "*?[]{}\x00\n\r\t"

// Validate checks the whole set and returns the first violation found. It is
// deliberately fail-fast: a manifest with two errors is fixed one at a time
// anyway, and reporting the first with a precise location beats a list.
func (s *InvariantSet) Validate() error {
	if s.APIVersion != APIVersion {
		return perr("apiVersion", "expected %q, got %q", APIVersion, s.APIVersion)
	}
	if s.Kind != Kind {
		return perr("kind", "expected %q, got %q", Kind, s.Kind)
	}
	if strings.TrimSpace(s.Metadata.Name) == "" {
		return perr("metadata.name", "must not be empty")
	}
	if strings.TrimSpace(s.Metadata.Version) == "" {
		return perr("metadata.version", "must not be empty")
	}
	if len(s.Invariants) == 0 {
		return perr("invariants", "must declare at least one invariant; an empty set compiles to an empty policy, which is silently permissive")
	}

	def := s.Defaults.Applied()
	if def.MaxPathDepth < 1 {
		return perr("defaults.maxPathDepth", "must be >= 1, got %d", def.MaxPathDepth)
	}
	switch def.FailurePolicy {
	case "Fail", "Ignore":
	default:
		return perr("defaults.failurePolicy", "must be Fail or Ignore, got %q", def.FailurePolicy)
	}

	seen := map[string]int{}
	for i := range s.Invariants {
		inv := &s.Invariants[i]
		where := fmt.Sprintf("invariants[%d]", i)

		if strings.TrimSpace(inv.ID) == "" {
			return perr(where+".id", "must not be empty")
		}
		if prev, dup := seen[inv.ID]; dup {
			return perr(where+".id", "duplicate id %q (first declared at invariants[%d])", inv.ID, prev)
		}
		seen[inv.ID] = i

		if strings.TrimSpace(inv.Title) == "" {
			return perr(where+".title", "invariant %s must have a title", inv.ID)
		}
		if !inv.Severity.Valid() {
			return perr(where+".severity", "invariant %s has unknown severity %q (want critical|high|medium|low)", inv.ID, inv.Severity)
		}
		if len(inv.Targets) == 0 {
			return perr(where+".targets", "invariant %s targets no tier; a rule that compiles nowhere is dead configuration", inv.ID)
		}
		for _, t := range inv.Targets {
			if !t.Valid() {
				return perr(where+".targets", "invariant %s has unknown target %q (want vap|landlock)", inv.ID, t)
			}
		}
		if len(inv.Filesystem) == 0 && len(inv.Process) == 0 && len(inv.Network) == 0 {
			return perr(where, "invariant %s declares no rules in any domain", inv.ID)
		}

		for j, r := range inv.Filesystem {
			rw := fmt.Sprintf("%s.filesystem[%d]", where, j)
			if err := validateFilesystemRule(rw, inv.ID, r, def.MaxPathDepth); err != nil {
				return err
			}
			// The Kubernetes volume model has exactly two mount modes, read-only
			// and read-write. There is no write-only mount, so a write-only grant
			// has no faithful admission-tier counterpart. Mapping it to either
			// mode would fabricate a permission the manifest never granted and
			// would break strict filesystem equivalence, so the manifest must say
			// which it means instead of the compiler guessing.
			if r.Access == AccessWrite && hasTarget(inv.Targets, TargetVAP) {
				return perr(rw+".access", "invariant %s: access %q cannot target the vap tier — "+
					"Kubernetes volume mounts are read-only or read-write, with no write-only mode, "+
					"so the grant has no faithful admission-tier counterpart. Use readwrite, or drop "+
					"vap from this invariant's targets.", inv.ID, AccessWrite)
			}
		}
		for j, r := range inv.Process {
			rw := fmt.Sprintf("%s.process[%d]", where, j)
			if !strings.HasPrefix(r.Binary, "/") {
				return perr(rw+".binary", "invariant %s: binary must be an absolute path, got %q", inv.ID, r.Binary)
			}
			if strings.ContainsAny(r.Binary, forbiddenPathRunes) {
				return perr(rw+".binary", "invariant %s: binary %q contains a forbidden character", inv.ID, r.Binary)
			}
			if !r.Action.Valid() {
				return perr(rw+".action", "invariant %s: unknown action %q (want allow|deny)", inv.ID, r.Action)
			}
			if r.Action == ActionDeny && len(r.DeniedArgs) > 0 {
				return perr(rw+".deniedArgs", "invariant %s: deniedArgs is only meaningful on an allow rule; a deny already forbids every argument", inv.ID)
			}
		}
		for j, r := range inv.Network {
			rw := fmt.Sprintf("%s.network[%d]", where, j)
			if r.Domain == "" && r.Port == 0 {
				return perr(rw, "invariant %s: network rule must set domain, port, or both", inv.ID)
			}
			if r.Port < 0 || r.Port > 65535 {
				return perr(rw+".port", "invariant %s: port %d out of range", inv.ID, r.Port)
			}
			if !r.Action.Valid() {
				return perr(rw+".action", "invariant %s: unknown action %q (want allow|deny)", inv.ID, r.Action)
			}
			if r.Direction != "" && !r.Direction.Valid() {
				return perr(rw+".direction", "invariant %s: unknown direction %q (want connect|listen)", inv.ID, r.Direction)
			}
			if strings.ContainsAny(r.Domain, "*?/\x00\n\r\t ") {
				return perr(rw+".domain", "invariant %s: domain %q contains a forbidden character", inv.ID, r.Domain)
			}
		}
	}
	return nil
}

func validateFilesystemRule(where, invID string, r FilesystemRule, maxDepth int) error {
	if r.Path == "" {
		return perr(where+".path", "invariant %s: path must not be empty", invID)
	}
	if !strings.HasPrefix(r.Path, "/") {
		return perr(where+".path", "invariant %s: path must be absolute, got %q", invID, r.Path)
	}
	if strings.ContainsAny(r.Path, forbiddenPathRunes) {
		return perr(where+".path", "invariant %s: path %q contains a forbidden character (glob metacharacters and control bytes are refused, never expanded)", invID, r.Path)
	}
	if !r.Access.Valid() {
		return perr(where+".access", "invariant %s: unknown access %q (want none|read|write|readwrite)", invID, r.Access)
	}
	norm := NormalisePath(r.Path)
	if d := PathDepth(norm); d > maxDepth {
		return perr(where+".path", "invariant %s: path %q has depth %d, exceeding maxPathDepth %d", invID, r.Path, d, maxDepth)
	}
	return nil
}

// NormalisePath collapses "." and ".." segments and strips a trailing slash,
// while preserving "/" itself. Normalising before emission is what stops two
// spellings of the same directory producing two Landlock rules and two CEL
// prefix tests that disagree about specificity.
func NormalisePath(p string) string {
	if p == "" {
		return ""
	}
	c := path.Clean(p)
	if c == "." {
		return "/"
	}
	return c
}

// PathDepth counts path segments. "/" is depth 0, "/a" is 1, "/a/b" is 2.
func PathDepth(p string) int {
	c := NormalisePath(p)
	if c == "/" || c == "" {
		return 0
	}
	return strings.Count(strings.TrimPrefix(c, "/"), "/") + 1
}

// IsUnder reports whether child is at or below parent, matching on whole path
// segments. It exists so that /etc/sshd is never treated as living under
// /etc/ssh, which a naive strings.HasPrefix would get wrong.
func IsUnder(child, parent string) bool {
	c, p := NormalisePath(child), NormalisePath(parent)
	if p == "/" {
		return true
	}
	return c == p || strings.HasPrefix(c, p+"/")
}

// Normalised is the canonical, flattened form of an InvariantSet: the shape both
// emitters consume. Producing it once, here, is the mechanism by which the two
// tiers cannot drift — neither generator ever sees the raw manifest.
type Normalised struct {
	Set      *InvariantSet
	Defaults Defaults

	// FS holds every filesystem rule that survives resolution, sorted by
	// descending specificity then path, so a linear scan finds the governing
	// rule first.
	FS []NormalFSRule

	Process []NormalProcessRule
	Network []NormalNetworkRule
}

// NormalFSRule is a resolved filesystem grant with provenance back to the
// invariant that produced it.
type NormalFSRule struct {
	Path        string
	Access      Access
	InvariantID string
	Targets     []Target
}

// NormalProcessRule is a resolved process-execution rule.
type NormalProcessRule struct {
	Binary      string
	Action      Action
	DeniedArgs  []string
	InvariantID string
	Targets     []Target
}

// NormalNetworkRule is a resolved network rule.
type NormalNetworkRule struct {
	Domain      string
	Port        int
	Action      Action
	Direction   Direction
	InvariantID string
	Targets     []Target
}

// Normalise flattens an InvariantSet into the canonical form.
//
// Conflict resolution for two rules on the same path is deny-wins: the more
// restrictive access is kept. That is the safe direction, and it matches the
// Landlock loader, where a deny cannot be overridden by an allow at the same
// specificity.
func (s *InvariantSet) Normalise() (*Normalised, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	n := &Normalised{Set: s, Defaults: s.Defaults.Applied()}

	byPath := map[string]*NormalFSRule{}
	for _, inv := range s.Invariants {
		for _, r := range inv.Filesystem {
			p := NormalisePath(r.Path)
			if cur, ok := byPath[p]; ok {
				// Keep the intersection of the two grants: deny wins, and a read
				// plus a write on the same path do not silently become readwrite.
				merged := Access(accessFromMask(cur.Access.Mask() & r.Access.Mask()))
				cur.Access = merged
				cur.Targets = mergeTargets(cur.Targets, inv.Targets)
				if cur.InvariantID != inv.ID {
					cur.InvariantID = cur.InvariantID + "," + inv.ID
				}
				continue
			}
			byPath[p] = &NormalFSRule{
				Path:        p,
				Access:      r.Access,
				InvariantID: inv.ID,
				Targets:     append([]Target(nil), inv.Targets...),
			}
		}
		for _, r := range inv.Process {
			n.Process = append(n.Process, NormalProcessRule{
				Binary:      NormalisePath(r.Binary),
				Action:      r.Action,
				DeniedArgs:  append([]string(nil), r.DeniedArgs...),
				InvariantID: inv.ID,
				Targets:     append([]Target(nil), inv.Targets...),
			})
		}
		for _, r := range inv.Network {
			d := r.Direction
			if d == "" {
				d = DirectionConnect
			}
			n.Network = append(n.Network, NormalNetworkRule{
				Domain:      r.Domain,
				Port:        r.Port,
				Action:      r.Action,
				Direction:   d,
				InvariantID: inv.ID,
				Targets:     append([]Target(nil), inv.Targets...),
			})
		}
	}

	for _, r := range byPath {
		sort.Slice(r.Targets, func(i, j int) bool { return r.Targets[i] < r.Targets[j] })
		n.FS = append(n.FS, *r)
	}

	// Descending specificity first, then lexicographic. A linear scan over this
	// order finds the longest-prefix match on the first hit, which is what the
	// Landlock evaluator relies on.
	sort.Slice(n.FS, func(i, j int) bool {
		di, dj := PathDepth(n.FS[i].Path), PathDepth(n.FS[j].Path)
		if di != dj {
			return di > dj
		}
		return n.FS[i].Path < n.FS[j].Path
	})
	sort.Slice(n.Process, func(i, j int) bool {
		if n.Process[i].Binary != n.Process[j].Binary {
			return n.Process[i].Binary < n.Process[j].Binary
		}
		return n.Process[i].Action < n.Process[j].Action
	})
	sort.Slice(n.Network, func(i, j int) bool {
		a, b := n.Network[i], n.Network[j]
		if a.Domain != b.Domain {
			return a.Domain < b.Domain
		}
		if a.Port != b.Port {
			return a.Port < b.Port
		}
		if a.Direction != b.Direction {
			return a.Direction < b.Direction
		}
		return a.Action < b.Action
	})
	return n, nil
}

func accessFromMask(m int) Access {
	switch m {
	case 1:
		return AccessRead
	case 2:
		return AccessWrite
	case 3:
		return AccessReadWrite
	default:
		return AccessNone
	}
}

func mergeTargets(a, b []Target) []Target {
	seen := map[Target]bool{}
	for _, t := range a {
		seen[t] = true
	}
	for _, t := range b {
		seen[t] = true
	}
	out := make([]Target, 0, len(seen))
	for t := range seen {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// ForTarget returns the filesystem rules that compile to tier t.
func (n *Normalised) ForTarget(t Target) []NormalFSRule {
	var out []NormalFSRule
	for _, r := range n.FS {
		if hasTarget(r.Targets, t) {
			out = append(out, r)
		}
	}
	return out
}

// ProcessForTarget returns the process rules that compile to tier t.
func (n *Normalised) ProcessForTarget(t Target) []NormalProcessRule {
	var out []NormalProcessRule
	for _, r := range n.Process {
		if hasTarget(r.Targets, t) {
			out = append(out, r)
		}
	}
	return out
}

// NetworkForTarget returns the network rules that compile to tier t.
func (n *Normalised) NetworkForTarget(t Target) []NormalNetworkRule {
	var out []NormalNetworkRule
	for _, r := range n.Network {
		if hasTarget(r.Targets, t) {
			out = append(out, r)
		}
	}
	return out
}

func hasTarget(ts []Target, want Target) bool {
	for _, t := range ts {
		if t == want {
			return true
		}
	}
	return false
}
