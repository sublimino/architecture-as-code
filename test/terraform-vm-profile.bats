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

# ---------------------------------------------------------------------------
# Docker socket access for OS Login users.
#
# The measured failure: `docker info` -> permission denied on
# /var/run/docker.sock, while the daemon is active and enabled. The CI tooling
# then reports "Docker daemon is not running", which is false and sends people
# to restart a healthy daemon.
# ---------------------------------------------------------------------------

@test "the startup script grants OS Login users access to the docker socket" {
	local body
	body="$(code_only "$STARTUP")"

	# Mechanism 1: the guest agent places new OS Login accounts in `docker`.
	grep -qE '^configure_oslogin_groups\(\)' "$STARTUP" || {
		echo "configure_oslogin_groups is gone. OS Login accounts will not" >&2
		echo "receive the docker group, and every pipeline run will fail with" >&2
		echo "a socket permission error misreported as a stopped daemon." >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qF '/etc/default/instance_configs.cfg' || {
		echo "the guest-agent account config path is gone from the script." >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qE '^groups = .*\bdocker\b' || {
		echo "the configured OS Login supplementary groups no longer include" >&2
		echo "docker; the file is written but grants nothing." >&2
		return 1
	}

	# Mechanism 2: the self-heal backstop.
	grep -qE '^install_docker_group_selfheal\(\)' "$STARTUP" || {
		echo "install_docker_group_selfheal is gone; there is no backstop for" >&2
		echo "an account the guest agent missed." >&2
		return 1
	}
	printf '%s\n' "$body" | grep -qF '/etc/profile.d/99-signalloom-docker-group.sh' || {
		echo "the self-heal profile snippet path is gone." >&2
		return 1
	}

	# Both are called, and after install_docker — the guest agent skips a group
	# that does not exist, and the snippet is pointless without a socket.
	local main_body docker_line groups_line selfheal_line
	main_body="$(sed -n '/^main()/,/^}/p' "$STARTUP")"
	[ -n "$main_body" ] || {
		echo "could not extract main(); this ordering check would be vacuous" >&2
		return 1
	}
	docker_line="$(printf '%s\n' "$main_body" | grep -n '^  install_docker$' | head -1 | cut -d: -f1)"
	groups_line="$(printf '%s\n' "$main_body" | grep -n 'configure_oslogin_groups' | head -1 | cut -d: -f1)"
	selfheal_line="$(printf '%s\n' "$main_body" | grep -n 'install_docker_group_selfheal' | head -1 | cut -d: -f1)"

	[ -n "$docker_line" ] && [ -n "$groups_line" ] && [ -n "$selfheal_line" ] || {
		echo "main() does not call all three of install_docker," >&2
		echo "configure_oslogin_groups and install_docker_group_selfheal;" >&2
		echo "a function that exists and is never called is dead code." >&2
		return 1
	}
	[ "$groups_line" -gt "$docker_line" ] || {
		echo "configure_oslogin_groups runs BEFORE install_docker. The guest" >&2
		echo "agent skips groups that do not exist yet, so the docker group" >&2
		echo "would silently not be applied." >&2
		return 1
	}
	[ "$selfheal_line" -gt "$docker_line" ] || {
		echo "install_docker_group_selfheal runs before install_docker" >&2
		return 1
	}
}

@test "the docker-group fix embeds no username and does not widen the socket" {
	local body
	body="$(code_only "$STARTUP")"

	# The dead-code shape this repo keeps getting burned by: a usermod naming a
	# fixed user. OS Login accounts are sa_<numeric-id> or <user>_<domain> and
	# are created at first login, so any literal here matches nobody and
	# succeeds silently.
	local fixed
	fixed="$(printf '%s\n' "$body" |
		grep -nE 'usermod[[:space:]]+-aG[[:space:]]+docker[[:space:]]+[a-z][a-z0-9_-]*[[:space:]]*$' || true)"
	[ -z "$fixed" ] || {
		echo "the script adds a HARDCODED username to the docker group:" >&2
		printf '%s\n' "$fixed" >&2
		echo "OS Login provisions the account at first login; this name" >&2
		echo "matches nobody and the command succeeds having done nothing." >&2
		return 1
	}

	# The rejected alternative. Root-equivalent socket access for every local
	# account. This assertion is meaningful only because the two positive
	# existence checks in the previous test passed — on their own, "no 0666"
	# is satisfied best by a script that does nothing about docker at all.
	local widened
	widened="$(printf '%s\n' "$body" |
		grep -nE 'SocketMode[[:space:]]*=[[:space:]]*0?666|chmod[[:space:]]+(a\+rw|0?666).*docker\.sock' || true)"
	[ -z "$widened" ] || {
		echo "the script world-writes the docker socket:" >&2
		printf '%s\n' "$widened" >&2
		echo "Docker socket access is root-equivalent. See the README for why" >&2
		echo "this was rejected in favour of group membership." >&2
		return 1
	}
}

@test "the README warns that the CI tooling misreports the socket failure" {
	local readme="${COMPUTE_DIR}/README.md"
	[ -f "$readme" ]

	grep -qiF 'wrong about the cause' "$readme" || {
		echo "the README no longer warns that 'Docker daemon is not running'" >&2
		echo "is a false diagnosis. The next person will restart a healthy" >&2
		echo "daemon and lose a bring-up to it." >&2
		return 1
	}
	grep -qF '/var/run/docker.sock' "$readme" || {
		echo "the README does not name the socket, so the warning cannot be" >&2
		echo "matched to the error a reader actually has in front of them." >&2
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

# Splits every google_compute_firewall resource in $1 into one file per block
# under $2, named after the resource. terraform fmt guarantees a top-level
# block closes with `}` in column zero, which is what makes this safe.
split_firewall_blocks() {
	mkdir -p "$2"
	awk -v out="$2" '
		/^resource "google_compute_firewall" "/ {
			name = $0
			sub(/^resource "google_compute_firewall" "/, "", name)
			sub(/".*$/, "", name)
			f = out "/" name ".tf"
			inblock = 1
		}
		inblock { print > f }
		/^}$/ { inblock = 0 }
	' "$1"
}

@test "REGRESSION: the app port is granted from the IAP range by some rule" {
	# The regression this guard exists for, in its own words: app_port was open
	# ONLY to Google's load-balancer health-check ranges. This environment has no
	# load balancer — hostname and dns_managed_zone are both "" by design — so
	# those ranges reach it never, and an IAP tunnel to the app port was dropped
	# by deny_all_ingress. It presented as 4003 'failed to connect to backend',
	# which reads as a dead application rather than a closed port.
	#
	# Written as a POSITIVE existence requirement, deliberately. The obvious
	# phrasing — "no rule opens app_port to the world" — is satisfied most
	# completely by a tree with no app-port rule at all, which is precisely the
	# broken state. This one counts the grants and fails at zero.
	local blocks="${BATS_TEST_TMPDIR}/fw"
	split_firewall_blocks "$NET_MAIN" "$blocks"

	# Positive control before any counting: the splitter found rules at all. A
	# splitter whose pattern stopped matching yields zero blocks, and "zero
	# grants" would then be a fact about awk rather than about the firewall.
	local found
	found="$(find "$blocks" -name '*.tf' | wc -l)"
	[ "$found" -ge 4 ] || {
		echo "the firewall-block splitter found only ${found} rules in" >&2
		echo "${NET_MAIN}; it has stopped parsing and every count below" >&2
		echo "would be meaningless." >&2
		return 1
	}

	# Rules that are INGRESS, grant app_port, and are sourced from the IAP range.
	local f grants=0 granting_rules=()
	for f in "$blocks"/*.tf; do
		grep -qF 'direction = "INGRESS"' "$f" || continue
		grep -qE '^[[:space:]]*allow \{' "$f" || continue
		grep -qF 'var.app_port' "$f" || continue
		# local.iap_range resolves to var.iap_source_range, which NET-RULE-01
		# pins to 35.235.240.0/20. Either spelling counts as the IAP source.
		grep -qE 'source_ranges[^=]*=.*(local\.iap_range|var\.iap_source_range|35\.235\.240\.0/20)' "$f" || continue
		grants=$((grants + 1))
		granting_rules+=("$(basename "$f" .tf)")
	done

	[ "$grants" -ge 1 ] || {
		echo "NO ingress rule grants app_port from the IAP range." >&2
		echo "" >&2
		echo "This is the exact outage that was reproduced live: with no load" >&2
		echo "balancer in this environment, the health-check ranges never reach" >&2
		echo "it, so app_port open to health checks alone is app_port open to" >&2
		echo "nobody. An IAP tunnel then fails with" >&2
		echo "  ERROR: ... [4003: 'failed to connect to backend']" >&2
		echo "which reads as a broken application, not as a closed port." >&2
		echo "" >&2
		echo "Ingress allow rules that mention app_port:" >&2
		for f in "$blocks"/*.tf; do
			grep -qF 'var.app_port' "$f" || continue
			echo "  $(basename "$f" .tf): $(grep -o 'source_ranges.*' "$f" | head -1)" >&2
		done
		return 1
	}
}

@test "REGRESSION: app_port is granted from the IAP range and nowhere unexpected" {
	# The other half. Every ingress rule that grants app_port must be sourced
	# from the IAP range or from the two Google health-check ranges — and from
	# nothing else. Together with the test above (at least one grant exists),
	# this pins both directions: the grant is present AND it is narrow.
	local blocks="${BATS_TEST_TMPDIR}/fw"
	split_firewall_blocks "$NET_MAIN" "$blocks"

	local f checked=0 bad=()
	for f in "$blocks"/*.tf; do
		grep -qF 'direction = "INGRESS"' "$f" || continue
		grep -qE '^[[:space:]]*allow \{' "$f" || continue
		grep -qF 'var.app_port' "$f" || continue
		checked=$((checked + 1))
		grep -qE 'source_ranges[^=]*=.*(local\.iap_range|var\.iap_source_range|local\.health_check_ranges)' "$f" ||
			bad+=("$(basename "$f" .tf)")
	done

	[ "$checked" -ge 1 ] || {
		echo "no ingress allow rule mentions var.app_port at all; this check" >&2
		echo "examined nothing. See the REGRESSION test above." >&2
		return 1
	}
	[ "${#bad[@]}" -eq 0 ] || {
		echo "these rules grant app_port from an unreviewed source: ${bad[*]}" >&2
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

@test "both egress_public_ports defaults are 443 alone, module AND root" {
	# The root default is the one that actually governs. The moment
	# environments/main.tf wires `egress_public_ports = var.egress_public_ports`
	# into the module, the MODULE's default is dead configuration and this one
	# decides. A root defaulting to ["80","443"] would open plaintext egress for
	# every environment while every module test stayed green — the module would
	# be behaving exactly as designed with the input it was handed.
	#
	# Found by mutation: adding 80 to the root default broke nothing at all
	# until this test existed.
	local f checked=0
	for f in "${REPO_ROOT}/terraform/modules/network/variables.tf" \
		"${REPO_ROOT}/terraform/environments/variables.tf"; do
		[ -f "$f" ] || {
			echo "missing variables file: $f" >&2
			return 1
		}

		# Presence before behaviour: the variable must be declared here at all,
		# or "no bad default" is a fact about a variable that does not exist.
		grep -qE '^variable "egress_public_ports" \{' "$f" || {
			echo "$(basename "$(dirname "$f")")/variables.tf does not declare" >&2
			echo "egress_public_ports; the port list is then unreachable from" >&2
			echo "tfvars and the container build has no supported fix." >&2
			return 1
		}

		local default_line
		default_line="$(sed -n '/^variable "egress_public_ports" {/,/^}/p' "$f" |
			sed -n 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*//p' | head -1)"
		[ -n "$default_line" ] || {
			echo "no default found for egress_public_ports in $f; a variable" >&2
			echo "with no default forces every caller to set it, which is not" >&2
			echo "what the fail-closed design intends." >&2
			return 1
		}
		[ "$default_line" = '["443"]' ] || {
			echo "egress_public_ports defaults to ${default_line} in $f," >&2
			echo "not [\"443\"]. Opening plaintext egress must be a" >&2
			echo "per-environment decision recorded in a reviewed tfvars file," >&2
			echo "not a default nobody rereads." >&2
			return 1
		}
		checked=$((checked + 1))
	done

	[ "$checked" -eq 2 ] || {
		echo "expected to check 2 variables.tf files, checked ${checked}" >&2
		return 1
	}

	# And the root actually passes it down. A mirrored variable that is never
	# wired is a value an operator sets in tfvars to no effect whatsoever.
	grep -qE '^[[:space:]]*egress_public_ports[[:space:]]*=[[:space:]]*var\.egress_public_ports$' \
		"${REPO_ROOT}/terraform/environments/main.tf" || {
		echo "the environments root declares egress_public_ports but never" >&2
		echo "passes it to modules/network. Setting it in tfvars would then" >&2
		echo "change nothing, silently." >&2
		return 1
	}
}

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
