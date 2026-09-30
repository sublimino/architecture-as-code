#!/usr/bin/env bats
#
# SLDC-P5-PRE: the operational preflight oracle must pass each Appendix F.4
# gate (PF-1..PF-6) only when the thing the gate protects is actually true,
# and fail loudly, by name, when it is broken. Tier 1: fixture repo and a
# fake kubectl, no cluster. The final test is tier 2 and only runs with
# P5_LIVE=1 against kind-osramp (read-only).
#
# Every "passes" test has a sibling mutation test that breaks exactly one
# fact and must fail (Shared Pattern 6: no vacuous greens).

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/verify-operational-gates.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	export P5_SKIP_CLUSTER=1
	export P5_FORENSIC_DIR="$BATS_TEST_TMPDIR/forensics"
	make_fixture_repo
}

# A repo in which every static half of PF-2..PF-6 holds.
make_fixture_repo() {
	fx="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$fx/d2-signalloom/infra/inf-bao/configs/base" "$fx/d2-agent-trust/policies" \
		"$fx/d2-signalloom/apps/signalloom-stun-sentinel" "$fx/d2-signalloom/apps/stun-sentinel/pkg/filter" \
		"$fx/d2-signalloom/apps/stun-sentinel/pkg/correlator" "$fx/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel" \
		"$fx/d2-signalloom/apps/kusari-agent" "$fx/d2-signalloom/infra/spire" "$fx/test"
	cat >"$fx/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml" <<'EOF'
              bao write auth/jwt/role/signalloom-cardvault-agent - <<'ROLE'
              {
                "role_type": "jwt",
                "bound_claims": {"sub": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/*cardvault*"},
                "bound_claims_type": "glob",
                "user_claim": "sub"
              }
              ROLE
EOF
	cat >"$fx/d2-agent-trust/policies/agent-identity-state-protection.yaml" <<'EOF'
  variables:
    - name: isGovernorOrAdmin
      expression: >-
        request.userInfo.username == 'system:serviceaccount:fe-signalloom:swarm-governor' ||
        request.userInfo.username == 'system:serviceaccount:fe-signalloom:supercred-demo-runner'
    - name: wasStunned
      expression: "false"
EOF
	cat >"$fx/d2-signalloom/apps/signalloom-stun-sentinel/main.go" <<'EOF'
func (r *stunReconciler) reconcile(pod *corev1.Pod) error {
	if pod.Status.Phase != corev1.PodRunning {
		return nil
	}
	return r.freezer.freeze(path)
}
EOF
	cat >"$fx/d2-signalloom/apps/stun-sentinel/pkg/filter/exclusion.go" <<'EOF'
func (f *Filter) CheckFreezable(pod *corev1.Pod) error {
	if pod.Status.Phase != corev1.PodRunning {
		return ErrNotRunning
	}
	return nil
}
EOF
	cat >"$fx/d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go" <<'EOF'
func (fm *freezeManager) FreezePod(pod *corev1.Pod) error {
	if err := filter.Default().CheckFreezable(pod); err != nil {
		return err
	}
	_, err := fm.freezer.FreezePod(string(pod.UID), "in-sentinel-governance")
	return err
}
EOF
	cat >"$fx/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go" <<'EOF'
func (s *server) exclusionGate(w http.ResponseWriter, podUID, podName, namespace, phase string) bool {
	if err := f.CheckFreezable(target); err != nil {
		return false
	}
	return true
}
EOF
	cat >"$fx/d2-signalloom/apps/kusari-agent/main.go" <<'EOF'
	mux.HandleFunc("/act/healthz", handleActHealthz)
	mux.HandleFunc("/act/read-passwd", a.handleReadPasswd)
	mux.HandleFunc("/act/cpu-burn", a.handleCPUBurn)
EOF
	cat >"$fx/d2-signalloom/infra/spire/register-entries.yaml" <<'EOF'
kind: Job
metadata:
  name: spire-register-entries
EOF
	cat >"$fx/test/swarm-fleet-acceptance.bats" <<'EOF'
  run kubectl get daemonset stun-sentinel -n "$NAMESPACE"
EOF
	git -C "$fx" init -q
	git -C "$fx" add -A
	git -C "$fx" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture
	export P5_REPO="$fx"
}

static_gates() { "$script" --gate PF-2 --gate PF-3 --gate PF-4 --gate PF-5 --gate PF-6 "$@"; }

# Fake kubectl for live halves. Behaviour is steered by env:
#   FK_STUNNED   value of signalloom.io/stunned on every swarm target ("" = absent)
#   FK_BCT       bound_claims_type returned by `bao read`
fake_kubectl() {
	cat >"$bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
args="$*"
ann() { [[ -n "$FK_STUNNED" ]] && printf '{"signalloom.io/stunned":"%s"}' "$FK_STUNNED" || printf '{}'; }
case "$args" in
*"version"*) [[ "${FK_DOWN:-0}" == 1 ]] && exit 1; exit 0 ;;
*"get deploy agent-sir-lancelot"*) exit 1 ;;
*"get deploy agent-"*) printf '{"kind":"Deployment","metadata":{"annotations":%s},"spec":{"template":{"metadata":{}}}}\n' "$(ann)" ;;
*"get pod agent-sir-lancelot"*) printf '{"kind":"Pod","metadata":{"annotations":%s}}\n' "$(ann)" ;;
*"get job openbao-supercred-bootstrap"*) printf 'fake-token' ;;
*"exec -i deploy/openbao"*) cat >/dev/null; printf '{"data":{"bound_claims_type":"%s"}}\n' "$FK_BCT" ;;
*) exit 1 ;;
esac
FAKE
	chmod +x "$bin/kubectl"
	export KUBECTL="$bin/kubectl" P5_SKIP_CLUSTER=0
}

# ------------------------------------------------------------------ contract

@test "all static gates pass on a conforming repo (exit 0)" {
	run static_gates --quiet
	[ "$status" -eq 0 ]
}

@test "unknown gate is a usage error (exit 2)" {
	run "$script" --gate PF-9
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown gate: PF-9"* ]]
}

@test "JSON report carries schema, six-gate slots and a verdict" {
	run static_gates --quiet --out "$BATS_TEST_TMPDIR/a.json"
	[ "$status" -eq 0 ]
	run jq -e '.schema=="sldc-p5-preflight/v1" and .card=="SLDC-P5-PRE" and .verdict.pass==true and (.gates|length)==5 and .cluster_probed==false' "$BATS_TEST_TMPDIR/a.json"
	[ "$status" -eq 0 ]
}

# ------------------------------------------------------------------ PF-3 (required mutation)

@test "PF-3 MUTATION: bound_claims_type=string fails with the named message" {
	sed -i 's/"bound_claims_type": "glob"/"bound_claims_type": "string"/' \
		"$fx/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
	run "$script" --gate PF-3
	[ "$status" -eq 1 ]
	[[ "$output" == *"PF-3 FAILED: OpenBao bound_claims_type is not glob"* ]]
	[[ "$output" == *"static=string"* ]]
}

@test "PF-3 MUTATION: removing bound_claims_type fails" {
	sed -i '/bound_claims_type/d' "$fx/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
	run "$script" --gate PF-3
	[ "$status" -eq 1 ]
	[[ "$output" == *"static=absent"* ]]
}

@test "PF-3 live: role reading string fails even when the repo says glob" {
	fake_kubectl
	FK_BCT=string run "$script" --gate PF-3
	[ "$status" -eq 1 ]
	[[ "$output" == *"static=glob live=string"* ]]
}

@test "PF-3 live: role reading glob passes" {
	fake_kubectl
	FK_BCT=glob run "$script" --gate PF-3
	[ "$status" -eq 0 ]
}

# ------------------------------------------------------------------ PF-1

@test "PF-1 live: every target annotated stunned=true passes (bare Pod included)" {
	fake_kubectl
	FK_STUNNED=true run "$script" --gate PF-1 --out "$BATS_TEST_TMPDIR/p1.json"
	[ "$status" -eq 0 ]
	run jq -r '.gates[0].live.targets[] | select(.target=="agent-sir-lancelot") | .kind' "$BATS_TEST_TMPDIR/p1.json"
	[ "$output" = "Pod" ]
}

@test "PF-1 MUTATION: missing annotation fails and names the targets" {
	fake_kubectl
	FK_STUNNED="" run "$script" --gate PF-1
	[ "$status" -eq 1 ]
	[[ "$output" == *"PF-1 FAILED"*"agent-cardvault"*"agent-sir-lancelot"*"agent-nono-evidenced"* ]]
}

@test "PF-1 MUTATION: annotation value other than \"true\" fails" {
	fake_kubectl
	FK_STUNNED=false run "$script" --gate PF-1
	[ "$status" -eq 1 ]
}

@test "PF-1 is skipped, not passed, without a cluster" {
	run "$script" --gate PF-1 --out "$BATS_TEST_TMPDIR/s.json"
	[ "$status" -eq 0 ]
	run jq -r '.gates[0].status' "$BATS_TEST_TMPDIR/s.json"
	[ "$output" = "skip" ]
}

# ------------------------------------------------------------------ PF-2

@test "PF-2 MUTATION: no spire-register-entries manifest fails" {
	git -C "$fx" rm -q d2-signalloom/infra/spire/register-entries.yaml
	run "$script" --gate PF-2
	[ "$status" -eq 1 ]
	[[ "$output" == *"PF-2 FAILED: no spire-register-entries Job manifest"* ]]
}

# ------------------------------------------------------------------ PF-4

@test "PF-4 MUTATION: runner SA removed from isGovernorOrAdmin fails" {
	sed -i '/supercred-demo-runner/d' "$fx/d2-agent-trust/policies/agent-identity-state-protection.yaml"
	run "$script" --gate PF-4
	[ "$status" -eq 1 ]
	[[ "$output" == *"PF-4 FAILED"* ]]
}

@test "PF-4 MUTATION: runner SA in a different variable does not count" {
	sed -i '/supercred-demo-runner/d' "$fx/d2-agent-trust/policies/agent-identity-state-protection.yaml"
	sed -i "s/expression: \"false\"/expression: \"request.userInfo.username == 'system:serviceaccount:fe-signalloom:supercred-demo-runner'\"/" \
		"$fx/d2-agent-trust/policies/agent-identity-state-protection.yaml"
	run "$script" --gate PF-4
	[ "$status" -eq 1 ]
}

# ------------------------------------------------------------------ PF-5

@test "PF-5 MUTATION: legacy reconciler without PodRunning check fails" {
	sed -i 's/pod.Status.Phase != corev1.PodRunning/pod.Status.Phase == corev1.PodFailed/' \
		"$fx/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
	run "$script" --gate PF-5
	[ "$status" -eq 1 ]
	[[ "$output" == *"legacy reconciler"* ]]
}

@test "PF-5 MUTATION: HTTP gate with optional phase fails" {
	sed -i 's/if err := f.CheckFreezable(target); err != nil {/if phase != "" {\n\t\tf.CheckFreezable(target)/' \
		"$fx/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go"
	run "$script" --gate PF-5
	[ "$status" -eq 1 ]
	[[ "$output" == *"HTTP /stun gate skips the phase check"* ]]
}

@test "PF-5 MUTATION: correlator freezing before CheckFreezable fails" {
	cat >"$fx/d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go" <<'EOF'
func (fm *freezeManager) FreezePod(pod *corev1.Pod) error {
	_, err := fm.freezer.FreezePod(string(pod.UID), "in-sentinel-governance")
	return filter.Default().CheckFreezable(pod)
}
EOF
	run "$script" --gate PF-5
	[ "$status" -eq 1 ]
	[[ "$output" == *"eBPF correlator freeze not preceded by CheckFreezable"* ]]
}

@test "PF-5 MUTATION: CheckFreezable without a phase check fails" {
	sed -i '/PodRunning/,+2d' "$fx/d2-signalloom/apps/stun-sentinel/pkg/filter/exclusion.go"
	run "$script" --gate PF-5
	[ "$status" -eq 1 ]
	[[ "$output" == *"CheckFreezable has no PodRunning check"* ]]
}

# ------------------------------------------------------------------ PF-6

@test "PF-6 MUTATION: legacy DaemonSet name fails" {
	sed -i 's/daemonset stun-sentinel/daemonset signalloom-stun-sentinel/' "$fx/test/swarm-fleet-acceptance.bats"
	run "$script" --gate PF-6
	[ "$status" -eq 1 ]
	[[ "$output" == *"PF-6 FAILED"*"legacy signalloom-stun-sentinel 1 times"* ]]
}

@test "PF-6 MUTATION: a stray legacy reference alongside the new name still fails" {
	printf '  # signalloom-stun-sentinel\n' >>"$fx/test/swarm-fleet-acceptance.bats"
	run "$script" --gate PF-6
	[ "$status" -eq 1 ]
}

# ------------------------------------------------------------------ auxiliary

@test "AUX-ACT passes when all three /act routes are registered (static)" {
	run "$script" --gate AUX-ACT
	[ "$status" -eq 0 ]
}

@test "AUX-ACT MUTATION: missing /act/cpu-burn route fails" {
	sed -i '/cpu-burn/d' "$fx/d2-signalloom/apps/kusari-agent/main.go"
	run "$script" --gate AUX-ACT
	[ "$status" -eq 1 ]
	[[ "$output" == *"/act/cpu-burn not registered"* ]]
}

@test "AUX-FORENSIC passes on a writable dir and fails when free space is below the floor" {
	run "$script" --gate AUX-FORENSIC
	[ "$status" -eq 0 ]
	P5_FORENSIC_MIN_KB=999999999999 run "$script" --gate AUX-FORENSIC
	[ "$status" -eq 1 ]
}

@test "the preflight never writes into the repo it audits" {
	before="$(git -C "$fx" status --porcelain)"
	run "$script" --out "$BATS_TEST_TMPDIR/full.json"
	[ "$(git -C "$fx" status --porcelain)" = "$before" ]
}

@test "an unreachable cluster is not reported as probed, and its live halves fail" {
	fake_kubectl
	export FK_DOWN=1 FK_STUNNED=true FK_BCT=glob
	run "$script" --quiet --out "$BATS_TEST_TMPDIR/down.json"
	[ "$status" -ne 0 ]
	run jq -e '.cluster_probed==false and .verdict.pass==false' "$BATS_TEST_TMPDIR/down.json"
	[ "$status" -eq 0 ]
}

# ------------------------------------------------------------------ tier 2 (live, read-only)

@test "live: kind-osramp audit produces a well-formed report with all ten checks" {
	[[ "${P5_LIVE:-0}" == 1 ]] || skip "set P5_LIVE=1 to probe kind-osramp (read-only)"
	unset P5_REPO KUBECTL
	export P5_SKIP_CLUSTER=0
	run "$script" --quiet --out "$BATS_TEST_TMPDIR/live.json"
	run jq -e '(.gates|length)==6 and (.auxiliary|length)==4 and .cluster_probed==true' "$BATS_TEST_TMPDIR/live.json"
	[ "$status" -eq 0 ]
}
