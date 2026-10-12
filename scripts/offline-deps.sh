#!/usr/bin/env bash
#
# SLSI-OSD-5. Populate the bun dependency trees that `make test-all-offline`
# reads, as an EXPLICIT, ORDERED PREREQUISITE of that leg -- never as a step
# inside it.
#
# THE BOUNDARY THIS SCRIPT SITS ON
# -------------------------------
# This script is the NETWORK side. It may resolve and download packages.
# `make test-all-offline` is the OFFLINE side: once this script has returned, the
# leg runs assertions and must not install anything. Make's prerequisite
# ordering is what separates them -- `test-all-offline: offline-deps` guarantees
# this script has completed before the first recipe line of the leg executes,
# and `test/offline-install-boundary.bats` fails if an install line is ever
# added back into the leg's recipe. An offline leg that performs a network
# install asserts nothing about offline behaviour, which is why the separation
# is structural and guarded rather than a comment.
#
# WHY THIS EXISTS (corrected root cause, measured 2026-10-12)
# -----------------------------------------------------------
# A LINKED GIT WORKTREE DOES NOT INHERIT THE MAIN CHECKOUT'S node_modules.
# node_modules is untracked, so `git worktree add` produces a tree with
# package.json and bun.lock present and no dependency tree at all. The SLSI P0
# baseline recorded this as `EACCES` on node_modules and therefore as a
# permissions fault. That attribution was wrong, and the remedy differs:
# populating an absent dependency tree is not the same action as relaxing
# permissions. Re-measured in a cold linked worktree:
#
#   ls -d .../dashboard-signalloom/node_modules -> No such file or directory (ENOENT)
#   mkdir .../dashboard-signalloom/node_modules -> succeeds (parent IS writable)
#   test -w .../dashboard-signalloom           -> writable
#   bun install --frozen-lockfile              -> succeeds, 455 packages, 233ms
#
# The directory is ABSENT, not permission-denied. bun 1.4.0 prints
# `EACCES: Permission denied: could not open the "node_modules" directory` for
# the absent case under some sandbox profiles, and that misleading string is
# what P0 copied into its failureNote.
#
# WHY THERE IS NO STAMP FILE
# --------------------------
# `bun install --frozen-lockfile` IS the idempotency gate. On a tree that
# already satisfies bun.lock it is a no-op in roughly a tenth of a second and
# touches no network. This repo has already paid for the alternative: the
# comment above `demo-signalloom-supercred-stream-harness` in the Makefile
# records a real failure caused by the guard `[ -d node_modules/@playwright ] ||
# bun install`, which asked about ONE package to decide whether the whole
# dependency SET was present. A checkout whose node_modules predated react being
# added to package.json short-circuited, the install never ran, and the harness
# died with `Cannot find package 'react'`. A stamp file keyed on the lockfile
# mtime or hash is the same defect wearing a different hat: it is a second,
# weaker model of "is this tree satisfied" sitting next to bun's own. The
# lockfile is the only thing that describes the dependency set, so bun compares
# against it.
#
# bun only. Never npm, never npx.

set -eo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The declared set of workspaces `make test-all-offline` needs populated.
#
# Explicit rather than globbed for package.json, deliberately: a glob would pull
# in every workspace in the repo, including the browser leg's test/acceptance
# (which installs playwright browsers and is not offline work) and
# d2-signalloom/apps/docs-signalloom (the docs portal, not in the offline leg).
# Over-installing is not free and it blurs which trees the offline leg actually
# depends on. If the offline leg grows a new bun workspace, add it here; the
# boundary suite asserts every `cd <dir> && bun` in the leg's recipe resolves to
# a directory named below.
#
# tools/harness-dash is intentionally NOT listed: its package.json declares no
# dependencies and no lockfile exists, so `bun test` there needs no install.
OFFLINE_BUN_WORKSPACES=(
	"d2-signalloom/apps/dashboard-signalloom"
	"d2-signalloom/design-system-demo"
)

usage() {
	cat <<EOF
usage: ${SCRIPT_NAME} [--check|--list|--help]

  (no arguments)  Install every declared offline bun workspace. This is the
                  production invocation: it is what 'make offline-deps' runs.
  --check         Report whether each workspace is already satisfied. Installs
                  NOTHING and makes no network call. Exit 0 if all are
                  satisfied, 1 if any is not.
  --list          Print the declared workspace directories, one per line.
  --help          This text.
EOF
}

die() {
	echo "${SCRIPT_NAME}: $*" >&2
	exit 1
}

require_bun() {
	command -v bun >/dev/null 2>&1 ||
		die "bun is not on PATH. This repo installs with bun only, never npm or npx."
}

# Satisfied means: node_modules exists AND bun's own binary entry point for the
# tree is resolvable. This is used ONLY by --check, which reports; it is never
# used to skip an install. See "WHY THERE IS NO STAMP FILE" above -- a cheap
# predicate is fine for a report and wrong as a gate.
workspace_satisfied() {
	local dir="$1"
	[ -d "${REPO_ROOT}/${dir}/node_modules" ] &&
		[ -e "${REPO_ROOT}/${dir}/node_modules/.bin" ]
}

cmd_list() {
	printf '%s\n' "${OFFLINE_BUN_WORKSPACES[@]}"
}

cmd_check() {
	local dir status=0
	for dir in "${OFFLINE_BUN_WORKSPACES[@]}"; do
		if workspace_satisfied "${dir}"; then
			echo "satisfied   ${dir}"
		else
			echo "UNSATISFIED ${dir}"
			status=1
		fi
	done
	return "${status}"
}

cmd_install() {
	require_bun
	local dir
	for dir in "${OFFLINE_BUN_WORKSPACES[@]}"; do
		[ -d "${REPO_ROOT}/${dir}" ] ||
			die "declared offline workspace is missing from the tree: ${dir}"
		[ -f "${REPO_ROOT}/${dir}/package.json" ] ||
			die "declared offline workspace has no package.json: ${dir}"
		[ -f "${REPO_ROOT}/${dir}/bun.lock" ] ||
			die "declared offline workspace has no bun.lock, so --frozen-lockfile cannot gate it: ${dir}"
		echo "--- offline-deps: bun install --frozen-lockfile in ${dir}"
		# Subshell, not `cd &&`: a failure must not leave the loop in the wrong
		# directory, and the exit status must be this install's, not a pipe's.
		( cd "${REPO_ROOT}/${dir}" && bun install --frozen-lockfile )
	done
	echo "=== offline-deps: all ${#OFFLINE_BUN_WORKSPACES[@]} offline bun workspaces satisfied ==="
}

main() {
	# NOT "${@:-}" -- with zero arguments that expands to one empty-string
	# argument and the case below would fall through to the unknown-option arm,
	# breaking the no-argument path, which is the production invocation.
	case "${1-}" in
	"") cmd_install ;;
	--check) cmd_check ;;
	--list) cmd_list ;;
	--help | -h)
		usage
		;;
	*)
		usage >&2
		die "unknown option: $1"
		;;
	esac
}

main "$@"
