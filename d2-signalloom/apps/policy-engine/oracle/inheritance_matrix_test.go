package oracle

// The pod-level / container-level inheritance matrix, anchored to the external
// oracle.
//
// Four securityContext fields exist at BOTH pod and container level, and
// Kubernetes resolves them by precedence: a container-level value overrides the
// pod's, an absent container-level value inherits it. Every one of them is a
// place a pack can be wrong in a way no fixture notices — read only the pod
// level and a pod hardened by its containers is reported non-compliant; read
// only the container level and a pod hardened once at the top is reported
// non-compliant.
//
// The expectations for those cells are deliberately NOT written here. Writing
// "pod=true, container=unset must pass" into this file would mean transcribing
// Kubernetes prose into a test and then checking the pack against my
// transcription — the same circularity (one author, one misconception) that
// the whole oracle tier exists to break, just with more steps.
//
// Instead the cells are PROBE PODS. k8s.io/pod-security-admission computes the
// effective pod/container fields itself, so registering the cells in
// oracleProbePods hands them to TestPSAOracle_PackAgreesWithPodSecurityAdmission
// and the matrix inherits, for free:
//
//   - an executable oracle (PSA's own verdict per cell, not my reading of the
//     docs);
//   - the two-way interlock — a divergence in either direction fails, and an
//     exception that stops diverging fails as stale;
//   - the inversion proof that tier already runs over every mapped check.
//
// This file therefore contains no verdict expectations at all. It contains the
// cell generator, a non-vacuity gate (a matrix whose cells all agree is
// testing nothing), and one injected-defect proof showing that a pack check
// which reads only the pod level is caught by these cells.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"

	psapolicy "k8s.io/pod-security-admission/policy"
)

// --- the fields and their values ----------------------------------------

// inheritField is one securityContext field present at both levels. `group`
// names the oracleGroup that already maps our checks to PSA's for this field,
// so the mapping is declared once, in psa_oracle_test.go, and reused here.
type inheritField struct {
	name    string
	group   string
	podPath []string // within spec
	ctrPath []string // within a container
	order   []string // value labels; "unset" removes the field
	values  map[string]any
	// base is the pod every cell of this field is built from: compliant in
	// every respect except the field under test, which base must not set at
	// either level, so a cell's verdict is attributable to the cell.
	base func() map[string]any
}

// inheritBasePod is restricted-compliant: non-root by uid, RuntimeDefault
// seccomp, no escalation, all capabilities dropped, no token automount, a
// non-default namespace. Each field's base() then strips whatever it varies.
func inheritBasePod() map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata":   map[string]any{"name": "placeholder", "namespace": "payments"},
		"spec": map[string]any{
			"automountServiceAccountToken": false,
			"securityContext": map[string]any{
				"runAsNonRoot":   true,
				"runAsUser":      10001,
				"seccompProfile": map[string]any{"type": "RuntimeDefault"},
			},
			"containers": []any{map[string]any{
				"name":  "app",
				"image": "registry.example/app:1",
				"securityContext": map[string]any{
					"allowPrivilegeEscalation": false,
					"capabilities":             map[string]any{"drop": []any{"ALL"}},
				},
			}},
		},
	}
}

// inheritBaseWithout is the base pod with one field removed from both levels.
func inheritBaseWithout(podPath, ctrPath []string) map[string]any {
	pod := inheritBasePod()
	spec := pod["spec"].(map[string]any)
	inheritDelete(spec, podPath)
	inheritDelete(inheritFirstContainer(pod), ctrPath)
	return pod
}

// inheritWindowsBase is the hostProcess base. hostProcess is a Windows-only
// field, so the pod declares spec.os.name: windows. runAsUser is dropped
// because a Windows pod expresses its identity through
// windowsOptions.runAsUserName, and hostNetwork is deliberately NOT set even
// though a real HostProcess pod must set it: hostNetwork would move the
// hostNamespaces and hostPorts groups as well and the cell's verdict would no
// longer be attributable to hostProcess.
func inheritWindowsBase() map[string]any {
	pod := inheritBasePod()
	spec := pod["spec"].(map[string]any)
	spec["os"] = map[string]any{"name": "windows"}
	delete(spec["securityContext"].(map[string]any), "runAsUser")
	return pod
}

var inheritFields = []inheritField{
	{
		name:    "runAsNonRoot",
		group:   "runAsNonRoot",
		podPath: []string{"securityContext", "runAsNonRoot"},
		ctrPath: []string{"securityContext", "runAsNonRoot"},
		order:   []string{"unset", "true", "false"},
		values:  map[string]any{"true": true, "false": false},
		base: func() map[string]any {
			return inheritBaseWithout([]string{"securityContext", "runAsNonRoot"}, []string{"securityContext", "runAsNonRoot"})
		},
	},
	{
		name:    "runAsUser",
		group:   "runAsNonRoot", // PSS splits runAsNonRoot and runAsUser; our pack folds both into no-root-containers.
		podPath: []string{"securityContext", "runAsUser"},
		ctrPath: []string{"securityContext", "runAsUser"},
		order:   []string{"unset", "nonroot", "root"},
		values:  map[string]any{"nonroot": 10001, "root": 0},
		base: func() map[string]any {
			return inheritBaseWithout([]string{"securityContext", "runAsUser"}, []string{"securityContext", "runAsUser"})
		},
	},
	{
		name:    "seccompProfile",
		group:   "seccompProfile",
		podPath: []string{"securityContext", "seccompProfile"},
		ctrPath: []string{"securityContext", "seccompProfile"},
		order:   []string{"unset", "runtimedefault", "unconfined"},
		values: map[string]any{
			"runtimedefault": map[string]any{"type": "RuntimeDefault"},
			"unconfined":     map[string]any{"type": "Unconfined"},
		},
		base: func() map[string]any {
			return inheritBaseWithout([]string{"securityContext", "seccompProfile"}, []string{"securityContext", "seccompProfile"})
		},
	},
	{
		name:    "hostProcess",
		group:   "windowsHostProcess",
		podPath: []string{"securityContext", "windowsOptions", "hostProcess"},
		ctrPath: []string{"securityContext", "windowsOptions", "hostProcess"},
		order:   []string{"unset", "false", "true"},
		values:  map[string]any{"false": false, "true": true},
		base:    inheritWindowsBase,
	},
}

// --- cell construction ---------------------------------------------------

func inheritFirstContainer(pod map[string]any) map[string]any {
	return pod["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
}

func inheritSet(root map[string]any, path []string, v any) {
	node := root
	for _, key := range path[:len(path)-1] {
		next, ok := node[key].(map[string]any)
		if !ok {
			next = map[string]any{}
			node[key] = next
		}
		node = next
	}
	node[path[len(path)-1]] = v
}

func inheritDelete(root map[string]any, path []string) {
	node := root
	for _, key := range path[:len(path)-1] {
		next, ok := node[key].(map[string]any)
		if !ok {
			return
		}
		node = next
	}
	delete(node, path[len(path)-1])
	// Drop the container now that it is empty, so an empty map cannot read as
	// "the field is set to something".
	if len(node) == 0 && len(path) > 1 {
		inheritDelete(root, path[:len(path)-1])
	}
}

func inheritProbeName(field, podValue, ctrValue string) string {
	return fmt.Sprintf("probe-inherit-%s-pod-%s-ctr-%s", strings.ToLower(field), podValue, ctrValue)
}

// inheritCellPod builds the cell (podValue, containerValue) for one field.
func inheritCellPod(f inheritField, podValue, ctrValue string) map[string]any {
	pod := f.base()
	pod["metadata"].(map[string]any)["name"] = inheritProbeName(f.name, podValue, ctrValue)
	spec := pod["spec"].(map[string]any)
	if podValue != "unset" {
		inheritSet(spec, f.podPath, f.values[podValue])
	}
	if ctrValue != "unset" {
		inheritSet(inheritFirstContainer(pod), f.ctrPath, f.values[ctrValue])
	}
	return pod
}

// inheritCells is every (field, podValue, containerValue) the matrix covers:
// the full {unset, A, B} x {unset, A, B} square for each field. No cell is
// excluded. Cells Kubernetes would reject structurally (pod and container
// hostProcess disagreeing) are kept deliberately — PSA still returns a verdict
// for them, so they are comparable, and dropping them would be a judgement
// about admissibility made here rather than by the oracle.
func inheritCells() []string {
	var names []string
	for _, f := range inheritFields {
		for _, pv := range f.order {
			for _, cv := range f.order {
				names = append(names, inheritProbeName(f.name, pv, cv))
			}
		}
	}
	sort.Strings(names)
	return names
}

// init registers every matrix cell in the probe set the oracle tier already
// walks. Registering here rather than editing oracleProbePods keeps
// psa_oracle_test.go untouched — it belongs to another worker — while the
// cells are picked up by oracleProbeCases, compared by
// TestPSAOracle_PackAgreesWithPodSecurityAdmission, inverted by
// TestPSAOracleNegative_InvertedCheckIsCaught and name-checked by
// TestPSAOracle_ExceptionsAreWellFormed, with that tier's exception and
// stale-exception discipline unchanged.
// inheritExceptions are the divergences the matrix cells found, each one a
// decision for the pack owner. They are appended to oracleExceptions rather
// than written into psa_oracle_test.go, which belongs to another worker; the
// discipline is untouched — applyExceptions walks the whole slice, so an entry
// here that stops diverging is reported stale and fails exactly like any other.
//
// This is the finding the whole leg was built to produce, and it is the
// opposite of what a transcription of Kubernetes prose would have asserted.
var inheritExceptions = []oracleException{
	// EMPTY, and that is the point. The one entry here recorded a real pack defect:
	// an explicit runAsNonRoot: false at pod level with a container override to true,
	// which the pack passed by effective-value precedence and PSA restricted rejects
	// outright. The lead fixed the pack (an explicit false is now fatal at either
	// level), the divergence disappeared, and the stale rule then REQUIRED this entry
	// to be retired rather than left as dead reasoning. The matrix cell stays
	// registered, so a regression reopens the divergence instead of slipping through.
}

func init() {
	oracleExceptions = append(oracleExceptions, inheritExceptions...)
	for _, f := range inheritFields {
		for _, pv := range f.order {
			for _, cv := range f.order {
				name := inheritProbeName(f.name, pv, cv)
				if _, dup := oracleProbePods[name]; dup {
					panic("inheritance matrix: duplicate probe name " + name)
				}
				raw, err := json.Marshal(inheritCellPod(f, pv, cv))
				if err != nil {
					panic(err)
				}
				oracleProbePods[name] = string(raw)
			}
		}
	}
}

// --- the gates this file does own ---------------------------------------

// TestPSAOracle_InheritanceMatrixIsRegistered proves the cells actually reach
// the comparison. If the init above regressed, the matrix would silently
// contribute nothing and every other tier would stay green.
func TestPSAOracle_InheritanceMatrixIsRegistered(t *testing.T) {
	want := inheritCells()
	if len(want) != 36 {
		t.Fatalf("matrix has %d cells, want 4 fields x 9 = 36", len(want))
	}
	registered := map[string]bool{}
	for _, c := range oracleProbeCases(t) {
		registered[c.name] = true
	}
	for _, name := range want {
		if !registered[name] {
			t.Errorf("matrix cell %q is not a registered probe: it is compared by nothing", name)
		}
	}
}

// TestPSAOracle_InheritanceMatrixIsNotVacuous is the gate that keeps the
// matrix from being 36 copies of one compliant pod. For each field the oracle
// must both ALLOW and REJECT somewhere across its nine cells, and the pack must
// both pass and fail — otherwise the cells vary a field neither side reads and
// the agreement is meaningless.
//
// It asserts no particular cell's verdict, so it cannot pin behaviour: it
// asserts only that the matrix discriminates.
func TestPSAOracle_InheritanceMatrixIsNotVacuous(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}
	p := cisPack(t)

	groupByName := map[string]oracleGroup{}
	for _, g := range oracleGroups {
		groupByName[g.name] = g
	}

	for _, f := range inheritFields {
		f := f
		t.Run(f.name, func(t *testing.T) {
			g, ok := groupByName[f.group]
			if !ok {
				t.Fatalf("field %s names unknown oracle group %q", f.name, f.group)
			}
			var packPass, packFail, psaAllow, psaReject int
			for _, pv := range f.order {
				for _, cv := range f.order {
					obj := oracleRoundTrip(t, inheritCellPod(f, pv, cv))
					pod, err := oracleDecodePod(obj)
					if err != nil {
						t.Fatalf("cell pod=%s ctr=%s is not a decodable Pod: %v", pv, cv, err)
					}
					oracleApplyAPIServerDefaults(pod)

					ours := oracleOurVerdicts(eng, p, obj)
					ourPass := true
					for _, id := range g.ours {
						switch ours[id] {
						case VerdictPass:
						case VerdictFail:
							ourPass = false
						default:
							t.Errorf("cell pod=%s ctr=%s: pack verdict for %q is %s, not comparable "+
								"(the cell is not a clean input)", pv, cv, id, ours[id])
						}
					}
					psaAllowed := true
					var psaDetail []string
					for _, id := range g.psa {
						if strings.HasPrefix(string(id), oracleAPIValidationPrefix) {
							continue
						}
						v := o.check(psapolicy.CheckID(id), pod)
						if v.err != nil {
							t.Fatalf("cell pod=%s ctr=%s: PSA check %q: %v", pv, cv, id, v.err)
						}
						if !v.allowed {
							psaAllowed = false
							psaDetail = append(psaDetail, string(id)+"="+v.detail)
						}
					}
					if ourPass {
						packPass++
					} else {
						packFail++
					}
					if psaAllowed {
						psaAllow++
					} else {
						psaReject++
					}
					t.Logf("pod=%-14s ctr=%-14s pack=%-4s PSA=%-6s %s",
						pv, cv, map[bool]string{true: "pass", false: "fail"}[ourPass],
						map[bool]string{true: "allow", false: "reject"}[psaAllowed],
						strings.Join(psaDetail, "; "))
				}
			}
			if psaAllow == 0 || psaReject == 0 {
				t.Errorf("the oracle gives the same answer to all 9 cells (%d allow / %d reject): the "+
					"matrix varies something PSA does not read, so it anchors nothing",
					psaAllow, psaReject)
			}
			if packPass == 0 || packFail == 0 {
				t.Errorf("the pack gives the same answer to all 9 cells (%d pass / %d fail): the matrix "+
					"varies something the pack does not read", packPass, packFail)
			}
		})
	}
}

// TestPSAOracleNegative_PodOnlyReadIsCaughtByTheMatrix is the injected-defect
// proof for this leg. The realistic defect in a pod/container pair is a check
// that reads only ONE level — the author writes the pod-level rule, the
// container-level override never occurs to them, and no fixture that sets the
// field at container level only is ever written.
//
// Here no-root-containers is replaced IN MEMORY with exactly that defect, and
// the matrix cells must produce a divergence the exception list does not
// excuse. Nothing on disk is touched.
func TestPSAOracleNegative_PodOnlyReadIsCaughtByTheMatrix(t *testing.T) {
	eng, err := NewCELEngine()
	if err != nil {
		t.Fatal(err)
	}
	o, err := newPSAOracle()
	if err != nil {
		t.Fatal(err)
	}

	// Only the matrix cells, so the proof is about these cells and not about
	// coverage the fixtures already provide.
	var cells []oracleCase
	want := map[string]bool{}
	for _, n := range inheritCells() {
		want[n] = true
	}
	for _, c := range oracleProbeCases(t) {
		if want[c.name] {
			cells = append(cells, c)
		}
	}
	if len(cells) != 36 {
		t.Fatalf("collected %d matrix cells, want 36", len(cells))
	}

	real := cisPack(t)
	baseline, _ := oracleScan(t, eng, o, real, cells)
	unexcusedBase, _ := applyExceptions(baseline, oracleExceptions)
	if len(unexcusedBase) != 0 {
		t.Fatalf("the matrix cells already diverge before the injection; the proof would be "+
			"indistinguishable from the pre-existing state: %v", unexcusedBase)
	}

	// The defect: judge root-ness from the pod securityContext alone.
	mutant := &Pack{
		ID: real.ID, Version: real.Version, Status: real.Status, Dir: real.Dir,
		Order: real.Order, Checks: map[string]Check{},
	}
	for id, c := range real.Checks {
		mutant.Checks[id] = c
	}
	const target = "no-root-containers"
	chk, ok := mutant.Checks[target]
	if !ok {
		t.Fatalf("pack has no %q to mutate", target)
	}
	chk.CELExpression = "has(object.spec) && has(object.spec.securityContext) && " +
		"has(object.spec.securityContext.runAsNonRoot) && object.spec.securityContext.runAsNonRoot == true && " +
		"!(has(object.spec.securityContext.runAsUser) && object.spec.securityContext.runAsUser == 0)"
	mutant.Checks[target] = chk

	divs, _ := oracleScan(t, eng, o, mutant, cells)
	unexcused, _ := applyExceptions(divs, oracleExceptions)
	if len(unexcused) == 0 {
		t.Fatalf("a %q that reads only the pod securityContext produced no unexcused divergence over "+
			"the 36 matrix cells: the matrix does not anchor pod/container precedence", target)
	}
	for _, d := range unexcused {
		t.Logf("injected pod-only defect caught: %s", d)
	}
}
