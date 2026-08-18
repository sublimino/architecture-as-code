#!/usr/bin/env bats
#
# Everything needed to bring up `demo-1`, checked offline.
#
# The apply itself cannot be run by an agent and could not be run at all when
# this was written: the active gcloud account cannot reach the target project
# and the account that can needs interactive reauthentication. So the deliverable
# is the *inputs* to a single reviewed command, and this suite is what stops
# those inputs rotting between now and the evening someone finally types it.
#
# Two conventions carried from CONTRACT.md §6/§7, both of which this repo has
# been bitten by before:
#
#   Presence before behaviour. Every assertion here is a grep or a diff, and a
#   grep against a file that does not exist finds nothing — which reads
#   identical to a clean tree. So every test asserts the thing exists first.
#
#   Assert on the message, never on the status alone. A bare "exits non-zero"
#   passes for any failure, including the script not existing, a typo in its
#   shebang, or a syntax error — none of which are the behaviour under test.
#
# Offline: no network, no cloud credentials, no real gcloud. Under 30 seconds.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export TFVARS="${REPO_ROOT}/terraform/environments/demo-1.tfvars.example"
	export PREFLIGHT="${REPO_ROOT}/scripts/gcp-tf/preflight.sh"
	export RUNBOOK="${REPO_ROOT}/terraform/RUNBOOK.md"
	export FIXTURES="${REPO_ROOT}/test/fixtures/terraform/demo1"
}

setup() {
	# Presence before behaviour, for every artefact this file touches.
	[ -f "${TFVARS}" ]
	[ -f "${PREFLIGHT}" ]
	[ -f "${RUNBOOK}" ]
	[ -d "${FIXTURES}" ]
}

# Strip comments and blank lines. The header of the tfvars example legitimately
# discusses 0.0.0.0/0 and the shape of a real principal; a guard that could not
# tell prose from configuration would have to be weakened until it caught
# nothing.
code_only() {
	grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" || true
}

# ---------------------------------------------------------------------------
# The security posture, as one reusable predicate.
#
# Factored out precisely so the mutation check at the bottom can run the SAME
# code against a deliberately broken copy. A mutation check that re-implements
# the assertion proves the re-implementation works, not the guard.
# ---------------------------------------------------------------------------
assert_iap_posture() {
	local file="$1" body
	[ -f "$file" ] || {
		echo "assert_iap_posture: no such file: $file" >&2
		return 1
	}
	body="$(code_only "$file")"

	printf '%s\n' "$body" | grep -qE '^access_mode[[:space:]]*=[[:space:]]*"iap"$' || {
		echo "$file does not set access_mode = \"iap\"." >&2
		echo "That single line is the difference between an environment that is" >&2
		echo "routable-but-not-public and one that is on the open internet." >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qE '^iap_members[[:space:]]*=' || {
		echo "$file sets access_mode = \"iap\" but declares no iap_members." >&2
		echo "IAP with an empty member list is a working, fully locked-out" >&2
		echo "environment whose failure looks like a broken deploy." >&2
		return 1
	}
	! printf '%s\n' "$body" | grep -q '0\.0\.0\.0/0\|::/0' || {
		echo "an any-source CIDR appears in the configuration of $file" >&2
		return 1
	}
	return 0
}

# key<TAB>subnet_cidr for every environment entry in a tfvars example.
env_subnets() {
	awk '
		/^[[:space:]]*"[a-z0-9-]+"[[:space:]]*=[[:space:]]*\{/ {
			key = $0
			sub(/^[[:space:]]*"/, "", key)
			sub(/".*$/, "", key)
		}
		/subnet_cidr[[:space:]]*=/ {
			cidr = $0
			sub(/^.*=[[:space:]]*"/, "", cidr)
			sub(/".*$/, "", cidr)
			if (key != "") printf "%s\t%s\n", key, cidr
		}
	' "$1"
}

# ---------------------------------------------------------------------------
# demo-1.tfvars.example
# ---------------------------------------------------------------------------

@test "demo-1.tfvars.example parses as HCL and is fmt-clean" {
	# terraform fmt only recognises .tf/.tfvars/.tftest.hcl, so the committed
	# .tfvars.example is invisible to it in place. Copying to a scratch dir
	# under its real extension is what makes the check actually run — and the
	# copy is also the parse test, because fmt errors on malformed HCL.
	command -v terraform >/dev/null || skip "terraform not on PATH"

	local dir="${BATS_TEST_TMPDIR}/fmt"
	mkdir -p "$dir"
	cp "${TFVARS}" "${dir}/demo-1.tfvars"

	run terraform fmt -check -diff "$dir"
	[ "$status" -eq 0 ] || {
		echo "demo-1.tfvars.example is not canonically formatted or does not parse:" >&2
		echo "$output" >&2
		return 1
	}
}

@test "demo-1.tfvars.example declares the demo-1 key and targets it" {
	local body
	body="$(code_only "${TFVARS}")"

	printf '%s\n' "$body" | grep -qE '^[[:space:]]*"demo-1"[[:space:]]*=[[:space:]]*\{' || {
		echo "no \"demo-1\" entry in the environments map" >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qE '^target_env[[:space:]]*=[[:space:]]*"demo-1"$' || {
		echo "target_env is not \"demo-1\"; it must equal the map key, the ENV" >&2
		echo "passed to make, and the backend prefix suffix (CONTRACT §5a)." >&2
		return 1
	}
}

@test "demo-1.tfvars.example sets the IAP-only posture" {
	assert_iap_posture "${TFVARS}"
}

@test "demo-1.tfvars.example contains no real project id, domain or address" {
	local body
	body="$(code_only "${TFVARS}")"

	grep -q 'CHANGEME' "${TFVARS}" || {
		echo "no CHANGEME placeholder; the file may carry a real project id" >&2
		return 1
	}
	# RFC 5737 documentation ranges and the RFC 1918 subnets, nothing else.
	! printf '%s\n' "$body" | grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' |
		grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.10\.' || {
		echo "non-documentation IPv4 literal in the configuration" >&2
		return 1
	}
	! printf '%s\n' "$body" | grep -qE 'https?://|\.(com|net|org|io|dev|co\.uk)\b' || {
		echo "real-looking domain in the configuration" >&2
		return 1
	}
	! grep -q '/home/andy' "${TFVARS}" || {
		echo "absolute home path in ${TFVARS}" >&2
		return 1
	}
}

@test "demo-1's subnet collides with no other environment in any example" {
	local pairs demo1_cidr dupes
	pairs="$(for f in "${REPO_ROOT}"/terraform/environments/*.tfvars.example; do
		env_subnets "$f"
	done | sort -u)"

	[ -n "$pairs" ] || {
		echo "no environment/subnet pairs parsed out of any example; the" >&2
		echo "collision check would be vacuously true" >&2
		return 1
	}

	demo1_cidr="$(printf '%s\n' "$pairs" | awk -F'\t' '$1 == "demo-1" { print $2 }' | sort -u)"
	[ "$(printf '%s\n' "$demo1_cidr" | wc -l)" -eq 1 ] || {
		echo "demo-1 is given more than one subnet across the examples:" >&2
		printf '%s\n' "$demo1_cidr" >&2
		return 1
	}

	# Any OTHER key holding demo-1's CIDR is the collision. Terraform's own
	# uniqueness validation only sees one file at a time; this sees the estate.
	dupes="$(printf '%s\n' "$pairs" | awk -F'\t' -v c="$demo1_cidr" '$1 != "demo-1" && $2 == c { print $1 }' | sort -u)"
	[ -z "$dupes" ] || {
		echo "demo-1's subnet ${demo1_cidr} is also claimed by: ${dupes}" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Every value set in an example must be a variable that exists
# ---------------------------------------------------------------------------
#
# Terraform treats a value for an UNDECLARED variable in a -var-file as a
# warning, not an error. It proceeds, discards the value, and the module takes
# its own default. The warning scrolls past in CI output where nobody reads it.
#
# That is how `access_mode = "iap"` in tfvars can produce an environment whose
# access mode was never set by anyone — right by accident, for exactly as long
# as the module default happens to agree. This test is the only thing that turns
# a discarded value into a failure.

# Top-level assignments only. Nested map entries are indented, so anchoring at
# column zero is what separates `iap_members = [...]` from `app_port = 8080`
# inside an environment block.
tfvars_assignments() {
	grep -oE '^[a-z_][a-z0-9_]*[[:space:]]*=' "$1" | sed 's/[[:space:]]*=$//' || true
}

declared_variables() {
	grep -oE '^variable "[a-z_][a-z0-9_]*"' "${REPO_ROOT}/terraform/environments/variables.tf" |
		sed 's/^variable "//; s/"$//' || true
}

# Names assigned in $1 that variables.tf does not declare, one per line.
undeclared_in() {
	comm -23 <(tfvars_assignments "$1" | sort -u) <(declared_variables | sort -u)
}

@test "every variable set in a committed tfvars example is declared" {
	local varfile="${REPO_ROOT}/terraform/environments/variables.tf"
	[ -f "$varfile" ]

	# Positive control, twice over. An empty assignment set or an empty
	# declaration set makes the comm below trivially clean, and a scan of
	# nothing reports the same "all declared" as a scan of everything.
	local declared assigned
	declared="$(declared_variables | wc -l)"
	[ "$declared" -ge 8 ] || {
		echo "only ${declared} variables parsed out of variables.tf; the parser is broken" >&2
		return 1
	}

	local f undeclared bad=()
	for f in "${REPO_ROOT}"/terraform/environments/*.tfvars.example; do
		assigned="$(tfvars_assignments "$f" | sort -u | wc -l)"
		[ "$assigned" -ge 4 ] || {
			echo "only ${assigned} assignments parsed out of $(basename "$f"); the parser is broken" >&2
			return 1
		}
		undeclared="$(undeclared_in "$f")"
		[ -z "$undeclared" ] || bad+=("$(basename "$f"): $(printf '%s' "$undeclared" | tr '\n' ' ')")
	done

	[ "${#bad[@]}" -eq 0 ] || {
		echo "these examples set variables that terraform/environments/variables.tf" >&2
		echo "does not declare. Terraform will WARN and silently discard the value:" >&2
		printf '  %s\n' "${bad[@]}" >&2
		return 1
	}
}

@test "the declared-variable check catches an undeclared assignment" {
	# The mutation for the test above. Without it, a parser that returned
	# nothing would report every example clean forever.
	local mutated="${BATS_TEST_TMPDIR}/undeclared.tfvars.example"
	cp "${TFVARS}" "$mutated"
	printf '\nnot_a_real_variable = "x"\n' >>"$mutated"

	run undeclared_in "$mutated"
	[[ "$output" == *"not_a_real_variable"* ]] || {
		echo "the check did not flag an assignment to an undeclared variable" >&2
		echo "output: ${output}" >&2
		return 1
	}
	# And the unmutated file must still be clean, or the check is just noisy.
	run undeclared_in "${TFVARS}"
	[ -z "$output" ] || {
		echo "the real example reports undeclared variables: ${output}" >&2
		return 1
	}
}

@test "access_mode and iap_members are both set in the example and declared" {
	# The specific pair this whole class of failure was found through. Named
	# explicitly so that deleting either declaration fails on the thing that
	# broke, not on a generic count.
	local name
	for name in access_mode iap_members; do
		tfvars_assignments "${TFVARS}" | grep -qx "$name" || {
			echo "demo-1.tfvars.example does not set ${name}" >&2
			return 1
		}
		declared_variables | grep -qx "$name" || {
			echo "terraform/environments/variables.tf does not declare ${name}." >&2
			echo "Terraform would warn and discard the tfvars value, leaving the" >&2
			echo "module default to decide whether the environment is public." >&2
			return 1
		}
	done
}

@test "the root declares access_mode with the safe default" {
	# A module default governs only while the caller passes no value. Once this
	# root wires access_mode into modules/edge, the ROOT's default is what
	# ships, and a root defaulting to "allowlist" reverses the private-edge
	# posture while every module test stays green.
	#
	# The evaluated-configuration proof lives in
	# terraform/environments/tests/edge_access_defaults.tftest.hcl; this is the
	# textual guard that the tftest file has not been deleted along with it.
	local tftest="${REPO_ROOT}/terraform/environments/tests/edge_access_defaults.tftest.hcl"
	[ -f "$tftest" ] || {
		echo "the evaluated-default proof is missing: ${tftest}" >&2
		return 1
	}
	grep -qF 'default_access_mode_is_iap' "$tftest" || {
		echo "${tftest} no longer asserts the evaluated default" >&2
		return 1
	}
	grep -qF 'expect_failures = [var.iap_members]' "$tftest" || {
		echo "${tftest} no longer proves the iap_members guards reject anything" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# preflight.sh
# ---------------------------------------------------------------------------

@test "preflight.sh is executable and shellcheck-clean" {
	[ -x "${PREFLIGHT}" ] || {
		echo "${PREFLIGHT} is not executable; the RUNBOOK invokes it directly" >&2
		return 1
	}
	command -v shellcheck >/dev/null || skip "shellcheck not on PATH"
	run shellcheck "${PREFLIGHT}"
	[ "$status" -eq 0 ] || {
		echo "$output" >&2
		return 1
	}
}

@test "preflight.sh fails with the identity fix named when the project is unreachable" {
	# The situation that actually exists on this machine: an active account that
	# cannot reach the project. gcloud answers that with a message reading
	# "(or it may not exist)", so the obvious conclusion is a wrong project id
	# and the obvious next move is to go hunting for a different one.
	#
	# Asserting on the MESSAGE, not merely on a non-zero status. A status check
	# alone passes if the script is missing, unexecutable, or has a syntax
	# error, so it would go green on a tree where nothing was built at all.
	local stub="${BATS_TEST_TMPDIR}/stub"
	mkdir -p "$stub"
	cat >"${stub}/gcloud" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" auth list "*)
    case " $* " in
      *"status:ACTIVE"*) echo "personal@example.invalid" ;;
      *) printf 'personal@example.invalid\nwork@example.invalid\n' ;;
    esac
    exit 0 ;;
  *" projects describe "*)
    echo "ERROR: (gcloud.projects.describe) User [personal@example.invalid] does not have permission to access projects instance [CHANGEME-project] (or it may not exist)." >&2
    exit 1 ;;
esac
echo "ERROR: PERMISSION_DENIED" >&2
exit 1
STUB
	chmod +x "${stub}/gcloud"

	PATH="${stub}:${PATH}" run "${PREFLIGHT}" --project CHANGEME-project --env demo-1

	[ "$status" -ne 0 ] || {
		echo "preflight exited 0 against a project it could not describe" >&2
		echo "$output" >&2
		return 1
	}
	# The stub must actually have been the gcloud that ran, or every assertion
	# below is about the real gcloud on this machine.
	[[ "$output" == *"${stub}/gcloud"* ]] || {
		echo "the stub gcloud was not the one invoked; this test measured nothing" >&2
		echo "$output" >&2
		return 1
	}
	[[ "$output" == *"cannot describe project"* ]] || {
		echo "the failure does not say the project could not be described" >&2
		echo "$output" >&2
		return 1
	}
	[[ "$output" == *"personal@example.invalid"* ]] || {
		echo "the failure does not name the identity that failed" >&2
		echo "$output" >&2
		return 1
	}
	[[ "$output" == *"gcloud auth login"* ]] || {
		echo "the failure does not name the fix: gcloud auth login <account>" >&2
		echo "$output" >&2
		return 1
	}
	# Could-not-look must never be reported as is-not-so.
	[[ "$output" == *"UNKNOWN"*"required APIs"* ]] || {
		echo "the API check reported something other than UNKNOWN when it could" >&2
		echo "not read the service list. Reporting 'not enabled' here sends" >&2
		echo "someone to enable an API that was already on." >&2
		echo "$output" >&2
		return 1
	}
}

@test "preflight.sh refuses to make a mutating gcloud call" {
	# Read-only is a mechanism here, not a promise in a comment. Verify the
	# mechanism is present in the source AND that it fails closed, because a
	# correct-looking allowlist that is never consulted is the same as none.
	grep -q 'gcloud_ro()' "${PREFLIGHT}" || {
		echo "preflight.sh has no gcloud_ro gate; the read-only claim is unbacked" >&2
		return 1
	}

	local probe="${BATS_TEST_TMPDIR}/probe.sh"
	{
		sed -n '/^gcloud_ro()/,/^}/p' "${PREFLIGHT}"
		echo 'SCRIPT_NAME=probe; EXIT_USAGE=2; GCLOUD_BIN=true'
		echo 'gcloud_ro services enable compute.googleapis.com'
	} >"$probe"

	run bash "$probe"
	[ "$status" -eq 2 ] || {
		echo "the read-only gate let 'services enable' through (status ${status})" >&2
		echo "$output" >&2
		return 1
	}
	[[ "$output" == *"refusing to run a non-read-only gcloud call"* ]] || {
		echo "the gate failed for some reason other than the allowlist" >&2
		echo "$output" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# RUNBOOK.md
# ---------------------------------------------------------------------------

@test "the RUNBOOK names every prerequisite Andy must supply" {
	local missing=() needle
	local needles=(
		'Target project id'
		'Billing account'
		'State bucket location'
		'Project number'
		'GitHub owner numeric id'
		'DNS managed zone'
		'iap_members'
		'allowlist'
		'Owner label'
	)
	for needle in "${needles[@]}"; do
		grep -qF "$needle" "${RUNBOOK}" || missing+=("$needle")
	done
	[ "${#missing[@]}" -eq 0 ] || {
		echo "the RUNBOOK does not name these prerequisites: ${missing[*]}" >&2
		echo "Each one discovered mid-run costs a re-plan." >&2
		return 1
	}
}

@test "the RUNBOOK's apply command names demo-1 and applies a saved plan" {
	grep -qF 'make gcp-tf-apply ENV=demo-1' "${RUNBOOK}" || {
		echo "no copy-pasteable apply command with demo-1 already substituted" >&2
		return 1
	}
	grep -qF 'make gcp-tf-plan ENV=demo-1' "${RUNBOOK}" || {
		echo "no copy-pasteable plan command with demo-1 already substituted" >&2
		return 1
	}
	grep -qF 'make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1' "${RUNBOOK}" || {
		echo "no exact destroy command; the typed CONFIRM is the guard that fails" >&2
		echo "when you meant demo-2 and your shell history said demo-1." >&2
		return 1
	}
	grep -qiE 'saved,? (and )?reviewed plan|saved plan file|applies a saved' "${RUNBOOK}" || {
		echo "the RUNBOOK does not state that gcp-tf-apply only ever applies a" >&2
		echo "saved reviewed plan. A bare apply re-plans at apply time, so what" >&2
		echo "a human read and what Terraform executes are two different plans." >&2
		return 1
	}
}

@test "the RUNBOOK states which steps have never been executed" {
	grep -qiF 'Execution status' "${RUNBOOK}" || {
		echo "the RUNBOOK has no execution-status section." >&2
		echo "A procedure written from configuration rather than from a" >&2
		echo "transcript must say so, or its first reader will trust it as" >&2
		echo "though someone had already walked it." >&2
		return 1
	}
	grep -qiE '(has ever|never) been (executed|run)' "${RUNBOOK}" || {
		echo "the RUNBOOK does not say plainly that these steps are unexecuted." >&2
		echo "A procedure written from configuration rather than from a" >&2
		echo "transcript must say so, or its first reader will trust it as" >&2
		echo "though someone had already walked it." >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Mutation check — prove the posture guard can go red
# ---------------------------------------------------------------------------

@test "the posture guard fails when demo-1 is flipped to allowlist-only" {
	local sedfile="${FIXTURES}/access-mode-allowlist.sed"
	[ -f "$sedfile" ] || {
		echo "mutation fixture missing: $sedfile" >&2
		return 1
	}

	local mutated="${BATS_TEST_TMPDIR}/demo-1-allowlist.tfvars.example"
	sed -f "$sedfile" "${TFVARS}" >"$mutated"

	# A sed program whose pattern has drifted applies cleanly and changes
	# nothing, and the mutation check then runs against an UNMUTATED file and
	# passes — reporting that the guard works when it has not been exercised at
	# all. Refuse to continue on a no-op mutation.
	if diff -q "${TFVARS}" "$mutated" >/dev/null; then
		echo "the mutation changed nothing: its pattern no longer matches" >&2
		echo "demo-1.tfvars.example, so this test is measuring nothing." >&2
		return 1
	fi

	# Baseline green, then mutation red — in that order, with the same predicate.
	assert_iap_posture "${TFVARS}" || {
		echo "the unmutated file already fails the posture guard" >&2
		return 1
	}
	run assert_iap_posture "$mutated"
	[ "$status" -ne 0 ] || {
		echo "the posture guard passed a file with access_mode = \"public\"." >&2
		echo "It cannot fail, so it has never been protecting anything." >&2
		return 1
	}
	[[ "$output" == *'access_mode = "iap"'* ]] || {
		echo "the guard failed for some reason other than access_mode" >&2
		echo "$output" >&2
		return 1
	}
}
