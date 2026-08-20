#!/usr/bin/env bats
#
# Whole-file and whole-tree invariants for the Tailscale access path.
#
# Offline. No network, no cloud credentials, no terraform, no gcloud. Under 30s.
#
# ─── What is here and what is deliberately not ──────────────────────────────
#
# CONTRACT §7a routes evaluated-value assertions to native `terraform test`, and
# the two suites that own them are
# `terraform/modules/network/tests/network.tftest.hcl` and
# `terraform/modules/compute/tests/compute.tftest.hcl`. A plan can prove the
# IAM binding it computed is secret-scoped; it cannot prove that no OTHER file
# anywhere grants the same role at project scope, and it cannot see inside a
# shell script at all. Those two classes are what this file is for.
#
# ─── The rule the whole feature rests on ────────────────────────────────────
#
# The Tailscale auth key is fetched from Secret Manager AT RUNTIME, by the VM,
# under its own attached service account. It is not in the startup script, not
# in instance metadata, and not in Terraform state. This matters because startup
# scripts ARE instance metadata: they are stored in plain text and readable by
# anyone holding compute.instances.get on the project, which is a much larger
# set of people than "may join the tailnet".
#
# ─── Two traps this repo has already paid for ───────────────────────────────
#
#   1. A bare `! grep …` that is not a test's final line does NOT fail the test
#      under bats' errexit handling. Three anti-criteria guards elsewhere in this
#      repo were decoration inside a 37/37 green suite for exactly that reason.
#      Every negative below therefore uses `run …` followed by an explicit
#      `[ "$status" -ne 0 ]`, which bats does check.
#
#   2. `[ "$status" -ne 0 ]` on a grep reads a MISSING FILE as "pattern absent" —
#      a pass earned by scanning nothing. So every scanner here returns a
#      DISTINCT non-zero status for "target missing" (2) and "violation found"
#      (1), and the callers assert the exact one they mean.
#
# ─── And the inversion that is subtler than both ────────────────────────────
#
# An assertion of the form "no wildcard source appears in rule X" passes HARDEST
# when rule X has been deleted. Absence-of-bad is trivially satisfied by
# nothing-present. So the ingress and grant checks below assert the thing is
# PRESENT AND CORRECT, and the absence checks are paired with a presence check
# that would fail first.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export TF_DIR="${REPO_ROOT}/terraform"
	export NET_MAIN="${TF_DIR}/modules/network/main.tf"
	export NET_VARS="${TF_DIR}/modules/network/variables.tf"
	export COMPUTE_MAIN="${TF_DIR}/modules/compute/main.tf"
	export COMPUTE_VARS="${TF_DIR}/modules/compute/variables.tf"
	export ROOT_VARS="${TF_DIR}/environments/variables.tf"
	export STARTUP="${TF_DIR}/modules/compute/startup/demo-vm.sh"
	export TF_ENV_ROOT="${TF_DIR}/environments"
	export CLOSURE="${REPO_ROOT}/test/helpers/tf-module-closure.sh"
}

setup() {
	# Presence first, always (CONTRACT §6: no test that passes vacuously). Every
	# assertion in this file is about the contents of one of these; if the file
	# is not there, every one of them is true for the wrong reason.
	[ -f "$NET_MAIN" ]
	[ -f "$NET_VARS" ]
	[ -f "$COMPUTE_MAIN" ]
	[ -f "$COMPUTE_VARS" ]
	[ -f "$ROOT_VARS" ]
	[ -f "$STARTUP" ]
	[ -d "$TF_ENV_ROOT" ]
	[ -x "$CLOSURE" ]
}

# ---------------------------------------------------------------------------
# Helpers
#
# Every scanner returns:
#   0  clean
#   1  violation found (printed)
#   2  the target does not exist — the case a bare `[ "$status" -ne 0 ]` would
#      otherwise read as success
# ---------------------------------------------------------------------------

# Executable lines only: comments stripped, blank lines dropped. The sources
# here legitimately DISCUSS the patterns they must not contain — the startup
# script explains where the key comes from, main.tf explains why a project-scoped
# grant would be wrong — and a scanner that cannot tell a violation from the
# sentence forbidding it is a scanner someone switches off within a week.
code_only() {
	sed -e 's/[[:space:]]*#.*$//' "$1" | grep -v '^[[:space:]]*$' || true
}

# Names of every google_compute_firewall resource in <file> whose evaluated
# direction is the literal <direction>. Whole-block extraction rather than a
# fixed grep window: a window is silently wrong the moment a comment is added
# inside a resource, and it fails by reporting the guarded attribute absent.
#
# `terraform fmt -check` is enforced separately, so a top-level resource block
# is guaranteed to close with `}` in column 0.
firewall_names_with_direction() {
	local file="$1" direction="$2"
	[ -f "$file" ] || return 2
	awk -v want="$direction" '
		/^resource "google_compute_firewall" "/ {
			inblock = 1
			name = $3
			gsub(/"/, "", name)
			found = 0
		}
		inblock && $0 ~ "direction[[:space:]]*=[[:space:]]*\"" want "\"" { found = 1 }
		inblock && /^}[[:space:]]*$/ {
			if (found) print name
			inblock = 0
		}
	' "$file" | sort
}

# VIOLATION SCANNER: a Tailscale auth key literal.
#
# The pattern requires KEY MATERIAL after the prefix, not the prefix alone. The
# startup script legitimately contains `tskey-*` as a glob and `'tskey-'` in a
# log message — that shape check is a feature, and a guard that fired on it
# would force the feature out.
#
# Hyphens are INSIDE the character class, and that is not cosmetic. A real key
# is `tskey-auth-<id>-<secret>`, so a class of `[A-Za-z0-9]{8,}` stops at the
# hyphen after "auth" — four characters — and matches nothing. The first draft
# of this scanner had exactly that bug, and its own mutation test is what found
# it: the injected key went undetected and the MUTATION case failed rather than
# the guard silently passing forever.
scan_authkey_literal() {
	local target="$1"
	[ -f "$target" ] || return 2
	if grep -InE -- 'tskey-[A-Za-z0-9][A-Za-z0-9-]{15,}' "$target"; then
		echo "TAILSCALE AUTH KEY LITERAL in ${target}"
		return 1
	fi
	return 0
}

# VIOLATION SCANNER: a project-scoped grant of any Secret Manager role.
#
# Reads whole IAM blocks so that a `google_project_iam_member` and the
# `secretmanager` role inside it are matched TOGETHER. Matching them as two
# independent greps over a file would fire on any file that happens to contain
# both, which in this tree is most of them.
scan_project_scoped_secret_grant() {
	local dir="$1" found=0
	[ -d "$dir" ] || return 2
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		awk '
			/^resource "google_project_iam_(member|binding|policy)" "/ { inblock = 1; body = "" }
			inblock { body = body $0 "\n" }
			inblock && /^}[[:space:]]*$/ {
				if (body ~ /secretmanager/) printf "%s", body
				inblock = 0
			}
		' "$f" | grep -q . && {
			echo "PROJECT-SCOPED SECRET GRANT in ${f}"
			found=1
		}
	done < <(find "$dir" -type f -name '*.tf' -not -path '*/.terraform/*' | sort)
	return "$found"
}

# VIOLATION SCANNER: any Secret Manager IAM resource declared in ONE directory.
#
# Non-recursive on purpose. Its caller walks the environments root's transitive
# module closure and asks this of each directory in turn, so recursing here would
# make the closure walk decorative — and a scan that recursed from
# terraform/environments would reach nothing at all, because every module it
# calls lives in a sibling tree rather than underneath it.
#
# All three member/binding/policy forms are matched. They differ in authority,
# not in the permission they require of the applying identity: every one of them
# is a setIamPolicy call on the secret, which is the thing the deploy identity
# does not have and must not be given.
#
# Matched over comment-stripped source, because modules/compute now carries a
# long comment naming the exact resource type it deliberately does not declare.
# A scanner that fired on the sentence explaining the decision is a scanner
# someone deletes within a week; the guard that used to sit here learned that
# lesson for google_secret_manager_secret_version and it is recorded above.
scan_secret_iam_resource() {
	local dir="$1" found=0 f
	[ -d "$dir" ] || return 2
	for f in "$dir"/*.tf; do
		[ -f "$f" ] || continue
		if code_only "$f" | grep -qE '^resource "google_secret_manager_secret_iam_(member|binding|policy)"'; then
			echo "SECRET MANAGER IAM RESOURCE in ${f}"
			found=1
		fi
	done
	return "$found"
}

# Names of every IAM resource type declared under <dir>.
iam_resource_types() {
	local dir="$1"
	[ -d "$dir" ] || return 2
	find "$dir" -type f -name '*.tf' -not -path '*/.terraform/*' -print0 \
		| xargs -0 -r grep -hoE '^resource "google_[a-z_]*iam[a-z_]*"' \
		| sed -e 's/^resource "//' -e 's/"$//' | sort -u
}

# The value of a `default = [...]` immediately following `variable "<name>" {`.
# Returns the literal text between the brackets, so an empty default prints "".
variable_list_default() {
	local file="$1" name="$2"
	[ -f "$file" ] || return 2
	awk -v want="variable \"" -v vname="$name" '
		$0 ~ "^variable \"" vname "\" \\{" { inblock = 1 }
		inblock && /^  default[[:space:]]*=/ {
			line = $0
			sub(/^[^=]*=[[:space:]]*/, "", line)
			print line
			exit
		}
		inblock && /^}[[:space:]]*$/ { exit }
	' "$file"
}

# ---------------------------------------------------------------------------
# THE MECHANISM IS PRESENT
#
# Everything below asserts something about the Tailscale feature. If the feature
# is not in the tree, every one of those assertions is vacuously satisfiable —
# so this runs first and names the thing under test.
# ---------------------------------------------------------------------------

@test "the tailscale feature is present in all three places it must be" {
	run grep -qF 'install_tailscale()' "$STARTUP"
	[ "$status" -eq 0 ] || {
		echo "the startup script has no install_tailscale; every startup-script"
		echo "assertion in this file would then be vacuously true."
		return 1
	}

	# The DATA source, not an IAM resource. The binding this used to name was
	# removed deliberately — the secret's policy is granted once by a human, and
	# the reasoning is at the head of modules/compute/main.tf. What must still be
	# present is the read-only lookup: it is the plan-time existence gate, and
	# every assertion below about how the key is resolved is vacuous without it.
	run grep -qF 'data "google_secret_manager_secret" "tailscale_authkey"' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the compute module no longer looks the auth-key secret up at all"
		return 1
	}

	run grep -qF 'resource "google_compute_firewall" "allow_egress_public_udp"' "$NET_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the network module declares no UDP egress rule"
		return 1
	}
}

# ---------------------------------------------------------------------------
# THE KEY IS NOT IN THE SOURCE, AND IS READ AT RUNTIME
#
# Two halves, and both are needed. The absence half alone is satisfied by a
# script that fetches nothing at all; the presence half alone is satisfied by a
# script that fetches a key it also hardcodes as a fallback.
# ---------------------------------------------------------------------------

@test "no tailscale auth key literal appears in the startup script" {
	run scan_authkey_literal "$STARTUP"
	[ "$status" -eq 0 ] || {
		echo "$output"
		echo ""
		echo "Startup scripts are stored in INSTANCE METADATA IN PLAIN TEXT and"
		echo "are readable by anyone holding compute.instances.get on the"
		echo "project. A key here is a key published to that whole set."
		return 1
	}
}

@test "no tailscale auth key literal appears anywhere under terraform/" {
	# Whole-tree, because the startup script is not the only file that could
	# carry one: a tfvars example, a module default, a README snippet.
	local scanned=0 f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		scanned=$((scanned + 1))
		run scan_authkey_literal "$f"
		[ "$status" -eq 0 ] || {
			echo "$output"
			return 1
		}
	done < <(git -C "$REPO_ROOT" ls-files -- 'terraform/*' 'deploy/gcp/*' | sed "s|^|${REPO_ROOT}/|")

	# Guard the guard: an empty file list makes the loop above trivially clean.
	[ "$scanned" -ge 20 ] || {
		echo "only ${scanned} files scanned; the file list is broken and this"
		echo "guard is measuring nothing."
		return 1
	}
}

@test "the startup script fetches the key from Secret Manager at runtime" {
	# The POSITIVE half, and it is the one that survives a deletion. "No key
	# literal" passes hardest when the whole feature has been removed; these
	# assertions fail in that case, which is the correct answer.
	local needle
	for needle in \
		'secretmanager.googleapis.com' \
		'versions/latest:access' \
		'instance/service-accounts/default/token' \
		'Metadata-Flavor: Google' \
		'signalloom-tailscale-secret-id'; do
		run grep -qF -- "$needle" "$STARTUP"
		[ "$status" -eq 0 ] || {
			echo "the startup script no longer contains '${needle}'."
			echo "The key must be resolved AT RUNTIME by the VM, under its own"
			echo "attached service account, via the metadata server."
			return 1
		}
	done
}

@test "the startup script reads the secret NAME from metadata, not the key" {
	# The distinction the whole design rests on: metadata carries an identifier
	# that is worthless without an IAM grant, never a credential.
	run grep -qF 'metadata_attr signalloom-tailscale-secret-id' "$STARTUP"
	[ "$status" -eq 0 ]

	# And the Terraform side emits exactly that key, on the instance.
	#
	# The VALUE is matched loosely here — either the variable or the data
	# source's echo of it — because this test owns one claim only: the metadata
	# key carries an identifier, which is worthless without an IAM grant, rather
	# than a credential. WHICH of the two expressions supplies it is a different
	# property with a different failure mode (the plan-time existence gate being
	# tidied away as unused), and it is asserted exactly, once, in "the compute
	# module still reads the secret, and grants nothing". Pinning the expression
	# in both places would mean two tests failing for one cause and neither
	# naming it.
	run grep -qE '^ *signalloom-tailscale-secret-id *= *(var\.tailscale_authkey_secret_id|data\.google_secret_manager_secret\.tailscale_authkey\[0\]\.secret_id) *$' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the compute module no longer publishes the secret NAME in metadata"
		return 1
	}

	# The paired negative: whatever supplies that value, it is an identifier and
	# not the key itself. Without this the assertion above is satisfied by a
	# module that publishes a hardcoded tskey-… under the same key name.
	run scan_authkey_literal "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "no module declares a secret VERSION resource, which would state the key" {
	# `google_secret_manager_secret_version` carries its payload in `secret_data`,
	# so declaring one would write the auth key into Terraform state in plain
	# text — a GCS object several principals can read. The secret is created out
	# of band precisely so that never happens.
	#
	# Matched as a RESOURCE DECLARATION over comment-stripped source, not as a
	# bare string. The first draft grepped for the type name and fired on the
	# module's own comment explaining why that resource must not be used — a
	# guard reporting the correctly-written file as broken, which is how a guard
	# gets switched off. Its own run is what caught it.
	local declarations f
	declarations=""
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if code_only "$f" | grep -qE '^resource "google_secret_manager_secret_version"'; then
			declarations="${declarations} ${f}"
		fi
	done < <(find "$TF_DIR" -type f -name '*.tf' -not -path '*/.terraform/*' | sort)

	[ -z "$declarations" ] || {
		echo "a secret version resource is declared in:${declarations}"
		echo "Its secret_data lands in Terraform state in plain text."
		return 1
	}

	# Paired presence check, so the loop above cannot pass by having walked an
	# empty tree.
	[ "$(find "$TF_DIR" -type f -name '*.tf' -not -path '*/.terraform/*' | wc -l)" -ge 20 ]
}

@test "MUTATION: a declared secret version resource is caught, but a comment is not" {
	# The two halves of the distinction that broke the first draft: the guard
	# must fire on a DECLARATION and must not fire on a comment discussing one.
	local dir
	dir="${BATS_TEST_TMPDIR}/mut-secretversion"
	mkdir -p "$dir"

	printf '%s\n' \
		'# google_secret_manager_secret_version is deliberately not used here.' \
		'resource "google_compute_instance" "x" {' \
		'  name = "x"' \
		'}' >"${dir}/comment-only.tf"

	printf '%s\n' \
		'resource "google_secret_manager_secret_version" "leak" {' \
		'  secret = "x"' \
		'}' >"${dir}/declared.tf"

	run bash -c "sed -e 's/[[:space:]]*#.*\$//' '${dir}/comment-only.tf' | grep -qE '^resource \"google_secret_manager_secret_version\"'"
	[ "$status" -ne 0 ]

	run bash -c "sed -e 's/[[:space:]]*#.*\$//' '${dir}/declared.tf' | grep -qE '^resource \"google_secret_manager_secret_version\"'"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# THE SECRET'S IAM IS NOT THE DEPLOY IDENTITY'S TO MANAGE
#
# The compute module used to declare a secret-scoped
# google_secret_manager_secret_iam_member granting secretAccessor to the VM's
# runtime account. Correct about scope, wrong about OWNER: declaring it means the
# identity running `terraform apply` needs secretmanager.secrets.setIamPolicy on
# that secret, and both first applies died on exactly that 403. Widening the
# deploy identity is the available fix and the wrong one — an account that can
# setIamPolicy on a secret can grant itself read of that secret, and this one
# runs unattended. The repo already settled the same question for buckets at the
# foot of modules/deploy-identity/main.tf: creation and IAM are lifecycle,
# lifecycle belongs to the one-time privileged human, and what the deploy
# identity does is POPULATE.
#
# So the assertion inverts. It is no longer "the grant is correctly scoped" but
# "no Secret Manager IAM resource is reachable from the environments root at
# all" — and it is asked of the transitive MODULE CLOSURE rather than of the
# root's own files, because the root declares no `resource` blocks whatsoever.
# A guard that grepped only terraform/environments/*.tf would be green today,
# green if the binding were re-added inside any module the root calls, and would
# report nothing on the morning the 403 came back. tf-module-closure.sh is the
# tool that answers the question actually being asked; it is the same helper
# test/terraform-preserve-guards.bats uses, for the same reason.
# ---------------------------------------------------------------------------

@test "no Secret Manager IAM resource is reachable from the environments root" {
	local closure violations dir

	closure="$("$CLOSURE" "$TF_ENV_ROOT")"

	# PRESENCE FIRST, and it is not ceremony. The scan below is an
	# absence-of-bad assertion, which is trivially satisfied by having walked
	# nothing: a closure helper that silently returned an empty list, or a
	# renamed module directory, would make this test pass hardest at the moment
	# it stopped looking at anything. So the closure must contain the module
	# that actually carries the Tailscale code before its emptiness means a
	# thing.
	[ -n "$closure" ]
	printf '%s\n' "$closure" | grep -qx "${TF_DIR}/modules/compute" || {
		echo "the environments root's module closure no longer reaches modules/compute:"
		printf '  %s\n' $closure
		echo "Every assertion below is vacuous until it does."
		return 1
	}

	violations=""
	while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		run scan_secret_iam_resource "$dir"
		[ "$status" -ne 2 ] || {
			echo "closure names a directory that does not exist: ${dir}"
			return 1
		}
		if [ "$status" -eq 1 ]; then
			violations="${violations}${output}"$'\n'
		fi
	done <<<"$closure"

	[ -z "$violations" ] || {
		echo "$violations"
		echo ""
		echo "A Secret Manager IAM resource in the environments root's closure"
		echo "requires the DEPLOY identity to hold secretmanager.secrets.setIamPolicy"
		echo "on that secret. It does not hold it, and it must not: an account that"
		echo "can setIamPolicy on a secret can grant itself read of that secret, and"
		echo "this one runs unattended from CI."
		echo ""
		echo "The grants are made once, by a human, in the act that creates the"
		echo "secret — see terraform/bootstrap/README.md."
		return 1
	}
}

@test "the compute module still reads the secret, and grants nothing" {
	# The two halves together, because either alone is satisfiable by deleting
	# the feature. A tree with no Tailscale code at all has no IAM resource in
	# it either, and would sail through the closure scan above.
	run grep -qE '^data "google_secret_manager_secret" "tailscale_authkey" \{' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the compute module no longer looks the auth-key secret up"
		echo "roles/secretmanager.viewer on the deploy identity exists to make"
		echo "this lookup resolve; without the lookup there is no plan-time gate."
		return 1
	}

	# The lookup is CONSUMED, not merely declared. Nothing else references it
	# now that the IAM binding is gone, so an unreferenced data source is one
	# `tflint --fix` away from deletion — and its deletion is silent, because
	# what it provides is a plan-time failure that simply stops happening.
	run grep -qF 'signalloom-tailscale-secret-id = data.google_secret_manager_secret.tailscale_authkey[0].secret_id' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the secret name published to the VM no longer comes FROM the lookup."
		echo "Taking it from var.tailscale_authkey_secret_id instead produces the"
		echo "identical string and removes the dependency edge, which is the only"
		echo "thing keeping the existence gate from being tidied away as unused."
		return 1
	}

	local types
	types="$(iam_resource_types "${TF_DIR}/modules/compute")"
	[ -z "$types" ] || {
		echo "the compute module declares IAM resources again:"
		printf '  %s\n' $types
		echo "Its IAM budget is now ZERO. The VM's access to the auth-key secret"
		echo "is granted out of band by a human; see the head of the module."
		return 1
	}
}

@test "no project-scoped Secret Manager grant exists anywhere under terraform/" {
	run scan_project_scoped_secret_grant "$TF_DIR"
	[ "$status" -eq 0 ] || {
		echo "$output"
		echo ""
		echo "roles/secretmanager.secretAccessor at PROJECT scope grants read on"
		echo "every secret in the project, present and future, to a service"
		echo "account attached to a VM that pulls public container images."
		return 1
	}
}

# ---------------------------------------------------------------------------
# INGRESS IS IMMOVABLE
#
# Stated as an exact SET of rule names, not as "no new wildcard appeared". The
# set form fails on an addition AND on a deletion; the absence form is satisfied
# by an empty file.
# ---------------------------------------------------------------------------

@test "the network module declares exactly the four known ingress rules" {
	local names expected
	names="$(firewall_names_with_direction "$NET_MAIN" INGRESS)"
	expected="$(printf '%s\n' allow_health_checks allow_iap_app_port allow_iap_ssh deny_all_ingress | sort)"

	[ "$names" = "$expected" ] || {
		echo "the module's INGRESS firewall rules changed."
		echo "found:"
		printf '  %s\n' $names
		echo "expected:"
		printf '  %s\n' $expected
		echo ""
		echo "Tailscale is outbound-only: it needs no ingress rule at all, and"
		echo "a new one arriving with a Tailscale change is a mistake, not a"
		echo "requirement."
		return 1
	}
}

@test "the IAP ingress source range is still exactly the IAP forwarding range" {
	# Both halves: the pinned value, and the validation that refuses any other.
	# The value alone proves it is right today; the rule proves a wrong one is
	# refused, which is the property that survives the next edit.
	run grep -qF 'default     = "35.235.240.0/20"' "$NET_VARS"
	[ "$status" -eq 0 ] || {
		echo "iap_source_range no longer defaults to Google's IAP range"
		return 1
	}

	run grep -qF 'var.iap_source_range == "35.235.240.0/20"' "$NET_VARS"
	[ "$status" -eq 0 ] || {
		echo "NET-RULE-01's equality validation is gone; the IAP source can now"
		echo "be repointed by a one-character edit that reads as configuration."
		return 1
	}
}

@test "no external IP is introduced anywhere by the tailscale change" {
	# The single property that keeps this instance off the public internet, and
	# the one an operator reaches for when a tailnet does not come up.
	run bash -c "sed -e 's/[[:space:]]*#.*\$//' '${COMPUTE_MAIN}' | grep -nE '^[[:space:]]*access_config[[:space:]]*\{'"
	[ "$status" -ne 0 ] || {
		echo "$output"
		echo "an access_config block grants an external IP. Tailscale needs"
		echo "none — it is outbound-only."
		return 1
	}
	# Paired presence check, so the assertion above cannot pass by the file
	# having been emptied or moved.
	run grep -qF 'network_interface {' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# THE UDP EGRESS RULE
# ---------------------------------------------------------------------------

@test "the udp rule is an egress rule, scoped, and never open to the world" {
	local names
	names="$(firewall_names_with_direction "$NET_MAIN" EGRESS)"
	printf '%s\n' "$names" | grep -qx 'allow_egress_public_udp' || {
		echo "allow_egress_public_udp is not an EGRESS rule. found EGRESS rules:"
		printf '  %s\n' $names
		return 1
	}

	# Scoped POSITIVELY to the runtime service account. Extracted from the block
	# itself rather than grepped file-wide, so a target on some other rule
	# cannot satisfy this one.
	local block
	block="$(awk '
		/^resource "google_compute_firewall" "allow_egress_public_udp" \{/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { exit }
	' "$NET_MAIN")"
	[ -n "$block" ]

	printf '%s\n' "$block" | grep -qF 'target_service_accounts = [var.runtime_service_account_email]' || {
		echo "the udp rule is not scoped to the runtime service account."
		echo "Unscoped, it grants outbound UDP to every instance in the VPC."
		return 1
	}

	printf '%s\n' "$block" | grep -qF 'protocol = "udp"' || {
		echo "the udp rule does not allow udp. TCP on 41641 grants nothing:"
		echo "Tailscale's direct listener and STUN are both UDP."
		return 1
	}

	run bash -c "printf '%s\n' \"\$1\" | sed -e 's/[[:space:]]*#.*\$//' | grep -nE '(0\.0\.0\.0/0|::/0)'" _ "$block"
	[ "$status" -ne 0 ] || {
		echo "$output"
		echo "the udp allow rule names the whole internet in its own source."
		return 1
	}
}

@test "both udp port defaults are the empty list, module AND root" {
	# The module default is dead the moment the root wires the variable through,
	# so BOTH must be empty or the root's default silently governs. This is the
	# exact shape that let a ["80","443"] root default open plaintext egress
	# while every module test stayed green.
	local mod_default root_default
	mod_default="$(variable_list_default "$NET_VARS" egress_public_udp_ports)"
	root_default="$(variable_list_default "$ROOT_VARS" egress_public_udp_ports)"

	[ -n "$mod_default" ] || {
		echo "no default found for egress_public_udp_ports in ${NET_VARS};"
		echo "this guard is reading nothing."
		return 1
	}
	[ -n "$root_default" ] || {
		echo "no default found for egress_public_udp_ports in ${ROOT_VARS};"
		echo "this guard is reading nothing."
		return 1
	}

	[ "$mod_default" = "[]" ] || {
		echo "the MODULE default for egress_public_udp_ports is '${mod_default}',"
		echo "not []. UDP egress must never be inherited: an environment that"
		echo "did not ask for a tailnet must not acquire outbound UDP because a"
		echo "module default said so."
		return 1
	}
	[ "$root_default" = "[]" ] || {
		echo "the ROOT default for egress_public_udp_ports is '${root_default}',"
		echo "not []. The root's default governs once it wires the variable"
		echo "through, so a non-empty value here opens UDP for every"
		echo "environment while every module test stays green."
		return 1
	}
}

@test "both udp destination defaults are the empty list, module AND root" {
	local mod_default root_default
	mod_default="$(variable_list_default "$NET_VARS" egress_public_udp_destinations)"
	root_default="$(variable_list_default "$ROOT_VARS" egress_public_udp_destinations)"
	[ -n "$mod_default" ]
	[ -n "$root_default" ]
	[ "$mod_default" = "[]" ]
	[ "$root_default" = "[]" ]
}

# ---------------------------------------------------------------------------
# THE STARTUP SCRIPT CANNOT BE TAKEN DOWN BY AN OPTIONAL FEATURE
# ---------------------------------------------------------------------------

@test "no tailscale code path calls die" {
	# `die` exits 1, and with `set -e` active that aborts the whole bootstrap
	# before the marker is written. A VM that will not boot because an optional
	# feature's secret is missing is strictly worse than a VM without the
	# feature — the estate does not depend on the tailnet in any way.
	local body
	body="$(awk '
		/^install_tailscale\(\)|^install_tailscale_package\(\)|^fetch_tailscale_authkey\(\)|^bring_tailscale_up\(\)/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { inblock = 0 }
	' "$STARTUP" | sed -e 's/[[:space:]]*#.*$//')"

	# Guard the guard: the extraction must have found real code, or "no die"
	# is true of an empty string.
	[ -n "$body" ]
	printf '%s\n' "$body" | grep -qF 'metadata_attr' || {
		echo "the tailscale function extraction found no metadata read; the awk"
		echo "range no longer matches and this guard is scanning nothing."
		return 1
	}

	run bash -c "printf '%s\n' \"\$1\" | grep -nE '(^|[[:space:]])die[[:space:]]'" _ "$body"
	[ "$status" -ne 0 ] || {
		echo "$output"
		echo "a tailscale code path calls die, which aborts the whole bootstrap."
		echo "Every failure there must log and continue."
		return 1
	}
}

@test "the tailscale stage does not accept MagicDNS" {
	# Load-bearing, not tidiness. Accepting MagicDNS rewrites /etc/resolv.conf;
	# this VM's resolver is the metadata server, and the VPC private zone is what
	# points googleapis.com at the restricted Private Google Access VIP. Replace
	# the resolver and googleapis.com resolves PUBLICLY, at which point the
	# deny-all egress rule correctly refuses it and the estate fails with
	# "dial tcp 172.217.x.x:443: i/o timeout" — which reads as an over-strict
	# firewall and has nothing to do with the firewall.
	run grep -qF -- '--accept-dns=false' "$STARTUP"
	[ "$status" -eq 0 ] || {
		echo "the tailscale stage no longer passes --accept-dns=false."
		echo "MagicDNS would replace the resolver that Private Google Access"
		echo "depends on, breaking every Google API call from this VM."
		return 1
	}
}

@test "the startup script still keeps its no-deploy and checksum properties" {
	# The Tailscale addition must not have moved the provisioning/deployment
	# line, and must not have displaced the download verification. Both are
	# owned by test/terraform-vm-profile.bats; re-asserted here in their
	# smallest form so a Tailscale change that broke either fails in the suite
	# that made it.
	run grep -qF 'does NOT deploy the demo' "$STARTUP"
	[ "$status" -eq 0 ]
	run grep -qE '^fetch_verified\(\)' "$STARTUP"
	[ "$status" -eq 0 ]
	run grep -qF 'already bootstrapped' "$STARTUP"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS
#
# Every guard above is driven with an injected violation and required to go RED
# for the RIGHT REASON. A guard that cannot fail is worse than no guard, because
# it reads as coverage.
#
# The mutations run on COPIES in BATS_TEST_TMPDIR, generated from the live tree
# at test time (CONTRACT §7: never by mutating the real tree). Generated rather
# than committed so they cannot go stale — they are derived from whatever the
# source says today.
#
# Each mutation ASSERTS IT CHANGED SOMETHING before running the guard. A sed
# whose pattern no longer matches silently no-ops, and the mutation check would
# then run against an unmutated copy and pass — which is the precise failure
# this whole section exists to prevent.
# ---------------------------------------------------------------------------

# Copy <src> to the tmpdir, apply <sed-program>, and refuse to continue unless
# the file actually changed. Prints the mutated path.
mutate() {
	local src="$1" sedprog="$2" dest="${BATS_TEST_TMPDIR}/mutated-$(basename "$1")"
	cp "$src" "$dest"
	sed -i -e "$sedprog" "$dest"
	if cmp -s "$src" "$dest"; then
		echo "mutation '${sedprog}' changed nothing in ${src}; it is testing nothing." >&2
		return 1
	fi
	printf '%s' "$dest"
}

@test "MUTATION: an auth key literal in the startup script is caught" {
	local mutated
	mutated="$(mutate "$STARTUP" 's|^readonly LOG_TAG=.*|readonly TS_KEY="tskey-auth-kAAAAAAACNTRL-abcdefghijklmnop"|')"
	[ -n "$mutated" ]

	run scan_authkey_literal "$mutated"
	[ "$status" -eq 1 ]
	[[ "$output" == *"AUTH KEY LITERAL"* ]]

	# The clean control: the real file must still pass the same scanner, or the
	# RED above proves only that the scanner fires on something.
	run scan_authkey_literal "$STARTUP"
	[ "$status" -eq 0 ]
}

@test "MUTATION: the auth key scanner reports a missing file distinctly" {
	# The trap this repo has been bitten by: `[ "$status" -ne 0 ]` on a grep
	# reads a MISSING FILE as "pattern absent". Status 2 is reserved for it so a
	# caller asserting `-eq 1` cannot be satisfied by scanning nothing.
	run scan_authkey_literal "${BATS_TEST_TMPDIR}/does-not-exist.sh"
	[ "$status" -eq 2 ]
}

@test "MUTATION: removing the runtime secret fetch is caught" {
	local mutated
	mutated="$(mutate "$STARTUP" 's|secretmanager\.googleapis\.com|example.invalid|g')"
	[ -n "$mutated" ]

	run grep -qF 'secretmanager.googleapis.com' "$mutated"
	[ "$status" -ne 0 ]
	run grep -qF 'secretmanager.googleapis.com' "$STARTUP"
	[ "$status" -eq 0 ]
}

@test "MUTATION: a project-scoped secret grant is caught" {
	# The mutation this replaces edited the real binding's resource type in a
	# copy of main.tf. That binding no longer exists, so the sed became a silent
	# no-op — and a no-op mutation leaves the scanner untested while the test
	# still passes, which is the exact failure mode this suite's header warns
	# about. The fixture is now synthesised, so it cannot stop matching.
	local dir
	dir="${BATS_TEST_TMPDIR}/mut-iam"
	mkdir -p "$dir"
	cat >"${dir}/main.tf" <<'PROJECTSCOPED'
resource "google_project_iam_member" "tailscale_authkey_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${var.service_account_email}"
}
PROJECTSCOPED

	run scan_project_scoped_secret_grant "$dir"
	[ "$status" -eq 1 ]
	[[ "$output" == *"PROJECT-SCOPED SECRET GRANT"* ]]

	# Clean control against the real tree.
	run scan_project_scoped_secret_grant "$TF_DIR"
	[ "$status" -eq 0 ]
}

@test "MUTATION: re-adding a secret IAM resource inside the closure is caught" {
	# The guard that replaced the scope check. Its subject is a resource that
	# is now ABSENT, and an absence assertion is exactly the shape that passes
	# hardest when nothing is there — so the only way to know it can still fail
	# is to put the resource back and watch it fire.
	#
	# All three authority forms, because they are equally 403-producing: each is
	# a setIamPolicy call on the secret.
	local dir form
	for form in member binding policy; do
		dir="${BATS_TEST_TMPDIR}/mut-secretiam-${form}"
		mkdir -p "$dir"
		cat >"${dir}/main.tf" <<RESTORED
resource "google_secret_manager_secret_iam_${form}" "tailscale_authkey_accessor" {
  project   = var.project_id
  secret_id = var.tailscale_authkey_secret_id
  role      = "roles/secretmanager.secretAccessor"
}
RESTORED

		run scan_secret_iam_resource "$dir"
		[ "$status" -eq 1 ] || {
			echo "the guard did not fire on a google_secret_manager_secret_iam_${form}"
			return 1
		}
		[[ "$output" == *"SECRET MANAGER IAM RESOURCE"* ]]
	done

	# A COMMENT discussing the resource type must NOT fire. modules/compute now
	# carries several paragraphs naming it, and a guard that reported the
	# correctly-written file as broken is one that gets switched off.
	dir="${BATS_TEST_TMPDIR}/mut-secretiam-comment"
	mkdir -p "$dir"
	cat >"${dir}/main.tf" <<'COMMENTONLY'
# resource "google_secret_manager_secret_iam_member" is deliberately not used:
# it would require setIamPolicy on the secret.
resource "google_compute_instance" "x" {
  name = "x"
}
COMMENTONLY
	run scan_secret_iam_resource "$dir"
	[ "$status" -eq 0 ]

	# Missing directory is status 2, distinct from "clean" — the trap where
	# `[ "$status" -ne 0 ]` reads a nonexistent target as a pass.
	run scan_secret_iam_resource "${BATS_TEST_TMPDIR}/no-such-dir-at-all"
	[ "$status" -eq 2 ]

	# Clean control: every directory in the real closure.
	local d
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		run scan_secret_iam_resource "$d"
		[ "$status" -eq 0 ] || {
			echo "$output"
			return 1
		}
	done < <("$CLOSURE" "$TF_ENV_ROOT")
}

@test "MUTATION: dropping the data-source reference from metadata is caught" {
	# The consumed-lookup half. Rewriting the metadata value back to the
	# variable produces a byte-identical published string, so nothing about the
	# VM changes and no other assertion in this suite or in compute.tftest.hcl
	# notices — the only casualty is the dependency edge that stops the
	# existence gate being deleted as unused. That is precisely the class of
	# change a guard has to catch, because its symptom is nothing.
	local mutated
	mutated="$(mutate "$COMPUTE_MAIN" \
		's|signalloom-tailscale-secret-id = data\.google_secret_manager_secret\.tailscale_authkey\[0\]\.secret_id|signalloom-tailscale-secret-id = var.tailscale_authkey_secret_id|')"
	[ -n "$mutated" ]

	# The mutation must have CHANGED something. A sed whose pattern stopped
	# matching would leave an identical file and the assertions below would
	# then be testing the unmutated original.
	run cmp -s "$COMPUTE_MAIN" "$mutated"
	[ "$status" -ne 0 ]

	run grep -qF 'signalloom-tailscale-secret-id = data.google_secret_manager_secret.tailscale_authkey[0].secret_id' "$mutated"
	[ "$status" -ne 0 ]

	run grep -qF 'signalloom-tailscale-secret-id = data.google_secret_manager_secret.tailscale_authkey[0].secret_id' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ]
}

@test "MUTATION: the project-scope scanner reports a missing directory distinctly" {
	run scan_project_scoped_secret_grant "${BATS_TEST_TMPDIR}/no-such-dir"
	[ "$status" -eq 2 ]
}

@test "MUTATION: ANY IAM resource breaks the compute permission budget" {
	# The budget is now ZERO, which makes this mutation more important rather
	# than less: "no IAM resources here" is an absence assertion, and the tree
	# satisfies it today by having none. Adding one is the only way to show the
	# check still has teeth.
	local dir
	dir="${BATS_TEST_TMPDIR}/mut-budget"
	mkdir -p "$dir"
	cp "$COMPUTE_MAIN" "${dir}/main.tf"
	cat >>"${dir}/main.tf" <<'EXTRA'

resource "google_project_iam_member" "sneaky" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${var.service_account_email}"
}
EXTRA

	run iam_resource_types "$dir"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" == *"google_project_iam_member"* ]]

	# Clean control: the real module holds none.
	run iam_resource_types "${TF_DIR}/modules/compute"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "MUTATION: a new ingress rule breaks the ingress set" {
	local dir
	dir="${BATS_TEST_TMPDIR}/mut-ingress"
	mkdir -p "$dir"
	cp "$NET_MAIN" "${dir}/main.tf"
	cat >>"${dir}/main.tf" <<'EXTRA'

resource "google_compute_firewall" "allow_tailscale_ingress" {
  name      = "${var.name_prefix}-allow-tailscale"
  project   = var.project_id
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["100.64.0.0/10"]

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }
}
EXTRA

	local names
	names="$(firewall_names_with_direction "${dir}/main.tf" INGRESS)"
	printf '%s\n' "$names" | grep -qx 'allow_tailscale_ingress'

	# The real module's set is unchanged, and it is exactly four.
	names="$(firewall_names_with_direction "$NET_MAIN" INGRESS)"
	[ "$(printf '%s\n' "$names" | wc -l)" -eq 4 ]
	printf '%s\n' "$names" | grep -qx 'allow_tailscale_ingress' && {
		echo "the real module now declares a tailscale ingress rule"
		return 1
	}
	true
}

@test "MUTATION: repointing the IAP source range is caught" {
	local mutated
	mutated="$(mutate "$NET_VARS" 's|default     = "35\.235\.240\.0/20"|default     = "0.0.0.0/0"|')"
	[ -n "$mutated" ]

	run grep -qF 'default     = "35.235.240.0/20"' "$mutated"
	[ "$status" -ne 0 ]
	run grep -qF 'default     = "35.235.240.0/20"' "$NET_VARS"
	[ "$status" -eq 0 ]
}

@test "MUTATION: a non-empty udp port default is caught, module and root" {
	local mutated
	mutated="$(mutate "$NET_VARS" 's|^  default     = \[\]$|  default     = ["41641", "3478"]|')"
	[ -n "$mutated" ]

	run variable_list_default "$mutated" egress_public_udp_ports
	[ "$status" -eq 0 ]
	[ "$output" != "[]" ]

	mutated="$(mutate "$ROOT_VARS" 's|^  default     = \[\]$|  default     = ["41641"]|')"
	[ -n "$mutated" ]
	run variable_list_default "$mutated" egress_public_udp_ports
	[ "$status" -eq 0 ]
	[ "$output" != "[]" ]

	# Clean control on both real files.
	run variable_list_default "$NET_VARS" egress_public_udp_ports
	[ "$output" = "[]" ]
	run variable_list_default "$ROOT_VARS" egress_public_udp_ports
	[ "$output" = "[]" ]
}

@test "MUTATION: unscoping the udp rule is caught" {
	local mutated block
	mutated="$(mutate "$NET_MAIN" '/^resource "google_compute_firewall" "allow_egress_public_udp"/,/^}$/ s|^  target_service_accounts = \[var\.runtime_service_account_email\]$||')"
	[ -n "$mutated" ]

	block="$(awk '
		/^resource "google_compute_firewall" "allow_egress_public_udp" \{/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { exit }
	' "$mutated")"
	[ -n "$block" ]
	run bash -c "printf '%s\n' \"\$1\" | grep -qF 'target_service_accounts'" _ "$block"
	[ "$status" -ne 0 ]

	# Clean control on the real file.
	block="$(awk '
		/^resource "google_compute_firewall" "allow_egress_public_udp" \{/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { exit }
	' "$NET_MAIN")"
	run bash -c "printf '%s\n' \"\$1\" | grep -qF 'target_service_accounts = [var.runtime_service_account_email]'" _ "$block"
	[ "$status" -eq 0 ]
}

@test "MUTATION: a die in the tailscale path is caught" {
	local mutated body
	mutated="$(mutate "$STARTUP" 's|    log "WARNING: could not install the tailscale package"|    die "could not install the tailscale package"|')"
	[ -n "$mutated" ]

	body="$(awk '
		/^install_tailscale\(\)|^install_tailscale_package\(\)|^fetch_tailscale_authkey\(\)|^bring_tailscale_up\(\)/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { inblock = 0 }
	' "$mutated" | sed -e 's/[[:space:]]*#.*$//')"
	[ -n "$body" ]
	run bash -c "printf '%s\n' \"\$1\" | grep -qE '(^|[[:space:]])die[[:space:]]'" _ "$body"
	[ "$status" -eq 0 ]

	# Clean control: the real script's tailscale path calls die nowhere.
	body="$(awk '
		/^install_tailscale\(\)|^install_tailscale_package\(\)|^fetch_tailscale_authkey\(\)|^bring_tailscale_up\(\)/ { inblock = 1 }
		inblock { print }
		inblock && /^}[[:space:]]*$/ { inblock = 0 }
	' "$STARTUP" | sed -e 's/[[:space:]]*#.*$//')"
	run bash -c "printf '%s\n' \"\$1\" | grep -qE '(^|[[:space:]])die[[:space:]]'" _ "$body"
	[ "$status" -ne 0 ]
}

@test "MUTATION: accepting MagicDNS is caught" {
	local mutated
	mutated="$(mutate "$STARTUP" 's|--accept-dns=false|--accept-dns=true|')"
	[ -n "$mutated" ]

	run grep -qF -- '--accept-dns=false' "$mutated"
	[ "$status" -ne 0 ]
	run grep -qF -- '--accept-dns=false' "$STARTUP"
	[ "$status" -eq 0 ]
}

@test "MUTATION: an access_config in the compute module is caught" {
	local dir
	dir="${BATS_TEST_TMPDIR}/mut-extip"
	mkdir -p "$dir"
	sed -e 's|^  network_interface {|  network_interface {\n    access_config {}|' "$COMPUTE_MAIN" >"${dir}/main.tf"
	run cmp -s "$COMPUTE_MAIN" "${dir}/main.tf"
	[ "$status" -ne 0 ]

	run bash -c "sed -e 's/[[:space:]]*#.*\$//' '${dir}/main.tf' | grep -nE '^[[:space:]]*access_config[[:space:]]*\{'"
	[ "$status" -eq 0 ]

	run bash -c "sed -e 's/[[:space:]]*#.*\$//' '${COMPUTE_MAIN}' | grep -nE '^[[:space:]]*access_config[[:space:]]*\{'"
	[ "$status" -ne 0 ]
}
