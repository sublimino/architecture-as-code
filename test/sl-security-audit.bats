#!/usr/bin/env bats

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	SKILL_DIR="$ROOT/.agents/skills/sl-security-audit"
	TOOL="$SKILL_DIR/Tools/security-audit.sh"
	TOOL="${MUTANT_TOOL:-$TOOL}"
	FIXTURE_BIN="$BATS_TEST_TMPDIR/bin"
	RULES="$BATS_TEST_TMPDIR/rules.yml"
	EVIDENCE="$BATS_TEST_TMPDIR/evidence"
	TRUSTED_KEY="$BATS_TEST_TMPDIR/trusted-public.pem"
	mkdir -p "$FIXTURE_BIN" "$EVIDENCE"
	printf 'rules: []\n' >"$RULES"
	printf '%s\n' 'trusted test public key' >"$TRUSTED_KEY"
	printf '%s\n' 'embedded untrusted key' >"$EVIDENCE/signing-key.pub.pem"
	printf '{"signed_at":"%s","evidence_origin":"fixture"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$EVIDENCE/bundle-header.json"

	cat >"$FIXTURE_BIN/unshare" <<'EOF'
#!/usr/bin/env bash
[[ "${SECURITY_AUDIT_UNSHARE_DENY:-0}" == 1 ]] && exit 1
while [[ "${1:-}" != -- ]]; do shift; done
shift
exec "$@"
EOF
	cat >"$FIXTURE_BIN/git" <<'EOF'
#!/usr/bin/env bash
[[ -z "${SECURITY_AUDIT_GIT_LOG:-}" ]] || printf '%s\n' "$*" >>"$SECURITY_AUDIT_GIT_LOG"
if [[ "$*" == *"rev-parse --verify HEAD"* ]]; then
  printf '%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  exit 0
fi
if [[ "$*" == *"ls-tree -r -l "* ]]; then
  if [[ "${SECURITY_AUDIT_ARCHIVE_MODE:-small}" == huge ]]; then
    printf '%s\n' '100644 blob 0000000000000000000000000000000000000000 999999999 huge.bin'
  else
    printf '%s\n' '100644 blob 0000000000000000000000000000000000000000 1 fixture.txt'
  fi
  exit 0
fi
if [[ "$*" == *"archive "* ]]; then
  [[ -z "${SECURITY_AUDIT_ARCHIVE_MARKER:-}" ]] || : >"$SECURITY_AUDIT_ARCHIVE_MARKER"
  if [[ "${SECURITY_AUDIT_ARCHIVE_MODE:-small}" == timeout ]]; then
    exec sleep 10
  fi
  exec tar -cf - -T /dev/null
fi
exit 2
EOF
	cat >"$FIXTURE_BIN/trufflehog" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
  printf '%s\n' '--no-update --no-verification --exclude-paths --exclude-detectors --json --fail'
  exit 0
fi
[[ "$(stat -c %a "$(dirname "$TMPDIR")")" == 700 ]] || exit 9
[[ "$HOME" == */home && "$XDG_CACHE_HOME" == */cache ]] || exit 9
if [[ "${SECURITY_AUDIT_SECRET_MODE:-pass}" == findings ]]; then
  printf '{"DetectorName":"canary","Raw":"TOKEN_CANARY_MUST_NOT_LEAK"}\n'
  exit 183
fi
exit 0
EOF
	cat >"$FIXTURE_BIN/semgrep" <<'EOF'
#!/usr/bin/env bash
case "${SECURITY_AUDIT_SAST_MODE:-pass}" in
  parse) printf '%s\n' '{"results":[],"errors":[{"message":"TOKEN_CANARY_MUST_NOT_LEAK"}]}' ;;
  findings) printf '%s\n' '{"results":[{"check_id":"new.issue","path":"x","extra":{"severity":"ERROR","message":"TOKEN_CANARY_MUST_NOT_LEAK"},"start":{"line":1}}],"errors":[]}' ;;
  *) printf '%s\n' '{"results":[],"errors":[]}' ;;
esac
EOF
	cat >"$FIXTURE_BIN/verify-eap-evidence.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *"--pubkey"* ]] || exit 1
[[ "$HOME" == */home && "$XDG_CACHE_HOME" == */cache ]] || exit 8
[[ "${SECURITY_AUDIT_SIGNATURE_MODE:-pass}" == pass ]] && exit 0
exit 1
EOF
	chmod +x "$FIXTURE_BIN"/*
}

run_fixture() {
	if [[ "${SECURITY_AUDIT_SECRET_MODE:-pass}" == findings ]]; then
		cat >"$FIXTURE_BIN/trufflehog" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
  printf '%s\n' '--no-update --no-verification --exclude-paths --exclude-detectors --json --fail'
  exit 0
fi
[[ "$(stat -c %a "$(dirname "$TMPDIR")")" == 700 ]] || exit 9
[[ "$HOME" == */home && "$XDG_CACHE_HOME" == */cache ]] || exit 9
printf '{"DetectorName":"canary","Raw":"TOKEN_CANARY_MUST_NOT_LEAK"}\n'
exit 183
EOF
		chmod +x "$FIXTURE_BIN/trufflehog"
	fi
	if [[ "${SECURITY_AUDIT_SAST_MODE:-pass}" == parse ]]; then
		cat >"$FIXTURE_BIN/semgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"results":[],"errors":[{"message":"TOKEN_CANARY_MUST_NOT_LEAK"}]}'
EOF
		chmod +x "$FIXTURE_BIN/semgrep"
	fi
	run env PATH="$FIXTURE_BIN:$PATH" \
		SL_SECURITY_AUDIT_SEMGREP_CONFIG="$RULES" \
		SL_SECURITY_AUDIT_VERIFIER="$FIXTURE_BIN/verify-eap-evidence.sh" \
		SECURITY_AUDIT_SECRET_MODE="${SECURITY_AUDIT_SECRET_MODE:-pass}" \
		SECURITY_AUDIT_SAST_MODE="${SECURITY_AUDIT_SAST_MODE:-pass}" \
		SECURITY_AUDIT_SIGNATURE_MODE="${SECURITY_AUDIT_SIGNATURE_MODE:-pass}" \
		"$TOOL" --repo-root "$ROOT" --timeout 2 --rules "$RULES" \
		--evidence-dir "$EVIDENCE" --public-key "$TRUSTED_KEY"
}

assert_protocol() {
	python3 - "$output" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
assert set(r) == {"schema_version", "skill", "checks"}
assert r["schema_version"] == 1
assert r["skill"] == "sl-security-audit"
assert [c["id"] for c in r["checks"]] == [
    "secrets", "sast", "evidence_signature", "evidence_freshness",
    "oci_signatures", "live_authorization", "live_containment",
]
allowed_reasons = {"passed", "findings", "missing_tool", "timeout", "coverage_gap", "invalid_output", "not_requested", "permission_denied", "untrusted_key", "stale_evidence", "offline_rules_missing"}
for c in r["checks"]:
    assert set(c) == {"id", "status", "exit_code", "required", "evidence_kind", "reason_code", "metrics"}
    assert c["status"] in {"PASS", "FAIL", "BLOCKED", "UNVERIFIED", "NOT_APPLICABLE"}
    assert c["reason_code"] in allowed_reasons
    assert all(isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 for v in c["metrics"].values())
PY
}

@test "security audit owns documented executable public CLI" {
	[ -x "$TOOL" ]
	[ -f "$SKILL_DIR/SKILL.md" ]
	[ -f "$SKILL_DIR/Workflows/Audit.md" ]
	run "$TOOL" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--repo-root"* ]]
	[[ "$output" == *"--timeout"* ]]
	[[ "$output" == *"--evidence-dir"* ]]
	[[ "$output" == *"--public-key"* ]]
	[[ "$output" == *"--rules"* ]]
}

@test "security report satisfies the scheduled runner control contract" {
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$ROOT/scripts/lib/scheduled-skills-runner.py" "$output" <<'PY'
import importlib.util, pathlib, sys, tempfile
spec = importlib.util.spec_from_file_location("audit_runner", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "report.json"
    path.write_text(sys.argv[2], encoding="utf-8")
    report = module.strict_report(path, "sl-security-audit")
    assert module.check_verdict(report["checks"]) == "UNVERIFIED"
PY
}

@test "natural language timestamps cannot certify evidence freshness" {
	printf '{"signed_at":"now","evidence_origin":"fixture"}\n' >"$EVIDENCE/bundle-header.json"
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["evidence_freshness"]["status"] == "BLOCKED"
assert c["evidence_freshness"]["reason_code"] == "invalid_output"
PY
}

@test "truncated scanner output cannot produce a clean secret verdict" {
	cat >"$FIXTURE_BIN/trufflehog" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
  printf '%s\n' '--no-update --no-verification --exclude-paths --exclude-detectors --json --fail'
  exit 0
fi
python3 -c 'import sys; sys.stdout.write(" " * 2097152)'
EOF
	chmod +x "$FIXTURE_BIN/trufflehog"
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED"
assert c["secrets"]["reason_code"] == "coverage_gap"
PY
}

@test "known-good fixtures emit fixed controls and closed live gaps" {
	run_fixture
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
for name in ("secrets", "sast", "evidence_signature", "evidence_freshness"):
    assert c[name]["status"] == "PASS", (name, c[name])
for name in ("oci_signatures", "live_authorization", "live_containment"):
    assert c[name]["status"] == "UNVERIFIED"
    assert c[name]["reason_code"] == "not_requested"
PY
}

@test "security archive uses the supplied immutable revision" {
  local revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local git_log="$BATS_TEST_TMPDIR/git-calls.log"
  run env PATH="$FIXTURE_BIN:$PATH" SECURITY_AUDIT_GIT_LOG="$git_log" \
    SL_SECURITY_AUDIT_SEMGREP_CONFIG="$RULES" \
    "$TOOL" --repo-root "$ROOT" --timeout 2 --revision "$revision" --rules "$RULES"
  [ "$status" -eq 0 ]
  assert_protocol
  grep -q "ls-tree -r -l $revision" "$git_log"
  grep -q "archive $revision" "$git_log"
  ! grep -q 'archive HEAD' "$git_log"
}

@test "SAST executes the validated scanner override rather than PATH decoy" {
  mv "$FIXTURE_BIN/semgrep" "$FIXTURE_BIN/custom-semgrep"
  cat >"$FIXTURE_BIN/semgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"results":[{"check_id":"decoy.issue","path":"x","extra":{"severity":"ERROR"},"start":{"line":1}}],"errors":[]}'
EOF
  chmod +x "$FIXTURE_BIN/semgrep"
  run env PATH="$FIXTURE_BIN:$PATH" \
    SL_SECURITY_AUDIT_SEMGREP="$FIXTURE_BIN/custom-semgrep" \
    "$TOOL" --repo-root "$ROOT" --timeout 2 --rules "$RULES"
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["sast"]["status"] == "PASS", c["sast"]
assert c["sast"]["metrics"]["findings"] == 0
PY
}

@test "missing scanner tools are BLOCKED rather than passed" {
	run env PATH="$FIXTURE_BIN:/usr/bin:/bin" \
		SL_SECURITY_AUDIT_TRUFFLEHOG=definitely-missing-trufflehog \
		SL_SECURITY_AUDIT_SEMGREP=definitely-missing-semgrep \
		SL_SECURITY_AUDIT_SEMGREP_CONFIG="$RULES" \
		"$TOOL" --repo-root "$ROOT" --timeout 2
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED" and c["secrets"]["reason_code"] == "missing_tool"
assert c["sast"]["status"] == "BLOCKED" and c["sast"]["reason_code"] == "missing_tool"
PY
}

@test "unsupported offline trufflehog flags block the secret control" {
	cat >"$FIXTURE_BIN/trufflehog" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '--no-update --exclude-paths --json'
EOF
	chmod +x "$FIXTURE_BIN/trufflehog"
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED"
assert c["secrets"]["reason_code"] == "invalid_output"
PY
}

@test "unavailable network isolation blocks static assurance" {
	run env PATH="$FIXTURE_BIN:$PATH" SECURITY_AUDIT_UNSHARE_DENY=1 \
		SL_SECURITY_AUDIT_SEMGREP_CONFIG="$RULES" \
		"$TOOL" --repo-root "$ROOT" --timeout 2
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
for name in ("secrets", "sast"):
    assert c[name]["status"] == "BLOCKED"
    assert c[name]["reason_code"] == "permission_denied"
PY
}

@test "network and live execution flags are rejected" {
	for flag in --network --live --cluster; do
		run "$TOOL" --repo-root "$ROOT" "$flag"
		[ "$status" -ne 0 ]
		[ -z "$output" ]
	done
}

@test "parse errors preserve accepted findings as coverage UNVERIFIED metrics" {
	SECURITY_AUDIT_SAST_MODE=parse run_fixture
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["sast"]["status"] == "UNVERIFIED"
assert c["sast"]["reason_code"] == "coverage_gap"
assert c["sast"]["metrics"]["parse_errors"] == 1
assert c["sast"]["metrics"]["accepted_baseline_entries"] > 0
PY
}

@test "new SAST findings FAIL even when parse coverage is incomplete" {
	cat >"$FIXTURE_BIN/semgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"results":[{"check_id":"new.issue","path":"x","extra":{"severity":"ERROR","message":"hidden"},"start":{"line":1}}],"errors":[{"message":"parse gap"}]}'
EOF
	chmod +x "$FIXTURE_BIN/semgrep"
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["sast"]["status"] == "FAIL"
assert c["sast"]["reason_code"] == "findings"
assert c["sast"]["metrics"]["parse_errors"] == 1
assert c["sast"]["metrics"]["findings"] == 1
PY
}

@test "archive size guard blocks before archive creation" {
	marker="$BATS_TEST_TMPDIR/archive-called"
	run env PATH="$FIXTURE_BIN:$PATH" SECURITY_AUDIT_ARCHIVE_MODE=huge \
		SECURITY_AUDIT_ARCHIVE_MARKER="$marker" "$TOOL" --repo-root "$ROOT" \
		--timeout 2 --rules "$RULES"
	[ "$status" -eq 0 ]
	[ ! -e "$marker" ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED"
assert c["secrets"]["reason_code"] == "invalid_output"
PY
}

@test "archive extraction deadline reports timeout without hanging" {
	run env PATH="$FIXTURE_BIN:$PATH" SECURITY_AUDIT_ARCHIVE_MODE=timeout \
		"$TOOL" --repo-root "$ROOT" --timeout 1 --rules "$RULES"
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED"
assert c["secrets"]["reason_code"] == "timeout"
assert c["secrets"]["exit_code"] in (124, 137)
PY
}

@test "scanner output capture is bounded and never echoed" {
	cat >"$FIXTURE_BIN/trufflehog" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
  printf '%s\n' '--no-update --no-verification --exclude-paths --exclude-detectors --json --fail'
  exit 0
fi
for _ in $(seq 1 10000); do
  printf '%s\n' '{"Raw":"TOKEN_CANARY_MUST_NOT_LEAK","DetectorName":"fixture"}'
done
exit 183
EOF
	chmod +x "$FIXTURE_BIN/trufflehog"
	run env PATH="$FIXTURE_BIN:$PATH" SL_SECURITY_AUDIT_MAX_LOG_BYTES=4096 \
		"$TOOL" --repo-root "$ROOT" --timeout 2 --rules "$RULES"
	[ "$status" -eq 0 ]
	[[ "$output" != *"TOKEN_CANARY_MUST_NOT_LEAK"* ]]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["secrets"]["status"] == "BLOCKED"
assert c["secrets"]["metrics"]["captured_stdout_bytes"] <= 4096
PY
}

@test "embedded key is untrusted while explicit operator key can PASS" {
	run env PATH="$FIXTURE_BIN:$PATH" SL_SECURITY_AUDIT_SEMGREP_CONFIG="$RULES" \
		SL_SECURITY_AUDIT_VERIFIER="$FIXTURE_BIN/verify-eap-evidence.sh" \
		"$TOOL" --repo-root "$ROOT" --timeout 2 --evidence-dir "$EVIDENCE"
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["evidence_signature"]["status"] == "UNVERIFIED"
assert c["evidence_signature"]["reason_code"] == "untrusted_key"
PY

	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["evidence_signature"]["status"] == "PASS"
assert c["evidence_signature"]["metrics"]["declared_live"] == 0
assert c["evidence_signature"]["metrics"]["observed_live"] == 0
PY
}

@test "stale evidence is independently non-passing" {
	printf '%s\n' '{"signed_at":"2000-01-01T00:00:00Z","evidence_origin":"live"}' >"$EVIDENCE/bundle-header.json"
	run_fixture
	[ "$status" -eq 0 ]
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["evidence_signature"]["status"] == "PASS"
assert c["evidence_freshness"]["status"] == "UNVERIFIED"
assert c["evidence_freshness"]["reason_code"] == "stale_evidence"
PY
}

@test "future evidence timestamp is rejected without negative metrics" {
	future="$(date -u -d '+60 seconds' +%Y-%m-%dT%H:%M:%SZ)"
	printf '{"signed_at":"%s","evidence_origin":"fixture"}\n' "$future" >"$EVIDENCE/bundle-header.json"
	run_fixture
	[ "$status" -eq 0 ]
	assert_protocol
	python3 - "$output" <<'PY'
import json, sys
c = {x["id"]: x for x in json.loads(sys.argv[1])["checks"]}
assert c["evidence_freshness"]["status"] == "BLOCKED"
assert c["evidence_freshness"]["reason_code"] == "invalid_output"
assert all(v >= 0 for v in c["evidence_freshness"]["metrics"].values())
PY
}

@test "baseline stays unchanged and token canary never reaches report stdout" {
	before="$(sha256sum "$ROOT/.semgrep-baseline.json" | cut -d' ' -f1)"
	SECURITY_AUDIT_SECRET_MODE=findings SECURITY_AUDIT_SAST_MODE=parse run_fixture
	[ "$status" -eq 0 ]
	assert_protocol
	[[ "$output" != *"TOKEN_CANARY_MUST_NOT_LEAK"* ]]
	after="$(sha256sum "$ROOT/.semgrep-baseline.json" | cut -d' ' -f1)"
	[ "$before" = "$after" ]
}
