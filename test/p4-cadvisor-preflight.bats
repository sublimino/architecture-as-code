#!/usr/bin/env bats
#
# SLDC-P4-PRE: the cAdvisor preflight oracle must prove the kubelet proxy
# scrape is reachable, reject a scrape whose schema the P4-1 poller cannot
# parse, report the fe-signalloom SA's RBAC honestly, and measure counter
# refresh cadence from cAdvisor's own sample timestamps.
#
# Tier 1 (default): no cluster; a fake kubectl serves fixture scrapes.
# Tier 2 (P4_LIVE=1): the card's required tests against kind-osramp.

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/p4-cadvisor-preflight.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	unset P4_NODE P4_SA_NAMESPACE P4_SA_NAME P4_REPO
	export P4_CADENCE_INTERVAL=0 P4_CADENCE_SAMPLES=5
}

write_fixture() {
	# $1 = variant: good | legacy-labels | wrong-type | no-throttle
	fixture="$BATS_TEST_TMPDIR/scrape.prom"
	local podlbl=pod rsstype=gauge
	[[ "$1" == legacy-labels ]] && podlbl=pod_name
	[[ "$1" == wrong-type ]] && rsstype=counter
	{
		echo '# HELP container_cpu_usage_seconds_total Cumulative cpu time consumed in seconds.'
		echo '# TYPE container_cpu_usage_seconds_total counter'
		echo "container_cpu_usage_seconds_total{container=\"\",cpu=\"total\",id=\"/pod1\",image=\"\",name=\"\",namespace=\"fe-signalloom-agents\",$podlbl=\"agent-kusari-1\"} 9.2 TS"
		echo "container_cpu_usage_seconds_total{container=\"POD\",cpu=\"total\",id=\"/pod1/pause\",image=\"pause:3.10\",name=\"p\",namespace=\"fe-signalloom-agents\",$podlbl=\"agent-kusari-1\"} 0.01 TS"
		echo "container_cpu_usage_seconds_total{container=\"agent\",cpu=\"total\",id=\"/pod1/c1\",image=\"kusari-agent:latest\",name=\"c1\",namespace=\"fe-signalloom-agents\",$podlbl=\"agent-kusari-1\"} 9.1 TS"
		echo "container_cpu_usage_seconds_total{container=\"api\",cpu=\"total\",id=\"/pod2/c2\",image=\"fe:1\",name=\"c2\",namespace=\"fe-signalloom\",$podlbl=\"fe-signalloom-1\"} 40.5 TS"
		echo '# HELP container_memory_rss Size of RSS in bytes.'
		echo "# TYPE container_memory_rss $rsstype"
		echo "container_memory_rss{container=\"agent\",id=\"/pod1/c1\",image=\"kusari-agent:latest\",name=\"c1\",namespace=\"fe-signalloom-agents\",$podlbl=\"agent-kusari-1\"} 1.2e+07 TS"
		if [[ "$1" != no-throttle ]]; then
			echo '# HELP container_cpu_cfs_throttled_periods_total Number of throttled period intervals.'
			echo '# TYPE container_cpu_cfs_throttled_periods_total counter'
			echo "container_cpu_cfs_throttled_periods_total{container=\"agent\",id=\"/pod1/c1\",image=\"kusari-agent:latest\",name=\"c1\",namespace=\"fe-signalloom-agents\",$podlbl=\"agent-kusari-1\"} 3 TS"
		fi
	} >"$fixture"
}

# The fake advances cAdvisor's sample timestamp by FAKE_TS_STEP_MS per scrape,
# answers can-i from FAKE_CANI, and fails the proxy when FAKE_PROXY_FAIL=1.
fake_kubectl() {
	cat >"$bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
args=" $* "
count_file="$BATS_TEST_TMPDIR/scrapes"
if [[ "$args" == *" get nodes "* ]]; then echo "${FAKE_NODE:-fake-control-plane}"; exit 0; fi
if [[ "$args" == *" auth can-i "* ]]; then echo "${FAKE_CANI:-no}"; [[ "${FAKE_CANI:-no}" == yes ]]; exit $?; fi
if [[ "$args" == *" get sa "* ]]; then exit 0; fi
if [[ "$args" == *" get --raw "* ]]; then
	if [[ "${FAKE_PROXY_FAIL:-0}" == 1 || "$args" == *nonexistent* ]]; then
		echo 'Error from server (NotFound): nodes "x" not found' >&2; exit 1
	fi
	if [[ "$args" == *" -v=8 "* ]]; then
		echo "I0930 round_trippers.go:632]     Content-Type: ${FAKE_CT:-text/plain; version=0.0.4; charset=utf-8}" >&2
	fi
	n=$(cat "$count_file" 2>/dev/null || echo 0); echo $((n + 1)) >"$count_file"
	ts=$((1790754000000 + n * ${FAKE_TS_STEP_MS:-15000}))
	sed "s/ TS\$/ $ts/" "$FAKE_FIXTURE"
	exit 0
fi
echo "fake kubectl: unhandled: $*" >&2; exit 99
FAKE
	chmod +x "$bin/kubectl"
	export KUBECTL="$bin/kubectl" FAKE_FIXTURE="$fixture"
}

@test "schema accepts a scrape carrying all three metrics with correct types and labels" {
	write_fixture good
	run "$script" schema "$fixture"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.ok' <<<"$output")" = true ]
	[ "$(jq -r '[.metrics[].declared_type]|join(",")' <<<"$output")" = "counter,gauge,counter" ]
	[ "$(jq -r '[.metrics[].missing_labels[]]|length' <<<"$output")" = 0 ]
}

@test "schema fails closed (exit 3) and flags legacy pod_name labels" {
	write_fixture legacy-labels
	run "$script" schema "$fixture"
	[ "$status" -eq 3 ]
	[ "$(jq -r '.metrics[0].missing_labels|join(",")' <<<"$output")" = "pod" ]
	[ "$(jq -r '.metrics[0].legacy_label_names' <<<"$output")" = true ]
}

@test "schema fails closed (exit 3) when container_memory_rss is not a gauge" {
	write_fixture wrong-type
	run "$script" schema "$fixture"
	[ "$status" -eq 3 ]
	[ "$(jq -r '.metrics[1].declared_type' <<<"$output")" = counter ]
}

@test "schema fails closed (exit 3) when the throttling counter is absent" {
	write_fixture no-throttle
	run "$script" schema "$fixture"
	[ "$status" -eq 3 ]
	[ "$(jq -r '.metrics[2].samples' <<<"$output")" = 0 ]
}

@test "node resolves dynamically from the cluster when P4_NODE is unset" {
	write_fixture good; fake_kubectl
	export FAKE_NODE=kind-osramp-control-plane; run "$script" node
	[ "$status" -eq 0 ]
	[ "$output" = kind-osramp-control-plane ]
}

@test "scrape exits 4 when the node proxy refuses" {
	write_fixture good; fake_kubectl
	export FAKE_PROXY_FAIL=1; run "$script" scrape
	[ "$status" -eq 4 ]
	[[ "$output" == *"proxy scrape failed"* ]]
}

@test "headers recognises exposition format 0.0.4 and rejects anything else" {
	write_fixture good; fake_kubectl
	run "$script" headers
	[ "$(jq -r '.exposition_0_0_4' <<<"$output")" = true ]
	export FAKE_CT='application/json'; run "$script" headers
	[ "$(jq -r '.exposition_0_0_4' <<<"$output")" = false ]
}

@test "rbac reports the fe-signalloom SA subject and a denied nodes/proxy honestly" {
	write_fixture good; fake_kubectl
	export FAKE_CANI=no; run "$script" rbac
	[ "$status" -eq 0 ]
	[ "$(jq -r '.subject' <<<"$output")" = "system:serviceaccount:fe-signalloom:fe-signalloom" ]
	[ "$(jq -r '.apiserver_proxy_ready' <<<"$output")" = false ]
	export FAKE_CANI=yes; run "$script" rbac
	[ "$(jq -r '.apiserver_proxy_ready' <<<"$output")" = true ]
}

@test "cadence rejects a 2s rate window when cAdvisor refreshes every 15s" {
	write_fixture good; fake_kubectl
	export FAKE_TS_STEP_MS=15000; run "$script" cadence
	[ "$status" -eq 0 ]
	jq -e '.refresh_s.p50 == 15' <<<"$output"
	[ "$(jq -r '.rate_window_viable' <<<"$output")" = false ]
}

@test "cadence accepts a 2s rate window when cAdvisor refreshes every second" {
	write_fixture good; fake_kubectl
	export FAKE_TS_STEP_MS=1000; run "$script" cadence
	jq -e '.refresh_s.p50 == 1' <<<"$output"
	[ "$(jq -r '.rate_window_viable' <<<"$output")" = true ]
}

@test "cadence counts real containers only, not the pod aggregate or pause sandbox" {
	write_fixture good; fake_kubectl
	run "$script" cadence
	[ "$(jq -r '.series' <<<"$output")" = 2 ]
	[ "$(jq -r '.intervals' <<<"$output")" = 8 ]
}

@test "routes finds /agents in the dashboard and fails on a repo without it" {
	run "$script" routes
	[ "$(jq -r '.agents_route_registered' <<<"$output")" = true ]
	mkdir -p "$BATS_TEST_TMPDIR/repo/d2-signalloom/apps/dashboard-signalloom/src"
	echo '<Route path="/weave" />' >"$BATS_TEST_TMPDIR/repo/d2-signalloom/apps/dashboard-signalloom/src/App.tsx"
	P4_REPO="$BATS_TEST_TMPDIR/repo" run "$script" routes
	[ "$(jq -r '.agents_route_registered' <<<"$output")" = false ]
}

@test "audit writes the report and an agent-namespace-only sample" {
	write_fixture good; fake_kubectl
	run "$script" audit --out "$BATS_TEST_TMPDIR/a.json" --sample-out "$BATS_TEST_TMPDIR/s.prom"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.gates.schema' "$BATS_TEST_TMPDIR/a.json")" = true ]
	[ "$(jq -r '.gates.rate_window_viable' "$BATS_TEST_TMPDIR/a.json")" = false ]
	grep -q 'namespace="fe-signalloom-agents"' "$BATS_TEST_TMPDIR/s.prom"
	! grep -q 'namespace="fe-signalloom"[,}]' "$BATS_TEST_TMPDIR/s.prom"
}

@test "audit exits 4 and still reports when the proxy is unreachable" {
	write_fixture good; fake_kubectl
	export FAKE_PROXY_FAIL=1; run "$script" audit --out "$BATS_TEST_TMPDIR/a.json"
	[ "$status" -eq 4 ]
	[ "$(jq -r '.proxy_reachable' "$BATS_TEST_TMPDIR/a.json")" = false ]
}

# ── Tier 2: live kind-osramp (P4_LIVE=1) ──────────────────────────────────────

live() { [[ "${P4_LIVE:-0}" == 1 ]] || skip "set P4_LIVE=1 to run against kind-osramp"; }

@test "live: kubelet cAdvisor proxy serves cpu usage and working-set series" {
	live
	# The card said `| head -n 30 | grep`, which can never match: cAdvisor sorts
	# families alphabetically and these first appear near lines 3265 and 12910.
	run bash -c 'kubectl --context kind-osramp get --raw "/api/v1/nodes/osramp-control-plane/proxy/metrics/cadvisor" | grep -E "^(container_cpu_usage_seconds_total|container_memory_working_set_bytes)\{" | cut -d"{" -f1 | sort -u'
	[ "$status" -eq 0 ]
	[ "$(wc -l <<<"$output")" -eq 2 ]
}

@test "live: agent-kusari series carry pod and namespace labels" {
	live
	run bash -c "kubectl --context kind-osramp get --raw /api/v1/nodes/osramp-control-plane/proxy/metrics/cadvisor | grep 'pod=\"agent-kusari' | head -n 1"
	[ "$status" -eq 0 ]
	[[ "$output" == *'namespace="fe-signalloom-agents"'* ]]
}

@test "live: a nonexistent node is a 404, proving the probe hits the real proxy" {
	live
	run kubectl --context kind-osramp get --raw /api/v1/nodes/nonexistent-node/proxy/metrics/cadvisor
	[ "$status" -ne 0 ]
	[[ "$output" == *NotFound* ]]
}

@test "live: full audit passes the hard gates on kind-osramp" {
	live
	unset KUBECTL
	P4_CADENCE_SAMPLES=3 run "$script" audit --out "$BATS_TEST_TMPDIR/live.json"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.gates.proxy_reachable and .gates.exposition_format and .gates.schema' "$BATS_TEST_TMPDIR/live.json")" = true ]
	[ "$(jq -r '.rbac.service_account_exists' "$BATS_TEST_TMPDIR/live.json")" = true ]
}
