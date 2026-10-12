package oracle

// External oracle for the CIS Kubernetes pack.
//
// Every other tier in this repo compares a CEL expression against a fixture
// expectation written by the same author in the same sitting, so it can only
// prove self-consistency. This tier compares the pack's decision semantics
// against code nobody here wrote: k8s.io/pod-security-admission, the module the
// API server itself runs to enforce the Pod Security Standards. A disagreement
// is a statement about Kubernetes, not about our fixtures.
//
// Oracle provenance
//
//	primary:   k8s.io/pod-security-admission v0.36.2 (policy.DefaultChecks,
//	           policy.NewEvaluator) — the admission decision.
//	secondary: structural API validation transcribed from
//	           kubernetes/kubernetes tag v1.34.0,
//	           pkg/apis/core/validation/validation.go lines 5126-5141
//	           (validateSeccompProfileField). PSA deliberately does not cover
//	           object validity, so the one rule we need from it is transcribed
//	           verbatim and cited rather than derived from our pack.
//	defaulting: kubernetes/kubernetes v1.34.0, pkg/apis/core/v1/defaults.go
//	           lines 209-212 and 401-409 (SetDefaults_Pod ->
//	           defaultHostNetworkPorts).
//
// Two legs feed the comparison:
//
//	leg A: every pod-shaped fixture under
//	       policy/frameworks/cis-kubernetes/v1.8/fixtures/**.
//	leg B: probe pods authored here, not in the pack. Fixture coverage is
//	       author-chosen, so a semantics gap no fixture exercises is invisible
//	       to leg A by construction.
//
// This module must not change policy/**. Where the oracle says our pack is
// wrong, the divergence is recorded as an exception with a reason and is a
// decision for the pack owner, not something to paper over here.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	psaapi "k8s.io/pod-security-admission/api"
	psapolicy "k8s.io/pod-security-admission/policy"
)

const (
	oraclePackID = "cis-kubernetes"
	// The directory name and the version framework.json declares are not the
	// same string; both are asserted so a pack moved between directories
	// cannot be judged under the wrong name.
	oraclePackDir     = "v1.8"
	oraclePackVersion = "v1.8.0"
	oraclePSAModule   = "k8s.io/pod-security-admission v0.36.2"
)

// --- the mapping: our check IDs <-> the PSA checks that bear on them ---------

// oracleGroup is one comparable unit. Several of our checks can split a single
// PSA check (hostNamespaces covers hostPID, hostIPC and hostNetwork) and a
// single one of ours can span several PSA checks (no-root-containers is judged
// by runAsNonRoot and runAsUser together), so the comparison is group-wise:
// the conjunction of our verdicts against the conjunction of PSA's.
type oracleGroup struct {
	name string
	ours []string
	psa  []psapolicy.CheckID
	// secondary marks a group that reads a pack check another group already
	// owns, against a different oracle. Ownership (one primary group per pack
	// check) is still enforced; secondary groups are exempt from it.
	secondary bool
	// necessaryOnly marks an oracle that states a NECESSARY condition only: it
	// can say "this object is invalid", never "this object is compliant". For
	// such an oracle, pack-fail with oracle-allow is not a disagreement (the
	// pack failed for a reason the oracle does not judge), so only the
	// pack-pass / oracle-reject direction is reported.
	necessaryOnly bool
	note          string
}

var oracleGroups = []oracleGroup{
	{
		name: "privileged",
		ours: []string{"no-privileged-containers"},
		psa:  []psapolicy.CheckID{"privileged"},
		note: "baseline. 1:1.",
	},
	{
		name: "hostNamespaces",
		ours: []string{"no-host-pid", "no-host-ipc", "no-host-network"},
		psa:  []psapolicy.CheckID{"hostNamespaces"},
		note: "baseline. PSA judges the three host namespaces as one check; CIS numbers them 5.2.3/5.2.4/5.2.5.",
	},
	{
		name: "allowPrivilegeEscalation",
		ours: []string{"no-privilege-escalation"},
		psa:  []psapolicy.CheckID{"allowPrivilegeEscalation"},
		note: "restricted. 1:1, both exempt spec.os.name == windows.",
	},
	{
		name: "runAsNonRoot",
		ours: []string{"no-root-containers"},
		psa:  []psapolicy.CheckID{"runAsNonRoot", "runAsUser"},
		note: "restricted. PSS splits 'must require runAsNonRoot: true' from 'must not set runAsUser: 0'.",
	},
	{
		name: "capabilities",
		ours: []string{"no-net-raw", "no-added-capabilities", "capabilities-dropped-all"},
		psa:  []psapolicy.CheckID{"capabilities_baseline", "capabilities_restricted", "privileged"},
		note: "baseline+restricted. PSA's two capability checks cover the same ground as our three. " +
			"privileged is in this group as well as its own because our no-net-raw folds \"must not be " +
			"privileged\" into the capability check (a privileged container holds NET_RAW whatever its " +
			"drop list says), where PSA attributes that to the privileged check. A PSA check may appear " +
			"in more than one group; a pack check may not.",
	},
	{
		name: "windowsHostProcess",
		ours: []string{"no-windows-hostprocess"},
		psa:  []psapolicy.CheckID{"windowsHostProcess"},
		note: "baseline. 1:1.",
	},
	{
		name: "hostPathVolumes",
		ours: []string{"no-hostpath-volumes"},
		psa:  []psapolicy.CheckID{"hostPathVolumes"},
		note: "baseline. Deliberately not mapped to restrictedVolumes, which forbids far more than hostPath.",
	},
	{
		name: "hostPorts",
		ours: []string{"no-host-ports"},
		psa:  []psapolicy.CheckID{"hostPorts"},
		note: "baseline. 1:1, once API-server hostNetwork port defaulting is applied.",
	},
	{
		name: "seccompProfile",
		ours: []string{"seccomp-runtime-default"},
		psa:  []psapolicy.CheckID{"seccompProfile_baseline", "seccompProfile_restricted"},
		note: "baseline+restricted. PSA checks the profile TYPE only; the Localhost/localhostProfile pairing is API validation, see the seccompAPIValidation group.",
	},
	{
		name:          "seccompAPIValidation",
		ours:          []string{"seccomp-runtime-default"},
		psa:           []psapolicy.CheckID{oracleAPIValidationSeccomp},
		secondary:     true,
		necessaryOnly: true,
		note: "Secondary oracle, not PSA: structural API validation. Compares seccomp-runtime-default " +
			"against whether the API server would accept the object at all, which PSA deliberately does " +
			"not judge.",
	},
}

// oracleAPIValidationSeccomp is a synthetic check ID: not a PSA check, but the
// secondary oracle's verdict carried through the same plumbing. The prefix
// marks every such ID so the upstream-completeness test does not mistake one
// for a PSA check.
const (
	oracleAPIValidationPrefix                    = "apiValidation:"
	oracleAPIValidationSeccomp psapolicy.CheckID = oracleAPIValidationPrefix + "seccompProfile"
)

// oracleUnanchoredChecks are pack checks with no Pod Security Standards
// counterpart. They are NOT anchored by anything outside this repo and their
// semantics rest entirely on fixtures written by their own author.
var oracleUnanchoredChecks = map[string]string{
	"sa-token-automount-disabled": "CIS 5.1.6. PSS says nothing about service account token mounting.",
	"no-secrets-in-env":           "CIS 5.4.1. PSS says nothing about secret delivery.",
	"no-default-namespace":        "CIS 5.7.4. Namespace hygiene is outside PSS.",
	"security-context-applied":    "CIS 5.7.3. PSS constrains securityContext CONTENT, never its mere presence.",
}

// oracleUnrepresentedPSAChecks are PSA checks with no counterpart in our pack:
// Pod Security Standards ground the pack covers nothing of.
var oracleUnrepresentedPSAChecks = map[psapolicy.CheckID]string{
	"appArmorProfile":            "no AppArmor check in the pack",
	"procMount":                  "no procMount check in the pack",
	"procMount_restricted":       "no procMount check in the pack",
	"restrictedVolumes":          "pack forbids hostPath only, not the restricted volume-type allow-list",
	"seLinuxOptions":             "no SELinux check in the pack",
	"sysctls":                    "no sysctl check in the pack",
	"hostProbesAndHostLifecycle": "no host-probe check in the pack (PSA >= 1.34)",
}

// --- exceptions: divergences accepted, each with its own reason -------------

// oracleException records one accepted divergence. Matching is exact on
// direction as well as identity, so a divergence that flips direction is a new
// finding and is reported, and an exception that stops diverging is reported as
// stale.
type oracleException struct {
	Case     string // fixture or probe name
	Group    string // oracleGroup.name
	OursPass bool
	PSAAllow bool
	Reason   string
}

// Every entry here is a semantics decision the pack owner has to make. None of
// them is "our expression is fine"; they are recorded so the tier can stay
// green while the decision is outstanding, and they fail loudly if stale.
var oracleExceptions = []oracleException{
	{
		Case: "added-capability-net-bind-service", Group: "capabilities", OursPass: false, PSAAllow: true,
		Reason: "DELIBERATELY STRICTER, defensible. PSS restricted permits adding NET_BIND_SERVICE; CIS 5.2.9 permits no added capability at all. Ours fails, PSA allows. Keep.",
	},
	{
		Case: "probe-add-net-bind-service-only", Group: "capabilities", OursPass: false, PSAAllow: true,
		Reason: "DELIBERATELY STRICTER, defensible. Same NET_BIND_SERVICE divergence as above, reached from a probe rather than a fixture.",
	},
	{
		Case: "host-network-true-no-ports", Group: "hostPorts", OursPass: false, PSAAllow: true,
		Reason: "ATTRIBUTION, NOT DISAGREEMENT (lead, 2026-10-10). PSA *does* reject this pod \u2014 see the recorded PSA detail: host namespaces (hostNetwork=true). It attributes that to hostNamespaces/hostProcess, while our no-host-ports carries it, because a hostNetwork pod binds host ports whether or not it declares them (A5 finding 7 made that documented rule reachable; it had been dead code nested inside c.ports.all). Both sides agree the pod is inadmissible, so this is a per-check attribution difference and the overlap with no-host-network is deliberate and visible.",
	},
	{
		Case: "windows-hostprocess-container-level", Group: "hostPorts", OursPass: false, PSAAllow: true,
		Reason: "ATTRIBUTION, NOT DISAGREEMENT (lead, 2026-10-10). PSA *does* reject this pod \u2014 see the recorded PSA detail: host namespaces (hostNetwork=true) plus hostProcess. It attributes that to hostNamespaces/hostProcess, while our no-host-ports carries it, because a hostNetwork pod binds host ports whether or not it declares them (A5 finding 7 made that documented rule reachable; it had been dead code nested inside c.ports.all). Both sides agree the pod is inadmissible, so this is a per-check attribution difference and the overlap with no-host-network is deliberate and visible.",
	},
	{
		Case: "windows-hostprocess-pod-level", Group: "hostPorts", OursPass: false, PSAAllow: true,
		Reason: "ATTRIBUTION, NOT DISAGREEMENT (lead, 2026-10-10). PSA *does* reject this pod \u2014 see the recorded PSA detail: host namespaces (hostNetwork=true) plus hostProcess. It attributes that to hostNamespaces/hostProcess, while our no-host-ports carries it, because a hostNetwork pod binds host ports whether or not it declares them (A5 finding 7 made that documented rule reachable; it had been dead code nested inside c.ports.all). Both sides agree the pod is inadmissible, so this is a per-check attribution difference and the overlap with no-host-network is deliberate and visible.",
	},
	{
		Case: "seccomp-container-localhost-without-profile", Group: "seccompProfile", OursPass: false, PSAAllow: true,
		Reason: "PACK IS RIGHT, PSA IS BLIND HERE (lead, 2026-10-10). seccompProfile.type: Localhost with no localhostProfile. PSA checks the profile *type* only and admits; the API server rejects the object outright (validateSeccompProfileField, cited in the secondary-oracle comment), so the pod cannot be submitted at all. A5 made the pack fail it, which is correct and stricter than the PSA leg can express \u2014 the necessary-only apiValidation oracle is what anchors this direction.",
	},
	{
		Case: "seccomp-pod-localhost-without-profile", Group: "seccompProfile", OursPass: false, PSAAllow: true,
		Reason: "PACK IS RIGHT, PSA IS BLIND HERE (lead, 2026-10-10). seccompProfile.type: Localhost with no localhostProfile. PSA checks the profile *type* only and admits; the API server rejects the object outright (validateSeccompProfileField, cited in the secondary-oracle comment), so the pod cannot be submitted at all. A5 made the pack fail it, which is correct and stricter than the PSA leg can express \u2014 the necessary-only apiValidation oracle is what anchors this direction.",
	},
	{
		Case: "probe-seccomp-localhost-without-profile", Group: "seccompProfile", OursPass: false, PSAAllow: true,
		Reason: "PACK IS RIGHT, PSA IS BLIND HERE (lead, 2026-10-10). seccompProfile.type: Localhost with no localhostProfile. PSA checks the profile *type* only and admits; the API server rejects the object outright (validateSeccompProfileField, cited in the secondary-oracle comment), so the pod cannot be submitted at all. A5 made the pack fail it, which is correct and stricter than the PSA leg can express \u2014 the necessary-only apiValidation oracle is what anchors this direction.",
	},
}

// --- the PSA oracle ---------------------------------------------------------

type psaVerdict struct {
	allowed bool
	detail  string
	err     error
}

// psaOracle evaluates each PSA check in isolation so a verdict can be
// attributed to a check ID. The aggregate evaluator answers "would the API
// server admit this pod at all", which is only used for context in messages.
type psaOracle struct {
	single     map[psapolicy.CheckID]psapolicy.Evaluator
	level      map[psapolicy.CheckID]psaapi.Level
	aggregator psapolicy.Evaluator
}

func newPSAOracle() (*psaOracle, error) {
	checks := psapolicy.DefaultChecks()
	o := &psaOracle{
		single: map[psapolicy.CheckID]psapolicy.Evaluator{},
		level:  map[psapolicy.CheckID]psaapi.Level{},
	}
	for _, c := range checks {
		ev, err := psapolicy.NewEvaluator([]psapolicy.Check{c}, nil)
		if err != nil {
			return nil, fmt.Errorf("psa check %s: %w", c.ID, err)
		}
		o.single[c.ID] = ev
		o.level[c.ID] = c.Level
	}
	agg, err := psapolicy.NewEvaluator(checks, nil)
	if err != nil {
		return nil, err
	}
	o.aggregator = agg
	return o, nil
}

// check runs one PSA check at the level it belongs to. Baseline checks are
// evaluated under baseline (they run unchanged under restricted); restricted
// checks under restricted.
func (o *psaOracle) check(id psapolicy.CheckID, pod *corev1.Pod) psaVerdict {
	ev, ok := o.single[id]
	if !ok {
		return psaVerdict{err: fmt.Errorf("psa has no check %q", id)}
	}
	lv := psaapi.LevelVersion{Level: o.level[id], Version: psaapi.LatestVersion()}
	results := ev.EvaluatePod(lv, &pod.ObjectMeta, &pod.Spec)
	if len(results) != 1 {
		return psaVerdict{err: fmt.Errorf("psa check %q returned %d results, want 1", id, len(results))}
	}
	r := results[0]
	detail := r.ForbiddenReason
	if r.ForbiddenDetail != "" {
		detail += " (" + r.ForbiddenDetail + ")"
	}
	return psaVerdict{allowed: r.Allowed, detail: detail}
}

func (o *psaOracle) aggregate(level psaapi.Level, pod *corev1.Pod) string {
	lv := psaapi.LevelVersion{Level: level, Version: psaapi.LatestVersion()}
	agg := psapolicy.AggregateCheckResults(o.aggregator.EvaluatePod(lv, &pod.ObjectMeta, &pod.Spec))
	if agg.Allowed {
		return "admit"
	}
	return "reject: " + agg.ForbiddenDetail()
}

// --- the secondary oracle: structural API validation ------------------------

// oracleSeccompAPIValidation reports why the API server would reject a
// seccompProfile, or "" if it would accept it.
//
// Transcribed from kubernetes/kubernetes v1.34.0,
// pkg/apis/core/validation/validation.go:5126-5141:
//
//	if sp.Type == core.SeccompProfileTypeLocalhost {
//	    if sp.LocalhostProfile == nil { Required("must be set when seccomp type is Localhost") }
//	} else if sp.LocalhostProfile != nil {
//	    Invalid("can only be set when seccomp type is Localhost")
//	}
//
// Pod Security Admission deliberately does not validate object structure, so
// this rule has to come from validation rather than from the PSA module. It is
// quoted from upstream, not inferred from our pack.
func oracleSeccompAPIValidation(p *corev1.SeccompProfile) string {
	if p == nil {
		return ""
	}
	if p.Type == corev1.SeccompProfileTypeLocalhost {
		if p.LocalhostProfile == nil {
			return "seccompProfile.localhostProfile: must be set when seccomp type is Localhost"
		}
		return ""
	}
	if p.LocalhostProfile != nil {
		return "seccompProfile.localhostProfile: can only be set when seccomp type is Localhost"
	}
	return ""
}

// oracleAPIValidationVerdict is the secondary oracle's verdict for a pod,
// shaped like a PSA verdict so it travels through the same comparison.
func oracleAPIValidationVerdict(pod *corev1.Pod) psaVerdict {
	profiles := oracleSeccompProfilesOf(&pod.Spec)
	var rejections []string
	for _, path := range oracleSortedKeys(profiles) {
		if msg := oracleSeccompAPIValidation(profiles[path]); msg != "" {
			rejections = append(rejections, path+": "+msg)
		}
	}
	if len(rejections) == 0 {
		return psaVerdict{allowed: true}
	}
	return psaVerdict{allowed: false, detail: "API server would reject the object: " + strings.Join(rejections, "; ")}
}

// oracleApplyAPIServerDefaults applies the one piece of API-server defaulting
// that changes a mapped verdict, so the oracle judges the object the API server
// stores rather than the one the author typed. PSA runs inside the API server,
// after defaulting; feeding it an undefaulted pod makes it disagree with our
// pack for a reason that has nothing to do with either's semantics.
//
// Transcribed from kubernetes/kubernetes v1.34.0,
// pkg/apis/core/v1/defaults.go:209-212 and :401-409 (SetDefaults_Pod ->
// defaultHostNetworkPorts):
//
//	if obj.Spec.HostNetwork {
//	    defaultHostNetworkPorts(&obj.Spec.Containers)
//	    defaultHostNetworkPorts(&obj.Spec.InitContainers)
//	}
//	... for each port: if HostPort == 0 { HostPort = ContainerPort }
//
// Note the fidelity limit this does NOT close: no other defaulting is applied,
// and upstream does not default ephemeral container ports either.
func oracleApplyAPIServerDefaults(pod *corev1.Pod) {
	if !pod.Spec.HostNetwork {
		return
	}
	defaultHostNetworkPorts := func(containers []corev1.Container) {
		for i := range containers {
			for j := range containers[i].Ports {
				if containers[i].Ports[j].HostPort == 0 {
					containers[i].Ports[j].HostPort = containers[i].Ports[j].ContainerPort
				}
			}
		}
	}
	defaultHostNetworkPorts(pod.Spec.Containers)
	defaultHostNetworkPorts(pod.Spec.InitContainers)
}

// oracleSeccompProfilesOf returns every seccompProfile in a pod spec with the
// field path it sits at.
func oracleSeccompProfilesOf(spec *corev1.PodSpec) map[string]*corev1.SeccompProfile {
	out := map[string]*corev1.SeccompProfile{}
	if spec.SecurityContext != nil && spec.SecurityContext.SeccompProfile != nil {
		out["spec.securityContext"] = spec.SecurityContext.SeccompProfile
	}
	add := func(kind string, cs []corev1.Container) {
		for i := range cs {
			if cs[i].SecurityContext != nil && cs[i].SecurityContext.SeccompProfile != nil {
				out[kind+"/"+cs[i].Name] = cs[i].SecurityContext.SeccompProfile
			}
		}
	}
	add("containers", spec.Containers)
	add("initContainers", spec.InitContainers)
	for i := range spec.EphemeralContainers {
		ec := &spec.EphemeralContainers[i]
		if ec.SecurityContext != nil && ec.SecurityContext.SeccompProfile != nil {
			out["ephemeralContainers/"+ec.Name] = ec.SecurityContext.SeccompProfile
		}
	}
	return out
}

// --- cases, comparison, exceptions ------------------------------------------

type oracleCase struct {
	name   string
	source string // "fixture" or "probe"
	object map[string]any
}

type oracleDivergence struct {
	Case     string
	Group    string
	OursPass bool
	PSAAllow bool
	Detail   string
}

func (d oracleDivergence) String() string {
	ours, psa := "fail", "reject"
	if d.OursPass {
		ours = "pass"
	}
	if d.PSAAllow {
		psa = "allow"
	}
	return fmt.Sprintf("%s / %s: pack=%s, PSA=%s | %s", d.Case, d.Group, ours, psa, d.Detail)
}

func (d oracleDivergence) matches(e oracleException) bool {
	return d.Case == e.Case && d.Group == e.Group && d.OursPass == e.OursPass && d.PSAAllow == e.PSAAllow
}

// compareCase is the whole comparison, isolated from loading and evaluation so
// it can be driven with injected verdicts. A group is skipped (and reported as
// skipped, never as agreement) when any side is not a clean pass/fail.
func compareCase(
	groups []oracleGroup,
	name string,
	ours map[string]Verdict,
	psa map[psapolicy.CheckID]psaVerdict,
) (divs []oracleDivergence, skipped []string) {
	for _, g := range groups {
		ourPass := true
		var why []string
		skip := ""
		for _, id := range g.ours {
			v, ok := ours[id]
			switch {
			case !ok:
				skip = fmt.Sprintf("%s / %s: pack has no verdict for %q", name, g.name, id)
			case v == VerdictPass:
			case v == VerdictFail:
				ourPass = false
				why = append(why, "pack-fail:"+id)
			default:
				skip = fmt.Sprintf("%s / %s: pack verdict for %q is %s, not comparable", name, g.name, id, v)
			}
			if skip != "" {
				break
			}
		}
		if skip != "" {
			skipped = append(skipped, skip)
			continue
		}
		psaAllow := true
		for _, id := range g.psa {
			v, ok := psa[id]
			if !ok || v.err != nil {
				skip = fmt.Sprintf("%s / %s: PSA check %q unavailable (%v)", name, g.name, id, v.err)
				break
			}
			if !v.allowed {
				psaAllow = false
				why = append(why, fmt.Sprintf("psa-reject:%s=%s", id, v.detail))
			}
		}
		if skip != "" {
			skipped = append(skipped, skip)
			continue
		}
		if g.necessaryOnly && !ourPass {
			continue
		}
		if ourPass != psaAllow {
			divs = append(divs, oracleDivergence{
				Case: name, Group: g.name, OursPass: ourPass, PSAAllow: psaAllow,
				Detail: strings.Join(why, "; "),
			})
		}
	}
	return divs, skipped
}

// applyExceptions splits divergences into unexcused ones and reports which
// exceptions went unused. An unused exception is stale and must fail.
func applyExceptions(divs []oracleDivergence, exceptions []oracleException) (unexcused []oracleDivergence, stale []oracleException) {
	used := make([]bool, len(exceptions))
	for _, d := range divs {
		matched := false
		for i, e := range exceptions {
			if d.matches(e) {
				used[i] = true
				matched = true
			}
		}
		if !matched {
			unexcused = append(unexcused, d)
		}
	}
	for i, e := range exceptions {
		if !used[i] {
			stale = append(stale, e)
		}
	}
	return unexcused, stale
}

// --- loading ----------------------------------------------------------------

func cisPack(t *testing.T) *Pack {
	t.Helper()
	root, err := PolicyRoot()
	if err != nil {
		t.Fatal(err)
	}
	p, err := LoadPack(root, oraclePackID, oraclePackDir)
	if err != nil {
		t.Fatalf("loading %s/%s: %v", oraclePackID, oraclePackDir, err)
	}
	if p.ID != oraclePackID || p.Version != oraclePackVersion {
		t.Fatalf("framework.json declares %s@%s, want %s@%s", p.ID, p.Version, oraclePackID, oraclePackVersion)
	}
	return p
}

func cisFixtures(t *testing.T, p *Pack) []Fixture {
	t.Helper()
	f, err := LoadFixtures(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(f) == 0 {
		t.Fatal("no fixtures loaded: the oracle would pass vacuously")
	}
	return f
}

// oraclePodShaped reports whether a fixture's object is a pod we can hand to
// PSA at all. Objects that are not Pods, or carry no spec, are out of scope
// and named in the skip report rather than silently dropped.
func oraclePodShaped(obj map[string]any) bool {
	if obj == nil {
		return false
	}
	if kind, _ := obj["kind"].(string); kind != "Pod" {
		return false
	}
	_, ok := obj["spec"].(map[string]any)
	return ok
}

// oracleDecodePod decodes a fixture object into the typed corev1.Pod PSA
// expects, rejecting unknown fields so a mistyped field cannot quietly vanish
// on the way to the oracle and manufacture agreement.
func oracleDecodePod(obj map[string]any) (*corev1.Pod, error) {
	raw, err := json.Marshal(obj)
	if err != nil {
		return nil, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var pod corev1.Pod
	if err := dec.Decode(&pod); err != nil {
		return nil, err
	}
	if pod.ObjectMeta.Name == "" {
		pod.ObjectMeta.Name = "oracle-pod"
	}
	return &pod, nil
}

// oracleOurVerdicts runs the mirrored CELEngine over the pack's checks for one
// object. It evaluates every check the pack has, not just the ones a fixture
// chose to pin, so leg B works on objects with no expectations at all.
func oracleOurVerdicts(eng *CELEngine, p *Pack, obj map[string]any) map[string]Verdict {
	in := celBindings(obj, map[string]any{}, map[string]any{})
	out := map[string]Verdict{}
	for _, id := range p.Order {
		if p.Placeholder(id) {
			out[id] = VerdictNotEvaluated
			continue
		}
		passed, err := eng.Evaluate(context.Background(), p.Checks[id].CELExpression, in)
		out[id] = verdictOf(passed, err)
	}
	return out
}

// oracleRoundTrip re-decodes an object the way handleScan decodes a request
// body, so numbers reach CEL as float64 exactly as in production.
func oracleRoundTrip(t *testing.T, obj map[string]any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(obj)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.NewDecoder(bytes.NewReader(raw)).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

func oracleFixtureCases(fixtures []Fixture) (cases []oracleCase, notPods []string) {
	for _, f := range fixtures {
		if !oraclePodShaped(f.Input.Object) {
			notPods = append(notPods, f.Name)
			continue
		}
		cases = append(cases, oracleCase{name: f.Name, source: "fixture", object: f.Input.Object})
	}
	return cases, notPods
}

// --- leg B: probe pods, authored here, deliberately not in the pack ---------

// oracleProbePods exist because fixture coverage is chosen by the same author
// as the expressions. Each probe isolates one semantic question and is named
// probe-* so it can never be confused with a pack fixture.
var oracleProbePods = map[string]string{
	// The three divergences the lead confirmed independently. The lowercase
	// drop and the bare runAsUser are also reachable from fixtures; the
	// Localhost-without-profile pod is not reachable from any fixture, which
	// is the point of this leg.
	"probe-seccomp-localhost-without-profile": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-seccomp-localhost-without-profile", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "Localhost"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false}}]
      }}`,
	"probe-drop-all-lowercase-minimal": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-drop-all-lowercase-minimal", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["all"]}}}]
      }}`,
	"probe-runasuser-nonzero-without-runasnonroot": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-runasuser-nonzero-without-runasnonroot", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,
	// NET_BIND_SERVICE: the one place our pack is knowingly stricter than PSS.
	"probe-add-net-bind-service-only": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-add-net-bind-service-only", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}}}]
      }}`,
	// A pod PSS admits under restricted, as a control: the oracle must agree
	// with the pack somewhere, or the mapping is just noise.
	"probe-restricted-compliant": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-restricted-compliant", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,
	// Host namespaces, one at a time, to prove our 3:1 split against PSA's
	// single hostNamespaces check lines up in each direction.
	"probe-host-pid-only": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-host-pid-only", "namespace": "payments"},
      "spec": {
        "hostPID": true,
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,
	// A capability outside the baseline allow-list, added without dropping ALL.
	"probe-add-sys-admin": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-add-sys-admin", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"add": ["SYS_ADMIN"]}}}]
      }}`,
	// Seccomp Unconfined at pod level: rejected by both PSA seccomp checks.
	"probe-seccomp-unconfined": `{
      "apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "probe-seccomp-unconfined", "namespace": "payments"},
      "spec": {
        "automountServiceAccountToken": false,
        "securityContext": {"runAsNonRoot": true, "runAsUser": 10001,
                            "seccompProfile": {"type": "Unconfined"}},
        "containers": [{"name": "app", "image": "registry.example/app:1",
          "securityContext": {"allowPrivilegeEscalation": false,
                              "capabilities": {"drop": ["ALL"]}}}]
      }}`,
}

func oracleProbeCases(t *testing.T) []oracleCase {
	t.Helper()
	names := make([]string, 0, len(oracleProbePods))
	for n := range oracleProbePods {
		names = append(names, n)
	}
	sort.Strings(names)
	cases := make([]oracleCase, 0, len(names))
	for _, n := range names {
		var obj map[string]any
		dec := json.NewDecoder(strings.NewReader(oracleProbePods[n]))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&obj); err != nil {
			t.Fatalf("probe %s: %v", n, err)
		}
		if !oraclePodShaped(obj) {
			t.Fatalf("probe %s is not pod-shaped", n)
		}
		if got, _ := obj["metadata"].(map[string]any)["name"].(string); got != n {
			t.Fatalf("probe %s: metadata.name is %q, must equal the probe name", n, got)
		}
		cases = append(cases, oracleCase{name: n, source: "probe", object: obj})
	}
	return cases
}

// --- the tier ---------------------------------------------------------------

// oracleScan is the reusable pipeline: for each case, our engine's verdicts and
// PSA's per-check verdicts, compared group-wise.
func oracleScan(t *testing.T, eng *CELEngine, o *psaOracle, p *Pack, cases []oracleCase) (divs []oracleDivergence, skipped []string) {
	t.Helper()
	for _, c := range cases {
		obj := oracleRoundTrip(t, c.object)
		pod, err := oracleDecodePod(obj)
		if err != nil {
			skipped = append(skipped, fmt.Sprintf("%s: not decodable as a Pod: %v", c.name, err))
			continue
		}
		oracleApplyAPIServerDefaults(pod)
		ours := oracleOurVerdicts(eng, p, obj)
		psa := map[psapolicy.CheckID]psaVerdict{oracleAPIValidationSeccomp: oracleAPIValidationVerdict(pod)}
		for _, g := range oracleGroups {
			for _, id := range g.psa {
				if strings.HasPrefix(string(id), oracleAPIValidationPrefix) {
					continue
				}
				psa[id] = o.check(id, pod)
			}
		}
		d, s := compareCase(oracleGroups, c.name, ours, psa)
		divs = append(divs, d...)
		skipped = append(skipped, s...)
	}
	return divs, skipped
}

// TestPSAOracle_PackAgreesWithPodSecurityAdmission is the tier. Every
// divergence is a failure unless it is an individually-justified exception,
// and an exception that no longer diverges is itself a failure.
func TestPSAOracle_PackAgreesWithPodSecurityAdmission(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	p := cisPack(t)

	fixtures, notPods := oracleFixtureCases(cisFixtures(t, p))
	cases := append(fixtures, oracleProbeCases(t)...)
	t.Logf("oracle: %s, policy version %s", oraclePSAModule, psaapi.LatestVersion())
	t.Logf("cases: %d fixtures (%d objects were not pod-shaped: %s) + %d probes",
		len(fixtures), len(notPods), strings.Join(notPods, ", "), len(oracleProbePods))

	divs, skipped := oracleScan(t, eng, o, p, cases)
	for _, s := range skipped {
		t.Logf("skipped: %s", s)
	}
	for _, d := range divs {
		t.Logf("divergence: %s", d)
	}

	unexcused, stale := applyExceptions(divs, oracleExceptions)
	for _, d := range unexcused {
		detail := ""
		if pod, err := oracleDecodePod(oracleRoundTrip(t, caseObject(cases, d.Case))); err == nil {
			oracleApplyAPIServerDefaults(pod)
			detail = fmt.Sprintf("\n  PSA baseline:   %s\n  PSA restricted: %s\n  pod: %s",
				o.aggregate(psaapi.LevelBaseline, pod), o.aggregate(psaapi.LevelRestricted, pod),
				compactJSON(caseObject(cases, d.Case)))
		}
		t.Errorf("UNEXCUSED DIVERGENCE from Pod Security Admission\n  %s%s\n"+
			"  Either the pack check is wrong (record it for the pack owner) or the divergence is "+
			"deliberate (add an oracleException with a one-line reason).", d, detail)
	}
	for _, e := range stale {
		t.Errorf("STALE EXCEPTION: %s / %s no longer diverges in the recorded direction "+
			"(pack=%v, PSA=%v). Delete the exception or re-state it.\n  was: %s",
			e.Case, e.Group, e.OursPass, e.PSAAllow, e.Reason)
	}
}

func caseObject(cases []oracleCase, name string) map[string]any {
	for _, c := range cases {
		if c.name == name {
			return c.object
		}
	}
	return nil
}

func compactJSON(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(raw)
}

// TestPSAOracle_SeccompLocalhostNeedsProfile is the secondary oracle leg: the
// one rule PSA does not carry. Our seccomp-runtime-default passes a pod the API
// server would reject outright.
func TestPSAOracle_SeccompLocalhostNeedsProfile(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	p := cisPack(t)

	type want struct {
		ourVerdict Verdict
		apiRejects bool
	}
	cases := map[string]want{
		// A5 fixed the pack to require localhostProfile, so the pack now agrees with
		// API validation here. The case stays because the SECONDARY ORACLE is what
		// anchors this direction: PSA checks the profile type only and admits, so
		// without apiValidation nothing outside this repo would notice a regression.
		"probe-seccomp-localhost-without-profile": {VerdictFail, true},
		"probe-restricted-compliant":              {VerdictPass, false},
	}
	for _, c := range oracleProbeCases(t) {
		w, ok := cases[c.name]
		if !ok {
			continue
		}
		obj := oracleRoundTrip(t, c.object)
		pod, err := oracleDecodePod(obj)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		profiles := oracleSeccompProfilesOf(&pod.Spec)
		var rejections []string
		for _, path := range oracleSortedKeys(profiles) {
			if msg := oracleSeccompAPIValidation(profiles[path]); msg != "" {
				rejections = append(rejections, path+": "+msg)
			}
		}
		if (len(rejections) > 0) != w.apiRejects {
			t.Errorf("%s: API validation rejects=%v, want %v (%v)", c.name, len(rejections) > 0, w.apiRejects, rejections)
		}
		got := oracleOurVerdicts(eng, p, obj)["seccomp-runtime-default"]
		if got != w.ourVerdict {
			t.Errorf("%s: pack seccomp-runtime-default = %s, want %s", c.name, got, w.ourVerdict)
		}
		if w.apiRejects && got == VerdictPass { //nolint:staticcheck // kept: fires if the pack ever regresses to accepting an unsubmittable pod
			t.Logf("DIVERGENCE (API validation): %s — pack passes seccomp-runtime-default, "+
				"the API server rejects the object: %s. Decision for the pack owner: a check that "+
				"accepts an unsubmittable pod is reporting compliance for something that cannot run.",
				c.name, strings.Join(rejections, "; "))
		}
	}
}

// --- mapping completeness: nothing may escape the oracle silently -----------

// TestPSAOracle_MappingCoversEveryPackCheck fails if a pack check is neither
// mapped to a PSA check nor explicitly declared unanchored. A new CIS check
// must make a decision, not default to unexamined.
func TestPSAOracle_MappingCoversEveryPackCheck(t *testing.T) {
	p := cisPack(t)
	mapped := map[string]string{}
	for _, g := range oracleGroups {
		if g.secondary {
			continue
		}
		for _, id := range g.ours {
			if prev, dup := mapped[id]; dup {
				t.Errorf("check %q owned by two primary groups: %s and %s", id, prev, g.name)
			}
			mapped[id] = g.name
		}
	}
	for _, g := range oracleGroups {
		if !g.secondary {
			continue
		}
		for _, id := range g.ours {
			if _, owned := mapped[id]; !owned {
				t.Errorf("secondary group %s reads %q, which no primary group owns", g.name, id)
			}
		}
	}
	for _, id := range p.Order {
		_, isMapped := mapped[id]
		_, isUnanchored := oracleUnanchoredChecks[id]
		switch {
		case isMapped && isUnanchored:
			t.Errorf("check %q is both mapped and declared unanchored", id)
		case !isMapped && !isUnanchored:
			t.Errorf("check %q is neither mapped to a PSA check nor declared unanchored: "+
				"decide which, in oracleGroups or oracleUnanchoredChecks", id)
		}
	}
	known := map[string]bool{}
	for _, id := range p.Order {
		known[id] = true
	}
	for id := range mapped {
		if !known[id] {
			t.Errorf("oracleGroups maps %q, which the pack does not have", id)
		}
	}
	for id := range oracleUnanchoredChecks {
		if !known[id] {
			t.Errorf("oracleUnanchoredChecks names %q, which the pack does not have", id)
		}
	}
	t.Logf("unanchored by this tier (%d of %d pack checks): %s",
		len(oracleUnanchoredChecks), len(p.Order), strings.Join(oracleSortedKeys(oracleUnanchoredChecks), ", "))
}

// TestPSAOracle_MappingCoversEveryPSACheck fails if upstream adds or renames a
// check: a PSA check must be either mapped or explicitly declared as ground the
// pack does not cover. Without this, an upstream rename turns the oracle into a
// no-op silently.
func TestPSAOracle_MappingCoversEveryPSACheck(t *testing.T) {
	upstream := map[psapolicy.CheckID]bool{}
	for _, c := range psapolicy.DefaultChecks() {
		upstream[c.ID] = true
	}
	mapped := map[psapolicy.CheckID]bool{}
	for _, g := range oracleGroups {
		for _, id := range g.psa {
			if strings.HasPrefix(string(id), oracleAPIValidationPrefix) {
				continue // secondary oracle, not a PSA check
			}
			if !upstream[id] {
				t.Errorf("oracleGroups %q maps PSA check %q, which k8s.io/pod-security-admission "+
					"does not have (renamed or removed upstream)", g.name, id)
			}
			mapped[id] = true
		}
	}
	for id := range oracleUnrepresentedPSAChecks {
		if !upstream[id] {
			t.Errorf("oracleUnrepresentedPSAChecks names %q, which upstream does not have", id)
		}
		if mapped[id] {
			t.Errorf("PSA check %q is both mapped and declared unrepresented", id)
		}
	}
	for id := range upstream {
		if !mapped[id] {
			if _, declared := oracleUnrepresentedPSAChecks[id]; !declared {
				t.Errorf("PSA check %q is neither mapped nor declared unrepresented: "+
					"upstream has a check this pack is not measured against", id)
			}
		}
	}
}

// TestPSAOracle_ExceptionsAreWellFormed keeps the exception list honest: known
// names, no duplicates, and a reason on every entry.
func TestPSAOracle_ExceptionsAreWellFormed(t *testing.T) {
	p := cisPack(t)
	groupNames := map[string]bool{}
	for _, g := range oracleGroups {
		groupNames[g.name] = true
	}
	caseNames := map[string]bool{}
	for _, f := range cisFixtures(t, p) {
		caseNames[f.Name] = true
	}
	for n := range oracleProbePods {
		caseNames[n] = true
	}
	seen := map[string]bool{}
	for _, e := range oracleExceptions {
		key := e.Case + "/" + e.Group
		if seen[key] {
			t.Errorf("duplicate exception for %s", key)
		}
		seen[key] = true
		if !groupNames[e.Group] {
			t.Errorf("exception %s names unknown group %q", key, e.Group)
		}
		if !caseNames[e.Case] {
			t.Errorf("exception %s names unknown fixture or probe %q", key, e.Case)
		}
		if len(strings.TrimSpace(e.Reason)) < 40 {
			t.Errorf("exception %s has no usable reason", key)
		}
	}
}

func oracleSortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// --- negative tests: a green oracle that cannot go red is worthless ---------

// invertedPack returns the real CIS pack with one check's expression negated.
// The pack on disk is untouched; the inversion exists only in this process.
func invertedPack(t *testing.T, invert string) *Pack {
	t.Helper()
	real := cisPack(t)
	out := &Pack{ID: real.ID, Version: real.Version, Status: real.Status, Dir: real.Dir, Checks: map[string]Check{}}
	found := false
	for _, id := range real.Order {
		c := real.Checks[id]
		if id == invert {
			c.CELExpression = "!(" + c.CELExpression + ")"
			found = true
		}
		out.Order = append(out.Order, id)
		out.Checks[id] = c
	}
	if !found {
		t.Fatalf("cannot invert %q: the pack has no such check", invert)
	}
	return out
}

// TestPSAOracleNegative_InvertedCheckIsCaught injects a disagreement by
// negating one pack expression in memory and asserts the tier reports it. If
// this test passes with the inversion undetected, the tier is decoration.
func TestPSAOracleNegative_InvertedCheckIsCaught(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	real := cisPack(t)
	fixtures, _ := oracleFixtureCases(cisFixtures(t, real))
	cases := append(fixtures, oracleProbeCases(t)...)

	baseline, _ := oracleScan(t, eng, o, real, cases)
	baselineKeys := map[string]bool{}
	for _, d := range baseline {
		baselineKeys[d.Case+"/"+d.Group] = true
	}

	// Every mapped pack check, not a hand-picked few: if inverting a check
	// produces no new divergence, that check is not actually anchored.
	type inversion struct{ check, group string }
	var inversions []inversion
	for _, g := range oracleGroups {
		if g.secondary {
			continue
		}
		for _, id := range g.ours {
			inversions = append(inversions, inversion{id, g.name})
		}
	}
	for _, inv := range inversions {
		t.Run(inv.check, func(t *testing.T) {
			divs, _ := oracleScan(t, eng, o, invertedPack(t, inv.check), cases)
			var fresh int
			for _, d := range divs {
				if d.Group == inv.group && !baselineKeys[d.Case+"/"+d.Group] {
					fresh++
				}
			}
			if fresh == 0 {
				t.Fatalf("inverting %q produced no new divergence in group %q: the oracle "+
					"cannot detect a wrong verdict for this check", inv.check, inv.group)
			}
			unexcused, _ := applyExceptions(divs, oracleExceptions)
			if len(unexcused) == 0 {
				t.Fatalf("inverting %q produced divergences but the exception list excused all "+
					"%d of them: the exception list is too broad", inv.check, len(divs))
			}
			t.Logf("inverting %q: %d new divergences in %q, %d unexcused overall",
				inv.check, fresh, inv.group, len(unexcused))
		})
	}
}

// TestPSAOracleNegative_HostNetworkDefaultingIsApplied proves the API-server
// defaulting step is load-bearing. Without it, PSA judges the pod the author
// typed rather than the pod the API server stores, and three fixtures diverge
// on hostPorts for a reason that is purely an artefact of the oracle.
func TestPSAOracleNegative_HostNetworkDefaultingIsApplied(t *testing.T) {
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	raw := map[string]any{
		"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "p"},
		"spec": map[string]any{
			"hostNetwork": true,
			"containers": []any{map[string]any{"name": "c", "image": "i",
				"ports": []any{map[string]any{"containerPort": float64(8080)}}}},
		},
	}
	undefaulted, err := oracleDecodePod(raw)
	if err != nil {
		t.Fatal(err)
	}
	if v := o.check("hostPorts", undefaulted); !v.allowed {
		t.Fatal("undefaulted hostNetwork pod already rejected by hostPorts: the defaulting step is no longer load-bearing, re-check this test")
	}
	defaulted, err := oracleDecodePod(raw)
	if err != nil {
		t.Fatal(err)
	}
	oracleApplyAPIServerDefaults(defaulted)
	if v := o.check("hostPorts", defaulted); v.allowed {
		t.Fatal("defaulted hostNetwork pod still allowed by hostPorts: oracleApplyAPIServerDefaults did nothing, so the oracle is judging an object the API server would never store")
	}
	if got := defaulted.Spec.Containers[0].Ports[0].HostPort; got != 8080 {
		t.Errorf("hostPort after defaulting = %d, want 8080", got)
	}
	// Non-hostNetwork pods must be left alone.
	raw["spec"].(map[string]any)["hostNetwork"] = false
	plain, err := oracleDecodePod(raw)
	if err != nil {
		t.Fatal(err)
	}
	oracleApplyAPIServerDefaults(plain)
	if got := plain.Spec.Containers[0].Ports[0].HostPort; got != 0 {
		t.Errorf("hostPort defaulted on a non-hostNetwork pod: %d", got)
	}
}

// TestPSAOracleNegative_NecessaryOnlyStillCatchesPackPass proves the
// necessaryOnly relaxation only drops the direction it is meant to drop. A
// pack-pass against an oracle-reject must still be reported.
func TestPSAOracleNegative_NecessaryOnlyStillCatchesPackPass(t *testing.T) {
	g := []oracleGroup{{
		name: "secondary", ours: []string{"x"},
		psa: []psapolicy.CheckID{oracleAPIValidationSeccomp}, necessaryOnly: true,
	}}
	reject := map[psapolicy.CheckID]psaVerdict{oracleAPIValidationSeccomp: {allowed: false, detail: "invalid"}}
	allow := map[psapolicy.CheckID]psaVerdict{oracleAPIValidationSeccomp: {allowed: true}}

	if divs, _ := compareCase(g, "c", map[string]Verdict{"x": VerdictPass}, reject); len(divs) != 1 {
		t.Errorf("pack-pass vs oracle-reject: %d divergences, want 1", len(divs))
	}
	if divs, _ := compareCase(g, "c", map[string]Verdict{"x": VerdictFail}, allow); len(divs) != 0 {
		t.Errorf("pack-fail vs oracle-allow on a necessary-only oracle: %d divergences, want 0", len(divs))
	}
	// The same pair on a two-way group IS a divergence, or necessaryOnly would
	// be indistinguishable from the default.
	g[0].necessaryOnly = false
	if divs, _ := compareCase(g, "c", map[string]Verdict{"x": VerdictFail}, allow); len(divs) != 1 {
		t.Errorf("pack-fail vs oracle-allow on a two-way group: %d divergences, want 1", len(divs))
	}
}

// TestPSAOracleNegative_StaleExceptionIsCaught proves the stale-exception rule
// bites: an exception for a case that agrees, and an exception whose recorded
// direction is backwards, are both reported.
func TestPSAOracleNegative_StaleExceptionIsCaught(t *testing.T) {
	divs := []oracleDivergence{
		{Case: "drop-all-lowercase", Group: "capabilities", OursPass: true, PSAAllow: false, Detail: "x"},
	}
	t.Run("exception for an agreeing case", func(t *testing.T) {
		exc := []oracleException{
			{Case: "probe-restricted-compliant", Group: "privileged", OursPass: true, PSAAllow: false, Reason: "x"},
		}
		unexcused, stale := applyExceptions(nil, exc)
		if len(stale) != 1 || len(unexcused) != 0 {
			t.Fatalf("stale=%d unexcused=%d, want 1 and 0", len(stale), len(unexcused))
		}
	})
	t.Run("exception with the direction reversed", func(t *testing.T) {
		exc := []oracleException{
			{Case: "drop-all-lowercase", Group: "capabilities", OursPass: false, PSAAllow: true, Reason: "x"},
		}
		unexcused, stale := applyExceptions(divs, exc)
		if len(stale) != 1 {
			t.Errorf("reversed exception not reported stale: %d", len(stale))
		}
		if len(unexcused) != 1 {
			t.Errorf("real divergence excused by a reversed exception: %d unexcused", len(unexcused))
		}
	})
	t.Run("matching exception excuses and is not stale", func(t *testing.T) {
		exc := []oracleException{
			{Case: "drop-all-lowercase", Group: "capabilities", OursPass: true, PSAAllow: false, Reason: "x"},
		}
		unexcused, stale := applyExceptions(divs, exc)
		if len(stale) != 0 || len(unexcused) != 0 {
			t.Fatalf("stale=%d unexcused=%d, want 0 and 0", len(stale), len(unexcused))
		}
	})
}

// TestPSAOracleNegative_ComparisonDoesNotMistakeErrorForAgreement proves a
// non-comparable pack verdict is skipped and counted, never silently read as
// agreement with the oracle.
func TestPSAOracleNegative_ComparisonDoesNotMistakeErrorForAgreement(t *testing.T) {
	groups := []oracleGroup{{name: "privileged", ours: []string{"no-privileged-containers"}, psa: []psapolicy.CheckID{"privileged"}}}
	psaReject := map[psapolicy.CheckID]psaVerdict{"privileged": {allowed: false, detail: "privileged"}}

	divs, skipped := compareCase(groups, "c", map[string]Verdict{"no-privileged-containers": VerdictError}, psaReject)
	if len(divs) != 0 || len(skipped) != 1 {
		t.Errorf("error verdict: divs=%d skipped=%d, want 0 and 1", len(divs), len(skipped))
	}
	divs, skipped = compareCase(groups, "c", map[string]Verdict{}, psaReject)
	if len(divs) != 0 || len(skipped) != 1 {
		t.Errorf("missing verdict: divs=%d skipped=%d, want 0 and 1", len(divs), len(skipped))
	}
	divs, skipped = compareCase(groups, "c", map[string]Verdict{"no-privileged-containers": VerdictPass}, psaReject)
	if len(divs) != 1 || len(skipped) != 0 {
		t.Errorf("real disagreement: divs=%d skipped=%d, want 1 and 0", len(divs), len(skipped))
	}
	divs, skipped = compareCase(groups, "c", map[string]Verdict{"no-privileged-containers": VerdictFail}, psaReject)
	if len(divs) != 0 || len(skipped) != 0 {
		t.Errorf("agreement: divs=%d skipped=%d, want 0 and 0", len(divs), len(skipped))
	}
}

// TestPSAOracleNegative_PodDecodeIsStrict proves the oracle cannot be fed a pod
// that quietly lost a field. A silently-dropped securityContext would make PSA
// judge a different pod from the one CEL saw, which is the subtlest way for an
// oracle to manufacture agreement.
func TestPSAOracleNegative_PodDecodeIsStrict(t *testing.T) {
	var obj map[string]any
	if err := json.Unmarshal([]byte(`{"apiVersion":"v1","kind":"Pod",
      "metadata":{"name":"p"},
      "spec":{"containers":[{"name":"c","image":"i","securityContxt":{"privileged":true}}]}}`), &obj); err != nil {
		t.Fatal(err)
	}
	if !oraclePodShaped(obj) {
		t.Fatal("pod-shaped object rejected")
	}
	if _, err := oracleDecodePod(obj); err == nil {
		t.Fatal("misspelled field accepted: PSA would judge a pod the pack never saw")
	}
	if _, err := oracleDecodePod(map[string]any{
		"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": "p"},
		"spec": map[string]any{"containers": []any{map[string]any{"name": "c", "image": "i"}}},
	}); err != nil {
		t.Fatalf("well-formed pod rejected: %v", err)
	}
}

// TestPSAOracleNegative_SeccompAPIValidationBothDirections pins the transcribed
// upstream rule against the quoted source, in both directions.
func TestPSAOracleNegative_SeccompAPIValidationBothDirections(t *testing.T) {
	profile := "profiles/app.json"
	cases := []struct {
		name    string
		in      *corev1.SeccompProfile
		rejects bool
	}{
		{"nil", nil, false},
		{"runtimedefault", &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault}, false},
		{"localhost with profile", &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost, LocalhostProfile: &profile}, false},
		{"localhost without profile", &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}, true},
		{"runtimedefault with profile", &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault, LocalhostProfile: &profile}, true},
		{"unconfined with profile", &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeUnconfined, LocalhostProfile: &profile}, true},
	}
	for _, c := range cases {
		if got := oracleSeccompAPIValidation(c.in) != ""; got != c.rejects {
			t.Errorf("%s: rejects=%v, want %v", c.name, got, c.rejects)
		}
	}
	// And the walker must find profiles at every level, or the rule is applied
	// to a subset of the pod.
	pod := &corev1.Pod{Spec: corev1.PodSpec{
		SecurityContext: &corev1.PodSecurityContext{SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}},
		Containers: []corev1.Container{{Name: "a", SecurityContext: &corev1.SecurityContext{
			SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}}}},
		InitContainers: []corev1.Container{{Name: "b", SecurityContext: &corev1.SecurityContext{
			SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}}}},
		EphemeralContainers: []corev1.EphemeralContainer{{EphemeralContainerCommon: corev1.EphemeralContainerCommon{
			Name: "c", SecurityContext: &corev1.SecurityContext{
				SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeLocalhost}}}}},
	}}
	got := oracleSortedKeys(oracleSeccompProfilesOf(&pod.Spec))
	want := []string{"containers/a", "ephemeralContainers/c", "initContainers/b", "spec.securityContext"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("seccomp walker found %v, want %v", got, want)
	}
}
