#!/usr/bin/env bash
# verify-cel.sh — one entry point for every tier of CEL-policy verification.
#
# Usage:
#   scripts/verify-cel.sh                       # every tier, in parallel
#   scripts/verify-cel.sh engine                # one tier alone (iteration)
#   scripts/verify-cel.sh conformance fe        # any subset
#
# Tier map — what each tier covers, and its measured wall clock on a 24-core
# box with warm go and uv caches (branch cel/a2-verify, base cb0a6d0e):
#
#   id  name          covers                                            measured
#   t1  engine        go test ./... -count=1 in apps/policy-engine:      14.1s
#                     CEL eval, compliance scan, money, FAIR, frameworks,
#                     bundles manifest, adversarial + e2e engine tests.
#   t2  conformance   -run TestConformance only: every framework pack's    0.7s
#                     fixtures replayed through the real CELEngine, plus
#                     the harness self-tests. Fast enough to run on save.
#   t3  fe-fast       fe pytest, the four policy/CEL files, no Postgres:   1.5s
#                     policy scan contract, per-agent reconciliation,
#                     evaluation and engine client. 3 DB tests skip here
#                     and are covered by t5.
#   t4  fe-full       the whole fe pytest suite, parallel:                42.0s
#                     3443 passed / 112 skipped, as two passes: 3409 at
#                     -n auto --dist worksteal, then 34 serially (see
#                     run_t4). Serial baseline 404s.
#   t5  db            real Postgres in a throwaway container: the policy  23.0s
#                     scan integration tests plus test/cel-frameworks-api-
#                     e2e.py, which builds the real engine binary and
#                     drives the real ASGI app against a migrated scratch
#                     database. Fails loudly if Docker is unavailable.
#
# Whole run, all five in parallel: 40.1s and 40.9s wall clock on two consecutive
# runs (bounded by t4), against ~480s for the same tiers one after another with
# the fe suite serial. VERIFY_CEL_ISOLATE_T4=1 gives t4 its own wave: 68s.
#
# How t4 got parallel WITHOUT touching fe-signalloom:
#   pytest.ini carries `addopts = -p no:xdist`, which disables the plugin before
#   `-n` can be parsed, which is why `-n auto` is rejected. `-o addopts=` on the
#   command line overrides the ini value (the pattern already used elsewhere in
#   this Makefile), so the plugin loads and `-n auto --dist worksteal` works
#   with no edit to pytest.ini or any conftest. Nothing is weakened: isolation
#   is unchanged, xdist workers are separate processes, and the pass/skip counts
#   are identical to the serial run (3443/112 both ways). --dist worksteal rather
#   than the loadfile default because the durations here are wildly uneven — see
#   the measurements in pytest.ini. One file has to stay serial, for a CPU-budget
#   reason rather than an isolation one — see run_t4.
#
# Honest aggregation — a tier that checked nothing must never read as success:
#   * any tier exiting non-zero fails the run;
#   * any tier reporting zero passing tests fails the run, including pytest's
#     exit 5 ("no tests ran") and go's "no test files";
#   * t2 additionally fails if it scanned zero conformance fixtures, so an empty
#     or unreadable policy/frameworks tree is visible rather than silently green;
#   * t5 additionally fails on ANY skip — a missing DATABASE_URL turns those
#     tests into skips, and a skipped integration tier is the exact failure this
#     runner exists to stop;
#   * Docker missing, broken, or slow to come up fails t5. It never skips.
#   t3 and t4 carry known skips (3 and 112) which is why they are not held to
#   zero: t3's three are the DB tests t5 runs for real, t4's are environment
#   gated tests outside the CEL surface.
#
# test/verify-cel.bats proves the aggregator can go red: it plants a failing
# test, a test file with no tests, a skip-only file, a fixture-free conformance
# run, and a missing Docker binary, and requires a non-zero exit from each. A
# green runner that cannot go red is worse than no runner.
#
# Injection seams (all env, all used by that test file):
#   VERIFY_CEL_GO, VERIFY_CEL_DOCKER, VERIFY_CEL_ENGINE_DIR, VERIFY_CEL_FE_SRC,
#   VERIFY_CEL_T2_RUN, VERIFY_CEL_T3_FILES, VERIFY_CEL_T4_SERIAL,
#   VERIFY_CEL_T5_FILES, VERIFY_CEL_PG_IMAGE, VERIFY_CEL_PG_TIMEOUT,
#   VERIFY_CEL_LOG_DIR, VERIFY_CEL_ISOLATE_T4.
#
# No `set -u`: a tier failing must not abort the run before the table prints.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GO_BIN="${VERIFY_CEL_GO:-go}"
DOCKER_BIN="${VERIFY_CEL_DOCKER:-docker}"
ENGINE_DIR="${VERIFY_CEL_ENGINE_DIR:-${REPO_ROOT}/d2-signalloom/apps/policy-engine}"
FE_SRC="${VERIFY_CEL_FE_SRC:-${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src}"
T2_RUN="${VERIFY_CEL_T2_RUN:-TestConformance}"
T3_FILES="${VERIFY_CEL_T3_FILES:-tests/test_policy_scan_integration.py tests/test_policy_scan_per_agent.py tests/test_policy_evaluation.py tests/test_policy_engine.py}"
T4_SERIAL="${VERIFY_CEL_T4_SERIAL:-tests/test_scenario_seeding.py tests/test_cadvisor_poller.py}"
T5_FILES="${VERIFY_CEL_T5_FILES:-tests/test_policy_scan_integration.py tests/test_policy_scan_per_agent.py ${REPO_ROOT}/test/cel-frameworks-api-e2e.py}"
PG_IMAGE="${VERIFY_CEL_PG_IMAGE:-postgres:16}"
PG_TIMEOUT="${VERIFY_CEL_PG_TIMEOUT:-60}"

# Baselines measured on cb0a6d0e, printed next to the live counts so a tier that
# shrank is visible. They are reference values, not gates: the gate is >0.
declare -A BASELINE=([t1]=1 [t2]=1 [t3]=31 [t4]=3443 [t5]=20)
declare -A TIER_NAME=([t1]=engine [t2]=conformance [t3]=fe-fast [t4]=fe-full [t5]=db)

LOG_DIR="${VERIFY_CEL_LOG_DIR:-}"
if [ -z "${LOG_DIR}" ]; then
	LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-cel.XXXXXX")" || exit 1
fi
mkdir -p "${LOG_DIR}" || exit 1

PG_CONTAINER=""
cleanup() {
	if [ -n "${PG_CONTAINER}" ]; then
		# By exact name, never by pattern: a pkill/pgrep pattern would match this
		# very shell's own command line.
		"${DOCKER_BIN}" stop --time 2 "${PG_CONTAINER}" >/dev/null 2>&1
		"${DOCKER_BIN}" rm -f "${PG_CONTAINER}" >/dev/null 2>&1
	fi
}
trap cleanup EXIT INT TERM

# now_ms — milliseconds since the epoch, without date +%s%N (GNU only) and
# without perl. EPOCHREALTIME is bash 5; the fallback is whole seconds.
now_ms() {
	if [ -n "${EPOCHREALTIME}" ]; then
		local t="${EPOCHREALTIME/,/.}"
		printf '%s%s\n' "${t%.*}" "$(printf '%.3s' "${t#*.}")"
	else
		printf '%s000\n' "$(date +%s)"
	fi
}

# count_of LOG NAME — the last "<N> NAME" pytest summary number, or 0.
count_of() {
	local n
	n="$(grep -oE "[0-9]+ $2" "$1" 2>/dev/null | tail -1 | grep -oE '^[0-9]+')"
	printf '%s\n' "${n:-0}"
}

# record TIER STATUS PASSED SKIPPED FAILED MS NOTE
record() {
	printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
		>"${LOG_DIR}/$1.result"
}

# go_tier TIER LABEL [extra go test args...] — run a go tier and grade it.
go_tier() {
	local tier="$1" start end rc passed skipped failed note="" status=PASS
	shift
	start="$(now_ms)"
	(cd "${ENGINE_DIR}" && "${GO_BIN}" test -count=1 -v "$@") \
		>"${LOG_DIR}/${tier}.log" 2>&1
	rc=$?
	end="$(now_ms)"
	passed="$(grep -c -- '--- PASS:' "${LOG_DIR}/${tier}.log")"
	skipped="$(grep -c -- '--- SKIP:' "${LOG_DIR}/${tier}.log")"
	failed="$(grep -c -- '--- FAIL:' "${LOG_DIR}/${tier}.log")"
	if [ "${rc}" -ne 0 ]; then
		status=FAIL
		note="go test exit ${rc}"
	fi
	if [ "${passed}" -eq 0 ]; then
		status=FAIL
		note="zero passing tests${note:+; }${note}"
	fi
	if grep -q 'no test files' "${LOG_DIR}/${tier}.log"; then
		status=FAIL
		note="package has no test files${note:+; }${note}"
	fi
	record "${tier}" "${status}" "${passed}" "${skipped}" "${failed}" \
		"$((end - start))" "${note}"
}

run_t1() { go_tier t1 ./...; }

run_t2() {
	go_tier t2 . -run "${T2_RUN}"
	# The fixture count is the thing that makes an empty policy/frameworks tree
	# visible: TestConformance_Verdicts runs one subtest per fixture, so the RUN
	# lines are a direct count of what was actually replayed through the engine.
	local fixtures line
	fixtures="$(grep -c '^=== RUN   TestConformance_Verdicts/' "${LOG_DIR}/t2.log")"
	line="$(cat "${LOG_DIR}/t2.result")"
	local IFS='|'
	read -r tier status passed skipped failed ms note <<<"${line}"
	if [ "${fixtures}" -eq 0 ]; then
		status=FAIL
		note="zero conformance fixtures scanned${note:+; }${note}"
	fi
	record "${tier}" "${status}" "${passed}" "${skipped}" "${failed}" "${ms}" \
		"${fixtures} fixtures${note:+; }${note}"
}

# fe_pytest FILES... — the repo's own uv invocation, plus the two flags that
# make xdist usable. `-o addopts=` drops pytest.ini's `-p no:xdist`.
fe_pytest() {
	cd "${FE_SRC}" || return 1
	UV_CONFIG_FILE=/dev/null UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}" \
		uv run --python 3.12 --with pytest --with pytest-asyncio \
		--with pytest-xdist --with respx --with-requirements requirements.txt \
		python -m pytest -q --disable-warnings -o addopts= -p no:cacheprovider \
		-rs "$@"
}

# pytest_tier TIER MAX_SKIPPED [pytest args...]
pytest_tier() {
	local tier="$1" max_skipped="$2" start end rc passed skipped failed
	local note="" status=PASS
	shift 2
	start="$(now_ms)"
	fe_pytest "$@" >"${LOG_DIR}/${tier}.log" 2>&1
	rc=$?
	end="$(now_ms)"
	passed="$(count_of "${LOG_DIR}/${tier}.log" passed)"
	skipped="$(count_of "${LOG_DIR}/${tier}.log" skipped)"
	failed="$(count_of "${LOG_DIR}/${tier}.log" failed)"
	if [ "${rc}" -eq 5 ]; then
		status=FAIL
		note="no tests ran (pytest exit 5)"
	elif [ "${rc}" -ne 0 ]; then
		status=FAIL
		note="pytest exit ${rc}"
	fi
	if [ "${passed}" -eq 0 ]; then
		status=FAIL
		note="zero passing tests${note:+; }${note}"
	fi
	if [ -n "${max_skipped}" ] && [ "${skipped}" -gt "${max_skipped}" ]; then
		status=FAIL
		note="${skipped} skipped, max ${max_skipped}${note:+; }${note}"
	fi
	record "${tier}" "${status}" "${passed}" "${skipped}" "${failed}" \
		"$((end - start))" "${note}"
}

run_t3() { pytest_tier t3 "" ${T3_FILES}; }

# t4 is two passes: everything at -n auto, then the wall-clock-sensitive file on
# its own with no workers at all.
#
# Two files in the suite genuinely cannot run under xdist. Both were found by
# running it, not by reading it, and both are measurement tests — they assert
# about resources rather than behaviour, so they need the process and the box to
# themselves:
#
#   tests/test_scenario_seeding.py — test_twenty_concurrent_customer_evaluations
#     spins up its own 20-way concurrency and asserts a per-evaluation latency
#     budget (`< 50.0` ms, line 385). With 24 xdist workers also on the box it
#     measured 199.3ms and 208.2ms. A CPU budget problem, not isolation.
#   tests/test_cadvisor_poller.py — line 283 calls gc.disable() and tracemalloc,
#     both process-global, then asserts net allocation across four polls stays
#     under one body (~2 MiB). Under worksteal the worker has already run other
#     tests, the baseline is not clean, and it reported "2.0 MiB still held" on
#     three consecutive runs. Order-sensitive, which is the likeliest reason
#     `-p no:xdist` was added to pytest.ini in ef8cea46 in the first place.
#
# Together they are 2.6s + 1.4s serially, so the second pass is cheap and the
# other ~3400 tests keep their parallelism. Nothing else is serialised, and no
# test is deselected: the two passes' counts sum to the serial suite's 3443/112.
run_t4() {
	local start end rc_par rc_ser pass_par pass_ser
	local passed skipped failed note="" status=PASS f ignore=()
	start="$(now_ms)"
	for f in ${T4_SERIAL}; do ignore+=("--ignore=${f}"); done
	fe_pytest -n auto --dist worksteal "${ignore[@]}" tests \
		>"${LOG_DIR}/t4.log" 2>&1
	rc_par=$?
	fe_pytest ${T4_SERIAL} >"${LOG_DIR}/t4-serial.log" 2>&1
	rc_ser=$?
	end="$(now_ms)"
	pass_par="$(count_of "${LOG_DIR}/t4.log" passed)"
	pass_ser="$(count_of "${LOG_DIR}/t4-serial.log" passed)"
	passed=$((pass_par + pass_ser))
	skipped=$(($(count_of "${LOG_DIR}/t4.log" skipped) +
		$(count_of "${LOG_DIR}/t4-serial.log" skipped)))
	failed=$(($(count_of "${LOG_DIR}/t4.log" failed) +
		$(count_of "${LOG_DIR}/t4-serial.log" failed)))
	# Both passes are graded, so a pass that collected nothing cannot be hidden
	# by the other pass's green.
	if [ "${rc_par}" -eq 5 ] || [ "${pass_par}" -eq 0 ]; then
		status=FAIL
		note="parallel pass ran no tests"
	elif [ "${rc_par}" -ne 0 ]; then
		status=FAIL
		note="parallel pass exit ${rc_par}"
	fi
	if [ "${rc_ser}" -eq 5 ] || [ "${pass_ser}" -eq 0 ]; then
		status=FAIL
		note="serial pass ran no tests${note:+; }${note}"
	elif [ "${rc_ser}" -ne 0 ]; then
		status=FAIL
		note="serial pass exit ${rc_ser}${note:+; }${note}"
	fi
	record t4 "${status}" "${passed}" "${skipped}" "${failed}" \
		"$((end - start))" "${note:-${pass_par} parallel + ${pass_ser} serial}"
}

run_t5() {
	local start end port i ready=0
	start="$(now_ms)"
	# Bash resets traps to default in a subshell, and every tier runs in one, so
	# the top-level trap would never fire for the container this tier starts.
	trap cleanup EXIT INT TERM
	{
		if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
			echo "FATAL: docker not found (VERIFY_CEL_DOCKER=${DOCKER_BIN})."
			echo "The db tier needs a real Postgres. It does not skip."
			return 1
		fi
		if ! "${DOCKER_BIN}" info >/dev/null 2>&1; then
			echo "FATAL: '${DOCKER_BIN} info' failed — no usable Docker daemon."
			return 1
		fi
		# ~/.docker is unreadable under the sandbox; give docker its own config.
		DOCKER_CONFIG="$(mktemp -d "${TMPDIR:-/tmp}/verify-cel-docker.XXXXXX")"
		export DOCKER_CONFIG
		PG_CONTAINER="verify-cel-pg-$$"
		if ! "${DOCKER_BIN}" run -d --rm --name "${PG_CONTAINER}" \
			-e POSTGRES_PASSWORD=pw -p 127.0.0.1:0:5432 "${PG_IMAGE}"; then
			echo "FATAL: could not start ${PG_IMAGE}."
			PG_CONTAINER=""
			return 1
		fi
		port="$("${DOCKER_BIN}" port "${PG_CONTAINER}" 5432 | head -1)"
		port="${port##*:}"
		if [ -z "${port}" ]; then
			echo "FATAL: could not read the mapped port for ${PG_CONTAINER}."
			return 1
		fi
		for ((i = 0; i < PG_TIMEOUT; i++)); do
			if "${DOCKER_BIN}" exec "${PG_CONTAINER}" \
				pg_isready -q -U postgres >/dev/null 2>&1; then
				ready=1
				break
			fi
			sleep 1
		done
		if [ "${ready}" -ne 1 ]; then
			echo "FATAL: Postgres not ready after ${PG_TIMEOUT}s."
			return 1
		fi
		echo "postgres ${PG_IMAGE} ready on 127.0.0.1:${port}"
		export DATABASE_URL="postgresql://postgres:pw@127.0.0.1:${port}/postgres"
		# Zero skips allowed: without DATABASE_URL these tests skip, and a
		# skipped integration tier reading green is the failure mode this gate
		# exists for. pytest_tier writes the result file.
		pytest_tier t5 0 ${T5_FILES}
	} >"${LOG_DIR}/t5.setup.log" 2>&1
	local rc=$?
	end="$(now_ms)"
	if [ "${rc}" -ne 0 ] && [ ! -f "${LOG_DIR}/t5.result" ]; then
		record t5 FAIL 0 0 0 "$((end - start))" \
			"environment unusable — see t5.setup.log"
	fi
	cat "${LOG_DIR}/t5.setup.log" >>"${LOG_DIR}/t5.log" 2>/dev/null
}

# --- tier selection -----------------------------------------------------------

declare -a SELECTED=()
add_tier() {
	local t
	for t in "${SELECTED[@]}"; do [ "${t}" = "$1" ] && return 0; done
	SELECTED+=("$1")
}
if [ "$#" -eq 0 ]; then
	set -- all
fi
for arg in "$@"; do
	case "${arg}" in
	all) add_tier t1; add_tier t2; add_tier t3; add_tier t4; add_tier t5 ;;
	t1 | engine) add_tier t1 ;;
	t2 | conformance) add_tier t2 ;;
	t3 | fe-fast) add_tier t3 ;;
	t4 | fe-full) add_tier t4 ;;
	fe) add_tier t3; add_tier t4 ;;
	t5 | db) add_tier t5 ;;
	-h | --help)
		sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "verify-cel: unknown tier '${arg}'" >&2
		echo "tiers: engine conformance fe-fast fe-full fe db all" >&2
		exit 2
		;;
	esac
done

# Scheduling. One wave by default: all five tiers at once is 40s wall clock and
# was green on two consecutive runs once the two measurement files moved to t4's
# serial pass. Before that split, co-scheduling was red on three runs out of
# five (test_scenario_seeding.py:385, then test_cadvisor_poller.py:283), so the
# split is what makes the single wave safe rather than merely fast.
#
# VERIFY_CEL_ISOLATE_T4=1 puts t4 in a second wave on its own: 68s, for a box
# that is busy with something other than this runner. It is the same tiers and
# the same gates either way.
declare -a WAVE1=() WAVE2=()
for tier in "${SELECTED[@]}"; do
	if [ "${tier}" = t4 ] && [ "${#SELECTED[@]}" -gt 1 ] &&
		[ "${VERIFY_CEL_ISOLATE_T4:-0}" = 1 ]; then
		WAVE2+=("${tier}")
	else
		WAVE1+=("${tier}")
	fi
done

echo "verify-cel: tiers ${SELECTED[*]} — logs in ${LOG_DIR}"
RUN_START="$(now_ms)"
for tier in ${WAVE1[@]+"${WAVE1[@]}"}; do
	"run_${tier}" &
done
wait
for tier in ${WAVE2[@]+"${WAVE2[@]}"}; do
	"run_${tier}" &
done
wait
RUN_END="$(now_ms)"

# --- aggregation --------------------------------------------------------------

exit_code=0
printf '\n%-4s %-12s %-6s %8s %8s %8s %9s  %s\n' \
	TIER NAME RESULT PASSED SKIPPED FAILED SECONDS NOTES
printf '%s\n' "------------------------------------------------------------------------------"
for tier in "${SELECTED[@]}"; do
	if [ ! -f "${LOG_DIR}/${tier}.result" ]; then
		printf '%-4s %-12s %-6s %8s %8s %8s %9s  %s\n' \
			"${tier}" "${TIER_NAME[${tier}]}" FAIL - - - - \
			"tier produced no result — see ${tier}.log"
		exit_code=1
		continue
	fi
	IFS='|' read -r t status passed skipped failed ms note \
		<"${LOG_DIR}/${tier}.result"
	printf '%-4s %-12s %-6s %8s %8s %8s %6s.%03d  %s\n' \
		"${t}" "${TIER_NAME[${t}]}" "${status}" "${passed}" "${skipped}" \
		"${failed}" "$((ms / 1000))" "$((ms % 1000))" \
		"${note:-baseline ${BASELINE[${t}]}}"
	[ "${status}" = PASS ] || exit_code=1
done
printf '%s\n' "------------------------------------------------------------------------------"
printf 'wall clock %s.%03ds for %s tier(s)\n' \
	"$(((RUN_END - RUN_START) / 1000))" "$(((RUN_END - RUN_START) % 1000))" \
	"${#SELECTED[@]}"
if [ "${exit_code}" -eq 0 ]; then
	echo "verify-cel: PASS"
else
	echo "verify-cel: FAIL — logs in ${LOG_DIR}"
fi
exit "${exit_code}"
