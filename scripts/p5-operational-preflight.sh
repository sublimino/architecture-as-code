#!/usr/bin/env bash
# ==============================================================================
# SLDC-P5-PRE operational rollout preflight (read-only).
#
# Audits the six Appendix F.4 rollout gates (PF-1..PF-6) of the SLDC proposal,
# plus four auxiliary readiness checks P5-1/P5-2 depend on, and emits one
# machine-readable JSON report. Every gate has a static half (what the repo on
# this checkout says) and, where the gate is about runtime state, a live half
# (what kind-osramp is actually running).
#
# It never writes to the cluster, OpenBao, SPIRE, or any tracked file other
# than the --out path. Live probes are get/list/auth can-i, API-server pod
# proxy GETs, and read-only `bao read` / `spire-server entry show` execs.
#
# Injectable boundaries (tests set these):
#   P5_REPO              repository root to inspect        (default: git toplevel)
#   KUBECTL              kubectl binary                    (default: kubectl)
#   P5_CONTEXT           kube context                      (default: kind-osramp)
#   P5_AGENT_NAMESPACE   namespace of the swarm/sentinel   (default: fe-signalloom-agents)
#   P5_BAO_NAMESPACE     namespace of openbao              (default: inf-bao)
#   P5_BAO_TOKEN         bao token; default read from the openbao-supercred-bootstrap Job env
#   P5_SPIRE_SERVERS     space-separated ns:target:container SPIRE servers to query
#   P5_FORENSIC_DIR      forensic staging dir              (default: /tmp/sldc-forensics)
#   P5_FORENSIC_MIN_KB   minimum free space                (default: 2097152 = 2 GiB)
#   P5_SKIP_CLUSTER=1    skip every live probe; live halves report "skipped"
#
# Usage:
#   p5-operational-preflight.sh [--gate ID]... [--out FILE] [--quiet]
#     ID is PF-1..PF-6 or AUX-RBAC, AUX-ACT, AUX-FORENSIC, AUX-KEYS.
#     Default: every gate and auxiliary check.
#
# Exit: 0 every selected check passed, 1 at least one FAILED, 2 usage error.
# Each failure prints "<ID> FAILED: <reason>" on stderr.
# ==============================================================================
set -o pipefail

REPO="${P5_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
KUBECTL="${KUBECTL:-kubectl}"
CTX="${P5_CONTEXT:-kind-osramp}"
NS="${P5_AGENT_NAMESPACE:-fe-signalloom-agents}"
BAO_NS="${P5_BAO_NAMESPACE:-inf-bao}"
SPIRE_SERVERS="${P5_SPIRE_SERVERS:-spire-system:statefulset/spire-server:spire-server inf-bao:deploy/spire-server:spire-server}"
FORENSIC_DIR="${P5_FORENSIC_DIR:-/tmp/sldc-forensics}"
FORENSIC_MIN_KB="${P5_FORENSIC_MIN_KB:-2097152}"
SKIP_CLUSTER="${P5_SKIP_CLUSTER:-0}"

SWARM_TARGETS=(agent-cardvault agent-sir-lancelot agent-nono-evidenced)
STUNNED_KEY="signalloom.io/stunned"
BAO_ROLE="signalloom-cardvault-agent"
RUNNER_SA="system:serviceaccount:fe-signalloom:supercred-demo-runner"

F_BAO_BOOTSTRAP="d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
F_VAP="d2-agent-trust/policies/agent-identity-state-protection.yaml"
F_LEGACY_RECONCILER="d2-signalloom/apps/signalloom-stun-sentinel/main.go"
F_EXCLUSION="d2-signalloom/apps/stun-sentinel/pkg/filter/exclusion.go"
F_CORRELATOR="d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go"
F_SENTINEL_HTTP="d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go"
F_F4_RECONCILER="d2-signalloom/apps/stun-sentinel/reconciler.go"
F_ACCEPTANCE="test/swarm-fleet-acceptance.bats"
F_KUSARI="d2-signalloom/apps/kusari-agent/main.go"

usage() { sed -n '2,/^# =====.*$/p' "$0" | sed -n '/^# Usage:/,/^# Each/p' >&2; exit 2; }

GATES=()
OUT=""
QUIET=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--gate) [[ -n "${2:-}" ]] || usage; GATES+=("$2"); shift 2 ;;
	--out) [[ -n "${2:-}" ]] || usage; OUT="$2"; shift 2 ;;
	--quiet) QUIET=1; shift ;;
	-h | --help) usage ;;
	*) echo "p5-operational-preflight: unknown option: $1" >&2; exit 2 ;;
	esac
done
ALL=(PF-1 PF-2 PF-3 PF-4 PF-5 PF-6 AUX-RBAC AUX-ACT AUX-FORENSIC AUX-KEYS)
[[ ${#GATES[@]} -gt 0 ]] || GATES=("${ALL[@]}")
for g in "${GATES[@]}"; do
	[[ " ${ALL[*]} " == *" $g "* ]] || { echo "p5-operational-preflight: unknown gate: $g" >&2; exit 2; }
done

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT
FAILED=()

k() { "$KUBECTL" --context "$CTX" --request-timeout=15s "$@"; }
live() { [[ "$SKIP_CLUSTER" != "1" ]]; }
repo_file() { [[ -f "$REPO/$1" ]]; }

# record ID NAME STATUS SUMMARY STATIC_JSON LIVE_JSON
record() {
	jq -nc --arg id "$1" --arg name "$2" --arg status "$3" --arg summary "$4" \
		--argjson static "$5" --argjson live "$6" \
		'{id:$id, name:$name, status:$status, summary:$summary, static:$static, live:$live}' >>"$RESULTS"
	if [[ "$3" == "fail" ]]; then
		FAILED+=("$1")
		echo "$1 FAILED: $4" >&2
	elif [[ "$QUIET" != "1" ]]; then
		echo "$1 ${3^^}: $4" >&2
	fi
}

SKIPPED='{"status":"skipped","reason":"P5_SKIP_CLUSTER=1"}'
NONE='{"status":"n/a"}'

# ---------------------------------------------------------------- PF-1
gate_pf1() {
	local live_json="$SKIPPED" status=pass summary rows=() n obj kind ann lbl tann
	if live; then
		for n in "${SWARM_TARGETS[@]}"; do
			kind=Deployment
			obj="$(k -n "$NS" get deploy "$n" -o json 2>/dev/null)" || obj=""
			if [[ -z "$obj" ]]; then
				kind=Pod
				obj="$(k -n "$NS" get pod "$n" -o json 2>/dev/null)" || obj=""
			fi
			if [[ -z "$obj" ]]; then
				rows+=("$(jq -nc --arg n "$n" '{target:$n, found:false, annotated:false}')")
				status=fail
				continue
			fi
			ann="$(jq -r --arg k "$STUNNED_KEY" '.metadata.annotations[$k] // ""' <<<"$obj")"
			tann="$(jq -r --arg k "$STUNNED_KEY" '.spec.template.metadata.annotations[$k] // ""' <<<"$obj")"
			lbl="$(jq -r --arg k "$STUNNED_KEY" '(.spec.template.metadata.labels // .metadata.labels // {})[$k] // ""' <<<"$obj")"
			[[ "$ann" == "true" ]] || status=fail
			rows+=("$(jq -nc --arg n "$n" --arg kind "$kind" --arg a "$ann" --arg t "$tann" --arg l "$lbl" \
				'{target:$n, found:true, kind:$kind, annotated:($a=="true"), annotation:$a, template_annotation:$t, pod_label:$l}')")
		done
		live_json="$(printf '%s\n' "${rows[@]}" | jq -sc '{status:"probed", targets:.}')"
		summary="$(jq -r '[.targets[] | select(.annotated|not) | .target + (if .found then "" else " (not found)" end)] | if length==0 then "all swarm targets annotated signalloom.io/stunned=true" else "not annotated signalloom.io/stunned=true: " + join(", ") end' <<<"$live_json")"
	else
		status=skip
		summary="runtime-only gate; live probe skipped"
	fi
	record PF-1 "Swarm pod annotation" "$status" "$summary" "$NONE" "$live_json"
}

# ---------------------------------------------------------------- PF-2
gate_pf2() {
	local status=pass reasons=() static_json live_json="$SKIPPED" hits job srv ns tgt ctr out rows=()
	hits="$(git -C "$REPO" grep -lE 'name:[[:space:]]*spire-register-entries' -- '*.yaml' '*.yml' 2>/dev/null | tr '\n' ' ')"
	static_json="$(jq -nc --arg h "${hits% }" '{job_manifests: ($h | if .=="" then [] else split(" ") end)}')"
	[[ -n "${hits// /}" ]] || { status=fail; reasons+=("no spire-register-entries Job manifest in repo"); }
	if live; then
		job="$(k get jobs -A -o json 2>/dev/null | jq -c '[.items[]? | select(.metadata.name=="spire-register-entries") | {namespace:.metadata.namespace, succeeded:(.status.succeeded // 0)}]')" || job="[]"
		[[ "$(jq 'map(select(.succeeded>0))|length' <<<"${job:-[]}")" -gt 0 ]] || { status=fail; reasons+=("job/spire-register-entries absent or not succeeded in cluster"); }
		for srv in $SPIRE_SERVERS; do
			IFS=: read -r ns tgt ctr <<<"$srv"
			out="$(k -n "$ns" exec "$tgt" -c "$ctr" -- /opt/spire/bin/spire-server entry show 2>/dev/null)" || out=""
			rows+=("$(jq -nc --arg s "$srv" --arg o "$out" '
				($o | split("\n") | map(select(test("^SPIFFE ID")))) as $ids |
				{server:$s, reachable:($o!=""), entries:($ids|length),
				 stun_sentinel:($ids|map(select(test("/sa/stun-sentinel$")))|length),
				 fleet_manager:($ids|map(select(test("/sa/fleet-manager$")))|length),
				 legacy_signalloom_stun_sentinel:($ids|map(select(test("signalloom-stun-sentinel")))|length)}')")
		done
		live_json="$(printf '%s\n' "${rows[@]}" | jq -sc --argjson job "${job:-[]}" '{status:"probed", job:$job, spire_servers:.}')"
		[[ "$(jq '[.spire_servers[].stun_sentinel]|add' <<<"$live_json")" -gt 0 ]] || { status=fail; reasons+=("no SPIRE entry for sa/stun-sentinel"); }
		[[ "$(jq '[.spire_servers[].fleet_manager]|add' <<<"$live_json")" -gt 0 ]] || { status=fail; reasons+=("no SPIRE entry for sa/fleet-manager"); }
		local legacy; legacy="$(jq '[.spire_servers[].legacy_signalloom_stun_sentinel]|add' <<<"$live_json")"
		[[ "$legacy" -eq 0 ]] || reasons+=("$legacy legacy signalloom-stun-sentinel SPIRE entries still registered")
	fi
	local summary="stun-sentinel and fleet-manager SPIRE entries registered by spire-register-entries"
	[[ ${#reasons[@]} -eq 0 ]] || summary="$(IFS=';'; echo "${reasons[*]}" | sed 's/;/; /g')"
	record PF-2 "SPIRE registration job" "$status" "$summary" "$static_json" "$live_json"
}

# ---------------------------------------------------------------- PF-3
bao_role_static() {
	# The role JSON is a heredoc between `bao write auth/jwt/role/<role> - <<'ROLE'` and `ROLE`.
	awk -v r="role/$BAO_ROLE" 'index($0, r) && /<<.ROLE/ {f=1; next} f && /^[[:space:]]*ROLE[[:space:]]*$/ {exit} f' \
		"$REPO/$F_BAO_BOOTSTRAP" 2>/dev/null | jq -r '.bound_claims_type // "absent"' 2>/dev/null || echo "unparseable"
}
gate_pf3() {
	local st lv="skipped" live_json="$SKIPPED" status=pass tok
	if repo_file "$F_BAO_BOOTSTRAP"; then st="$(bao_role_static)"; else st="missing-file"; fi
	[[ -n "$st" ]] || st="role-not-found"
	[[ "$st" == "glob" ]] || status=fail
	if live; then
		tok="${P5_BAO_TOKEN:-$(k -n "$BAO_NS" get job openbao-supercred-bootstrap -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BAO_TOKEN")].value}' 2>/dev/null)}"
		# Token travels on stdin, never argv.
		lv="$(printf '%s\n' "$tok" | k -n "$BAO_NS" exec -i deploy/openbao -c openbao -- \
			sh -c 'read -r T; BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$T" bao read -format=json auth/jwt/role/'"$BAO_ROLE" 2>/dev/null |
			jq -r '.data.bound_claims_type // "absent"' 2>/dev/null)" || lv=""
		[[ -n "$lv" ]] || lv="unreadable"
		live_json="$(jq -nc --arg v "$lv" '{status:"probed", bound_claims_type:$v}')"
		[[ "$lv" == "glob" ]] || status=fail
	fi
	local summary="OpenBao role $BAO_ROLE bound_claims_type=glob (static=$st live=$lv)"
	[[ "$status" == pass ]] || summary="OpenBao bound_claims_type is not glob (static=$st live=$lv)"
	record PF-3 "OpenBao JWT glob setting" "$status" "$summary" \
		"$(jq -nc --arg f "$F_BAO_BOOTSTRAP" --arg v "$st" '{file:$f, role:"'"$BAO_ROLE"'", bound_claims_type:$v}')" "$live_json"
}

# ---------------------------------------------------------------- PF-4
gate_pf4() {
	local st=false lv="skipped" live_json="$SKIPPED" status=pass expr
	if repo_file "$F_VAP"; then
		expr="$(awk '/name:[[:space:]]*isGovernorOrAdmin/ {f=1; next} f && /-[[:space:]]*name:/ {exit} f' "$REPO/$F_VAP")"
		[[ "$expr" == *"'$RUNNER_SA'"* ]] && st=true
	fi
	[[ "$st" == true ]] || status=fail
	if live; then
		expr="$(k get validatingadmissionpolicy sl-agent-identity-state-protection -o json 2>/dev/null |
			jq -r '.spec.variables[]? | select(.name=="isGovernorOrAdmin") | .expression')" || expr=""
		if [[ -z "$expr" ]]; then lv="absent"; elif [[ "$expr" == *"'$RUNNER_SA'"* ]]; then lv=true; else lv=false; fi
		live_json="$(jq -nc --arg v "$lv" '{status:"probed", runner_whitelisted:$v}')"
		[[ "$lv" == true ]] || status=fail
	fi
	local summary="supercred-demo-runner in isGovernorOrAdmin (static=$st live=$lv)"
	[[ "$status" == pass ]] || summary="supercred-demo-runner not whitelisted in isGovernorOrAdmin (static=$st live=$lv)"
	record PF-4 "CEL admission whitelist" "$status" "$summary" \
		"$(jq -nc --arg f "$F_VAP" --argjson v "$st" '{file:$f, runner_whitelisted:$v}')" "$live_json"
}

# ---------------------------------------------------------------- PF-5
func_body() { # file, awk regex of the func line: prints the body up to the closing brace at column 0
	awk -v re="$2" '$0 ~ re {f=1} f {print} f && /^}/ {exit}' "$REPO/$1" 2>/dev/null
}
gate_pf5() {
	local status=pass reasons=() legacy excl corr http f4 live_json="$SKIPPED"
	f4=false; repo_file "$F_F4_RECONCILER" && f4=true
	legacy="$(func_body "$F_LEGACY_RECONCILER" '^func \\(r \\*stunReconciler\\) reconcile\\(')"
	if [[ -z "$legacy" ]]; then legacy=absent
	elif grep -q 'corev1.PodRunning' <<<"$legacy"; then legacy=gated
	else legacy=ungated; status=fail; reasons+=("legacy reconciler ($F_LEGACY_RECONCILER) freezes stunned pods in any phase but Succeeded/Failed")
	fi
	excl="$(func_body "$F_EXCLUSION" '^func \\(f \\*Filter\\) CheckFreezable\\(')"
	if grep -q 'Status.Phase != corev1.PodRunning' <<<"$excl"; then excl=gated; else excl=ungated; status=fail; reasons+=("CheckFreezable has no PodRunning check"); fi
	corr=ungated
	if repo_file "$F_CORRELATOR"; then
		local c fz
		c="$(grep -n 'CheckFreezable(' "$REPO/$F_CORRELATOR" | head -1 | cut -d: -f1)"
		fz="$(grep -n '\.FreezePod(string(pod.UID)' "$REPO/$F_CORRELATOR" | head -1 | cut -d: -f1)"
		[[ -n "$c" && -n "$fz" && "$c" -lt "$fz" ]] && corr=gated
	fi
	[[ "$corr" == gated ]] || { status=fail; reasons+=("eBPF correlator freeze not preceded by CheckFreezable"); }
	http="$(func_body "$F_SENTINEL_HTTP" '^func \\(s \\*server\\) exclusionGate\\(')"
	if grep -q 'if phase != "" {' <<<"$http"; then http=optional
	elif grep -q 'CheckFreezable' <<<"$http"; then http=gated
	else http=ungated; fi
	[[ "$http" == gated ]] || { status=fail; reasons+=("HTTP /stun gate skips the phase check when the caller omits phase ($http)"); }
	[[ "$f4" == true ]] || reasons+=("F.4 target $F_F4_RECONCILER does not exist")
	if live; then
		local logs img
		img="$(k -n "$NS" get ds stun-sentinel -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
		logs="$(k -n "$NS" logs ds/stun-sentinel --tail=2000 2>/dev/null)" || logs=""
		live_json="$(jq -nc --arg img "$img" \
			--argjson legacy_events "$(grep -cE '"event":"(unstun|stun)"' <<<"$logs")" \
			'{status:"probed", daemonset_image:$img, legacy_reconciler_stun_unstun_events:$legacy_events,
			  running_build:(if $legacy_events>0 then "signalloom-stun-sentinel reconciler" else "unknown" end)}')"
	fi
	local summary="every freeze path waits for status.phase == Running"
	[[ ${#reasons[@]} -eq 0 ]] || summary="$(IFS=';'; echo "${reasons[*]}" | sed 's/;/; /g')"
	record PF-5 "Owner-record phase gating" "$status" "$summary" \
		"$(jq -nc --arg l "$legacy" --arg e "$excl" --arg c "$corr" --arg h "$http" --argjson f4 "$f4" \
			'{f4_named_file_exists:$f4, legacy_reconciler:$l, check_freezable:$e, ebpf_correlator_path:$c, http_stun_path:$h}')" "$live_json"
}

# ---------------------------------------------------------------- PF-6
gate_pf6() {
	local status=pass new=0 old=0 live_json="$SKIPPED" ds=skipped
	if repo_file "$F_ACCEPTANCE"; then
		new="$(grep -cE 'daemonset[[:space:]]+stun-sentinel\b' "$REPO/$F_ACCEPTANCE")"
		old="$(grep -c 'signalloom-stun-sentinel' "$REPO/$F_ACCEPTANCE")"
	fi
	[[ "$new" -gt 0 && "$old" -eq 0 ]] || status=fail
	if live; then
		k -n "$NS" get ds stun-sentinel -o name >/dev/null 2>&1 && ds=present || ds=absent
		live_json="$(jq -nc --arg d "$ds" '{status:"probed", daemonset_stun_sentinel:$d}')"
		[[ "$ds" == present ]] || status=fail
	fi
	local summary="$F_ACCEPTANCE asserts DaemonSet stun-sentinel (live ds=$ds)"
	[[ "$status" == pass ]] || summary="$F_ACCEPTANCE asserts stun-sentinel $new times and legacy signalloom-stun-sentinel $old times (live ds=$ds)"
	record PF-6 "Acceptance test DaemonSet name" "$status" "$summary" \
		"$(jq -nc --arg f "$F_ACCEPTANCE" --argjson n "$new" --argjson o "$old" '{file:$f, stun_sentinel_refs:$n, legacy_refs:$o}')" "$live_json"
}

# ---------------------------------------------------------------- auxiliary
aux_rbac() {
	local v="skipped" status=skip
	if live; then
		v="$(k auth can-i list pods --all-namespaces --as="system:serviceaccount:$NS:stun-sentinel" 2>/dev/null)" || true
		[[ "$v" == yes ]] && status=pass || status=fail
	fi
	record AUX-RBAC "Sentinel pod informer RBAC" "$status" "stun-sentinel SA can list pods cluster-wide: ${v:-no}" "$NONE" \
		"$(jq -nc --arg v "${v:-no}" '{can_list_pods:$v}')"
}

aux_act() {
	local status=pass reasons=() routes=() r src_json live_json="$SKIPPED" pod hz act
	for r in /act/healthz /act/read-passwd /act/cpu-burn; do
		if repo_file "$F_KUSARI" && grep -q "\"$r\"" "$REPO/$F_KUSARI"; then routes+=("$r")
		else status=fail; reasons+=("$r not registered in $F_KUSARI"); fi
	done
	src_json="$(printf '%s\n' "${routes[@]}" | jq -Rsc '{registered_act_routes: (split("\n")|map(select(.!="")))}')"
	if live; then
		pod="$(k -n "$NS" get pods -o json 2>/dev/null | jq -r '[.items[]? | select(.metadata.name|startswith("agent-kusari-")) | select(.status.phase=="Running") | .metadata.name][0] // ""')"
		if [[ -n "$pod" ]]; then
			# API-server pod proxy: the distroless stub has no shell or curl to exec.
			hz="$(k get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/healthz" 2>/dev/null)" || hz=""
			act="$(k get --raw "/api/v1/namespaces/$NS/pods/$pod:8080/proxy/act/healthz" 2>&1)" || act="error: ${act##*: }"
			[[ "$act" == *'"status":"ready"'* ]] || { status=fail; reasons+=("live /act/healthz did not return {\"status\":\"ready\"}"); }
		else
			status=fail; reasons+=("no Running agent-kusari pod")
		fi
		live_json="$(jq -nc --arg p "$pod" --arg h "$hz" --arg a "$act" '{status:"probed", pod:$p, healthz:$h, act_healthz:$a}')"
	fi
	local summary="Kusari stub serves /act/healthz, /act/read-passwd, /act/cpu-burn"
	[[ ${#reasons[@]} -eq 0 ]] || summary="$(IFS=';'; echo "${reasons[*]}" | sed 's/;/; /g')"
	record AUX-ACT "Kusari stub /act API" "$status" "$summary" "$src_json" "$live_json"
}

aux_forensic() {
	local status=pass w=false free=0
	if mkdir -p "$FORENSIC_DIR" 2>/dev/null && touch "$FORENSIC_DIR/.p5-probe" 2>/dev/null && rm -f "$FORENSIC_DIR/.p5-probe"; then w=true; fi
	free="$(df -Pk "$FORENSIC_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
	[[ "$w" == true && "${free:-0}" -ge "$FORENSIC_MIN_KB" ]] || status=fail
	record AUX-FORENSIC "Forensic staging directory" "$status" "$FORENSIC_DIR writable=$w free_kb=${free:-0} (min $FORENSIC_MIN_KB)" \
		"$(jq -nc --arg d "$FORENSIC_DIR" --argjson w "$w" --argjson f "${free:-0}" '{dir:$d, writable:$w, free_kb:$f}')" "$NONE"
}

aux_keys() {
	local status=pass rows=() f ok
	for f in cosign.pub witness-pub.pem orbit-approval-pub.pem; do
		ok=false; openssl pkey -pubin -in "$REPO/.keys/$f" -noout 2>/dev/null && ok=true
		[[ "$ok" == true ]] || status=fail
		rows+=("$(jq -nc --arg f "$f" --argjson ok "$ok" '{file:$f, parses:$ok}')")
	done
	ok=false; head -1 "$REPO/.keys/cosign.key" 2>/dev/null | grep -q 'BEGIN ENCRYPTED SIGSTORE PRIVATE KEY' && ok=true
	[[ "$ok" == true ]] || status=fail
	rows+=("$(jq -nc --argjson ok "$ok" '{file:"cosign.key", encrypted_sigstore_header:$ok}')")
	record AUX-KEYS "Signing keys in .keys/" "$status" "public keys parse and cosign.key is an encrypted Sigstore key: $status" \
		"$(printf '%s\n' "${rows[@]}" | jq -sc '{keys:.}')" "$NONE"
}

for g in "${GATES[@]}"; do
	case "$g" in
	PF-1) gate_pf1 ;; PF-2) gate_pf2 ;; PF-3) gate_pf3 ;; PF-4) gate_pf4 ;; PF-5) gate_pf5 ;; PF-6) gate_pf6 ;;
	AUX-RBAC) aux_rbac ;; AUX-ACT) aux_act ;; AUX-FORENSIC) aux_forensic ;; AUX-KEYS) aux_keys ;;
	esac
done

report="$(jq -s --arg ctx "$CTX" --arg head "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unresolved)" \
	--arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg skip "$SKIP_CLUSTER" '{
	schema: "sldc-p5-preflight/v1",
	card: "SLDC-P5-PRE",
	generated_at: $at,
	repo_head: $head,
	context: $ctx,
	cluster_probed: ($skip != "1"),
	gates: map(select(.id|startswith("PF-"))),
	auxiliary: map(select(.id|startswith("AUX-"))),
	verdict: {
		pass: (map(select(.status=="fail"))|length == 0),
		failed: [.[] | select(.status=="fail") | .id],
		proceed_p5: (map(select(.status=="fail"))|length == 0)
	}
}' "$RESULTS")"

if [[ -n "$OUT" ]]; then
	mkdir -p "$(dirname "$OUT")"
	printf '%s\n' "$report" >"$OUT"
else
	printf '%s\n' "$report"
fi

[[ ${#FAILED[@]} -eq 0 ]]
