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

# ── spire-agent-swarm-entries: four compounding defects, none of which ever ran
#
# The Job registered the SPIFFE identities for the agent swarm and had never
# once started: `command: ["/bin/sh","-c"]` on the DISTROLESS spire-server
# image. Behind that sat three more — a removed `-registrationUDSPath` flag,
# pointed at the agent's socket directory rather than the server's admin socket,
# from a pod that mounted no server socket at all — and over the top,
# `2>/dev/null || echo "(entry may already exist, continuing)"`, which would
# have printed reassurance over a total failure had it ever executed.
#
# Each assertion below pins one of them.

swarm_manifest() { printf '%s' "$root/d2-signalloom/infra/inf-bao/controllers/base/spire-agent-swarm-entries.yaml"; }

swarm_script() {
	yq -N -r 'select(.kind == "ConfigMap" and .metadata.name == "spire-agent-swarm-entries-config")
	          | .data["register-entries.sh"]' "$(swarm_manifest)"
}

@test "the swarm-entries Job reaches spire-server by kubectl exec, not by running its binary" {
	# Defect 1. The spire-server image is distroless: any `command` that is a
	# shell dies with `exec: "/bin/sh": ... no such file or directory` before a
	# single line of the script runs.
	run yq -N -r 'select(.kind == "Job" and .metadata.name == "spire-agent-swarm-entries-setup")
	              | .spec.template.spec.containers[]
	              | [.image, (.command | join(" "))] | @tsv' "$(swarm_manifest)"
	[ "$status" -eq 0 ]
	row="$(sed '/^[[:space:]]*$/d' <<<"$output")"
	[[ "$row" != *"spiffe/spire-server"* ]]
	[[ "$row" == *"kubectl"* ]]

	# and the script must actually use kubectl exec against the Deployment
	run swarm_script
	[ "$status" -eq 0 ]
	[[ "$output" == *"kubectl -n \"\$NAMESPACE\" exec deployment/spire-server"* ]]
}

@test "no container in the inf-bao controllers slice pins a dead bitnami tag" {
	# docker.io/bitnami removed its versioned tags in 2025, so `bitnami/kubectl:1.31`
	# resolves to NotFound — an ImagePullBackOff, not a network error. Both this
	# Job and the spire-openbao-sync CronJob carried that pin; neither had ever
	# run, so nothing surfaced it.
	#
	# Matches `bitnami/` but not `bitnamilegacy/`, which is the live relocation.
	offenders=""
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		hits="$(grep -nE 'image:[[:space:]]*(docker\.io/)?bitnami/' "$f" || true)"
		[ -n "$hits" ] && offenders="${offenders}${f#"$root"/}: ${hits}"$'\n'
	done < <(find "$root/d2-signalloom/infra/inf-bao" -type f -name '*.yaml' | sort)

	if [ -n "$offenders" ]; then
		echo "dead docker.io/bitnami tag pinned (use bitnamilegacy/):"
		echo "$offenders"
	fi
	[ -z "$offenders" ]
}

@test "the registration script does not use the removed registrationUDSPath flag" {
	# Defects 2 and 3. Exec'ing into the server pod reaches SPIRE's DEFAULT
	# admin socket; naming a socket explicitly is what broke every spire-server
	# CLI call in this repo once already (see spire-trust-anchor.sh).
	run swarm_script
	[ "$status" -eq 0 ]
	script="$output"

	# Comments are stripped before matching, and that is not a convenience.
	# The script explains WHY it does not set the flag, naming it — so a naive
	# grep matches the explanation and reports the defect it was told is
	# absent. The first version of this test failed for exactly that reason.
	# d2-signalloom/test/bats-registry-coverage.bats strips comments for the
	# same reason; a guard that can be satisfied, or tripped, by prose is not
	# reading the code.
	code="$(grep -vE '^[[:space:]]*#' <<<"$script")"

	uds="$(grep -n 'registrationUDSPath' <<<"$code" || true)"
	[ -z "$uds" ]

	sockets="$(grep -n '/run/spire/sockets' <<<"$code" || true)"
	[ -z "$sockets" ]

	# and the Job must mount no socket volume at all
	run yq -N -r 'select(.kind == "Job" and .metadata.name == "spire-agent-swarm-entries-setup")
	              | [.spec.template.spec.volumes[].name] | join(",")' "$(swarm_manifest)"
	[ "$status" -eq 0 ]
	[ "$(sed '/^[[:space:]]*$/d' <<<"$output")" = "register-script" ]
}

@test "the registration script does not swallow errors" {
	# Defect 4, and the one that made the other three survivable-looking. A Job
	# that prints "(entry may already exist, continuing)" over a container that
	# cannot start is the false-green shape this whole slice has been cleared of.
	run swarm_script
	[ "$status" -eq 0 ]
	script="$output"

	swallowed="$(grep -nE '2>/dev/null[[:space:]]*\|\|[[:space:]]*(echo|true)|\|\|[[:space:]]*true[[:space:]]*$' <<<"$script" || true)"
	[ -z "$swallowed" ]

	# errexit must be on, so any unexpected failure fails the Job
	[[ "$script" == *"set -euo pipefail"* ]]
}

@test "the registration script asserts the entries exist afterwards" {
	# The lead assertion: a Job that exits 0 having created nothing is exactly
	# where this started. Verified live by mutation — with the create call
	# replaced by `:`, the Job failed and named the absent SPIFFE ID.
	run swarm_script
	[ "$status" -eq 0 ]
	script="$output"

	[[ "$script" == *"Verifying every entry is present"* ]]
	[[ "$script" == *"entry show"* ]]
	# it must be able to fail: a non-zero exit guarded by the missing set
	[[ "$script" == *"exit 1"* ]]

	verify="$(grep -cE 'missing\+=\(' <<<"$script" || true)"
	[ "$verify" -gt 0 ]
}

# ── grep -q never feeds a pipe ─────────────────────────────────────────────
#
# openbao-fleet-manager-bootstrap asserted its policy with
#
#   bao policy read fleet-manager | grep -q 'revoke-accessor' | grep -q 'lookup-accessor'
#
# `grep -q` writes nothing to stdout, so the second grep always reads an empty
# stream and exits 1. Under `sh -e` the Job therefore failed on every run, with
# a policy that was correct. Checking two strings needs the text read once and
# grepped twice.

# Every shell script an inf-bao manifest carries: ConfigMap data values and the
# last element of each Job container's command+args (the `sh -ec <script>` form).
all_job_scripts() {
	find "$root/d2-signalloom/infra/inf-bao" -name '*.yaml' -print0 | sort -z |
		while IFS= read -r -d '' f; do
			yq -N -r '
				(select(.kind == "ConfigMap") | .data | to_entries[] | .value),
				(select(.kind == "Job" or .kind == "CronJob")
					| (.spec.template.spec // .spec.jobTemplate.spec.template.spec)
					| .containers[] | ((.command // []) + (.args // [])) | .[-1])
			' "$f" 2>/dev/null | sed "s|^|${f#"$root"/}: |"
		done
}

@test "the job-script extraction sees the fleet-manager bootstrap assertions" {
	# Mechanism-presence check for the guard below.
	run all_job_scripts
	[ "$status" -eq 0 ]
	[[ "$output" == *"openbao-fleet-manager-bootstrap.yaml: "*"bao policy read fleet-manager"* ]]
}

@test "no inf-bao job script pipes the silent output of grep -q into another command" {
	run all_job_scripts
	[ "$status" -eq 0 ]
	offenders="$(printf '%s\n' "$output" | rg -e 'grep -q[^|]*\|' || true)"
	if [ -n "$offenders" ]; then
		printf 'grep -q produces no output, so a pipe after it always reads empty:\n%s\n' "$offenders" >&2
		return 1
	fi
}

@test "the fleet-manager bootstrap assertions pass under sh -e against a correct policy" {
	# Run the manifest's own assertion block, verbatim, with a stub `bao` that
	# returns what a correctly bootstrapped OpenBao returns.
	manifest="$root/d2-signalloom/infra/inf-bao/configs/base/openbao-fleet-manager-bootstrap.yaml"
	script="$BATS_TEST_TMPDIR/assert.sh"
	yq -N -r 'select(.kind == "Job") | .spec.template.spec.containers[0].command[-1]' "$manifest" |
		sed -n '/# --- Assert the outcome/,$p' >"$script"
	grep -q 'bao policy read fleet-manager' "$script"

	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/bao" <<'STUB'
#!/bin/sh
case "$*" in
"read -field=bound_subject auth/jwt/role/fleet-manager")
	echo 'spiffe://signalloom.demo/ns/fe-signalloom/sa/fleet-manager' ;;
"policy read fleet-manager")
	printf '%s\n' 'path "auth/token/accessors" { capabilities = ["list"] }' \
		'path "auth/token/lookup-accessor" { capabilities = ["update"] }' \
		'path "auth/token/revoke-accessor" { capabilities = ["update"] }' ;;
*) echo "unexpected bao $*" >&2; exit 2 ;;
esac
STUB
	chmod +x "$BATS_TEST_TMPDIR/bin/bao"

	PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sh -e "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"fleet-manager bootstrap complete"* ]]

	# And it must still fail when the policy lacks a path.
	sed -i '/lookup-accessor/d' "$BATS_TEST_TMPDIR/bin/bao"
	PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sh -e "$script"
	[ "$status" -ne 0 ]
}
