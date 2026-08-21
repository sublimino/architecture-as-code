#!/usr/bin/env bash
# probe.sh — the VM-side half of the node doctor. COLLECTS, never adjudicates.
#
# This file is shipped to the lane over `gcloud compute ssh --command` and its
# entire output is a flat `key=value` report on stdout. It contains no verdicts,
# no colour and no exit-status opinions: every judgement lives in
# scripts/node-doctor/lib.sh, on the operator's machine, where it can be driven
# against a fixture without a VM.
#
# ─── Why the split, and what it buys ────────────────────────────────────────
#
# A doctor that decides inside an `ssh --command` heredoc is a doctor whose
# logic can only be tested by standing up a lane. Every branch in it is then
# either unexercised or exercised by hand once. Splitting collection from
# adjudication makes the adjudication a pure function of a text blob, so
# test/node-doctor.bats drives the REAL functions against recorded probe output
# — including the outputs that cannot be produced on demand, like an unlinked
# zot blob store.
#
# ─── The completion marker is a positive control, not decoration ────────────
#
# The LAST line is always `probe.complete=1`. `gcloud compute ssh` can truncate,
# the connection can drop, and a partial report is a report in which every
# absent key looks exactly like a key whose check found nothing. Without the
# marker "no `zot.log.defect` line" is indistinguishable from "zot is clean",
# which is the vacuous pass this repo exists to refuse. lib.sh treats a report
# without the marker as UNKNOWN throughout and says so.
#
# ─── Every fact emits a key, ALWAYS ─────────────────────────────────────────
#
# `emit` is used for everything, and an unavailable fact emits the literal
# `UNKNOWN` rather than being skipped. A skipped key and a truncated report are
# the same evidence to the reader; an explicit UNKNOWN is not.
#
# Not `set -e`: a probe that dies on the first missing binary reports nothing
# about the twenty facts after it, and a half-built lane is exactly when this is
# most worth running. Not `set -u` either — see the shell-snapshot note in the
# repo's CLAUDE.md.

set +e
set -o pipefail 2>/dev/null || true

APP_PORT="${ND_APP_PORT:-30754}"
KIND_NODE="${ND_KIND_NODE:-osramp-control-plane}"
ZOT_CACHE_HOST="${ND_ZOT_CACHE_HOST:-/opt/signalloom/zot-cache}"
ZOT_CACHE_NODE="${ND_ZOT_CACHE_NODE:-/var/local/osramp-zot-cache}"
TS_SERVE_UNIT="${ND_TS_SERVE_UNIT:-signalloom-tailscale-serve.service}"
AFM_NS="${ND_AFM_NS:-fe-k8s-afm}"
ZOT_NS="${ND_ZOT_NS:-registry}"
# 0 disables the write probe. On by default because a 200 on /v2/ is the exact
# reading the known blob-store defect leaves intact — see the block above
# probe_zot_push.
ZOT_PUSH="${ND_ZOT_PUSH:-1}"

emit() {
  # A value that is empty, or that never got assigned, becomes UNKNOWN. Newlines
  # are folded to a space so one fact is always one line — a multi-line value
  # would make the report unparseable in exactly the places it matters most.
  local key="$1" value="$2"
  value="$(printf '%s' "$value" | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
  [ -n "$value" ] || value="UNKNOWN"
  printf '%s=%s\n' "$key" "$value"
}

have() { command -v "$1" >/dev/null 2>&1; }

emit probe.schema "signalloom.node-doctor.probe/v1"
emit probe.host "$(hostname 2>/dev/null)"
emit probe.time "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
emit probe.app_port "$APP_PORT"

# ─── Tailscale ──────────────────────────────────────────────────────────────
#
# `tailscale status --json` needs root here, and `sudo -n` rather than `sudo`:
# an ssh --command has no tty, so a password prompt would hang until the
# operator's timeout rather than reporting that it could not read.
TS_JSON="$(sudo -n tailscale status --json 2>/dev/null)"
if [ -n "$TS_JSON" ] && have jq; then
  emit ts.backend   "$(printf '%s' "$TS_JSON" | jq -r '.BackendState // empty' 2>/dev/null)"
  emit ts.online    "$(printf '%s' "$TS_JSON" | jq -r '.Self.Online // empty'  2>/dev/null)"
  emit ts.dnsname   "$(printf '%s' "$TS_JSON" | jq -r '.Self.DNSName // empty' 2>/dev/null)"
  emit ts.ip        "$(printf '%s' "$TS_JSON" | jq -r '.Self.TailscaleIPs[0] // empty' 2>/dev/null)"
else
  emit ts.backend UNKNOWN; emit ts.online UNKNOWN
  emit ts.dnsname UNKNOWN; emit ts.ip UNKNOWN
fi

# The serve config, reduced to the two facts that can independently be wrong:
# WHICH hostname is served, and WHERE the `/` handler proxies to. `tailscale
# logout` wipes this while leaving the node online and correctly named, so an
# absent serve config is a specific, common and completely silent failure.
SERVE_JSON="$(sudo -n tailscale serve status --json 2>/dev/null)"
if [ -n "$SERVE_JSON" ] && have jq; then
  emit ts.serve.hostport "$(printf '%s' "$SERVE_JSON" | jq -r '.Web // {} | keys[0] // empty' 2>/dev/null)"
  emit ts.serve.proxy    "$(printf '%s' "$SERVE_JSON" | jq -r '[.Web // {} | .[] | .Handlers // {} | .["/"] // empty | .Proxy // empty] | .[0] // empty' 2>/dev/null)"
  emit ts.serve.https    "$(printf '%s' "$SERVE_JSON" | jq -r '.TCP // {} | .["443"] // {} | .HTTPS // empty' 2>/dev/null)"
else
  # An EMPTY serve config is valid JSON `{}` and is the `tailscale logout`
  # aftermath, so "no output at all" and "output with no Web key" are different
  # findings and get different values.
  emit ts.serve.hostport ABSENT; emit ts.serve.proxy ABSENT; emit ts.serve.https ABSENT
fi

# `is-enabled`, not `is-active`. The unit is a oneshot: `active` says only that
# it ran once, `enabled` is the property that survives the next reboot. Both are
# reported because a unit that is enabled and failed is not the same lane as one
# that is enabled and ran.
emit ts.serve.unit_enabled "$(systemctl is-enabled "$TS_SERVE_UNIT" 2>&1)"
emit ts.serve.unit_active  "$(systemctl is-active  "$TS_SERVE_UNIT" 2>&1)"

# ─── HTTP surface, measured ON the VM ───────────────────────────────────────
#
# Deliberately NOT the tailnet URL. Going through `tailscale serve` conflates
# two failures that need different fixes: measured on all four lanes on
# 2026-08-21, https://sl-<lane>/ answered 502 while 127.0.0.1:<app_port>
# answered 000. The 502 is serve reporting that its proxy target is dead; the
# 000 is the fact that nothing is listening. The operator's machine probes the
# tailnet separately, and lib.sh reports the pair — a 000 here with a 200 there
# would mean the URL is being served by something that is not this lane.
probe_http() {
  local path="$1"
  have curl || { printf 'UNKNOWN'; return; }
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://127.0.0.1:${APP_PORT}${path}" 2>/dev/null
}
emit http.root       "$(probe_http /)"
emit http.afm_health "$(probe_http /afm/health)"

# ─── docker + containerd ────────────────────────────────────────────────────
if have docker; then
  emit docker.server  "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  emit docker.driver  "$(docker info --format '{{.Driver}}' 2>/dev/null)"
  emit docker.images  "$(docker info --format '{{.Images}}' 2>/dev/null)"
  emit docker.running "$(docker info --format '{{.ContainersRunning}}' 2>/dev/null)"
  # `docker ps` filtered to the exact name, then matched on the leading `Up`.
  # `docker inspect .State.Running` would be the obvious call and it reports
  # true for a container that is up and wedged; `Status` carries the uptime a
  # reader needs to tell a fresh restart from a steady node.
  emit kind.node_status "$(docker ps --filter "name=^${KIND_NODE}$" --format '{{.Status}}' 2>/dev/null)"
else
  emit docker.server UNKNOWN; emit docker.driver UNKNOWN
  emit docker.images UNKNOWN; emit docker.running UNKNOWN
  emit kind.node_status UNKNOWN
fi

# crictl's view from inside the node. Distinct from docker.images: the kind node
# has its own containerd store, and "the image is on the host" has never meant
# "the kubelet can run it".
emit kind.crictl_images "$(docker exec "$KIND_NODE" crictl images -q 2>/dev/null | wc -l 2>/dev/null)"

# ─── Disk headroom ──────────────────────────────────────────────────────────
#
# The VM root and the kind node's root are reported separately AND their backing
# device is reported, because on this estate they are the same filesystem
# (measured on sl-demo-1: overlay 96G / on the node, /dev/root 96G / on the
# host, both 17% used). Printing two percentages as if they were two independent
# capacity budgets would invite an operator to free space in the wrong place.
emit disk.vm_root_pct    "$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
emit disk.vm_root_avail  "$(df -PBG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
emit disk.vm_root_dev    "$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
emit disk.node_root_pct  "$(docker exec "$KIND_NODE" df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
emit disk.node_var_dev   "$(docker exec "$KIND_NODE" df -P /var 2>/dev/null | awk 'NR==2{print $1}')"

# ─── Kubernetes ─────────────────────────────────────────────────────────────
if have kubectl && kubectl get --raw='/readyz' >/dev/null 2>&1; then
  emit k8s.reachable yes
  emit k8s.nodes_total     "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
  emit k8s.nodes_ready     "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)"
  emit k8s.kustomizations_total "$(kubectl get kustomizations -A --no-headers 2>/dev/null | wc -l)"
  # Column 4 is the READY condition on the Flux Kustomization printer columns.
  # Counting "not True" rather than grepping for False catches Unknown, which is
  # the state a Kustomization sits in while its source is failing to fetch — a
  # lane genuinely mid-failure, not merely mid-reconcile.
  emit k8s.kustomizations_notready "$(kubectl get kustomizations -A --no-headers 2>/dev/null | awk '$4!="True"' | wc -l)"
  emit k8s.kustomizations_bad_names "$(kubectl get kustomizations -A --no-headers 2>/dev/null | awk '$4!="True"{printf "%s/%s(%s) ", $1, $2, $4}')"
  emit k8s.pods_bad "$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' | wc -l)"
  emit k8s.pods_bad_names "$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"{printf "%s/%s(%s) ", $1, $2, $4}')"
else
  emit k8s.reachable no
  for k in nodes_total nodes_ready kustomizations_total kustomizations_notready \
           kustomizations_bad_names pods_bad pods_bad_names; do
    emit "k8s.${k}" UNKNOWN
  done
fi

# ─── Zot registry ───────────────────────────────────────────────────────────
#
# THE defect this section exists for: the blob store directory gets unlinked
# while the pod keeps serving. `/v2/` answers 200, the pod is 1/1 Running, every
# readiness probe is green, and only a PUSH fails — with a 500 that names
# nothing. Three independent detectors, because each one alone has a blind spot:
#
#   1. the inode agreement below   catches it with no writes at all
#   2. the zot log                 catches it only after something has tried
#   3. the real blob push          catches it, and also catches every OTHER
#                                  reason a push fails, which the first two miss
emit zot.pod_status "$(kubectl -n "$ZOT_NS" get pods -l app=zot --no-headers 2>/dev/null | awk 'NR==1{print $3}')"
emit zot.pod_ready  "$(kubectl -n "$ZOT_NS" get pods -l app=zot --no-headers 2>/dev/null | awk 'NR==1{print $2}')"

# The host directory and the path the kind node's bind mount resolves to must be
# the SAME inode. If the host directory is unlinked and recreated, the host gets
# a fresh inode while the node's mount still points at the deleted one — the
# pod writes into a directory with no name, and `readdirent` on it fails. Two
# numbers that must be equal is the cheapest possible detector for that, needs
# no writes, and works while the pod is mid-crash.
emit zot.cache_host_inode "$(stat -c '%i' "$ZOT_CACHE_HOST" 2>/dev/null)"
emit zot.cache_node_inode "$(docker exec "$KIND_NODE" stat -c '%i' "$ZOT_CACHE_NODE" 2>/dev/null)"
emit zot.cache_host_path  "$ZOT_CACHE_HOST"
# `stat -c %h` is the link count. A directory that has been unlinked while a
# mount still holds it open reports 0 here on Linux, which is the one reading
# that says "deleted but still referenced" without any inference.
emit zot.cache_host_links "$(stat -c '%h' "$ZOT_CACHE_HOST" 2>/dev/null)"

# The log scan, and the reason it emits three values rather than a boolean.
#
# `grep -c` on an empty log returns 0, exactly like `grep -c` on a healthy log.
# "The defect is absent" and "there was nothing to look at" are the same number,
# and treating that 0 as health is precisely the vacuous pass this repo refuses.
# The BYTE COUNT is emitted alongside so lib.sh can tell them apart.
ZOT_LOG="$(kubectl -n "$ZOT_NS" logs -l app=zot --tail=400 2>/dev/null)"
emit zot.log_bytes "$(printf '%s' "$ZOT_LOG" | wc -c)"
emit zot.log_defect_hits "$(printf '%s' "$ZOT_LOG" | grep -c -e 'readdirent' -e 'no such file or directory' 2>/dev/null)"

probe_zot_push() {
  # A real OCI blob round trip: open an upload session, PUT the bytes against
  # their digest, confirm the blob is readable, then delete it. Anything short
  # of the PUT is the reading the defect leaves intact.
  #
  # The port-forward is backgrounded and killed BY PID. Never by pattern: this
  # repo's Bash tooling wraps commands in `bash -c`, so a `pkill -f` pattern
  # matches the shell running it and takes out the caller.
  local port="${ND_ZOT_PF_PORT:-45997}" repo="doctor-probe/node-doctor"
  local pf loc url sep code digest blob i
  have kubectl || { emit zot.push_result UNKNOWN; return; }
  kubectl -n "$ZOT_NS" port-forward svc/zot "${port}:5000" >/dev/null 2>&1 &
  pf=$!
  for i in $(seq 1 40); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/v2/" && break
    sleep 0.25
  done
  emit zot.v2_code "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${port}/v2/" 2>/dev/null)"

  blob="signalloom-node-doctor-probe"
  digest="sha256:$(printf '%s' "$blob" | sha256sum | cut -d' ' -f1)"
  loc="$(curl -s -i -X POST --max-time 15 "http://127.0.0.1:${port}/v2/${repo}/blobs/uploads/" 2>/dev/null \
          | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')"
  emit zot.push_session "${loc:+opened}"
  case "$loc" in
    http*) url="$loc" ;;
    /*)    url="http://127.0.0.1:${port}${loc}" ;;
    *)     url="" ;;
  esac
  if [ -n "$url" ]; then
    case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
    code="$(printf '%s' "$blob" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
              -X PUT -H 'Content-Type: application/octet-stream' \
              --data-binary @- "${url}${sep}digest=${digest}" 2>/dev/null)"
    emit zot.push_code "$code"
    emit zot.push_head "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -I \
              "http://127.0.0.1:${port}/v2/${repo}/blobs/${digest}" 2>/dev/null)"
    # Cleanup is best-effort and its status is REPORTED rather than swallowed:
    # a registry that accepts pushes and refuses deletes is a registry that
    # fills the durable cache, which is a different problem worth seeing.
    emit zot.push_delete "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE \
              "http://127.0.0.1:${port}/v2/${repo}/blobs/${digest}" 2>/dev/null)"
  else
    emit zot.push_code UNKNOWN; emit zot.push_head UNKNOWN; emit zot.push_delete UNKNOWN
  fi
  kill "$pf" 2>/dev/null
  wait "$pf" 2>/dev/null
}
if [ "$ZOT_PUSH" = "1" ]; then
  probe_zot_push
else
  emit zot.v2_code SKIPPED; emit zot.push_session SKIPPED
  emit zot.push_code SKIPPED; emit zot.push_head SKIPPED; emit zot.push_delete SKIPPED
fi

# ─── AFM cluster import ─────────────────────────────────────────────────────
#
# afm-cluster-import is `*/30 * * * *` and a CronJob does not run on creation.
# So a lane can sit for half an hour with /afm/health answering 200 and ZERO
# clusters imported: the 502 is gone, the slice looks finished, and the RBAC
# pages render empty. Everything downstream reports success. The cluster COUNT
# is therefore reported as its own fact and lib.sh fails on zero — "200 with 0
# clusters" is the failure this section exists to name.
emit afm.cronjob_schedule "$(kubectl -n "$AFM_NS" get cronjob afm-cluster-import -o jsonpath='{.spec.schedule}' 2>/dev/null)"
emit afm.cronjob_last     "$(kubectl -n "$AFM_NS" get cronjob afm-cluster-import -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null)"
emit afm.deploy_ready     "$(kubectl -n "$AFM_NS" get deploy afm-platform -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"

probe_afm_clusters() {
  local port="${ND_AFM_PF_PORT:-45996}" pf body i
  have kubectl || { emit afm.cluster_count UNKNOWN; return; }
  kubectl -n "$AFM_NS" get deploy afm-platform >/dev/null 2>&1 || {
    # NOT zero. A platform that is not deployed has not imported zero clusters,
    # it has not been asked — and reporting 0 here would send the reader to the
    # CronJob instead of to the missing deployment.
    emit afm.cluster_count NOT_DEPLOYED
    return
  }
  kubectl -n "$AFM_NS" port-forward svc/afm-platform "${port}:8000" >/dev/null 2>&1 &
  pf=$!
  for i in $(seq 1 40); do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/health" && break
    sleep 0.25
  done
  emit afm.health_code "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${port}/health" 2>/dev/null)"
  body="$(curl -s --max-time 15 "http://127.0.0.1:${port}/clusters" 2>/dev/null)"
  if [ -n "$body" ] && have jq; then
    # The endpoint has been seen returning both a bare array and an object with
    # a `clusters` key. Asking for both and taking whichever answers means a
    # shape change reads as a count, not as a crash.
    emit afm.cluster_count "$(printf '%s' "$body" | jq -r 'if type=="array" then length elif type=="object" then ((.clusters // .items // []) | length) else empty end' 2>/dev/null)"
    emit afm.cluster_ids "$(printf '%s' "$body" | jq -r '[.. | objects | .id? // empty] | join(",")' 2>/dev/null)"
  else
    emit afm.cluster_count UNKNOWN; emit afm.cluster_ids UNKNOWN
  fi
  kill "$pf" 2>/dev/null
  wait "$pf" 2>/dev/null
}
probe_afm_clusters

# ─── The completion marker ──────────────────────────────────────────────────
# Last line, unconditionally. Its ABSENCE is the signal — see the header.
emit probe.complete 1
