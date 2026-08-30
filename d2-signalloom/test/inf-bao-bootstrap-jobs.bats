#!/usr/bin/env bats
#
# The inf-bao bootstrap Jobs must be able to run at all.
#
# ── The defect this pins ───────────────────────────────────────────────────
#
# `bao write <path> k=v` sends every value as a STRING. bound_claims and
# claim_mappings on a JWT auth role are MAP-typed, so the k=v form is rejected
# by the server:
#
#   Code: 400. Errors:
#   * error converting input {"sub":"spiffe://signalloom.demo/ns/*/sa/*"}
#     for field "bound_claims": '' expected a map, got 'string'
#
# The value in the manifest was valid JSON and the quoting was correct, which is
# exactly why it survived review — the CLI simply never parses a k=v operand as
# anything but a string. `bao write <path> -` reads a JSON object from stdin and
# preserves types.
#
# ── Why it went unnoticed for so long ──────────────────────────────────────
#
# openbao-agent-generic-role-setup had NEVER succeeded. It failed on this line
# on every run since it was authored, went to BackoffLimitExceeded, and held
# inf-bao/infra-controllers not-Ready through its health check — which blocked
# inf-bao/infra-configs on dependsOn, and the agent-trust ResourceSet behind
# that. Three things hid it:
#
#   1. the policy write on the preceding line succeeds, so the log opens with
#      "Success! Uploaded policy" and reads healthy at a glance;
#   2. a SECOND, unrelated defect in the same slice — a privilege-escalation
#      deadlock on a RoleBinding — aborted the whole change set before these
#      Jobs were ever applied, so the Kustomization's error named that instead.
#      Fixing the first error only revealed this one;
#   3. `kubectl get job` reports "Failed" with `error: timed out waiting for the
#      condition`, which names the timeout and not the 400.
#
# Verified live 2026-08-30: with the stdin form the Job reaches Complete 1/1 and
# `bao read auth/jwt/role/signalloom-agent-generic` returns bound_claims and
# claim_mappings as maps rather than strings.

setup() {
	root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	base="$root/d2-signalloom/infra/inf-bao/controllers/base"
	generic="$base/openbao-agent-generic-role.yaml"
}

# The shell script a Job's ConfigMap carries, extracted the way the Job runs it.
job_script() { # manifest
	yq -N -r 'select(.kind == "ConfigMap") | .data | to_entries[] | .value' "$1" \
		| sed '/^[[:space:]]*$/d'
}

@test "the generic-role manifest still ships a script for this suite to read" {
	# Mechanism-presence check. Every assertion below greps this text; if the
	# extraction silently returns nothing, they all pass over an empty string.
	run job_script "$generic"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" == *"auth/jwt/role/signalloom-agent-generic"* ]]
}

@test "the extracted bootstrap script is valid shell" {
	# It is embedded in a YAML block scalar and piped into sh at runtime, so a
	# quoting or heredoc-indentation mistake is invisible until the Job runs.
	# The heredoc terminator in particular must land at column 0 AFTER yaml
	# strips the block-scalar indent, which is not obvious from reading the
	# manifest.
	script="$BATS_TEST_TMPDIR/generic.sh"
	job_script "$generic" >"$script"
	[ -s "$script" ]

	# `bash -n` is NOT enough on its own, and the mutation harness proved it:
	# indenting the heredoc terminator makes the here-document run to EOF, and
	# bash reports that as a WARNING ON STDERR while still EXITING 0 —
	#
	#   warning: here-document at line 39 delimited by end-of-file (wanted `ROLE')
	#   rc=0
	#
	# so a status-only assertion stayed green through exactly the defect this
	# test exists to catch. That matters here more than it would elsewhere:
	# the terminator's column is decided by YAML block-scalar indent stripping,
	# which is invisible when reading the manifest, so this is the single most
	# likely way to break the script while it still looks correct.
	#
	# Both channels are therefore checked: a clean parse means exit 0 AND
	# nothing on stderr.
	run bash -n "$script"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "map-typed OpenBao role fields are not passed as k=v operands" {
	# The actual regression. `bound_claims={...}` and `claim_mappings={...}` as
	# arguments are rejected with a 400; they have to arrive as JSON on stdin.
	#
	# Collected into a variable and asserted with a positive test. A bare
	# `! grep ...` as the last statement of a bats body is exempt from errexit
	# and can never fail — this repo has been bitten by that.
	script="$BATS_TEST_TMPDIR/generic.sh"
	job_script "$generic" >"$script"

	offenders="$(grep -nE '^[[:space:]]*(bound_claims|claim_mappings)=' "$script" || true)"
	if [ -n "$offenders" ]; then
		echo "map-typed field passed as a k=v operand to 'bao write':"
		echo "$offenders"
		echo "The CLI sends k=v values as strings, so the server rejects these with"
		echo "  error converting input ... expected a map, got 'string'"
		echo "Pass the whole payload as JSON on stdin: bao write <path> - <<'EOF'"
	fi
	[ -z "$offenders" ]
}

@test "the role write feeds its payload from stdin" {
	# The positive half. Absence of the k=v form is also satisfied by deleting
	# the write altogether, which would leave the sidecars with no role at all —
	# quieter than a failing Job, and worse.
	script="$BATS_TEST_TMPDIR/generic.sh"
	job_script "$generic" >"$script"

	stdin_form="$(grep -cE "bao write auth/jwt/role/signalloom-agent-generic[[:space:]]+-[[:space:]]*<<" "$script" || true)"
	[ "$stdin_form" -eq 1 ]

	# and the payload still carries the fields that motivated the change
	for field in bound_claims claim_mappings bound_audiences user_claim token_policies; do
		n="$(grep -cF "\"$field\"" "$script" || true)"
		[ "$n" -gt 0 ]
	done
}

@test "the generic role the sidecars bind is the one this Job creates" {
	# RBAC and auth-role names drift independently of the configs that use them,
	# and nothing at runtime reports a mismatch except a login failure. The
	# sidecar config is the consumer of record.
	sidecar="$root/d2-signalloom/infra/agent-swarm/openbao-agent-sidecar.yaml"
	[ -f "$sidecar" ]

	# Whitespace around `=` varies between these configs, so the pattern is
	# tolerant of it. Counts are captured into variables rather than asserted
	# through `run grep -c`: grep exits 1 on zero matches, so `[ "$status" -eq
	# 0 ]` fails for the same reason the count would — two different faults
	# reported as one, and the message names neither.
	bound="$(grep -cE 'role[[:space:]]*=[[:space:]]*"signalloom-agent-generic"' "$sidecar" || true)"
	[ "$bound" -gt 0 ]

	script="$BATS_TEST_TMPDIR/generic.sh"
	job_script "$generic" >"$script"
	created="$(grep -cF 'auth/jwt/role/signalloom-agent-generic' "$script" || true)"
	[ "$created" -gt 0 ]
}
