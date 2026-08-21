#!/usr/bin/env bats
# node-doctor.bats — drives the REAL adjudicators in scripts/node-doctor/lib.sh
# against recorded probe output.
#
# ═══ WHY THIS SUITE CAN EXIST AT ALL ════════════════════════════════════════
#
# The node doctor is split into a collector that runs on the VM (probe.sh) and
# adjudicators that run here (lib.sh) and are pure functions of the collected
# text. That split is the whole reason these states are testable: an unlinked
# zot blob store, a MagicDNS name that drifted to sl-demo-1-1, a demo VM wearing
# the reaper's label and a truncated SSH transfer cannot be produced on demand
# against a live estate, and every one of them is a fixture here.
#
# ═══ THE HOUSE RULE THIS SUITE IS BUILT AROUND ══════════════════════════════
#
# Every guard gets a POSITIVE CONTROL: a paired case proving the check can
# actually SEE the thing it asserts. A test that only ever feeds an adjudicator
# good input proves nothing — it passes identically against a function that
# returns PASS unconditionally, which is exactly the regression a future
# "simplification" produces.
#
# So the pairs below are deliberate and must stay paired:
#
#   ... accepts <good>          and  ... rejects <bad>
#   ... is PASS when readable   and  ... is UNKNOWN when unreadable
#
# and assert_field_present() guards the third failure mode, which is subtler
# than either: a test that reads a key the fixture does not contain feeds the
# adjudicator an EMPTY string, gets UNKNOWN back, and asserts UNKNOWN — a green
# test measuring nothing at all. Every test that pulls a field asserts the field
# is there first.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  LIB="${REPO_ROOT}/scripts/node-doctor/lib.sh"
  PROBE="${REPO_ROOT}/scripts/node-doctor/probe.sh"
  ENTRY="${REPO_ROOT}/scripts/node-doctor.sh"
  DEMO="${REPO_ROOT}/scripts/node-doctor/demo.sh"
  CI="${REPO_ROOT}/scripts/node-doctor/ci.sh"
  # Sourcing must be side-effect free beyond defining functions. If this line
  # ever starts reaching for gcloud or kubectl, every test below becomes an
  # integration test and this suite stops being runnable offline.
  # shellcheck disable=SC1090
  . "$LIB"
}

# A probe report from a healthy demo lane. The values are REAL — recorded off
# sl-demo-1-vm on 2026-08-21 — so the fixture cannot drift into a shape the
# probe never emits.
healthy_report() {
  cat <<'REPORT'
probe.schema=signalloom.node-doctor.probe/v1
probe.host=sl-demo-1-vm
probe.app_port=30754
ts.backend=Running
ts.online=true
ts.dnsname=sl-demo-1.taild4da3.ts.net.
ts.ip=100.110.9.0
ts.serve.hostport=sl-demo-1.taild4da3.ts.net:443
ts.serve.proxy=http://127.0.0.1:30754
ts.serve.https=true
ts.serve.unit_enabled=enabled
ts.serve.unit_active=active
http.root=200
http.afm_health=200
docker.server=29.7.2
docker.driver=overlayfs
docker.images=15
docker.running=7
kind.node_status=Up 36 minutes
kind.crictl_images=43
disk.vm_root_pct=18
disk.vm_root_avail=79
disk.vm_root_dev=/dev/root
disk.node_root_pct=18
disk.node_var_dev=/dev/root
k8s.reachable=yes
k8s.nodes_total=1
k8s.nodes_ready=1
k8s.kustomizations_total=15
k8s.kustomizations_notready=0
k8s.kustomizations_bad_names=UNKNOWN
k8s.pods_bad=0
k8s.pods_bad_names=UNKNOWN
zot.pod_status=Running
zot.pod_ready=1/1
zot.cache_host_inode=527104
zot.cache_node_inode=527104
zot.cache_host_path=/opt/signalloom/zot-cache
zot.cache_host_links=3
zot.log_bytes=191156
zot.log_defect_hits=0
zot.v2_code=200
zot.push_session=opened
zot.push_code=201
zot.push_head=200
zot.push_delete=202
afm.cronjob_schedule=*/30 * * * *
afm.cronjob_last=2026-08-21T19:30:00Z
afm.deploy_ready=1
afm.health_code=200
afm.cluster_count=1
afm.cluster_ids=local
probe.complete=1
REPORT
}

# The guard against the quietest failure in this file: a test that reads a key
# the fixture does not have gets an empty string, the adjudicator returns
# UNKNOWN, and an `[ "$v" = UNKNOWN ]` assertion goes green having measured
# nothing. Asserting the key is PRESENT first is what makes the subsequent
# assertion about the adjudicator rather than about the fixture.
assert_field_present() {
  local report="$1" key="$2" value
  value="$(nd_field "$report" "$key")"
  if [ -z "$value" ]; then
    echo "FIXTURE ERROR: key '${key}' is absent from the report, so this test is" >&2
    echo "               feeding the adjudicator an empty string and measuring nothing." >&2
    return 1
  fi
}

# ═══ WHY THERE IS NO BARE `! grep` ANYWHERE IN THIS FILE ════════════════════
#
# Because there was, and the mutation proof caught it.
#
# bats runs each test under errexit, and bash EXEMPTS a `!`-negated command from
# errexit. So `! grep -q forbidden "$file"` fails silently unless it happens to
# be the test's LAST statement: the grep matches, the negation returns 1, and
# execution carries straight on to the next line. Four tests here were written
# that way and every one of their negative assertions was dead code — including
# the one asserting the demo doctor does not adjudicate the CI lane's contract,
# which is why mutation M9 reported NOT PROVEN on the first run of the harness.
#
# refute_match() is a FUNCTION returning 1. A failing function call that is not
# itself negated does trip errexit, so it fails the test from any position.
refute_match() {
  local file="$1" pattern="$2" desc="${3:-}"
  # The positive control for the refutation itself: a file that could not be
  # read matches nothing, so "no match" would be indistinguishable from "no
  # file". Assert there is something to search before concluding it is absent.
  if [ ! -s "$file" ]; then
    echo "GUARD ERROR: ${file} is missing or empty, so 'no match' means nothing" >&2
    return 1
  fi
  if code_only "$file" | grep -qE -- "$pattern"; then
    echo "REFUTATION FAILED: ${file} matches forbidden pattern '${pattern}'" >&2
    [ -n "$desc" ] && echo "                   ${desc}" >&2
    code_only "$file" | grep -nE -- "$pattern" | head -5 >&2
    return 1
  fi
  return 0
}

# Replaces one key's value in a report. Refuses to no-op: a sed that matches
# nothing rewrites nothing while reporting success, and a mutation-style test
# built on one ships as "the check caught it" against unmutated input.
with_field() {
  local report="$1" key="$2" value="$3" out
  out="$(printf '%s\n' "$report" | sed "s|^${key}=.*|${key}=${value}|")"
  if [ "$out" = "$report" ]; then
    echo "FIXTURE ERROR: setting ${key}=${value} changed nothing — the key is absent" >&2
    return 1
  fi
  printf '%s' "$out"
}

# ════════════════════════════════════════════════════════════════════════════
# TRUNCATION — the positive control for the whole report
# ════════════════════════════════════════════════════════════════════════════

@test "TRUNCATION a complete report is recognised as complete" {
  # The positive control for the two tests below. Without it, a broken
  # nd_report_complete that always returns false would make them both pass.
  run nd_report_complete "$(healthy_report)"
  [ "$status" -eq 0 ]
}

@test "TRUNCATION a report missing its completion marker is NOT complete" {
  local truncated
  truncated="$(healthy_report | grep -v '^probe.complete=')"
  # The fixture must actually have lost the line, or this measures nothing.
  ! printf '%s' "$truncated" | grep -q '^probe.complete='
  run nd_report_complete "$truncated"
  [ "$status" -ne 0 ]
}

@test "TRUNCATION a truncated report's absent keys are empty, not silently healthy" {
  # The reason the marker exists. Cut the report off before the zot section and
  # every zot key reads as absent — which, adjudicated naively, is exactly what
  # a healthy quiet registry looks like.
  local cut
  cut="$(healthy_report | sed -n '1,20p')"
  [ -z "$(nd_field "$cut" zot.log_defect_hits)" ]
  [ "$(nd_verdict_zot_log "$(nd_field "$cut" zot.log_bytes)" "$(nd_field "$cut" zot.log_defect_hits)")" = "UNKNOWN" ]
}

@test "TRUNCATION the entry point refuses to adjudicate an incomplete report" {
  # A grep guard, so it needs to be shown it can see the file at all — an
  # anchor that IS present, asserted alongside the thing under test.
  grep -q 'nd_report_complete' "$ENTRY"
  grep -q 'the VM-side probe did not complete' "$ENTRY"
}

# ════════════════════════════════════════════════════════════════════════════
# ZOT — the blob store defect, which every other signal reports as healthy
# ════════════════════════════════════════════════════════════════════════════

@test "ZOT a healthy blob store passes on all four detectors" {
  local r; r="$(healthy_report)"
  assert_field_present "$r" zot.cache_host_inode
  assert_field_present "$r" zot.log_bytes
  assert_field_present "$r" zot.push_code
  [ "$(nd_verdict_zot_inode "$(nd_field "$r" zot.cache_host_inode)" "$(nd_field "$r" zot.cache_node_inode)")" = "PASS" ]
  [ "$(nd_verdict_zot_cache_links "$(nd_field "$r" zot.cache_host_links)")" = "PASS" ]
  [ "$(nd_verdict_zot_log "$(nd_field "$r" zot.log_bytes)" "$(nd_field "$r" zot.log_defect_hits)")" = "PASS" ]
  [ "$(nd_verdict_zot_push "$(nd_field "$r" zot.push_session)" "$(nd_field "$r" zot.push_code)" "$(nd_field "$r" zot.push_head)")" = "PASS" ]
}

@test "ZOT an unlinked blob store is caught by inode disagreement" {
  # THE defect. The host directory is unlinked and recreated, so the host has a
  # new inode while the kind node's bind mount still resolves to the old,
  # deleted one. Everything else in the report stays green.
  local r; r="$(with_field "$(healthy_report)" zot.cache_host_inode 998877)"
  [ "$(nd_verdict_zot_inode "$(nd_field "$r" zot.cache_host_inode)" "$(nd_field "$r" zot.cache_node_inode)")" = "FAIL" ]
  # And the point of the whole check: the pod is still Running 1/1 and /v2/
  # still answers 200 in the very same report.
  [ "$(nd_verdict_zot_pod "$(nd_field "$r" zot.pod_status)" "$(nd_field "$r" zot.pod_ready)")" = "PASS" ]
  [ "$(nd_field "$r" zot.v2_code)" = "200" ]
}

@test "ZOT a directory unlinked while still mounted is caught by its link count" {
  local r; r="$(with_field "$(healthy_report)" zot.cache_host_links 0)"
  [ "$(nd_verdict_zot_cache_links "$(nd_field "$r" zot.cache_host_links)")" = "FAIL" ]
}

@test "ZOT the readdirent error in the pod log is caught" {
  local r; r="$(with_field "$(healthy_report)" zot.log_defect_hits 4)"
  [ "$(nd_verdict_zot_log "$(nd_field "$r" zot.log_bytes)" "$(nd_field "$r" zot.log_defect_hits)")" = "FAIL" ]
}

@test "ZOT an UNREADABLE log is UNKNOWN, never a clean bill of health" {
  # The vacuous pass this repo exists to refuse, stated as a test.
  #
  # `grep -c readdirent` returns 0 for a healthy registry AND 0 for a log that
  # could not be read. Same number, opposite meanings. Only the byte count
  # separates them, which is why nd_verdict_zot_log takes both — and why this
  # test's fixture keeps hits at 0 while dropping bytes to 0.
  local r; r="$(with_field "$(healthy_report)" zot.log_bytes 0)"
  [ "$(nd_field "$r" zot.log_defect_hits)" = "0" ]
  [ "$(nd_verdict_zot_log "$(nd_field "$r" zot.log_bytes)" "$(nd_field "$r" zot.log_defect_hits)")" = "UNKNOWN" ]
  # Positive control: the SAME zero hit count with a readable log is a PASS, so
  # the function is discriminating on bytes and not merely always UNKNOWN.
  [ "$(nd_verdict_zot_log 191156 0)" = "PASS" ]
}

@test "ZOT a 500 on the blob PUT fails even though /v2/ answered 200" {
  # The defect's exact signature: a registry that serves and cannot store.
  local r; r="$(with_field "$(healthy_report)" zot.push_code 500)"
  [ "$(nd_field "$r" zot.v2_code)" = "200" ]
  [ "$(nd_verdict_zot_push "$(nd_field "$r" zot.push_session)" "$(nd_field "$r" zot.push_code)" "$(nd_field "$r" zot.push_head)")" = "FAIL" ]
}

@test "ZOT a 201 the registry cannot then serve back is NOT a successful push" {
  # Accepted is not stored. A store that reports success and holds nothing is
  # the defect's whole character, so the HEAD is load-bearing.
  [ "$(nd_verdict_zot_push opened 201 404)" = "FAIL" ]
  [ "$(nd_verdict_zot_push opened 201 200)" = "PASS" ]
}

@test "ZOT a skipped push is UNKNOWN and never inherits the /v2/ 200" {
  # ND_ZOT_PUSH=0 must not quietly turn into a pass on the strength of the
  # readonly probe, because that probe is precisely what the defect leaves
  # intact.
  [ "$(nd_verdict_zot_push SKIPPED SKIPPED SKIPPED)" = "SKIPPED" ]
  # SKIPPED is deliberately NOT one of the four verdicts, so the caller has to
  # handle it explicitly. Assert what happens if a future edit forgets to: it
  # reaches nd_report, which routes anything unrecognised to FAIL rather than
  # swallowing it. A silent pass is the only unacceptable outcome here.
  run bash -c ". '$LIB'; nd_report SKIPPED 'a thing'; nd_summary demo-1 demo"
  [ "$status" -ne 0 ]
  [[ "$output" != *"HEALTHY"* ]]
  [[ "$output" == *"unrecognised verdict"* ]]
  # And the caller does handle it — as an UNKNOWN, never as a pass.
  grep -q 'nd_unknown "blob push: SKIPPED' "$LIB"
}

@test "ZOT a pod that is Running with 0/1 ready is not healthy" {
  [ "$(nd_verdict_zot_pod Running 0/1)" = "FAIL" ]
  [ "$(nd_verdict_zot_pod Running 1/1)" = "PASS" ]
  [ "$(nd_verdict_zot_pod CrashLoopBackOff 0/1)" = "FAIL" ]
  [ "$(nd_verdict_zot_pod '' '')" = "UNKNOWN" ]
}

# ════════════════════════════════════════════════════════════════════════════
# AFM — "200 with 0 clusters" must be a FAIL
# ════════════════════════════════════════════════════════════════════════════

@test "AFM a lane with clusters imported passes" {
  local r; r="$(healthy_report)"
  assert_field_present "$r" afm.cluster_count
  [ "$(nd_verdict_cluster_count "$(nd_field "$r" afm.cluster_count)")" = "PASS" ]
}

@test "AFM zero clusters is a FAIL even when the health endpoint answers 200" {
  # The failure the CronJob's */30 schedule creates: for up to half an hour a
  # lane answers /afm/health 200 holding nothing, and everything downstream
  # reports success against empty pages.
  local r; r="$(with_field "$(healthy_report)" afm.cluster_count 0)"
  [ "$(nd_field "$r" http.afm_health)" = "200" ]
  [ "$(nd_field "$r" afm.health_code)" = "200" ]
  [ "$(nd_verdict_cluster_count "$(nd_field "$r" afm.cluster_count)")" = "FAIL" ]
}

@test "AFM a platform that is not deployed is distinguished from zero clusters" {
  # Different fix, so it must be a different reading. Reporting NOT_DEPLOYED as
  # 0 sends the reader to the CronJob to explain a missing Deployment.
  [ "$(nd_verdict_cluster_count NOT_DEPLOYED)" = "FAIL" ]
  grep -q 'This is not .zero clusters. — nothing has been asked' "$LIB"
}

@test "AFM an unmeasurable cluster count is UNKNOWN, not zero" {
  [ "$(nd_verdict_cluster_count UNKNOWN)" = "UNKNOWN" ]
  [ "$(nd_verdict_cluster_count '')" = "UNKNOWN" ]
  # Positive control: a real count is still a PASS, so it is not always UNKNOWN.
  [ "$(nd_verdict_cluster_count 3)" = "PASS" ]
}

# ════════════════════════════════════════════════════════════════════════════
# TSNAME — MagicDNS drift, which serves and resolves and is the wrong node
# ════════════════════════════════════════════════════════════════════════════

@test "TSNAME the correct MagicDNS name passes" {
  [ "$(nd_verdict_ts_name sl-demo-1 'sl-demo-1.taild4da3.ts.net.')" = "PASS" ]
}

@test "TSNAME a suffixed name is REJECTED, not accepted as a prefix match" {
  # Tailscale resolves a name collision by suffixing. sl-demo-1-1 resolves,
  # serves and answers 200 from a node that is not the one the URL implies, and
  # a prefix match would wave it through. This is why the check is an equality
  # test on the first label.
  [ "$(nd_verdict_ts_name sl-demo-1 'sl-demo-1-1.taild4da3.ts.net.')" = "FAIL" ]
  [ "$(nd_verdict_ts_name sl-ci-1   'sl-ci-11.taild4da3.ts.net.')"   = "FAIL" ]
}

@test "TSNAME an unreadable name is UNKNOWN, never a pass" {
  [ "$(nd_verdict_ts_name sl-demo-1 UNKNOWN)" = "UNKNOWN" ]
  [ "$(nd_verdict_ts_name sl-demo-1 '')" = "UNKNOWN" ]
}

@test "TSSERVE an absent serve config FAILS rather than reading as unmeasurable" {
  # `tailscale logout` wipes the serve config and leaves the node online and
  # correctly named. Reporting that as UNKNOWN would bury it among the
  # could-not-measures; it is a definite, actionable, common failure.
  [ "$(nd_verdict_ts_serve 30754 ABSENT)" = "FAIL" ]
  [ "$(nd_verdict_ts_serve 30754 UNKNOWN)" = "UNKNOWN" ]
  [ "$(nd_verdict_ts_serve 30754 'http://127.0.0.1:30754')" = "PASS" ]
}

@test "TSSERVE a serve config pointing at the WRONG port is caught" {
  # It serves, it resolves, and it 502s — which reads as a dead backend rather
  # than as a listener aimed somewhere else.
  [ "$(nd_verdict_ts_serve 30754 'http://127.0.0.1:8080')" = "FAIL" ]
}

@test "TSSERVE the boot unit must be enabled, not merely active" {
  # A oneshot that is `active` has run once. Only `enabled` survives a reboot,
  # and after that reboot every other tailscale line is still green while the
  # lane serves nothing.
  [ "$(nd_verdict_ts_serve_unit enabled)" = "PASS" ]
  [ "$(nd_verdict_ts_serve_unit disabled)" = "FAIL" ]
  [ "$(nd_verdict_ts_serve_unit static)" = "FAIL" ]
  [ "$(nd_verdict_ts_serve_unit 'enabled-runtime')" = "FAIL" ]
  [ "$(nd_verdict_ts_serve_unit UNKNOWN)" = "UNKNOWN" ]
}

# ════════════════════════════════════════════════════════════════════════════
# LANE — the two properties that actually differ between the kinds
# ════════════════════════════════════════════════════════════════════════════

@test "LANE a ci lane found SUSPENDED is a PASS, because that is the reaper working" {
  # Getting this backwards costs money AND time: the response to "the CI VM is
  # down" is to resume it, which restarts the billing the reaper just stopped,
  # while the doctor that caused it reports a fix.
  [ "$(nd_verdict_vm_status ci SUSPENDED)" = "PASS" ]
  [ "$(nd_verdict_vm_status ci RUNNING)" = "PASS" ]
}

@test "LANE a demo lane found SUSPENDED is a FAIL, because nothing should suspend it" {
  # Same word, opposite meaning, and the positive control for the test above:
  # without this pair, a nd_verdict_vm_status that returned PASS for SUSPENDED
  # unconditionally would look correct.
  [ "$(nd_verdict_vm_status demo SUSPENDED)" = "FAIL" ]
  [ "$(nd_verdict_vm_status demo RUNNING)" = "PASS" ]
}

@test "LANE an unreadable VM status is UNKNOWN and never NOT_FOUND" {
  # An expired credential once produced "VM not found — run provision first"
  # against a healthy VM, and acting on that rebuilds a standing estate.
  [ "$(nd_verdict_vm_status demo AUTH_REQUIRED)" = "UNKNOWN" ]
  [ "$(nd_verdict_vm_status demo QUERY_FAILED)" = "UNKNOWN" ]
  # A genuinely absent VM is still a FAIL, so the function is not merely
  # answering UNKNOWN to everything it does not recognise.
  [ "$(nd_verdict_vm_status demo NOT_FOUND)" = "FAIL" ]
}

@test "LANE the entry point classifies gcloud's three failure texts separately" {
  grep -q 'NOT_FOUND' "$ENTRY"
  grep -q 'AUTH_REQUIRED' "$ENTRY"
  grep -q 'QUERY_FAILED' "$ENTRY"
}

@test "LANE a demo VM wearing the reaper's ci-lane label is a FAIL" {
  # scripts/ci/gcp-tf-reaper.sh selects instances to SUSPEND on this label, so a
  # demo VM carrying it is one the reaper may switch off mid-presentation.
  [ "$(nd_verdict_demo_no_ci_label ABSENT)" = "PASS" ]
  [ "$(nd_verdict_demo_no_ci_label demo-1)" = "FAIL" ]
  [ "$(nd_verdict_demo_no_ci_label ci-1)" = "FAIL" ]
}

@test "LANE a ci lane WITHOUT the ci-lane label is a FAIL — it is unreapable" {
  # The reaper matching nothing is not an error to the reaper; it suspends
  # nothing and reports success, and the lane bills until somebody notices.
  [ "$(nd_verdict_ci_lane_label ci-1 ci-1)" = "PASS" ]
  [ "$(nd_verdict_ci_lane_label ci-1 ABSENT)" = "FAIL" ]
  # The value must equal the key, not merely exist. A lane labelled with another
  # lane's key fails the reaper's cross-check and is equally unreapable.
  [ "$(nd_verdict_ci_lane_label ci-1 ci-2)" = "FAIL" ]
}

@test "LANE the ci idle budget must clear COMPUTE-RULE-12's floor of 5" {
  # Below 5 the reaper suspends lanes mid-run; at 0 or absent it never suspends
  # them at all.
  [ "$(nd_verdict_ci_idle_budget 30)" = "PASS" ]
  [ "$(nd_verdict_ci_idle_budget 5)" = "PASS" ]
  [ "$(nd_verdict_ci_idle_budget 4)" = "FAIL" ]
  [ "$(nd_verdict_ci_idle_budget 0)" = "FAIL" ]
  [ "$(nd_verdict_ci_idle_budget ABSENT)" = "FAIL" ]
}

@test "LANE a demo lane publishing an idle-suspend budget is a FAIL" {
  # It would switch itself off while somebody is presenting on it.
  [ "$(nd_verdict_demo_no_idle_budget ABSENT)" = "PASS" ]
  [ "$(nd_verdict_demo_no_idle_budget 30)" = "FAIL" ]
}

@test "LANE the two doctors differ on EXACTLY the two properties that differ" {
  # Guards against the opposite failure to all of the above: inventing a
  # difference. terraform/environments/main.tf collapsed modules/ci-runner into
  # modules/compute precisely so a CI lane IS a demo lane apart from the reaper
  # label and the idle budget, and a doctor that asserted more would fail lanes
  # for not having properties the estate never gave them.
  #
  # Both files must call the shared block, so neither can quietly grow its own
  # copy of the node checks.
  grep -q 'nd_checks_shared' "$DEMO"
  grep -q 'nd_checks_shared' "$CI"
  # And each must adjudicate the two properties, from its own side.
  grep -q 'nd_verdict_demo_no_ci_label'    "$DEMO"
  grep -q 'nd_verdict_demo_no_idle_budget' "$DEMO"
  grep -q 'nd_verdict_ci_lane_label'       "$CI"
  grep -q 'nd_verdict_ci_idle_budget'      "$CI"
  # Neither may adjudicate the OTHER kind's contract — that is how a demo lane
  # ends up being failed for lacking a reaper label it must not have.
  refute_match "$DEMO" 'nd_verdict_ci_lane_label' \
    "the demo doctor is demanding the CI lane's reaper label — a correctly configured demo lane would fail"
  refute_match "$CI" 'nd_verdict_demo_no_ci_label' \
    "the ci doctor is demanding the ABSENCE of the reaper label it requires"
}

# ════════════════════════════════════════════════════════════════════════════
# HTTP — three codes, three fixes
# ════════════════════════════════════════════════════════════════════════════

@test "HTTP 000, 502 and 200 are three different readings" {
  [ "$(nd_verdict_http 200)" = "PASS" ]
  [ "$(nd_verdict_http 502)" = "FAIL" ]
  [ "$(nd_verdict_http 000)" = "FAIL" ]
  [ "$(nd_verdict_http UNKNOWN)" = "UNKNOWN" ]
  # The verdicts for 502 and 000 are the same; the EXPLANATIONS must not be, or
  # the operator is sent to the wrong layer.
  [ "$(nd_http_explain 502)" != "$(nd_http_explain 000)" ]
}

@test "HTTP a 502 means different things from the VM and from the tailnet" {
  # Measured simultaneously on all four lanes on 2026-08-21: VM-side 000 while
  # the tailnet answered 502. The tailnet 502 is `tailscale serve` reporting its
  # proxy target refused; the VM-side one is nginx reporting a dead upstream.
  # Same number, two layers, two fixes.
  [ "$(nd_http_explain 502 vm)" != "$(nd_http_explain 502 tailnet)" ]
  [[ "$(nd_http_explain 502 tailnet)" == *"tailscale serve"* ]]
  [[ "$(nd_http_explain 502 vm)" == *"nginx"* ]]
}

@test "HTTP the entry point flags a tailnet 200 over a dead VM as another lane answering" {
  # The worst of the four VM/tailnet pairings and the one neither probe can see
  # alone: the URL answers while this lane does not.
  grep -q 'Something OTHER than this lane is behind that URL' "$ENTRY"
}

# ════════════════════════════════════════════════════════════════════════════
# COUNTS — zero-node and zero-image traps
# ════════════════════════════════════════════════════════════════════════════

@test "COUNTS zero nodes is a FAIL, not 'all nodes ready'" {
  # `ready == total` alone reports PASS for 0 == 0, which is the most
  # confident-sounding wrong line available here.
  [ "$(nd_verdict_nodes_ready 0 0)" = "FAIL" ]
  [ "$(nd_verdict_nodes_ready 1 1)" = "PASS" ]
  [ "$(nd_verdict_nodes_ready 3 2)" = "FAIL" ]
  [ "$(nd_verdict_nodes_ready UNKNOWN UNKNOWN)" = "UNKNOWN" ]
}

@test "COUNTS an empty node image store is a FAIL" {
  [ "$(nd_verdict_image_store 0)" = "FAIL" ]
  [ "$(nd_verdict_image_store 43)" = "PASS" ]
  [ "$(nd_verdict_image_store UNKNOWN)" = "UNKNOWN" ]
}

@test "COUNTS a kind node that is not Up is a FAIL, not merely non-empty" {
  # `Restarting`, `Exited` and `Created` are all non-empty and all not running,
  # so an emptiness test would pass a crash-looping node.
  [ "$(nd_verdict_kind_node 'Up 36 minutes')" = "PASS" ]
  [ "$(nd_verdict_kind_node 'Restarting (1) 3 seconds ago')" = "FAIL" ]
  [ "$(nd_verdict_kind_node 'Exited (137) 2 minutes ago')" = "FAIL" ]
  [ "$(nd_verdict_kind_node '')" = "UNKNOWN" ]
}

@test "COUNTS disk thresholds fire, and a non-numeric reading is UNKNOWN" {
  [ "$(nd_verdict_disk 18)" = "PASS" ]
  [ "$(nd_verdict_disk 85)" = "WARN" ]
  [ "$(nd_verdict_disk 95)" = "FAIL" ]
  [ "$(nd_verdict_disk UNKNOWN)" = "UNKNOWN" ]
  [ "$(nd_verdict_disk '')" = "UNKNOWN" ]
}

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY — UNKNOWN must never be laundered into a pass
# ════════════════════════════════════════════════════════════════════════════

@test "SUMMARY a clean run exits 0 and says HEALTHY" {
  run bash -c ". '$LIB'; nd_pass a >/dev/null; nd_pass b >/dev/null; nd_summary demo-1 demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NODE-DOCTOR demo-1 demo PASS pass=2 fail=0 warn=0 unknown=0"* ]]
}

@test "SUMMARY any failure exits 1" {
  run bash -c ". '$LIB'; nd_pass a >/dev/null; nd_fail b >/dev/null; nd_summary ci-1 ci"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NODE-DOCTOR ci-1 ci FAIL"* ]]
}

@test "SUMMARY an UNKNOWN with no failures exits 3, and is NOT reported as a pass" {
  # The distinction the whole four-verdict scheme exists for. Folding this into
  # 0 is the vacuous pass; folding it into 1 sends an operator hunting a fault
  # that may not be there.
  run bash -c ". '$LIB'; nd_pass a >/dev/null; nd_unknown b >/dev/null; nd_summary demo-2 demo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"NODE-DOCTOR demo-2 demo UNKNOWN"* ]]
  [[ "$output" == *"This is NOT a pass"* ]]
  [[ "$output" != *"HEALTHY"* ]]
}

@test "SUMMARY the machine-readable verdict line is always emitted last" {
  # The sweep's contract with the per-lane runs. It greps this line rather than
  # parsing the prose, so the prose stays free to be reworded.
  run bash -c ". '$LIB'; nd_fail x >/dev/null; nd_summary ci-2 ci"
  [ "$(printf '%s\n' "$output" | tail -1 | cut -d' ' -f1)" = "NODE-DOCTOR" ]
}

@test "SUMMARY an unrecognised verdict is routed to FAIL, never swallowed" {
  # An adjudicator returning a typo must not become a silent pass.
  run bash -c ". '$LIB'; nd_report BANANA 'a thing' >/dev/null; nd_summary demo-1 demo"
  [ "$status" -eq 1 ]
}

# ════════════════════════════════════════════════════════════════════════════
# PROBE — properties of the collector that cannot be checked by running it
# ════════════════════════════════════════════════════════════════════════════

# Strips comments before grepping the source. Without this, a guard looking for
# a forbidden construct matches the COMMENT that explains why the construct is
# forbidden — a green-looking finding about the file's own prose. probe.sh
# contains exactly such a comment about `pkill -f`.
code_only() {
  sed 's/#.*//' "$1"
}

@test "GUARD refute_match can actually fail, and refuses to judge an empty file" {
  # The meta positive control, and the reason it exists: every negative
  # assertion in this file routes through refute_match, so a refute_match that
  # could never fail would silently disable all of them at once — and they
  # would all still read as green assertions in the source.
  local tmp="$BATS_TEST_TMPDIR/sample.sh"

  printf 'echo hello\npkill -f something\n' >"$tmp"
  run refute_match "$tmp" '\bpkill\b'
  [ "$status" -ne 0 ]

  printf 'echo hello\n' >"$tmp"
  run refute_match "$tmp" '\bpkill\b'
  [ "$status" -eq 0 ]

  # An unreadable file matches nothing, which is indistinguishable from a clean
  # file. refute_match must refuse rather than return the reassuring answer.
  : >"$tmp"
  run refute_match "$tmp" '\bpkill\b'
  [ "$status" -ne 0 ]

  # And comments must not satisfy it: a guard that matches the prose explaining
  # why a construct is forbidden reports the explanation as the violation.
  printf '# we never call pkill here\necho hello\n' >"$tmp"
  run refute_match "$tmp" '\bpkill\b'
  [ "$status" -eq 0 ]
}

@test "PROBE the completion marker is the last thing emitted" {
  # The positive control for every TRUNCATION test above: if probe.sh stopped
  # emitting it, those tests would still pass against their fixtures while the
  # real thing lost its only integrity signal.
  local last
  last="$(grep -n '^emit ' "$PROBE" | tail -1)"
  [[ "$last" == *"emit probe.complete 1"* ]]
}

@test "PROBE every fact is emitted through emit(), which never omits a key" {
  # A skipped key and a truncated report are the same evidence to the reader.
  # emit() substitutes the literal UNKNOWN for an empty value, so the guard is
  # that the substitution is still there.
  grep -q 'value="UNKNOWN"' "$PROBE"
}

@test "PROBE the port-forward is killed by PID, never by pattern" {
  # This repo's Bash tooling wraps commands in `bash -c`, so a `pkill -f`
  # pattern matches the shell running it and takes out the caller — silently,
  # and reading as a hung probe.
  refute_match "$PROBE" '\b(pkill|pgrep)\b' \
    "a pattern kill here matches the wrapping bash -c and takes out the caller"
  # Positive control: the file IS being read and the kill it does use is there.
  grep -q 'kill "$pf"' "$PROBE"
}

@test "PROBE the collector sets no verdicts — adjudication lives in lib.sh" {
  # The property that makes this whole suite possible. If probe.sh starts
  # deciding, those decisions become untestable without a VM.
  refute_match "$PROBE" '\b(PASS|FAIL|WARN)\b' \
    "a verdict decided on the VM is a verdict this suite cannot drive without a VM"
  # Positive control: lib.sh, which SHOULD contain them, does.
  code_only "$LIB" | grep -q 'PASS'
}

@test "PROBE the collector does not enable nounset" {
  # The shell snapshot Claude Code injects has an unguarded $ZSH_VERSION, and
  # `set -u` turns every grep into a fatal error. Unrelated to the VM, entirely
  # about how this file gets edited and driven.
  refute_match "$PROBE" 'set -[a-z]*u' \
    "nounset makes the shell snapshot's unguarded \$ZSH_VERSION fatal on every grep"
}

@test "PROBE the entry point never redirects a file into gcloud ssh's stdin" {
  # gcloud compute ssh DOES NOT FORWARD STDIN: the redirect is accepted, the
  # command exits 0, and the script runs as ZERO BYTES. For a doctor that means
  # a report with no keys and no error anywhere. The probe text goes in
  # --command; see verify_delivered_size() in scripts/gcp-tf/demo-up.sh.
  refute_match "$ENTRY" 'command="bash -s"' \
    "gcloud compute ssh does not forward stdin — the probe would run as zero bytes"
  refute_match "$ENTRY" '<<<"\$script"' \
    "here-string into gcloud ssh is the same zero-byte trap"
  # Positive control: the file is being read, and the correct spelling is there.
  grep -q -- '--command="$script"' "$ENTRY"
}

@test "PROBE every gcloud call empties SSH_AUTH_SOCK" {
  # A forwarded agent makes gcloud compute ssh fail with "agent refused
  # operation", which surfaces as a connection timeout and reads as a broken VM
  # — a node doctor misreporting a healthy lane as unreachable is the exact
  # failure it exists to prevent.
  #
  # Counted rather than merely grepped: every `gcloud compute` invocation must
  # be preceded by the emptying, so a NEW call site added without it fails here.
  local calls guarded
  calls="$(code_only "$ENTRY" | grep -cE 'gcloud compute')"
  guarded="$(code_only "$ENTRY" | grep -cE "SSH_AUTH_SOCK='' gcloud compute")"
  [ "$calls" -gt 0 ]
  [ "$calls" -eq "$guarded" ]
}

# ════════════════════════════════════════════════════════════════════════════
# MAKE — the targets exist and carry the family's guards
# ════════════════════════════════════════════════════════════════════════════

@test "MAKE doctor-node and doctor-node-all are declared and .PHONY" {
  local mk="${REPO_ROOT}/Makefile"
  grep -qE '^\.PHONY: doctor-node$' "$mk"
  grep -qE '^doctor-node:' "$mk"
  grep -qE '^\.PHONY: doctor-node-all$' "$mk"
  grep -qE '^doctor-node-all:' "$mk"
}

@test "MAKE doctor-node reuses the gcp-tf family's ENV and impersonation guards" {
  # Not a second spelling of "is ENV valid". Two of those drift the moment one
  # is corrected, and the correction is always applied to the one the author
  # happened to be looking at.
  local body
  body="$(sed -n '/^doctor-node:/,/^$/p' "${REPO_ROOT}/Makefile")"
  [[ "$body" == *'$(gcp_tf_require_env)'* ]]
  [[ "$body" == *'$(gcp_tf_require_impersonation)'* ]]
}

@test "MAKE the sweep reads the machine-readable verdict line, not the prose" {
  local body
  body="$(sed -n '/^doctor-node-all:/,/^$/p' "${REPO_ROOT}/Makefile")"
  [[ "$body" == *'NODE-DOCTOR '* ]]
  # And it must not stop at the first failing lane — on a four-lane estate the
  # second broken lane is most of the value.
  [[ "$body" == *'--all'* ]]
}

@test "MAKE the node doctors are discoverable from the debugging-first-moves block" {
  grep -q 'make doctor-node ENV=demo-1' "${REPO_ROOT}/Makefile"
}

@test "MAKE this suite and its proof each have a target that runs them" {
  # A suite nothing invokes provides no regression protection however green it
  # is by hand. d2-signalloom/test/bats-registry-coverage.bats is the fixed
  # point that enforces this across the repo — it caught this very file being
  # unregistered — and these two targets are the local entry points.
  local mk="${REPO_ROOT}/Makefile"
  grep -qE '^test-node-doctor:' "$mk"
  grep -qE '^test-node-doctor-proof:' "$mk"
  grep -q 'bats test/node-doctor.bats' "$mk"
  grep -q './test/node-doctor-mutation-proof.sh' "$mk"
}

@test "MAKE both CI pipelines invoke this suite, not just one of them" {
  # The two pipeline scripts carry hand-written suite lists and are known to
  # drift: scripts/ci/vm-pipeline.sh duplicates chunks of the Makefile, so a fix
  # applied to one has repeatedly failed to reach the other. Both are asserted
  # here rather than trusting that whoever edits one will remember the other.
  grep -q 'test/node-doctor.bats' "${REPO_ROOT}/scripts/ci/vm-pipeline.sh"
  grep -q 'test/node-doctor.bats' "${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
}
