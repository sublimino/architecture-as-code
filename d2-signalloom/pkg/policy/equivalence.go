package policy

import (
	"fmt"
	"sort"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
)

// Cross-tier semantic equivalence.
//
// Landlock mediates a host process's syscalls against host paths. A
// ValidatingAdmissionPolicy mediates an API object at admission time. Those are
// different subjects, so "identical verdicts everywhere" is not a hard claim —
// it is a category error, because a VAP cannot deny a syscall.
//
// What IS provable, and what this file proves, is that both emitters are pure
// functions of one normalised (path, access) relation, and that on the domain
// where both tiers are defined they agree exactly. Two distinct claims, held to
// two distinct standards:
//
//	FILESYSTEM — StrictEquality. A pod reaches a host path through exactly one
//	channel, a hostPath volume. So for every probe point the Landlock verdict and
//	the admission verdict must be equal. The admission verdict is obtained by
//	EVALUATING THE EMITTED CEL through cel-go against a synthetic Pod — not by
//	re-deriving it in Go, which would make the test agree with itself.
//
//	NETWORK and PROCESS — Coverage. The admission tier cannot observe an egress
//	destination or the host binary that will execute, so no verdict comparison is
//	meaningful. The checkable claim is that every rule targeting both tiers is
//	represented in both artefacts, and that neither artefact grants anything the
//	manifest does not declare.

// EquivalenceMode names the standard a domain is held to.
type EquivalenceMode string

// The two equivalence standards.
const (
	// ModeStrict asserts identical verdicts on every probe point.
	ModeStrict EquivalenceMode = "strict-verdict-equality"
	// ModeCoverage asserts mutual representation of every dual-targeted rule.
	ModeCoverage EquivalenceMode = "coverage"
)

// Divergence is one disagreement between the two tiers.
type Divergence struct {
	Domain          Domain `json:"domain"`
	Subject         string `json:"subject"`
	Operation       string `json:"operation,omitempty"`
	LandlockVerdict string `json:"landlockVerdict"`
	VAPVerdict      string `json:"vapVerdict"`
	Detail          string `json:"detail"`
}

// DomainResult is the equivalence outcome for one rule domain.
type DomainResult struct {
	Domain      Domain          `json:"domain"`
	Mode        EquivalenceMode `json:"mode"`
	ProbePoints int             `json:"probePoints"`
	Divergences []Divergence    `json:"divergences"`
	Equivalent  bool            `json:"equivalent"`
}

// EquivalenceReport is the machine-readable equivalence verdict.
type EquivalenceReport struct {
	Equivalent bool           `json:"equivalent"`
	Domains    []DomainResult `json:"domains"`
	Probes     []string       `json:"probes"`
}

// EffectiveAccess resolves the access level in force at p under the Landlock
// resolution rules: longest matching prefix wins, deny wins at equal
// specificity, and an unmatched path is denied.
//
// This is deliberately a different algorithm from the depth-keyed ternary chain
// the CEL generator emits. Two implementations that agree are evidence; one
// implementation called twice is not.
func EffectiveAccess(rules []NormalFSRule, p string) Access {
	target := NormalisePath(p)
	bestDepth := -1
	acc := AccessNone
	found := false

	for _, r := range rules {
		if !IsUnder(target, r.Path) {
			continue
		}
		d := PathDepth(r.Path)
		switch {
		case d > bestDepth:
			bestDepth, acc, found = d, r.Access, true
		case d == bestDepth:
			// Cannot normally happen — two distinct paths of equal depth cannot
			// both prefix the same target — but intersecting rather than picking
			// arbitrarily keeps the resolution deny-biased if it ever does.
			acc = accessFromMask(acc.Mask() & r.Access.Mask())
		}
	}
	if !found {
		return AccessNone
	}
	return acc
}

// LandlockPermits reports whether the host tier would allow op at p.
func LandlockPermits(rules []NormalFSRule, p string, op Access) bool {
	return EffectiveAccess(rules, p).Permits(op)
}

// SyntheticPod builds the AdmissionReview object used as a probe: one hostPath
// volume at path, mounted by one container with the given readOnly setting.
func SyntheticPod(hostPath string, readOnly bool) map[string]any {
	return map[string]any{
		"kind": "Pod",
		"metadata": map[string]any{
			"name":      "equivalence-probe",
			"namespace": "signalloom-probe",
		},
		"spec": map[string]any{
			"volumes": []any{
				map[string]any{
					"name":     "probe",
					"hostPath": map[string]any{"path": hostPath, "type": "Directory"},
				},
			},
			"containers": []any{
				map[string]any{
					"name":  "probe",
					"image": "registry.invalid/probe@sha256:" + zeroDigest,
					"volumeMounts": []any{
						map[string]any{
							"name":      "probe",
							"mountPath": "/mnt/probe",
							"readOnly":  readOnly,
						},
					},
				},
			},
		},
	}
}

const zeroDigest = "0000000000000000000000000000000000000000000000000000000000000000"

// Evaluator compiles emitted CEL once and evaluates it against probe objects.
type Evaluator struct {
	env      *cel.Env
	programs map[string]cel.Program
}

// NewEvaluator compiles each named expression in the SP-4 environment. Using the
// same constrained environment the linter uses means the oracle cannot pass an
// expression the linter would reject.
func NewEvaluator(exprs map[string]string) (*Evaluator, error) {
	env, err := SP4Env()
	if err != nil {
		return nil, err
	}
	ev := &Evaluator{env: env, programs: map[string]cel.Program{}}
	for name, src := range exprs {
		ast, iss := env.Compile(src)
		if iss != nil && iss.Err() != nil {
			return nil, fmt.Errorf("compile %s: %w", name, iss.Err())
		}
		prg, err := env.Program(ast)
		if err != nil {
			return nil, fmt.Errorf("plan %s: %w", name, err)
		}
		ev.programs[name] = prg
	}
	return ev, nil
}

// emptyActivation supplies every declared VAP variable. cel-go errors on an
// unbound reference at evaluation time, and an evaluation error must not be
// silently read as "denied" — so every variable gets a value even though the
// generated expressions only reach for `object`.
func activation(object map[string]any) map[string]any {
	return map[string]any{
		"object":          object,
		"oldObject":       map[string]any{},
		"request":         map[string]any{"operation": "CREATE"},
		"params":          map[string]any{},
		"namespaceObject": map[string]any{},
		"authorizer":      map[string]any{},
		"variables":       map[string]any{},
	}
}

// Admits evaluates every compiled expression against object and reports whether
// all of them hold. An evaluation error is returned, never folded into a
// verdict: "the policy could not be evaluated" and "the policy denied this" are
// different facts and conflating them is how a broken guard reads as a working
// one.
func (e *Evaluator) Admits(object map[string]any) (bool, error) {
	names := make([]string, 0, len(e.programs))
	for n := range e.programs {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, n := range names {
		out, _, err := e.programs[n].Eval(activation(object))
		if err != nil {
			return false, fmt.Errorf("eval %s: %w", n, err)
		}
		b, ok := out.(ref.Val).Value().(bool)
		if !ok {
			return false, fmt.Errorf("eval %s: expression returned %T, want bool", n, out.Value())
		}
		if types.Bool(b) != types.True {
			return false, nil
		}
	}
	return true, nil
}

// ProbePoints derives the path probe matrix from the rule set: each declared
// path exactly, a child of it, a sibling of it, plus fixed unrelated paths.
//
// Testing only declared paths would miss every prefix-matching bug, which is the
// defect class this compiler is most likely to have.
func ProbePoints(rules []NormalFSRule) []string {
	seen := map[string]bool{}
	add := func(p string) {
		p = NormalisePath(p)
		if p != "" && !seen[p] {
			seen[p] = true
		}
	}
	for _, r := range rules {
		add(r.Path)
		add(r.Path + "/child-probe")
		add(r.Path + "/child-probe/grandchild")
		// A sibling whose name shares the parent's prefix catches the classic
		// /etc/sshd-matches-/etc/ssh substring bug.
		add(r.Path + "-sibling")
	}
	add("/nonexistent-probe-root")
	add("/")
	add("/tmp/unrelated-probe")

	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// CheckEquivalence runs the full cross-tier audit.
func CheckEquivalence(n *Normalised, bundles []VAPBundle, profile *NonoProfile) (*EquivalenceReport, error) {
	rep := &EquivalenceReport{Equivalent: true}

	fsRes, probes, err := checkFilesystemEquivalence(n)
	if err != nil {
		return nil, err
	}
	rep.Probes = probes
	rep.Domains = append(rep.Domains, fsRes)

	rep.Domains = append(rep.Domains, checkNetworkCoverage(n, bundles, profile))
	rep.Domains = append(rep.Domains, checkProcessCoverage(n, bundles, profile))

	for _, d := range rep.Domains {
		if !d.Equivalent {
			rep.Equivalent = false
		}
	}
	return rep, nil
}

func checkFilesystemEquivalence(n *Normalised) (DomainResult, []string, error) {
	res := DomainResult{Domain: DomainFilesystem, Mode: ModeStrict, Equivalent: true, Divergences: []Divergence{}}

	vapRules := n.ForTarget(TargetVAP)
	llRules := n.ForTarget(TargetLandlock)
	if len(vapRules) == 0 || len(llRules) == 0 {
		// Only one tier carries filesystem rules. There is nothing to compare, and
		// reporting "equivalent" for an unperformed comparison would be the
		// absence-read-as-confirmation failure this project keeps finding.
		res.Mode = ModeCoverage
		res.Divergences = append(res.Divergences, Divergence{
			Domain:  DomainFilesystem,
			Subject: "<tiers>",
			Detail: fmt.Sprintf("filesystem rules target only one tier (vap=%d, landlock=%d); "+
				"no cross-tier comparison was performed", len(vapRules), len(llRules)),
			LandlockVerdict: "n/a", VAPVerdict: "n/a",
		})
		res.Equivalent = false
		return res, nil, nil
	}

	ev, err := NewEvaluator(FilesystemExpressions(vapRules))
	if err != nil {
		return res, nil, err
	}

	probes := ProbePoints(append(append([]NormalFSRule{}, vapRules...), llRules...))
	res.ProbePoints = len(probes) * 2

	for _, p := range probes {
		for _, ro := range []bool{true, false} {
			op := AccessReadWrite
			opName := "read-write"
			if ro {
				op = AccessRead
				opName = "read-only"
			}

			land := LandlockPermits(llRules, p, op)
			admitted, err := ev.Admits(SyntheticPod(p, ro))
			if err != nil {
				return res, probes, fmt.Errorf("probe %s (%s): %w", p, opName, err)
			}
			if land != admitted {
				res.Divergences = append(res.Divergences, Divergence{
					Domain:          DomainFilesystem,
					Subject:         p,
					Operation:       opName,
					LandlockVerdict: verdict(land),
					VAPVerdict:      verdict(admitted),
					Detail: fmt.Sprintf("effective Landlock access at %s is %q; admission %s the equivalent hostPath mount",
						p, EffectiveAccess(llRules, p), admittedWord(admitted)),
				})
			}
		}
	}
	res.Equivalent = len(res.Divergences) == 0
	return res, probes, nil
}

func verdict(b bool) string {
	if b {
		return "allow"
	}
	return "deny"
}

func admittedWord(b bool) string {
	if b {
		return "admits"
	}
	return "refuses"
}

func checkNetworkCoverage(n *Normalised, bundles []VAPBundle, profile *NonoProfile) DomainResult {
	res := DomainResult{Domain: DomainNetwork, Mode: ModeCoverage, Equivalent: true, Divergences: []Divergence{}}

	vapHasNetwork := false
	for _, b := range bundles {
		if b.Domain == DomainNetwork {
			vapHasNetwork = true
		}
	}
	denyDomains := map[string]bool{}
	for _, d := range profile.Network.DenyDomain {
		denyDomains[d] = true
	}
	allowDomains := map[string]bool{}
	for _, d := range profile.Network.AllowDomain {
		allowDomains[d] = true
	}

	declaredAllow := map[string]bool{}
	for _, r := range n.Network {
		res.ProbePoints++
		dual := hasTarget(r.Targets, TargetVAP) && hasTarget(r.Targets, TargetLandlock)

		if r.Action == ActionAllow && r.Domain != "" {
			declaredAllow[r.Domain] = true
		}
		if r.Action != ActionDeny || r.Domain == "" {
			continue
		}
		if hasTarget(r.Targets, TargetLandlock) && !denyDomains[r.Domain] {
			res.Divergences = append(res.Divergences, Divergence{
				Domain: DomainNetwork, Subject: r.Domain,
				LandlockVerdict: "absent", VAPVerdict: "n/a",
				Detail: fmt.Sprintf("invariant %s denies %s at the landlock tier but the domain is missing from network.deny_domain", r.InvariantID, r.Domain),
			})
		}
		if dual && !vapHasNetwork {
			res.Divergences = append(res.Divergences, Divergence{
				Domain: DomainNetwork, Subject: r.Domain,
				LandlockVerdict: "deny", VAPVerdict: "absent",
				Detail: fmt.Sprintf("invariant %s targets both tiers but no network ValidatingAdmissionPolicy was emitted", r.InvariantID),
			})
		}
	}

	// No fabricated grants: every allowed domain in the profile must trace back
	// to a declared allow rule.
	for d := range allowDomains {
		if !declaredAllow[d] {
			res.Divergences = append(res.Divergences, Divergence{
				Domain: DomainNetwork, Subject: d,
				LandlockVerdict: "allow", VAPVerdict: "n/a",
				Detail: fmt.Sprintf("generated profile allows domain %s which no invariant declares", d),
			})
		}
	}

	sortDivergences(res.Divergences)
	res.Equivalent = len(res.Divergences) == 0
	return res
}

func checkProcessCoverage(n *Normalised, bundles []VAPBundle, profile *NonoProfile) DomainResult {
	res := DomainResult{Domain: DomainProcess, Mode: ModeCoverage, Equivalent: true, Divergences: []Divergence{}}

	vapHasProcess := false
	for _, b := range bundles {
		if b.Domain == DomainProcess {
			vapHasProcess = true
		}
	}
	denyCmds := map[string]bool{}
	for _, c := range profile.Commands.Deny {
		denyCmds[c] = true
	}

	for _, r := range n.Process {
		res.ProbePoints++
		if r.Action != ActionDeny {
			continue
		}
		base := baseName(r.Binary)
		if hasTarget(r.Targets, TargetLandlock) && !denyCmds[base] {
			res.Divergences = append(res.Divergences, Divergence{
				Domain: DomainProcess, Subject: r.Binary,
				LandlockVerdict: "absent", VAPVerdict: "n/a",
				Detail: fmt.Sprintf("invariant %s denies %s at the landlock tier but %q is missing from commands.deny", r.InvariantID, r.Binary, base),
			})
		}
		if hasTarget(r.Targets, TargetVAP) && !vapHasProcess {
			res.Divergences = append(res.Divergences, Divergence{
				Domain: DomainProcess, Subject: r.Binary,
				LandlockVerdict: "deny", VAPVerdict: "absent",
				Detail: fmt.Sprintf("invariant %s denies %s at the vap tier but no process ValidatingAdmissionPolicy was emitted", r.InvariantID, r.Binary),
			})
		}
	}

	sortDivergences(res.Divergences)
	res.Equivalent = len(res.Divergences) == 0
	return res
}

func sortDivergences(d []Divergence) {
	sort.Slice(d, func(i, j int) bool {
		if d[i].Subject != d[j].Subject {
			return d[i].Subject < d[j].Subject
		}
		return d[i].Detail < d[j].Detail
	})
}

func baseName(p string) string {
	n := NormalisePath(p)
	for i := len(n) - 1; i >= 0; i-- {
		if n[i] == '/' {
			return n[i+1:]
		}
	}
	return n
}
