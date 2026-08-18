#!/usr/bin/env bats
#
# The demo VM's provisioning/deployment split, and the prerequisites that make
# it survivable — expressed as tests rather than as a paragraph in a header.
#
# ─── The rule this file exists to keep ──────────────────────────────────────
#
# `terraform/modules/compute/startup/demo-vm.sh` installs Docker, kind, kubectl
# and the handful of packages the pipeline cannot install for itself, and then
# it STOPS. It does not create a cluster and it does not deploy the estate.
#
# That is not tidiness. A startup script runs exactly once, at instance
# creation, as root, with its output going to the serial console. Fold the
# deployment into it and the deployment becomes something nobody can re-run: to
# retry a failed deploy you must delete and recreate the VM, and to debug one
# you must read a console log. Keeping deployment in the pipeline makes it a
# thing you can run again, from a shell, with the output in front of you.
#
# The header of that script states this. A header is a claim; this file is the
# enforcement.
#
# ─── Why the guard strips comments first ────────────────────────────────────
#
# The script's own documentation names `make demo-signalloom-up`,
# `install-ci-tools.sh` and `make ci-tools` in prose, because explaining the
# split requires naming the thing on the other side of it. A guard matching raw
# text would fire on that explanation and report the correctly-written script as
# broken — and a guard that fails on correct input gets switched off. So every
# match below runs over code with comments removed, and
# `hides-it-in-a-comment.sh` is the fixture that proves the stripping works.
#
# Offline: no network, no cloud credentials, no terraform, no gcloud.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export COMPUTE_DIR="${REPO_ROOT}/terraform/modules/compute"
	export STARTUP="${COMPUTE_DIR}/startup/demo-vm.sh"
	export COMPUTE_VARS="${COMPUTE_DIR}/variables.tf"
	export COMPUTE_MAIN="${COMPUTE_DIR}/main.tf"
	export NET_MAIN="${REPO_ROOT}/terraform/modules/network/main.tf"
	export NET_VARS="${REPO_ROOT}/terraform/modules/network/variables.tf"
	export FIXTURES="${REPO_ROOT}/test/fixtures/terraform/vm-profile"
}

setup() {
	# Presence first, always (CONTRACT.md §6: no test that passes vacuously).
	# Every assertion in this file is "X is absent from Y"; if Y does not exist,
	# X is absent from it for the wrong reason.
	[ -f "$STARTUP" ]
	[ -f "$COMPUTE_VARS" ]
	[ -f "$COMPUTE_MAIN" ]
	[ -f "$NET_MAIN" ]
	[ -f "$NET_VARS" ]
	[ -d "$FIXTURES" ]
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Executable lines only: comments stripped, blank lines dropped. `|| true`
# because grep exits 1 on an all-blank file, which is a legitimate (if useless)
# input and not an error here — the emptiness check is done by the caller, which
# can say something more useful about it.
code_only() {
	sed -e 's/[[:space:]]*#.*$//' "$1" | grep -v '^[[:space:]]*$' || true
}

# The detector. Prints every executable line that creates a cluster or deploys
# the application; prints nothing when the script is correct.
#
# `helm` and `flux` are matched as whole words with a command-position anchor,
# not as substrings: the script legitimately handles a file called
# `kind-linux-amd64` and a variable called KIND_VERSION, and a substring match
# on "kind" would make the guard unusable on the very script it guards.
deployment_verbs_in() {
	code_only "$1" | grep -nE \
		'kind[[:space:]]+create[[:space:]]+cluster|make[[:space:]]+demo|demo-signalloom|(^|[[:space:]/])(helm|flux|kustomize)[[:space:]]|kubectl[[:space:]]+apply' \
		|| true
}

# ---------------------------------------------------------------------------
# The split itself
# ---------------------------------------------------------------------------

@test "the startup script creates no cluster and deploys no application" {
	local body findings
	body="$(code_only "$STARTUP")"

	# Positive control, and it is the whole reason this test is not vacuous.
	# "No findings" is the same output whether the script is clean or whether
	# code_only returned nothing at all — a moved file, a renamed function, a
	# sed that ate the file. Anchoring on a line that must exist distinguishes
	# them.
	[ -n "$body" ] || {
		echo "code_only produced nothing from ${STARTUP}; the guard would" >&2
		echo "report a clean result having examined no code at all." >&2
		return 1
	}
	printf '%s\n' "$body" | grep -q 'install_docker' || {
		echo "the startup script no longer contains install_docker; either it" >&2
		echo "moved or the comment-stripping is eating executable lines." >&2
		return 1
	}

	findings="$(deployment_verbs_in "$STARTUP")"
	[ -z "$findings" ] || {
		echo "the startup script has taken on deployment work:" >&2
		printf '%s\n' "$findings" >&2
		echo "" >&2
		echo "Provisioning and deployment are separate on purpose. A startup" >&2
		echo "script runs once, at instance creation; a deploy folded into it" >&2
		echo "cannot be re-run without rebuilding the VM." >&2
		return 1
	}
}

@test "the startup script's header still states the split it keeps" {
	# The prose and the enforcement must not drift apart. If someone removes the
	# rule they should have to remove the explanation too, and notice.
	grep -qF 'does NOT deploy the demo' "$STARTUP" || {
		echo "the startup script no longer documents that it does not deploy." >&2
		return 1
	}
	grep -qiE "startup script that also deploys is a startup script nobody can re-run" "$STARTUP" || {
		echo "the reason for the split is gone from the header; the rule is" >&2
		echo "then a preference nobody can argue with or against." >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Mutation: the guard is proven to fail, on copies, one verb at a time.
#
# One fixture per pattern. A single fixture containing all five would still fire
# if four patterns worked and the fifth had a typo — which is exactly the defect
# a mutation check exists to catch, and exactly the one it would then hide.
# ---------------------------------------------------------------------------

@test "the guard fires on every forbidden verb, one fixture at a time" {
	local f checked=0 findings
	for f in creates-a-cluster runs-a-make-demo-target deploys-signalloom \
		installs-a-helm-release bootstraps-flux; do
		[ -f "${FIXTURES}/${f}.sh" ] || {
			echo "missing mutation fixture: ${FIXTURES}/${f}.sh" >&2
			return 1
		}
		findings="$(deployment_verbs_in "${FIXTURES}/${f}.sh")"
		[ -n "$findings" ] || {
			echo "the guard did NOT fire on ${f}.sh, which deploys." >&2
			echo "That pattern is dead: the real script could contain the same" >&2
			echo "line and this suite would stay green." >&2
			return 1
		}
		checked=$((checked + 1))
	done

	# A loop that iterated over nothing reports the same silence as a loop that
	# checked everything and found it correct.
	[ "$checked" -eq 5 ] || {
		echo "expected to exercise 5 fixtures, exercised ${checked}" >&2
		return 1
	}
}

@test "the guard fires on a realistic mutation of the real script" {
	# The fixtures above are synthetic four-line scripts. This is the mutation
	# that would actually happen: someone appends a deploy to the end of the real
	# script. Done on a COPY — the real tree is never modified (CONTRACT.md §7).
	local mutated="${BATS_TEST_TMPDIR}/demo-vm-that-deploys.sh"
	cp "$STARTUP" "$mutated"

	# Clean first, or a fixture that was already dirty proves nothing.
	local before
	before="$(deployment_verbs_in "$mutated")"
	[ -z "$before" ] || {
		echo "the unmodified copy already reports findings; the before/after" >&2
		echo "comparison below would be meaningless:" >&2
		printf '%s\n' "$before" >&2
		return 1
	}

	printf 'kind create cluster --name signalloom --config /opt/kind.yaml\n' >>"$mutated"
	printf 'make demo-signalloom-up\n' >>"$mutated"

	local after
	after="$(deployment_verbs_in "$mutated")"
	[ -n "$after" ] || {
		echo "the guard did not fire on a real script with a deploy appended." >&2
		return 1
	}
}

@test "the guard does not fire on forbidden verbs that are only discussed" {
	# The inverse control. Comments naming the deployment are how the split gets
	# explained; a guard that cannot tell prose from code is a guard that will be
	# deleted the first time it blocks a correct commit.
	local findings
	findings="$(deployment_verbs_in "${FIXTURES}/hides-it-in-a-comment.sh")"
	[ -z "$findings" ] || {
		echo "the guard fired on commented-out verbs; it cannot distinguish" >&2
		echo "documentation from code:" >&2
		printf '%s\n' "$findings" >&2
		return 1
	}

	# And it is not simply silent on that file for an unrelated reason.
	[ -n "$(code_only "${FIXTURES}/hides-it-in-a-comment.sh")" ] || {
		echo "the inverse-control fixture has no executable lines at all, so" >&2
		echo "its silence proves nothing about comment stripping." >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Prerequisites: the small set the pipeline cannot install for itself
# ---------------------------------------------------------------------------

@test "the startup script installs the prerequisites the pipeline cannot" {
	# git   — install-ci-tools.sh installs bats by `git clone`, and
	#         vm-pipeline.sh runs `git init` so Kustomize resolves the tree.
	# make  — the whole pipeline is make targets.
	# curl  — every fetch in the installer and in fetch_verified.
	#
	# Asserted against executable lines, so a prerequisite that is only
	# mentioned in a comment does not count as installed.
	local body pkg missing=()
	body="$(code_only "$STARTUP")"

	for pkg in git make curl ca-certificates gnupg; do
		printf '%s\n' "$body" | grep -qE "(^|[[:space:]])${pkg}([[:space:]]|$|\\\\)" ||
			missing+=("$pkg")
	done

	[ "${#missing[@]}" -eq 0 ] || {
		echo "the startup script does not install: ${missing[*]}" >&2
		echo "Without them scripts/ci/install-ci-tools.sh cannot run at all," >&2
		echo "and the failure surfaces as a pipeline error on a healthy VM." >&2
		return 1
	}
}

@test "the base packages install unconditionally, not behind the docker guard" {
	# The bug this catches, which was live: the base packages were installed
	# inside install_docker, which early-returns when docker is already present.
	# On any image shipping docker, curl and gnupg were therefore never
	# installed and the first fetch_verified died — on a VM that looked fine.
	grep -qE '^install_base_packages\(\)' "$STARTUP" || {
		echo "install_base_packages is gone; the base packages are back inside" >&2
		echo "a function that can early-return." >&2
		return 1
	}

	# Present is not the same as called. Assert it is invoked from main(), and
	# before install_docker, which is the ordering that matters.
	local main_body base_line docker_line
	main_body="$(sed -n '/^main()/,/^}/p' "$STARTUP")"
	[ -n "$main_body" ] || {
		echo "could not extract main() from the startup script; this check" >&2
		echo "would be vacuous." >&2
		return 1
	}

	base_line="$(printf '%s\n' "$main_body" | grep -n 'install_base_packages' | head -1 | cut -d: -f1)"
	docker_line="$(printf '%s\n' "$main_body" | grep -n 'install_docker' | head -1 | cut -d: -f1)"

	[ -n "$base_line" ] || {
		echo "main() never calls install_base_packages; the function exists" >&2
		echo "and nothing runs it." >&2
		return 1
	}
	[ -n "$docker_line" ] || {
		echo "main() never calls install_docker; the ordering check below" >&2
		echo "would compare against nothing." >&2
		return 1
	}
	[ "$base_line" -lt "$docker_line" ] || {
		echo "install_base_packages runs after install_docker (${base_line} vs" >&2
		echo "${docker_line}); docker's apt source needs gnupg and curl first." >&2
		return 1
	}
}

@test "the startup script keeps its checksum discipline and its marker" {
	# fetch_verified is the only download path, and it aborts on a mismatch
	# rather than degrading to an unverified install.
	grep -qE '^fetch_verified\(\)' "$STARTUP" || {
		echo "fetch_verified is gone; downloads are no longer checksum-verified." >&2
		return 1
	}
	grep -qF 'checksum mismatch for' "$STARTUP" || {
		echo "the checksum mismatch abort is gone from fetch_verified." >&2
		return 1
	}
	grep -qF 'sha256sum' "$STARTUP" || {
		echo "nothing in the startup script computes a sha256." >&2
		return 1
	}

	# Idempotency: re-running must be cheap, because a startup script that is
	# expensive to re-run is one people avoid re-running.
	grep -qF 'MARKER=' "$STARTUP" || {
		echo "the bootstrap marker is gone; the script is no longer idempotent." >&2
		return 1
	}
	grep -qF 'already bootstrapped' "$STARTUP" || {
		echo "the marker no longer short-circuits a second run." >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# The IAP posture, as a whole-tree property.
#
# The evaluated assertions live in modules/network/tests/network.tftest.hcl —
# `terraform test` can prove the rule it planned has the right source range, and
# is the better surface for it. What it cannot prove is that NO OTHER source
# range appears anywhere in the module, because a plan only ever sees the
# configuration it evaluated. That is what these are for.
# ---------------------------------------------------------------------------

@test "no ingress allow rule in the network module names a non-IAP source" {
	# Scans the whole module, not main.tf alone. The IAP range is the default of
	# `var.iap_source_range` and therefore lives in variables.tf; a check pinned
	# to main.tf would find it only in a comment, and a guard satisfied by prose
	# is a guard that has stopped measuring anything.
	local body allow_sources
	body="$(code_only "$NET_MAIN"; code_only "$NET_VARS")"
	[ -n "$body" ] || {
		echo "code_only produced nothing from ${NET_MAIN} or ${NET_VARS}" >&2
		return 1
	}

	# Every literal CIDR that appears in the module, minus the ones that are
	# legitimately there: the IAP range, the two health-check ranges, the two
	# Private Google Access VIP ranges, the metadata server, and the 0.0.0.0/0
	# that both deny rules name.
	local unexpected
	unexpected="$(printf '%s\n' "$body" |
		grep -oE '"[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}"' |
		sort -u |
		grep -vE '"(35\.235\.240\.0/20|130\.211\.0\.0/22|35\.191\.0\.0/16|199\.36\.153\.(4|8)/30|169\.254\.169\.254/32|0\.0\.0\.0/0)"' || true)"

	[ -z "$unexpected" ] || {
		echo "modules/network names CIDRs that are not on the reviewed list:" >&2
		printf '%s\n' "$unexpected" >&2
		return 1
	}

	# Positive control: the extraction found the ranges that ARE expected. An
	# extraction that matched nothing would produce the same empty "unexpected".
	allow_sources="$(printf '%s\n' "$body" | grep -cE '"35\.235\.240\.0/20"' || true)"
	[ "$allow_sources" -ge 1 ] || {
		echo "the IAP range literal was not found in the network module's" >&2
		echo "executable lines; the CIDR extraction above examined nothing." >&2
		return 1
	}
}

@test "the SSH rule and the app-port rule are separate resources" {
	# Two exposures, two rules, two names. A single rule opening 22 and the app
	# port would satisfy every functional test and would be called
	# "allow-iap-ssh" in the console, which is a name that lies.
	grep -qE 'resource "google_compute_firewall" "allow_iap_ssh"' "$NET_MAIN" || {
		echo "allow_iap_ssh is gone from ${NET_MAIN}." >&2
		return 1
	}
	grep -qE 'resource "google_compute_firewall" "allow_iap_app_port"' "$NET_MAIN" || {
		echo "allow_iap_app_port is gone; the application is either unreachable" >&2
		echo "over IAP or has been folded into the SSH rule." >&2
		return 1
	}

	# And the SSH rule still opens 22 alone. Extracted from the resource block
	# rather than from the file, so a "22" elsewhere cannot satisfy it.
	local ssh_ports
	ssh_ports="$(sed -n '/resource "google_compute_firewall" "allow_iap_ssh"/,/^}/p' "$NET_MAIN" |
		sed -n 's/.*ports[[:space:]]*=[[:space:]]*\(.*\)/\1/p')"
	[ -n "$ssh_ports" ] || {
		echo "could not parse the ports of allow_iap_ssh; check would be vacuous" >&2
		return 1
	}
	[ "$ssh_ports" = '["22"]' ] || {
		echo "allow_iap_ssh no longer opens exactly port 22: ${ssh_ports}" >&2
		echo "The app port belongs in allow_iap_app_port, not here." >&2
		return 1
	}
}

@test "the app-port firewall rule derives its port and hardcodes nothing" {
	local block
	block="$(sed -n '/resource "google_compute_firewall" "allow_iap_app_port"/,/^}/p' "$NET_MAIN")"
	[ -n "$block" ] || {
		echo "could not extract the allow_iap_app_port block" >&2
		return 1
	}

	printf '%s\n' "$block" | grep -qF 'tostring(var.app_port)' || {
		echo "the app-port rule does not derive its port from var.app_port." >&2
		echo "A hardcoded port silently ignores the environment map, and the" >&2
		echo "symptom is a demo that will not log in." >&2
		return 1
	}

	# No numeric port literal anywhere in the block.
	local literal
	literal="$(printf '%s\n' "$block" |
		sed -e 's/[[:space:]]*#.*$//' |
		grep -nE 'ports[[:space:]]*=[[:space:]]*\[[[:space:]]*"[0-9]+"' || true)"
	[ -z "$literal" ] || {
		echo "the app-port rule hardcodes a port literal:" >&2
		printf '%s\n' "$literal" >&2
		return 1
	}
}

@test "30754 is documented as load-bearing wherever it is set" {
	# The number is not a preference. Dex pins its OIDC issuer and callback to
	# it, so any other value reaches the Gateway and then fails the login
	# redirect — a failure that presents as a broken application. Anywhere it is
	# configured, the reason must travel with it, or the next person to see an
	# odd port number will "tidy" it to 8080.
	local f checked=0
	for f in "${REPO_ROOT}/terraform/environments/demo-1.tfvars.example" \
		"${REPO_ROOT}/terraform/environments/demo-1-and-demo-2.tfvars.example" \
		"${REPO_ROOT}/deploy/gcp/sl-port-over-sandbox.example.tfvars"; do
		[ -f "$f" ] || {
			echo "missing example: $f" >&2
			return 1
		}
		grep -qE '^[[:space:]]*app_port[[:space:]]*=[[:space:]]*30754$' "$f" || {
			echo "$(basename "$f") does not set app_port = 30754" >&2
			return 1
		}
		grep -qiF 'dex' "$f" || {
			echo "$(basename "$f") sets 30754 without saying why. The next" >&2
			echo "reader will assume it is arbitrary." >&2
			return 1
		}
		checked=$((checked + 1))
	done

	[ "$checked" -eq 3 ] || {
		echo "expected to check 3 example files, checked ${checked}" >&2
		return 1
	}
}

# ---------------------------------------------------------------------------
# Sizing. The evaluated behaviour is in modules/compute/tests/compute.tftest.hcl;
# what is asserted here is that the rules exist at all, so that a `terraform
# test` suite cannot go green against a module that lost them.
# ---------------------------------------------------------------------------

@test "the compute module still carries a machine-type floor" {
	grep -qF 'COMPUTE-RULE-01-MACHINE-TYPE-VCPU' "$COMPUTE_VARS" || {
		echo "the machine-type vCPU floor is gone from ${COMPUTE_VARS}." >&2
		echo "Without it e2-standard-4 plans cleanly and the acceptance suite" >&2
		echo "times out forty minutes later." >&2
		return 1
	}
	grep -qF 'COMPUTE-RULE-03-BOOT-DISK' "$COMPUTE_VARS" || {
		echo "the boot-disk floor is gone from ${COMPUTE_VARS}." >&2
		return 1
	}

	# The measured profile is the default, not merely a permitted value.
	grep -qE 'default[[:space:]]*=[[:space:]]*"n2-standard-16"' "$COMPUTE_VARS" || {
		echo "the default machine type is no longer the measured n2-standard-16." >&2
		return 1
	}
	grep -qE 'default[[:space:]]*=[[:space:]]*200$' "$COMPUTE_VARS" || {
		echo "the default boot disk is no longer the measured 200GB." >&2
		return 1
	}
}

@test "a machine-type change is an update, not a rebuild" {
	# allow_stopping_for_update is what makes a resize stop-and-start the
	# instance instead of failing the apply. Losing it does not fail a plan; it
	# fails the apply, half-way, on a live demo.
	grep -qE '^[[:space:]]*allow_stopping_for_update[[:space:]]*=[[:space:]]*true$' "$COMPUTE_MAIN" || {
		echo "allow_stopping_for_update is no longer true in ${COMPUTE_MAIN}." >&2
		echo "A machine_type change will now plan cleanly and then fail the" >&2
		echo "apply with \"instance must be stopped\"." >&2
		return 1
	}

	# And the confidential block stays dynamic. Declared unconditionally it
	# produced a perpetual diff on a ForceNew attribute, so every plan proposed
	# replacing a healthy VM — observed live on sl-demo-1-vm.
	grep -qE '^[[:space:]]*dynamic "confidential_instance_config"' "$COMPUTE_MAIN" || {
		echo "confidential_instance_config is no longer a dynamic block. An" >&2
		echo "unconditional block makes every plan propose replacing the VM." >&2
		return 1
	}
}
