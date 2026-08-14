#!/usr/bin/env bats
#
# No CI environment variable that names a directory may be relative.
#
# This is the THIRD instance of one defect class in this repo. Each time, an
# absolute-vs-relative assumption crossed a process boundary and silently
# produced a path nobody intended:
#
#   1. `../$(KEYS_DIR)` at bootstrap-local, after 72d0166 made KEYS_DIR absolute.
#      Expanded to `..//home/ci/osramp-demo/.keys/cosign.pub`, aborted BOTH GCP
#      lanes before stage 1, and the error told you to run `make signing-keys`,
#      which had already succeeded.
#   2. The identical concatenation 500 lines away, missed by 5d31ff6's sweep
#      because that fix was scoped to the audit-anchor entry points.
#   3. `GCP_CI_REPORT_DIR=ci-reports-2` in CI_2_ENV. gcp-ci.sh's DEFAULT is
#      `${REPO_ROOT}/ci-reports` — absolute and script-anchored, which is what
#      the warm lane uses. The cold lane overrode it with a RELATIVE value, so
#      its reports resolved against the running process's cwd instead. The two
#      lanes were not symmetric, and only one of them could be moved by where
#      you happened to be standing.
#
# test/keys-dir-path-safety.bats exists because a guard aimed at one SITE does
# not cover a CLASS. This file is the same lesson applied to the CI variables:
# it is derived from the Makefile and from what `make -n` actually expands, not
# from a list of the paths someone remembered.

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	makefile="${repo_root}/Makefile"
	gcp="${repo_root}/scripts/ci/gcp-ci.sh"
}

# Every GCP_CI_* variable whose NAME says it holds a directory or a log path.
# Derived from the naming convention rather than enumerated, so a variable added
# later is covered the day it is added. GCP_CI_REPORT_FILENAME is deliberately
# excluded: it is a bare filename joined onto a directory, and requiring it to
# be absolute would be wrong.
readonly PATH_VAR_RE='GCP_CI_[A-Z0-9_]*(DIR|LOG|PATH)'

@test "CIPATH no CI path variable is assigned a relative value in the Makefile" {
	# The signature is `GCP_CI_..._DIR=` followed by something that is neither an
	# absolute path nor a make function that produces one.
	# The token is cut at the first space, so `$(abspath ci-reports-2)` arrives
	# here as `GCP_CI_REPORT_DIR=$(abspath`. Match the opening of the make
	# function, not the whole call.
	local offenders allowed='=(/|\$\(abspath|\$\(CURDIR\)|\$\{CURDIR\})'
	offenders="$(grep -vE '^[[:space:]]*#' "$makefile" \
		| grep -oE "${PATH_VAR_RE}=[^ 	]*" \
		| grep -vE "$allowed" || true)"

	if [ -n "$offenders" ]; then
		echo "A CI path variable is assigned a RELATIVE value. It will resolve" >&2
		echo "against the cwd of whatever process ends up reading it, which is" >&2
		echo "not necessarily the tree under test. Use \$(abspath …), as" >&2
		echo "AUDIT_ANCHOR_KEYS and CI_2_ENV's GCP_CI_REPORT_DIR do:" >&2
		echo "$offenders" >&2
		return 1
	fi
}

@test "CIPATH every CI path variable make actually expands is absolute" {
	# The test above reads the source; this one reads what make EXPANDS, so a
	# relative value written in a form the pattern does not anticipate — a
	# variable holding a variable, a computed suffix — still fails. This is the
	# same two-layer structure keys-dir-path-safety.bats uses, and the reason it
	# has it: the source scan is the readable guard, the expansion scan is the
	# one that cannot be worked around by accident.
	local target expanded offenders found=0
	for target in ci-gcp ci-gcp-2 ci-status ci-status-2 ci-state ci-state-2 ci-ssh ci-ssh-2 ci-provision ci-provision-2; do
		expanded="$(cd "$repo_root" && make -n "$target" 2>/dev/null \
			| grep -vE '^[[:space:]]*#' || true)"
		[ -n "$expanded" ] || continue
		found=1
		offenders="$(printf '%s' "$expanded" \
			| grep -oE "${PATH_VAR_RE}=[^ 	]*" \
			| grep -vE '=/' || true)"
		if [ -n "$offenders" ]; then
			echo "make -n ${target} expands a relative CI path variable:" >&2
			echo "$offenders" >&2
			return 1
		fi
		# And the same doubled-slash shape that aborted both lanes on the keys
		# path, which is what a relative value concatenated onto an absolute one
		# produces.
		if printf '%s' "$expanded" | grep -oE "${PATH_VAR_RE}=[^ 	]*//[^ 	]*" | grep -q .; then
			echo "make -n ${target} expands a CI path with a doubled slash:" >&2
			printf '%s' "$expanded" | grep -oE "${PATH_VAR_RE}=[^ 	]*//[^ 	]*" >&2
			return 1
		fi
	done
	[ "$found" -eq 1 ] || skip "no CI target expanded; make -n produced nothing"
}

@test "CIPATH the two lanes anchor their reports the same way" {
	# The asymmetry IS the bug. The warm lane took gcp-ci.sh's absolute default
	# and the cold lane overrode it with a relative value, so one lane's reports
	# could be moved by cwd and the other's could not — which is why the two
	# lanes' artefacts disagreed about which directory was authoritative.
	local warm cold
	warm="$(cd "$repo_root" && make -n ci-gcp 2>/dev/null \
		| grep -oE 'GCP_CI_REPORT_DIR=[^ 	]*' | head -1 || true)"
	cold="$(cd "$repo_root" && make -n ci-gcp-2 2>/dev/null \
		| grep -oE 'GCP_CI_REPORT_DIR=[^ 	]*' | head -1 || true)"

	# The warm lane sets nothing and inherits the absolute default; the cold lane
	# must set an absolute value. Either way, neither may be relative.
	[ -z "$warm" ] || [[ "$warm" == GCP_CI_REPORT_DIR=/* ]]
	[ -n "$cold" ]
	[[ "$cold" == GCP_CI_REPORT_DIR=/* ]]
}

@test "CIPATH gcp-ci.sh anchors a relative override rather than trusting it" {
	# Belt and braces, and the half that protects a hand-typed
	# `GCP_CI_REPORT_DIR=ci-reports-3 ./scripts/ci/gcp-ci.sh run` — which the
	# Makefile guard above can never see. Run the real script from a cwd that is
	# guaranteed not to be the repo and check where it resolves.
	cd "$BATS_TEST_TMPDIR"
	run env GCP_CI_REPORT_DIR=relative-reports bash "$gcp" state
	[[ "${lines[0]}" == "Report:   ${repo_root}/relative-reports/summary.json" ]]
	[[ "${lines[0]}" != *"$BATS_TEST_TMPDIR"* ]]
}

@test "CIPATH the remote CI paths are absolute, since the VM's cwd is not ours" {
	# GCP_CI_REMOTE_* are interpreted by a shell on the VM, in whatever directory
	# sudo drops it into. A relative value there is the same defect with a
	# process boundary and an SSH hop in the middle, where it would be far harder
	# to see.
	local expanded offenders
	expanded="$(cd "$repo_root" && make -n ci-gcp-2 2>/dev/null \
		| grep -vE '^[[:space:]]*#' || true)"
	[ -n "$expanded" ] || skip "make -n ci-gcp-2 produced nothing"
	offenders="$(printf '%s' "$expanded" \
		| grep -oE 'GCP_CI_REMOTE_[A-Z0-9_]*=[^ 	]*' | grep -vE '=/' || true)"
	[ -z "$offenders" ] || { echo "relative remote path: $offenders" >&2; return 1; }
}
