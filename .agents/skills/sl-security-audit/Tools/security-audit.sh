#!/usr/bin/env bash
set -uo pipefail

usage() {
	cat <<'EOF'
Usage: security-audit.sh --repo-root DIR [--timeout SECONDS]
                         [--revision SHA] [--rules FILE]
                         [--evidence-dir DIR] [--public-key PEM]

Runs existing static scanners in a network-isolated user namespace and emits one
JSON report. No network or live-execution option exists.
EOF
}

repo_root=""
timeout_seconds=120
evidence_dir=""
public_key=""
rules_file=""
revision=""
while (($#)); do
	case "$1" in
		--repo-root) (($# >= 2)) || exit 2; repo_root="$2"; shift 2 ;;
		--timeout) (($# >= 2)) || exit 2; timeout_seconds="$2"; shift 2 ;;
		--evidence-dir) (($# >= 2)) || exit 2; evidence_dir="$2"; shift 2 ;;
		--public-key) (($# >= 2)) || exit 2; public_key="$2"; shift 2 ;;
		--rules) (($# >= 2)) || exit 2; rules_file="$2"; shift 2 ;;
		--revision) (($# >= 2)) || exit 2; revision="$2"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) exit 2 ;;
	esac
done

[[ -n "$repo_root" && -d "$repo_root" ]] || exit 2
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || exit 2
((timeout_seconds <= 3600)) || exit 2
repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || exit 2
if [[ -z "$revision" ]]; then
	revision="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null)" || exit 2
fi
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ -z "$evidence_dir" || -d "$evidence_dir" ]] || exit 2
[[ -z "$public_key" || -f "$public_key" ]] || exit 2

raw_dir="$(mktemp -d "${TMPDIR:-/tmp}/sl-security-audit.XXXXXX")" || exit 1
chmod 0700 "$raw_dir" || exit 1
active_pids=()
cleanup() {
	if ((${#active_pids[@]})); then
		kill "${active_pids[@]}" 2>/dev/null || true
		wait "${active_pids[@]}" 2>/dev/null || true
	fi
	rm -rf "$raw_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
scan_home="$raw_dir/home"
scan_cache="$raw_dir/cache"
scan_tmp="$raw_dir/tmp"
mkdir -m 0700 "$scan_home" "$scan_cache" "$scan_tmp" || exit 1

checks=()
add_check() {
	local id="$1" status="$2" exit_code="$3" required="$4" kind="$5" reason="$6" metrics="$7"
	checks+=("{\"id\":\"$id\",\"status\":\"$status\",\"exit_code\":$exit_code,\"required\":$required,\"evidence_kind\":\"$kind\",\"reason_code\":\"$reason\",\"metrics\":$metrics}")
}

tool_exists() {
	command -v "$1" >/dev/null 2>&1
}

max_log_bytes="${SL_SECURITY_AUDIT_MAX_LOG_BYTES:-1048576}"
[[ "$max_log_bytes" =~ ^[0-9]+$ ]] && ((max_log_bytes >= 4096 && max_log_bytes <= 16777216)) || exit 2

capture_stream() {
	local fifo="$1" destination="$2"
	exec 3<"$fifo"
	head -c "$max_log_bytes" <&3 >"$destination" 2>/dev/null || true
	cat <&3 >/dev/null
	exec 3<&-
}

run_bounded() {
	local stdout_file="$1" stderr_file="$2" stdout_fifo="$raw_dir/stdout.fifo" stderr_fifo="$raw_dir/stderr.fifo"
	shift 2
	rm -f "$stdout_fifo" "$stderr_fifo"
	mkfifo -m 0600 "$stdout_fifo" "$stderr_fifo" || return 1
	capture_stream "$stdout_fifo" "$stdout_file" &
	local stdout_pid=$!
	capture_stream "$stderr_fifo" "$stderr_file" &
	local stderr_pid=$!
	"$@" >"$stdout_fifo" 2>"$stderr_fifo" &
	local command_pid=$!
	active_pids=("$stdout_pid" "$stderr_pid" "$command_pid")
	wait "$command_pid"
	local rc=$?
	wait "$stdout_pid" "$stderr_pid" 2>/dev/null || true
	active_pids=()
	rm -f "$stdout_fifo" "$stderr_fifo"
	return "$rc"
}

isolation_status="passed"
if ! tool_exists unshare; then
	isolation_status="missing_tool"
elif ! unshare --user --map-root-user --net --pid --fork --kill-child -- true >"$raw_dir/unshare-probe.log" 2>&1; then
	isolation_status="permission_denied"
fi

run_isolated() {
	local stdout_file="$1" stderr_file="$2"
	shift 2
	run_bounded "$stdout_file" "$stderr_file" \
		timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
		unshare --user --map-root-user --net --pid --fork --kill-child -- \
		env -i PATH="$PATH" HOME="$scan_home" XDG_CACHE_HOME="$scan_cache" \
		TMPDIR="$scan_tmp" LANG=C LC_ALL=C "$@"
}

# Secrets: scan a committed archive only, using the repository's pinned exclusions.
trufflehog="${SL_SECURITY_AUDIT_TRUFFLEHOG:-trufflehog}"
if [[ "$isolation_status" != passed ]]; then
	add_check secrets BLOCKED null true static "$isolation_status" '{}'
elif ! tool_exists "$trufflehog" || ! tool_exists git || ! tool_exists tar; then
	add_check secrets BLOCKED null true static missing_tool '{}'
else
	secret_help="$raw_dir/trufflehog-help.log"
	if run_isolated "$secret_help" "$raw_dir/trufflehog-help.err" "$trufflehog" filesystem --help; then
		if ! grep -q -- '--no-update' "$secret_help" ||
			! grep -q -- '--no-verification' "$secret_help" ||
			! grep -q -- '--exclude-paths' "$secret_help" ||
			! grep -q -- '--json' "$secret_help"; then
			add_check secrets BLOCKED null true static invalid_output '{}'
		else
			tree="$raw_dir/tree"
			mkdir -m 0700 "$tree"
			# shellcheck disable=SC2016
			if run_bounded "$raw_dir/archive-size.out" "$raw_dir/archive-size.err" \
				timeout --signal=TERM --kill-after=2 "$timeout_seconds" bash -o pipefail -c \
				'git -C "$1" ls-tree -r -l "$2" | awk '\''$4 ~ /^[0-9]+$/ { total += $4 } END { print total + 0 }'\''' _ "$repo_root" "$revision"; then
				archive_bytes="$(tr -d '[:space:]' <"$raw_dir/archive-size.out")"
			else
				rc=$?
				archive_bytes=""
			fi
			available_kb="$(df -Pk "$raw_dir" | awk 'NR == 2 { print $4 }')"
			# shellcheck disable=SC2016
			if [[ ! "$archive_bytes" =~ ^[0-9]+$ || ! "$available_kb" =~ ^[0-9]+$ ]]; then
				add_check secrets BLOCKED "${rc:-null}" true static invalid_output '{}'
			elif ((archive_bytes > 268435456 || available_kb * 1024 < archive_bytes * 2 + 33554432)); then
				add_check secrets BLOCKED null true static invalid_output "{\"archive_bytes\":$archive_bytes}"
			elif run_bounded "$raw_dir/archive.out" "$raw_dir/archive.err" \
				timeout --signal=TERM --kill-after=2 "$timeout_seconds" bash -o pipefail -c \
				'git -C "$1" archive "$3" | tar -xf - -C "$2"' _ "$repo_root" "$tree" "$revision"; then
				secret_out="$raw_dir/trufflehog.jsonl"
				(
					cd "$tree" || exit 2
					run_isolated "$secret_out" "$raw_dir/trufflehog.err" \
						"$trufflehog" filesystem --no-update --no-verification --json --fail \
						--exclude-detectors=Lob --exclude-paths="$repo_root/.trufflehog-exclude-paths" .
				)
				rc=$?
				captured_bytes="$(stat -c %s "$secret_out" 2>/dev/null || printf 0)"
				if [[ -s "$secret_out" ]]; then
					finding_count="$(jq -s 'length' "$secret_out" 2>/dev/null)" || finding_count=""
				else
					finding_count=0
				fi
				if [[ ! "$finding_count" =~ ^[0-9]+$ ]]; then
					add_check secrets BLOCKED "$rc" true static invalid_output "{\"captured_stdout_bytes\":$captured_bytes}"
				elif ((rc == 0 && finding_count == 0 && captured_bytes >= max_log_bytes)); then
					add_check secrets BLOCKED "$rc" true static coverage_gap "{\"captured_stdout_bytes\":$captured_bytes}"
				elif ((rc == 0 && finding_count == 0)); then
					add_check secrets PASS 0 true static passed "{\"findings\":0,\"captured_stdout_bytes\":$captured_bytes}"
				elif ((rc == 183 || finding_count > 0)); then
					add_check secrets FAIL "$rc" true static findings "{\"findings\":$finding_count,\"captured_stdout_bytes\":$captured_bytes}"
				elif ((rc == 124 || rc == 137)); then
					add_check secrets BLOCKED "$rc" true static timeout '{}'
				else
					add_check secrets BLOCKED "$rc" true static invalid_output '{}'
				fi
			else
				rc=$?
				if ((rc == 124 || rc == 137)); then
					add_check secrets BLOCKED "$rc" true static timeout "{\"archive_bytes\":$archive_bytes}"
				else
					add_check secrets BLOCKED "$rc" true static invalid_output "{\"archive_bytes\":$archive_bytes}"
				fi
			fi
		fi
	else
		rc=$?
		if ((rc == 124 || rc == 137)); then
			add_check secrets BLOCKED "$rc" true static timeout '{}'
		else
			add_check secrets BLOCKED "$rc" true static invalid_output '{}'
		fi
	fi
fi

# SAST: the existing gate is permitted only with an explicit local rules file.
semgrep="${SL_SECURITY_AUDIT_SEMGREP:-semgrep}"
semgrep_path="$(command -v "$semgrep" 2>/dev/null || true)"
semgrep_config="${rules_file:-${SL_SECURITY_AUDIT_SEMGREP_CONFIG:-}}"
if [[ "$isolation_status" != passed ]]; then
	add_check sast BLOCKED null true static "$isolation_status" '{}'
elif ! tool_exists "$semgrep" || ! tool_exists node; then
	add_check sast BLOCKED null true static missing_tool '{}'
elif [[ -z "$semgrep_config" || ! -f "$semgrep_config" ]]; then
	add_check sast BLOCKED null true static offline_rules_missing '{}'
else
	sast_out="$raw_dir/semgrep-gate.out"
	if run_isolated "$sast_out" "$raw_dir/semgrep-gate.err" \
		env SEMGREP_HOME="$scan_home" SEMGREP_CONFIG="$semgrep_config" SEMGREP_BIN="$semgrep_path" \
		node "$repo_root/scripts/semgrep-gate.mjs" --severity ERROR; then
		rc=0
	else
		rc=$?
	fi
	summary="$(grep -E '^[[:space:]]*[0-9]+ ERROR finding\(s\), [0-9]+ accepted in baseline, [0-9]+ parse error\(s\)' "$sast_out" | tail -n 1)"
	counts="$(printf '%s\n' "$summary" | sed -E 's/^[[:space:]]*([0-9]+) ERROR finding\(s\), ([0-9]+) accepted in baseline, ([0-9]+) parse error\(s\).*/\1 \2 \3/')"
	read -r sast_findings accepted_entries parse_errors <<<"$counts"
	if [[ ! "${sast_findings:-}" =~ ^[0-9]+$ || ! "${accepted_entries:-}" =~ ^[0-9]+$ || ! "${parse_errors:-}" =~ ^[0-9]+$ ]]; then
		add_check sast BLOCKED "$rc" true static invalid_output '{}'
	elif ((rc == 124 || rc == 137)); then
		add_check sast BLOCKED "$rc" true static timeout '{}'
	elif ((rc == 1)); then
		add_check sast FAIL 1 true static findings "{\"findings\":$sast_findings,\"accepted_baseline_entries\":$accepted_entries,\"parse_errors\":$parse_errors}"
	elif ((parse_errors > 0)); then
		add_check sast UNVERIFIED "$rc" true static coverage_gap "{\"findings\":$sast_findings,\"accepted_baseline_entries\":$accepted_entries,\"parse_errors\":$parse_errors}"
	elif ((rc == 0)); then
		add_check sast PASS 0 true static passed "{\"findings\":$sast_findings,\"accepted_baseline_entries\":$accepted_entries,\"parse_errors\":0}"
	else
		add_check sast BLOCKED "$rc" true static invalid_output '{}'
	fi
fi

# Bundle signature: an embedded key is never treated as independently trusted.
declared_live=0
header="${evidence_dir:+$evidence_dir/bundle-header.json}"
if [[ -n "$header" && -f "$header" && ! -L "$header" ]] && [[ "$(jq -r '.evidence_origin // "unknown"' "$header" 2>/dev/null)" == live ]]; then
	declared_live=1
fi
if [[ -z "$evidence_dir" ]]; then
	add_check evidence_signature UNVERIFIED null true cryptographic not_requested '{"declared_live":0,"observed_live":0}'
elif [[ -z "$public_key" ]]; then
	add_check evidence_signature UNVERIFIED null true cryptographic untrusted_key "{\"declared_live\":$declared_live,\"observed_live\":0}"
else
	evidence_real="$(cd "$evidence_dir" 2>/dev/null && pwd -P)" || evidence_real=""
	key_real="$(readlink -f "$public_key" 2>/dev/null || true)"
	case "$key_real" in
		"$evidence_real"/* | "") add_check evidence_signature UNVERIFIED null true cryptographic untrusted_key "{\"declared_live\":$declared_live,\"observed_live\":0}" ;;
		*)
			verifier="${SL_SECURITY_AUDIT_VERIFIER:-$repo_root/scripts/verify-eap-evidence.sh}"
			if [[ ! -x "$verifier" ]]; then
				add_check evidence_signature BLOCKED null true cryptographic missing_tool "{\"declared_live\":$declared_live,\"observed_live\":0}"
			elif run_isolated "$raw_dir/evidence-verify.out" "$raw_dir/evidence-verify.err" \
				"$verifier" "$evidence_dir" --pubkey "$public_key" --quiet; then
				add_check evidence_signature PASS 0 true cryptographic passed "{\"declared_live\":$declared_live,\"observed_live\":0}"
			else
				rc=$?
				if ((rc == 124 || rc == 137)); then
					add_check evidence_signature BLOCKED "$rc" true cryptographic timeout "{\"declared_live\":$declared_live,\"observed_live\":0}"
				else
					add_check evidence_signature FAIL "$rc" true cryptographic findings "{\"declared_live\":$declared_live,\"observed_live\":0}"
				fi
			fi
			;;
	esac
fi

# Freshness is separate from signature validity.
if [[ -z "$evidence_dir" ]]; then
	add_check evidence_freshness UNVERIFIED null true cryptographic not_requested '{}'
elif [[ ! -f "$header" || -L "$header" ]]; then
	add_check evidence_freshness BLOCKED null true cryptographic invalid_output '{}'
else
	signed_at="$(jq -r '.signed_at // empty' "$header" 2>/dev/null)"
	signed_epoch=""
	if [[ "$signed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
		signed_epoch="$(date -u -d "$signed_at" +%s 2>/dev/null || true)"
	fi
	now_epoch="$(date -u +%s)"
	if [[ ! "$signed_epoch" =~ ^[0-9]+$ ]] || ((signed_epoch > now_epoch)); then
		add_check evidence_freshness BLOCKED null true cryptographic invalid_output '{}'
	else
		age=$((now_epoch - signed_epoch))
		if ((age > 86400)); then
			add_check evidence_freshness UNVERIFIED 0 true cryptographic stale_evidence "{\"age_seconds\":$age,\"max_age_seconds\":86400}"
		else
			add_check evidence_freshness PASS 0 true cryptographic passed "{\"age_seconds\":$age,\"max_age_seconds\":86400}"
		fi
	fi
fi

add_check oci_signatures UNVERIFIED null true cryptographic not_requested '{}'
add_check live_authorization UNVERIFIED null true live not_requested '{}'
add_check live_containment UNVERIFIED null true live not_requested '{}'

report="$raw_dir/report.json"
{
	printf '{"schema_version":1,"skill":"sl-security-audit","checks":['
	for i in "${!checks[@]}"; do
		((i == 0)) || printf ','
		printf '%s' "${checks[$i]}"
	done
	printf ']}\n'
} >"$report"

tool_exists jq || exit 1
jq -ce '
  .schema_version == 1 and .skill == "sl-security-audit" and
  (.checks | type == "array" and length == 7) and
  ([.checks[].id] == ["secrets","sast","evidence_signature","evidence_freshness","oci_signatures","live_authorization","live_containment"]) and
  (all(.checks[]; (.metrics | type == "object")))
' "$report" >/dev/null 2>&1 || exit 1
jq -c . "$report"
