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

	# The real, apply-ready input. It is NOT under terraform/ and cannot be:
	# "no .tfvars file is committed under terraform/" in
	# terraform-environment-keys.bats runs a filesystem `find`, so a real
	# .tfvars there turns that suite red whether or not it is committed, and
	# the committed-secrets guard on *.tfvars.example rejects the real IAP
	# principal because it contains a real domain. See the header of the file
	# itself for the full reasoning.
	export REAL_TFVARS="${REPO_ROOT}/deploy/gcp/sl-port-over-sandbox.example.tfvars"
}

setup() {
	# Presence before behaviour, for every artefact this file touches.
	[ -f "${TFVARS}" ]
	[ -f "${PREFLIGHT}" ]
	[ -f "${RUNBOOK}" ]
	[ -d "${FIXTURES}" ]
	[ -f "${REAL_TFVARS}" ]
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

# $1 = path to a variables.tf. Defaults to the environments root so every
# existing caller is unchanged.
declared_variables() {
	local varfile="${1:-${REPO_ROOT}/terraform/environments/variables.tf}"
	grep -oE '^variable "[a-z_][a-z0-9_]*"' "$varfile" |
		sed 's/^variable "//; s/"$//' || true
}

# Names assigned in $1 that the variables.tf at $2 does not declare, one per
# line. $2 defaults to the environments root.
#
# The variables.tf must be passed rather than globbed, because each root
# declares its own: terraform/bootstrap/terraform.tfvars.example is checked
# against terraform/bootstrap/variables.tf and would be reported as entirely
# undeclared against the environments one. A wider glob would have looked like
# more coverage and been strictly wrong.
undeclared_in() {
	comm -23 <(tfvars_assignments "$1" | sort -u) <(declared_variables "${2:-}" | sort -u)
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

# ─── The bootstrap root has its own variables.tf, and its own exposure ───────
#
# The scans above cover terraform/environments only. terraform/bootstrap ships
# a committed terraform.tfvars.example too, and it is checked against
# terraform/bootstrap/variables.tf — a different declaration set, so this is a
# second scan rather than a wider glob. Globbing both roots into one comparison
# would report every bootstrap assignment as undeclared and look like coverage
# while being strictly wrong.
#
# It was clean when this was written. That is exactly the state worth pinning:
# a root nobody is watching is where a discarded tfvars value survives longest,
# and the bootstrap root is the one that creates the bucket holding every other
# root's state.

@test "every variable set in the bootstrap tfvars example is declared" {
	local example="${REPO_ROOT}/terraform/bootstrap/terraform.tfvars.example"
	local varfile="${REPO_ROOT}/terraform/bootstrap/variables.tf"
	[ -f "$example" ]
	[ -f "$varfile" ]

	# Positive control on both sides. An empty parse on either makes the
	# comparison trivially clean, and a scan of nothing reports the same
	# "all declared" as a scan of everything.
	local declared assigned
	declared="$(declared_variables "$varfile" | wc -l)"
	[ "$declared" -ge 4 ] || {
		echo "only ${declared} variables parsed out of bootstrap/variables.tf; the parser is broken" >&2
		return 1
	}
	assigned="$(tfvars_assignments "$example" | wc -l)"
	[ "$assigned" -ge 3 ] || {
		echo "only ${assigned} assignments parsed out of the bootstrap example; the parser is broken" >&2
		return 1
	}

	local undeclared
	undeclared="$(undeclared_in "$example" "$varfile")"
	[ -z "$undeclared" ] || {
		echo "the bootstrap example sets variables that terraform/bootstrap/variables.tf" >&2
		echo "does not declare. Terraform will WARN and silently discard the value:" >&2
		echo "$undeclared" | sed 's/^/  terraform.tfvars.example: /' >&2
		return 1
	}
}

@test "the bootstrap declared-variable check catches an undeclared assignment" {
	# Mutation. Without this the test above passes on a tree where the
	# comparison silently compares two empty sets.
	local stage undeclared
	stage="$(mktemp -d)"
	cp "${REPO_ROOT}/terraform/bootstrap/terraform.tfvars.example" "${stage}/mutant.tfvars.example"
	printf '\nnot_a_real_bootstrap_variable = "x"\n' >>"${stage}/mutant.tfvars.example"

	undeclared="$(undeclared_in "${stage}/mutant.tfvars.example" "${REPO_ROOT}/terraform/bootstrap/variables.tf")"
	rm -rf "$stage"

	[ -n "$undeclared" ]
	[[ "$undeclared" == *"not_a_real_bootstrap_variable"* ]]
}

@test "the bootstrap and environments declaration sets are genuinely different" {
	# Proves the two-scan design is necessary rather than defensive. If these
	# ever became the same set, one scan would do and this file should say so.
	local boot env_
	boot="$(declared_variables "${REPO_ROOT}/terraform/bootstrap/variables.tf" | sort -u)"
	env_="$(declared_variables "${REPO_ROOT}/terraform/environments/variables.tf" | sort -u)"
	[ -n "$boot" ]
	[ -n "$env_" ]
	[ "$boot" != "$env_" ]
}

# ---------------------------------------------------------------------------
# us-east4 and the real, apply-ready input
# ---------------------------------------------------------------------------
#
# The estate was written against europe-west2, which was correct for the
# hand-built CI VM and wrong for the project this actually deploys into. The
# tests below pin the retarget so nobody copies a europe-west2 example into a
# us-east4 project, and pin the real input so its apply-ready values cannot
# quietly rot back into placeholders.

# key<TAB>region<TAB>zone for every environment entry in a tfvars file.
#
# Emitted on the ZONE line, which in every file in this tree follows the region
# line. A file that ordered them the other way would parse as zero pairs rather
# than as a wrong pair, which is why every caller below asserts a non-zero
# count before drawing any conclusion from the result.
env_region_zone() {
	awk '
		/^[[:space:]]*"[a-z0-9-]+"[[:space:]]*=[[:space:]]*\{/ {
			key = $0
			sub(/^[[:space:]]*"/, "", key)
			sub(/".*$/, "", key)
			region = ""
		}
		/^[[:space:]]+region[[:space:]]*=/ {
			region = $0
			sub(/^.*=[[:space:]]*"/, "", region)
			sub(/".*$/, "", region)
		}
		/^[[:space:]]+zone[[:space:]]*=/ {
			zone = $0
			sub(/^.*=[[:space:]]*"/, "", zone)
			sub(/".*$/, "", zone)
			if (key != "" && region != "") printf "%s\t%s\t%s\n", key, region, zone
		}
	' "$1"
}

# ---------------------------------------------------------------------------
# The zone/region coupling, as one reusable predicate.
#
# Factored out so the mutation check at the bottom runs the SAME code against a
# deliberately broken copy. A mutation check that re-implements the assertion
# proves the re-implementation works, not the guard.
#
# Why this is worth a test at all: `region` and `zone` are independent strings
# and nothing in Terraform compares them. `region = "us-east4"` with
# `zone = "europe-west2-a"` produces a completely clean plan and fails during
# apply, once the VPC, the subnet and the load balancer already exist. Apply is
# the expensive place to discover it and the slow place to unwind it.
# ---------------------------------------------------------------------------
assert_zone_in_region() {
	local file="$1" pairs n bad
	[ -f "$file" ] || {
		echo "assert_zone_in_region: no such file: $file" >&2
		return 1
	}

	pairs="$(env_region_zone "$file")"
	n="$(printf '%s' "$pairs" | grep -c . || true)"
	[ "$n" -ge 1 ] || {
		echo "no region/zone pairs parsed out of ${file}; this check would be" >&2
		echo "vacuously true, which reads identical to a clean file." >&2
		return 1
	}

	# A GCP zone is its region plus a single-letter suffix. Anything else is a
	# mismatch, including a zone that merely starts with a similar string.
	bad="$(printf '%s\n' "$pairs" |
		awk -F'\t' '$3 !~ "^" $2 "-[a-z]$" { print "  " $1 ": region=" $2 " zone=" $3 }')"
	[ -z "$bad" ] || {
		echo "${file} pairs a zone with a region it is not inside:" >&2
		printf '%s\n' "$bad" >&2
		echo "This plans cleanly and fails at apply, after the network exists." >&2
		return 1
	}
	return 0
}

@test "the real apply-ready input exists outside terraform/ and is fmt-clean" {
	# Presence and parse before any content assertion. And the location is
	# itself load-bearing: terraform-environment-keys.bats runs
	# `find terraform/ -name '*.tfvars'` and asserts it is EMPTY, so a real
	# .tfvars under terraform/ turns that suite red whether or not git tracks
	# it. If someone "helpfully" moves this file, both suites should say so.
	case "${REAL_TFVARS}" in
	*/terraform/*)
		echo "the real input is under terraform/, where the find-based guard in" >&2
		echo "terraform-environment-keys.bats will fail on it." >&2
		return 1
		;;
	esac

	run bash -c "find '${REPO_ROOT}/terraform' -name '*.tfvars' -type f"
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		echo "a real .tfvars exists under terraform/ and will fail" >&2
		echo "terraform-environment-keys.bats:" >&2
		echo "$output" >&2
		return 1
	}

	command -v terraform >/dev/null || skip "terraform not on PATH"
	local dir="${BATS_TEST_TMPDIR}/realfmt"
	mkdir -p "$dir"
	cp "${REAL_TFVARS}" "${dir}/real.tfvars"
	run terraform fmt -check -diff "$dir"
	[ "$status" -eq 0 ] || {
		echo "the real input is not canonically formatted or does not parse:" >&2
		echo "$output" >&2
		return 1
	}
}

@test "the real input targets us-east4 with a zone inside that region" {
	local body
	body="$(code_only "${REAL_TFVARS}")"

	printf '%s\n' "$body" | grep -qE '^[[:space:]]+region[[:space:]]*=[[:space:]]*"us-east4"$' || {
		echo "the real input does not set region = \"us-east4\"." >&2
		echo "The target project's environment is us-east4; europe-west2 is the" >&2
		echo "old hand-built CI estate's region." >&2
		return 1
	}
	# Assert no stale region survived anywhere in the configuration.
	! printf '%s\n' "$body" | grep -q 'europe-west2' || {
		echo "europe-west2 still appears in the real input's configuration" >&2
		return 1
	}
	assert_zone_in_region "${REAL_TFVARS}"
}

@test "every committed example also targets us-east4 with a coherent zone" {
	# The retarget is only useful if it is complete. An example left on
	# europe-west2 is one copy-paste from an environment built in the wrong
	# region, which is a full destroy/recreate to correct.
	local f checked=0
	for f in "${REPO_ROOT}"/terraform/environments/demo-1.tfvars.example \
		"${REPO_ROOT}"/terraform/environments/demo-1-and-demo-2.tfvars.example; do
		[ -f "$f" ] || {
			echo "missing example: $f" >&2
			return 1
		}
		code_only "$f" | grep -q 'europe-west2' && {
			echo "$(basename "$f") still configures europe-west2" >&2
			return 1
		}
		code_only "$f" | grep -qE '^[[:space:]]+region[[:space:]]*=[[:space:]]*"us-east4"$' || {
			echo "$(basename "$f") does not configure us-east4" >&2
			return 1
		}
		assert_zone_in_region "$f"
		checked=$((checked + 1))
	done

	# Positive control. A loop that examined nothing reports the same silence
	# as a loop that examined everything and found it correct.
	[ "$checked" -eq 2 ] || {
		echo "expected to check 2 examples, checked ${checked}" >&2
		return 1
	}
}

@test "the real input is apply-ready: IAP, a named principal, no placeholder" {
	local body
	body="$(code_only "${REAL_TFVARS}")"

	# Reuses the same posture predicate the examples are held to, so the real
	# file cannot drift to a weaker posture than the template it came from.
	assert_iap_posture "${REAL_TFVARS}"

	printf '%s\n' "$body" | grep -qE '^project_id[[:space:]]*=[[:space:]]*"sl-port-over-sandbox"$' || {
		echo "the real input does not name the real project" >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qE '^project_number[[:space:]]*=[[:space:]]*"[0-9]{6,}"$' || {
		echo "the real input has no numeric project_number" >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qE '^target_env[[:space:]]*=[[:space:]]*"demo-1"$' || {
		echo "the real input does not target demo-1" >&2
		return 1
	}

	# The inverse of the examples' rule. An example MUST carry CHANGEME; the
	# real input must carry none, or it is not apply-ready and the operator
	# discovers that at plan time.
	! printf '%s\n' "$body" | grep -q 'CHANGEME' || {
		echo "the real input still contains a CHANGEME placeholder in its" >&2
		echo "configuration; it is not apply-ready." >&2
		return 1
	}
	! printf '%s\n' "$body" | grep -q 'example\.invalid' || {
		echo "the real input still contains an example.invalid value" >&2
		return 1
	}
}

@test "the real input names a non-empty, non-wildcard IAP principal" {
	# The single value that decides whether the demo can be opened at all.
	# An empty list applies cleanly and locks everyone out including Andy, and
	# the symptom is a 403 AFTER a successful Google login — which reads like a
	# broken deploy rather than a missing grant.
	local members
	members="$(code_only "${REAL_TFVARS}" |
		sed -n '/^iap_members[[:space:]]*=[[:space:]]*\[/,/^\]/p' |
		grep -oE '"[^"]+"' | tr -d '"')"

	[ -n "$members" ] || {
		echo "iap_members is empty in the real input. IAP with no authorised" >&2
		echo "principal is a locked door with no key." >&2
		return 1
	}

	local m
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		# Same structural rule modules/edge enforces: a bare address grants
		# nothing, and the two dangerous values carry no prefix at all.
		[[ "$m" =~ ^(user|group|serviceAccount|domain|principal|principalSet): ]] || {
			echo "iap_members entry is not a prefixed IAM principal: ${m}" >&2
			return 1
		}
		case "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" in
		*allusers* | *allauthenticatedusers* | *'*'*)
			echo "iap_members contains a public or wildcard principal: ${m}" >&2
			return 1
			;;
		esac
	done <<<"$members"
}

@test "every variable set in the real input is declared by the environments root" {
	# Terraform treats a value for an UNDECLARED variable in a -var-file as a
	# warning, not an error: it proceeds, discards the value and takes the
	# module default. That is how a real input can set access_mode and get an
	# environment whose access mode nobody chose.
	#
	# The existing scan globs terraform/environments/*.tfvars.example only, so
	# this file — the one that will actually be applied — is outside it.
	local varfile="${REPO_ROOT}/terraform/environments/variables.tf"
	[ -f "$varfile" ]

	# Positive control on both sides before comparing.
	local declared assigned
	declared="$(declared_variables "$varfile" | wc -l)"
	[ "$declared" -ge 8 ] || {
		echo "only ${declared} variables parsed out of variables.tf; parser broken" >&2
		return 1
	}
	assigned="$(tfvars_assignments "${REAL_TFVARS}" | sort -u | wc -l)"
	[ "$assigned" -ge 5 ] || {
		echo "only ${assigned} assignments parsed out of the real input; parser broken" >&2
		return 1
	}

	local undeclared
	undeclared="$(undeclared_in "${REAL_TFVARS}" "$varfile")"
	[ -z "$undeclared" ] || {
		echo "the real input sets variables the environments root does not" >&2
		echo "declare. Terraform will WARN and silently discard them:" >&2
		printf '  %s\n' "$undeclared" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Mutation checks — prove each new guard can actually go red
# ---------------------------------------------------------------------------

@test "the zone/region guard fails when a zone is moved out of its region" {
	local mutated="${BATS_TEST_TMPDIR}/zone-mismatch.tfvars"
	sed 's/^\([[:space:]]*\)zone\([[:space:]]*\)= "us-east4-a"/\1zone\2= "europe-west2-a"/' \
		"${REAL_TFVARS}" >"$mutated"

	# A sed whose pattern has drifted applies cleanly and changes nothing, and
	# the check then runs against an UNMUTATED file and passes — reporting that
	# the guard works when it was never exercised. Refuse a no-op mutation.
	if diff -q "${REAL_TFVARS}" "$mutated" >/dev/null; then
		echo "the mutation changed nothing: its pattern no longer matches the" >&2
		echo "real input, so this test is measuring nothing." >&2
		return 1
	fi

	# Baseline green, then mutation red, with the same predicate in both.
	assert_zone_in_region "${REAL_TFVARS}" || {
		echo "the unmutated real input already fails the zone/region guard" >&2
		return 1
	}
	run assert_zone_in_region "$mutated"
	[ "$status" -ne 0 ] || {
		echo "the guard passed a zone in a different region from its region." >&2
		echo "It cannot fail, so it has never been protecting anything." >&2
		return 1
	}
	[[ "$output" == *"not inside"* ]] || {
		echo "the guard failed for some reason other than the zone mismatch" >&2
		echo "$output" >&2
		return 1
	}
}

@test "the zone/region guard fails when it can parse nothing" {
	# The vacuous-pass direction, which is the one that hides. A parser that
	# returns nothing must be an error, not a silent success.
	local empty="${BATS_TEST_TMPDIR}/no-environments.tfvars"
	printf 'project_id = "sl-port-over-sandbox"\n' >"$empty"

	run assert_zone_in_region "$empty"
	[ "$status" -ne 0 ] || {
		echo "the guard passed a file containing no region/zone pair at all" >&2
		return 1
	}
	[[ "$output" == *"vacuously true"* ]] || {
		echo "the guard failed for some reason other than parsing nothing" >&2
		echo "$output" >&2
		return 1
	}
}

@test "the apply-ready guard fails when the real input reverts to a placeholder" {
	local mutated="${BATS_TEST_TMPDIR}/placeholder.tfvars"
	sed 's/"user:sublimino@gmail\.com"/"user:CHANGEME-you@example.invalid"/' \
		"${REAL_TFVARS}" >"$mutated"

	if diff -q "${REAL_TFVARS}" "$mutated" >/dev/null; then
		echo "the mutation changed nothing: its pattern no longer matches" >&2
		return 1
	fi

	# Positive: the real file has no placeholder in its configuration.
	! code_only "${REAL_TFVARS}" | grep -q 'CHANGEME\|example\.invalid' || {
		echo "the unmutated real input already contains a placeholder" >&2
		return 1
	}
	# Negative: the mutant does, and is therefore not apply-ready.
	code_only "$mutated" | grep -q 'CHANGEME\|example\.invalid' || {
		echo "the placeholder check cannot see a placeholder that is present." >&2
		echo "It cannot fail, so it has never been protecting anything." >&2
		return 1
	}
}

@test "the posture guard fails when the real input is flipped to allowlist-only" {
	# Same predicate the examples are held to, exercised against the file that
	# will actually be applied.
	local mutated="${BATS_TEST_TMPDIR}/real-allowlist.tfvars"
	sed 's/^access_mode = "iap"$/access_mode = "allowlist"/' "${REAL_TFVARS}" >"$mutated"

	if diff -q "${REAL_TFVARS}" "$mutated" >/dev/null; then
		echo "the mutation changed nothing: its pattern no longer matches" >&2
		return 1
	fi

	assert_iap_posture "${REAL_TFVARS}" || {
		echo "the unmutated real input already fails the posture guard" >&2
		return 1
	}
	run assert_iap_posture "$mutated"
	[ "$status" -ne 0 ] || {
		echo "the posture guard passed access_mode = \"allowlist\" on the real" >&2
		echo "input. An IP allowlist is exposure control, not authentication." >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# The private-edge posture: no public frontend, IAP TCP forwarding only
# ---------------------------------------------------------------------------
#
# This environment deliberately instantiates no public HTTPS edge. IAP for web
# backends needs an HTTPS load balancer, which needs a certificate on a name
# that resolves, and the project has no Cloud DNS managed zone. Rather than
# reach for a self-signed certificate, the environment exposes nothing publicly
# at all and is reached over IAP TCP forwarding.
#
# The pairing is what matters. `hostname` alone drives the frontend
# (tls_enabled = hostname != ""), while the DNS RECORD needs both
# (dns_enabled = hostname != "" && dns_managed_zone != ""). So a future edit
# that sets a hostname while leaving dns_managed_zone empty builds a real
# certificate for a name with no record to validate against — it sits in
# PROVISIONING, and a certificate that has not issued yet is indistinguishable
# from one that never will. That is the edit this guard is here to catch.

# Value of a top-level scalar assignment, or the empty string if unset.
# Prints nothing at all when the key is absent, which every caller below
# distinguishes from "present and empty".
tfvars_scalar() {
	code_only "$1" |
		sed -n "s/^${2}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*$/\\1/p"
}

# Present-and-empty, as a predicate, so the mutation checks can reuse it.
assert_no_public_edge() {
	local file="$1" host_lines zone_lines host zone
	[ -f "$file" ] || {
		echo "assert_no_public_edge: no such file: $file" >&2
		return 1
	}

	# hostname lives inside the environment map, so it is indented.
	host_lines="$(code_only "$file" |
		grep -cE '^[[:space:]]+hostname[[:space:]]*=' || true)"
	zone_lines="$(code_only "$file" |
		grep -cE '^dns_managed_zone[[:space:]]*=' || true)"

	# Presence before behaviour. An absent key would make both greps below
	# find nothing, which reads identical to "correctly empty".
	[ "$host_lines" -ge 1 ] || {
		echo "${file} sets no hostname at all; the check would be vacuous" >&2
		return 1
	}
	[ "$zone_lines" -ge 1 ] || {
		echo "${file} sets no dns_managed_zone at all; the check would be vacuous" >&2
		return 1
	}

	host="$(code_only "$file" |
		sed -n 's/^[[:space:]]\+hostname[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')"
	zone="$(tfvars_scalar "$file" dns_managed_zone)"

	[ -z "$host" ] || {
		echo "${file} sets hostname = \"${host}\"." >&2
		echo "That instantiates the full public HTTPS frontend. This" >&2
		echo "environment is deliberately private: IAP TCP forwarding only," >&2
		echo "no public listener of any kind." >&2
		if [ -z "$zone" ]; then
			echo "Worse, dns_managed_zone is empty, so no DNS record is created" >&2
			echo "either — the managed certificate would sit in PROVISIONING" >&2
			echo "against a name nothing resolves, forever." >&2
		fi
		return 1
	}
	[ -z "$zone" ] || {
		echo "${file} sets dns_managed_zone = \"${zone}\", but no Cloud DNS" >&2
		echo "managed zone exists in this project." >&2
		return 1
	}
	return 0
}

@test "the real input instantiates no public edge: hostname and zone both empty" {
	assert_no_public_edge "${REAL_TFVARS}"
}

@test "the module proof that an empty hostname builds no frontend still exists" {
	# The textual guard above asserts the INPUT. This asserts the evaluated
	# proof that the input has the effect claimed for it, and that the proof
	# has not been deleted along with the behaviour. Without it, "hostname is
	# empty" would be an assertion about a string with nothing tying it to the
	# absence of a public listener.
	local tftest="${REPO_ROOT}/terraform/modules/edge/tests/tls_frontend.tftest.hcl"
	[ -f "$tftest" ] || {
		echo "the evaluated no-frontend proof is missing: ${tftest}" >&2
		return 1
	}
	grep -qF 'empty_hostname_plans_no_public_frontend_at_all' "$tftest" || {
		echo "${tftest} no longer proves that an empty hostname plans no" >&2
		echo "public frontend. The tfvars guard alone is then a claim about a" >&2
		echo "string, not about what gets built." >&2
		return 1
	}
}

@test "the IAP tunnel path is open on 22, and on the app port separately" {
	# The reachability story depends on firewall rules this chunk does not own,
	# so it is asserted rather than assumed. `allow_iap_ssh` permits the IAP
	# TCP-forwarding range on port 22 ONLY; the application is reached through a
	# second, separately-named rule, `allow_iap_app_port`, on the environment's
	# app_port and nothing else. Two rules rather than two ports on one rule:
	# SSH and the application are different exposures, and a rule named
	# "allow-iap-ssh" that also opened 30754 would be a rule whose name lies.
	local net="${REPO_ROOT}/terraform/modules/network/main.tf"
	local netvars="${REPO_ROOT}/terraform/modules/network/variables.tf"
	[ -f "$net" ]
	[ -f "$netvars" ]

	# Both files, and comments stripped. The range is the default of
	# `var.iap_source_range` and now lives in variables.tf, so a grep pinned to
	# main.tf would be satisfied by the comment that explains the rule — which
	# is a check that has quietly stopped checking anything.
	local code
	code="$(sed -e 's/[[:space:]]*#.*$//' "$net" "$netvars")"
	printf '%s\n' "$code" | grep -qF '35.235.240.0/20' || {
		echo "the IAP TCP-forwarding range is not in modules/network's" >&2
		echo "executable configuration; the tunnel access path would not work." >&2
		return 1
	}

	# The SSH rule exists and is scoped to 22 alone. If the app port ever
	# appears here, the split above has been undone.
	local ports
	ports="$(sed -n '/resource "google_compute_firewall" "allow_iap_ssh"/,/^}/p' "$net" |
		sed -n 's/.*ports[[:space:]]*=[[:space:]]*\(.*\)/\1/p')"
	[ -n "$ports" ] || {
		echo "could not parse the ports of allow_iap_ssh; check would be vacuous" >&2
		return 1
	}
	[[ "$ports" == *'"22"'* ]] || {
		echo "allow_iap_ssh no longer opens port 22: ${ports}" >&2
		return 1
	}

	# And the app-port rule is present and derived, not hardcoded.
	local app_ports
	app_ports="$(sed -n '/resource "google_compute_firewall" "allow_iap_app_port"/,/^}/p' "$net" |
		sed -n 's/.*ports[[:space:]]*=[[:space:]]*\(.*\)/\1/p')"
	[ -n "$app_ports" ] || {
		echo "allow_iap_app_port is missing or has no ports; the dashboard is" >&2
		echo "then unreachable over IAP." >&2
		return 1
	}
	[[ "$app_ports" == *'var.app_port'* ]] || {
		echo "allow_iap_app_port does not derive its port from var.app_port:" >&2
		echo "  ${app_ports}" >&2
		return 1
	}
}

@test "the no-public-edge guard fails when a hostname is set without a zone" {
	# The exact future edit this exists to catch: a hostname added while
	# dns_managed_zone stays empty. That builds a real managed certificate for
	# a name with no record to validate it, and it sits in PROVISIONING
	# indefinitely.
	local mutated="${BATS_TEST_TMPDIR}/hostname-no-zone.tfvars"
	sed 's|^\([[:space:]]*\)hostname = ""|\1hostname = "demo-1.example.invalid"|' \
		"${REAL_TFVARS}" >"$mutated"

	if diff -q "${REAL_TFVARS}" "$mutated" >/dev/null; then
		echo "the mutation changed nothing: its pattern no longer matches" >&2
		return 1
	fi

	assert_no_public_edge "${REAL_TFVARS}" || {
		echo "the unmutated real input already fails the no-public-edge guard" >&2
		return 1
	}
	run assert_no_public_edge "$mutated"
	[ "$status" -ne 0 ] || {
		echo "the guard passed a tfvars that sets a hostname. It cannot fail," >&2
		echo "so it has never been protecting anything." >&2
		return 1
	}
	# Assert on the message: it must name the certificate trap, not merely
	# exit non-zero, or it would pass for any unrelated failure.
	[[ "$output" == *"PROVISIONING"* ]] || {
		echo "the guard failed without naming the never-validating certificate" >&2
		echo "$output" >&2
		return 1
	}
}

@test "the no-public-edge guard fails when the keys are absent entirely" {
	# The vacuity direction. A file with no hostname key at all would make a
	# naive grep find nothing, which reads exactly like "correctly empty".
	local empty="${BATS_TEST_TMPDIR}/no-keys.tfvars"
	printf 'project_id = "sl-port-over-sandbox"\n' >"$empty"

	run assert_no_public_edge "$empty"
	[ "$status" -ne 0 ] || {
		echo "the guard passed a file that sets neither key" >&2
		return 1
	}
	[[ "$output" == *"vacuous"* ]] || {
		echo "the guard failed for some reason other than the absent keys" >&2
		echo "$output" >&2
		return 1
	}
}
