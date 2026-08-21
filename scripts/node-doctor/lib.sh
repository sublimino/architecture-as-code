#!/usr/bin/env bash
# lib.sh — the node doctor's shared health library. ADJUDICATES, never collects.
#
# Sourced by scripts/node-doctor/demo.sh and scripts/node-doctor/ci.sh. Sourcing
# it has no side effects beyond defining functions and zeroing the counters, so
# a test can source it and call one function.
#
# Every adjudicator here is a PURE function of strings: it takes the values
# scripts/node-doctor/probe.sh collected and returns a verdict. Nothing in this
# file shells out to gcloud, ssh, kubectl or curl. That is what lets
# test/node-doctor.bats drive the real functions against recorded probe output,
# including the states that cannot be produced on demand — an unlinked zot blob
# store, a drifted MagicDNS name, a demo lane wearing the reaper's label.
#
# ═══ THE FOUR VERDICTS, AND WHY THERE ARE FOUR ══════════════════════════════
#
#   PASS     the check ran and the thing is right
#   FAIL     the check ran and the thing is wrong
#   WARN     the check ran, the thing is not wrong yet, and it is heading there
#   UNKNOWN  the check COULD NOT RUN
#
# UNKNOWN is the one that matters and it is the one usually missing. A health
# check that cannot distinguish "I looked and it was fine" from "I could not
# look" reports the second as the first, and every reader downstream is told the
# lane was checked when nothing was. So UNKNOWN counts as an issue, is never
# folded into PASS, and gets its own exit status (3) so a sweep can tell
# "this lane is broken" from "this lane was not measured".
#
# The clearest instance is the zot log scan. `grep -c readdirent` returns 0 for
# a healthy registry and 0 for a log that could not be read; only the byte count
# alongside it separates the two, which is why nd_verdict_zot_log takes both.

# ─── Verdict accumulation ───────────────────────────────────────────────────
ND_PASS=0
ND_FAIL=0
ND_WARN=0
ND_UNKNOWN=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ND_RED=$'\033[0;31m'; ND_GRN=$'\033[0;32m'; ND_YEL=$'\033[0;33m'
  ND_CYA=$'\033[0;36m'; ND_BLD=$'\033[1m';    ND_RST=$'\033[0m'
else
  ND_RED=''; ND_GRN=''; ND_YEL=''; ND_CYA=''; ND_BLD=''; ND_RST=''
fi

nd_header() { printf '\n%s%s── %s ──%s\n' "$ND_BLD" "$ND_CYA" "$1" "$ND_RST"; }
nd_pass()   { printf '  %s✓%s %s\n' "$ND_GRN" "$ND_RST" "$1"; ND_PASS=$((ND_PASS + 1)); }
nd_fail()   { printf '  %s✗%s %s\n' "$ND_RED" "$ND_RST" "$1"; ND_FAIL=$((ND_FAIL + 1)); }
nd_warn()   { printf '  %s⚠%s %s\n' "$ND_YEL" "$ND_RST" "$1"; ND_WARN=$((ND_WARN + 1)); }
# Deliberately NOT a warning. "?" reads as "we do not know", which is the whole
# point; a "⚠" next to it would invite the reader to treat it as a soft pass.
nd_unknown() { printf '  %s?%s %s\n' "$ND_YEL" "$ND_RST" "$1"; ND_UNKNOWN=$((ND_UNKNOWN + 1)); }

# Routes a verdict word to the right reporter. Adjudicators return the word and
# the caller prints the sentence, so a verdict can be unit-tested without
# asserting on prose that is free to be reworded.
nd_report() {
  local verdict="$1" message="$2"
  case "$verdict" in
    PASS)    nd_pass    "$message" ;;
    FAIL)    nd_fail    "$message" ;;
    WARN)    nd_warn    "$message" ;;
    UNKNOWN) nd_unknown "$message" ;;
    # An adjudicator returning something else is a bug in this file, and it must
    # not be silently swallowed into a pass.
    *)       nd_fail    "INTERNAL: unrecognised verdict '${verdict}' for: ${message}" ;;
  esac
}

# ─── Report parsing ─────────────────────────────────────────────────────────

# Reads one key out of a probe report. Returns the empty string when the key is
# absent, which callers must treat as UNKNOWN rather than as a value — probe.sh
# emits the literal `UNKNOWN` for facts it could not collect, so an EMPTY answer
# here means the key was never emitted at all, i.e. the report is truncated.
nd_field() {
  local report="$1" key="$2"
  printf '%s\n' "$report" | sed -n "s/^${key}=//p" | head -1
}

# The positive control for the whole report. probe.sh's last line is
# `probe.complete=1`; without it every absent key is indistinguishable from a
# key whose check found nothing, so the caller must refuse to adjudicate.
nd_report_complete() {
  local report="$1"
  [ "$(nd_field "$report" 'probe.complete')" = "1" ]
}

# ─── Adjudicators — tailscale ───────────────────────────────────────────────

# The MagicDNS name must be EXACTLY sl-<env>. Tailscale resolves a name
# collision by suffixing, so a rebuilt lane that did not release its device
# record comes back as `sl-demo-1-1` — which resolves, serves, and answers 200
# from a node that is not the one anybody thinks they are looking at. Prefix
# matching would accept it; this is an equality test on the first label for
# exactly that reason.
nd_verdict_ts_name() {
  local expect_host="$1" dnsname="$2" first_label
  case "$dnsname" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  first_label="${dnsname%%.*}"
  if [ "$first_label" = "$expect_host" ]; then printf 'PASS'; else printf 'FAIL'; fi
}

nd_verdict_ts_online() {
  local backend="$1" online="$2"
  case "$backend" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  if [ "$backend" = "Running" ] && [ "$online" = "true" ]; then printf 'PASS'; else printf 'FAIL'; fi
}

# ABSENT is a FAIL, not an UNKNOWN: probe.sh distinguishes "tailscale would not
# answer" (UNKNOWN) from "it answered and there is no serve config" (ABSENT),
# and the second is a real, common state — it is what `tailscale logout` leaves
# behind on a node that stays online and correctly named.
#
# The PORT is compared, not merely the presence of a proxy. A serve config
# pointing at the wrong port is served, resolves, and 502s, which reads as a
# dead backend rather than as a misconfigured listener.
nd_verdict_ts_serve() {
  local want_port="$1" proxy="$2"
  case "$proxy" in
    ''|UNKNOWN) printf 'UNKNOWN'; return ;;
    ABSENT)     printf 'FAIL';    return ;;
  esac
  case "$proxy" in
    *:"${want_port}"|*:"${want_port}"/) printf 'PASS' ;;
    *)                                  printf 'FAIL' ;;
  esac
}

# `enabled` only. `enabled-runtime`, `static` and `linked` all mean the unit does
# not durably survive a reboot, and every other tailscale line stays green after
# one — the lane comes back online, correctly named, serving nothing.
nd_verdict_ts_serve_unit() {
  local state="$1"
  case "$state" in
    enabled) printf 'PASS' ;;
    ''|UNKNOWN) printf 'UNKNOWN' ;;
    *) printf 'FAIL' ;;
  esac
}

# ─── Adjudicators — HTTP ────────────────────────────────────────────────────
#
# Three codes, three different fixes, and collapsing any pair loses the fix:
#
#   000  nothing is listening on the app port at all
#   502  nginx is up and the thing it proxies to is not
#   200  answering
#
# Measured on all four lanes 2026-08-21: the tailnet URL answered 502 while the
# VM-side probe answered 000. Both are true — `tailscale serve` synthesises the
# 502 when its own proxy target refuses — and a doctor that reported only one of
# them would send the operator to the wrong layer.
nd_verdict_http() {
  local code="$1"
  case "$code" in
    200)        printf 'PASS' ;;
    ''|UNKNOWN) printf 'UNKNOWN' ;;
    *)          printf 'FAIL' ;;
  esac
}

# The second argument is the VANTAGE POINT, and it changes what a 502 means.
# From the VM the 502 is the dashboard's nginx reporting that an upstream it
# proxies to is dead. From the tailnet it is `tailscale serve` reporting that
# ITS proxy target — the app port — refused the connection, which is a different
# layer and a different fix. Both were measured on all four lanes on 2026-08-21,
# simultaneously: VM-side 000, tailnet-side 502. Printing one sentence for both
# would send an operator to nginx to explain a lane where nginx is not running.
nd_http_explain() {
  local code="$1" vantage="${2:-vm}"
  case "$code" in
    200) printf 'answering' ;;
    502) if [ "$vantage" = "tailnet" ]; then
           printf 'tailscale serve is up; the app port it proxies to refused'
         else
           printf 'nginx is up, an upstream it proxies to is not'
         fi ;;
    000) if [ "$vantage" = "tailnet" ]; then
           printf 'no response — the name did not resolve, or nothing is served on it'
         else
           printf 'nothing is listening on this port'
         fi ;;
    404) printf 'served, but this route is not mounted' ;;
    ''|UNKNOWN) printf 'not measured' ;;
    *)   printf 'unexpected status' ;;
  esac
}

# ─── Adjudicators — docker / kind ───────────────────────────────────────────

nd_verdict_docker() {
  local version="$1"
  case "$version" in ''|UNKNOWN) printf 'UNKNOWN' ;; *) printf 'PASS' ;; esac
}

# `docker ps --format {{.Status}}` for a running container starts with "Up".
# "Restarting", "Exited" and "Created" are all non-empty and all not running, so
# an emptiness test here would pass a node that is crash-looping.
nd_verdict_kind_node() {
  local status="$1"
  case "$status" in
    Up*)        printf 'PASS' ;;
    ''|UNKNOWN) printf 'UNKNOWN' ;;
    *)          printf 'FAIL' ;;
  esac
}

# A node whose containerd store holds nothing cannot start a workload, and it is
# a state the cluster reports as Ready. Zero is the finding; the exact floor is
# not worth guessing at, so anything above zero passes and the count is printed.
nd_verdict_image_store() {
  local count="$1"
  case "$count" in
    ''|UNKNOWN)     printf 'UNKNOWN' ;;
    0)              printf 'FAIL' ;;
    *[!0-9]*)       printf 'UNKNOWN' ;;
    *)              printf 'PASS' ;;
  esac
}

# ─── Adjudicators — disk ────────────────────────────────────────────────────
#
# 90 fails and 80 warns. The numbers are a judgement, not a measurement, and are
# named here rather than buried so they can be argued with: a kind node that
# fills stops being able to pull, and the symptom is an ImagePullBackOff that
# names a registry rather than a disk.
ND_DISK_FAIL_PCT="${ND_DISK_FAIL_PCT:-90}"
ND_DISK_WARN_PCT="${ND_DISK_WARN_PCT:-80}"
nd_verdict_disk() {
  local pct="$1"
  case "$pct" in
    ''|UNKNOWN) printf 'UNKNOWN'; return ;;
    *[!0-9]*)   printf 'UNKNOWN'; return ;;
  esac
  if   [ "$pct" -ge "$ND_DISK_FAIL_PCT" ]; then printf 'FAIL'
  elif [ "$pct" -ge "$ND_DISK_WARN_PCT" ]; then printf 'WARN'
  else printf 'PASS'; fi
}

# ─── Adjudicators — Kubernetes ──────────────────────────────────────────────

nd_verdict_nodes_ready() {
  local total="$1" ready="$2"
  case "$total$ready" in *UNKNOWN*|'') printf 'UNKNOWN'; return ;; esac
  case "$total" in ''|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  case "$ready" in ''|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  # Zero nodes is not "all nodes ready". `[ "$ready" = "$total" ]` alone reports
  # PASS for 0 == 0, which is what an unreachable-but-answering API server looks
  # like, and it is the single most confident-sounding wrong line available here.
  if [ "$total" -eq 0 ]; then printf 'FAIL'
  elif [ "$ready" -eq "$total" ]; then printf 'PASS'
  else printf 'FAIL'; fi
}

nd_verdict_count_zero_good() {
  local n="$1"
  case "$n" in
    ''|UNKNOWN|*[!0-9]*) printf 'UNKNOWN' ;;
    0)                   printf 'PASS' ;;
    *)                   printf 'FAIL' ;;
  esac
}

# ─── Adjudicators — zot ─────────────────────────────────────────────────────

# The weakest of the four zot checks, kept because it is the one that fires when
# the pod is genuinely down. `Running` with a `1/1` ready count is exactly what
# the blob-store defect leaves in place, so this passing means very little on
# its own — which is why the message beside it says so.
nd_verdict_zot_pod() {
  local status="$1" ready="$2"
  case "$status" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  case "$ready"  in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  # `Running` is not enough: a pod can be Running with 0/1 containers ready,
  # which is what a crash-looping sidecar looks like from the outside.
  case "$ready" in
    0/*|*/0) printf 'FAIL'; return ;;
  esac
  if [ "$status" = "Running" ] && [ "${ready%%/*}" = "${ready##*/}" ]; then
    printf 'PASS'
  else
    printf 'FAIL'
  fi
}

# The cheapest detector for the known blob-store defect, and the only one that
# needs no writes: the host directory and the path the kind node's bind mount
# resolves to must be the same inode. Unlink and recreate the host directory and
# the host gets a fresh one while the node's mount still holds the old, deleted
# inode — the pod then writes into a directory with no name and `readdirent`
# fails, while `/v2/` keeps answering 200 and the pod stays 1/1 Running.
nd_verdict_zot_inode() {
  local host="$1" node="$2"
  case "$host" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  case "$node" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  if [ "$host" = "$node" ]; then printf 'PASS'; else printf 'FAIL'; fi
}

# Link count 0 on a directory means it has been unlinked while something still
# holds it open — "deleted but still referenced", stated by the filesystem
# rather than inferred.
nd_verdict_zot_cache_links() {
  local links="$1"
  case "$links" in
    ''|UNKNOWN|*[!0-9]*) printf 'UNKNOWN' ;;
    0)                   printf 'FAIL' ;;
    *)                   printf 'PASS' ;;
  esac
}

# ═══ The vacuous-pass guard this whole file is organised around ═════════════
#
# `grep -c readdirent` returns 0 for a healthy registry AND 0 for a log that
# could not be read. One number, two opposite meanings, and taking it at face
# value reports an unreadable registry as clean. That is why this function
# refuses to accept the hit count alone: it takes the log's BYTE COUNT too, and
# zero bytes is UNKNOWN no matter what the hit count says.
nd_verdict_zot_log() {
  local bytes="$1" hits="$2"
  case "$bytes" in ''|UNKNOWN|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  case "$hits"  in ''|UNKNOWN|*[!0-9]*) printf 'UNKNOWN'; return ;; esac
  if [ "$bytes" -eq 0 ]; then printf 'UNKNOWN'; return; fi
  if [ "$hits" -eq 0 ]; then printf 'PASS'; else printf 'FAIL'; fi
}

# The write path, which is the only one of the three zot detectors that can see
# every reason a push fails rather than just the one we know about. 201 is the
# OCI spec's "blob uploaded"; the defect produces a 500 that names nothing.
nd_verdict_zot_push() {
  local session="$1" put_code="$2" head_code="$3"
  case "$put_code" in
    SKIPPED)    printf 'SKIPPED'; return ;;
    ''|UNKNOWN) printf 'UNKNOWN'; return ;;
  esac
  case "$session" in ''|UNKNOWN) printf 'UNKNOWN'; return ;; esac
  # A 201 the registry cannot then serve back is not a successful push. The HEAD
  # is what distinguishes "accepted" from "stored", and the defect's whole
  # character is a store that reports success and holds nothing.
  if [ "$put_code" = "201" ] && [ "$head_code" = "200" ]; then printf 'PASS'; else printf 'FAIL'; fi
}

# ─── Adjudicators — AFM cluster import ──────────────────────────────────────
#
# THE check the task exists for. afm-cluster-import is `*/30 * * * *` and a
# CronJob does not run on creation, so for up to half an hour a lane answers
# /afm/health with 200 while holding ZERO clusters: the 502 is gone, the slice
# looks finished, and every RBAC page renders empty. Everything downstream
# reports success. "200 with 0 clusters" is a FAIL here, and it is a fail with a
# name so nobody has to infer it from an empty page.
nd_verdict_cluster_count() {
  local count="$1"
  case "$count" in
    NOT_DEPLOYED)        printf 'FAIL' ;;
    ''|UNKNOWN|*[!0-9]*) printf 'UNKNOWN' ;;
    0)                   printf 'FAIL' ;;
    *)                   printf 'PASS' ;;
  esac
}

# ─── Adjudicators — lane kind contract ──────────────────────────────────────
#
# The two kinds differ in exactly two observable ways and this is where that is
# encoded. Andy's 2026-08-20 decision was that a CI environment IS a demo
# environment, differing only in that it suspends itself when idle and carries a
# reaper label; terraform/modules/compute enforces the same two properties as
# COMPUTE-RULE-09/10 (label) and COMPUTE-RULE-12 (budget). Measured on the live
# estate 2026-08-21:
#
#   sl-ci-1-vm    ci-lane=ci-1   kind=ci     idle-suspend-minutes=30
#   sl-demo-1-vm  <no ci-lane>   kind=demo   <no metadata key>
#
# Inverted, each is a real incident: a demo VM wearing `ci-lane` is a demo VM
# the reaper is entitled to switch off mid-presentation, and a CI lane without
# it is a lane nothing can reap, billing until somebody notices.
nd_verdict_ci_lane_label() {
  local env_key="$1" label_value="$2"
  case "$label_value" in ''|ABSENT) printf 'FAIL'; return ;; UNKNOWN) printf 'UNKNOWN'; return ;; esac
  if [ "$label_value" = "$env_key" ]; then printf 'PASS'; else printf 'FAIL'; fi
}

nd_verdict_demo_no_ci_label() {
  local label_value="$1"
  case "$label_value" in
    UNKNOWN)   printf 'UNKNOWN' ;;
    ''|ABSENT) printf 'PASS' ;;
    *)         printf 'FAIL' ;;
  esac
}

# COMPUTE-RULE-12's floor. Below 5 the reaper suspends lanes mid-run; at 0 it
# never suspends them at all and the lane bills forever.
nd_verdict_ci_idle_budget() {
  local minutes="$1"
  case "$minutes" in ''|ABSENT|UNKNOWN|*[!0-9]*) printf 'FAIL'; return ;; esac
  if [ "$minutes" -ge 5 ]; then printf 'PASS'; else printf 'FAIL'; fi
}

nd_verdict_demo_no_idle_budget() {
  local minutes="$1"
  case "$minutes" in
    UNKNOWN)   printf 'UNKNOWN' ;;
    ''|ABSENT) printf 'PASS' ;;
    *)         printf 'FAIL' ;;
  esac
}

# ─── VM instance state ──────────────────────────────────────────────────────
#
# SUSPENDED means opposite things on the two kinds, and this is the one place
# where reading it wrong wastes the most time. A ci lane suspends itself after
# its idle budget: that is the mechanism working, not a fault, and waking it to
# "fix" it is the wrong move AND spends money. A demo lane has no such mechanism
# — nothing on the estate should ever suspend it — so the same word is a real
# failure there.
#
# Never collapse "could not ask" into "absent". An expired credential once
# produced "VM not found. Run provision first" against a healthy VM, and
# following that instruction rebuilds an estate that was fine; test/
# gcp-ci-vm-status.bats carries the full account.
nd_verdict_vm_status() {
  local kind="$1" status="$2"
  case "$status" in
    RUNNING)                        printf 'PASS' ;;
    SUSPENDED|SUSPENDING)
      if [ "$kind" = "ci" ]; then printf 'PASS'; else printf 'FAIL'; fi ;;
    NOT_FOUND)                      printf 'FAIL' ;;
    ''|UNKNOWN|AUTH_REQUIRED|QUERY_FAILED) printf 'UNKNOWN' ;;
    *)                              printf 'FAIL' ;;
  esac
}

# ─── Summary ────────────────────────────────────────────────────────────────
#
# Exit codes, and why UNKNOWN gets its own:
#
#   0  every check passed
#   1  at least one check FAILED — the lane is broken
#   3  nothing failed but something could not be measured
#
# 3 exists so a sweep can tell "this lane is broken" from "this lane was not
# measured". Folding the second into 0 is the vacuous pass; folding it into 1
# sends an operator hunting for a fault that may not be there.
nd_summary() {
  local env_key="$1" kind="$2" verdict rc

  if   [ "$ND_FAIL" -gt 0 ];    then verdict=FAIL;    rc=1
  elif [ "$ND_UNKNOWN" -gt 0 ]; then verdict=UNKNOWN; rc=3
  else                               verdict=PASS;    rc=0
  fi

  nd_header "SUMMARY"
  printf '  pass=%d  fail=%d  warn=%d  unknown=%d\n' \
    "$ND_PASS" "$ND_FAIL" "$ND_WARN" "$ND_UNKNOWN"
  case "$verdict" in
    PASS) printf '  %s%sHEALTHY%s — every check ran and passed.\n' "$ND_GRN" "$ND_BLD" "$ND_RST" ;;
    FAIL) printf '  %s%sFAULTS FOUND%s — %d check(s) failed. See above.\n' "$ND_RED" "$ND_BLD" "$ND_RST" "$ND_FAIL" ;;
    UNKNOWN) printf '  %s%sNOT FULLY MEASURED%s — nothing failed, but %d check(s) could not run.\n' \
               "$ND_YEL" "$ND_BLD" "$ND_RST" "$ND_UNKNOWN"
             printf '  This is NOT a pass. A check that could not run has told you nothing.\n' ;;
  esac

  # The sweep contract. One machine-readable line, always last, always emitted —
  # `make doctor-node-all` greps for exactly this rather than parsing the prose
  # above it, so the prose stays free to be reworded.
  printf 'NODE-DOCTOR %s %s %s pass=%d fail=%d warn=%d unknown=%d\n' \
    "$env_key" "$kind" "$verdict" "$ND_PASS" "$ND_FAIL" "$ND_WARN" "$ND_UNKNOWN"
  return "$rc"
}

# ─── Shared check block ─────────────────────────────────────────────────────
#
# Everything both kinds check, in causal order — the node, then what runs on it,
# then what it serves. demo.sh and ci.sh call this and then add the handful of
# checks that are genuinely theirs. Two copies of "is the kind node up" would
# drift the moment one of them was corrected.
nd_checks_shared() {
  local report="$1" env_key="$2" app_port="$3" expect_host="$4"
  local v c

  nd_header "TAILSCALE"
  v="$(nd_verdict_ts_online "$(nd_field "$report" ts.backend)" "$(nd_field "$report" ts.online)")"
  nd_report "$v" "node state: backend=$(nd_field "$report" ts.backend) online=$(nd_field "$report" ts.online) ip=$(nd_field "$report" ts.ip)"

  v="$(nd_verdict_ts_name "$expect_host" "$(nd_field "$report" ts.dnsname)")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "MagicDNS name DRIFTED: $(nd_field "$report" ts.dnsname) — expected first label '${expect_host}'. A suffixed name means the previous device record was never released; this node serves, resolves and answers 200 while being a different node from the one the URL implies."
  else
    nd_report "$v" "MagicDNS name: $(nd_field "$report" ts.dnsname) (expected ${expect_host})"
  fi

  v="$(nd_verdict_ts_serve "$app_port" "$(nd_field "$report" ts.serve.proxy)")"
  if [ "$(nd_field "$report" ts.serve.proxy)" = "ABSENT" ]; then
    nd_report FAIL "tailscale serve: ABSENT — nothing is served on the tailnet. This is what 'tailscale logout' leaves behind: node online, correctly named, serving nothing. Run: make gcp-tf-ts-up ENV=${env_key}"
  else
    nd_report "$v" "tailscale serve: $(nd_field "$report" ts.serve.hostport) / -> $(nd_field "$report" ts.serve.proxy) (expected port ${app_port})"
  fi

  v="$(nd_verdict_ts_serve_unit "$(nd_field "$report" ts.serve.unit_enabled)")"
  nd_report "$v" "boot unit: signalloom-tailscale-serve.service is-enabled=$(nd_field "$report" ts.serve.unit_enabled) is-active=$(nd_field "$report" ts.serve.unit_active) — 'enabled' is the property that survives a reboot"

  nd_header "HTTP SURFACE (measured on the VM, 127.0.0.1:${app_port})"
  c="$(nd_field "$report" http.root)"
  nd_report "$(nd_verdict_http "$c")" "/ -> ${c} ($(nd_http_explain "$c"))"
  c="$(nd_field "$report" http.afm_health)"
  nd_report "$(nd_verdict_http "$c")" "/afm/health -> ${c} ($(nd_http_explain "$c"))"

  nd_header "DOCKER + CONTAINERD"
  v="$(nd_verdict_docker "$(nd_field "$report" docker.server)")"
  nd_report "$v" "docker daemon: server=$(nd_field "$report" docker.server) driver=$(nd_field "$report" docker.driver) images=$(nd_field "$report" docker.images) running=$(nd_field "$report" docker.running)"
  v="$(nd_verdict_kind_node "$(nd_field "$report" kind.node_status)")"
  nd_report "$v" "kind node: $(nd_field "$report" kind.node_status)"
  v="$(nd_verdict_image_store "$(nd_field "$report" kind.crictl_images)")"
  nd_report "$v" "node image store: $(nd_field "$report" kind.crictl_images) image(s) visible to crictl"

  nd_header "CAPACITY"
  v="$(nd_verdict_disk "$(nd_field "$report" disk.vm_root_pct)")"
  nd_report "$v" "VM /: $(nd_field "$report" disk.vm_root_pct)% used, $(nd_field "$report" disk.vm_root_avail)G free on $(nd_field "$report" disk.vm_root_dev)"
  v="$(nd_verdict_disk "$(nd_field "$report" disk.node_root_pct)")"
  nd_report "$v" "kind node /: $(nd_field "$report" disk.node_root_pct)% used"
  # Said out loud rather than left to be inferred. On this estate the node's
  # /var and the VM root are the same device, so the two percentages above are
  # ONE budget — an operator freeing space "on the node" is freeing it on the
  # host, and there is no second reserve to fall back on.
  if [ "$(nd_field "$report" disk.node_var_dev)" = "$(nd_field "$report" disk.vm_root_dev)" ] \
     && [ -n "$(nd_field "$report" disk.vm_root_dev)" ]; then
    printf '    note: the kind node and the VM share %s — the two figures above are one budget, not two.\n' \
      "$(nd_field "$report" disk.vm_root_dev)"
  fi

  nd_header "KUBERNETES"
  if [ "$(nd_field "$report" k8s.reachable)" != "yes" ]; then
    nd_unknown "API server not reachable from the VM — every Kubernetes, zot and AFM check below could not run."
    return 0
  fi
  nd_pass "API server reachable"
  v="$(nd_verdict_nodes_ready "$(nd_field "$report" k8s.nodes_total)" "$(nd_field "$report" k8s.nodes_ready)")"
  nd_report "$v" "nodes: $(nd_field "$report" k8s.nodes_ready)/$(nd_field "$report" k8s.nodes_total) Ready"
  v="$(nd_verdict_count_zero_good "$(nd_field "$report" k8s.kustomizations_notready)")"
  nd_report "$v" "Flux: $(nd_field "$report" k8s.kustomizations_notready)/$(nd_field "$report" k8s.kustomizations_total) Kustomization(s) not Ready $(nd_field "$report" k8s.kustomizations_bad_names)"
  v="$(nd_verdict_count_zero_good "$(nd_field "$report" k8s.pods_bad)")"
  nd_report "$v" "pods: $(nd_field "$report" k8s.pods_bad) not Running/Completed $(nd_field "$report" k8s.pods_bad_names)"

  nd_header "ZOT REGISTRY"
  v="$(nd_verdict_zot_pod "$(nd_field "$report" zot.pod_status)" "$(nd_field "$report" zot.pod_ready)")"
  nd_report "$v" "pod: status=$(nd_field "$report" zot.pod_status) ready=$(nd_field "$report" zot.pod_ready) — note that all three of these can be green while a push fails"
  v="$(nd_verdict_zot_inode "$(nd_field "$report" zot.cache_host_inode)" "$(nd_field "$report" zot.cache_node_inode)")"
  if [ "$v" = "FAIL" ]; then
    nd_report FAIL "blob store UNLINKED: host $(nd_field "$report" zot.cache_host_path) is inode $(nd_field "$report" zot.cache_host_inode) but the node's mount resolves to inode $(nd_field "$report" zot.cache_node_inode). The directory was replaced under the mount; zot writes into a directory with no name. /v2/ will keep answering 200 and only a push will fail."
  else
    nd_report "$v" "blob store mount: host and node agree on inode $(nd_field "$report" zot.cache_host_inode)"
  fi
  v="$(nd_verdict_zot_cache_links "$(nd_field "$report" zot.cache_host_links)")"
  nd_report "$v" "blob store directory link count: $(nd_field "$report" zot.cache_host_links) (0 means unlinked but still held open)"
  v="$(nd_verdict_zot_log "$(nd_field "$report" zot.log_bytes)" "$(nd_field "$report" zot.log_defect_hits)")"
  if [ "$v" = "UNKNOWN" ]; then
    nd_report UNKNOWN "zot log: could not be read ($(nd_field "$report" zot.log_bytes) bytes). NOT a clean log — an unreadable log and a healthy one both grep to zero hits."
  else
    nd_report "$v" "zot log: $(nd_field "$report" zot.log_defect_hits) blob-store error(s) in $(nd_field "$report" zot.log_bytes) bytes"
  fi
  v="$(nd_verdict_zot_push "$(nd_field "$report" zot.push_session)" "$(nd_field "$report" zot.push_code)" "$(nd_field "$report" zot.push_head)")"
  case "$v" in
    SKIPPED) nd_unknown "blob push: SKIPPED (ND_ZOT_PUSH=0), and so was the /v2/ probe. This lane's registry has NOT been shown to work — and note that a 200 on /v2/ would not have shown it either, since that is the exact reading the unlinked-blob-store defect leaves intact." ;;
    PASS)    nd_pass "blob push: real round trip succeeded (session opened, PUT $(nd_field "$report" zot.push_code), HEAD $(nd_field "$report" zot.push_head), cleanup $(nd_field "$report" zot.push_delete))" ;;
    FAIL)    nd_fail "blob push FAILED: session=$(nd_field "$report" zot.push_session) PUT=$(nd_field "$report" zot.push_code) HEAD=$(nd_field "$report" zot.push_head), while /v2/ answered $(nd_field "$report" zot.v2_code). A serving registry that cannot store is the blob-store defect's signature." ;;
    *)       nd_unknown "blob push: could not be attempted (/v2/ -> $(nd_field "$report" zot.v2_code))" ;;
  esac

  nd_header "AFM CLUSTER IMPORT"
  printf '    cronjob: schedule=%s lastSchedule=%s  deploy readyReplicas=%s\n' \
    "$(nd_field "$report" afm.cronjob_schedule)" \
    "$(nd_field "$report" afm.cronjob_last)" \
    "$(nd_field "$report" afm.deploy_ready)"
  v="$(nd_verdict_cluster_count "$(nd_field "$report" afm.cluster_count)")"
  case "$(nd_field "$report" afm.cluster_count)" in
    NOT_DEPLOYED)
      nd_fail "afm-platform is NOT DEPLOYED on this lane. /afm/ answers 502 and every RBAC page shows its unreachable banner. This is not 'zero clusters' — nothing has been asked." ;;
    0)
      nd_fail "ZERO clusters imported. The CronJob is */30 and does not run at creation, so /afm/health can answer 200 with an empty platform for up to half an hour — every page downstream renders empty while reporting success. Force it: kubectl -n fe-k8s-afm create job afm-cluster-import-now --from=cronjob/afm-cluster-import" ;;
    *)
      nd_report "$v" "clusters imported: $(nd_field "$report" afm.cluster_count) [$(nd_field "$report" afm.cluster_ids)]" ;;
  esac
}
