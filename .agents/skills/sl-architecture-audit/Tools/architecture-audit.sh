#!/usr/bin/env bash
set -uo pipefail

usage() {
	cat <<'EOF'
Usage: architecture-audit.sh --repo-root PATH [--timeout SECONDS]

Options:
  --repo-root PATH   Repository root containing the existing static gates.
  --timeout SECONDS  Per-command GNU timeout in whole seconds (default: 120).
  --help             Show this help.
EOF
}

fail() {
	printf 'architecture-audit: %s\n' "$1" >&2
	exit 2
}

repo_root=""
command_timeout=120
while (($#)); do
	case "$1" in
		--repo-root)
			(($# >= 2)) || fail "--repo-root requires a value"
			repo_root="$2"
			shift 2
			;;
		--timeout)
			(($# >= 2)) || fail "--timeout requires a value"
			command_timeout="$2"
			shift 2
			;;
		--help|-h)
			usage
			exit 0
			;;
		*) fail "unknown argument" ;;
	esac
done

[[ -n "$repo_root" && -d "$repo_root" ]] || fail "repository root is not a directory"
[[ "$command_timeout" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive integer"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || fail "cannot resolve tool directory"
report_helper="$script_dir/report.py"
[[ -f "$report_helper" ]] || fail "report helper is unavailable"

unshare_name="${ARCH_AUDIT_UNSHARE:-unshare}"
nono_name="${ARCH_AUDIT_NONO:-nono}"
timeout_bin="$(command -v timeout || true)"
unshare_bin="$(command -v "$unshare_name" || true)"
nono_bin="$(command -v "$nono_name" || true)"
python_bin="$(command -v python3 || true)"
make_name="${ARCH_AUDIT_MAKE:-make}"
bats_name="${ARCH_AUDIT_BATS:-bats}"
make_bin="$(command -v "$make_name" || true)"
bats_bin="$(command -v "$bats_name" || true)"
[[ -n "$timeout_bin" && -n "$python_bin" ]] || fail "required execution tools are unavailable"

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/sl-architecture-audit.XXXXXX")" || fail "cannot create run directory"
chmod 700 "$run_dir" || fail "cannot protect run directory"
results="$run_dir/results.tsv"
: >"$results" || fail "cannot initialize results"

offline_reason=""
offline_isolation=()

unshare_probe_exit=0
nono_probe_exit=0

if [[ -n "$unshare_bin" ]]; then
	"$timeout_bin" --kill-after=1 "${command_timeout}s" \
		"$unshare_bin" --user --map-root-user --net -- true \
		>"$run_dir/offline-probe-unshare.log" 2>&1
	unshare_probe_exit=$?
	if ((unshare_probe_exit == 0)); then
		offline_isolation=("$unshare_bin" --user --map-root-user --net --)
	fi
fi

if ((${#offline_isolation[@]} == 0)) && [[ -n "$nono_bin" ]]; then
	local_tool_dirs=()
	for d in "${HOME}/.local/bin" "${HOME}/.bun" "${HOME}/.hermes"; do
		[[ -d "$d" ]] && local_tool_dirs+=(--allow "$d")
	done
	"$timeout_bin" --kill-after=1 "${command_timeout}s" \
		"$nono_bin" wrap -s --allow-cwd --allow /tmp --allow "$repo_root" --allow "$run_dir" "${local_tool_dirs[@]}" --block-net -- true \
		>"$run_dir/offline-probe-nono.log" 2>&1
	nono_probe_exit=$?
	if ((nono_probe_exit == 0)); then
		offline_isolation=("$nono_bin" wrap -s --allow-cwd --allow /tmp --allow "$repo_root" --allow "$run_dir" "${local_tool_dirs[@]}" --block-net --)
	fi
fi

if ((${#offline_isolation[@]} == 0)); then
	if [[ -z "$unshare_bin" && -z "$nono_bin" ]]; then
		offline_reason="missing_tool"
	elif [[ "$unshare_probe_exit" == "124" || "$unshare_probe_exit" == "137" || "$nono_probe_exit" == "124" || "$nono_probe_exit" == "137" ]]; then
		offline_reason="timeout"
	else
		offline_reason="permission_denied"
	fi
fi

append_blocked() {
	local id="$1" kind="$2" reason="$3"
	printf '%s\tBLOCKED\tnull\ttrue\t%s\t%s\tfindings=0\n' "$id" "$kind" "$reason" >>"$results"
}

run_check() {
	local id="$1" kind="$2" tool="$3"
	shift 3
	if [[ -n "$offline_reason" ]]; then
		append_blocked "$id" "$kind" "$offline_reason"
		return
	fi
	if [[ -z "$tool" ]]; then
		append_blocked "$id" "$kind" "missing_tool"
		return
	fi

	local status exit_code reason findings log_bytes
	local -a pipe_codes
	"$timeout_bin" --kill-after=1 "${command_timeout}s" \
		"${offline_isolation[@]}" \
		env -i PATH="$PATH" HOME="$run_dir" XDG_CONFIG_HOME="$run_dir" TMPDIR="$run_dir" \
		TERM="${TERM:-dumb}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
		LANG=C LC_ALL=C "$tool" "$@" \
		2>&1 | head -c 1048576 >"$run_dir/$id.log"
	pipe_codes=("${PIPESTATUS[@]}")
	exit_code="${pipe_codes[0]}"
	log_bytes="$(stat -c %s "$run_dir/$id.log" 2>/dev/null || printf 1048576)"
	if ((pipe_codes[1] != 0 || log_bytes >= 1048576)); then
		printf '%s\tBLOCKED\t%s\ttrue\t%s\tinvalid_output\tfindings=0\n' \
			"$id" "$exit_code" "$kind" >>"$results"
		return
	fi
	case "$exit_code" in
		0) status=PASS; reason=passed; findings=0 ;;
		124|137) status=BLOCKED; reason=timeout; findings=0 ;;
		*) status=FAIL; reason=findings; findings=1 ;;
	esac
	printf '%s\t%s\t%s\ttrue\t%s\t%s\tfindings=%s\n' \
		"$id" "$status" "$exit_code" "$kind" "$reason" "$findings" >>"$results"
}

run_check docs_lint static "$make_bin" --no-print-directory -C "$repo_root" docs-lint
run_check test_alignment static "$make_bin" --no-print-directory -C "$repo_root" test-alignment
run_check flux_coverage static "$make_bin" --no-print-directory -C "$repo_root" flux-coverage
run_check diagram_vocabulary static "$bats_bin" "$repo_root/test/diagram-focus.bats"
printf 'topology_edges\tUNVERIFIED\tnull\ttrue\tstatic\tcoverage_gap\tassertions=0\n' >>"$results"

candidate="$run_dir/report.json"
if ! "$python_bin" "$report_helper" "$results" >"$candidate" 2>"$run_dir/report.log"; then
	printf 'architecture-audit: report generation failed; log=%s\n' "$run_dir/report.log" >&2
	exit 3
fi
if ! "$python_bin" - "$candidate" >/dev/null 2>"$run_dir/validation.log" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
assert set(report) == {"schema_version", "skill", "checks"}
assert report["schema_version"] == 1
assert report["skill"] == "sl-architecture-audit"
assert [item["id"] for item in report["checks"]] == [
    "docs_lint", "test_alignment", "flux_coverage",
    "diagram_vocabulary", "topology_edges",
]
for item in report["checks"]:
    assert set(item) == {"id", "status", "exit_code", "required", "evidence_kind", "reason_code", "metrics"}
    assert item["status"] in {"PASS", "FAIL", "BLOCKED", "UNVERIFIED", "NOT_APPLICABLE"}
    assert item["exit_code"] is None or isinstance(item["exit_code"], int)
    assert isinstance(item["required"], bool)
    assert item["evidence_kind"] in {"static", "fixture", "live", "cryptographic"}
    assert item["reason_code"] in {"passed", "findings", "missing_tool", "timeout", "coverage_gap", "invalid_output", "not_requested", "permission_denied"}
    assert all(isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 for value in item["metrics"].values())
PY
then
	printf 'architecture-audit: invalid report; log=%s\n' "$run_dir/validation.log" >&2
	exit 3
fi

cat "$candidate"
