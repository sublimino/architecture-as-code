#!/usr/bin/env bash
# ==============================================================================
# SLDC-P4-PRE kubelet cAdvisor proxy preflight audit (read-only).
#
# Proves the API-server node proxy serves the kubelet's embedded cAdvisor
# metrics, validates the Prometheus exposition schema the P4-1 poller will
# parse, audits the fe-signalloom ServiceAccount's RBAC for the scrape, and
# measures how often cAdvisor actually refreshes its CPU counters.
#
# It never writes to the cluster or to any tracked file other than the --out /
# --sample-out paths it is given. It is an audit oracle, not the P4-1 poller.
#
# Injectable boundaries (tests set these):
#   KUBECTL              kubectl binary                    (default: kubectl)
#   P4_CONTEXT           kube context                      (default: kind-osramp)
#   P4_NODE              node name; empty = first node     (default: resolved)
#   P4_SA_NAMESPACE      fe-signalloom SA namespace        (default: fe-signalloom)
#   P4_SA_NAME           fe-signalloom SA name             (default: fe-signalloom)
#   P4_REPO              repository root for route checks  (default: git toplevel)
#   P4_CADENCE_SAMPLES   cadence scrapes                   (default: 11)
#   P4_CADENCE_INTERVAL  seconds between cadence scrapes   (default: 1)
#   P4_RATE_WINDOW       rate window under test, seconds   (default: 2)
#
# Usage:
#   p4-cadvisor-preflight.sh node                    resolved node name
#   p4-cadvisor-preflight.sh scrape [--out FILE]     raw scrape (exit 4 on proxy failure)
#   p4-cadvisor-preflight.sh headers                 JSON content-type probe
#   p4-cadvisor-preflight.sh schema FILE             JSON schema report (exit 3 on violation)
#   p4-cadvisor-preflight.sh rbac                    JSON can-i report for the SA
#   p4-cadvisor-preflight.sh cadence                 JSON counter refresh-interval report
#   p4-cadvisor-preflight.sh routes                  JSON /agents route registration
#   p4-cadvisor-preflight.sh audit [--out FILE] [--sample-out FILE]
# ==============================================================================
set -eo pipefail

KUBECTL="${KUBECTL:-kubectl}"
CONTEXT="${P4_CONTEXT:-kind-osramp}"
SA_NS="${P4_SA_NAMESPACE:-fe-signalloom}"
SA_NAME="${P4_SA_NAME:-fe-signalloom}"
REPO="${P4_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SAMPLES="${P4_CADENCE_SAMPLES:-11}"
INTERVAL="${P4_CADENCE_INTERVAL:-1}"
RATE_WINDOW="${P4_RATE_WINDOW:-2}"

# The series the P4-1 poller consumes, with the Prometheus type each must carry.
REQUIRED_METRICS=(
	"container_cpu_usage_seconds_total:counter"
	"container_memory_rss:gauge"
	"container_cpu_cfs_throttled_periods_total:counter"
)
REQUIRED_LABELS=(pod namespace container image id)

die() { echo "p4-cadvisor-preflight: $*" >&2; exit 2; }
kc() { "$KUBECTL" --context "$CONTEXT" "$@"; }

resolve_node() {
	if [[ -n "${P4_NODE:-}" ]]; then
		printf '%s\n' "$P4_NODE"
		return
	fi
	local n
	n="$(kc get nodes -o jsonpath='{.items[0].metadata.name}')" || die "cannot list nodes on $CONTEXT"
	[[ -n "$n" ]] || die "no nodes on $CONTEXT"
	printf '%s\n' "$n"
}

proxy_path() { printf '/api/v1/nodes/%s/proxy/metrics/cadvisor' "$1"; }

cmd_scrape() {
	local out="" node
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--out) out="$2"; shift 2 ;;
		*) die "scrape: unknown option $1" ;;
		esac
	done
	node="$(resolve_node)"
	if [[ -n "$out" ]]; then
		kc get --raw "$(proxy_path "$node")" >"$out" || { echo "proxy scrape failed for node $node" >&2; return 4; }
	else
		kc get --raw "$(proxy_path "$node")" || { echo "proxy scrape failed for node $node" >&2; return 4; }
	fi
}

cmd_headers() {
	local node ct
	node="$(resolve_node)"
	# -v=8 logs response headers on stderr; the body is discarded.
	ct="$(kc get --raw "$(proxy_path "$node")" -v=8 2>&1 >/dev/null |
		sed -n 's/^.*Content-Type: *//p' | head -n1 | tr -d '\r')"
	jq -n --arg ct "$ct" '{
		content_type: $ct,
		exposition_0_0_4: ($ct | test("^text/plain; *version=0\\.0\\.4"))
	}'
}

# schema FILE: one JSON object; exit 3 if any required metric, type or label is missing.
cmd_schema() {
	local file="$1" ok=true entries="[]" m name type samples declared labels missing legacy
	[[ -f "$file" ]] || die "schema: no such file $file"
	for m in "${REQUIRED_METRICS[@]}"; do
		name="${m%%:*}" type="${m##*:}"
		declared="$(sed -n "s/^# TYPE $name \\([a-z]*\\)\$/\\1/p" "$file" | head -n1)"
		samples="$(grep -c "^$name{" "$file" || true)"
		labels="$(grep -m1 "^$name{" "$file" | sed -E 's/^[^{]*\{//; s/\}.*$//' |
			grep -oE '(^|,)[a-z_]+=' | tr -d ',=' | sort -u | paste -sd, - || true)"
		missing=""
		for l in "${REQUIRED_LABELS[@]}"; do
			[[ ",$labels," == *",$l,"* ]] || missing="${missing:+$missing,}$l"
		done
		legacy=false
		[[ ",$labels," == *",pod_name,"* || ",$labels," == *",container_name,"* ]] && legacy=true
		if [[ "$declared" != "$type" || "$samples" -eq 0 || -n "$missing" ]]; then ok=false; fi
		entries="$(jq -c --arg n "$name" --arg want "$type" --arg got "$declared" \
			--argjson s "$samples" --arg labels "$labels" --arg missing "$missing" --argjson legacy "$legacy" \
			'. + [{metric:$n, expected_type:$want, declared_type:$got, samples:$s,
			      labels:($labels|split(",")|map(select(.!=""))),
			      missing_labels:($missing|split(",")|map(select(.!=""))),
			      legacy_label_names:$legacy}]' <<<"$entries")"
	done
	jq -n --argjson e "$entries" --argjson ok "$ok" \
		--argjson bytes "$(wc -c <"$file")" --argjson lines "$(wc -l <"$file")" \
		--arg sha "$(sha256sum "$file" | cut -d' ' -f1)" \
		'{ok:$ok, bytes:$bytes, lines:$lines, sha256:$sha, metrics:$e}'
	[[ "$ok" == true ]] || exit 3
}

cmd_rbac() {
	local subject="system:serviceaccount:$SA_NS:$SA_NAME" r res="{}" sa_exists=false
	kc -n "$SA_NS" get sa "$SA_NAME" >/dev/null 2>&1 && sa_exists=true
	for r in nodes/proxy nodes/metrics; do
		# can-i exits 1 on "no"; the answer is on stdout either way.
		local ans
		ans="$(kc auth can-i get "$r" --as="$subject" 2>/dev/null || true)"
		res="$(jq -c --arg r "$r" --arg a "${ans:-no}" '. + {($r): ($a == "yes")}' <<<"$res")"
	done
	jq -n --arg s "$subject" --argjson e "$sa_exists" --argjson can "$res" \
		'{subject:$s, service_account_exists:$e, can_get:$can,
		  apiserver_proxy_ready:$can["nodes/proxy"], kubelet_direct_ready:$can["nodes/metrics"]}'
}

# cadence: scrape SAMPLES times, key every container_cpu_usage_seconds_total
# series of a real container (not the pod cgroup aggregate, not the pause
# sandbox) by its label set, and measure the gaps between distinct cAdvisor
# sample timestamps. The trailing millisecond timestamp is cAdvisor's own
# collection time, so it is the ground truth for refresh cadence.
cmd_cadence() {
	local node i tmp
	node="$(resolve_node)"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	for ((i = 0; i < SAMPLES; i++)); do
		kc get --raw "$(proxy_path "$node")" |
			grep '^container_cpu_usage_seconds_total{' |
			grep -v 'container=""' | grep -v 'container="POD"' |
			sed -E 's/^[^{]*(\{.*\}) [^ ]+ ([0-9]+)$/\1 \2/' >>"$tmp" || true
		((i + 1 < SAMPLES)) && sleep "$INTERVAL"
	done
	awk -v window="$RATE_WINDOW" -v samples="$SAMPLES" -v every="$INTERVAL" '
		NF >= 2 { ts = $NF; $NF = ""; key = $0; if (!((key, ts) in seen)) { seen[key, ts] = 1; list[key] = list[key] " " ts; n[key]++ } }
		END {
			series = 0; single = 0; k = 0
			for (key in list) {
				series++
				if (n[key] < 2) { single++; continue }
				c = split(list[key], a, " "); m = 0
				for (i = 1; i <= c; i++) if (a[i] != "") b[++m] = a[i] + 0
				for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (b[j] < b[i]) { t = b[i]; b[i] = b[j]; b[j] = t }
				for (i = 2; i <= m; i++) iv[++k] = (b[i] - b[i - 1]) / 1000
				delete b
			}
			for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) if (iv[j] < iv[i]) { t = iv[i]; iv[i] = iv[j]; iv[j] = t }
			p50 = (k ? iv[int(0.5 * (k - 1)) + 1] : -1); p90 = (k ? iv[int(0.9 * (k - 1)) + 1] : -1)
			min = (k ? iv[1] : -1); max = (k ? iv[k] : -1)
			printf "{\"samples\":%d,\"interval_s\":%s,\"series\":%d,\"series_without_refresh\":%d,\"intervals\":%d,", samples, every, series, single, k
			printf "\"refresh_s\":{\"min\":%.2f,\"p50\":%.2f,\"p90\":%.2f,\"max\":%.2f},", min, p50, p90, max
			viable = (k > 0 && p50 <= window) ? "true" : "false"
			printf "\"rate_window_s\":%s,\"rate_window_viable\":%s}\n", window, viable
		}' "$tmp"
}

cmd_routes() {
	local app="$REPO/d2-signalloom/apps/dashboard-signalloom/src/App.tsx" hit=""
	[[ -f "$app" ]] && hit="$(grep -nE 'path="/agents"' "$app" | head -n1 || true)"
	jq -n --arg f "d2-signalloom/apps/dashboard-signalloom/src/App.tsx" --arg hit "$hit" \
		'{file:$f, agents_route_registered:($hit != ""), line:$hit}'
}

cmd_audit() {
	local out="" sample_out="" node raw headers schema rbac cadence routes proxy_ok=true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--out) out="$2"; shift 2 ;;
		--sample-out) sample_out="$2"; shift 2 ;;
		*) die "audit: unknown option $1" ;;
		esac
	done
	node="$(resolve_node)"
	raw="$(mktemp)"
	trap 'rm -f "$raw"' EXIT
	P4_NODE="$node" cmd_scrape --out "$raw" || proxy_ok=false
	headers="$(P4_NODE="$node" cmd_headers)"
	schema="$( (cmd_schema "$raw") || true)"
	rbac="$(cmd_rbac)"
	cadence="$(P4_NODE="$node" cmd_cadence)"
	routes="$(cmd_routes)"
	if [[ -n "$sample_out" ]]; then
		# The full scrape is >10 MB; commit the type declarations plus every
		# series of the three required metrics for the agent namespace only.
		{
			grep -E '^# (HELP|TYPE) (container_cpu_usage_seconds_total|container_memory_rss|container_cpu_cfs_throttled_periods_total) ' "$raw" || true
			grep -E '^(container_cpu_usage_seconds_total|container_memory_rss|container_cpu_cfs_throttled_periods_total)\{' "$raw" |
				grep 'namespace="fe-signalloom-agents"' || true
		} >"$sample_out"
	fi
	local report
	report="$(jq -n --arg ctx "$CONTEXT" --arg node "$node" --arg path "$(proxy_path "$node")" \
		--argjson proxy_ok "$proxy_ok" --argjson h "$headers" --argjson s "${schema:-null}" \
		--argjson r "$rbac" --argjson c "$cadence" --argjson ro "$routes" '{
			card: "SLDC-P4-PRE", context: $ctx, node: $node, proxy_path: $path,
			proxy_reachable: $proxy_ok, headers: $h, schema: $s, rbac: $r,
			cadence: $c, routes: $ro,
			gates: {
				proxy_reachable: $proxy_ok,
				exposition_format: $h.exposition_0_0_4,
				schema: ($s.ok // false),
				sa_rbac_apiserver_proxy: $r.apiserver_proxy_ready,
				rate_window_viable: $c.rate_window_viable,
				agents_route: $ro.agents_route_registered
			}
		}')"
	if [[ -n "$out" ]]; then printf '%s\n' "$report" >"$out"; else printf '%s\n' "$report"; fi
	# Hard blockers only: an unreachable proxy or a broken schema stops Phase 4.
	[[ "$proxy_ok" == true ]] || exit 4
	[[ "$(jq -r '.gates.schema' <<<"$report")" == true ]] || exit 3
}

main() {
	local sub="${1:-}"
	[[ -n "$sub" ]] || die "usage: $0 {node|scrape|headers|schema|rbac|cadence|routes|audit}"
	shift
	case "$sub" in
	node) resolve_node ;;
	scrape) cmd_scrape "$@" ;;
	headers) cmd_headers ;;
	schema) [[ $# -eq 1 ]] || die "schema FILE"; cmd_schema "$1" ;;
	rbac) cmd_rbac ;;
	cadence) cmd_cadence ;;
	routes) cmd_routes ;;
	audit) cmd_audit "$@" ;;
	*) die "unknown subcommand $sub" ;;
	esac
}

main "$@"
