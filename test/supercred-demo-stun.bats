#!/usr/bin/env bats
#
# Step 4 is the SuperCred demo's whole point: a superadmin revokes a running
# agent's credentials and the agent is proven unable to act. Everything here
# guards the gap between "the script ran some delete commands" and "revocation
# is evidenced", because on 2026-08-13 the dashboard's Instructor Controls
# printed this and nothing else:
#
#   Success! Data deleted (if it existed) at: kv/data/signalloom/cardvault-agent
#   Success! Data deleted (if it existed) at: auth/jwt/role/signalloom-cardvault-agent
#   ...
#   [supercred] confirmed: agent cannot acquire credentials (expected failure)
#   [supercred] ✓ step 4 complete — agent stunned, credentials revoked
#
# "(if it existed)" is OpenBao's output for a delete of something that may never
# have been there, both deletes ran under `2>/dev/null || true`, and the log
# line that was supposed to show the denial printed nothing at all. Three
# separate claims, none of them evidenced.

setup() {
	script="$BATS_TEST_DIRNAME/../scripts/supercred-demo.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"

	export AGENT_LOG_FILE="$BATS_TEST_TMPDIR/agent.log"
	: >"$AGENT_LOG_FILE"
	export AGENT_PREVIOUS_LOG_FILE="$BATS_TEST_TMPDIR/agent-previous.log"
	: >"$AGENT_PREVIOUS_LOG_FILE"

	# Defaults describe a correct, fully-revoked run. Each test perturbs one
	# thing, so a failure names the property that broke.
	export AGENT_STATE="active"
	export BAO_KV_DELETE_STATUS=0
	export BAO_ROLE_DELETE_STATUS=0
	export BAO_KV_GET_MODE="soft_deleted"
	export BAO_ROLE_READ_MODE="absent"
	export JOB_POD_NAME="supercred-agent-run-abc12"
	export JOB_CONDITION="Failed"
	export SUPERCRED_STUN_EVIDENCE_TIMEOUT=6

	cat >"$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Deliberately no `set -e`: this stub emulates commands that fail on purpose.

argv="$*"

bao_kv_get_soft_deleted() {
	cat <<'JSON'
{
  "data": {
    "data": null,
    "metadata": {
      "created_time": "2026-08-13T00:01:56.269896383Z",
      "deletion_time": "2026-08-13T00:02:08.818103270Z",
      "destroyed": false,
      "version": 3
    }
  }
}
JSON
}

bao_kv_get_live() {
	cat <<'JSON'
{
  "data": {
    "data": {"password": "supercred-demo-password-2026", "username": "cardvault-svc-account"},
    "metadata": {
      "created_time": "2026-08-13T00:01:56.269896383Z",
      "deletion_time": "",
      "destroyed": false,
      "version": 3
    }
  }
}
JSON
}

case "$argv" in
	# ─── OpenBao ────────────────────────────────────────────────────────────
	*"bao kv delete kv/signalloom/cardvault-agent")
		if [ "${BAO_KV_DELETE_STATUS:-0}" -ne 0 ]; then
			printf 'Error deleting kv/data/signalloom/cardvault-agent: Error making API request.\n' >&2
			printf 'command terminated with exit code %s\n' "$BAO_KV_DELETE_STATUS" >&2
			exit "$BAO_KV_DELETE_STATUS"
		fi
		echo "Success! Data deleted (if it existed) at: kv/data/signalloom/cardvault-agent"
		;;
	*"bao delete auth/jwt/role/signalloom-cardvault-agent")
		if [ "${BAO_ROLE_DELETE_STATUS:-0}" -ne 0 ]; then
			printf 'Error deleting auth/jwt/role/signalloom-cardvault-agent: permission denied\n' >&2
			printf 'command terminated with exit code %s\n' "$BAO_ROLE_DELETE_STATUS" >&2
			exit "$BAO_ROLE_DELETE_STATUS"
		fi
		echo "Success! Data deleted (if it existed) at: auth/jwt/role/signalloom-cardvault-agent"
		;;
	*"bao kv get -format=json kv/signalloom/cardvault-agent")
		case "${BAO_KV_GET_MODE}" in
			soft_deleted) bao_kv_get_soft_deleted ;;
			live)         bao_kv_get_live ;;
			absent)
				printf 'No value found at kv/data/signalloom/cardvault-agent\n' >&2
				printf 'command terminated with exit code 2\n' >&2
				exit 2 ;;
			unreadable)
				printf 'not json at all\n'
				exit 0 ;;
			unreachable)
				printf 'Error from server: dial tcp 127.0.0.1:8200: connect: connection refused\n' >&2
				exit 1 ;;
		esac
		;;
	*"bao read auth/jwt/role/signalloom-cardvault-agent")
		if [ "${BAO_ROLE_READ_MODE}" = "present" ]; then
			printf 'Key                Value\n---                -----\nbound_subject      spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent\n'
			exit 0
		fi
		printf 'No value found at auth/jwt/role/signalloom-cardvault-agent\n' >&2
		printf 'command terminated with exit code 2\n' >&2
		exit 2
		;;

	# ─── Agent pod / job ────────────────────────────────────────────────────
	*"get pod agent-cardvault -o jsonpath="*)
		printf '%s' "$AGENT_STATE" ;;
	*"get pod agent-cardvault")
		# resolve_agent_pod_namespace: only fe-signalloom-agents holds it.
		case "$argv" in *"-n fe-signalloom-agents "*|*"-n fe-signalloom-agents") exit 0 ;; esac
		exit 1 ;;
	*"get pods -l job-name=supercred-agent-run"*)
		printf '%s' "${JOB_POD_NAME}"
		[ -n "${JOB_POD_NAME}" ] || exit 1 ;;
	*"logs "*"--all-containers"*"--previous"*)
		[ -s "$AGENT_PREVIOUS_LOG_FILE" ] || exit 1
		cat "$AGENT_PREVIOUS_LOG_FILE" ;;
	*"logs "*"--all-containers"*)
		[ -s "$AGENT_LOG_FILE" ] || exit 1
		cat "$AGENT_LOG_FILE" ;;
	*"get job supercred-agent-run"*)
		case "$argv" in
			*"@.type=='Complete'"*) [ "$JOB_CONDITION" = "Complete" ] && printf 'True' ;;
			*"@.type=='Failed'"*)   [ "$JOB_CONDITION" = "Failed" ] && printf 'True' ;;
		esac
		exit 0 ;;
	*"label pod agent-cardvault"*)    echo "pod/agent-cardvault labeled" ;;
	*"annotate pod agent-cardvault"*) echo "pod/agent-cardvault annotated" ;;
	*"delete job supercred-agent-run"*) : ;;
	"apply -f "*)                     echo "job.batch/supercred-agent-run created" ;;
	*)
		printf 'kubectl stub received unexpected argv: %s\n' "$argv" >&2
		exit 97 ;;
esac
exit 0
STUB

	# supercred-images.sh talks to the node through $DOCKER_BIN; a table with
	# every image present keeps preflight_images out of the way of these tests.
	cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'IMAGE TAG IMAGE-ID SIZE\n'
for i in cardvault policy-engine cardvault-agent supercred-demo-runner; do
	printf 'docker.io/library/%s local abc123 10MB\n' "$i"
done
exit 0
STUB

	chmod +x "$bin/kubectl" "$bin/docker"
	export PATH="$bin:$PATH"
	export DOCKER_BIN="$bin/docker"
}

# The output an agent produces when its credentials really have been revoked:
# SPIFFE still works (the workload identity is intact), the OpenBao exchange
# does not (the authorisation is gone). That distinction is the demo.
write_revoked_agent_log() {
	cat >"$AGENT_LOG_FILE" <<'LOG'
[step-1] SPIFFE identity acquired: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent
[step-2] FAILED: OpenBao login returned 400: {"errors":["role \"signalloom-cardvault-agent\" could not be found"]}
LOG
}

run_step4() {
	run bash -c "PATH='$PATH' DOCKER_BIN='$DOCKER_BIN' '$script' 4 2>&1"
}

@test "truncated image listing warns and continues through the preflight caller" {
	# Exit 3 from supercred-images.sh is deliberately not a preflight failure: the
	# node listing cannot prove absence. Exercise the caller, rather than only the
	# verifier, because an undefined warning helper aborts under set -e here.
	cat >"$bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'IMAGE TAG IMAGE-ID SIZE\n'
printf 'docker.io/library/larger-image local abc123 1GB\n'
printf 'node.status.images is at the kubelet cap\n' >&2
STUB
	chmod +x "$bin/docker"
	write_revoked_agent_log

	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"COULD NOT BE VERIFIED (truncated node listing)"* ]]
	[[ "$output" == *"step 4 complete — agent stunned"* ]]
	[[ "$output" != *"warn: command not found"* ]]
}

@test "preflight fallback documentation matches SuperCred image pull policies" {
	local images_script="$BATS_TEST_DIRNAME/../scripts/supercred-images.sh"
	local manifest
	local manifests=(
		"$BATS_TEST_DIRNAME/../d2-signalloom/apps/cardvault/base/deployment.yaml"
		"$BATS_TEST_DIRNAME/../d2-signalloom/apps/policy-engine/base/deployment.yaml"
		"$BATS_TEST_DIRNAME/../d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml"
		"$BATS_TEST_DIRNAME/../d2-signalloom/apps/supercred-demo-runner/base/deployment.yaml"
	)

	run grep -Fq 'imagePullPolicy: IfNotPresent' "$script"
	[ "$status" -eq 0 ]
	run grep -Fq 'Kubelet attempts a registry pull for an absent image' "$script"
	[ "$status" -eq 0 ]
	run grep -Fq 'imagePullPolicy: IfNotPresent' "$images_script"
	[ "$status" -eq 0 ]
	run grep -Fq 'Kubelet attempts a registry pull for an absent image' "$images_script"
	[ "$status" -eq 0 ]
	run grep -Fq 'ErrImageNeverPull' "$script"
	[ "$status" -ne 0 ]
	run grep -Fq 'ErrImageNeverPull' "$images_script"
	[ "$status" -ne 0 ]
	for manifest in "${manifests[@]}"; do
		run grep -Fq 'imagePullPolicy: IfNotPresent' "$manifest"
		[ "$status" -eq 0 ]
	done
}

@test "credential-chain retries preserve distinct pod logs for stun evidence" {
	local job_manifest="$BATS_TEST_DIRNAME/../d2-signalloom/apps/fe-signalloom/base/agents-cardvault-job.yaml"
	run grep -Fq 'restartPolicy: Never' "$job_manifest"
	[ "$status" -eq 0 ]
	run grep -Fq 'Keep each failed credential-chain attempt as a distinct Pod' "$job_manifest"
	[ "$status" -eq 0 ]
}

# ─── The load-bearing claim: revocation is read back, not assumed ───────────

@test "a fully revoked run succeeds and prints the read-back as evidence" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"KV credential revoked"* ]]
	[[ "$output" == *'"deletion_time": "2026-08-13T00:02:08.818103270Z"'* ]]
	[[ "$output" == *"JWT auth role revoked"* ]]
	[[ "$output" == *"step 4 complete"* ]]
}

# The defect in one test. `bao kv delete` printed Success, the script declared
# the credential revoked, and the credential was still readable.
@test "a KV path that still returns secret data fails the step instead of claiming a stun" {
	write_revoked_agent_log
	export BAO_KV_GET_MODE="live"
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"REVOCATION DID NOT HAPPEN"* ]]
	[[ "$output" == *"still returns secret data"* ]]
	[[ "$output" == *"password"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "a JWT auth role that still resolves fails the step" {
	write_revoked_agent_log
	export BAO_ROLE_READ_MODE="present"
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"REVOCATION DID NOT HAPPEN"* ]]
	[[ "$output" == *"still resolves"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "a KV path deleted outright is proof of revocation too" {
	write_revoked_agent_log
	export BAO_KV_GET_MODE="absent"
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"read-back proves the path is gone"* ]]
}

@test "an unparseable read-back is never treated as revoked" {
	write_revoked_agent_log
	export BAO_KV_GET_MODE="unreadable"
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not prove revocation"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

# `2>/dev/null || true` on both deletes meant a sealed vault, an expired root
# token or an unreachable pod all produced silence followed by "✓ credentials
# revoked".
@test "a rejected KV delete stops the step and names the failure" {
	write_revoked_agent_log
	export BAO_KV_DELETE_STATUS=2
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"OpenBao rejected the KV delete"* ]]
	[[ "$output" == *"Error making API request"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "a rejected auth-role delete stops the step and names the failure" {
	write_revoked_agent_log
	export BAO_ROLE_DELETE_STATUS=2
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"OpenBao rejected the auth-role delete"* ]]
	[[ "$output" == *"permission denied"* ]]
}

@test "an unreachable vault during read-back fails rather than passing silently" {
	write_revoked_agent_log
	export BAO_KV_GET_MODE="unreachable"
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not read back"* ]]
	[[ "$output" == *"connection refused"* ]]
}

@test "the ambiguous OpenBao delete line is shown but labelled as not proof" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"Success! Data deleted (if it existed)"* ]]
	[[ "$output" == *"not that a"* ]]
	[[ "$output" == *"Reading the paths back is the proof"* ]]
}

# ─── The evidence log: captured, complete, and actually checked ─────────────

# The Job controller deletes the pod the moment backoffLimit is exceeded, so
# `kubectl logs job/...` AFTER the terminal condition has no pod to read: it
# blocked, printed "error: timed out waiting for the condition" to stderr, and
# `2>/dev/null` swallowed that. The demo showed nothing at the one moment it
# had something to prove.
@test "the agent's denial output is printed in full" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"SPIFFE identity acquired"* ]]
	[[ "$output" == *'FAILED: OpenBao login returned 400'* ]]
	[[ "$output" == *"role \\\"signalloom-cardvault-agent\\\" could not be found"* ]]
}

@test "a restarted agent pod preserves revocation evidence through previous logs" {
	write_revoked_agent_log
	cp "$AGENT_LOG_FILE" "$AGENT_PREVIOUS_LOG_FILE"
	: >"$AGENT_LOG_FILE"

	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"SPIFFE identity acquired"* ]]
	[[ "$output" == *"DENIED credentials"* ]]
}

@test "a CRI log retrieval failure cannot overwrite captured denial evidence" {
	write_revoked_agent_log
	cp "$AGENT_LOG_FILE" "$AGENT_PREVIOUS_LOG_FILE"
	printf 'unable to retrieve container logs for containerd://terminated-container\n' >"$AGENT_LOG_FILE"

	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"SPIFFE identity acquired"* ]]
	[[ "$output" == *"DENIED credentials"* ]]
	[[ "$output" != *"did not report a failure"* ]]
}

@test "each log probe has a bounded pending-pod wait" {
	run grep -Fq 'logs "$agent_pod" --all-containers --pod-running-timeout=1s' "$script"
	[ "$status" -eq 0 ]
	run grep -Fq 'logs "$agent_pod" --all-containers --previous --pod-running-timeout=1s' "$script"
	[ "$status" -eq 0 ]
}

# --tail=5 was in the original. A chain longer than five lines lost its opening
# steps, which are the half that shows identity still worked.
@test "no line of a long agent log is truncated away" {
	{
		echo "[step-1] SPIFFE identity acquired: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"
		echo "[step-1a] SVID expires in 3600s"
		echo "[step-1b] trust bundle has 1 root"
		echo "[step-1c] audience openbao"
		echo "[step-1d] attempting exchange"
		echo "[step-2] FAILED: OpenBao login returned 403: permission denied"
	} >"$AGENT_LOG_FILE"

	run_step4
	[ "$status" -eq 0 ]
	# The FIRST line is the one --tail=5 dropped, and the one that proves the
	# agent's identity survived while its authorisation did not.
	[[ "$output" == *"[step-1] SPIFFE identity acquired"* ]]
	[[ "$output" == *"[step-1a] SVID expires in 3600s"* ]]
	[[ "$output" == *"[step-2] FAILED: OpenBao login returned 403"* ]]
}

@test "a stun with no captured agent output is reported as unproven, not as success" {
	export JOB_POD_NAME=""
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"the stun is unproven"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "an agent job that completes after the stun fails AND shows why" {
	cat >"$AGENT_LOG_FILE" <<'LOG'
[step-1] SPIFFE identity acquired: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent
[step-2] OpenBao token acquired (policies: signalloom-cardvault-agent)
[step-4] Cardvault access successful — retrieved 3 card records
[complete] SuperCred identity chain verified
LOG
	export JOB_CONDITION="Complete"
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"COMPLETED after the stun"* ]]
	# The old code failed here too, but printed nothing — leaving the operator
	# with a red line and no idea which part of the chain still worked.
	[[ "$output" == *"Cardvault access successful"* ]]
}

# "The job did not succeed" is not evidence of credential revocation. A missing
# image, an unschedulable pod or a deleted ServiceAccount produce it just as
# readily, and the old code called every one of them a successful stun.
@test "a job that failed for a non-credential reason does not count as a stun" {
	cat >"$AGENT_LOG_FILE" <<'LOG'
[step-0] FAILED: cannot reach the SPIRE agent socket at /run/spire/sockets/agent.sock
LOG
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"NOT at the credential step"* ]]
	[[ "$output" == *"SPIRE agent socket"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "a job that neither succeeded nor reported a failure is unproven" {
	cat >"$AGENT_LOG_FILE" <<'LOG'
[step-1] SPIFFE identity acquired
[step-2] retrying...
LOG
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"did not report a failure"* ]]
	[[ "$output" != *"step 4 complete"* ]]
}

@test "a 403 denial from OpenBao is recognised as the stun" {
	cat >"$AGENT_LOG_FILE" <<'LOG'
[step-1] SPIFFE identity acquired
[step-2] FAILED: permission denied reading kv/data/signalloom/cardvault-agent
LOG
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" == *"DENIED credentials"* ]]
}

# ─── Output hygiene ─────────────────────────────────────────────────────────

# kubectl's own "command terminated with exit code 2" is not an error the
# operator needs to see inside a green ✓ block — bao's status is reported
# explicitly on every failure path — and mid-demo it reads as a fresh fault.
@test "kubectl exec noise is kept out of the success evidence blocks" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]
	[[ "$output" != *"command terminated with exit code"* ]]
}

# The failure paths keep it: there, every scrap of diagnostic earns its place.
@test "kubectl exec noise is preserved on the failure paths" {
	write_revoked_agent_log
	export BAO_KV_DELETE_STATUS=2
	run_step4
	[ "$status" -ne 0 ]
	[[ "$output" == *"command terminated with exit code 2"* ]]
}

# ─── Timestamps: whose clock, and whose line ────────────────────────────────
#
# These live in this file rather than one of their own because the stubs above
# are what make a complete step-4 run possible without a cluster, and step 4 is
# the step that emits BOTH kinds of line: the script's own narration, and
# output it is QUOTING from somewhere else — OpenBao's reply, the agent pod's
# log. A timestamp is only true for a line the script printed at the moment it
# printed it, so the two kinds are stamped differently and both halves of that
# rule are asserted here.

# A run under a non-UTC zone. Asia/Tokyo is +9 year-round, so a stamp that
# followed the host's local time can never coincidentally equal UTC — unlike
# Europe/London, which would make this test pass every winter for the wrong
# reason.
run_step4_in_tokyo() {
	run bash -c "TZ=Asia/Tokyo PATH='$PATH' DOCKER_BIN='$DOCKER_BIN' '$script' 4 2>&1"
}

@test "every narration line is stamped with the instant it was printed" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]

	local line unstamped="" narration=0
	while IFS= read -r line; do
		case "$line" in *"[supercred]"*) ;; *) continue ;; esac
		narration=$((narration + 1))
		if [[ ! "$line" =~ ^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]\  ]]; then
			unstamped="${unstamped}${line}"$'\n'
		fi
	done <<<"$output"

	# Step 4 narrates far more than five lines; the floor only guards against a
	# run that emitted nothing and vacuously satisfied the loop.
	[ "$narration" -ge 5 ]
	[ -z "$unstamped" ] || {
		printf 'narration lines with no timestamp:\n%s' "$unstamped" >&2
		false
	}
}

# The same script runs from a terminal in Europe/London and from the
# demo-runner pod, whose image sets no TZ and is therefore UTC. Local time
# would render one instant two ways with nothing on the line to say which.
@test "the stamp is UTC, so a terminal and the demo-runner pod agree" {
	write_revoked_agent_log
	local before after first
	before="$(date -u +%H:%M)"
	run_step4_in_tokyo
	after="$(date -u +%H:%M)"
	[ "$status" -eq 0 ]

	first="$(printf '%s\n' "$output" | grep -oE '^\[[0-9]{2}:[0-9]{2}' | head -1)"
	first="${first#[}"
	# Either side of a minute rollover is fine; nine hours out is not.
	[ "$first" = "$before" ] || [ "$first" = "$after" ]
}

@test "stamps never go backwards over the course of a run" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]

	local stamps sorted
	stamps="$(printf '%s\n' "$output" | grep -oE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]')"
	[ -n "$stamps" ]
	# HH:MM:SS sorts lexicographically in chronological order.
	sorted="$(printf '%s\n' "$stamps" | sort)"
	[ "$stamps" = "$sorted" ]
}

# The agent's line was printed inside a pod, and this script reads it back
# after the Job has already failed — a delay of up to SUPERCRED_STUN_EVIDENCE_-
# TIMEOUT seconds. Stamping it with the moment the script echoed it would put a
# false time on a real event, in a demo whose entire subject is evidence. Same
# for OpenBao's reply, which is quoted, not narrated.
@test "output the script is quoting from elsewhere is left unstamped" {
	write_revoked_agent_log
	run_step4
	[ "$status" -eq 0 ]

	# Deliberately NOT written as `! grep -q …`: bash exempts a !-inverted
	# command from errexit, so under bats such a line is inert and passes
	# whatever the output says. Capturing the offenders and asserting the
	# capture is empty is the form that can actually fail.
	local fabricated
	fabricated="$(printf '%s\n' "$output" \
		| grep -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}Z\].*(\[step-2\] FAILED|Success! Data deleted)' || true)"
	[ -z "$fabricated" ] || {
		printf 'quoted output was given a timestamp it did not earn:\n%s\n' "$fabricated" >&2
		false
	}

	# Present, verbatim, and still recognisable at the start of its own line.
	printf '%s\n' "$output" | grep -qE '^[[:space:]]*\[step-2\] FAILED: OpenBao login'
}
