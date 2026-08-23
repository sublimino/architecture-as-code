#!/usr/bin/env bats
#
# What a plan cannot see.
#
# CONTRACT.md §7a made native `terraform test` the primary correctness surface,
# and the eleven validation rules moved there —
# `terraform/modules/env-contract/tests/environment_contract.tftest.hcl` and
# `terraform/environments/tests/root_contract.tftest.hcl` execute them against
# the evaluated configuration with `expect_failures`. This file was shrunk to
# what `terraform test` structurally cannot reach:
#
#   1. Absence across the whole tree. `terraform test` sees what a given plan
#      evaluated, never what no configuration anywhere contains. ISC-333, 335,
#      347 and 355 are all of this shape and are all asserted here.
#   2. Text properties of files that are inputs rather than configuration —
#      the `.tfvars.example` files, which are never planned.
#   3. The extensibility proof, which is a statement about a diff between two
#      committed files.
#   4. Presence of a rule that no input can isolate — see the ENV-RULE-02 note
#      below, which is the one gap the native suites genuinely cannot close.
#
# ─── Why every negated assertion is written `! cmd || { ...; return 1; }` ────
#
# Under bash `errexit`, which bats enables, a command whose status is inverted
# with `!` is EXEMPT from erroring out. So a bare `! grep forbidden_thing file`
# that is not the last line of a test is a DEAD ASSERTION: grep finds the
# forbidden thing, `!` turns that into a non-zero status, and the test carries
# on and passes. Three assertions in the previous version of this file were
# dead exactly that way, and were found only by planting a violation and
# watching the suite stay green. Every negation below carries an explicit
# `|| { return 1; }` and says what it caught.

# Strip whole-line comments. Several assertions below are about VALUES, and
# the files under test document their own rules in prose — ci-1.tfvars.example
# explains why its allowlist is populated by naming 0.0.0.0/0, and the tftest
# headers explain why providers are mocked by naming credentials. A guard that
# cannot tell a documented counter-example from a committed value fails on
# correct code, and the fix people reach for is to delete the comment or weaken
# the guard. Trailing comments are deliberately NOT stripped: a value hidden
# after a `#` on a code line still trips the check, which is the safe direction.
code_only() {
	grep -vE '^[[:space:]]*(#|//)|^[[:space:]]*$' "$1" || true
}

setup_file() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export repo_root
	export tf_src="${repo_root}/terraform"

	# ── Presence before behaviour. CONTRACT.md §6: no test that passes
	# vacuously. Every assertion below greps or diffs one of these; a missing
	# file makes a grep find nothing, which reads identical to a clean tree.
	local f
	for f in \
		"${tf_src}/modules/env-contract/variables.tf" \
		"${tf_src}/modules/env-contract/main.tf" \
		"${tf_src}/modules/env-contract/outputs.tf" \
		"${tf_src}/modules/env-contract/versions.tf" \
		"${tf_src}/modules/env-contract/tests/environment_contract.tftest.hcl" \
		"${tf_src}/environments/variables.tf" \
		"${tf_src}/environments/main.tf" \
		"${tf_src}/environments/outputs.tf" \
		"${tf_src}/environments/versions.tf" \
		"${tf_src}/environments/backend.tf" \
		"${tf_src}/environments/providers.tf" \
		"${tf_src}/environments/tests/root_contract.tftest.hcl" \
		"${tf_src}/environments/demo-1.tfvars.example" \
		"${tf_src}/environments/ci-1.tfvars.example" \
		"${tf_src}/environments/demo-1-and-demo-2.tfvars.example"; do
		[ -f "$f" ] || {
			echo "MISSING under test: $f" >&2
			return 1
		}
	done
}

# ─── ISC-324, ISC-325, ISC-355 — the native surface exists at all ────────────

@test "every owned directory with .tf rules ships a tests/ directory" {
	# ISC-355. If a tests/ directory disappears, `terraform test` reports
	# "Success! 0 passed" and the sweep goes green having run nothing. That is
	# the quietest possible way for a primary correctness surface to vanish, so
	# its existence is asserted from outside itself.
	local d n
	for d in "${tf_src}/modules/env-contract" "${tf_src}/environments"; do
		[ -d "${d}/tests" ] || {
			echo "${d} has no tests/ directory" >&2
			return 1
		}
		n="$(find "${d}/tests" -name '*.tftest.hcl' -type f | wc -l)"
		[ "$n" -ge 1 ] || {
			echo "${d}/tests contains no .tftest.hcl files" >&2
			return 1
		}
	done
}

@test "every .tftest.hcl mocks both providers, never applies, and is calibrated" {
	# ISC-332, ISC-333, ISC-334, ISC-335, ISC-347 — all whole-tree absence
	# properties, which is why they live here and not in a tftest.
	#
	# The stakes are higher than they look. This machine has working gcloud
	# credentials, so a `run` block that reaches a real provider is not a
	# failing test, it is billable infrastructure; and `command = apply`
	# against even a mocked provider writes state. `mock_provider` and
	# `command = plan` are what prevent each, and neither can assert its own
	# presence.
	local files f
	mapfile -t files < <(find "${tf_src}" -name '*.tftest.hcl' -type f)
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
		! grep -qE '^[[:space:]]*command[[:space:]]*=[[:space:]]*apply' "$f" || {
			echo "$f uses command = apply; only plan is permitted" >&2
			return 1
		}
		# ISC-346/347. A file of nothing but `expect_failures` cannot tell "the
		# rule fired" from "the configuration was broken all along" — every run
		# would fail, and every run would be recorded as a pass.
		if grep -q 'expect_failures' "$f"; then
			grep -qE '^[[:space:]]*assert \{' "$f" || {
				echo "$f has expect_failures but no positive assertion to calibrate against" >&2
				return 1
			}
		fi
	done
}

@test "no .tftest.hcl anywhere under terraform/ requires real credentials" {
	# ISC-357 as a static property. The dynamic half — the sweep passing with
	# no ADC and no active gcloud account — is verified by running it; this
	# catches the constructs that would make it need credentials at all.
	local files f
	mapfile -t files < <(find "${tf_src}" -name '*.tftest.hcl' -type f)
	# Same guard as its sibling above, and for the same reason: `mapfile -t arr
	# < <(cmd)` reports MAPFILE's status, so a find that errored or a tf_src that
	# moved leaves `files` empty, the loop below runs zero times, and this test
	# reports that no .tftest.hcl requires credentials by not looking at any.
	[ "${#files[@]}" -ge 2 ] || {
		echo "expected at least two .tftest.hcl files, found ${#files[@]}" >&2
		return 1
	}
	local body
	for f in "${files[@]}"; do
		body="$(code_only "$f")"
		! printf '%s\n' "$body" | grep -qE '^[[:space:]]*(provider|backend)[[:space:]]+"' || {
			echo "$f declares a real provider or backend instead of mocking" >&2
			return 1
		}
		! printf '%s\n' "$body" | grep -qE 'credentials|access_token|service_account_key' || {
			echo "$f references a credential" >&2
			return 1
		}
	done
}

# ─── The rule no behavioural test can isolate ────────────────────────────────

@test "all sixteen validation rules are declared in source" {
	# Fifteen of the sixteen are proven behaviourally by the native suites:
	# deleting any one of rules 1, 3, 4, 5, 6, 6B, 7, 8, 9, 10, 11, 12, 13 or
	# either PROJECT rule turns a tftest run red. Measured one rule at a time
	# against a throwaway copy of the tree.
	#
	# ENV-RULE-02 (the kind enum) is the exception, and it is not a gap in the
	# tests — it is a redundancy in the rules. Rules 1 and 3 together IMPLY
	# rule 2: rule 1 forces the key to match ^(demo|ci)-[1-9][0-9]*$, rule 3
	# forces the key to start with "${kind}-", and the only kind satisfying
	# both is "demo" or "ci". No input exists that rule 2 alone rejects, so
	# deleting rule 2 leaves both native suites green. Verified with rule 2
	# removed: kind="production"/key="demo-1" is caught by rule 3, and
	# kind="prod"/key="prod-1" is caught by rule 1.
	#
	# Rule 2 stays because CONTRACT.md §3 mandates it and because it produces
	# the error message an operator can act on. Its presence is asserted
	# structurally — the only surface that can see a rule no input can reach.
	local tag
	for tag in \
		ENV-RULE-01-KEY-FORMAT \
		ENV-RULE-02-KIND-ENUM \
		ENV-RULE-03-KEY-KIND-AGREE \
		ENV-RULE-04-HOSTNAME-UNIQUE \
		ENV-RULE-05-SUBNET-UNIQUE \
		ENV-RULE-06-SUBNET-RFC1918 \
		ENV-RULE-06B-SUBNET-PREFIX-24 \
		ENV-RULE-07-IPV4-CIDR \
		ENV-RULE-08-IPV6-CIDR \
		ENV-RULE-09-NO-ANY-IPV4 \
		ENV-RULE-10-NO-ANY-IPV6 \
		ENV-RULE-11-APP-PORT-RANGE; do
		grep -q "$tag" "${tf_src}/modules/env-contract/variables.tf" || {
			echo "${tag} is not declared in the env-contract module" >&2
			return 1
		}
	done
	for tag in \
		ENV-RULE-12-NON-EMPTY \
		ENV-RULE-13-TARGET-ENV-EXISTS \
		PROJECT-RULE-01-PLACEHOLDER \
		PROJECT-RULE-02-FORMAT; do
		grep -q "$tag" "${tf_src}/environments/variables.tf" || {
			echo "${tag} is not declared in the environments root" >&2
			return 1
		}
	done
	# And the block count matches, so a rule cannot be deleted while its tag
	# survives in a comment.
	local n
	n="$(grep -c '^  validation {' "${tf_src}/modules/env-contract/variables.tf")"
	[ "$n" -eq 12 ] || {
		echo "expected 12 validation blocks in the env-contract, found ${n}" >&2
		return 1
	}
}

# ─── The worked examples: ISC-72, ISC-73, ISC-74 ─────────────────────────────

@test "the three worked tfvars examples set target_env and project_id" {
	# ISC-72 and ISC-73. The examples are never planned — they are what a human
	# copies — so their content is only ever checkable as text. An example
	# missing target_env produces a copy that cannot reach a plan at all.
	local f
	for f in demo-1 ci-1 demo-1-and-demo-2; do
		grep -qE '^target_env[[:space:]]*=' "${tf_src}/environments/${f}.tfvars.example" || {
			echo "${f}.tfvars.example does not set target_env" >&2
			return 1
		}
		grep -qE '^project_id[[:space:]]*=' "${tf_src}/environments/${f}.tfvars.example" || {
			echo "${f}.tfvars.example does not set project_id" >&2
			return 1
		}
	done
}

@test "no .tfvars file is committed under terraform/, only .tfvars.example" {
	# ISC-74. A real .tfvars is where a real project ID, a real hostname and a
	# real office IP range would end up.
	run find "${tf_src}" -name '*.tfvars' -type f
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "gaining demo-2 adds tfvars lines and modifies nothing" {
	# ISC-75, the textual half. `diff` hunk types are the assertion: `a` is an
	# addition, `d` a deletion, `c` a modification. If the second-environment
	# example required editing or removing any line of the first, at least one
	# `d` or `c` hunk would appear, and "add an entry" would really be "add an
	# entry and adjust some things".
	#
	# The executable half lives in root_contract.tftest.hcl, which resolves a
	# one-environment and a two-environment map through the same unmodified
	# source and asserts demo-2 gets a derived name and the full label set.
	local d
	d="$(diff "${tf_src}/environments/demo-1.tfvars.example" "${tf_src}/environments/demo-1-and-demo-2.tfvars.example" || true)"
	[ -n "$d" ] || {
		echo "the two examples are identical; there is no second environment to prove" >&2
		return 1
	}
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

# ─── Committed-secret hygiene: CONTRACT.md §6 ────────────────────────────────

@test "no example contains a real project id, domain, or address" {
	local f body
	for f in "${tf_src}"/environments/*.tfvars.example; do
		body="$(code_only "$f")"
		# Documentation ranges only: RFC5737 for IPv4, RFC3849 for IPv6,
		# RFC2606 .invalid for names, plus the RFC1918 subnets themselves.
		! printf '%s\n' "$body" | grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' |
			grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.10\.' || {
			echo "non-documentation IPv4 literal in $f" >&2
			return 1
		}
		! printf '%s\n' "$body" | grep -qE 'https?://|\.(com|net|org|io|dev|co\.uk)\b' || {
			echo "real-looking domain in $f" >&2
			return 1
		}
		grep -q 'CHANGEME' "$f" || {
			echo "$f has no CHANGEME placeholder; it may carry a real project id" >&2
			return 1
		}
		! grep -q '/home/andy' "$f" || {
			echo "absolute home path in $f" >&2
			return 1
		}
	done
}

@test "no example or shipping source contains an any-source CIDR" {
	# CONTRACT.md §6: no 0.0.0.0/0 or ::/0 in any allowlist default or example.
	#
	# Scoped to the examples and the non-test source. The `.tftest.hcl` files DO
	# contain 0.0.0.0/0 and ::/0 — as inputs they prove are rejected — and a
	# rule that could not tell a rejected input from a shipped default would
	# have to be weakened until it caught nothing.
	local f
	for f in "${tf_src}"/environments/*.tfvars.example \
		"${tf_src}"/environments/main.tf \
		"${tf_src}"/environments/outputs.tf \
		"${tf_src}"/modules/env-contract/main.tf \
		"${tf_src}"/modules/env-contract/outputs.tf; do
		! code_only "$f" | grep -n '0\.0\.0\.0/0\|::/0' || {
			echo "an any-source CIDR appears in $f" >&2
			return 1
		}
	done
}

@test "no committed Terraform source contains a home path or a forbidden construct" {
	# CONTRACT.md §6 anti-criteria.
	#
	# Scoped with --include/--exclude-dir deliberately. A bare `grep -r` over
	# these directories also walks `.terraform/`, and the downloaded google
	# provider binary contains the literal string `access_config` because the
	# provider implements it — so the guard's verdict would depend on whether
	# anyone had recently run `init`. Caught by this suite going red after a
	# validate.
	local globs=(--include='*.tf' --include='*.tftest.hcl' --exclude-dir='.terraform')
	! grep -rn "${globs[@]}" '/home/andy' "${tf_src}/modules/env-contract" "${tf_src}/environments" || {
		echo "absolute home path in committed Terraform source" >&2
		return 1
	}
	! grep -rn "${globs[@]}" 'access_config\|google_service_account_key\|google_project_iam_policy' \
		"${tf_src}/modules/env-contract" "${tf_src}/environments" || {
		echo "CONTRACT.md §6 forbidden construct in committed Terraform source" >&2
		return 1
	}
}

# ─── Structural criteria a plan cannot express ───────────────────────────────

@test "the environments variable is a single explicitly-typed object map" {
	# ISC-47, ISC-48. `any` would make every downstream module input unchecked
	# and ten of the rules unreachable — there would be no field to read. A
	# plan given a valid map cannot notice that the type is permissive.
	grep -q 'type = map(object({' "${tf_src}/modules/env-contract/variables.tf"
	! grep -qE 'type[[:space:]]*=[[:space:]]*map\(any\)|type[[:space:]]*=[[:space:]]*any' \
		"${tf_src}/modules/env-contract/variables.tf" || {
		echo "the environments map is typed 'any'; every downstream module input becomes unchecked" >&2
		return 1
	}
	[ "$(grep -c '^variable "environments"' "${tf_src}/modules/env-contract/variables.tf")" -eq 1 ]
}

@test "project_id is required and has no default" {
	# ISC-58. A property of the declaration, not of a plan: a default here means
	# a forgotten -var-file applies to somebody else's project, and every plan
	# would look perfectly healthy.
	run awk '/^variable "project_id"/{f=1} f&&/^}/{f=0} f' "${tf_src}/environments/variables.tf"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	! printf '%s\n' "$output" | grep -qE '^[[:space:]]*default[[:space:]]*=' || {
		echo "project_id declares a default; it must be required" >&2
		return 1
	}
}

@test "target_env is required and has no default" {
	# CONTRACT.md §5a. A default would silently pick an environment for a
	# distracted operator, which is the precise failure the variable exists to
	# prevent.
	run awk '/^variable "target_env"/{f=1} f&&/^}/{f=0} f' "${tf_src}/environments/variables.tf"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	! printf '%s\n' "$output" | grep -qE '^[[:space:]]*default[[:space:]]*=' || {
		echo "target_env declares a default; it must be required" >&2
		return 1
	}
}

@test "the environments root declares an empty gcs backend and no hand-completed prefix" {
	# CONTRACT.md §5. The empty form is what makes it impossible to reach apply
	# without naming the environment on the init command line.
	#
	# Comments are stripped first: backend.tf's rationale block quotes the
	# `-backend-config=prefix=...` invocation an operator must type, and an
	# assertion that cannot tell a documented command from a committed setting
	# fails on correct code — which trains people to loosen it until it catches
	# nothing.
	local body
	body="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${tf_src}/environments/backend.tf")"
	printf '%s\n' "$body" | grep -q 'backend "gcs" {}'
	! printf '%s\n' "$body" | grep -qE 'bucket[[:space:]]*=|prefix[[:space:]]*=' || {
		echo "backend.tf hand-completes the backend; the prefix must come from init" >&2
		return 1
	}
}
