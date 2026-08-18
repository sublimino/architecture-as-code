#!/usr/bin/env bats
#
# The environment contract, executed rather than grepped.
#
# ─── Why this suite runs `terraform plan` and not `terraform validate` ───────
#
# `terraform validate -var-file=x.tfvars` ACCEPTS the flag, IGNORES the file,
# and exits 0. It does not evaluate variables at all, so it cannot evaluate a
# `validation` block. Measured on Terraform v1.15.8 against a root whose key
# regex the tfvars violates:
#
#     $ terraform validate -var-file=bad.tfvars ; echo $?
#     Success! The configuration is valid.
#     0
#
# A suite built on that call would be twenty green tests measuring nothing —
# every negative case "passing" because the assertion never ran. `plan` does
# evaluate variables, exits non-zero, and names the rule that fired.
#
# ─── Why `plan` is safe here, given live gcloud credentials on this box ──────
#
# The root this suite plans is a THROWAWAY COPY under $BATS_FILE_TMPDIR, not
# the real tree. The copy deliberately omits `versions.tf`, `providers.tf` and
# `backend.tf`, so it declares no provider, no backend and no resource. There
# is nothing for a plan to reach: no API is called, no credential is read, no
# state is touched. `setup_file` proves the no-provider property rather than
# asserting it — see the filesystem_mirror guard below.
#
# ─── Baseline-green before mutation-red, every single time ───────────────────
#
# A validation failure caused by an unrelated syntax error in a fixture reads
# exactly like a correctly-firing rule: non-zero exit, an error on stderr, a
# green test. Every negative test therefore plans `base.tfvars` FIRST and
# requires it to succeed, then plans the mutant. Each mutant is base.tfvars
# with one thing changed, so if the baseline is green and the mutant is red,
# the change is what did it.
#
# And each negative test declares the EXACT set of rule tags it expects. A tag
# outside that set fails the test even though the plan failed, because a fixture
# that trips two rules is a fixture that stopped testing the one it was named
# for.

# ─── Why every negated assertion is written `! cmd || { ...; return 1; }` ────
#
# Under bash `errexit`, which bats enables, a command whose status is inverted
# with `!` is EXEMPT from erroring out. So a bare `! grep forbidden_thing file`
# that is not the last line of a test is a DEAD ASSERTION: grep finds the
# forbidden thing, `!` turns that into a non-zero status, and the test carries
# on and passes. Three assertions in this file were dead exactly that way, and
# they were found only by planting a violation and watching the suite stay
# green — which is the whole argument for falsifying a guard rather than
# trusting it. Every negation below therefore carries an explicit `|| { return
# 1; }` and says what it caught.

setup_file() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export repo_root
	export tf_src="${repo_root}/terraform"
	export fixtures="${repo_root}/test/fixtures/terraform/envmodel"
	export tfvars="${fixtures}/tfvars"

	# ── Presence assertions. CONTRACT.md §6: no test that passes vacuously. ──
	# Everything below greps, copies or plans these files. If one is missing,
	# the copy is empty, the plan finds no rules, and every negative test goes
	# green having proved nothing. Fail here instead.
	local f
	for f in \
		"${tf_src}/modules/env-contract/variables.tf" \
		"${tf_src}/modules/env-contract/main.tf" \
		"${tf_src}/modules/env-contract/outputs.tf" \
		"${tf_src}/modules/env-contract/versions.tf" \
		"${tf_src}/environments/variables.tf" \
		"${tf_src}/environments/main.tf" \
		"${tf_src}/environments/outputs.tf" \
		"${tf_src}/environments/versions.tf" \
		"${tf_src}/environments/backend.tf" \
		"${tf_src}/environments/providers.tf" \
		"${tf_src}/environments/demo-1.tfvars.example" \
		"${tf_src}/environments/ci-1.tfvars.example" \
		"${tf_src}/environments/demo-1-and-demo-2.tfvars.example" \
		"${tf_src}/modules/env-contract/tests/environment_contract.tftest.hcl" \
		"${tf_src}/environments/tests/root_contract.tftest.hcl" \
		"${tfvars}/base.tfvars"; do
		[ -f "$f" ] || {
			echo "MISSING under test: $f" >&2
			return 1
		}
	done

	# ── Assert the mechanism exists before testing the mechanism. ──
	# A suite that executes validation rules against a tree that has no
	# validation rules reports "plan succeeded" for the baseline and "plan
	# failed" for nothing at all. Count the blocks.
	local nrules
	nrules="$(grep -c '^  validation {' "${tf_src}/modules/env-contract/variables.tf")"
	[ "$nrules" -ge 11 ] || {
		echo "expected >= 11 validation blocks in the env-contract, found ${nrules}" >&2
		return 1
	}

	# ── Build the throwaway root, mirroring the real layout. ──
	# The layout is mirrored (environments/ beside modules/env-contract/) so
	# that `source = "../modules/env-contract"` in the copied main.tf resolves
	# without editing it. Editing the copy is the thing to avoid: a rewritten
	# module path is one keystroke from a rewritten validation rule, and then
	# the suite is testing a file that does not ship.
	export work="${BATS_FILE_TMPDIR}/tree"
	mkdir -p "${work}/environments" "${work}/modules/env-contract"
	cp "${tf_src}/modules/env-contract/variables.tf" \
		"${tf_src}/modules/env-contract/main.tf" \
		"${tf_src}/modules/env-contract/outputs.tf" \
		"${work}/modules/env-contract/"
	cp "${tf_src}/environments/variables.tf" \
		"${tf_src}/environments/main.tf" \
		"${tf_src}/environments/outputs.tf" \
		"${work}/environments/"

	# versions.tf / providers.tf / backend.tf are omitted ON PURPOSE, and their
	# absence is what makes the plan provider-free, credential-free and
	# offline. Prove they were not copied — a future `cp -r` would silently
	# reintroduce a google provider requirement and turn this suite into a
	# network-dependent one that fails on a train.
	local unwanted
	for unwanted in versions.tf providers.tf backend.tf; do
		[ ! -e "${work}/environments/${unwanted}" ] || {
			echo "fixture root must not contain ${unwanted}" >&2
			return 1
		}
	done
	[ ! -e "${work}/modules/env-contract/versions.tf" ] || {
		echo "fixture module must not contain versions.tf" >&2
		return 1
	}
	! grep -rq 'required_providers' "${work}" || {
		echo "fixture tree declares required_providers; it is no longer offline" >&2
		return 1
	}

	# ── Enforce offline, do not merely claim it. ──
	# A provider_installation stanza naming ONLY a filesystem mirror, at a path
	# that does not exist, removes the direct registry install method entirely.
	# If the fixture root ever needs a plugin, `init` fails here with "no
	# available releases" instead of quietly reaching the network on the one
	# machine that happens to have it. Verified: adding a google provider
	# requirement to a root under this config fails init.
	export TF_CLI_CONFIG_FILE="${BATS_FILE_TMPDIR}/offline.tfrc"
	cat >"${TF_CLI_CONFIG_FILE}" <<-EOF
		provider_installation {
		  filesystem_mirror { path = "${BATS_FILE_TMPDIR}/no-such-mirror" }
		}
	EOF
	export CHECKPOINT_DISABLE=1
	export TF_IN_AUTOMATION=1
	export TF_INPUT=0

	terraform -chdir="${work}/environments" init -backend=false -input=false -no-color >"${BATS_FILE_TMPDIR}/init.log" 2>&1 || {
		cat "${BATS_FILE_TMPDIR}/init.log" >&2
		return 1
	}
}

# Plan the throwaway root against a tfvars file. Never touches the real tree.
tf_plan() {
	terraform -chdir="${work}/environments" plan \
		-input=false -no-color -lock=false -var-file="$1" 2>&1
}

# Every distinct rule tag named in a plan's output, sorted and space-separated.
rule_tags() {
	printf '%s\n' "$1" |
		grep -oE '(ENV|PROJECT)-RULE-[0-9]+[A-Z]*-[A-Z0-9-]+' |
		sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The one assertion shape every negative test uses.
#
#   assert_rejected <fixture-basename> <expected tag> [more expected tags...]
#
# 1. base.tfvars must plan cleanly. Without this the test cannot tell a firing
#    rule from a broken fixture root.
# 2. The mutant must plan non-zero.
# 3. The set of tags that fired must equal the declared set exactly — not merely
#    contain the headline one. A mutant that trips an unrelated rule as well has
#    stopped being a test of the rule it is named for.
assert_rejected() {
	local name="$1"
	shift
	local expected
	expected="$(printf '%s\n' "$@" | sort -u | tr '\n' ' ' | sed 's/ $//')"

	[ -f "${tfvars}/${name}" ] || {
		echo "missing fixture: ${tfvars}/${name}" >&2
		return 1
	}

	local base_out base_rc
	base_out="$(tf_plan "${tfvars}/base.tfvars")" && base_rc=0 || base_rc=$?
	[ "$base_rc" -eq 0 ] || {
		echo "BASELINE NOT GREEN — every rejection below this line is uninterpretable." >&2
		echo "$base_out" >&2
		return 1
	}

	local out rc
	out="$(tf_plan "${tfvars}/${name}")" && rc=0 || rc=$?
	[ "$rc" -ne 0 ] || {
		echo "expected ${name} to be REJECTED, but the plan succeeded" >&2
		return 1
	}

	local got
	got="$(rule_tags "$out")"
	[ "$got" = "$expected" ] || {
		echo "rule tags fired: [${got}]" >&2
		echo "rule tags wanted: [${expected}]" >&2
		echo "$out" >&2
		return 1
	}
}

# Evaluate an expression against the throwaway root with a tfvars loaded.
tf_console() {
	printf '%s\n' "$2" | terraform -chdir="${work}/environments" console -var-file="$1" 2>&1 | tr -d '\r' | tail -1
}

# ─── The harness itself must be honest before anything it reports counts ─────

@test "fixture root is a byte-identical copy of the real validation sources" {
	# The entire value of this suite is that it executes the code that ships.
	# If the copy drifts — a hand-edit to make a test pass, a stale fixture
	# committed alongside a changed rule — the suite silently starts grading a
	# file nobody deploys, and it will stay green while the real tree rots.
	cmp "${tf_src}/modules/env-contract/variables.tf" "${work}/modules/env-contract/variables.tf"
	cmp "${tf_src}/modules/env-contract/main.tf" "${work}/modules/env-contract/main.tf"
	cmp "${tf_src}/modules/env-contract/outputs.tf" "${work}/modules/env-contract/outputs.tf"
	cmp "${tf_src}/environments/variables.tf" "${work}/environments/variables.tf"
	cmp "${tf_src}/environments/main.tf" "${work}/environments/main.tf"
	cmp "${tf_src}/environments/outputs.tf" "${work}/environments/outputs.tf"
}

@test "the valid baseline plans cleanly" {
	# Read this as the suite's own calibration. If this test is red, every
	# assert_rejected below is meaningless rather than merely wrong.
	run tf_plan "${tfvars}/base.tfvars"
	[ "$status" -eq 0 ]
}

@test "every mutant fixture differs from the baseline, and differs only a little" {
	# A fixture accidentally identical to base.tfvars would make its test fail
	# loudly (plan succeeds where a rejection was expected), which is fine. The
	# dangerous direction is a fixture that has drifted far from base: it may
	# still be rejected, but no longer for the reason its name claims.
	# Comments are stripped before diffing. Each mutant carries its own header
	# explaining what it mutates, so a raw diff is dominated by prose and the
	# threshold would be measuring how chatty the header is rather than how big
	# the mutation is. Compare the values, which is what Terraform reads.
	local f n
	for f in "${tfvars}"/*.tfvars; do
		case "$(basename "$f")" in
		base.tfvars | two-environment*.tfvars | environments-empty.tfvars) continue ;;
		esac
		n="$(diff \
			<(grep -vE '^\s*#|^\s*$' "${tfvars}/base.tfvars") \
			<(grep -vE '^\s*#|^\s*$' "$f") | grep -cE '^[<>]')"
		[ "$n" -gt 0 ] || {
			echo "$f is identical to base.tfvars" >&2
			return 1
		}
		[ "$n" -le 4 ] || {
			echo "$f diverges from base.tfvars by $n lines; it is no longer a single mutation" >&2
			return 1
		}
	done
}

# ─── Key format: ISC-50, ISC-65..69 ─────────────────────────────────────────

@test "key demo-0 is rejected (zero is not a valid ordinal)" {
	assert_rejected key-demo-0.tfvars ENV-RULE-01-KEY-FORMAT
}

@test "key demo-01 is rejected (leading zero)" {
	assert_rejected key-demo-01.tfvars ENV-RULE-01-KEY-FORMAT
}

@test "key prod-1 is rejected (prod is not a permitted kind)" {
	# Two rules fire and both are correct: the key does not match the regex,
	# and "prod-1" does not start with its declared kind "demo". Declaring both
	# is the honest expectation; declaring only the first would let this fixture
	# start failing for a third reason without the suite noticing.
	assert_rejected key-prod-1.tfvars ENV-RULE-01-KEY-FORMAT ENV-RULE-03-KEY-KIND-AGREE
}

@test "key demo_1 is rejected (underscore, not hyphen)" {
	assert_rejected key-demo-underscore.tfvars ENV-RULE-01-KEY-FORMAT ENV-RULE-03-KEY-KIND-AGREE
}

@test "keys demo-1 and ci-2 are accepted" {
	# base.tfvars IS demo-1 plus ci-2. The acceptance case is the baseline, so
	# it is impossible for the accept and reject halves of the key rule to be
	# graded against different inputs.
	grep -q '"demo-1" = {' "${tfvars}/base.tfvars"
	grep -q '"ci-2" = {' "${tfvars}/base.tfvars"
	run tf_plan "${tfvars}/base.tfvars"
	[ "$status" -eq 0 ]
}

# ─── Kind and key/kind agreement: ISC-49, ISC-51 ────────────────────────────

@test "kind outside the demo/ci enum is rejected" {
	assert_rejected kind-enum.tfvars ENV-RULE-02-KIND-ENUM ENV-RULE-03-KEY-KIND-AGREE
}

@test "a key prefix disagreeing with its kind is rejected" {
	assert_rejected kind-prefix-disagree.tfvars ENV-RULE-03-KEY-KIND-AGREE
}

# ─── Cross-environment collisions: ISC-52, ISC-53, ISC-70, ISC-71 ───────────

@test "duplicate hostnames across two entries are rejected" {
	assert_rejected hostname-duplicate.tfvars ENV-RULE-04-HOSTNAME-UNIQUE
}

@test "duplicate subnet CIDRs across two entries are rejected" {
	assert_rejected subnet-duplicate.tfvars ENV-RULE-05-SUBNET-UNIQUE
}

@test "overlapping subnet CIDRs are rejected even though the strings differ" {
	# 10.10.0.0/16 CONTAINS 10.10.1.0/24. String uniqueness (rule 5) cannot see
	# that; the /24 constraint can, because two /24s intersect if and only if
	# they are identical. This is the case a uniqueness check alone would let
	# through, and two environments sharing address space is a routing failure
	# that surfaces months later as intermittent cross-talk.
	assert_rejected subnet-overlap.tfvars ENV-RULE-06B-SUBNET-PREFIX-24
}

@test "a subnet outside RFC1918 is rejected" {
	assert_rejected subnet-not-rfc1918.tfvars ENV-RULE-06-SUBNET-RFC1918
}

# ─── Allowlists: ISC-55, ISC-56, ISC-57 ─────────────────────────────────────

@test "a malformed IPv4 allowlist entry is rejected" {
	assert_rejected ipv4-not-cidr.tfvars ENV-RULE-07-IPV4-CIDR
}

@test "a malformed IPv6 allowlist entry is rejected" {
	assert_rejected ipv6-not-cidr.tfvars ENV-RULE-08-IPV6-CIDR
}

@test "0.0.0.0/0 in allowed_ipv4 is rejected" {
	assert_rejected ipv4-any.tfvars ENV-RULE-09-NO-ANY-IPV4
}

@test "::/0 in allowed_ipv6 is rejected" {
	assert_rejected ipv6-any.tfvars ENV-RULE-10-NO-ANY-IPV6
}

# ─── Ports: ISC-47..49 object typing, rule 11 ───────────────────────────────

@test "app_port 0 is rejected" {
	assert_rejected port-zero.tfvars ENV-RULE-11-APP-PORT-RANGE
}

@test "app_port 70000 is rejected" {
	assert_rejected port-70000.tfvars ENV-RULE-11-APP-PORT-RANGE
}

# ─── project_id: ISC-58, ISC-59 ─────────────────────────────────────────────

@test "project_id is required and has no default" {
	# ISC-58 is a property of the declaration, not of a plan, so it is checked
	# by reading the block rather than by executing it: extract the project_id
	# variable block and assert no `default` line inside it. A default here
	# would mean a forgotten -var-file applies to somebody else's project.
	run awk '/^variable "project_id"/{f=1} f&&/^}/{f=0} f' "${tf_src}/environments/variables.tf"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	! printf '%s\n' "$output" | grep -qE '^\s*default\s*='
}

@test "a project_id containing example is rejected" {
	assert_rejected project-example.tfvars PROJECT-RULE-01-PLACEHOLDER
}

@test "the CHANGEME project_id placeholder is rejected" {
	# Both rules fire: it reads as a placeholder AND it is not a well-formed
	# project ID (leading capitals). An unedited copy of the shipped example
	# therefore cannot reach a plan, which is the entire purpose of shipping the
	# example with a value that is invalid rather than merely wrong.
	assert_rejected project-changeme.tfvars PROJECT-RULE-01-PLACEHOLDER PROJECT-RULE-02-FORMAT
}

@test "a too-short project_id is rejected" {
	assert_rejected project-short.tfvars PROJECT-RULE-01-PLACEHOLDER PROJECT-RULE-02-FORMAT
}

# ─── Empty map and target_env: ISC-54, CONTRACT.md §5a ──────────────────────

@test "an empty environments map is rejected" {
	# Only rule 12 fires: Terraform skips the target_env validation once the
	# variable it depends on has itself failed. That is fine — the plan aborts
	# either way — but the expectation is written to match what actually
	# happens rather than what would be tidy.
	assert_rejected environments-empty.tfvars ENV-RULE-12-NON-EMPTY
}

@test "a target_env naming a key absent from the map is rejected" {
	# The failure this prevents is the quietest one in the design. Without the
	# rule, a typo'd target_env filters the map down to nothing, and a
	# for_each over nothing is a SUCCESSFUL plan — one that proposes destroying
	# every resource already in that environment's state.
	assert_rejected target-env-missing.tfvars ENV-RULE-13-TARGET-ENV-EXISTS
}

@test "target_env selects exactly one environment, and which one it selects" {
	# Rejecting a bad target_env is half the property. The other half is that a
	# good one actually narrows the apply — a target_env that validated and
	# then instantiated both environments would close nothing.
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'join(",", keys(local.target_environments))')" = '"demo-1"' ]
	[ "$(tf_console "${tfvars}/two-environment-target-demo-2.tfvars" 'join(",", keys(local.target_environments))')" = '"demo-2"' ]
	# ...while the whole map stays in scope, which is what keeps the
	# cross-environment collision rules able to see a collision at all.
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'join(",", module.env_contract.environment_keys)')" = '"demo-1,demo-2"' ]
}

# ─── Extensibility: ISC-75 ──────────────────────────────────────────────────

@test "a valid two-environment tfvars plans cleanly" {
	run tf_plan "${tfvars}/two-environment.tfvars"
	[ "$status" -eq 0 ]
}

@test "gaining demo-2 adds tfvars lines and modifies nothing" {
	# The textual half of the extensibility proof. `diff` hunk types are the
	# assertion: `a` is an addition, `d` a deletion, `c` a modification. If the
	# second-environment example required editing or removing any line of the
	# first, at least one `d` or `c` hunk would appear here, and "add an entry"
	# would really be "add an entry and adjust some things".
	local d
	d="$(diff "${tf_src}/environments/demo-1.tfvars.example" "${tf_src}/environments/demo-1-and-demo-2.tfvars.example" || true)"
	[ -n "$d" ]
	! printf '%s\n' "$d" | grep -qE '^[0-9,]+[dc][0-9,]+' || {
		echo "the two-environment example deletes or modifies lines of the first; it is not purely additive" >&2
		printf '%s\n' "$d" >&2
		return 1
	}
	printf '%s\n' "$d" | grep -q '"demo-2"' || {
		echo "the two-environment example does not actually add a demo-2 entry" >&2
		return 1
	}
}

@test "gaining demo-2 requires no Terraform source change at all" {
	# The executable half. Hash every .tf file in the tree, resolve a
	# one-environment and a two-environment map through the real module and
	# root, then hash again. An unchanged digest set proves the second
	# environment cost zero .tf edits — no new module block, no copied file, no
	# per-environment branch.
	local before after
	before="$(find "${tf_src}" -name '*.tf' -type f -exec sha256sum {} + | sort)"
	run tf_plan "${tfvars}/base.tfvars"
	[ "$status" -eq 0 ]
	run tf_plan "${tfvars}/two-environment.tfvars"
	[ "$status" -eq 0 ]
	after="$(find "${tf_src}" -name '*.tf' -type f -exec sha256sum {} + | sort)"
	[ "$before" = "$after" ]

	# And the module resolves the new key without being told about it.
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'module.env_contract.name_prefix["demo-2"]')" = '"sl-demo-2"' ]
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'module.env_contract.mandatory_labels["demo-2"]["environment"]')" = '"demo-2"' ]
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'module.env_contract.mandatory_labels["demo-2"]["managed-by"]')" = '"terraform"' ]
	[ "$(tf_console "${tfvars}/two-environment.tfvars" 'module.env_contract.mandatory_labels["demo-2"]["component"]')" = '"signalloom"' ]
}

# ─── Committed-secret hygiene: ISC-74, CONTRACT.md §6 ───────────────────────

@test "no .tfvars file is committed under terraform/, only .tfvars.example" {
	# A real .tfvars is where a real project ID, a real hostname and a real
	# office IP range would end up. The examples are the only committed form.
	run find "${tf_src}" -name '*.tfvars' -type f
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "committed example and fixture inputs contain no real project, domain or address" {
	local f
	for f in "${tf_src}"/environments/*.tfvars.example "${tfvars}"/*.tfvars; do
		# Documentation ranges and .invalid only. RFC5737 / RFC3849 / RFC2606.
		! grep -nE '\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" |
			grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.10\.|0\.0\.0\.0/0' || {
			echo "non-documentation IPv4 literal in $f" >&2
			return 1
		}
		! grep -qE 'https?://|\.(com|net|org|io|dev|co\.uk)\b' "$f" || {
			echo "real-looking domain in $f" >&2
			return 1
		}
		! grep -q '/home/andy' "$f" || {
			echo "absolute home path in $f" >&2
			return 1
		}
	done
}

@test "no committed Terraform source contains an absolute home path or an any-source CIDR" {
	# CONTRACT.md §6 anti-criteria, asserted against the source this chunk owns.
	#
	# ─── Scoped to committed source, deliberately ───
	#
	# A bare `grep -r` over these directories also walks `.terraform/`, which
	# holds ~700MB of downloaded provider binaries — and those binaries contain
	# the literal string `access_config`, because the provider implements it.
	# The guard then passes or fails depending on whether somebody happened to
	# run `init` recently, which is a test that reports on the local machine
	# rather than on the code. Caught by this suite going red after a validate.
	#
	# The allowlist fixtures and the negative `.tftest.hcl` runs that DO contain
	# 0.0.0.0/0 exist precisely to be rejected, so the CIDR check is scoped to
	# the module's non-test source. A rule that could not tell a rejected input
	# from a shipped default would have to be weakened until it caught nothing.
	local src_globs=(--include='*.tf' --include='*.tftest.hcl' --exclude-dir='.terraform')
	! grep -rn "${src_globs[@]}" '/home/andy' "${tf_src}/modules/env-contract" "${tf_src}/environments" || {
		echo "absolute home path in committed Terraform source" >&2
		return 1
	}
	! grep -rn "${src_globs[@]}" 'access_config\|google_service_account_key\|google_project_iam_policy' \
		"${tf_src}/modules/env-contract" "${tf_src}/environments" || {
		echo "CONTRACT.md §6 forbidden construct in committed Terraform source" >&2
		return 1
	}
	! grep -n '0\.0\.0\.0/0\|::/0' \
		"${tf_src}/modules/env-contract/main.tf" \
		"${tf_src}/modules/env-contract/outputs.tf" \
		"${tf_src}/environments/main.tf" \
		"${tf_src}/environments/outputs.tf" || {
		echo "an any-source CIDR appears in shipping Terraform source" >&2
		return 1
	}
}

@test "every native test file mocks both providers and never applies" {
	# CONTRACT.md §7a makes `.tftest.hcl` the primary correctness surface, which
	# moves the blast radius: a `run` block reaching a real provider on a box
	# with live gcloud credentials is not a failing test, it is billable
	# infrastructure. `mock_provider` is what prevents that and `command = plan`
	# is what prevents state being written, so both are asserted per file rather
	# than trusted.
	#
	# This is a whole-tree absence property — §7a's own table puts exactly this
	# class of assertion in bats, because `terraform test` can only see what a
	# given plan evaluated, never what no configuration anywhere contains.
	local files f
	mapfile -t files < <(find "${tf_src}/modules/env-contract" "${tf_src}/environments" -name '*.tftest.hcl' -type f)
	[ "${#files[@]}" -ge 2 ] || {
		echo "expected at least two .tftest.hcl files, found ${#files[@]}" >&2
		return 1
	}
	for f in "${files[@]}"; do
		grep -q '^mock_provider "google" {}' "$f" || {
			echo "$f does not mock the google provider" >&2
			return 1
		}
		grep -q '^mock_provider "google-beta" {}' "$f" || {
			echo "$f does not mock the google-beta provider" >&2
			return 1
		}
		! grep -qE '^\s*command\s*=\s*apply' "$f" || {
			echo "$f uses command = apply; only plan is permitted" >&2
			return 1
		}
		# Every negative run must be answered by a positive one somewhere in the
		# file. A file of nothing but expect_failures cannot distinguish "the
		# rule fired" from "the configuration was broken all along".
		if grep -q 'expect_failures' "$f"; then
			grep -q '^\s*assert {' "$f" || {
				echo "$f has expect_failures but no positive assertion to calibrate against" >&2
				return 1
			}
		fi
	done
}

# ─── Structural criteria the plan cannot express: ISC-47, ISC-48, ISC-60 ────

@test "the environments variable is a single explicitly-typed object map" {
	# ISC-47 and ISC-48. `any` here would make every downstream module's inputs
	# unchecked, and would make ten of the eleven validation rules unreachable
	# because there would be no field to read.
	grep -q 'type = map(object({' "${tf_src}/modules/env-contract/variables.tf"
	! grep -qE 'type\s*=\s*map\(any\)|type\s*=\s*any' "${tf_src}/modules/env-contract/variables.tf" || {
		echo "the environments map is typed 'any'; every downstream module input becomes unchecked" >&2
		return 1
	}
	[ "$(grep -c '^variable "environments"' "${tf_src}/modules/env-contract/variables.tf")" -eq 1 ]
}

@test "name_prefix and the mandatory labels are computed per environment key" {
	# ISC-60, ISC-62, ISC-63, ISC-64 at the contract layer. The per-resource
	# halves of 61..64 belong to the modules that own resources; this module
	# has none, and claiming them here would be claiming somebody else's work.
	grep -q 'name_prefix = { for k, v in var.environments : k => "sl-${k}" }' "${tf_src}/modules/env-contract/main.tf"
	grep -q 'managed-by  = "terraform"' "${tf_src}/modules/env-contract/main.tf"
	grep -q 'component   = "signalloom"' "${tf_src}/modules/env-contract/main.tf"
	grep -q 'environment = k' "${tf_src}/modules/env-contract/main.tf"
}

@test "the environments root declares an empty gcs backend and no hand-completed prefix" {
	# CONTRACT.md §5: the empty form is what makes it impossible to reach apply
	# without having named the environment on the init command line.
	#
	# Comments are stripped first. backend.tf's rationale block quotes the
	# `-backend-config=prefix=...` invocation an operator must type, and an
	# assertion that cannot tell a documented command from a committed setting
	# fails on correct code — which trains people to loosen it until it catches
	# nothing.
	local body
	body="$(grep -vE '^\s*#|^\s*$' "${tf_src}/environments/backend.tf")"
	printf '%s\n' "$body" | grep -q 'backend "gcs" {}'
	! printf '%s\n' "$body" | grep -qE 'bucket\s*=|prefix\s*='
}
