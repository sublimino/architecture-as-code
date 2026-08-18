#!/usr/bin/env bats
#
# Whole-tree security invariants for the Terraform GCP demo platform.
#
# Offline. No network, no cloud credentials, no `terraform init`. Under 30s.
#
# ─── What belongs in this file, and what no longer does ─────────────────────
#
# CONTRACT §7a makes native `terraform test` the primary correctness surface.
# Anything about the *value* an attribute evaluates to now lives in
# `terraform/modules/{network,compute}/tests/*.tftest.hcl`, where it is
# asserted against the configuration Terraform actually computed rather than
# against the HCL text that produced it. That is a strictly stronger claim: a
# grep proves the source mentions the IAP range; the tftest proves the firewall
# rule Terraform would create has exactly that source, after variables, locals
# and conditionals resolved.
#
# What stays here is the class `terraform test` genuinely cannot express:
#
#   1. ABSENCE ACROSS THE WHOLE TREE. A plan can only see what it evaluated.
#      It cannot tell you that no `access_config` exists in any module anywhere
#      under terraform/, including modules owned by other chunks and modules no
#      root has wired up yet. That is the merge-time property, and it is the
#      one that matters most.
#   2. UNIVERSALS ACROSS THE WHOLE TREE. "Every instance in the repository sets
#      enable-oslogin" spans F3's demo VM and F5's CI runner. Neither module's
#      own tftest can see the other.
#   3. DOCUMENTATION CONTENT, FILE LAYOUT, GIT HYGIENE, and the shape of the
#      tftest suites themselves — a suite cannot audit its own existence.
#
# ─── The failure mode this file is built against ────────────────────────────
#
# A guard that greps for a forbidden pattern passes when the file it greps was
# never written. `grep -q access_config terraform/ || pass` is green on an
# empty repository, and it stays green if someone deletes the compute module.
# So every assertion below proves the artefact exists FIRST, and the mutation
# tests at the bottom prove the guards can actually fail — a guard that cannot
# fail is worse than no guard, because it reads as coverage.
#
# The mutation fixtures come in two flavours deliberately:
#
#   1. GENERATED — copied from the live tree at test time into BATS_TEST_TMPDIR
#      and broken there. These can never go stale, because they are derived
#      from whatever main.tf says today. The real tree is never mutated.
#   2. COMMITTED — static files under test/fixtures/terraform/netcompute/, as
#      the chunk contract requires. A staleness assertion checks each still
#      contains the violation it exists to carry, so a fixture that someone
#      "tidied" fails loudly rather than silently disarming its mutation test.
#
# ─── On 0.0.0.0/0 ───────────────────────────────────────────────────────────
#
# A default-deny firewall rule MUST name 0.0.0.0/0 — that is what "deny
# everything not otherwise allowed" means. A guard that banned the string
# outright would force the default-deny rules out of the tree, which is the
# opposite of the intended outcome. So the guard here is semantic: a firewall
# resource that contains BOTH an `allow {` block AND 0.0.0.0/0 is a violation;
# one that contains `deny {` and 0.0.0.0/0 is the posture working.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	export REPO_ROOT
	export TF_DIR="$REPO_ROOT/terraform"
	export NET_DIR="$TF_DIR/modules/network"
	export COMPUTE_DIR="$TF_DIR/modules/compute"
	export STARTUP="$COMPUTE_DIR/startup/demo-vm.sh"
	export FIXTURES="$REPO_ROOT/test/fixtures/terraform/netcompute"
}

setup() {
	BLOCKS="$BATS_TEST_TMPDIR/blocks"
	export BLOCKS
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Lists every .tf file under a directory, excluding provider caches.
tf_files() {
	find "$1" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null | sort
}

tftest_files() {
	find "$1" -type f -name '*.tftest.hcl' -not -path '*/.terraform/*' 2>/dev/null | sort
}

# Strips comment lines so a comment that discusses a forbidden pattern is not
# mistaken for the pattern itself.
uncommented() {
	sed -e 's/[[:space:]]*#.*$//' "$1"
}

# Git-tracked files under the given paths. Untracked build output is excluded
# by construction rather than by an exclusion list that goes stale.
tracked_sources() {
	git -C "$REPO_ROOT" ls-files -- "$@" | sed "s|^|$REPO_ROOT/|"
}

# Splits every resource of <type> under <dir> into one file per block in
# <outdir>. terraform fmt guarantees a top-level resource block closes with `}`
# in column 0, and `terraform fmt -check` is enforced separately, so this split
# is reliable on a formatted tree.
#
# Whole-block extraction rather than a fixed `grep -A<n>` window: a window is
# silently wrong the moment a comment is added inside a resource, and it fails
# by reporting the guarded attribute absent.
explode_resource_blocks() {
	local dir="$1" type="$2" outdir="$3" f base
	mkdir -p "$outdir"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		base="$(printf '%s' "${f#"$dir"/}" | tr '/' '_')"
		awk -v out="$outdir" -v src="$base" -v type="$type" '
			$0 ~ "^resource \"" type "\"" { inblock = 1; n += 1; file = out "/" src "-" n ".block" }
			inblock { print > file }
			inblock && /^}[[:space:]]*$/ { inblock = 0 }
		' "$f"
	done < <(tf_files "$dir")
}

# Firewall rules are exploded often enough to deserve a named wrapper. `.rule`
# rather than `.block` so the two glob namespaces cannot collide in one tmpdir.
explode_firewall_rules() {
	local dir="$1" outdir="$2" b
	explode_resource_blocks "$dir" "google_compute_firewall" "$outdir"
	for b in "$outdir"/*.block; do
		[ -e "$b" ] || continue
		mv "$b" "${b%.block}.rule"
	done
}

# VIOLATION SCANNER: a firewall rule that allows traffic from or to anywhere.
# Returns 1 and prints the offenders when any is found, 0 when clean.
scan_wide_open_allow() {
	local blocks="$1" b found=0
	for b in "$blocks"/*.rule; do
		[ -e "$b" ] || continue
		uncommented "$b" | grep -qE '^[[:space:]]*allow[[:space:]]*\{' || continue
		if uncommented "$b" | grep -qE '(0\.0\.0\.0/0|::/0)'; then
			echo "WIDE-OPEN ALLOW RULE: $b"
			found=1
		fi
	done
	return "$found"
}

# VIOLATION SCANNER: any access_config block, which grants an external IP.
scan_access_config() {
	local dir="$1" f found=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if uncommented "$f" | grep -qE '^[[:space:]]*access_config[[:space:]]*\{'; then
			echo "EXTERNAL IP (access_config): $f"
			found=1
		fi
	done < <(tf_files "$dir")
	return "$found"
}

# VIOLATION SCANNER: credential-shaped literals in the named FILES.
#
# Takes files, not directories, on purpose. A recursive scan of a module
# directory also reads whatever `terraform init` left behind — `.terraform/`
# and `.terraform.lock.hcl` are full of legitimate 64-character provider
# digests, so the high-entropy heuristic fires on every developer who has run
# `terraform validate` or `terraform test`. That produces a guard people learn
# to ignore, which is the same as no guard. The caller decides the file list;
# `tracked_sources` derives it from git, so only committed source is judged.
scan_credential_literals() {
	local found=0 target
	for target in "$@"; do
		[ -f "$target" ] || continue
		if grep -InE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$target" 2>/dev/null; then found=1; fi
		if grep -InE -- 'AKIA[0-9A-Z]{16}' "$target" 2>/dev/null; then found=1; fi
		if grep -InE -- '(gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}' "$target" 2>/dev/null; then found=1; fi
		if grep -InE -- 'AIza[0-9A-Za-z_-]{30,}' "$target" 2>/dev/null; then found=1; fi
		# Literal assignment to a secret-ish name. Interpolations ($ or var.)
		# are not literals, so they are excluded.
		if grep -InE -- '(password|passwd|secret|token|api_?key|private_key|credential)[[:space:]]*[:=][[:space:]]*"[^"$]{8,}"' "$target" 2>/dev/null; then found=1; fi
		# A 40+ character unbroken alphanumeric run: base64/hex key material.
		# Excludes '/' and '.' so URLs and CIDRs do not match.
		if grep -InE -- '[A-Za-z0-9+]{40,}' "$target" 2>/dev/null; then found=1; fi
	done
	return "$found"
}

# ---------------------------------------------------------------------------
# PRESENCE. Everything below depends on these, so they run first (CONTRACT §7).
# ---------------------------------------------------------------------------

@test "network module directory exists with its required files" {
	[ -d "$NET_DIR" ]
	for f in versions.tf main.tf variables.tf outputs.tf README.md; do
		[ -s "$NET_DIR/$f" ] || {
			echo "missing or empty: $NET_DIR/$f"
			return 1
		}
	done
}

@test "compute module directory exists with its required files" {
	[ -d "$COMPUTE_DIR" ]
	for f in versions.tf main.tf variables.tf outputs.tf README.md; do
		[ -s "$COMPUTE_DIR/$f" ] || {
			echo "missing or empty: $COMPUTE_DIR/$f"
			return 1
		}
	done
}

@test "startup script is version-controlled, non-empty, and executable" {
	[ -s "$STARTUP" ]
	[ -x "$STARTUP" ]
	run git -C "$REPO_ROOT" ls-files --error-unmatch "${STARTUP#"$REPO_ROOT"/}"
	[ "$status" -eq 0 ]
}

@test "firewall rules are actually present to be inspected" {
	explode_firewall_rules "$TF_DIR" "$BLOCKS"
	local count
	count="$(find "$BLOCKS" -name '*.rule' | wc -l)"
	# Below the floor means the exploder silently matched nothing and every
	# firewall assertion in this file would pass vacuously.
	[ "$count" -ge 5 ] || {
		echo "only $count firewall rules found; the block exploder is broken or the module is missing"
		return 1
	}
}

@test "instances are actually present to be inspected" {
	# The instance sweeps below all quantify over "every instance under
	# terraform/". If that set is empty they are unanimously, vacuously true.
	local instances
	instances="$(grep -rhE '^resource "google_compute_instance" ' "$TF_DIR" --include='*.tf' | wc -l)"
	[ "$instances" -ge 1 ] || {
		echo "no google_compute_instance resources found anywhere under terraform/"
		return 1
	}
}

# ---------------------------------------------------------------------------
# ABSENCE ACROSS THE WHOLE TREE
#
# The class `terraform test` cannot reach: a plan sees what it evaluated, never
# what no configuration anywhere contains. These are the merge-time guards, and
# they deliberately scan all of terraform/, including chunks I do not own.
# ---------------------------------------------------------------------------

@test "no access_config block appears anywhere under terraform/" {
	[ -d "$TF_DIR" ]
	# Guard the guard: prove there is a tree to scan before declaring it clean.
	[ "$(tf_files "$TF_DIR" | wc -l)" -ge 4 ]
	run scan_access_config "$TF_DIR"
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "no firewall rule anywhere allows traffic from or to 0.0.0.0/0 or ::/0" {
	explode_firewall_rules "$TF_DIR" "$BLOCKS"
	[ "$(find "$BLOCKS" -name '*.rule' | wc -l)" -ge 5 ]
	run scan_wide_open_allow "$BLOCKS"
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "no credential-shaped literal in either module tree or the startup script" {
	[ -d "$NET_DIR" ] && [ -d "$COMPUTE_DIR" ] && [ -s "$STARTUP" ]

	local files
	mapfile -t files < <(tracked_sources 'terraform/modules/network' 'terraform/modules/compute')

	# Guard the guard. An empty file list makes the scan below trivially clean,
	# and the startup script — the one file that is stored in instance metadata
	# in plain text — must be in it by name, not by hope.
	[ "${#files[@]}" -ge 10 ] || {
		echo "only ${#files[@]} tracked files scanned; the file list is broken"
		printf '%s\n' "${files[@]}"
		return 1
	}
	printf '%s\n' "${files[@]}" | grep -q 'startup/demo-vm.sh$' || {
		echo "the startup script is not in the scanned set"
		return 1
	}

	run scan_credential_literals "${files[@]}"
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
}

@test "no developer-machine absolute path is committed in this chunk" {
	[ -d "$NET_DIR" ] && [ -d "$COMPUTE_DIR" ]
	run grep -rn '/home/[a-z]' "$NET_DIR" "$COMPUTE_DIR" "${BATS_TEST_FILENAME}" --exclude-dir=.terraform
	[ "$status" -ne 0 ] || {
		echo "$output"
		return 1
	}
}

# ---------------------------------------------------------------------------
# UNIVERSALS ACROSS THE WHOLE TREE
#
# "Every instance in the repository" spans F3's demo VM and F5's CI runner.
# Neither module's own tftest can see the other, so the cross-chunk quantifier
# stays here. Each module's tftest asserts the values on its own evaluated
# config; what these add is that no *other* module drifts from the posture.
# ---------------------------------------------------------------------------

@test "every instance under terraform/ sets enable-oslogin and blocks project SSH keys" {
	local instances
	instances="$(grep -rhE '^resource "google_compute_instance" ' "$TF_DIR" --include='*.tf' | wc -l)"
	[ "$instances" -ge 1 ]

	local oslogin blocked
	oslogin="$(grep -rhE '^[[:space:]]*enable-oslogin[[:space:]]*=[[:space:]]*"TRUE"' "$TF_DIR" --include='*.tf' | wc -l)"
	blocked="$(grep -rhE '^[[:space:]]*block-project-ssh-keys[[:space:]]*=[[:space:]]*"TRUE"' "$TF_DIR" --include='*.tf' | wc -l)"
	[ "$oslogin" -eq "$instances" ]
	[ "$blocked" -eq "$instances" ]

	# FALSE anywhere is a straight violation, not a count mismatch.
	run grep -rE '(enable-oslogin|block-project-ssh-keys)[[:space:]]*=[[:space:]]*"FALSE"' "$TF_DIR" --include='*.tf'
	[ "$status" -ne 0 ]
}

@test "every instance under terraform/ enables all three Shielded VM protections" {
	local instances
	instances="$(grep -rhE '^resource "google_compute_instance" ' "$TF_DIR" --include='*.tf' | wc -l)"
	[ "$instances" -ge 1 ]

	local field count
	for field in enable_secure_boot enable_vtpm enable_integrity_monitoring; do
		count="$(grep -rhE "^[[:space:]]*${field}[[:space:]]*=[[:space:]]*true" "$TF_DIR" --include='*.tf' | wc -l)"
		[ "$count" -eq "$instances" ] || {
			echo "$field is true on $count of $instances instances"
			return 1
		}
		run grep -rE "^[[:space:]]*${field}[[:space:]]*=[[:space:]]*false" "$TF_DIR" --include='*.tf'
		[ "$status" -ne 0 ]
	done
}

@test "no instance anywhere uses the default compute service account" {
	[ "$(tf_files "$TF_DIR" | wc -l)" -ge 4 ]
	run grep -rE 'developer\.gserviceaccount\.com' "$TF_DIR" --include='*.tf'
	# The only permitted mention is the validation block that forbids it.
	if [ "$status" -eq 0 ]; then
		while IFS= read -r line; do
			grep -q 'endswith\|error_message' <<<"$line" || {
				echo "default compute SA referenced: $line"
				return 1
			}
		done <<<"$output"
	fi
}

# ---------------------------------------------------------------------------
# CONTRACT SURFACE — the outputs siblings wire against
#
# Not an evaluated-value property: this is the merge interface. A renamed
# output breaks F4's edge module at composition time, which no single-module
# plan can detect.
# ---------------------------------------------------------------------------

@test "both modules export their contracted outputs" {
	local o
	for o in network_self_link subnet_self_link network_tag subnet_cidr; do
		grep -qE "^output \"$o\"" "$NET_DIR/outputs.tf" || {
			echo "network module missing output $o"
			return 1
		}
	done
	for o in instance_self_link instance_name internal_ip instance_group_self_link; do
		grep -qE "^output \"$o\"" "$COMPUTE_DIR/outputs.tf" || {
			echo "compute module missing output $o"
			return 1
		}
	done
}

# ---------------------------------------------------------------------------
# DOCUMENTATION CONTENT (CONTRACT §7a routes this class to bats)
# ---------------------------------------------------------------------------

@test "the egress policy names each allowed dependency in a comment" {
	# ISC-91: the list must be documented, not merely present. The rules
	# themselves are asserted on evaluated config in the network tftest; what
	# cannot be asserted there is whether a human wrote down why they exist.
	local comments
	comments="$(grep -E '^#' "$NET_DIR/main.tf")"
	grep -qi 'dns' <<<"$comments"
	grep -qi 'private google access\|googleapis' <<<"$comments"
	grep -qi 'registr' <<<"$comments"
	grep -qi 'NAT is not egress control' <<<"$comments"
}

@test "the closed egress default is stated loudly in both NOTES.md and the module README" {
	# The chunk brief's explicit requirement. A variable that quietly defaults
	# open is how "NAT is not egress control" survives review; a variable that
	# defaults closed without anyone being told is how the demo mysteriously
	# fails to pull images. Both documents must say so.
	local doc
	for doc in "$REPO_ROOT/NOTES.md" "$NET_DIR/README.md"; do
		[ -s "$doc" ] || {
			echo "missing: $doc"
			return 1
		}
		grep -q 'enable_default_deny_egress' "$doc" || {
			echo "$doc does not name the egress gate variable"
			return 1
		}
		grep -qi 'cannot pull' "$doc" || {
			echo "$doc does not state the consequence of the closed default"
			return 1
		}
		grep -qi 'NAT is not egress control' "$doc" || {
			echo "$doc does not name the threat the default exists to close"
			return 1
		}
	done
}

@test "confidential_instance_config is addressed, not silently omitted" {
	# ISC-107. The evaluated value is asserted in the compute tftest; the
	# *reason* it is off can only live in prose.
	grep -qE '^[[:space:]]*confidential_instance_config[[:space:]]*\{' "$COMPUTE_DIR/main.tf"
	grep -qi 'confidential' "$COMPUTE_DIR/README.md"
}

# ---------------------------------------------------------------------------
# FILE LAYOUT AND TFTEST HYGIENE (CONTRACT §7a; ISC-326/327/332/334/347)
#
# A terraform test suite cannot audit its own existence, its own mock_provider
# block, or whether it only ever asserts failure.
# ---------------------------------------------------------------------------

@test "both modules ship a native terraform test suite" {
	# ISC-326, ISC-327.
	local d
	for d in "$NET_DIR" "$COMPUTE_DIR"; do
		[ -d "$d/tests" ] || {
			echo "missing $d/tests"
			return 1
		}
		[ "$(tftest_files "$d/tests" | wc -l)" -ge 1 ] || {
			echo "no .tftest.hcl under $d/tests"
			return 1
		}
	done
}

@test "every .tftest.hcl mocks its providers and never applies" {
	# ISC-332, ISC-334. Scanned across the whole terraform tree, not just this
	# chunk's: `command = apply` is an absence property and a sibling chunk
	# adding one is exactly what this should catch at merge.
	local files f
	mapfile -t files < <(tftest_files "$TF_DIR")

	# Guard the guard. Two files are this chunk's; a floor of 2 means the scan
	# cannot report clean because it found nothing.
	[ "${#files[@]}" -ge 2 ] || {
		echo "only ${#files[@]} .tftest.hcl files found; the scan is vacuous"
		return 1
	}

	for f in "${files[@]}"; do
		grep -qE '^mock_provider "google" \{' "$f" || {
			echo "no mock_provider \"google\" in $f — this test could reach a real API"
			return 1
		}
		if uncommented "$f" | grep -qE '^[[:space:]]*command[[:space:]]*=[[:space:]]*apply'; then
			echo "command = apply in $f"
			return 1
		fi
		uncommented "$f" | grep -qE '^[[:space:]]*command[[:space:]]*=[[:space:]]*plan' || {
			echo "no command = plan in $f"
			return 1
		}
	done
}

@test "every negative tftest run is paired with a passing run" {
	# ISC-346/347, and the single most common way a terraform test suite ends
	# up measuring nothing. A file that only ever asserts failure cannot tell a
	# validation firing from a syntax error, so a file using expect_failures
	# must also contain a run that asserts something positive.
	local files f
	mapfile -t files < <(tftest_files "$TF_DIR")
	[ "${#files[@]}" -ge 2 ]

	for f in "${files[@]}"; do
		grep -qE '^[[:space:]]*expect_failures' "$f" || continue
		local blocks="$BATS_TEST_TMPDIR/runs" b positive=0
		rm -rf "$blocks"
		mkdir -p "$blocks"
		awk -v out="$blocks" '
			/^run "/ { inblock = 1; n += 1; file = out "/run-" n ".block" }
			inblock { print > file }
			inblock && /^}[[:space:]]*$/ { inblock = 0 }
		' "$f"
		for b in "$blocks"/*.block; do
			grep -qE '^[[:space:]]*expect_failures' "$b" && continue
			grep -qE '^[[:space:]]*assert[[:space:]]*\{' "$b" && positive=1
		done
		[ "$positive" -eq 1 ] || {
			echo "$f has no run block that asserts a positive outcome"
			return 1
		}
	done
}

# ---------------------------------------------------------------------------
# GIT HYGIENE
# ---------------------------------------------------------------------------

@test "no terraform init artifact is committed under either module" {
	# `.terraform.lock.hcl` is only consulted in a ROOT module; in a shared child
	# module it is inert and drifts from whatever the roots (F1/F6) actually
	# lock. Both modules had one committed as a side effect of running
	# `terraform init -backend=false` in-place to validate. They are removed,
	# and this assertion stops them coming back — the previous symptom was the
	# credential scanner drowning in legitimate 64-character provider digests,
	# which is how a secrets guard becomes something people mute.
	#
	# `terraform test` needs that init to have run, so the artifacts reappear on
	# every local run. This is the guard that keeps them out of a commit.
	local artifacts
	artifacts="$(tracked_sources 'terraform/modules/network' 'terraform/modules/compute' |
		grep -E '\.terraform\.lock\.hcl$|/\.terraform/' || true)"
	[ -z "$artifacts" ] || {
		echo "terraform init artifacts are committed:"
		echo "$artifacts"
		return 1
	}
}

# ---------------------------------------------------------------------------
# MUTATION CHECKS
#
# Everything above asserts the tree is clean. These assert the guards can say
# otherwise. Without them, a scanner whose regex silently stopped matching
# would report the same green as a genuinely clean tree.
# ---------------------------------------------------------------------------

@test "MUTATION (generated): injecting access_config makes the guard fail" {
	local broken="$BATS_TEST_TMPDIR/gen-access-config"
	mkdir -p "$broken"
	cp "$COMPUTE_DIR/main.tf" "$broken/main.tf"

	# Positive control: the unmodified copy must be clean, or the mutation
	# below would prove nothing about the injection.
	run scan_access_config "$broken"
	[ "$status" -eq 0 ]

	# Inject a real external IP into the existing network_interface block.
	perl -0pi -e 's/(network_interface \{\n)/$1    access_config {}\n/' "$broken/main.tf"
	grep -q 'access_config' "$broken/main.tf"

	run scan_access_config "$broken"
	[ "$status" -eq 1 ]
	[[ "$output" == *"EXTERNAL IP"* ]]
}

@test "MUTATION (generated): widening a firewall to 0.0.0.0/0 makes the guard fail" {
	local broken="$BATS_TEST_TMPDIR/gen-wide-fw"
	mkdir -p "$broken"
	cp "$NET_DIR/main.tf" "$broken/main.tf"

	local genblocks="$BATS_TEST_TMPDIR/gen-wide-fw-blocks"
	explode_firewall_rules "$broken" "$genblocks"
	[ "$(find "$genblocks" -name '*.rule' | wc -l)" -ge 5 ]

	# Positive control on the faithful copy.
	run scan_wide_open_allow "$genblocks"
	[ "$status" -eq 0 ]

	# Widen the IAP SSH rule to the whole internet.
	sed -i 's|source_ranges           = \[local.iap_range\]|source_ranges           = ["0.0.0.0/0"]|' "$broken/main.tf"
	grep -q '"0.0.0.0/0"' "$broken/main.tf"

	local badblocks="$BATS_TEST_TMPDIR/gen-wide-fw-blocks-bad"
	explode_firewall_rules "$broken" "$badblocks"
	run scan_wide_open_allow "$badblocks"
	[ "$status" -eq 1 ]
	[[ "$output" == *"WIDE-OPEN ALLOW RULE"* ]]
}

@test "MUTATION (generated): a secret literal in the startup script makes the guard fail" {
	local broken="$BATS_TEST_TMPDIR/gen-secret/demo-vm.sh"
	mkdir -p "${broken%/*}"
	cp "$STARTUP" "$broken"

	# Positive control: the faithful copy is clean. Without this, a scanner that
	# stopped matching entirely would still pass the assertion below by luck.
	run scan_credential_literals "$broken"
	[ "$status" -eq 0 ]

	# Two independent shapes, so the test does not hinge on one regex. The
	# values are synthetic — a fake token pattern and a fake base64 run.
	printf '%s\n' 'readonly API_TOKEN="ghp_0000000000000000000000000000000000"' >>"$broken"
	run scan_credential_literals "$broken"
	[ "$status" -eq 1 ]

	cp "$STARTUP" "$broken"
	printf '%s\n' 'readonly DEPLOY_KEY="AAAAB3NzaC1yc2EAAAADAQABAAABgQCfakefakefake"' >>"$broken"
	run scan_credential_literals "$broken"
	[ "$status" -eq 1 ]
}

# The §7a guards are the newest and least exercised, so they get a mutation
# check of their own rather than being trusted because they are green.
check_tftest_dir() {
	local f
	for f in "$1"/*.tftest.hcl; do
		grep -qE '^mock_provider "google" \{' "$f" || return 1
		if uncommented "$f" | grep -qE '^[[:space:]]*command[[:space:]]*=[[:space:]]*apply'; then
			return 1
		fi
	done
	return 0
}

@test "MUTATION (generated): a tftest that applies, or drops its mock, is caught" {
	local dir="$BATS_TEST_TMPDIR/gen-tftest"
	mkdir -p "$dir"
	cp "$NET_DIR/tests"/*.tftest.hcl "$dir/a.tftest.hcl"
	cp "$COMPUTE_DIR/tests"/*.tftest.hcl "$dir/b.tftest.hcl"

	# Positive control on the faithful copies.
	run check_tftest_dir "$dir"
	[ "$status" -eq 0 ]

	sed -i '0,/^  command = plan$/s//  command = apply/' "$dir/a.tftest.hcl"
	grep -q 'command = apply' "$dir/a.tftest.hcl"
	run check_tftest_dir "$dir"
	[ "$status" -eq 1 ]

	cp "$NET_DIR/tests"/*.tftest.hcl "$dir/a.tftest.hcl"
	sed -i 's/^mock_provider "google" {}$/# removed/' "$dir/b.tftest.hcl"
	run check_tftest_dir "$dir"
	[ "$status" -eq 1 ]
}

@test "MUTATION (committed fixture): access_config fixture is still broken and still caught" {
	local fixture="$FIXTURES/broken-access-config.tf"
	[ -s "$fixture" ]
	# Staleness guard: a fixture someone "tidied" would disarm this test while
	# leaving it green.
	grep -qE '^[[:space:]]*access_config[[:space:]]*\{' "$fixture"

	local dir="$BATS_TEST_TMPDIR/fx-access"
	mkdir -p "$dir"
	cp "$fixture" "$dir/main.tf"
	run scan_access_config "$dir"
	[ "$status" -eq 1 ]
}

@test "MUTATION (committed fixture): wide-firewall fixture is still broken and still caught" {
	local fixture="$FIXTURES/broken-wide-firewall.tf"
	[ -s "$fixture" ]
	grep -q '0\.0\.0\.0/0' "$fixture"
	grep -qE '^[[:space:]]*allow[[:space:]]*\{' "$fixture"

	local dir="$BATS_TEST_TMPDIR/fx-fw" blocks="$BATS_TEST_TMPDIR/fx-fw-blocks"
	mkdir -p "$dir"
	cp "$fixture" "$dir/main.tf"
	explode_firewall_rules "$dir" "$blocks"
	[ "$(find "$blocks" -name '*.rule' | wc -l)" -ge 1 ]
	run scan_wide_open_allow "$blocks"
	[ "$status" -eq 1 ]
}

@test "MUTATION (committed fixture): the clean control fixture passes both guards" {
	# Proves the two scanners are not simply always-fail. A guard that always
	# fires is as useless as one that never does.
	local fixture="$FIXTURES/clean-control.tf"
	[ -s "$fixture" ]

	local dir="$BATS_TEST_TMPDIR/fx-clean" blocks="$BATS_TEST_TMPDIR/fx-clean-blocks"
	mkdir -p "$dir"
	cp "$fixture" "$dir/main.tf"

	run scan_access_config "$dir"
	[ "$status" -eq 0 ]

	explode_firewall_rules "$dir" "$blocks"
	[ "$(find "$blocks" -name '*.rule' | wc -l)" -ge 1 ]
	run scan_wide_open_allow "$blocks"
	[ "$status" -eq 0 ]
}
