#!/usr/bin/env bats

setup() {
	bats_require_minimum_version 1.5.0
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	SKILL_DIR="$ROOT/.agents/skills/sl-architecture-audit"
	TOOL="$SKILL_DIR/Tools/architecture-audit.sh"
	FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
	FIXTURE_MODE_FILE="$BATS_TEST_TMPDIR/mode"
	mkdir -p "$FIXTURE_BIN"

	cat >"$FIXTURE_BIN/unshare" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
[[ "${1:-}" == "--" ]] && shift
exec "$@"
EOF
	cat >"$FIXTURE_BIN/make" <<EOF
#!/usr/bin/env bash
target="\${*: -1}"
case "\$(cat "$FIXTURE_MODE_FILE"):\$target" in
	fail:test-alignment) exit 7 ;;
	timeout:docs-lint) exec python3 -c 'while True: pass' ;;
	flood:docs-lint) exec python3 -c 'print("x" * 2097152)' ;;
	*) exit 0 ;;
esac
EOF
	cat >"$FIXTURE_BIN/bats" <<EOF
#!/usr/bin/env bash
[[ "\$(cat "$FIXTURE_MODE_FILE")" == fail-diagram ]] && exit 9
exit 0
EOF
	chmod +x "$FIXTURE_BIN/unshare" "$FIXTURE_BIN/make" "$FIXTURE_BIN/bats"
	printf 'pass\n' >"$FIXTURE_MODE_FILE"
}

run_fixture() {
	printf '%s\n' "${1:-pass}" >"$FIXTURE_MODE_FILE"
	run env PATH="$FIXTURE_BIN:$PATH" \
		"$TOOL" --repo-root "$ROOT" --timeout "${2:-2}"
}

assert_protocol() {
	python3 - "$output" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
assert set(r) == {"schema_version", "skill", "checks"}
assert r["schema_version"] == 1
assert r["skill"] == "sl-architecture-audit"
assert [c["id"] for c in r["checks"]] == [
    "docs_lint", "test_alignment", "flux_coverage",
    "diagram_vocabulary", "topology_edges",
]
for c in r["checks"]:
    assert set(c) == {"id", "status", "exit_code", "required", "evidence_kind", "reason_code", "metrics"}
    assert c["status"] in {"PASS", "FAIL", "BLOCKED", "UNVERIFIED", "NOT_APPLICABLE"}
    assert c["reason_code"] in {"passed", "findings", "missing_tool", "timeout", "coverage_gap", "invalid_output", "not_requested", "permission_denied"}
    assert all(isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 for v in c["metrics"].values())
PY
}

@test "architecture audit owns documented executable public CLI" {
	[ -x "$TOOL" ]
	[ -f "$SKILL_DIR/SKILL.md" ]
	[ -f "$SKILL_DIR/Workflows/Audit.md" ]
	run "$TOOL" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--repo-root"* ]]
	[[ "$output" == *"--timeout"* ]]
}

@test "architecture log flooding is bounded and cannot certify PASS" {
	run_fixture flood
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["docs_lint"]["status"] == "BLOCKED"
assert c["docs_lint"]["reason_code"] == "invalid_output"
PY
}

@test "architecture report satisfies the scheduled runner control contract" {
	run_fixture pass
	[ "$status" -eq 0 ]
	python3 - "$ROOT/scripts/lib/scheduled-skills-runner.py" "$output" <<'PY'
import importlib.util, json, pathlib, sys, tempfile
spec = importlib.util.spec_from_file_location("audit_runner", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "report.json"
    path.write_text(sys.argv[2], encoding="utf-8")
    report = module.strict_report(path, "sl-architecture-audit")
    assert module.check_verdict(report["checks"]) == "UNVERIFIED"
PY
}

@test "known-good fixtures emit exact checks and honest topology gap" {
	run_fixture pass
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
for name in ("docs_lint", "test_alignment", "flux_coverage", "diagram_vocabulary"):
    assert c[name]["status"] == "PASS"
    assert c[name]["reason_code"] == "passed"
assert c["topology_edges"]["status"] == "UNVERIFIED"
assert c["topology_edges"]["required"] is True
assert c["topology_edges"]["reason_code"] == "coverage_gap"
PY
}

@test "a failing registered command becomes a finding without breaking JSON" {
	run_fixture fail
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["test_alignment"]["status"] == "FAIL"
assert c["test_alignment"]["exit_code"] == 7
assert c["test_alignment"]["reason_code"] == "findings"
PY
}

@test "missing bats is BLOCKED rather than silently passed" {
	rm "$FIXTURE_BIN/bats"
	run env PATH="$FIXTURE_BIN:/usr/bin:/bin" ARCH_AUDIT_BATS="definitely-missing-bats" \
		"$TOOL" --repo-root "$ROOT" --timeout 2
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["diagram_vocabulary"]["status"] == "BLOCKED"
assert c["diagram_vocabulary"]["exit_code"] is None
assert c["diagram_vocabulary"]["reason_code"] == "missing_tool"
PY
}

@test "timed out command is BLOCKED and collector remains bounded" {
	run_fixture timeout 1
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["docs_lint"]["status"] == "BLOCKED"
assert c["docs_lint"]["reason_code"] == "timeout"
assert c["docs_lint"]["exit_code"] in (124, 137)
PY
}

@test "malformed helper output is an instrument failure with no stdout" {
	local copy="$BATS_TEST_TMPDIR/skill"
	cp -R "$SKILL_DIR" "$copy"
	cat >"$copy/Tools/report.py" <<'EOF'
#!/usr/bin/env python3
print("not-json")
EOF
	chmod +x "$copy/Tools/architecture-audit.sh" "$copy/Tools/report.py"
	run --separate-stderr env PATH="$FIXTURE_BIN:$PATH" "$copy/Tools/architecture-audit.sh" --repo-root "$ROOT" --timeout 2
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"invalid report"* ]]
}

@test "fixture environment cannot leak DEMO overrides into checks" {
	printf 'fail\n' >"$FIXTURE_MODE_FILE"
	run env PATH="$FIXTURE_BIN:$PATH" DEMO_ARCHITECTURE_AUDIT_STATUS=PASS \
		"$TOOL" --repo-root "$ROOT" --timeout 2
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["test_alignment"]["status"] == "FAIL"
PY
}
