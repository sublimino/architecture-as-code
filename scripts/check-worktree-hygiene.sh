#!/usr/bin/env bash
# scripts/check-worktree-hygiene.sh
#
# Guard against creating secondary git worktrees inside the repository root
# (e.g. $REPO_ROOT/.claude/worktrees/agent-* or $REPO_ROOT/<subdir>), and
# report stale osramp worktrees strictly older than --max-age-days (default 21).
#
# Reference: AGENTS.md ("Worktree location"):
#   "Put worktrees in ~/src/.worktrees/<repo>/<branch>/. Do not make a worktree
#    inside the repository directory. Search tools and test runners then scan
#    the same files twice."
#
# Usage:
#   scripts/check-worktree-hygiene.sh [options]
#
# Options:
#   --repo-root <dir>           Main repository root (defaults to main worktree root)
#   --worktree-list-file <file> Read `git worktree list --porcelain` output from file
#   --baseline-file <file>      File with one legacy in-repo path per line (relative to repo root or absolute)
#   --max-age-days <days>       Maximum age in days before an osramp worktree is considered stale (default: 21)
#   --now-epoch <epoch>         Override current Unix epoch seconds (for deterministic testing)
#   --list-stale-osramp         List osramp worktrees strictly older than --max-age-days (> N days)
#   -h, --help                  Show this help message

set -euo pipefail

usage() {
	sed -n '14,24p' "$0" | sed 's/^# \{0,1\}//'
}

REPO_ROOT=""
WORKTREE_LIST_FILE=""
BASELINE_FILE=""
MAX_AGE_DAYS=21
NOW_EPOCH=""
MODE="guard"

# Legacy in-repo .claude/worktrees/agent-* directories created on or before
# 2026-10-13 that are <= 21 days old (retained per Andy's rule: "don't prune
# worktrees unless over 21 days old and of osramp type"). Once > 21 days old,
# they are no longer exempted here and must be pruned.
DEFAULT_LEGACY_AGENTS=(
	".claude/worktrees/agent-a12964f5e4d6f2170"
	".claude/worktrees/agent-a15d942e64d2b4774"
	".claude/worktrees/agent-a206bb89509db9d38"
	".claude/worktrees/agent-a22073a2720e88e0d"
	".claude/worktrees/agent-a2c04c7f4eeeba765"
	".claude/worktrees/agent-a3b4704e08af5f62c"
	".claude/worktrees/agent-a4118d224adb2fa17"
	".claude/worktrees/agent-a4ae6e4f286ec8c4c"
	".claude/worktrees/agent-a4c07da3b6ff9a159"
	".claude/worktrees/agent-a6af5f0879abffdc7"
	".claude/worktrees/agent-a79b9105ae833b32e"
	".claude/worktrees/agent-a831b49e67fd8b2c5"
	".claude/worktrees/agent-abcb6fd0ace1bcea4"
	".claude/worktrees/agent-ade58a3c2e6e62a65"
	".claude/worktrees/agent-af41beb3acdf4bbf4"
)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo-root)
			REPO_ROOT="${2:-}"
			shift 2
			;;
		--worktree-list-file)
			WORKTREE_LIST_FILE="${2:-}"
			shift 2
			;;
		--baseline-file)
			BASELINE_FILE="${2:-}"
			shift 2
			;;
		--max-age-days)
			MAX_AGE_DAYS="${2:-}"
			shift 2
			;;
		--now-epoch)
			NOW_EPOCH="${2:-}"
			shift 2
			;;
		--list-stale-osramp)
			MODE="list-stale-osramp"
			shift
			;;
		--prune-stale-osramp)
			MODE="prune-stale-osramp"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ -z "$NOW_EPOCH" ]]; then
	NOW_EPOCH="$(date +%s)"
fi

if [[ -z "$REPO_ROOT" ]]; then
	# Resolve the main checkout root via --git-common-dir so running inside a
	# linked worktree still resolves the main repository directory.
	common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
	if [[ -n "$common_dir" && "$(basename "$common_dir")" == ".git" ]]; then
		REPO_ROOT="$(dirname "$common_dir")"
	else
		REPO_ROOT="$(git rev-parse --show-toplevel)"
	fi
fi
REPO_ROOT="${REPO_ROOT%/}"

read_porcelain() {
	if [[ -n "$WORKTREE_LIST_FILE" ]]; then
		cat "$WORKTREE_LIST_FILE"
	else
		git -C "$REPO_ROOT" worktree list --porcelain
	fi
}

is_baseline_exempt() {
	local wt_path="$1"
	local age_days="$2"

	# Never exempt a worktree strictly older than MAX_AGE_DAYS
	if (( age_days > MAX_AGE_DAYS )); then
		return 1
	fi

	if [[ -n "$BASELINE_FILE" ]]; then
		if [[ ! -f "$BASELINE_FILE" ]]; then
			return 1
		fi
		local line
		while IFS= read -r line; do
			[[ -z "$line" || "$line" =~ ^# ]] && continue
			if [[ "$wt_path" == "$line" || "$wt_path" == "$REPO_ROOT/${line#/}" ]]; then
				return 0
			fi
		done < "$BASELINE_FILE"
		return 1
	fi

	# When using a custom --worktree-list-file in tests without --baseline-file,
	# do not apply the live repo's legacy baseline unless explicitly requested.
	if [[ -n "$WORKTREE_LIST_FILE" && "${WORKTREE_HYGIENE_USE_DEFAULT_BASELINE:-0}" != "1" ]]; then
		return 1
	fi

	local rel
	for rel in "${DEFAULT_LEGACY_AGENTS[@]}"; do
		if [[ "$wt_path" == "$REPO_ROOT/$rel" ]]; then
			return 0
		fi
	done
	return 1
}

get_worktree_age_days() {
	local wt_path="$1"
	local mtime_override="$2"
	local mtime=""

	if [[ -n "$mtime_override" ]]; then
		mtime="$mtime_override"
	elif [[ -e "$wt_path" ]]; then
		mtime="$(stat -c %Y "$wt_path" 2>/dev/null || echo "")"
	fi

	if [[ -z "$mtime" ]]; then
		echo 0
		return
	fi

	local diff=$(( NOW_EPOCH - mtime ))
	if (( diff < 0 )); then
		echo 0
	else
		echo $(( diff / 86400 ))
	fi
}

is_osramp_worktree() {
	local wt_path="$1"
	local branch_ref="$2"
	if [[ "$wt_path" == *"osramp"* || "$branch_ref" == *"osramp"* ]]; then
		return 0
	fi
	return 1
}

get_worktree_status() {
	local wt_path="$1"
	if [[ ! -d "$wt_path" || ! -r "$wt_path" ]]; then
		echo "UNREADABLE"
		return
	fi
	local status_out=""
	if ! status_out="$(git -C "$wt_path" status --porcelain 2>/dev/null)"; then
		echo "UNREADABLE"
		return
	fi
	if [[ -n "$status_out" ]]; then
		echo "DIRTY"
	else
		echo "CLEAN"
	fi
}

# Parse porcelain records: each stanza starts with `worktree <path>` and may
# optionally include `# mtime <epoch>` or `mtime <epoch>` in synthetic fixtures.
parse_worktrees() {
	local wt="" head="" branch="" mtime="" idx=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
			"worktree "*)
				if [[ -n "$wt" ]]; then
					printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$wt" "$head" "$branch" "$mtime"
					idx=$(( idx + 1 ))
				fi
				wt="${line#worktree }"
				head=""
				branch="DETACHED"
				mtime=""
				;;
			"HEAD "*)
				head="${line#HEAD }"
				;;
			"branch "*)
				branch="${line#branch }"
				;;
			"mtime "*|"# mtime "*)
				mtime="${line##*mtime }"
				;;
			"")
				if [[ -n "$wt" ]]; then
					printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$wt" "$head" "$branch" "$mtime"
					idx=$(( idx + 1 ))
					wt=""
					head=""
					branch="DETACHED"
					mtime=""
				fi
				;;
		esac
	done
	if [[ -n "$wt" ]]; then
		printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$wt" "$head" "$branch" "$mtime"
	fi
}

run_guard() {
	local violations=0
	local idx wt head branch mtime age_days

	while IFS=$'\t' read -r idx wt head branch mtime; do
		[[ -z "$wt" ]] && continue
		# Skip the primary checkout itself
		if [[ "$wt" == "$REPO_ROOT" ]]; then
			continue
		fi
		# Check if worktree path is nested inside $REPO_ROOT/
		if [[ "$wt" == "$REPO_ROOT/"* ]]; then
			age_days="$(get_worktree_age_days "$wt" "$mtime")"
			if is_baseline_exempt "$wt" "$age_days"; then
				continue
			fi
			echo "ERROR: in-repo secondary git worktree detected: $wt (branch: $branch, age: ${age_days}d)" >&2
			echo "       Worktrees must be placed outside $REPO_ROOT (e.g. ~/src/.worktrees/osramp-demo/<branch>/)." >&2
			violations=$(( violations + 1 ))
		fi
	done < <(read_porcelain | parse_worktrees)

	if (( violations > 0 )); then
		echo "FAILED: $violations offending in-repo worktree(s) found under $REPO_ROOT/." >&2
		return 1
	fi
	return 0
}

run_list_stale_osramp() {
	local idx wt head branch mtime age_days wt_status

	while IFS=$'\t' read -r idx wt head branch mtime; do
		[[ -z "$wt" ]] && continue
		# Never flag the primary checkout
		if [[ "$wt" == "$REPO_ROOT" || "$idx" == "0" ]]; then
			continue
		fi
		if ! is_osramp_worktree "$wt" "$branch"; then
			continue
		fi
		age_days="$(get_worktree_age_days "$wt" "$mtime")"
		if (( age_days > MAX_AGE_DAYS )); then
			wt_status="$(get_worktree_status "$wt")"
			printf 'STALE_OSRAMP\tage_days=%d\tpath=%s\tbranch=%s\tSTATUS=%s\n' "$age_days" "$wt" "$branch" "$wt_status"
		fi
	done < <(read_porcelain | parse_worktrees)
}

run_prune_stale_osramp() {
	local idx wt head branch mtime age_days wt_status

	while IFS=$'\t' read -r idx wt head branch mtime; do
		[[ -z "$wt" ]] && continue
		if [[ "$wt" == "$REPO_ROOT" || "$idx" == "0" ]]; then
			continue
		fi
		if ! is_osramp_worktree "$wt" "$branch"; then
			continue
		fi
		age_days="$(get_worktree_age_days "$wt" "$mtime")"
		if (( age_days > MAX_AGE_DAYS )); then
			wt_status="$(get_worktree_status "$wt")"
			if [[ "$wt_status" == "CLEAN" ]]; then
				git -C "$REPO_ROOT" worktree remove "$wt" 2>/dev/null || true
				printf 'PRUNED_OSRAMP\tage_days=%d\tpath=%s\tbranch=%s\tSTATUS=%s\n' "$age_days" "$wt" "$branch" "$wt_status"
			else
				printf 'SKIPPED_OSRAMP\tage_days=%d\tpath=%s\tbranch=%s\tSTATUS=%s\n' "$age_days" "$wt" "$branch" "$wt_status"
			fi
		fi
	done < <(read_porcelain | parse_worktrees)
}

main() {
	case "$MODE" in
		guard)
			run_guard
			;;
		list-stale-osramp)
			run_list_stale_osramp
			;;
		prune-stale-osramp)
			run_prune_stale_osramp
			;;
	esac
}

main "$@"
