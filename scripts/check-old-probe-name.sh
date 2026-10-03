#!/usr/bin/env bash
# check-old-probe-name.sh — guard against legacy stun-sentinel probe name occurrences in tracked files.
#
# Usage:
#   scripts/check-old-probe-name.sh [--root DIR] [--allowlist FILE] [--pending-allowlist FILE]
#
# Exit codes:
#   0  SCANNED CLEAN    a non-empty set of files was scanned, no unallowed old probe
#                       names were found, and every allowlist entry was active.
#   1  FINDINGS         at least one unallowed old probe name was found, or the
#                       allowlist contains stale entries that suppress nothing.
#   2  CANNOT SCAN      invalid arguments, missing allowlist file, not a git repo,
#                       or zero tracked files scanned.

set -euo pipefail
ZSH_VERSION=${ZSH_VERSION:-}

ROOT="."
ALLOWLIST=""
PENDING_ALLOWLIST=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--root)
			ROOT="${2:?--root requires an argument}"
			shift 2
			;;
		--allowlist)
			ALLOWLIST="${2:?--allowlist requires an argument}"
			shift 2
			;;
		--pending-allowlist)
			PENDING_ALLOWLIST="${2:?--pending-allowlist requires an argument}"
			shift 2
			;;
		-h|--help)
			echo "Usage: scripts/check-old-probe-name.sh [--root DIR] [--allowlist FILE] [--pending-allowlist FILE]"
			exit 2
			;;
		*)
			echo "CANNOT SCAN: unknown option: $1" >&2
			echo "Usage: scripts/check-old-probe-name.sh [--root DIR] [--allowlist FILE] [--pending-allowlist FILE]" >&2
			exit 2
			;;
	esac
done

if [ ! -d "$ROOT" ]; then
	echo "CANNOT SCAN: root directory $ROOT does not exist" >&2
	exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "CANNOT SCAN: $ROOT is not a git repository" >&2
	exit 2
fi

if [ -z "$ALLOWLIST" ]; then
	ALLOWLIST="$ROOT/test/fixtures/old-probe-name-allowlist.txt"
fi

if [ ! -f "$ALLOWLIST" ]; then
	echo "CANNOT SCAN: allowlist file $ALLOWLIST not found" >&2
	exit 2
fi

if [ -z "$PENDING_ALLOWLIST" ]; then
	PENDING_ALLOWLIST="$ROOT/test/fixtures/old-probe-name-pending-p3-1.txt"
fi

# Extract RECORDS regex from scripts/docs-lint.sh
RECORDS=""
DOCS_LINT_SCRIPT="$ROOT/scripts/docs-lint.sh"
if [ -f "$DOCS_LINT_SCRIPT" ]; then
	RECORDS="$(sed -n "s/^RECORDS='\([^']*\)'/\1/p" "$DOCS_LINT_SCRIPT")"
fi

# Read tracked files count
FILE_COUNT="$(git -C "$ROOT" ls-files | wc -l | tr -d ' ')"

if [ "$FILE_COUNT" -eq 0 ]; then
	echo "CANNOT SCAN: zero tracked files in $ROOT" >&2
	exit 2
fi

# Load pending P3-1 allowlist if present
declare -A PENDING_FILES=()
if [ -f "$PENDING_ALLOWLIST" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[[ -z "$line" || "$line" == \#* ]] && continue
		PENDING_FILES["$line"]=1
	done < "$PENDING_ALLOWLIST"
fi

# Parse permanent allowlist entries
# Each entry: pattern/path or path:anchor, plus reason
declare -a ALLOW_PATTERNS=()
declare -a ALLOW_ANCHORS=()
declare -a ALLOW_REASONS=()
declare -a ALLOW_LINES=()
declare -a ALLOW_HITS=()

lineno=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
	lineno=$((lineno + 1))
	trimmed="$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	[[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

	# Extract entry and reason: entry # reason
	entry="${trimmed%%#*}"
	entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	reason="${trimmed#*#}"
	reason="$(echo "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	if [ "$trimmed" = "$entry" ]; then
		reason=""
	fi

	if [[ "$entry" == *:* ]]; then
		path_part="${entry%%:*}"
		anchor_part="${entry#*:}"
		ALLOW_PATTERNS+=("$path_part")
		ALLOW_ANCHORS+=("$anchor_part")
	else
		ALLOW_PATTERNS+=("$entry")
		ALLOW_ANCHORS+=("")
	fi
	ALLOW_REASONS+=("$reason")
	ALLOW_LINES+=("$lineno")
	ALLOW_HITS+=(0)
done < "$ALLOWLIST"

# Pattern to search for old probe name
# Pattern uses -e 'stun[-_ ]?sentinel' (case-insensitive -i)
SEARCH_PAT='stun[-_ ]?sentinel'

# Temporary files for findings
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RAW_FINDINGS="$TMP_DIR/raw_findings.txt"
FINAL_FINDINGS="$TMP_DIR/final_findings.txt"
: > "$RAW_FINDINGS"
: > "$FINAL_FINDINGS"

# 1. Scan tracked file paths
(
	cd "$ROOT"
	git ls-files | rg -i -e "$SEARCH_PAT" | while IFS= read -r f; do
		printf '%s:1: [path-match] %s\n' "$f" "$f"
	done >> "$RAW_FINDINGS" || true
)

# 2. Scan tracked file contents
(
	cd "$ROOT"
	git ls-files -z | xargs -0 rg -n -i -e "$SEARCH_PAT" --path-separator / -- >> "$RAW_FINDINGS" 2>/dev/null || true
)

# Process raw findings and apply filters
FINDINGS_COUNT=0

while IFS= read -r finding || [ -n "$finding" ]; do
	[ -z "$finding" ] && continue

	# finding is formatted as path:lineno:text
	f_path="${finding%%:*}"
	rest="${finding#*:}"
	f_lineno="${rest%%:*}"
	f_text="${rest#*:}"

	# Check RECORDS exclusion
	if [ -n "$RECORDS" ] && [[ "$f_path" =~ $RECORDS ]]; then
		continue
	fi

	# Check permanent allowlist
	matched_allowlist=0
	for i in "${!ALLOW_PATTERNS[@]}"; do
		pat="${ALLOW_PATTERNS[$i]}"
		anc="${ALLOW_ANCHORS[$i]}"

		path_matches=0
		if [ "$f_path" = "$pat" ]; then
			path_matches=1
		elif [[ "$pat" == */ && "$f_path" == "$pat"* ]]; then
			path_matches=1
		elif [[ "$pat" == *\** ]] && [[ "$f_path" == $pat ]]; then
			path_matches=1
		fi

		if [ "$path_matches" -eq 1 ]; then
			if [ -z "$anc" ]; then
				ALLOW_HITS[$i]=$((ALLOW_HITS[$i] + 1))
				matched_allowlist=1
				break
			else
				if [[ "$f_text" == *"$anc"* || "$f_lineno" == "$anc" || "$finding" == *"$anc"* ]]; then
					ALLOW_HITS[$i]=$((ALLOW_HITS[$i] + 1))
					matched_allowlist=1
					break
				fi
			fi
		fi
	done

	if [ "$matched_allowlist" -eq 1 ]; then
		continue
	fi

	# Check pending P3-1 allowlist
	if [[ -n "${PENDING_FILES["$f_path"]:-}" ]]; then
		continue
	fi

	# Unsuppressed finding!
	FINDINGS_COUNT=$((FINDINGS_COUNT + 1))
	printf '%s\n' "$finding" >> "$FINAL_FINDINGS"
done < "$RAW_FINDINGS"

# Check for stale allowlist entries
STALE_COUNT=0
for i in "${!ALLOW_PATTERNS[@]}"; do
	if [ "${ALLOW_HITS[$i]}" -eq 0 ]; then
		entry_str="${ALLOW_PATTERNS[$i]}"
		[ -n "${ALLOW_ANCHORS[$i]}" ] && entry_str="${entry_str}:${ALLOW_ANCHORS[$i]}"
		echo "allowlist:${ALLOW_LINES[$i]}: entry suppresses nothing (${entry_str})" >&2
		STALE_COUNT=$((STALE_COUNT + 1))
	fi
done

if [ "$FINDINGS_COUNT" -gt 0 ]; then
	cat "$FINAL_FINDINGS"
	echo "check-old-probe-name: FINDINGS: ${FINDINGS_COUNT} unallowed occurrences found" >&2
	exit 1
fi

if [ "$STALE_COUNT" -gt 0 ]; then
	echo "check-old-probe-name: FINDINGS: ${STALE_COUNT} stale allowlist entries found" >&2
	exit 1
fi

echo "check-old-probe-name: SCANNED CLEAN: ${FILE_COUNT} files"
exit 0
