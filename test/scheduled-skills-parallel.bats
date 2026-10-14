#!/usr/bin/env bats

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	RUNNER="$ROOT/scripts/test-scheduled-skills-parallel.sh"
	FIXTURE="$BATS_TEST_TMPDIR/repo"
	BIN="$BATS_TEST_TMPDIR/bin"
	HOME="$BATS_TEST_TMPDIR/home"
	mkdir -p "$FIXTURE/.agents/skills" "$BIN" "$HOME"
	export HOME
	git -C "$FIXTURE" init -q
	git -C "$FIXTURE" config user.email fixture@example.invalid
	git -C "$FIXTURE" config user.name Fixture
	touch "$FIXTURE/README"
	git -C "$FIXTURE" add README
	git -C "$FIXTURE" commit --no-gpg-sign -qm fixture
	export CAPTURE="$BATS_TEST_TMPDIR/capture"
	cat >"$BIN/unshare" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
[[ "${1:-}" == "--" ]] && shift
exec "$@"
EOF
	chmod +x "$BIN/unshare"
	export PATH="$BIN:$PATH"
	# shellcheck source=scripts/lib/wait.sh
	source "$ROOT/scripts/lib/wait.sh"
	export WAIT_STATS_FILE="$BATS_TEST_TMPDIR/wait-stats.jsonl"
	export WAIT_QUIET=1 WAIT_SLEEP=0.05 WAIT_BACKOFF=1.1 WAIT_JITTER=0 WAIT_DEADLINE_SCALE=1
}

collector() {
	local skill="$1" body="$2" dir="$FIXTURE/.agents/skills/$1/Tools" tool
	body="${body//\$CAPTURE/$CAPTURE}"
	mkdir -p "$dir"
	case "$skill" in
		sl-architecture-audit) tool=architecture-audit.sh ;;
		sl-security-audit) tool=security-audit.sh ;;
		*) tool=test-tool.sh ;;
	esac
	cat >"$dir/$tool" <<EOF
#!/usr/bin/env bash
$body
EOF
	chmod +x "$dir/$tool"
}

valid_report() {
	local skill="$1" status="${2:-PASS}"
	python3 - "$skill" "$status" <<'PY'
import json,sys
skill,status=sys.argv[1:]
controls={
 "sl-architecture-audit":{"docs_lint":"static","test_alignment":"static","flux_coverage":"static","diagram_vocabulary":"static","topology_edges":"static"},
 "sl-security-audit":{"secrets":"static","sast":"static","evidence_signature":"cryptographic","evidence_freshness":"cryptographic","oci_signatures":"cryptographic","live_authorization":"live","live_containment":"live"},
}[skill]
checks=[{"id":i,"status":status,"exit_code":0,"required":True,"evidence_kind":k,"reason_code":"passed" if status=="PASS" else "findings","metrics":{"assertions":1}} for i,k in controls.items()]
print(json.dumps({"schema_version":1,"skill":skill,"checks":checks},separators=(",",":")))
PY
}

install_default_collectors() {
	collector sl-architecture-audit "printf '%s\\n' '$(valid_report sl-architecture-audit)'"
	collector sl-security-audit "printf '%s\\n' '$(valid_report sl-security-audit)'"
}

@test "runner rejects an unexpected skill identifier" {
	run "$RUNNER" --repo-root "$FIXTURE" --skill ../../escape --no-agent
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown skill"* ]]
}

@test "runner fails before starting jobs when GNU Parallel is missing" {
	install_default_collectors
	cat >"$BIN/parallel" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
	chmod +x "$BIN/parallel"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --no-agent
	[ "$status" -eq 2 ]
	[[ "$output" == *"GNU Parallel is required"* ]]
}

@test "--jobs bounds concurrent collector processes" {
	for skill in sl-architecture-audit sl-security-audit; do
		report="$(valid_report "$skill")"
		collector "$skill" "n=\$(flock \"$CAPTURE.lock\" bash -c 'n=\$(cat \"$CAPTURE\" 2>/dev/null || echo 0); n=\$((n+1)); echo \"\$n\" >\"$CAPTURE\"; m=\$(cat \"$CAPTURE.max\" 2>/dev/null || echo 0); [ \"\$n\" -le \"\$m\" ] || echo \"\$n\" >\"$CAPTURE.max\"'); sleep 0.3; flock \"$CAPTURE.lock\" bash -c 'n=\$(cat \"$CAPTURE\"); echo \$((n-1)) >\"$CAPTURE\"'; printf '%s\\n' '$report'"
	done
	run "$RUNNER" --repo-root "$FIXTURE" --jobs 1 --no-agent
	[ "$status" -eq 0 ]
	[ "$(cat "$CAPTURE.max")" -eq 1 ]
}

@test "collector timeout kills its descendant process tree" {
	collector sl-architecture-audit 'echo ready >"$CAPTURE.ready"; (sleep 3; echo escaped >"$CAPTURE") & wait'
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --timeout 1 --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *"BLOCKED"* ]]
	[ -e "$CAPTURE.ready" ]
	sleep 3.2
	[ ! -e "$CAPTURE" ]
}

@test "interrupting the runner terminates owned descendants" {
	collector sl-architecture-audit 'echo ready >"$CAPTURE.ready"; (sleep 4; echo escaped >"$CAPTURE") & wait'
	"$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --timeout 20 --no-agent >"$BATS_TEST_TMPDIR/out" 2>&1 &
	pid=$!
	local ready_condition
	printf -v ready_condition '[ -f %q ]' "$CAPTURE.ready"
	_wait_retry 10 "collector startup" "$ready_condition"
	kill -INT "$pid"
	wait "$pid" || rc=$?
	[ "${rc:-0}" -ne 0 ]
	sleep 4.1
	[ ! -e "$CAPTURE" ]
}

@test "zero-exit invalid JSON is UNVERIFIED and cannot pass" {
	collector sl-architecture-audit 'printf "not-json\\n"; exit 0'
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *"UNVERIFIED"* ]]
}

@test "runner never resolves a missing collector from HOME" {
	mkdir -p "$HOME/.andy_sync/confExt/skills/sl-architecture-audit/Tools"
	cat >"$HOME/.andy_sync/confExt/skills/sl-architecture-audit/Tools/architecture-audit.sh" <<'EOF'
#!/usr/bin/env bash
echo unsafe-fallback-ran >"$CAPTURE"
EOF
	chmod +x "$HOME/.andy_sync/confExt/skills/sl-architecture-audit/Tools/architecture-audit.sh"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[ ! -e "$CAPTURE" ]
	[[ "$output" == *"BLOCKED"* ]]
}

@test "collector symlinks cannot escape the repository boundary" {
	collector sl-architecture-audit 'echo escaped >"$CAPTURE"'
	local tool="$FIXTURE/.agents/skills/sl-architecture-audit/Tools/architecture-audit.sh"
	local outside="$BATS_TEST_TMPDIR/outside-collector.sh"
	mv "$tool" "$outside"
	ln -s "$outside" "$tool"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *"BLOCKED"* ]]
	[ ! -e "$CAPTURE" ]
}

@test "existing evidence output is preserved before any collector starts" {
	collector sl-architecture-audit 'echo ran >"$CAPTURE"'
	local existing="$BATS_TEST_TMPDIR/existing.json"
	printf '%s\n' '{"preserve":true}' >"$existing"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent --evidence-out "$existing"
	[ "$status" -eq 2 ]
	[ "$(cat "$existing")" = '{"preserve":true}' ]
	[ ! -e "$CAPTURE" ]
}

make_opencode_stub() {
	cat >"$BIN/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$CAPTURE.args"
printf '%s' "\${OPENCODE_CONFIG_CONTENT:-}" >"$CAPTURE.config"
if [ "\${1:-}" = export ]; then
  printf '%s\n' '{"messages":[{"info":{"role":"assistant","sessionID":"ses_fixture123","agent":"sl-audit-reviewer","providerID":"openai","modelID":"gpt-6.1-sol"},"parts":[{"type":"text","text":"MACHINE VERDICT: PASS"}]}]}'
else
  printf '%s\n' '{"type":"step_start","part":{"type":"step-start","sessionID":"ses_fixture123"}}'
  printf '%s\n' '{"type":"text","part":{"type":"text","text":"MACHINE VERDICT: PASS","sessionID":"ses_fixture123","messageID":"msg_fixture"}}'
  printf '%s\n' '{"type":"step_finish","part":{"type":"step-finish","sessionID":"ses_fixture123"}}'
fi
EOF
	chmod +x "$BIN/opencode"
}

@test "reviewer receives sanitized evidence, fixed model, and invocation deny override" {
	make_opencode_stub
	collector sl-architecture-audit 'echo "raw-secret-value" >&2; printf '\''%s\\n'\'' '\''{"schema_version":1,"skill":"sl-architecture-audit","checks":[{"id":"required_control_coverage","status":"FAIL","exit_code":9,"required":true,"evidence_kind":"static","reason_code":"coverage_incomplete","metrics":{"missing":1}},{"id":"raw_secret_value","status":"PASS","exit_code":0,"required":false,"evidence_kind":"static","reason_code":"raw_secret_value","metrics":{"raw_secret_value":7}}]}'\'''
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --agent-timeout 5
	[ "$status" -eq 1 ]
	grep -qx 'openai/gpt-6.1-sol' "$CAPTURE.args"
	grep -qx 'sl-audit-reviewer' "$CAPTURE.args"
	jq -e '.permission["*"] == "deny" and .agent["sl-audit-reviewer"].permission["*"] == "deny"' "$CAPTURE.config"
	! grep -q 'raw-secret-value' "$CAPTURE.args"
	! grep -q 'raw_secret_value' "$CAPTURE.args"
	[[ "$output" != *"raw-secret-value"* ]]
}

@test "advisory reviewer cannot promote a machine FAIL verdict" {
	make_opencode_stub
	collector sl-architecture-audit "printf '%s\\n' '$(valid_report sl-architecture-audit FAIL)'"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "--no-agent is explicit collector-only mode" {
	install_default_collectors
	cat >"$BIN/opencode" <<EOF
#!/usr/bin/env bash
echo invoked >"$CAPTURE"
exit 99
EOF
	chmod +x "$BIN/opencode"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --no-agent
	[ "$status" -eq 0 ]
	[ ! -e "$CAPTURE" ]
	[[ "$output" == *"collector-only"* ]]
}

@test "structured evidence records exact repository metadata" {
	install_default_collectors
	out="$BATS_TEST_TMPDIR/evidence.json"
	run "$RUNNER" --repo-root "$FIXTURE" --no-agent --evidence-out "$out"
	[ "$status" -eq 0 ]
	[ "$(jq -r .source.before_commit "$out")" = "$(git -C "$FIXTURE" rev-parse HEAD)" ]
	[ "$(jq -r .source.before_dirty "$out")" = true ]
	[ "$(jq -r .source.coherence_status "$out")" = PASS ]
	[ "$(jq -r '.runs | length' "$out")" -eq 2 ]
	jq -e '.run_id | test("^[a-z0-9-]+$")' "$out"
}

@test "private logs are retained but never dumped by verbose output" {
	collector sl-architecture-audit 'echo private-log-token >&2; printf '\''%s\\n'\'' '\''not-json'\'''
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent --verbose
	[ "$status" -eq 1 ]
	[[ "$output" != *"private-log-token"* ]]
	dir="$(printf '%s\n' "$output" | awk '/Evidence directory:/ {print $3}')"
	[ "$(stat -c %a "$dir")" = 700 ]
	grep -q private-log-token "$dir/logs/sl-architecture-audit.stderr"
}

@test "collector environment clears demo and goal control variables" {
	collector sl-architecture-audit "if env | grep -Eq '^(DEMO_|GOAL_MODE=)'; then exit 12; fi; printf '%s\\n' '$(valid_report sl-architecture-audit)'"
	run env DEMO_SECRET=should-not-leak GOAL_MODE=unsafe "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 0 ]
}

@test "unsafe legacy checks are BLOCKED without execution" {
	mkdir -p "$FIXTURE/.agents/skills/sl-portforward-supervisor/Tools"
	cat >"$FIXTURE/.agents/skills/sl-portforward-supervisor/Tools/portforward-check.sh" <<EOF
#!/usr/bin/env bash
echo executed >"$CAPTURE"
EOF
	chmod +x "$FIXTURE/.agents/skills/sl-portforward-supervisor/Tools/portforward-check.sh"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-portforward-supervisor --no-agent
	[ "$status" -eq 1 ]
	[ ! -e "$CAPTURE" ]
	[[ "$output" == *"BLOCKED"* ]]
}

@test "nonfinite or negative metrics make evidence UNVERIFIED" {
	collector sl-architecture-audit 'printf '\''%s\n'\'' '\''{"schema_version":1,"skill":"sl-architecture-audit","checks":[{"id":"required_control_coverage","status":"PASS","exit_code":0,"required":true,"evidence_kind":"static","reason_code":"coverage_complete","metrics":{"findings":-1}}]}'\'''
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *"UNVERIFIED"* ]]
}

@test "reviewer timeout makes an otherwise green run incomplete" {
	install_default_collectors
	cat >"$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
	chmod +x "$BIN/opencode"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --agent-timeout 0.2
	[ "$status" -eq 1 ]
	[[ "$output" == *"Reviewer: BLOCKED"* ]]
}

@test "repository reviewer profile fixes model and denies every tool" {
	profile="$ROOT/.opencode/agents/sl-audit-reviewer.md"
	grep -q '^model: openai/gpt-6.1-sol$' "$profile"
	grep -q '^mode: all$' "$profile"
	grep -A2 '^permission:$' "$profile" | grep -q '^  "\*": deny$'
	grep -A2 '^tools:$' "$profile" | grep -q '^  "\*": false$'
}

@test "collector receives validated repo root and integer timeout" {
	report="$(valid_report sl-architecture-audit)"
	collector sl-architecture-audit "[ \"\$1\" = --repo-root ] && [ \"\$2\" = \"$FIXTURE\" ] && [ \"\$3\" = --timeout ] && [[ \"\$4\" =~ ^[0-9]+$ ]] && [ \"\$4\" -le 7 ] || exit 23; printf '%s\\n' '$report'"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --timeout 7 --no-agent
	[ "$status" -eq 0 ]
}

@test "missing required control cannot pass" {
	bad="$(valid_report sl-architecture-audit | jq -c '.checks |= map(select(.id != "topology_edges"))')"
	collector sl-architecture-audit "printf '%s\\n' '$bad'"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *UNVERIFIED* ]]
}

@test "wrong evidence kind cannot pass" {
	bad="$(valid_report sl-security-audit | jq -c '(.checks[] | select(.id == "live_containment") | .evidence_kind) = "static"')"
	collector sl-security-audit "printf '%s\\n' '$bad'"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-security-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *UNVERIFIED* ]]
}

@test "nonzero collector cannot pass a PASS report" {
	collector sl-architecture-audit "printf '%s\\n' '$(valid_report sl-architecture-audit)'; exit 7"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL (exit=7"* ]]
}

@test "repo paths containing spaces remain one collector argument" {
	space="$BATS_TEST_TMPDIR/repo with spaces"
	mv "$FIXTURE" "$space"
	FIXTURE="$space"
	report="$(valid_report sl-architecture-audit)"
	collector sl-architecture-audit "[ \"\$2\" = \"$space\" ] || exit 24; printf '%s\\n' '$report'"
	run "$RUNNER" --repo-root "$space" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 0 ]
}

@test "reviewer tool events make review UNVERIFIED" {
	install_default_collectors
	cat >"$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"tool_use","part":{"type":"tool","name":"bash"}}'
echo '{"type":"text","sessionID":"s","providerID":"openai","modelID":"gpt-6.1-sol","part":{"type":"text","text":"PASS"}}'
EOF
	chmod +x "$BIN/opencode"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Reviewer: UNVERIFIED"* ]]
}

@test "reviewer export must attribute the intended role and model" {
	install_default_collectors
	cat >"$BIN/opencode" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = export ]; then
  echo '{"messages":[{"info":{"role":"assistant","sessionID":"ses_fixture123","agent":"build","providerID":"openai","modelID":"gpt-6.1-sol"},"parts":[{"type":"text","text":"PASS"}]}]}'
else
  echo '{"type":"text","part":{"type":"text","text":"PASS","sessionID":"ses_fixture123","messageID":"msg_fixture"}}'
  echo '{"type":"step_finish","part":{"type":"step-finish","sessionID":"ses_fixture123"}}'
fi
EOF
	chmod +x "$BIN/opencode"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE"
	[ "$status" -eq 1 ]
	[[ "$output" == *"Reviewer: UNVERIFIED"* ]]
}

@test "interrupting reviewer kills its descendant tree" {
	install_default_collectors
	cat >"$BIN/opencode" <<EOF
#!/usr/bin/env bash
(sleep 3; echo escaped >"$CAPTURE") & wait
EOF
	chmod +x "$BIN/opencode"
	env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --agent-timeout 20 >"$BATS_TEST_TMPDIR/reviewer-out" 2>&1 &
	pid=$!
	sleep 1
	kill -TERM "$pid"
	wait "$pid" || true
	sleep 3.2
	[ ! -e "$CAPTURE" ]
}

@test "log floods are capped without limiting collector artifacts" {
	report="$(valid_report sl-architecture-audit)"
	collector sl-architecture-audit "dd if=/dev/zero of='$CAPTURE' bs=1048576 count=2 status=none; dd if=/dev/zero bs=1048576 count=2 status=none >&2; printf '%s\\n' '$report'"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
	[ "$status" -eq 0 ]
	[ "$(stat -c %s "$CAPTURE")" -eq 2097152 ]
	dir="$(printf '%s\n' "$output" | awk '/Evidence directory:/ {print $3}')"
	[ "$(stat -c %s "$dir/logs/sl-architecture-audit.stderr")" -le 1048576 ]
}

@test "joblog completion order and malformed rows cannot misattribute jobs" {
	cat >"$BIN/parallel" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'GNU parallel fixture'; exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --joblog ]; then joblog="$2"; shift 2; else shift; fi
done
cat >"$joblog" <<'ROWS'
Seq	Host	Starttime	JobRuntime	Send	Receive	Exitval	Signal	Command
2	:	1	2.000	0	0	-1	15	second
malformed
1	:	1	1.000	0	0	-1	15	first
ROWS
EOF
	chmod +x "$BIN/parallel"
	out="$BATS_TEST_TMPDIR/ordered.json"
	run env PATH="$BIN:$PATH" "$RUNNER" --repo-root "$FIXTURE" --timeout 10 --no-agent --evidence-out "$out"
	[ "$status" -eq 1 ]
	jq -e '.runs[0].duration_seconds == 1 and .runs[1].duration_seconds == 2' "$out"
}

@test "contradictory PASS metadata is UNVERIFIED" {
	for mutation in '(.checks[] | select(.id == "docs_lint") | .reason_code) = "missing_tool"' '(.checks[] | select(.id == "docs_lint") | .exit_code) = null'; do
		bad="$(valid_report sl-architecture-audit | jq -c "$mutation")"
		collector sl-architecture-audit "printf '%s\\n' '$bad'"
		run "$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent
		[ "$status" -eq 1 ]
		[[ "$output" == *UNVERIFIED* ]]
	done
}

@test "HEAD change during collection prevents aggregate PASS" {
	report="$(valid_report sl-architecture-audit)"
	collector sl-architecture-audit "sleep 1; printf '%s\\n' '$report'"
	out="$BATS_TEST_TMPDIR/head-change.json"
	"$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent --evidence-out "$out" >"$BATS_TEST_TMPDIR/head-out" 2>&1 &
	pid=$!
	sleep 0.3
	touch "$FIXTURE/new-file"
	git -C "$FIXTURE" add new-file
	git -C "$FIXTURE" commit --no-gpg-sign -qm changed
	wait "$pid" || rc=$?
	[ "${rc:-0}" -eq 1 ]
	jq -e '.source.coherence_status == "UNVERIFIED" and .machine_verdict == "UNVERIFIED"' "$out"
}

@test "dirty content change during collection prevents aggregate PASS" {
	printf before >"$FIXTURE/README"
	report="$(valid_report sl-architecture-audit)"
	collector sl-architecture-audit "sleep 1; printf '%s\\n' '$report'"
	out="$BATS_TEST_TMPDIR/dirty-change.json"
	"$RUNNER" --repo-root "$FIXTURE" --skill sl-architecture-audit --no-agent --evidence-out "$out" >"$BATS_TEST_TMPDIR/dirty-out" 2>&1 &
	pid=$!
	sleep 0.3
	printf after >"$FIXTURE/README"
	wait "$pid" || rc=$?
	[ "${rc:-0}" -eq 1 ]
	jq -e '.source.before_dirty == true and .source.coherence_status == "UNVERIFIED" and .machine_verdict == "UNVERIFIED"' "$out"
}

@test "security collector receives the immutable pre-run revision" {
	revision="$(git -C "$FIXTURE" rev-parse HEAD)"
	report="$(valid_report sl-security-audit)"
	collector sl-security-audit "[ \"\$5\" = --revision ] && [ \"\$6\" = '$revision' ] || exit 25; printf '%s\\n' '$report'"
	run "$RUNNER" --repo-root "$FIXTURE" --skill sl-security-audit --no-agent
	[ "$status" -eq 0 ]
}
