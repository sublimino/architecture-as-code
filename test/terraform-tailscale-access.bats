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

	run grep -qF 'resource "google_secret_manager_secret_iam_member" "tailscale_authkey_accessor"' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the compute module declares no secret-scoped IAM binding"
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

	# And the Terraform side emits exactly that, on the instance.
	run grep -qF 'signalloom-tailscale-secret-id = var.tailscale_authkey_secret_id' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the compute module no longer publishes the secret NAME in metadata"
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
# THE GRANT IS SECRET-SCOPED, AND IS THE ONLY GRANT
# ---------------------------------------------------------------------------

@test "the secret grant is secret-scoped and names secretAccessor" {
	# Presence and correctness together. The resource TYPE is the control:
	# google_secret_manager_secret_iam_member binds on one secret, where
	# google_project_iam_member with the same role grants read on every secret
	# in the project, present and future.
	run grep -qE '^resource "google_secret_manager_secret_iam_member" "tailscale_authkey_accessor" \{' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ]

	run grep -qF 'role      = "roles/secretmanager.secretAccessor"' "$COMPUTE_MAIN"
	[ "$status" -eq 0 ] || {
		echo "the binding no longer names roles/secretmanager.secretAccessor"
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

@test "the compute module's IAM budget is exactly one secret-scoped binding" {
	# A count, not a value check. Adding a second IAM resource — a project
	# member, a service-account user binding, a second secret — fails here
	# rather than being noticed later. When one is genuinely needed the required
	# change is: add it, update this list, and justify it in the diff.
	local types
	types="$(iam_resource_types "${TF_DIR}/modules/compute")"
	[ "$types" = "google_secret_manager_secret_iam_member" ] || {
		echo "the compute module's IAM resource types are now:"
		printf '  %s\n' "$types"
		echo "Expected exactly: google_secret_manager_secret_iam_member"
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

@test "MUTATION: widening the grant to project scope is caught" {
	local mutated dir
	dir="${BATS_TEST_TMPDIR}/mut-iam"
	mkdir -p "$dir"
	cp "$COMPUTE_MAIN" "${dir}/main.tf"
	sed -i -e 's|^resource "google_secret_manager_secret_iam_member" "tailscale_authkey_accessor" {|resource "google_project_iam_member" "tailscale_authkey_accessor" {|' "${dir}/main.tf"
	run cmp -s "$COMPUTE_MAIN" "${dir}/main.tf"
	[ "$status" -ne 0 ]

	run scan_project_scoped_secret_grant "$dir"
	[ "$status" -eq 1 ]
	[[ "$output" == *"PROJECT-SCOPED SECRET GRANT"* ]]

	# Clean control against the real tree.
	run scan_project_scoped_secret_grant "$TF_DIR"
	[ "$status" -eq 0 ]
}

@test "MUTATION: the project-scope scanner reports a missing directory distinctly" {
	run scan_project_scoped_secret_grant "${BATS_TEST_TMPDIR}/no-such-dir"
	[ "$status" -eq 2 ]
}

@test "MUTATION: a second IAM resource breaks the compute permission budget" {
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
	[ "$output" != "google_secret_manager_secret_iam_member" ]
	[[ "$output" == *"google_project_iam_member"* ]]

	# Clean control: the real module still holds exactly one.
	run iam_resource_types "${TF_DIR}/modules/compute"
	[ "$status" -eq 0 ]
	[ "$output" = "google_secret_manager_secret_iam_member" ]
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
