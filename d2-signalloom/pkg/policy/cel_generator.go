package policy

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Domain names the rule family a generated policy covers. One policy per domain
// keeps a filesystem failure message from talking about ports.
type Domain string

// The three rule domains.
const (
	DomainFilesystem Domain = "filesystem"
	DomainNetwork    Domain = "network"
	DomainProcess    Domain = "process"
)

// Annotation keys stamped onto generated ValidatingAdmissionPolicy objects.
const (
	// AnnotationDigest carries the canonical digest of the invariant set the
	// policy was compiled from. ValidatingAdmissionPolicy.metadata.annotations is
	// an arbitrary-key surface, so the digest can be read straight off a live
	// cluster for the drift check.
	AnnotationDigest = "signalloom.io/invariants-digest"
	// AnnotationSource names the manifest that produced the policy.
	AnnotationSource = "signalloom.io/invariants-source"
	// AnnotationDomain names the rule domain the policy covers.
	AnnotationDomain = "signalloom.io/policy-domain"
)

// VAPMetadata is the metadata block of a generated policy or binding.
type VAPMetadata struct {
	Name        string            `yaml:"name" json:"name"`
	Labels      map[string]string `yaml:"labels,omitempty" json:"labels,omitempty"`
	Annotations map[string]string `yaml:"annotations,omitempty" json:"annotations,omitempty"`
}

// ResourceRule is one matchConstraints entry.
type ResourceRule struct {
	APIGroups   []string `yaml:"apiGroups" json:"apiGroups"`
	APIVersions []string `yaml:"apiVersions" json:"apiVersions"`
	Operations  []string `yaml:"operations" json:"operations"`
	Resources   []string `yaml:"resources" json:"resources"`
}

// MatchConstraints selects the objects a policy evaluates against.
type MatchConstraints struct {
	ResourceRules []ResourceRule `yaml:"resourceRules" json:"resourceRules"`
}

// Validation is one CEL expression plus the message shown on refusal.
type Validation struct {
	Expression string `yaml:"expression" json:"expression"`
	Message    string `yaml:"message" json:"message"`
	Reason     string `yaml:"reason,omitempty" json:"reason,omitempty"`
}

// VAPSpec is the spec of a ValidatingAdmissionPolicy.
type VAPSpec struct {
	FailurePolicy    string           `yaml:"failurePolicy" json:"failurePolicy"`
	MatchConstraints MatchConstraints `yaml:"matchConstraints" json:"matchConstraints"`
	Validations      []Validation     `yaml:"validations" json:"validations"`
}

// ValidatingAdmissionPolicy is the generated cluster-tier artefact.
type ValidatingAdmissionPolicy struct {
	APIVersion string      `yaml:"apiVersion" json:"apiVersion"`
	Kind       string      `yaml:"kind" json:"kind"`
	Metadata   VAPMetadata `yaml:"metadata" json:"metadata"`
	Spec       VAPSpec     `yaml:"spec" json:"spec"`
}

// MatchResources scopes a binding to a set of namespaces.
type MatchResources struct {
	NamespaceSelector *LabelSelector `yaml:"namespaceSelector,omitempty" json:"namespaceSelector,omitempty"`
}

// LabelSelector is the subset of the Kubernetes selector this compiler emits.
type LabelSelector struct {
	MatchLabels map[string]string `yaml:"matchLabels,omitempty" json:"matchLabels,omitempty"`
}

// BindingSpec is the spec of a ValidatingAdmissionPolicyBinding.
type BindingSpec struct {
	PolicyName        string          `yaml:"policyName" json:"policyName"`
	ValidationActions []string        `yaml:"validationActions" json:"validationActions"`
	MatchResources    *MatchResources `yaml:"matchResources,omitempty" json:"matchResources,omitempty"`
}

// ValidatingAdmissionPolicyBinding activates a policy against a namespace set.
type ValidatingAdmissionPolicyBinding struct {
	APIVersion string      `yaml:"apiVersion" json:"apiVersion"`
	Kind       string      `yaml:"kind" json:"kind"`
	Metadata   VAPMetadata `yaml:"metadata" json:"metadata"`
	Spec       BindingSpec `yaml:"spec" json:"spec"`
}

// VAPBundle is one policy and its binding.
type VAPBundle struct {
	Domain  Domain
	Policy  ValidatingAdmissionPolicy
	Binding ValidatingAdmissionPolicyBinding
}

// BindingNamespaceLabel is the namespace label that activates generated
// bindings, matching the convention already used by policy/cel/*.yaml.
var BindingNamespaceLabel = map[string]string{"signalloom.io/policy": "enforced"}

var dns1123 = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`)

// IsDNS1123Subdomain reports whether name is a legal Kubernetes object name.
func IsDNS1123Subdomain(name string) bool {
	return len(name) > 0 && len(name) <= 253 && dns1123.MatchString(name)
}

var nonDNS = regexp.MustCompile(`[^a-z0-9.-]+`)

func sanitiseName(s string) string {
	s = strings.ToLower(s)
	s = nonDNS.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-.")
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	if s == "" {
		s = "policy"
	}
	if len(s) > 200 {
		s = strings.Trim(s[:200], "-.")
	}
	return s
}

// celString renders a Go string as a single-quoted CEL literal.
//
// The generated expressions are the security control, so the escaping here is
// load-bearing rather than cosmetic. Path validation already refuses control
// bytes and glob metacharacters, but a backslash or quote must still not be able
// to terminate the literal early and graft an operator onto the expression.
func celString(s string) string {
	var b strings.Builder
	b.WriteByte('\'')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '\'':
			b.WriteString(`\'`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('\'')
	return b.String()
}

func celStringList(items []string) string {
	parts := make([]string, 0, len(items))
	for _, s := range items {
		parts = append(parts, celString(s))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// underExpr renders "subject is at or below one of paths", matching on whole
// segments so that /etc/sshd is never treated as living under /etc/ssh.
func underExpr(subject string, paths []string) string {
	return fmt.Sprintf("%s.exists(p, %s == p || %s.startsWith(p + '/'))",
		celStringList(paths), subject, subject)
}

// prefixChain renders a longest-prefix-match decision over the rule set as a
// ternary chain keyed on path DEPTH rather than on individual rules.
//
// This shape is the whole reason the compiler scales. A naive chain of one
// ternary per rule is O(rules) deep, which blows the cel-go checker's recursion
// on a large manifest and trips the expression-depth cap. Grouping by depth
// bounds nesting at maxPathDepth (12) no matter how many rules exist, because
// two distinct paths of equal depth can never both be prefixes of the same
// subject — so the deepest level that matches at all is the governing rule.
// Evaluation stays linear in rule count instead of quadratic.
//
// grant reports whether a rule's access satisfies the operation being tested.
func prefixChain(subject string, rules []NormalFSRule, grant func(Access) bool) string {
	byDepth := map[int][]NormalFSRule{}
	for _, r := range rules {
		d := PathDepth(r.Path)
		byDepth[d] = append(byDepth[d], r)
	}
	depths := make([]int, 0, len(byDepth))
	for d := range byDepth {
		depths = append(depths, d)
	}
	// Deepest first: the first level with any match is the longest prefix.
	sort.Sort(sort.Reverse(sort.IntSlice(depths)))

	expr := "false"
	for i := len(depths) - 1; i >= 0; i-- {
		d := depths[i]
		level := byDepth[d]
		all := make([]string, 0, len(level))
		var granted []string
		for _, r := range level {
			all = append(all, r.Path)
			if grant(r.Access) {
				granted = append(granted, r.Path)
			}
		}
		sort.Strings(all)
		sort.Strings(granted)

		var verdict string
		switch {
		case len(granted) == 0:
			verdict = "false"
		case len(granted) == len(all):
			verdict = "true"
		default:
			verdict = underExpr(subject, granted)
		}
		expr = fmt.Sprintf("(%s ? %s : %s)", underExpr(subject, all), verdict, expr)
	}
	return expr
}

// GenerateVAP compiles the cluster tier. It returns one bundle per rule domain
// that has at least one vap-targeted rule.
func GenerateVAP(n *Normalised, digest string) ([]VAPBundle, error) {
	base := sanitiseName("sl-" + n.Set.Metadata.Name)
	var bundles []VAPBundle

	if fs := n.ForTarget(TargetVAP); len(fs) > 0 {
		b, err := fsBundle(n, fs, base, digest)
		if err != nil {
			return nil, err
		}
		bundles = append(bundles, b)
	}
	if nw := n.NetworkForTarget(TargetVAP); len(nw) > 0 {
		b, err := netBundle(n, nw, base, digest)
		if err != nil {
			return nil, err
		}
		bundles = append(bundles, b)
	}
	if pr := n.ProcessForTarget(TargetVAP); len(pr) > 0 {
		b, err := procBundle(n, pr, base, digest)
		if err != nil {
			return nil, err
		}
		bundles = append(bundles, b)
	}
	if len(bundles) == 0 {
		return nil, perr("targets", "no invariant targets the vap tier; refusing to emit an empty policy set")
	}
	return bundles, nil
}

func podRules() MatchConstraints {
	return MatchConstraints{ResourceRules: []ResourceRule{{
		APIGroups:   []string{""},
		APIVersions: []string{"v1"},
		Operations:  []string{"CREATE", "UPDATE"},
		Resources:   []string{"pods"},
	}}}
}

func newPolicy(name string, domain Domain, n *Normalised, digest string, vals []Validation) ValidatingAdmissionPolicy {
	return ValidatingAdmissionPolicy{
		APIVersion: "admissionregistration.k8s.io/v1",
		Kind:       "ValidatingAdmissionPolicy",
		Metadata: VAPMetadata{
			Name: name,
			Labels: map[string]string{
				"app.kubernetes.io/part-of":    "signalloom",
				"app.kubernetes.io/component":  "admission-policy",
				"app.kubernetes.io/managed-by": "policy-compiler",
			},
			Annotations: map[string]string{
				AnnotationDigest: digest,
				AnnotationSource: n.Set.Metadata.Name + "@" + n.Set.Metadata.Version,
				AnnotationDomain: string(domain),
			},
		},
		Spec: VAPSpec{
			FailurePolicy:    n.Defaults.FailurePolicy,
			MatchConstraints: podRules(),
			Validations:      vals,
		},
	}
}

func newBinding(policyName string) ValidatingAdmissionPolicyBinding {
	return ValidatingAdmissionPolicyBinding{
		APIVersion: "admissionregistration.k8s.io/v1",
		Kind:       "ValidatingAdmissionPolicyBinding",
		Metadata: VAPMetadata{
			Name: policyName + "-binding",
			Labels: map[string]string{
				"app.kubernetes.io/part-of":   "signalloom",
				"app.kubernetes.io/component": "admission-policy",
			},
		},
		Spec: BindingSpec{
			PolicyName:        policyName,
			ValidationActions: []string{"Deny"},
			MatchResources: &MatchResources{
				NamespaceSelector: &LabelSelector{MatchLabels: BindingNamespaceLabel},
			},
		},
	}
}

// hostPathSubject is the CEL sub-expression naming the host path of a volume.
const hostPathSubject = "v.hostPath.path"

// ExprReadableName and friends label the generated filesystem validations, and
// double as the keys the equivalence oracle uses to fetch each expression.
const (
	ExprClosedWorld = "filesystem-closed-world"
	ExprReadOnly    = "filesystem-write-requires-grant"
)

// FilesystemExpressions renders the two filesystem validations. It is exported
// because the equivalence oracle evaluates these exact strings — the oracle must
// test what ships, not a re-derivation of it.
func FilesystemExpressions(rules []NormalFSRule) map[string]string {
	readable := prefixChain(hostPathSubject, rules, func(a Access) bool { return a.Permits(AccessRead) })
	writable := prefixChain(hostPathSubject, rules, func(a Access) bool { return a.Permits(AccessReadWrite) })

	closedWorld := fmt.Sprintf(
		"!has(object.spec.volumes) || object.spec.volumes.filter(v, has(v.hostPath)).all(v, %s)",
		readable)

	readOnly := fmt.Sprintf(
		"!has(object.spec.volumes) || object.spec.volumes.filter(v, has(v.hostPath) && !(%s)).all(v, "+
			"!has(object.spec.containers) || object.spec.containers.all(c, "+
			"!has(c.volumeMounts) || c.volumeMounts.filter(m, m.name == v.name).all(m, has(m.readOnly) && m.readOnly)))",
		writable)

	return map[string]string{
		ExprClosedWorld: closedWorld,
		ExprReadOnly:    readOnly,
	}
}

func fsBundle(n *Normalised, rules []NormalFSRule, base, digest string) (VAPBundle, error) {
	name := base + "-filesystem"
	if !IsDNS1123Subdomain(name) {
		return VAPBundle{}, perr("metadata.name", "generated policy name %q is not a valid DNS-1123 subdomain", name)
	}
	exprs := FilesystemExpressions(rules)
	vals := []Validation{
		{
			Expression: exprs[ExprClosedWorld],
			Message: "hostPath volume references a host path that no security invariant grants. " +
				"Signal Loom admission is closed-world: a path must be declared in " +
				"config/security-invariants.yaml before a pod may mount it.",
			Reason: "Forbidden",
		},
		{
			Expression: exprs[ExprReadOnly],
			Message: "hostPath volume is mounted read-write but the governing security invariant " +
				"grants only read access. Set readOnly: true on every volumeMount, or widen the " +
				"invariant in config/security-invariants.yaml.",
			Reason: "Forbidden",
		},
	}
	return VAPBundle{Domain: DomainFilesystem, Policy: newPolicy(name, DomainFilesystem, n, digest, vals), Binding: newBinding(name)}, nil
}

func netBundle(n *Normalised, rules []NormalNetworkRule, base, digest string) (VAPBundle, error) {
	name := base + "-network"
	if !IsDNS1123Subdomain(name) {
		return VAPBundle{}, perr("metadata.name", "generated policy name %q is not a valid DNS-1123 subdomain", name)
	}

	var deniedPorts []string
	anyDomainDeny := false
	for _, r := range rules {
		if r.Action != ActionDeny {
			continue
		}
		if r.Domain != "" {
			anyDomainDeny = true
		}
		if r.Port != 0 {
			deniedPorts = append(deniedPorts, strconv.Itoa(r.Port))
		}
	}
	sort.Strings(deniedPorts)

	var vals []Validation
	if anyDomainDeny {
		// The admission tier cannot see egress destinations, so the honest
		// cluster-side proxy for a domain denial is refusing host networking:
		// a pod on the host network escapes every namespaced egress control the
		// domain rule depends on. This is the refinement half of the
		// equivalence contract, and is documented as such.
		vals = append(vals, Validation{
			Expression: "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false",
			Message: "Pod requests host networking, which bypasses the namespaced egress controls " +
				"that carry Signal Loom domain-deny invariants. Host networking is refused while any " +
				"domain-deny invariant is in force.",
			Reason: "Forbidden",
		})
	}
	if len(deniedPorts) > 0 {
		vals = append(vals, Validation{
			Expression: fmt.Sprintf(
				"!has(object.spec.containers) || object.spec.containers.all(c, "+
					"!has(c.ports) || c.ports.all(p, !has(p.hostPort) || !(p.hostPort in [%s])))",
				strings.Join(deniedPorts, ", ")),
			Message: "Container binds a hostPort that a Signal Loom network invariant denies.",
			Reason:  "Forbidden",
		})
	}
	if len(vals) == 0 {
		// Every network rule was an allow. There is nothing for admission to
		// refuse, and emitting a vacuously-true validation would read as
		// enforcement while asserting nothing.
		return VAPBundle{}, perr("network", "network invariants target the vap tier but contain no deny rule; an all-allow network policy would compile to a vacuous validation")
	}
	return VAPBundle{Domain: DomainNetwork, Policy: newPolicy(name, DomainNetwork, n, digest, vals), Binding: newBinding(name)}, nil
}

func procBundle(n *Normalised, rules []NormalProcessRule, base, digest string) (VAPBundle, error) {
	name := base + "-process"
	if !IsDNS1123Subdomain(name) {
		return VAPBundle{}, perr("metadata.name", "generated policy name %q is not a valid DNS-1123 subdomain", name)
	}

	var deniedBins []string
	type argRule struct {
		binary string
		args   []string
	}
	var argRules []argRule
	for _, r := range rules {
		switch r.Action {
		case ActionDeny:
			deniedBins = append(deniedBins, r.Binary)
		case ActionAllow:
			if len(r.DeniedArgs) > 0 {
				a := append([]string(nil), r.DeniedArgs...)
				sort.Strings(a)
				argRules = append(argRules, argRule{binary: r.Binary, args: a})
			}
		}
	}
	sort.Strings(deniedBins)
	sort.Slice(argRules, func(i, j int) bool { return argRules[i].binary < argRules[j].binary })

	var vals []Validation
	if len(deniedBins) > 0 {
		vals = append(vals, Validation{
			Expression: fmt.Sprintf(
				"!has(object.spec.containers) || object.spec.containers.all(c, "+
					"!has(c.command) || size(c.command) == 0 || !(c.command[0] in %s))",
				celStringList(deniedBins)),
			Message: "Container entrypoint invokes a binary that a Signal Loom process invariant denies.",
			Reason:  "Forbidden",
		})
	}
	for _, ar := range argRules {
		vals = append(vals, Validation{
			Expression: fmt.Sprintf(
				"!has(object.spec.containers) || object.spec.containers.all(c, "+
					"!has(c.command) || size(c.command) < 2 || c.command[0] != %s || !(c.command[1] in %s))",
				celString(ar.binary), celStringList(ar.args)),
			Message: fmt.Sprintf(
				"Container entrypoint invokes %s with a subcommand that a Signal Loom process "+
					"invariant denies. The binary itself remains permitted.", ar.binary),
			Reason: "Forbidden",
		})
	}
	if len(vals) == 0 {
		return VAPBundle{}, perr("process", "process invariants target the vap tier but contain no deny rule or denied argument; the policy would compile to a vacuous validation")
	}
	return VAPBundle{Domain: DomainProcess, Policy: newPolicy(name, DomainProcess, n, digest, vals), Binding: newBinding(name)}, nil
}

// AllExpressions returns every CEL expression in a bundle set, keyed by
// "<policy-name>#<index>". The SP-4 linter and the AST validator consume this so
// that neither can be handed a re-derivation of what actually ships.
func AllExpressions(bundles []VAPBundle) map[string]string {
	out := map[string]string{}
	for _, b := range bundles {
		for i, v := range b.Policy.Spec.Validations {
			out[fmt.Sprintf("%s#%d", b.Policy.Metadata.Name, i)] = v.Expression
		}
	}
	return out
}
