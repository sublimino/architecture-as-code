#!/usr/bin/env bats
#
# Tier 1 for scripts/supercred-state.sh — no cluster, no demo run, no waiting.
#
# The assertions in supercred-state.sh are pure functions over a key=value state
# document, precisely so this file can exist. Every test below states a
# guarantee and then PROVES THE GUARANTEE CAN FAIL by mutating exactly one key
# of an otherwise-passing document and requiring the assertion to go red naming
# that key. An assertion that cannot go red is not coverage, and this repo has
# already shipped several that could not.
#
# The live-cluster counterpart is test/supercred-e2e.bats (tier 2).

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supercred-state.sh"
	clean="$BATS_TEST_TMPDIR/clean.state"
	deployed="$BATS_TEST_TMPDIR/deployed.state"

	cat >"$clean" <<-'STATE'
		k8s.cardvault_deployment=absent
		k8s.policy_engine_deployment=absent
		k8s.cardvault_service=absent
		k8s.policy_engine_service=absent
		k8s.agent_pod=absent
		k8s.agent_pod_namespace=
		k8s.agent_pod_state=
		k8s.agent_pod_phase=
		k8s.agent_sa=absent
		k8s.agent_job=absent
		k8s.bootstrap_job=absent
		bao.kv_secret=absent
		bao.jwt_role=absent
		bao.policy=absent
		spire.reachable=true
		spire.entry=absent
		flux.fe_signalloom_suspended=true
		flux.fe_signalloom_interval=30m
		flux.inf_bao_suspended=true
		flux.inf_bao_interval=30m
	STATE

	cat >"$deployed" <<-'STATE'
		k8s.cardvault_deployment=present
		k8s.policy_engine_deployment=present
		k8s.cardvault_service=present
		k8s.policy_engine_service=present
		k8s.agent_pod=present
		k8s.agent_pod_namespace=fe-signalloom-agents
		k8s.agent_pod_state=active
		k8s.agent_pod_phase=Running
		k8s.agent_sa=present
		k8s.agent_job=absent
		k8s.bootstrap_job=absent
		bao.kv_secret=readable
		bao.jwt_role=present
		bao.policy=present
		spire.reachable=true
		spire.entry=present
		flux.fe_signalloom_suspended=true
		flux.fe_signalloom_interval=30m
		flux.inf_bao_suspended=true
		flux.inf_bao_interval=30m
	STATE
}

# mutate <source-file> <key> <new-value> — emit a copy with one key changed,
# printing the path of the copy so calls compose:
#   s="$(mutate "$clean" a present)"; s="$(mutate "$s" b present)"
#
# Each call gets its OWN output file, from mktemp. A fixed output path looks
# fine until the second call in such a chain, where src and out are the same
# file and the `>` redirect truncates it before awk reads a byte — yielding an
# empty document, which reads as a PASSING assert-clean. That is the exact
# silent false-pass this suite exists to prevent, planted in the test helper.
#
# A counter does not fix it either: every `$(mutate ...)` runs in a command
# substitution subshell, so an incremented counter dies with the subshell and
# the second call reuses name 1. mktemp is the only allocator here that is
# actually subshell-safe. The `-s` guard makes a regression loud rather than
# green.
mutate() {
	local src="$1" key="$2" value="$3"
	local out; out="$(mktemp "$BATS_TEST_TMPDIR/mutated-XXXXXX.state")"
	awk -F= -v k="$key" -v v="$value" \
		'{ if ($1 == k) print k "=" v; else print }' "$src" >"$out"
	[ -s "$out" ] || { echo "mutate produced an empty document" >&2; return 1; }
	printf '%s' "$out"
}

# ─── Baseline: the fixtures pass ────────────────────────────────────────────

@test "assert-clean passes on a genuinely clean state" {
	run "$script" assert-clean "$clean"
	[ "$status" -eq 0 ]
	[[ "$output" == *"state is clean"* ]]
}

@test "assert-deployed passes on a fully deployed state" {
	run "$script" assert-deployed "$deployed"
	[ "$status" -eq 0 ]
	[[ "$output" == *"state is deployed"* ]]
}

@test "assert-clean reads the state document from stdin as well as a file" {
	run bash -c "'$script' assert-clean < '$clean'"
	[ "$status" -eq 0 ]
}

# ─── Proof: assert-clean goes red for every residue class ───────────────────
#
# One test per object the demo creates. Each mutates a single key, so a failure
# names exactly one cause and cannot be satisfied by an unrelated regression.

@test "assert-clean FAILS when the cardvault Deployment survives" {
	run "$script" assert-clean "$(mutate "$clean" k8s.cardvault_deployment present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.cardvault_deployment"* ]]
	[[ "$output" == *"survived teardown"* ]]
}

@test "assert-clean FAILS when the policy-engine Deployment survives" {
	run "$script" assert-clean "$(mutate "$clean" k8s.policy_engine_deployment present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.policy_engine_deployment"* ]]
}

@test "assert-clean FAILS when the cardvault Service survives" {
	run "$script" assert-clean "$(mutate "$clean" k8s.cardvault_service present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.cardvault_service"* ]]
}

@test "assert-clean FAILS when the agent Pod survives" {
	run "$script" assert-clean "$(mutate "$clean" k8s.agent_pod present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.agent_pod"* ]]
}

@test "assert-clean FAILS when the cardvault-agent ServiceAccount survives" {
	# supercred-demo.sh 5 deletes the SA but never verifies the deletion.
	run "$script" assert-clean "$(mutate "$clean" k8s.agent_sa present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.agent_sa"* ]]
}

@test "assert-clean FAILS when the supercred-agent-run Job survives" {
	run "$script" assert-clean "$(mutate "$clean" k8s.agent_job present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.agent_job"* ]]
}

@test "assert-clean FAILS when the OpenBao KV secret survives" {
	# THE mid-run-reset leak: step 1 seeds this secret and only step 4 deletes
	# it, so any reset before step 4 leaves live credential material in the
	# vault. supercred-demo.sh 5 does not look at it, so its teardown reports
	# success in exactly this state.
	run "$script" assert-clean "$(mutate "$clean" bao.kv_secret readable)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
	[[ "$output" == *"reset before step 4 leaks live credentials"* ]]
}

@test "assert-clean FAILS when the OpenBao JWT auth role survives" {
	run "$script" assert-clean "$(mutate "$clean" bao.jwt_role present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.jwt_role"* ]]
}

@test "assert-clean FAILS when the OpenBao policy survives" {
	# Nothing in the demo — not step 4, not step 5 — ever deletes this policy.
	run "$script" assert-clean "$(mutate "$clean" bao.policy present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.policy"* ]]
	[[ "$output" == *"NOTHING in the demo ever deletes this"* ]]
}

@test "assert-clean FAILS when the SPIRE registration entry survives" {
	run "$script" assert-clean "$(mutate "$clean" spire.entry present)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"spire.entry"* ]]
}

@test "assert-clean reports EVERY violation, not just the first" {
	# A teardown that leaked six objects used to be indistinguishable from one
	# that leaked one, which made "is it getting better?" unanswerable.
	local s
	s="$(mutate "$clean" bao.kv_secret readable)"
	s="$(mutate "$s" bao.jwt_role present)"
	s="$(mutate "$s" bao.policy present)"

	run "$script" assert-clean "$s"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
	[[ "$output" == *"bao.jwt_role"* ]]
	[[ "$output" == *"bao.policy"* ]]
}

# ─── Proof: assert-deployed goes red for every missing precondition ─────────

@test "assert-deployed FAILS when the agent Pod was never created" {
	run "$script" assert-deployed "$(mutate "$deployed" k8s.agent_pod absent)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.agent_pod"* ]]
}

@test "assert-deployed FAILS when step 1 seeded no OpenBao secret" {
	run "$script" assert-deployed "$(mutate "$deployed" bao.kv_secret absent)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
}

@test "assert-deployed FAILS when the SPIRE entry was never registered" {
	# The exact state a live probe found the shared cluster in: credentials
	# seeded, workload never registered. Step 1 swallows `entry create`
	# failures with `|| true`, so this state is reachable through a green run.
	run "$script" assert-deployed "$(mutate "$deployed" spire.entry absent)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"spire.entry"* ]]
}

# ─── Proof: per-step postconditions go red ─────────────────────────────────

@test "assert-step 2 FAILS when the agent was never marked active" {
	run "$script" assert-step 2 "$(mutate "$deployed" k8s.agent_pod_state '')"
	[ "$status" -ne 0 ]
	[[ "$output" == *"k8s.agent_pod_state"* ]]
}

@test "assert-step 3 FAILS when the compliance scan did not mark non-compliant" {
	# Passing step 2's state to step 3 must fail: state is 'active', not
	# 'non-compliant'. This is the skip-a-step case.
	run "$script" assert-step 3 "$deployed"
	[ "$status" -ne 0 ]
	[[ "$output" == *"non-compliant"* ]]
}

@test "assert-step 3 passes once the scan has marked the agent non-compliant" {
	run "$script" assert-step 3 "$(mutate "$deployed" k8s.agent_pod_state non-compliant)"
	[ "$status" -eq 0 ]
}

@test "assert-step 4 FAILS when the KV secret was not revoked" {
	# The single most important assertion in the demo: step 4 claims to revoke
	# credentials. If the secret is still readable, the stun did nothing.
	local s
	s="$(mutate "$deployed" k8s.agent_pod_state stunned)"
	s="$(mutate "$s" bao.jwt_role absent)"
	# bao.kv_secret deliberately left readable
	run "$script" assert-step 4 "$s"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
	[[ "$output" == *"must revoke"* ]]
}

@test "assert-step 4 passes on a correctly stunned agent" {
	local s
	s="$(mutate "$deployed" k8s.agent_pod_state stunned)"
	s="$(mutate "$s" bao.kv_secret absent)"
	s="$(mutate "$s" bao.jwt_role absent)"
	run "$script" assert-step 4 "$s"
	[ "$status" -eq 0 ]
}

@test "assert-step 4 accepts a soft-deleted secret as revoked" {
	# `bao kv delete` is a soft delete. The credential is unreadable, which is
	# what step 4 promises, so this must PASS — asserting bao.kv_secret=absent
	# here would demand a hard destroy the demo never claimed to do.
	local s
	s="$(mutate "$deployed" k8s.agent_pod_state stunned)"
	s="$(mutate "$s" bao.kv_secret soft-deleted)"
	s="$(mutate "$s" bao.jwt_role absent)"
	run "$script" assert-step 4 "$s"
	[ "$status" -eq 0 ]
}

@test "assert-clean REJECTS a soft-deleted secret as not clean" {
	# The mirror of the test above, and the distinction the whole three-valued
	# encoding exists for. Soft-deleted is good enough for revocation and NOT
	# good enough for teardown: the version history survives and `bao kv
	# undelete` brings the credential back. A boolean present/absent probe
	# cannot express this, and would call the state clean.
	run "$script" assert-clean "$(mutate "$clean" bao.kv_secret soft-deleted)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
	[[ "$output" == *"SOFT delete"* ]]
}

@test "expect_not treats a missing key as a violation, not a pass" {
	# `expect_not X readable` must not quietly succeed because the probe never
	# emitted X. Absence of evidence is the silent-false-pass shape.
	grep -v '^bao.kv_secret=' "$deployed" >"$BATS_TEST_TMPDIR/nokv.state"
	run "$script" assert-step 4 "$BATS_TEST_TMPDIR/nokv.state"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
}

@test "assert-step 5 is assert-clean" {
	run "$script" assert-step 5 "$clean"
	[ "$status" -eq 0 ]
	run "$script" assert-step 5 "$deployed"
	[ "$status" -ne 0 ]
}

@test "assert-step rejects a step number outside 1..5" {
	run "$script" assert-step 9 "$clean"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown step"* ]]
}

# ─── Proof: Flux durability is a separate verdict ───────────────────────────

@test "assert-stays-clean FAILS while the fe-signalloom Kustomization is live" {
	# agents-cardvault{,-sa,-job}.yaml are members of the Flux-managed
	# fe-signalloom apps Kustomization, so a clean teardown is undone at the
	# next reconcile. "Clean now" and "stays clean" are different questions.
	run "$script" assert-stays-clean "$(mutate "$clean" flux.fe_signalloom_suspended '')"
	[ "$status" -ne 0 ]
	[[ "$output" == *"flux.fe_signalloom_suspended"* ]]
	[[ "$output" == *"re-create agent-cardvault"* ]]
}

@test "assert-stays-clean passes when the Kustomization is suspended" {
	run "$script" assert-stays-clean "$clean"
	[ "$status" -eq 0 ]
}

# ─── Proof: the harness refuses to pass on absent input ─────────────────────

@test "an empty state document is a hard failure, never a silent pass" {
	# The failure mode this whole file is defending against: a check that
	# reports success because it had nothing to check. If the probe dies, every
	# assertion downstream of it must go red, not green.
	: >"$BATS_TEST_TMPDIR/empty.state"
	run "$script" assert-clean "$BATS_TEST_TMPDIR/empty.state"
	[ "$status" -ne 0 ]
	[[ "$output" == *"probe produced nothing"* ]]
}

@test "a probe that emits only comments is also a hard failure" {
	printf '# probe failed to reach the cluster\n' >"$BATS_TEST_TMPDIR/comments.state"
	run "$script" assert-clean "$BATS_TEST_TMPDIR/comments.state"
	[ "$status" -ne 0 ]
	[[ "$output" == *"probe produced nothing"* ]]
}

@test "a state document missing a key fails rather than skipping the check" {
	# Dropping a key must not silently remove its assertion — that is how a
	# check quietly stops running.
	grep -v '^bao.kv_secret=' "$clean" >"$BATS_TEST_TMPDIR/partial.state"
	run "$script" assert-clean "$BATS_TEST_TMPDIR/partial.state"
	[ "$status" -ne 0 ]
	[[ "$output" == *"bao.kv_secret"* ]]
	[[ "$output" == *"<unset>"* ]]
}

# ─── Proof: the Flux re-seed race is detectable ────────────────────────────

@test "assert-no-reseed FAILS while inf-bao reconciliation is live" {
	# The highest-severity finding this harness produced. inf-bao/infra-configs
	# recreates openbao-supercred-bootstrap on every reconcile (force: "true"),
	# and that Job re-writes the policy, JWT role and KV secret that step 4 has
	# just revoked — so the stun silently un-does itself and the agent
	# authenticates successfully right after being "revoked". Observed live: the
	# reconcile went Ready at 16:23:58Z and step 4 failed in the same second.
	run "$script" assert-no-reseed "$(mutate "$clean" flux.inf_bao_suspended '')"
	[ "$status" -ne 0 ]
	[[ "$output" == *"flux.inf_bao_suspended"* ]]
	[[ "$output" == *"openbao-supercred-bootstrap"* ]]
	# The message must carry the mitigation, not just the diagnosis.
	[[ "$output" == *"suspend"* ]]
}

@test "assert-no-reseed passes once inf-bao is suspended" {
	run "$script" assert-no-reseed "$clean"
	[ "$status" -eq 0 ]
}

@test "assert-no-reseed FAILS when the probe never reported inf-bao at all" {
	grep -v '^flux.inf_bao_suspended=' "$clean" >"$BATS_TEST_TMPDIR/nobao.state"
	run "$script" assert-no-reseed "$BATS_TEST_TMPDIR/nobao.state"
	[ "$status" -ne 0 ]
	[[ "$output" == *"flux.inf_bao_suspended"* ]]
}
