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
pf.unit_active=active
pf.unit_enabled=enabled
pf.listeners=1
pf.main_pid=1509084
pf.pid_alive=yes
spire.jwt_active_kid=nnsfgifDSBnAJTRpyFs8HiEFna6dW0AN
spire.jwt_prepared_kid=NDpwg3CGHayGiYH0WqHjGVV187kWfpxb
spire.jwt_active_expiry=2026-08-24 17:41:45 +0000 UTC
spire.bundle_bytes=5132
spire.jwt_kids=nnsfgifDSBnAJTRpyFs8HiEFna6dW0AN,NDpwg3CGHayGiYH0WqHjGVV187kWfpxb,dTkURcNOMrbH5YNwagsONVZDKFgou7Ng,KKEv0c4CBplCbeqrNdwIHssG77QjVdkT
spire.jwt_keys=KEY_ACTIVE,KEY_PREPARED,KEY_C,KEY_D
bao.jwt_config_bytes=1095
bao.jwt_keys=KEY_ACTIVE,KEY_PREPARED,KEY_C,KEY_D
probe.complete=1
REPORT
}

# The SPIRE/OpenBao key values above are PLACEHOLDERS (KEY_ACTIVE, KEY_C …) and
# the kids beside them are the real ones recorded off sl-demo-1-vm on
# 2026-08-24. That split is deliberate. The adjudicator does set membership on
# opaque strings — it never parses a key — so a 124-character base64 DER in the
# fixture would make every assertion below unreadable while testing exactly the
# same code path. The KIDS stay real because nd_der_for_kid matches on them
# positionally, and a made-up kid would hide a real ordering bug.
#
# The one thing this MUST not do is diverge in SHAPE, so the counts are held
# equal to what the live lane emits: four kids, four keys, comma-separated, in
# bundle order with the active authority first.

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

# ─── The seam between the two halves above ──────────────────────────────────
#
# nd_http_explain is exercised with a hand-written `000` and probe_tailnet was
# exercised with nothing at all, so both halves were green while the chain
# between them was broken. Measured on ci-1 on 2026-08-22, the doctor printed
#
#   ✗ / -> 000000 (unexpected status)
#
# `000000` is not a status code. curl's `-w '%{http_code}'` ALREADY prints 000
# when the connection fails, and probe_tailnet appended a second one with
# `|| printf '000'`. No arm of nd_http_explain matches the result, so it fell
# through to `*)` and the purpose-written 000 sentence — "the name did not
# resolve, or nothing is served on it" — was dead code in the one case it was
# written for.
#
# It survived because the failure it hides needs curl to FAIL. On 2026-08-21
# the lanes answered a real 502, and a 502 is a SUCCESSFUL curl (rc=0), so the
# fallback never fired and the seam looked fine.
#
# The stub is in the shape curl really has, and both halves of that shape are
# load-bearing: it prints 000 AND exits non-zero. Measured live against an
# unroutable address on 2026-08-22: `code=000 rc=28`. A stub that only exited
# non-zero without printing would not reproduce the defect at all.
lift_probe_tailnet() {   # the entry script runs its arg parser on source
	eval "$(awk '/^probe_tailnet\(\) \{/,/^\}/' "$ENTRY")"
}
stub_failing_curl() {
	local stub="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stub"
	printf '%s\n' '#!/usr/bin/env bash' 'printf 000' 'exit 28' >"$stub/curl"
	chmod +x "$stub/curl"
	printf '%s' "$stub"
}

@test "HTTP a probe whose curl fails emits ONE status code, not two" {
	lift_probe_tailnet
	local stub; stub="$(stub_failing_curl)"
	PATH="${stub}:$PATH" TS_FQDN=example.invalid run probe_tailnet /
	[ "$output" = "000" ]
}

@test "HTTP what a failing probe emits is a code nd_http_explain understands" {
	# The assertion that would have caught it. Whatever probe_tailnet emits has
	# to survive the adjudicator it is fed to — testing the two ends against
	# each other's assumptions is what neither half did.
	lift_probe_tailnet
	local stub; stub="$(stub_failing_curl)"
	PATH="${stub}:$PATH" TS_FQDN=example.invalid run probe_tailnet /
	[ "$(nd_http_explain "$output" tailnet)" != "unexpected status" ]
	[[ "$(nd_http_explain "$output" tailnet)" == *"no response"* ]]
}

@test "HTTP a probe with no curl at all is still UNKNOWN, not 000" {
	# The positive control for the pair above: the fix must not collapse
	# "could not measure" into "measured, nothing there". Those are the two
	# answers this whole file exists to keep apart.
	lift_probe_tailnet
	local empty="$BATS_TEST_TMPDIR/empty"
	mkdir -p "$empty"
	PATH="$empty" TS_FQDN=example.invalid run probe_tailnet /
	[ "$output" = "UNKNOWN" ]
	[ "$(nd_verdict_http "$output")" = "UNKNOWN" ]
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
# PUBLISH PATH — the forward that dies without telling anyone
# ════════════════════════════════════════════════════════════════════════════

@test "PUBLISH a forward that is active and listening passes" {
  # The positive control for every PUBLISH test below. Without it, a
  # nd_verdict_publish that returned FAIL unconditionally would make all four
  # failure cases pass while the check was useless.
  local r; r="$(healthy_report)"
  assert_field_present "$r" pf.unit_active
  assert_field_present "$r" pf.listeners
  run nd_verdict_publish "$(nd_field "$r" pf.unit_active)" "$(nd_field "$r" pf.listeners)"
  [ "$output" = PASS ]
  run nd_publish_state "$(nd_field "$r" pf.unit_active)" "$(nd_field "$r" pf.listeners)"
  [ "$output" = SERVING ]
}

@test "PUBLISH the ZOMBIE forward — systemd active, NOTHING listening — is a FAIL" {
  # THE case this check exists for, and the one every naive in-VM probe passes.
  # kubectl port-forward does not exit when the pod it forwards to is rolled:
  # the process survives, systemd reports `active`, the journal's last line is
  # still "Forwarding from 0.0.0.0:30754", and the socket is gone. The public
  # origin serves 502 throughout.
  #
  # A single "is the unit up" boolean reports this GREEN, which is precisely how
  # a dashboard rollout took the public URL down with every check passing.
  run nd_verdict_publish active 0
  [ "$output" = FAIL ]
  run nd_publish_state active 0
  [ "$output" = ZOMBIE ]
}

@test "PUBLISH a unit that is down with no listener is a FAIL, and a DIFFERENT state" {
  # Same verdict as the zombie, deliberately different state: the zombie needs
  # the forward re-established after whatever rolled the backend, this needs the
  # unit started. Collapsing them would send an operator to the wrong command.
  run nd_verdict_publish inactive 0
  [ "$output" = FAIL ]
  run nd_publish_state inactive 0
  [ "$output" = DOWN ]
}

@test "PUBLISH a FOREIGN listener on the port is never a pass" {
  # Traffic may be answering, but not from the supervised unit — so nothing
  # re-establishes it after a reboot, and a restart of the real unit will fail
  # to bind. The tempting reading ("something is listening, so we are fine") is
  # the one this refuses.
  run nd_verdict_publish inactive 1
  [ "$output" = FAIL ]
  run nd_publish_state inactive 1
  [ "$output" = FOREIGN_LISTENER ]
}

@test "PUBLISH an unmeasured unit or listener count is UNKNOWN, never a pass" {
  # `ss` absent, or the unit name wrong, must not read as a healthy forward.
  run nd_verdict_publish UNKNOWN 1
  [ "$output" = UNKNOWN ]
  run nd_verdict_publish active UNKNOWN
  [ "$output" = UNKNOWN ]
  # A non-numeric listener count is a broken probe, not zero listeners.
  run nd_verdict_publish active 'error'
  [ "$output" = UNKNOWN ]
  run nd_publish_state active 'error'
  [ "$output" = UNMEASURED ]
}

@test "PUBLISH the entry point reports the zombie with its own diagnosis" {
  # The verdict alone is not the product — an operator must learn WHICH of the
  # four states this is. Drives the real shared block against a mutated report.
  local r; r="$(with_field "$(healthy_report)" pf.listeners 0)"
  run bash -c ". '$LIB'; nd_checks_shared \"\$1\" demo-1 30754 sl-demo-1" _ "$r"
  [[ "$output" == *"ZOMBIE"* ]]
  [[ "$output" == *"does not exit when the pod it forwards to is rolled"* ]]
}

# ════════════════════════════════════════════════════════════════════════════
# JWT TRUST — the SuperCred outage, caught before it lands
# ════════════════════════════════════════════════════════════════════════════

@test "JWT a lane where OpenBao holds every key SPIRE publishes passes" {
  # The positive control. Every failing case below is worthless without it: an
  # adjudicator hardwired to FAIL would satisfy all of them.
  local r; r="$(healthy_report)"
  assert_field_present "$r" spire.jwt_keys
  assert_field_present "$r" bao.jwt_keys
  assert_field_present "$r" spire.jwt_active_kid
  local der; der="$(nd_der_for_kid "$(nd_field "$r" spire.jwt_kids)" \
                     "$(nd_field "$r" spire.jwt_keys)" "$(nd_field "$r" spire.jwt_active_kid)")"
  [ "$der" = KEY_ACTIVE ]
  run nd_verdict_jwt_trust "$(nd_field "$r" spire.jwt_active_kid)" \
        "$(nd_field "$r" spire.jwt_keys)" "$(nd_field "$r" bao.jwt_keys)" "$der"
  [ "$output" = PASS ]
}

@test "JWT the ACTIVE authority missing from OpenBao is BROKEN_NOW" {
  # Every SPIFFE->OpenBao login is failing right now with "no known key
  # successfully validated the token signature". SuperCred step 2 dies on
  # exactly this while the runner still reports script_available=true.
  run nd_verdict_jwt_trust ACTIVEKID 'KEY_ACTIVE,KEY_C' 'KEY_C' KEY_ACTIVE
  [ "$output" = BROKEN_NOW ]
}

@test "JWT the PREPARED authority missing is WILL_BREAK — the live sl-demo-1 state" {
  # Recorded off sl-demo-1 on 2026-08-24T09:15Z: SPIRE published four keys,
  # OpenBao held three, the absent one was the PREPARED authority, and the
  # active authority was due to expire at 17:41:45Z the same day. The lane
  # worked perfectly and was going to stop, unattended, about eight hours later.
  #
  # node-doctor scored 24 pass and the user-surface gate reported both demos
  # READY at that moment. Neither could see it. This is the case that proves
  # capability is not completion, and that the cause is cheaper to check than
  # the symptom.
  local r; r="$(with_field "$(healthy_report)" bao.jwt_keys 'KEY_ACTIVE,KEY_C,KEY_D')"
  local der; der="$(nd_der_for_kid "$(nd_field "$r" spire.jwt_kids)" \
                     "$(nd_field "$r" spire.jwt_keys)" "$(nd_field "$r" spire.jwt_active_kid)")"
  run nd_verdict_jwt_trust "$(nd_field "$r" spire.jwt_active_kid)" \
        "$(nd_field "$r" spire.jwt_keys)" "$(nd_field "$r" bao.jwt_keys)" "$der"
  [ "$output" = WILL_BREAK ]
}

@test "JWT WILL_BREAK is a FAIL in the summary, not a soft warning" {
  # The considered call, asserted so a future "this lane works, tone it down"
  # cannot quietly make it rc=0. DEGRADED exists for a condition we EXPECT and
  # cannot fix for up to 168h; this is neither — it is never expected and the
  # fix is one command. A rc=0 verdict on a certain, imminent, trivially
  # fixable outage is how the principal ends up being the detector again.
  local r; r="$(with_field "$(healthy_report)" bao.jwt_keys 'KEY_ACTIVE,KEY_C,KEY_D')"
  run bash -c ". '$LIB'; nd_checks_shared \"\$1\" demo-1 30754 sl-demo-1; nd_summary demo-1 demo" _ "$r"
  [ "$status" -eq 1 ]
  [[ "$output" == *"will stop the moment SPIRE rotates"* ]]
}

@test "JWT an UNREADABLE side is UNKNOWN — the vacuous pass this refuses" {
  # THE defect this adjudicator is shaped around. A failed kubectl produces an
  # empty key list on both sides, the membership loop never executes, and a
  # naive implementation returns PASS having compared NOTHING.
  #
  # That exact bug was found in assert_openbao_accepts_spire_jwt_keys on
  # 2026-08-23, where it passed against no cluster at all — in the one assert
  # that exists to catch silent identity-plane failure.
  run nd_verdict_jwt_trust KID '' 'KEY_A' KEY_A
  [ "$output" = UNKNOWN ]
  run nd_verdict_jwt_trust KID 'KEY_A' '' KEY_A
  [ "$output" = UNKNOWN ]
  run nd_verdict_jwt_trust KID UNKNOWN UNKNOWN UNKNOWN
  [ "$output" = UNKNOWN ]
}

@test "JWT a lane with no SPIRE is NOT_DEPLOYED, distinct from zero keys" {
  # "Nothing has been asked" and "everything was asked and nothing matched" send
  # a reader to completely different places — a missing deployment versus a sync
  # command for a component that is not there.
  run nd_verdict_jwt_trust NOT_DEPLOYED NOT_DEPLOYED NOT_DEPLOYED UNKNOWN
  [ "$output" = NOT_DEPLOYED ]
}

@test "JWT nd_der_for_kid refuses to answer from lists that are not parallel" {
  # The positional lookup is only safe because probe.sh builds both lists from
  # ONE jq selector. If they ever desync, a positional answer is a DIFFERENT
  # key's bytes returned with no error anywhere — so a length disagreement must
  # produce UNKNOWN rather than a confident wrong string.
  run nd_der_for_kid 'a,b,c' 'K1,K2' a
  [ "$output" = UNKNOWN ]
  # Positive control: parallel lists DO resolve, and to the right element.
  run nd_der_for_kid 'a,b,c' 'K1,K2,K3' b
  [ "$output" = K2 ]
  # A kid that is not in the list is UNKNOWN, never the first element.
  run nd_der_for_kid 'a,b,c' 'K1,K2,K3' zzz
  [ "$output" = UNKNOWN ]
}

@test "JWT nd_csv_count never prints 0 for an unmeasured list" {
  # "OpenBao holds 0 keys" and "OpenBao could not be read" are opposite
  # findings, and both would otherwise render as the same number in the prose.
  run nd_csv_count ''
  [ "$output" = UNKNOWN ]
  run nd_csv_count UNKNOWN
  [ "$output" = UNKNOWN ]
  run nd_csv_count 'a,b,c'
  [ "$output" = 3 ]
}

# ════════════════════════════════════════════════════════════════════════════
# DEX — the redirect_uri that broke sign-in while the page returned 200
# ════════════════════════════════════════════════════════════════════════════

@test "DEX an accepted redirect_uri passes and a rejected one FAILS" {
  # Both arms measured against sl-demo-1 on 2026-08-24 by following the
  # redirect: the dashboard's own /callback returned 200 with a clean body, and
  # https://evil.example/cb returned 400 with "Unregistered redirect_uri".
  run nd_verdict_dex_redirect 200 no
  [ "$output" = PASS ]
  run nd_verdict_dex_redirect 400 yes
  [ "$output" = FAIL ]
}

@test "DEX a 302 with no rejection passes — the first hop is not the answer" {
  # Dex bounces to its connector before rejecting anything, so a 302 is a normal
  # intermediate state. What decides is the rejection flag, not the code.
  run nd_verdict_dex_redirect 302 no
  [ "$output" = PASS ]
  # And a rejection outranks ANY status code: if the body says unregistered,
  # the verdict is FAIL even on a 200.
  run nd_verdict_dex_redirect 200 yes
  [ "$output" = FAIL ]
}

@test "DEX an empty body cannot be said to lack the rejection" {
  # "Dex accepted it" and "we never got an answer" both produce no match for the
  # rejection string. Only the second is UNKNOWN, and conflating them reports a
  # dead origin as a working sign-in.
  run nd_verdict_dex_redirect 200 UNKNOWN
  [ "$output" = UNKNOWN ]
  run nd_verdict_dex_redirect 000 no
  [ "$output" = UNKNOWN ]
}

@test "DEX the probed callback path is the one the dashboard actually uses" {
  # An earlier draft of this probe guessed /auth/callback and reported the LIVE,
  # WORKING lane as broken — Dex rejected the guess exactly as it would reject a
  # genuine misconfiguration. The value is pinned to the client's own source so
  # the two cannot drift apart again.
  local oidc="${REPO_ROOT}/d2-signalloom/apps/dashboard-signalloom/src/auth/oidc.tsx"
  [ -s "$oidc" ]
  grep -q 'redirect_uri: `${window.location.origin}/callback`' "$oidc"
  grep -q 'ND_DEX_CALLBACK:-/callback' "$ENTRY"
}

@test "DEX the probe FOLLOWS redirects, which is what makes it able to fail" {
  # Measured, not assumed: a bare GET /dex/auth returns 302 for a VALID
  # redirect_uri AND for https://evil.example/cb. A probe reading the first
  # response passes identically against a completely broken origin — a check
  # that cannot fail, which is worse than no check.
  code_only "$ENTRY" | grep -q 'curl -skL'
}

# ════════════════════════════════════════════════════════════════════════════
# DEMO SURFACES — the Signal Fusion class: reachable, 200, and unusable
# ════════════════════════════════════════════════════════════════════════════

@test "DEMO a capable surface with acts passes" {
  # The positive control for the three failure cases below.
  run nd_verdict_demo_surface 200 true 3
  [ "$output" = PASS ]
}

@test "DEMO a 200 that reports script_available=false FAILS" {
  # THE Signal Fusion outage. The page returned 200, the demo API was reachable,
  # and all three acts 503'd. HTTP 200 is not evidence that a demo can run —
  # only the runner's own statement that it CAN is, and this is where that gets
  # asserted.
  run nd_verdict_demo_surface 200 false 3
  [ "$output" = FAIL ]
}

@test "DEMO a capable surface advertising ZERO acts FAILS" {
  # A runner that reports itself capable and enumerates nothing is a demo a
  # human opens and cannot drive. It passes every reachability check there is.
  run nd_verdict_demo_surface 200 true 0
  [ "$output" = FAIL ]
}

@test "DEMO a 5xx or 404 FAILS and an unreachable surface is UNKNOWN" {
  run nd_verdict_demo_surface 503 '' ''
  [ "$output" = FAIL ]
  run nd_verdict_demo_surface 404 '' ''
  [ "$output" = FAIL ]
  # A transport failure has not shown the demo to be broken — it has shown
  # nothing, and must not be reported as a product outage.
  run nd_verdict_demo_surface 000 '' ''
  [ "$output" = UNKNOWN ]
}

@test "DEMO an absent script_available is UNKNOWN, never treated as false" {
  # A response shape change would otherwise report every demo BROKEN at once —
  # a whole-estate false RED, which erodes trust in a doctor as surely as a
  # false GREEN does.
  run nd_verdict_demo_surface 200 '' 3
  [ "$output" = UNKNOWN ]
  run nd_verdict_demo_surface 200 true 'x'
  [ "$output" = UNKNOWN ]
}

@test "DEMO the doctor never reports success over an EMPTY surface set" {
  # A gate that cannot list what it guards must not pass. The entry point's
  # empty-registry arm is UNKNOWN, and this asserts the wording that says so.
  code_only "$ENTRY" | grep -q 'nd_unknown "the demo surface registry could not be enumerated'
  refute_match "$ENTRY" 'nd_pass "the demo surface registry' \
    "an unenumerable registry must never render as a pass"
}

@test "DEMO surfaces are enumerated from the registry, never from a list here" {
  # A hand-written list in a doctor silently stops covering the newest demo,
  # which is the one most likely to be broken. Same rule the user-surface gate
  # is built on, asserted here so the doctor cannot drift away from it.
  code_only "$ENTRY" | grep -q 'demo-surface-registry.py'
  refute_match "$ENTRY" 'for demo in .*supercred.*signalfusion' \
    "a hardcoded demo list stops covering the newest demo"
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

@test "PROBE the publish path is collected as three separate facts" {
  # The unit state, the listening socket and the pid are collected separately
  # and never merged, because the DISAGREEMENT between them is the diagnosis: a
  # zombie forward reads `active` with no listener. A probe that emitted one
  # "is it up" boolean could not express that state at all.
  code_only "$PROBE" | grep -q 'emit pf.unit_active'
  code_only "$PROBE" | grep -q 'emit pf.listeners'
  code_only "$PROBE" | grep -q 'emit pf.main_pid'
}

@test "PROBE the listener count is counted, never piped into grep -q" {
  # Under `set -o pipefail` a `grep -q` that matches early can close the pipe and
  # surface 141, inverting the answer — the shape VAC008 rejects in verdict
  # positions. This is a verdict input, so it must be a count that runs to
  # completion.
  refute_match "$PROBE" 'ss -ltn[^|]*\|[^|]*grep -q' \
    "grep -q under pipefail can report the opposite of what it found"
  # Positive control: the counting form IS there, and it forces a literal 0
  # rather than an empty string, so "no listeners" and "unreadable" stay apart.
  code_only "$PROBE" | grep -q 'END{print n+0}'
}

@test "PROBE both SPIRE key lists are built from ONE pinned jq selector" {
  # nd_der_for_kid matches the active kid POSITIONALLY across spire.jwt_kids and
  # spire.jwt_keys. That is only safe while both lists filter identically. The
  # obvious spelling gives the kid list a looser filter than the key list, and
  # they desync the first time a bundle carries a jwt-svid key of another type —
  # after which the lookup returns a DIFFERENT key's bytes with no error.
  #
  # nd_der_for_kid's length check is the runtime backstop; this is the guard
  # that keeps the lists parallel in the first place.
  code_only "$PROBE" | grep -q 'JWT_SVID_SELECT='
  local uses
  uses="$(code_only "$PROBE" | grep -c '\${JWT_SVID_SELECT}')"
  [ "$uses" -eq 2 ]
  # And there is exactly ONE jwt-svid selector in the file — the definition
  # above. A refute_match here would be self-defeating: the forbidden pattern is
  # the definition's own text, so the guard fires on the very line that makes
  # the property true. Counting is the form that expresses "one, and only one".
  local selectors
  selectors="$(code_only "$PROBE" | grep -c 'select(\.use=="jwt-svid"')"
  [ "$selectors" -eq 1 ]
}

@test "PROBE the JWT trust read distinguishes 'no keys' from 'could not read'" {
  # Both produce an empty key list and they are opposite findings. The byte
  # counts are what let lib.sh tell them apart, exactly as zot.log_bytes does
  # for the log scan.
  code_only "$PROBE" | grep -q 'emit spire.bundle_bytes'
  code_only "$PROBE" | grep -q 'emit bao.jwt_config_bytes'
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
