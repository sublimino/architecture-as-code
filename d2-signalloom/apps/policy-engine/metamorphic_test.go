package main

// Metamorphic property tier for the framework packs.
//
// Every other instrument in this repo asserts a VERDICT: a fixture says
// "check X on input Y is `fail`", and one author wrote both the input and the
// expectation. That is the structural blind spot the adversarial review
// named — a wrong answer on an input shape no fixture contains cannot be
// caught by the fixtures, because the fixture set and the expressions it
// judges share an author and therefore share a misconception.
//
// These tests assert nothing about any single verdict. They assert a RELATION
// between the verdicts of two related inputs, so there is no expectation for a
// misconception to live in:
//
//	add a compliant container   -> no `fail` may become `pass`   (monotonicity)
//	add a violating container   -> verdict(A ⊎ B) == fail(A) ∨ fail(B)
//	move that violation between
//	  container kinds           -> same verdict, or a DECLARED scope
//	perturb a field DECLARED
//	  irrelevant                -> no verdict may change at all
//
// Inputs are derived from the existing fixture estate rather than hand-written,
// so the relations cover every pod the packs are already proven against.
//
// Scope notes, and what is deliberately NOT here:
//
//   - Container REORDERING is not tested: no pack indexes a container
//     positionally and CEL's `.all()`/`.exists()` over a list are
//     order-invariant by construction, so the property cannot fail.
//   - Container DUPLICATION is not tested: it is false, not unproven. Several
//     packs guard with `size(object.spec.containers) > 0` and read that size,
//     so duplicating a container legitimately moves those verdicts; and two
//     containers with one name is schema-invalid, so the input cannot exist.
//   - IDEMPOTENCE is not tested here: compliance_adversarial_scan_test.go
//     already pins two scans of one input to identical verdicts and ALE.
//   - FIELD LOCALITY in its general form ("only checks that read field F may
//     change when F changes") is not tested, because deriving the permitted
//     set from expression TEXT has no workable setting: every CIS check is
//     prefixed `has(object.spec) && …` and reads containers through a
//     comprehension variable, so segment matching permits everything and leaf
//     matching permits nothing. readsObject (workload_shape.go) is textual and
//     over-inclusive because for a SHAPE GUARD over-inclusion fails toward
//     `error`; for locality over-inclusion fails toward silence, so copying
//     the technique inverts its safety property. Doing it properly needs a CEL
//     AST walk with comprehension-binding resolution. What is here instead is
//     the falsifiable half: declared irrelevance.
//   - The POD/CONTAINER INHERITANCE MATRIX is not here. Its expectations would
//     have to come from somewhere, and transcribing Kubernetes prose into this
//     file would re-commit the circularity the tier exists to break. The
//     matrix cells are probe pods in the external oracle tier instead
//     (oracle/inheritance_matrix_test.go), where k8s.io/pod-security-admission
//     computes the effective pod/container fields itself and supplies the
//     verdicts.
//
// THE RULE THAT KEEPS THIS FROM BECOMING THE SAME TRAP: a relation is never
// weakened to accommodate current behaviour. Where current behaviour violates
// a relation, the divergence is recorded in an individually-justified list —
// and an entry that stops being needed is itself a failure, the same discipline
// as oracle/psa_oracle_test.go's exception list.

import (
	"context"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

// --- scanning -----------------------------------------------------------

// mmScanner holds the one engine every relation below reuses.
//
// It evaluates in-process rather than through handleScan. The relations need
// verdicts, not money, and they need tens of thousands of evaluations: a
// perturbation sweep through the HTTP handler costs ~6.7 ms per input (JSON
// round trip, store write and a FAIR run per check) against ~0.15 ms here,
// which is the difference between a 20-second tier and a four-minute one. The
// handler path is not left unproven — compliance_fixture_scan_test.go POSTs
// every fixture in the estate through it — and the input-shape guard applied
// here is the same shapeWorkload/verdictFor pair handleScan applies, exactly
// as in evaluateFixture.
type mmScanner struct {
	eng   *CELEngine
	packs []*conformancePack
}

func newMMScanner(t *testing.T) mmScanner {
	t.Helper()
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	return mmScanner{eng: eng, packs: loadConformancePacks(t, conformancePolicyRoot(t))}
}

// verdicts evaluates every check in the pack, not only the ones some fixture
// happens to expect: a perturbation may move a check no fixture mentions, and
// that is precisely the blind spot this tier exists for.
func (s mmScanner) verdicts(t *testing.T, p *conformancePack, in conformanceInput) map[string]Verdict {
	t.Helper()
	shaped := shapeWorkload(in.Object)
	bindings := celBindings(shaped.object, in.Agent, in.Request)
	out := make(map[string]Verdict, len(p.order))
	for _, id := range p.order {
		if p.placeholder(id) {
			out[id] = VerdictNotEvaluated
			continue
		}
		expr := p.checks[id].CELExpression
		if v, _, guarded := shaped.verdictFor(expr); guarded {
			out[id] = v
			continue
		}
		passed, _, err := s.eng.Evaluate(context.Background(), expr, bindings)
		out[id] = verdictOf(passed, err)
	}
	return out
}

// mmClone deep-copies through JSON, which also re-decodes numbers to float64
// exactly as a request body would.
func mmClone[T any](v T) T {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	var out T
	if err := json.Unmarshal(raw, &out); err != nil {
		panic(err)
	}
	return out
}

func mmSortedIDs[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// --- the pod corpus -----------------------------------------------------

// mmPod is one fixture-derived input: a pod-shaped object plus the fixture's
// own agent and request documents, scanned against the fixture's own pack.
type mmPod struct {
	pack *conformancePack
	name string
	in   conformanceInput
}

func mmSpec(obj map[string]any) (map[string]any, bool) {
	spec, ok := obj["spec"].(map[string]any)
	return spec, ok
}

func mmList(obj map[string]any, key string) ([]any, bool) {
	spec, ok := mmSpec(obj)
	if !ok {
		return nil, false
	}
	list, ok := spec[key].([]any)
	return list, ok
}

func mmSetList(obj map[string]any, key string, list []any) {
	spec, ok := mmSpec(obj)
	if !ok {
		panic("mmSetList on an object with no spec")
	}
	spec[key] = list
}

// mmPodCorpus is every fixture in the estate whose object is a pod carrying a
// containers list. Fixtures whose object is absent, malformed or
// controller-shaped are excluded — there is no container list to perturb —
// and counted.
func mmPodCorpus(t *testing.T, s mmScanner) ([]mmPod, int) {
	t.Helper()
	var pods []mmPod
	skipped := 0
	for _, p := range s.packs {
		for _, f := range p.fixtures {
			f = roundTripFixtureInput(t, f)
			if _, ok := mmList(f.Input.Object, "containers"); !ok {
				skipped++
				continue
			}
			pods = append(pods, mmPod{pack: p, name: p.label() + "/" + f.Name, in: f.Input})
		}
	}
	if len(pods) < 100 {
		t.Fatalf("only %d pod-shaped fixtures found (%d skipped): the relations would be near-vacuous", len(pods), skipped)
	}
	return pods, skipped
}

// --- container building blocks ------------------------------------------

// mmCompliantContainer satisfies every per-container control in the estate it
// can: non-root by both means, no escalation, all capabilities dropped,
// RuntimeDefault seccomp, read-only root, a digest-pinned image on the allowed
// registry, resources and probes, no host port and no secret in env.
func mmCompliantContainer(name string) map[string]any {
	return map[string]any{
		"name":  name,
		"image": "ghcr.io/controlplaneio-in-toto/app@sha256:" + strings.Repeat("b", 64),
		"securityContext": map[string]any{
			"privileged":               false,
			"allowPrivilegeEscalation": false,
			"runAsNonRoot":             true,
			"runAsUser":                1000,
			"readOnlyRootFilesystem":   true,
			"capabilities":             map[string]any{"drop": []any{"ALL"}},
			"seccompProfile":           map[string]any{"type": "RuntimeDefault"},
			"windowsOptions":           map[string]any{"hostProcess": false},
		},
		"ports":          []any{map[string]any{"containerPort": 8080, "name": "http"}},
		"resources":      map[string]any{"limits": map[string]any{"cpu": "500m", "memory": "256Mi"}, "requests": map[string]any{"cpu": "100m", "memory": "128Mi"}},
		"livenessProbe":  map[string]any{"httpGet": map[string]any{"path": "/healthz", "port": 8080}},
		"readinessProbe": map[string]any{"httpGet": map[string]any{"path": "/ready", "port": 8080}},
		"volumeMounts":   []any{map[string]any{"name": "logs", "mountPath": "/var/log/app"}},
		"env":            []any{map[string]any{"name": "LOG_LEVEL", "value": "info"}},
	}
}

// mmViolatingContainer violates every per-container control the estate has:
// privileged, escalating, uid 0, root by declaration, added NET_ADMIN and
// NET_RAW, Unconfined seccomp, Windows HostProcess, a mutable root, an
// untrusted floating tag, a host port and a secret in env.
//
// It deliberately sets no `resources`, no probes and no `lifecycle`, so the
// same object is admissible as an init container as well as an app container.
func mmViolatingContainer(name string) map[string]any {
	return map[string]any{
		"name":  name,
		"image": "attacker.example/tools:latest",
		"securityContext": map[string]any{
			"privileged":               true,
			"allowPrivilegeEscalation": true,
			"runAsNonRoot":             false,
			"runAsUser":                0,
			"readOnlyRootFilesystem":   false,
			"capabilities":             map[string]any{"add": []any{"NET_ADMIN", "NET_RAW"}},
			"seccompProfile":           map[string]any{"type": "Unconfined"},
			"windowsOptions":           map[string]any{"hostProcess": true},
		},
		"ports": []any{map[string]any{"containerPort": 8080, "hostPort": 8080}},
		"env": []any{map[string]any{
			"name":      "TOKEN",
			"valueFrom": map[string]any{"secretKeyRef": map[string]any{"name": "creds", "key": "token"}},
		}},
		"volumeMounts": []any{map[string]any{"name": "root", "mountPath": "/host"}},
	}
}

// mmViolatorFor returns the violating container in the form the named
// collection admits. The API server rejects `ports`, `resources`, `lifecycle`
// and probes on an ephemeral container, so the ephemeral form drops `ports`;
// comparing an ephemeral violator that carries a host port against an app
// container that does would be comparing two different violations.
func mmViolatorFor(collection, name string) map[string]any {
	c := mmViolatingContainer(name)
	if collection == "ephemeralContainers" {
		delete(c, "ports")
	}
	return c
}

// --- expression-derived collection reads --------------------------------

// mmFieldPathRe builds a matcher for a dotted field path read off the
// workload: `object.spec.initContainers`, `manifest . spec . containers`.
func mmFieldPathRe(segments ...string) *regexp.Regexp {
	parts := []string{`(?:object|manifest)`}
	for _, s := range segments {
		parts = append(parts, regexp.QuoteMeta(s))
	}
	return regexp.MustCompile(`(^|[^A-Za-z0-9_.])` + strings.Join(parts, `\s*\.\s*`) + `\b`)
}

// mmReadsCollection reports whether a check reads a named container collection
// at all. A collection absent from the text means the check is scoped to app
// containers, which must then be a declared, justified scope.
func mmReadsCollection(expr, collection string) bool {
	return mmFieldPathRe("spec", collection).MatchString(expr)
}

// --- declared scopes: checks deliberately narrowed to app containers -----

// mmDeclaredScope records one check that deliberately does NOT look at a
// container kind, with the Kubernetes reason the narrowing is correct. An
// undeclared narrowing is a failure; a declared scope no pack exercises, or
// one that turns out not to be a real narrowing, is also a failure.
type mmDeclaredScope struct {
	Check      string
	Collection string // initContainers | ephemeralContainers
	Reason     string
}

var mmDeclaredScopes = []mmDeclaredScope{
	{"resource-limits-set", "ephemeralContainers",
		"The API server rejects `resources` on an ephemeral container (core/v1 EphemeralContainerCommon: resources are not allowed), so there is nothing there to judge."},
	{"resource-requests-set", "ephemeralContainers",
		"Same API restriction: an ephemeral container cannot declare resources."},
	{"liveness-probe-present", "initContainers",
		"A regular init container may not declare livenessProbe (only a restartPolicy:Always sidecar may), so requiring one would be unsatisfiable."},
	{"liveness-probe-present", "ephemeralContainers",
		"The API server rejects probes on an ephemeral container."},
	{"readiness-probe-present", "initContainers",
		"A regular init container may not declare readinessProbe, so requiring one would be unsatisfiable."},
	{"readiness-probe-present", "ephemeralContainers",
		"The API server rejects probes on an ephemeral container."},
	{"log-volume-mount", "initContainers",
		"The control is about the long-running workload's log stream; an init container exits before the workload starts and produces none of it."},
	{"log-volume-mount", "ephemeralContainers",
		"An ephemeral debug container is injected by an operator at troubleshooting time, is not part of the audited log path, and cannot be declared in a manifest at all."},
}

func mmScopeFor(check, collection string) (mmDeclaredScope, bool) {
	for _, d := range mmDeclaredScopes {
		if d.Check == check && d.Collection == collection {
			return d, true
		}
	}
	return mmDeclaredScope{}, false
}

// --- the entry point ----------------------------------------------------

// TestMetamorphic runs every relation against one handler and one engine. The
// sub-test names are the relation names; each reports the fixture and both
// verdicts on failure.
func TestMetamorphic(t *testing.T) {
	s := newMMScanner(t)
	pods, skipped := mmPodCorpus(t, s)
	t.Logf("corpus: %d pod-shaped fixtures across %d packs (%d fixtures skipped: no spec.containers list)",
		len(pods), len(s.packs), skipped)

	t.Run("compliant_container_never_rescues_a_fail", func(t *testing.T) { mmMonotonicity(t, s, pods) })
	t.Run("union_of_container_sets_is_conjunctive", func(t *testing.T) { mmConjunctivity(t, s, pods) })
	t.Run("container_kind_equivalence", func(t *testing.T) { mmContainerKindEquivalence(t, s, pods) })
	t.Run("declared_irrelevance", func(t *testing.T) { mmDeclaredIrrelevance(t, s, pods) })
}

// --- relation 1: monotonicity -------------------------------------------

// Adding a compliant container to a pod can never turn a `fail` into a `pass`.
// This is the relation that catches `exists` where `all` was meant: under
// `exists`, one compliant container satisfies the whole pod and every real
// violation beside it disappears.
//
// Pods with an EMPTY containers list are excluded, as in mmConjunctivity: the
// `size(object.spec.containers) > 0` guard several packs carry fails closed on
// a zero-container pod, so the first container added legitimately turns those
// checks from fail to pass. Measured: 385 of the 385 rescues the relation
// reported before this exclusion came from `*--no-containers` fixtures in
// nist-800-53 and eu-ai-act, every one of them that guard opening, and none
// from a non-conjunctive aggregation. A Pod with no containers is not
// admissible in Kubernetes, so the exclusion costs no real input — but it is
// an exclusion, not a weakening of the relation, and the zero-container
// behaviour itself is pinned by the `empty-containers-vacuous` and
// `*--no-containers` fixtures.
func mmMonotonicity(t *testing.T, s mmScanner, pods []mmPod) {
	start := time.Now()
	pairs, rescued, failing, emptyExcluded := 0, 0, 0, 0
	for _, pod := range pods {
		if list, _ := mmList(pod.in.Object, "containers"); len(list) == 0 {
			emptyExcluded++
			continue
		}
		want := s.verdicts(t, pod.pack, pod.in)
		fails := 0
		for _, v := range want {
			if v == VerdictFail {
				fails++
			}
		}
		if fails == 0 {
			continue
		}
		failing++
		in := mmClone(pod.in)
		cur, _ := mmList(in.Object, "containers")
		mmSetList(in.Object, "containers", append(cur, mmCompliantContainer("mm-compliant")))
		got := s.verdicts(t, pod.pack, in)
		pairs++
		for _, id := range mmSortedIDs(want) {
			if want[id] == VerdictFail && got[id] == VerdictPass {
				rescued++
				t.Errorf("%s: check %q was fail; adding one compliant container made it pass. "+
					"Aggregation over the container set is not conjunctive (an `exists` where an `all` "+
					"was meant), so a single compliant container hides every violation beside it.",
					pod.name, id)
			}
		}
	}
	if failing < 20 {
		t.Fatalf("only %d fixtures produced a fail: monotonicity is near-vacuous", failing)
	}
	t.Logf("%d (fixture, +compliant container) pairs over %d failing fixtures (%d zero-container "+
		"fixtures excluded), %d rescues, in %s",
		pairs, failing, emptyExcluded, rescued, time.Since(start).Round(time.Millisecond))
}

// --- relation 2: the converse, as an exact identity ---------------------

// Let A be a fixture pod and B the same pod with its app containers replaced
// by one maximally-violating container. Their union U is A with that container
// appended. Every per-container check aggregates
// `containers + initContainers + ephemeralContainers` with `.all()`, and A, B
// and U share every pod-level field, so
//
//	all(U) = all(A.containers) ∧ all(violator) ∧ all(init) ∧ all(eph)
//	       = all(A) ∧ all(B)
//
// exactly. verdict(U) must therefore be `fail` iff A fails or B fails, and
// `pass` iff both pass. An `all()` over the wrong collection breaks the first
// direction; an `exists()` breaks the second. This is the brief's "adding a
// violating container must turn the relevant check to fail" stated as an
// identity, so there is no hand-authored notion of "relevant".
//
// Fixtures with an EMPTY containers list are excluded: several packs guard with
// `size(object.spec.containers) > 0`, which fails closed on a zero-container
// pod and so is deliberately non-monotone in the container set. A Pod with no
// containers is not admissible in Kubernetes, so the exclusion costs no real
// input.
func mmConjunctivity(t *testing.T, s mmScanner, pods []mmPod) {
	start := time.Now()
	triples, emptyExcluded, violatorFails, passingUnions := 0, 0, 0, 0
	for _, pod := range pods {
		list, _ := mmList(pod.in.Object, "containers")
		if len(list) == 0 {
			emptyExcluded++
			continue
		}
		a := s.verdicts(t, pod.pack, pod.in)

		bIn := mmClone(pod.in)
		mmSetList(bIn.Object, "containers", []any{mmViolatingContainer("mm-violator")})
		b := s.verdicts(t, pod.pack, bIn)

		uIn := mmClone(pod.in)
		cur, _ := mmList(uIn.Object, "containers")
		mmSetList(uIn.Object, "containers", append(cur, mmViolatingContainer("mm-violator")))
		u := s.verdicts(t, pod.pack, uIn)
		triples++

		for _, id := range mmSortedIDs(a) {
			va, vb, vu := a[id], b[id], u[id]
			// An unevaluable or unevaluated check carries no verdict to
			// conjoin; the shape guard and placeholders are other tiers'
			// subject.
			if va != VerdictPass && va != VerdictFail {
				continue
			}
			if vb != VerdictPass && vb != VerdictFail {
				continue
			}
			if vu != VerdictPass && vu != VerdictFail {
				t.Errorf("%s: check %q: A=%s and violator-only B=%s are both decided, but their union "+
					"is %s", pod.name, id, va, vb, vu)
				continue
			}
			if vb == VerdictFail {
				violatorFails++
			}
			if va == VerdictFail || vb == VerdictFail {
				if vu != VerdictFail {
					t.Errorf("%s: check %q: A=%s, violator-only B=%s, union=%s — the union of two "+
						"container sets must fail when either fails", pod.name, id, va, vb, vu)
				}
				continue
			}
			if vu != VerdictPass {
				t.Errorf("%s: check %q: A=%s, violator-only B=%s, union=%s — the union must pass when "+
					"both pass", pod.name, id, va, vb, vu)
				continue
			}
			passingUnions++
		}
	}
	if violatorFails == 0 || passingUnions == 0 {
		t.Fatalf("conjunctivity is vacuous: %d violator-only fails, %d passing unions", violatorFails, passingUnions)
	}
	t.Logf("%d (fixture, A/B/union) triples (%d zero-container fixtures excluded), %d violator fails, "+
		"%d passing unions, in %s", triples, emptyExcluded, violatorFails, passingUnions,
		time.Since(start).Round(time.Millisecond))
}

// --- relation 3: container-kind equivalence (scoped) --------------------

// A violation is a violation wherever the kubelet runs it. Placing the SAME
// violating container in `initContainers` or `ephemeralContainers` instead of
// `containers` must yield the same verdict for every check that reads that
// collection — and where a pack narrows a check to app containers, the
// narrowing must be declared with a Kubernetes reason and is then asserted to
// be a real narrowing (the verdict stays the untouched baseline's).
//
// The equivalence is scoped, not blanket, because the API does not treat the
// three kinds alike:
//
//   - an ephemeral container may not declare `ports`, `resources`,
//     `lifecycle` or probes, so the violator is adjusted per collection
//     (mmViolatorFor) and the app-container reference uses the identical
//     object — otherwise two different violations would be compared;
//   - a `restartPolicy: Always` init container (a sidecar, 1.29+) runs
//     alongside the app containers and may carry probes, so it behaves like
//     neither kind. No sidecar is exercised here; that is a declared gap, not
//     a claim.
func mmContainerKindEquivalence(t *testing.T, s mmScanner, pods []mmPod) {
	start := time.Now()
	type scopeKey struct{ check, collection string }
	usedScopes := map[scopeKey]bool{}
	pairs, equivalences := 0, 0

	for _, pod := range pods {
		list, _ := mmList(pod.in.Object, "containers")
		if len(list) == 0 {
			continue // see mmConjunctivity on zero-container pods
		}
		base := s.verdicts(t, pod.pack, pod.in)

		for _, collection := range []string{"initContainers", "ephemeralContainers"} {
			violator := mmViolatorFor(collection, "mm-violator")

			appIn := mmClone(pod.in)
			cur, _ := mmList(appIn.Object, "containers")
			mmSetList(appIn.Object, "containers", append(cur, mmClone(violator)))
			app := s.verdicts(t, pod.pack, appIn)

			altIn := mmClone(pod.in)
			existing, _ := mmList(altIn.Object, collection)
			mmSetList(altIn.Object, collection, append(existing, mmClone(violator)))
			alt := s.verdicts(t, pod.pack, altIn)
			pairs++

			for _, id := range mmSortedIDs(app) {
				expr := pod.pack.checks[id].CELExpression
				if !mmReadsCollection(expr, "containers") {
					continue // not a per-container check
				}
				if mmReadsCollection(expr, collection) {
					equivalences++
					if app[id] != alt[id] {
						t.Errorf("%s: check %q reads %s but judges the same violating container "+
							"differently there: in containers=%s, in %s=%s",
							pod.name, id, collection, app[id], collection, alt[id])
					}
					continue
				}
				// The check does not read this collection. That must be a
				// declared scope, and it must be a real one: a violation
				// placed there has to leave the baseline verdict untouched.
				d, ok := mmScopeFor(id, collection)
				if !ok {
					t.Errorf("%s: check %q ignores %s with no declared scope — either read the "+
						"collection or declare the narrowing with a Kubernetes reason in mmDeclaredScopes",
						pod.name, id, collection)
					continue
				}
				usedScopes[scopeKey{id, collection}] = true
				if alt[id] != base[id] {
					t.Errorf("%s: check %q is declared scoped away from %s (%s) but a violation placed "+
						"there changed its verdict: baseline=%s, with the violation in %s=%s",
						pod.name, id, collection, d.Reason, base[id], collection, alt[id])
				}
			}
		}
	}

	// A declared scope no pack exercises is stale and must be deleted.
	for _, d := range mmDeclaredScopes {
		if !usedScopes[scopeKey{d.Check, d.Collection}] {
			t.Errorf("declared scope %q/%s is stale: no pack has a check of that name that ignores the "+
				"collection. Delete it.", d.Check, d.Collection)
		}
	}
	if equivalences == 0 {
		t.Fatal("no check both reads a container collection and was compared: the relation is vacuous")
	}
	t.Logf("%d (fixture, collection) pairs, %d check-level equivalences asserted, %d declared scopes "+
		"exercised, in %s", pairs, equivalences, len(usedScopes), time.Since(start).Round(time.Millisecond))
}

// --- relation 4: declared irrelevance -----------------------------------

// mmIrrelevance is a CLAIM: perturbing this field changes no verdict anywhere
// in the estate. It is the falsifiable half of field locality. The general
// form ("only checks that read F may change") needs a CEL AST to state
// honestly; this form needs nothing, because the permitted set is empty.
//
// Each entry is a reviewable assertion by its author, enforced by the test
// against every pod in the estate. A red here is one of two things and never a
// third: the claim is wrong (narrow it and say why), or a pack reads a field it
// has no business reading (a finding). It is never "pin the current output".
type mmIrrelevance struct {
	Name   string
	Apply  func(obj map[string]any)
	Reason string
}

func mmMeta(obj map[string]any) map[string]any {
	meta, ok := obj["metadata"].(map[string]any)
	if !ok {
		meta = map[string]any{}
		obj["metadata"] = meta
	}
	return meta
}

func mmMetaMap(obj map[string]any, key string) map[string]any {
	meta := mmMeta(obj)
	m, ok := meta[key].(map[string]any)
	if !ok {
		m = map[string]any{}
		meta[key] = m
	}
	return m
}

func mmEachContainer(obj map[string]any, fn func(c map[string]any)) {
	for _, key := range []string{"containers", "initContainers", "ephemeralContainers"} {
		list, ok := mmList(obj, key)
		if !ok {
			continue
		}
		for _, raw := range list {
			if c, ok := raw.(map[string]any); ok {
				fn(c)
			}
		}
	}
}

var mmIrrelevances = []mmIrrelevance{
	{
		Name:   "unrecognised annotation",
		Apply:  func(obj map[string]any) { mmMetaMap(obj, "annotations")["osramp.io/mm-probe"] = "1" },
		Reason: "Every annotation-reading check in the estate names its own key. An annotation no pack documents carries no governance fact, so no verdict may move. If one does, a check is reading the annotation map structurally (size, emptiness, prefix) rather than its own key.",
	},
	{
		Name:   "unrecognised label",
		Apply:  func(obj map[string]any) { mmMetaMap(obj, "labels")["osramp.io/mm-probe"] = "1" },
		Reason: "Same argument for labels: the label-reading checks name their keys. A new key no pack documents must not move a verdict.",
	},
	{
		Name:   "object name",
		Apply:  func(obj map[string]any) { mmMeta(obj)["name"] = "mm-renamed-object" },
		Reason: "No control in any pack judges what a workload is called. metadata.name is identity, not posture.",
	},
	{
		Name: "server-populated identity fields",
		Apply: func(obj map[string]any) {
			meta := mmMeta(obj)
			meta["uid"] = "11111111-2222-3333-4444-555555555555"
			meta["resourceVersion"] = "987654"
			meta["generation"] = 7
			meta["creationTimestamp"] = "2020-01-01T00:00:00Z"
		},
		Reason: "These are set by the API server, differ between a manifest and a live object, and are not posture. A check that moved on them would judge a workload differently depending on whether it was read from git or from the cluster.",
	},
	{
		Name: "container diagnostics fields",
		Apply: func(obj map[string]any) {
			mmEachContainer(obj, func(c map[string]any) {
				c["terminationMessagePath"] = "/dev/termination-log"
				c["terminationMessagePolicy"] = "FallbackToLogsOnError"
			})
		},
		Reason: "Termination-message plumbing is container diagnostics, not security or resilience posture, and no control in the estate covers it.",
	},
}

// mmIrrelevanceChanges applies one perturbation across the corpus and returns
// every verdict that moved. Shared with the self-test, which uses a field that
// IS relevant to prove the walk can see a change.
func mmIrrelevanceChanges(t *testing.T, s mmScanner, pods []mmPod, apply func(map[string]any)) (changes []string, pairs int) {
	t.Helper()
	for _, pod := range pods {
		want := s.verdicts(t, pod.pack, pod.in)
		in := mmClone(pod.in)
		apply(in.Object)
		got := s.verdicts(t, pod.pack, in)
		pairs++
		for _, id := range mmSortedIDs(want) {
			if want[id] != got[id] {
				changes = append(changes, pod.name+": check "+id+": "+string(want[id])+" -> "+string(got[id]))
			}
		}
	}
	return changes, pairs
}

// The claims are proved together and bisected only on failure. Applying all of
// them at once and finding no verdict moved proves every one of them
// individually — irrelevance is closed under composition in the direction that
// matters, since any single relevant field would show up in the combined
// result. One sweep of the corpus instead of five.
func mmDeclaredIrrelevance(t *testing.T, s mmScanner, pods []mmPod) {
	start := time.Now()
	combined, pairs := mmIrrelevanceChanges(t, s, pods, func(obj map[string]any) {
		for _, irr := range mmIrrelevances {
			irr.Apply(obj)
		}
	})
	t.Logf("%d claims proved together over %d (fixture, perturbation) pairs, %d verdict changes, in %s",
		len(mmIrrelevances), pairs, len(combined), time.Since(start).Round(time.Millisecond))
	if len(combined) == 0 {
		return
	}
	// Something moved. Attribute it to a claim, so the failure names the one
	// that is wrong rather than the whole set.
	t.Errorf("the declared-irrelevance set moved %d verdicts; bisecting", len(combined))
	for _, irr := range mmIrrelevances {
		irr := irr
		t.Run(irr.Name, func(t *testing.T) {
			changes, _ := mmIrrelevanceChanges(t, s, pods, irr.Apply)
			for _, c := range changes {
				t.Errorf("%q is declared irrelevant (%s) but perturbing it moved a verdict: %s",
					irr.Name, irr.Reason, c)
			}
		})
	}
}

// --- tier self-tests: every checker must bite ---------------------------

// The relations above earn their runtime only if their checkers fail when the
// relation is broken. These exercise the comparison logic and the corpus walk
// directly — the parts a mutation inside a pack cannot reach.

func TestMetamorphicTier_IrrelevanceWalkSeesARelevantField(t *testing.T) {
	// The declared-irrelevance walk asserts "nothing changed". A walk that
	// could not see a change would pass every claim vacuously. Perturbing
	// metadata.namespace, which no-default-namespace does read, must produce
	// changes — so a green claim means the field really is inert.
	s := newMMScanner(t)
	pods, _ := mmPodCorpus(t, s)
	changes, pairs := mmIrrelevanceChanges(t, s, pods, func(obj map[string]any) {
		mmMeta(obj)["namespace"] = "default"
	})
	if len(changes) == 0 {
		t.Fatalf("relocating %d pods into the default namespace moved no verdict: the irrelevance walk "+
			"is blind and every claim it passes is vacuous", pairs)
	}
	t.Logf("control: namespace -> default moved %d verdicts over %d pods", len(changes), pairs)
}

func TestMetamorphicTier_CheckersBite(t *testing.T) {
	t.Run("collection detector distinguishes app-only from all-kinds", func(t *testing.T) {
		all := "(object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : []) + " +
			"(has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])).all(c, true)"
		appOnly := "object.spec.containers.all(c, has(c.resources))"
		for _, col := range []string{"containers", "initContainers", "ephemeralContainers"} {
			if !mmReadsCollection(all, col) {
				t.Errorf("all-kinds expression not detected as reading %s", col)
			}
		}
		if !mmReadsCollection(appOnly, "containers") {
			t.Error("app-only expression not detected as reading containers")
		}
		for _, col := range []string{"initContainers", "ephemeralContainers"} {
			if mmReadsCollection(appOnly, col) {
				t.Errorf("app-only expression wrongly detected as reading %s", col)
			}
		}
		// Near misses: another binding's field, and a longer identifier.
		for _, expr := range []string{"agent.spec.containers.all(c, true)", "object.spec.containersAll"} {
			if mmReadsCollection(expr, "containers") {
				t.Errorf("%q wrongly detected as a workload containers read", expr)
			}
		}
	})

	t.Run("compliant and violating containers are genuinely opposed", func(t *testing.T) {
		// If the compliant container failed checks, monotonicity would have
		// nothing to rescue; if the violating one passed them, conjunctivity
		// and kind-equivalence would compare two compliant pods.
		s := newMMScanner(t)
		var cis *conformancePack
		for _, p := range s.packs {
			if p.fw.ID == cisPackID {
				cis = p
			}
		}
		if cis == nil {
			t.Fatal("no cis pack loaded")
		}
		pod := func(c map[string]any) conformanceInput {
			return conformanceInput{Object: map[string]any{
				"apiVersion": "v1", "kind": "Pod",
				"metadata": map[string]any{"name": "x", "namespace": "payments"},
				"spec": map[string]any{
					"automountServiceAccountToken": false,
					"securityContext": map[string]any{
						"runAsNonRoot":   true,
						"seccompProfile": map[string]any{"type": "RuntimeDefault"},
					},
					"containers": []any{c},
				},
			}}
		}
		good := tally(s.verdicts(t, cis, pod(mmCompliantContainer("app"))))
		bad := tally(s.verdicts(t, cis, pod(mmViolatingContainer("app"))))
		if good[VerdictFail] != 0 || good[VerdictError] != 0 {
			t.Errorf("the compliant container is not a compliant baseline: %v", good)
		}
		if bad[VerdictFail] < 10 {
			t.Errorf("the violating container only fails %d CIS checks: too weak to drive the relations (%v)",
				bad[VerdictFail], bad)
		}
	})
}
