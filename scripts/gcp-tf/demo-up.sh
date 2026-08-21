#!/usr/bin/env bash
#
# demo-up.sh — the LOCAL side of the GCP demo lane.
#
#   demo-up.sh up          # deliver this checkout, build the estate, test it
#   demo-up.sh test        # re-run the tests only, against a standing cluster
#   demo-up.sh status      # VM state and the verdict on disk, read-only
#   demo-up.sh payload F   # build the delivery tarball at F and stop
#
#   --- The TWO test surfaces ---
#   demo-up.sh test          # LOCAL-ON-VM: the full suite, over 127.0.0.1
#   demo-up.sh ts-test       # REMOTE: the transport, over the tailnet. No creds.
#   demo-up.sh test-surfaces # did BOTH of the above actually run? Asserted.
#
#   --- Tailscale, the PRIMARY access path ---
#   demo-up.sh ts-up       # serve the dashboard on the tailnet, print the URL
#   demo-up.sh ts-status   # node, MagicDNS name, tailnet IP, dashboard health
#   demo-up.sh ts-logout   # release the tailnet name before a destroy.
#                          # REFUSES on a live serve config; --force overrides.
#   demo-up.sh funnel-up   # additionally expose it to the PUBLIC internet
#   demo-up.sh funnel-down # remove the public listener, keep the tailnet one
#
#   --- IAP, the fallback ---
#   demo-up.sh connect     # open the IAP tunnel and print what a human needs
#   demo-up.sh public      # publish, prove a 200, then hand over the URL
#   demo-up.sh public-down # stop the VM-side forward
#
# Terraform builds a hardened, IAP-only VM with no external IP.
# scripts/gcp-tf/demo-pipeline.sh runs ON that VM and stands the estate up.
# This file is what carries the code across, starts that pipeline, streams it
# back, collects the report, and decides whether the run passed.
#
# ─── One entry point for every access method ────────────────────────────────
#
# ts-up, funnel-up, connect and public all forward to the SAME thing: the
# dashboard's nginx at dashboard-signalloom:8080 in fe-signalloom. So does
# scripts/public-tunnel.sh, which has always done it this way. See the
# DASHBOARD_* constants below for what that buys and what it replaced.
#
# Each of them publishes a browser-visible ORIGIN and claims it through
# scripts/lib/dex-origin.sh, because Dex has exactly one issuer and the loser of
# an unclaimed race presents as a broken login rather than as a collision. IAP is
# not special here any more — it claims http://localhost:<port> like everything
# else, where http is safe because the origin is loopback and the IAP tunnel is
# the confidentiality boundary.
#
# It is a SIBLING of scripts/ci/gcp-ci.sh and scripts/ci/gcp-tf-ci.sh. That
# first one owns the shared signalloom-ci VMs and their kind pipeline; the
# second owns the per-lane Terraform CI runners. This one owns the human-facing
# demo VM. None of the three reads or writes another's state, and gcp-ci.sh is
# frozen (test/fixtures/gcp-tf-ci/untouched-scripts.sha256 pins its digest).
#
# ─── Nothing is hardcoded; everything comes from the hand-off ───────────────
#
# deploy/gcp/<env>.handoff.json (schema signalloom.gcp.handoff/v1, written by
# `make gcp-tf-handoff`) carries project_id, zone, instance_name, app_port and
# the service accounts. Every value this script needs is read from there. A
# project id or a zone typed into a script is a value that goes stale silently
# and names the wrong estate at the worst possible moment.
#
# ─── ssh-agent ──────────────────────────────────────────────────────────────
#
# SSH_AUTH_SOCK is emptied before anything can call `gcloud compute ssh`. A
# populated agent makes IAP SSH fail with "agent refused operation", which reads
# as a VM provisioning fault and is a purely local one. That misdiagnosis has
# cost real debugging time on this project twice — on 2026-08-03 it burned ten
# minutes pointed at a VM that had finished provisioning in 124s.
#
# ─── Impersonation is not optional here, and not for the usual reason ───────
#
# Everywhere else in this estate impersonation exists because the human's own
# principal is roles/editor and cannot create IAM-shaped resources. Here it
# exists because the operator is EXTERNAL to the owning organisation, so
# `gcloud compute ssh` demands roles/compute.osLoginExternalUser — a role the
# operator cannot grant themselves. An org-INTERNAL service account is not
# subject to that rule, so every gcloud call below runs as one. This is
# measured, not theoretical: without it the SSH fails at the OS Login step with
# a permission error that names the external-user role, and the obvious next
# move (grant it) is one the operator has no authority to make.
#
# ─── A missing verdict is never a pass ──────────────────────────────────────
#
# On 2026-08-13 an absent summary.json was read as a pass twice in one day. The
# classifier below has exactly four answers — PASS, FAIL, ABORTED, STALE — and
# only the first of them exits 0. Absence of a report is ABORTED. A report
# stamped with a different commit than the one delivered is STALE, which is also
# an abort: it describes some other run.

set -euo pipefail

# ── Injectable boundaries ───────────────────────────────────────────────────
#
# Every external dependency is overridable, which is what makes the whole
# control flow exercisable by test/terraform-demo-driver.bats against stubs on
# PATH, with no cloud access and no credentials. A component that can only be
# tested against the real system is a component nobody tests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GCP_TF_DEMO_REPO_ROOT:-}"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# The shared waiting primitives. Sourced from SCRIPT_DIR, not REPO_ROOT: a test
# points REPO_ROOT at a scratch tree containing only a copy of this driver, and
# resolving the library from there would find nothing.
#
# Hard-required rather than optional. A `command -v wait_reachable || fallback`
# here would give this file two waiting implementations, only one of which is
# ever exercised — and the untested one would be the one that ran on the day the
# vendored copy went missing. wait.sh is committed at scripts/lib/wait.sh; if it
# is absent, that is a broken checkout and saying so immediately beats waiting
# with a silently different set of deadlines.
# `source=` documents the target for `shellcheck -x`; SC1091 is disabled because
# the suite runs shellcheck WITHOUT -x and asserts empty output, and an
# unfollowed source is an info-level note rather than a finding. Same pairing as
# scripts/olly-adk-web.sh.
# shellcheck source=../lib/wait.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/wait.sh"

# ─── This file depends on _wait_retry, which is wait.sh's PRIVATE engine ─────
#
# Deliberate, and the reason is the injectable-boundary rule. `wait_reachable`
# is a three-line convenience wrapper whose probe string hardcodes a literal
# `curl`, so calling it BYPASSES this file's CURL_BIN injection point and sends
# the health probe to the real network no matter what a test injected. That is a
# component that can only be tested against the real system, which is exactly
# what the boundary rule forbids.
#
# `_wait_retry` takes the command as an argument, so the probe can be built from
# CURL_BIN while every piece of machinery worth having — deadline, exponential
# backoff with jitter, the per-attempt hang fence, the soft warning at 60%, the
# heartbeat and the WAIT_STAT line — lives in _wait_retry and is inherited
# unchanged. Nothing is reimplemented here.
#
# The cost is a dependency on an underscore-prefixed name in a VENDORED file
# ("DO NOT EDIT HERE. Source of truth: ~/.andy_sync/includes/wait.sh"). A
# re-vendor that renames or removes it would otherwise fail as
# "_wait_retry: command not found" at the moment of a health check, i.e. during
# a demo. Asserted here instead, at load, so the message names the cause.
#
# The generically right fix is a WAIT_CURL override upstream in wait.sh, in the
# same family as WAIT_ATTEMPT_TIMEOUT and WAIT_DEADLINE_SCALE. That is a change
# to a shared library and needs Andy's say-so, so it is proposed rather than
# taken; this guard is what makes the interim coupling safe rather than silent.
if ! declare -F _wait_retry >/dev/null 2>&1; then
  printf 'demo-up: %s defines no _wait_retry.\n' "${SCRIPT_DIR}/../lib/wait.sh" >&2
  printf '  This file drives that function directly so the health probe can go\n' >&2
  printf '  through CURL_BIN rather than wait_reachable'"'"'s hardcoded curl.\n' >&2
  printf '  A re-vendor has renamed or removed it. See the note above this check.\n' >&2
  exit 2
fi

ENV_KEY="${GCP_TF_DEMO_ENV:-${ENV:-}}"
HANDOFF_DIR="${GCP_TF_HANDOFF_DIR:-${REPO_ROOT}/deploy/gcp}"
GCLOUD_CMD="${GCP_TF_DEMO_GCLOUD:-gcloud}"
TAR_CMD="${GCP_TF_DEMO_TAR:-tar}"
GIT_CMD="${GCP_TF_DEMO_GIT:-git}"

# Where the delivered checkout and its reports live ON THE VM. Both are part of
# the contract with demo-pipeline.sh (chunk C) and are stated in
# docs/gcp-demo/RUNBOOK.md § "The pipeline contract".
#
# /opt/signalloom is the path an unpack was actually measured working at, not a
# path this file invented.
REMOTE_WORK_DIR="${GCP_TF_DEMO_REMOTE_DIR:-/opt/signalloom/repo}"
REMOTE_REPORT_DIR="${GCP_TF_DEMO_REMOTE_REPORT_DIR:-/opt/signalloom/reports}"
REMOTE_LOG="${GCP_TF_DEMO_REMOTE_LOG:-/opt/signalloom/demo-pipeline.log}"

# The signing keypair, deliberately a SIBLING of the checkout rather than a
# directory inside it.
#
# ─── The defect this removes ────────────────────────────────────────────────
#
# `.keys/` is gitignored, so `git archive HEAD` cannot carry it — that is the
# tracked-files-only property build_payload depends on and it is correct. The
# consequence is that the VM has no keypair until `make signing-keys` mints one,
# and signing-keys writes into $(KEYS_DIR), which resolves to the delivered
# tree's own `.keys/`. deliver_code opens with `sudo rm -rf $REMOTE_WORK_DIR`.
#
# So every run destroyed the previous run's keypair and minted a fresh one:
#
#   run 1  mint key A -> push signed by A -> bootstrap-local installs A into
#          flux-system/cosign-pub. Consistent, and it works.
#   run 2  rm -rf the tree (and key A with it) -> mint key B -> push-local's
#          trust preflight finds the cluster trusting A and refuses.
#
# Captured on sl-demo-1-vm 2026-08-20: cluster afddf5a2626d87bf, delivered tree
# 2575de005cbcba9e. A first run always worked and every re-run could not, which
# is why a retry failed DIFFERENTLY from the original and misdirected the
# diagnosis.
#
# ─── Why a sibling, and why the key outlives the cluster ────────────────────
#
# Three lifetimes are in play and the bug was conflating them. The TREE is
# rebuilt on every delivery. The CLUSTER survives across runs. The KEYPAIR's
# only job is to make the signer and the verifier agree, and the verifier is the
# cluster's flux-system/cosign-pub secret — so the keypair must outlive the
# tree, which is the shortest of the three and the one it was tied to.
#
# It also outlives the CLUSTER, which is safe for one specific reason worth
# stating: trust is always derived key -> cluster, never the reverse.
# `bootstrap-local` installs the public half into whatever cluster is standing,
# so a recreated cluster re-derives its trust from the surviving key and the two
# agree again. The opposite direction is not merely discouraged, it is
# impossible — the cluster holds only the PUBLIC half, so a cluster can never
# restore the ability to sign. Confirmed empirically on demo-1: the private half
# of afddf5a2 existed nowhere on the box once its tree was wiped.
#
# Rotating the key whenever the cluster is recreated was therefore rejected. It
# buys nothing on an estate whose private key never leaves the VM, and every
# rotation reopens exactly the mismatch window this change closes.
#
# ─── The property that must not be lost ─────────────────────────────────────
#
# This path must stay OUTSIDE $REMOTE_WORK_DIR. Nested under it, deliver_code's
# `rm -rf` deletes it again and the defect returns silently — a re-run would
# mint over a key the cluster already trusts and fail exactly as before. It is
# an override, so that is one environment variable away; assert_keys_dir_is_
# durable() below refuses rather than trusting the default to stay correct, and
# test/gcp-demo-keys-persistence-mutation-proof.sh proves that refusal can fire.
REMOTE_KEYS_DIR="${GCP_TF_DEMO_REMOTE_KEYS_DIR:-/opt/signalloom/keys}"

# EMPTY by default, meaning "run as whoever OS Login logged us in as".
#
# v1 hardcodes `sudo -u ci` because that VM provisions a `ci` account. This lane
# has no such guarantee: the only account proven to exist on the demo VM is the
# one OS Login creates for the impersonated operator SA, and `sudo -u <someone
# who does not exist>` fails with a message about the user, which reads as a
# permissions problem rather than as a wrong assumption in this file. Set it
# when chunk B's VM profile guarantees a service account to drop to.
REMOTE_USER="${GCP_TF_DEMO_REMOTE_USER:-}"

# The pipeline, relative to the repo root. Overridable so the tests can drive a
# fixture tree, and so a rename on chunk C's side is a one-variable change here
# rather than a silent 127 on the VM.
PIPELINE_REL="${GCP_TF_DEMO_PIPELINE:-scripts/gcp-tf/demo-pipeline.sh}"

# ─── Per-lane, because four lanes rotate this directory concurrently ────────
#
# This defaulted to a single shared ${REPO_ROOT}/demo-reports for every lane.
# One lane at a time, that is fine. Four lanes at once, it is a data race with
# no interlock: prepare_report_dir does `rm -rf ${REPORT_DIR}.prev` then
# `mv $REPORT_DIR ${REPORT_DIR}.prev`, so a lane starting up renames the
# directory out from under three lanes already writing into it.
#
# Measured 2026-08-21 on the first genuine four-lane parallel bring-up. Three of
# four died and the two spellings of the same race are worth recording, because
# neither names the cause:
#
#   mv: cannot stat '.../demo-reports': No such file or directory
#   mv: cannot stat '.../demo-reports/.summary.json.tmp': No such file or directory
#
# The first is a lane whose directory was rotated away before it could rotate
# it; the second is a lane whose summary was written into a directory that had
# already become .prev. Both read as a broken driver rather than as contention.
#
# The clash audit in terraform/notes/j-lane-parallelism.md enumerated the shared
# mutable paths it could find by inspection — the terraform lockfile, the plan
# file, the state prefix, the local tunnel port — and this was not among them,
# because the variable was already overridable and therefore looked per-lane.
# Overridable is not the same as overridden. Only running four lanes at once
# found it, which is the whole argument for doing so.
REPORT_DIR="${GCP_TF_DEMO_REPORT_DIR:-${REPO_ROOT}/demo-reports/${ENV_KEY}}"
SUMMARY_NAME="${GCP_TF_DEMO_SUMMARY_NAME:-summary.json}"

# How long cmd_connect waits for the tunnel to bind before it stops waiting and
# starts diagnosing. PORT_PROBE is injectable so the whole connect path is
# exercisable without a real listener; the default needs no external binary.
TUNNEL_WAIT_SECONDS="${GCP_TF_DEMO_TUNNEL_WAIT_SECONDS:-20}"
PORT_PROBE="${GCP_TF_DEMO_PORT_PROBE:-default_port_probe}"

default_port_probe() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# ── The PRE-FLIGHT probe, which asks the opposite question ──────────────────
#
# Deliberately a SECOND injection point rather than a reuse of PORT_PROBE, and
# the split is the whole point rather than duplication.
#
# PORT_PROBE runs AFTER the tunnel is launched and asks "is the port bound yet?"
# — success means proceed. This one runs BEFORE anything is launched and asks
# "is the port ALREADY taken?" — success means REFUSE. Same syscall, opposite
# polarity, opposite moment. A single injectable cannot express both: the
# suites' `probe-ok` stub answers "bound" unconditionally, which is correct for
# the post-launch question and would make this guard refuse every run.
PREFLIGHT_PORT_PROBE="${GCP_TF_DEMO_PREFLIGHT_PORT_PROBE:-default_port_probe}"

# ── Why a local port collision is a WRONG-LANE bug, not an inconvenience ────
#
# Every lane in this estate publishes the same app_port (30754 for demo-1,
# demo-2, ci-1 and ci-2 alike — it is one value in the shared tfvars), and
# local_tunnel_port() defaults the LOCAL end to that same number. So all four
# lanes want to bind localhost:30754 on the operator's machine, and only one of
# them can have it.
#
# Left unguarded that does NOT present as "address already in use". It presents
# as success on the wrong cluster, by this exact sequence:
#
#   1. lane A's tunnel is already bound on localhost:30754.
#   2. the operator runs `connect` for lane B. gcloud is launched in the
#      background and takes several seconds to authenticate and impersonate
#      before it ever attempts its bind.
#   3. the post-launch wait loop checks `kill -0` (the process is alive — it is
#      still starting up) and then probes the port. The probe SUCCEEDS, because
#      lane A is listening on it.
#   4. `bound=1`, and the driver reports "tunnel is UP on localhost:30754".
#
# The operator is now doing lane B's work against lane A's cluster, and nothing
# in the output says so. Worse, step 2 is reached only after `dex_origin apply`
# has already repointed lane B's Dex issuer at an origin that lane A is serving
# — so a refused run would still have mutated the cluster.
#
# Hence: refused here, before the origin claim and before any cloud call.
# `require_no_conflicting_origin` cannot catch this — it asks lane B's own
# cluster whether another ACCESS METHOD holds its issuer, and lane A is a
# different cluster that it never speaks to.
# ── Proving the socket is OURS, which is a different claim from "free" ──────
#
# require_local_port_free below closes the common case and does not close the
# race. Between its check and gcloud's bind there is a window — several seconds
# wide, because gcloud spends that long authenticating before it binds — in
# which another lane can take the port. The wait loop then probes, the other
# lane answers, and we are back to reporting a healthy tunnel on the wrong
# cluster. A per-lane port narrows that window; it does not remove it, and it
# removes nothing at all if two operators pick the same number.
#
# So the binding question is not "is something listening" but "is the thing
# listening the tunnel I just started for THIS lane". That is answerable
# locally and exactly: `gcloud compute start-iap-tunnel` was invoked with this
# lane's INSTANCE_NAME, so if the socket belongs to that process, the far end is
# this lane by construction.
#
# ─── Why provenance, and what far-side attestation can and cannot do here ───
#
# The complementary property is far-side attestation: ask through the tunnel who
# answered, and compare. This estate already does exactly that on ONE path —
# cmd_ts_test's R3 fetches Dex's discovery document and requires
# `.issuer` to equal the origin it asked for.
#
# That works over the tailnet and cannot work over IAP, for precisely the reason
# this whole guard exists. The tailnet origin is https://sl-<env>.<tailnet>.ts.net,
# which embeds the lane key, so a wrong lane answers with an issuer naming
# ITSELF and the mismatch is caught. The IAP origin is http://localhost:<port>,
# and every lane defaults to the SAME port — so the issuer string is identical
# across all four lanes and attests to nothing at all. The colliding port does
# not merely cause the hijack; it also disarms the one identity check the estate
# already owns.
#
# Nothing else nginx serves distinguishes a lane: HEALTH_PATH (/readyz) returns
# a bare status code, and the SPA, Dex and the API are byte-identical across
# lanes because they are built from the same images.
#
# So there are two ways to earn far-side attestation over IAP, and they are
# worth stating because one of them is nearly free:
#
#   * make the local port per-lane, which makes the IAP origin lane-specific
#     and brings the EXISTING Dex issuer check into range on this path too;
#   * or have nginx return the environment key in a header, which is
#     path-agnostic and covers both transports at once.
#
# Neither replaces this check, and the ordering matters: attestation is
# TESTIMONY from whatever is on the other end of the socket, while ownership is
# PROVENANCE of the socket itself. A confused or hostile far side can say
# anything; a socket's owning pid cannot. Ownership is also the only one of the
# two that is available before a single byte is exchanged.
LISTENER_OWNER_PROBE="${GCP_TF_DEMO_LISTENER_OWNER_PROBE:-default_listener_owner}"

# Prints the pids holding a LISTENING socket on port $1, one per line.
#
# `ss` reports `pid=` only for sockets the calling user owns, which is exactly
# the case that matters here: another lane's tunnel, started by the same
# operator at the same terminal. A socket owned by another user prints no pid,
# which this treats as "not ours" — the fail-closed direction.
default_listener_owner() {
  ss -ltnpH "sport = :$1" 2>/dev/null |
    grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# True when $1 is $2, or any descendant of $2.
#
# The walk is not ceremony. `$!` is the pid of the backgrounded `env`, which
# execs gcloud, which is a wrapper that runs Python — so the pid holding the
# socket is routinely a descendant rather than the pid we recorded. Comparing
# only the two numbers would reject our own tunnel every time.
#
# `ps -o ppid=`, never `awk` over /proc/PID/stat: the comm field in stat is
# parenthesised and may contain spaces, so positional parsing silently reads
# the wrong column for any process whose name has one.
pid_is_descendant_of() {
  local pid="$1" want="$2" hops=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$hops" -lt 32 ]; do
    [ "$pid" = "$want" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    hops=$((hops + 1))
  done
  return 1
}

# Refuse to hand over a tunnel whose socket we cannot show we own.
assert_tunnel_is_ours() {
  local want="$1" tunnel_pid="$2" who="$3" owners owner

  owners="$("$LISTENER_OWNER_PROBE" "$want" 2>/dev/null || true)"

  for owner in $owners; do
    pid_is_descendant_of "$owner" "$tunnel_pid" && return 0
  done

  cat >&2 <<EOF
demo-up: REFUSING — localhost:${want} is not served by this run's tunnel.

  wanted by:     ${who} (ENV=${ENV_KEY})
  this lane:     ${INSTANCE_NAME}
  our tunnel:    pid ${tunnel_pid}
  socket owner:  ${owners:-<none reported>}

  Something bound this port that this invocation did not start, so the port
  answered our readiness probe on behalf of a process we do not own. In a
  multi-lane session that is another lane's tunnel, and continuing would hand
  you a dashboard, a login and a full test run against a DIFFERENT cluster —
  reporting success the whole way.

  This is the check that does not care whether the ports were chosen well. A
  per-lane port makes the collision unlikely; this makes acting on one
  impossible.

  If '<none reported>' above, the socket belongs to another user or 'ss' is
  unavailable — both are refusals here rather than assumptions, because the
  question is whether we can PROVE the tunnel is ours, not whether we can find
  a reason it might be.

      ss -ltnp 'sport = :${want}'
EOF
  return 1
}

# ── The ONE far-side identity primitive, shared by every access path ────────
#
# Ownership (above) is inherently local: it proves the socket on THIS machine
# belongs to the tunnel we started. It cannot be made path-agnostic, because the
# tailnet path has no local socket of ours to attribute — the connection goes
# over the tailnet to a remote node. Anything claiming to generalise it would be
# a different mechanism wearing the same name.
#
# What DOES generalise is the other half: does the far side agree it is this
# lane's origin. cmd_ts_test's R3 has been doing exactly that — fetching Dex's
# discovery document and requiring `.issuer` to equal the origin it asked for.
# This is that check, extracted so there is ONE definition of the rule rather
# than one per transport. A second copy bolted onto a second path is how this
# model drifts, and drift in an identity check is the failure it exists to stop.
#
# ─── THREE answers, not a boolean, and the third is the point ───────────────
#
#   0  VERIFIED      the far side named this lane's origin
#   1  MISMATCH      it named a different one — refuse
#   2  CANNOT-VERIFY the origin cannot distinguish lanes, so a match proves
#                    nothing and reporting one would be a lie
#
# The third exists because of the defect this whole branch is about. Over the
# tailnet the origin is https://sl-<env>.<tailnet>.ts.net and embeds the lane
# key, so a wrong lane answers with an issuer naming ITSELF and the mismatch is
# caught. Over IAP the origin is http://localhost:<port>, and every lane
# defaults to the same port — so the string is identical across all four lanes,
# `got == want` holds no matter which lane answered, and a naive reuse of this
# check on that path would return VERIFIED for a hijacked socket.
#
# That is a vacuous pass, and a vacuous pass in an identity check is worse than
# no check: it converts "we do not know" into "we have confirmed". So the origin
# is tested for lane-distinguishing power FIRST, and the answer is refused
# rather than faked.
LANE_IDENTITY_DETAIL=""

# An origin can distinguish lanes only if the lane key appears in it.
#
# Deliberately a property of the ORIGIN rather than a list of known-bad hosts.
# A denylist of "localhost" would pass the day someone introduces a second
# non-distinguishing origin, and the question is not "is this localhost" but
# "could this string have come from another lane".
lane_origin_is_distinguishing() {
  case "$1" in
    *"$ENV_KEY"*) return 0 ;;
  esac
  return 1
}

# Injectable, like PORT_PROBE and LISTENER_OWNER_PROBE, and for the same reason:
# every branch of the identity decision has to be drivable with no cluster, no
# credentials and no network. A check whose failure path can only be seen
# against a real estate is a check nobody ever sees fail.
FAR_SIDE_ISSUER_PROBE="${GCP_TF_DEMO_ISSUER_PROBE:-far_side_issuer}"

# Fetch the issuer Dex publishes at an origin. Prints it, or nothing.
# Separated so the comparison is testable without a cluster.
far_side_issuer() {
  local origin="$1" body
  body="$(mktemp "${TMPDIR:-/tmp}/demo-issuer.XXXXXX.json")"
  local code
  code="$("$CURL_BIN" -sS -o "$body" -w '%{http_code}' --max-time 15 \
    "${origin}/dex/.well-known/openid-configuration" 2>/dev/null || printf '000')"
  if [ "$code" = "200" ]; then
    jq -r '.issuer // ""' "$body" 2>/dev/null || printf ''
  fi
  rm -f "$body"
}

assert_far_side_lane_identity() {
  local origin="$1" want got

  if ! lane_origin_is_distinguishing "$origin"; then
    LANE_IDENTITY_DETAIL="origin ${origin} does not contain the lane key '${ENV_KEY}', so it is identical across lanes and cannot attest to one"
    return 2
  fi

  want="${origin}/dex"
  got="$("$FAR_SIDE_ISSUER_PROBE" "$origin")"

  if [ -z "$got" ]; then
    LANE_IDENTITY_DETAIL="no issuer returned at ${origin} — Dex discovery did not answer, so identity is unconfirmed rather than wrong"
    return 2
  fi
  if [ "$got" = "$want" ]; then
    LANE_IDENTITY_DETAIL="$got"
    return 0
  fi
  LANE_IDENTITY_DETAIL="the estate at ${origin} issues for '${got}', not '${want}'"
  return 1
}

# The caller-facing wrapper: fatal on MISMATCH, explicit on CANNOT-VERIFY.
#
# CANNOT-VERIFY is a warning rather than a refusal, and that is a judgement
# rather than a shrug. On the IAP path with the default port it is the NORMAL
# state today, so failing on it would refuse every correct single-lane run —
# and a guard that refuses valid input is one somebody deletes. Ownership is
# what actually defends that path; this is the second layer, and it becomes
# load-bearing the moment the local port is per-lane.
require_far_side_lane_identity() {
  local origin="$1" who="$2" rc=0

  assert_far_side_lane_identity "$origin" || rc=$?

  case "$rc" in
    0)
      log "far-side identity CONFIRMED: ${LANE_IDENTITY_DETAIL}"
      return 0
      ;;
    2)
      warn "far-side identity UNVERIFIED for ${ENV_KEY}: ${LANE_IDENTITY_DETAIL}"
      warn "  a per-lane local port (GCP_TF_DEMO_LOCAL_PORT) makes this checkable — see require_local_port_free"
      return 0
      ;;
  esac

  cat >&2 <<EOF
demo-up: REFUSING — the estate answering here is not ${ENV_KEY}.

  wanted by: ${who} (ENV=${ENV_KEY})
  origin:    ${origin}
  detail:    ${LANE_IDENTITY_DETAIL}

  Dex publishes the origin its own lane was configured for, so an issuer naming
  a different origin means a different lane answered. Continuing would run this
  lane's work against that one and report success.
EOF
  exit 9
}

require_local_port_free() {
  local want="$1" who="$2"

  "$PREFLIGHT_PORT_PROBE" "$want" || return 0

  cat >&2 <<EOF
demo-up: REFUSING — localhost:${want} is already in use.

  wanted by:  ${who} (ENV=${ENV_KEY})
  local port: ${want}

  Something on this machine is already listening there. In a multi-lane session
  that is almost certainly ANOTHER LANE's tunnel: every lane in this estate
  publishes the same app_port, and the local end of the tunnel defaults to it,
  so demo-1, demo-2, ci-1 and ci-2 all want this one number.

  This is refused rather than survived because the failure it prevents is
  silent. The tunnel would be launched, the wait loop would probe this port,
  the OTHER lane's listener would answer, and this run would report a healthy
  tunnel while serving you a different cluster's dashboard.

  Give this lane a local port of its own — the remote end is fixed by the
  estate's firewall rule, the local end is whatever this machine has free:

      GCP_TF_DEMO_LOCAL_PORT=$((want + 1)) make ${who} ENV=${ENV_KEY}

  Or close whatever holds it:

      ss -ltnp 'sport = :${want}'
EOF
  exit 7
}

SSH_WAIT_ATTEMPTS="${GCP_TF_DEMO_SSH_WAIT_ATTEMPTS:-30}"
SSH_WAIT_INTERVAL="${GCP_TF_DEMO_SSH_WAIT_INTERVAL:-5}"
TIMEOUT_MINUTES="${GCP_TF_DEMO_TIMEOUT_MINUTES:-90}"
TIMEOUT_CMD="${GCP_TF_DEMO_TIMEOUT:-timeout}"

# ── The single entry point ──────────────────────────────────────────────────
#
# Every access path in this estate — IAP here, ngrok in scripts/public-tunnel.sh,
# Tailscale and Funnel below — forwards to the dashboard's nginx and nothing
# else. nginx serves the built SPA and proxy_passes /dex/, /api/, /afm/, /demo/,
# /fleet/ and /supercred-api/ to their in-cluster backends, so it is a
# SAME-ORIGIN front door for the whole application INCLUDING OIDC.
#
# This lane used to tunnel to the Envoy Gateway instead, and every painful thing
# about the IAP path descended from that one choice:
#
#   * the tunnel was pinned to 30754, because Dex's callback was pinned to it
#   * the operator had to add `127.0.0.1 dashboard.osramp.acme.local` to
#     /etc/hosts, because Envoy routes by SNI
#   * any other hostname 404'd, because Envoy matches the request's :authority
#     against `*.osramp.acme.local` — measured: identical SNI, Host:
#     dashboard.osramp.acme.local -> 200, Host: <node>.ts.net -> 404
#
# All three disappear here, and they disappear for the same reason rather than
# by three separate fixes: nginx routes by PATH and terminates nothing, so there
# is no name to match and no certificate to satisfy. scripts/public-tunnel.sh
# has always done it this way and says so in its own header; this is that
# pattern generalised to every method.
#
# Envoy is untouched and still deployed. It remains the Gateway API ingress and
# part of what the product demonstrates — it is simply no longer what a human
# browses through.
DASHBOARD_NAMESPACE="${GCP_TF_DEMO_DASHBOARD_NAMESPACE:-fe-signalloom}"
DASHBOARD_SERVICE="${GCP_TF_DEMO_DASHBOARD_SERVICE:-dashboard-signalloom}"
DASHBOARD_SERVICE_PORT="${GCP_TF_DEMO_DASHBOARD_SERVICE_PORT:-8080}"

# Dashboard hostname used by the VM-side pipeline's human handover. Acceptance
# retains its own Envoy Gateway origin and TLS/SNI contract internally.
DASHBOARD_HOST="${GCP_TF_DEMO_DASHBOARD_HOST:-dashboard.osramp.acme.local}"

# The LOCAL port a browser will type, and therefore the port the origin carries.
#
# Defaults to app_port so both ends of the tunnel match, which is the least
# surprising thing for anyone reading `--local-host-port`. It is overridable
# because it no longer HAS to match: nothing pins the callback to a particular
# port now that Dex's redirect URI follows PUBLIC_ORIGIN, and 8080 is a heavily
# contended port on a developer's laptop. Whatever it is set to, the origin
# follows it — that is the invariant, and iap_origin is the one place that
# keeps it.
local_tunnel_port() {
  printf '%s' "${GCP_TF_DEMO_LOCAL_PORT:-$APP_PORT}"
}

# The origin a browser sees on the IAP path.
#
# http, deliberately and not by oversight: nginx serves cleartext on 8080 and
# the IAP tunnel is the confidentiality boundary — Google authenticates the
# caller against roles/iap.tunnelResourceAccessor before a byte reaches it.
# dex-origin.sh accepts http:// on loopback for exactly this reason and refuses
# it on any routable host, so this construction cannot quietly turn into a
# cleartext origin somebody else can intercept.
iap_origin() {
  printf 'http://localhost:%s' "$(local_tunnel_port)"
}

DEMO_LOGIN_USER="${GCP_TF_DEMO_LOGIN_USER:-demo-user@signalloom.local}"
DEMO_LOGIN_PASS="${GCP_TF_DEMO_LOGIN_PASS:-demo-user}"

# An ssh-agent socket in the environment breaks IAP SSH. Emptied here, before
# any code path can reach `gcloud compute ssh`. Exported so a stub gcloud in the
# tests observes the same value the real one would — which is what makes this a
# behavioural assertion rather than a grep.
export SSH_AUTH_SOCK=

# Word-split deliberately: this is a command plus its flags supplied by the
# operator (e.g. "gcloud --verbosity=error"), not user input.
read -r -a GCLOUD <<<"$GCLOUD_CMD"

# Resolved from the hand-off in load_handoff.
PROJECT_ID=""
ZONE=""
INSTANCE_NAME=""
APP_PORT=""
OPERATOR_SA=""
HANDOFF_FILE=""

RUN_COMMIT="unknown"
RUN_BRANCH="unknown"
RUN_STARTED_AT=""
RUN_PHASE="not-started"

die() {
  printf 'demo-up: %s\n' "$*" >&2
  exit 2
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'demo-up: WARNING — %s\n' "$*" >&2; }

# ── Configuration, entirely from the hand-off ───────────────────────────────

require_env() {
  [ -n "$ENV_KEY" ] || die "ENV is required. Usage: ENV=demo-1 $(basename "$0") ${1:-up}"
  case "$ENV_KEY" in
    demo-[1-9] | demo-[1-9][0-9]* | ci-[1-9] | ci-[1-9][0-9]*) ;;
    *) die "ENV='${ENV_KEY}' is not a valid environment key (^(demo|ci)-[1-9][0-9]*\$)" ;;
  esac
}

# Read every value this script needs out of deploy/gcp/<env>.handoff.json.
#
# The absent-file message names the target that produces it. The alternative —
# "no such file" — sends a reader hunting for a file that was never meant to be
# written by hand, and the fields in it are derived from `terraform output`, so
# hand-writing one produces a driver pointed at an estate that does not exist.
load_handoff() {
  HANDOFF_FILE="${HANDOFF_DIR}/${ENV_KEY}.handoff.json"

  if [ ! -f "$HANDOFF_FILE" ]; then
    cat >&2 <<EOF
demo-up: no hand-off for ENV=${ENV_KEY}.

  Expected: ${HANDOFF_FILE}

  That file carries the project, the zone, the instance name and the service
  accounts. Nothing here is hardcoded, so without it this script does not know
  which estate to talk to and will not guess.

  Produce it with:

      make gcp-tf-handoff ENV=${ENV_KEY} TF_STATE_BUCKET=<bucket>

  It is derived from 'terraform output -json' and is untracked, because every
  field in it names a real project. Do not hand-write one.
EOF
    exit 2
  fi

  command -v jq >/dev/null 2>&1 || die "jq is required to read ${HANDOFF_FILE}"
  jq -e . "$HANDOFF_FILE" >/dev/null 2>&1 ||
    die "${HANDOFF_FILE} is not valid JSON — regenerate it with 'make gcp-tf-handoff ENV=${ENV_KEY}'"

  local schema
  schema="$(jq -r '.schema // ""' "$HANDOFF_FILE")"
  case "$schema" in
    signalloom.gcp.handoff/v1) ;;
    "") die "${HANDOFF_FILE} declares no schema — it was not written by 'make gcp-tf-handoff'" ;;
    *) die "${HANDOFF_FILE} declares schema '${schema}', which this driver does not understand (expected signalloom.gcp.handoff/v1)" ;;
  esac

  PROJECT_ID="$(jq -r '.project_id // ""' "$HANDOFF_FILE")"
  ZONE="$(jq -r '.zone // ""' "$HANDOFF_FILE")"
  INSTANCE_NAME="$(jq -r '.instance_name // ""' "$HANDOFF_FILE")"
  APP_PORT="$(jq -r '.app_port // ""' "$HANDOFF_FILE")"

  # The SSH identity is a DIFFERENT service account from the Terraform deploy SA
  # and must not silently fall back to it. The deploy SA holds resource-creation
  # rights the demo lane has no business exercising, and an operator who typed
  # nothing would get those rights by accident. So: explicit override first,
  # then the hand-off's own field, then a refusal that names both.
  OPERATOR_SA="${GCP_TF_DEMO_OPERATOR_SA:-$(jq -r '.operator_sa // .operator_service_account // ""' "$HANDOFF_FILE")}"

  local missing=""
  [ -n "$PROJECT_ID" ] || missing="${missing} project_id"
  [ -n "$ZONE" ] || missing="${missing} zone"
  [ -n "$INSTANCE_NAME" ] || missing="${missing} instance_name"
  [ -n "$APP_PORT" ] || missing="${missing} app_port"
  if [ -n "$missing" ]; then
    die "${HANDOFF_FILE} is missing required field(s):${missing} — regenerate it with 'make gcp-tf-handoff ENV=${ENV_KEY}'"
  fi

  local env_in_file
  env_in_file="$(jq -r '.environment_key // .env // ""' "$HANDOFF_FILE")"
  if [ -n "$env_in_file" ] && [ "$env_in_file" != "$ENV_KEY" ]; then
    die "${HANDOFF_FILE} describes environment '${env_in_file}', not '${ENV_KEY}'. Reading it would point this run at the wrong estate."
  fi
}

# Refuse to reach the cloud as the human. See the header for why this is about
# osLoginExternalUser here and about IAM-shaped resources everywhere else.
require_operator_sa() {
  [ -n "$OPERATOR_SA" ] && return 0
  cat >&2 <<EOF
demo-up: refusing to run without an operator service account.

  ${HANDOFF_FILE} carries no 'operator_sa', and GCP_TF_DEMO_OPERATOR_SA is not
  set, so every gcloud call below would run as your own principal.

  That does not fail cleanly. The operator on this estate is EXTERNAL to the
  owning organisation, so 'gcloud compute ssh' requires
  roles/compute.osLoginExternalUser — which an external principal cannot grant
  itself. The error names an OS Login permission, so the diagnosis it invites is
  "grant that role", which is not an action you have the authority to take.
  An org-internal service account is not subject to the rule at all.

  Fix, in order of preference:

    1. Republish the hand-off. This works only if the environments root has
       APPLIED its 'operator_sa' output — the writer emits the field, but
       'terraform output' reads applied state, so a root that declares the
       output and has not been applied since still produces a hand-off without
       it. gcp-tf-handoff says which of the two you are looking at.

           make gcp-tf-handoff ENV=${ENV_KEY} TF_STATE_BUCKET=<bucket>

    2. Supply it directly. Always works, and is the right answer during a
       rebuild or against a root you are not applying:

           GCP_TF_DEMO_OPERATOR_SA=<sa>@<project>.iam.gserviceaccount.com make ...

       The value is the platform root's 'operator_service_account_email':

           terraform -chdir=terraform/platform output -raw operator_service_account_email

  This message used to offer (1) alone, as a bare "republish it". That advice
  could not work: the hand-off writer had never emitted 'operator_sa' at all, so
  it sent every reader to the exact command that had just failed to help them.
EOF
  exit 2
}

# ── gcloud boundary ─────────────────────────────────────────────────────────
#
# Every call goes through these three so the impersonation flag, the project,
# the zone and the emptied agent socket cannot be forgotten on one path and
# present on the others. SSH_AUTH_SOCK is already empty process-wide; it is
# re-stated on the call itself so the guard survives anyone later sourcing this
# file or reordering the header.

gcloud_common() {
  printf '%s\n' "--project=${PROJECT_ID}" "--impersonate-service-account=${OPERATOR_SA}"
}

# `--impersonate-service-account` makes gcloud print a WARNING to stderr on
# EVERY underlying API call — four per invocation, observed live. Two things go
# wrong if that is left alone, and they are different problems:
#
#   1. It pollutes the streamed pipeline output the operator is watching, at a
#      rate of four lines per gcloud call.
#   2. Anything that PARSES stderr gets the warning as data. vm_status merges
#      stderr into stdout deliberately (so it can classify auth failures) and
#      then compares the result against RUNNING/SUSPENDED/… — with the warning
#      glued on, that comparison never matches, every state reads as unknown,
#      and the run aborts against a perfectly healthy VM.
#
# Narrow on purpose. It matches gcloud's own impersonation warning and nothing
# else; a filter broad enough to swallow a real error would be worse than the
# noise it removes.
strip_impersonation_warning() {
  grep -v -E '^WARNING: This command is using service account impersonation|^WARNING: .*impersonat' || true
}

# The two IAP tunnel errors that do not say what they mean, both hit live.
#
#   4033 'not authorized'          — the SA lacks roles/iap.tunnelResourceAccessor.
#                                    Says nothing about IAM; reads as a network fault.
#   4003 'failed to connect to backend' — nothing is listening on the target port,
#                                    OR a firewall rule does not permit it. Those
#                                    two are indistinguishable from the client, so
#                                    the message must name both rather than pick.
explain_iap_error() {
  local err="$1" port="${2:-the target port}"
  case "$err" in
    *4033*|*"not authorized"*)
      cat >&2 <<EOF

  This is an IAM failure, not a network one, despite what it says.

  The operator service account needs roles/iap.tunnelResourceAccessor on the
  project (or on the instance). Without it every tunnel attempt returns
  4033 'not authorized', which mentions no permission and no principal.

      gcloud projects add-iam-policy-binding ${PROJECT_ID} \\
        --member=serviceAccount:${OPERATOR_SA} \\
        --role=roles/iap.tunnelResourceAccessor

  IAM takes roughly a minute to propagate. An immediate retry after granting
  still fails, which reads exactly like the grant not having worked.
EOF
      ;;
    *4003*|*"failed to connect to backend"*)
      cat >&2 <<EOF

  The tunnel reached IAP and IAP could not reach the port. That is TWO causes
  wearing one error, and they are indistinguishable from here:

    1. Nothing is listening on ${INSTANCE_NAME}:${port}.
       Check the estate is actually up:  make gcp-tf-demo-status ENV=${ENV_KEY}
    2. A firewall rule does not permit it. The IAP range is 35.235.240.0/20,
       and a rule that only opens tcp:22 from it — with the app port opened to
       Google's load-balancer health-check ranges instead — produces exactly
       this, because this environment has no load balancer in front of it.

       gcloud compute firewall-rules list --project=${PROJECT_ID} \\
         --filter="network~${INSTANCE_NAME}" --format='table(name,allowed[],sourceRanges[])'
EOF
      ;;
  esac
}

# Run a command with its stderr passed through the impersonation filter, and
# its exit status and its stdout untouched.
#
# stderr is buffered to a file rather than piped, deliberately. A pipe or a
# process substitution here would either lose the exit status or race the
# script's own exit; every caller below is a short control-plane call, so
# buffering costs nothing. Anything that STREAMS (the pipeline) filters inline
# instead and never comes through here.
run_filtered() {
  local err rc=0
  err="$(mktemp "${TMPDIR:-/tmp}/demo-stderr.XXXXXX")"
  "$@" 2>"$err" || rc=$?
  strip_impersonation_warning <"$err" >&2
  rm -f "$err"
  return "$rc"
}

vm_ssh() {
  local args=()
  mapfile -t args < <(gcloud_common)
  run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --tunnel-through-iap \
    --command="$1"
}

# Run a command on the VM, optionally dropping to a service account.
#
# `--command` and NOTHING on stdin. `gcloud compute ssh --command '…' < file`
# DOES NOT FORWARD STDIN: the redirect is accepted, the command runs, the exit
# status is 0, and the file arrives EMPTY. Every surrounding step then reports
# success — chmod works, a launch reports launched, and the log is empty. It is
# the worst possible failure shape, because nothing anywhere goes red. Anything
# that needs bytes on the VM goes through vm_scp and is verified after transfer.
remote_run() {
  local cmd="$1"
  if [ -n "$REMOTE_USER" ]; then
    printf -v cmd 'sudo -u %q bash -lc %q' "$REMOTE_USER" "$cmd"
  fi
  vm_ssh "$cmd"
}

vm_scp() {
  local args=()
  mapfile -t args < <(gcloud_common)
  run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute scp --tunnel-through-iap \
    --zone="$ZONE" "${args[@]}" "$@"
}

# An unreadable state is not an absent VM. Distinguishing them matters: acting
# on "absent" here would mean telling the operator to re-apply Terraform against
# an estate that is standing and healthy.
vm_status() {
  local out rc=0 args=()
  mapfile -t args < <(gcloud_common)
  # stderr is merged in ON PURPOSE — the classification below reads gcloud's
  # error text — and then the impersonation warning is stripped, because
  # otherwise it is glued onto the status and `RUNNING` never compares equal to
  # anything. Stripping BEFORE the success branch is what matters; doing it only
  # on the error path would leave the healthy case broken.
  out="$(SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" "${args[@]}" --format='get(status)' 2>&1 |
    strip_impersonation_warning)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | tr -d '[:space:]'
    return 0
  fi
  case "$out" in
    *"was not found"* | *"notFound"* | *"does not exist"*) printf 'NOT_FOUND' ;;
    *"gcloud auth login"* | *"Reauthentication"* | *"credentials"* | *"invalid_grant"*) printf 'AUTH_REQUIRED' ;;
    *) printf 'QUERY_FAILED' ;;
  esac
}

wait_for_ssh() {
  local attempts=0
  while [ "$attempts" -lt "$SSH_WAIT_ATTEMPTS" ]; do
    if vm_ssh "echo ready" >/dev/null 2>&1; then
      log "SSH is available on ${INSTANCE_NAME}"
      return 0
    fi
    attempts=$((attempts + 1))
    sleep "$SSH_WAIT_INTERVAL"
  done
  printf 'demo-up: %s did not accept SSH within %ds.\n' \
    "$INSTANCE_NAME" "$((SSH_WAIT_ATTEMPTS * SSH_WAIT_INTERVAL))" >&2
  printf '         If gcloud mentioned "agent refused operation" this is a LOCAL\n' >&2
  printf '         ssh-agent fault, not the VM. This script already empties\n' >&2
  printf '         SSH_AUTH_SOCK, so an ad-hoc gcloud call is the likelier culprit.\n' >&2
  return 2
}

ensure_vm_ready() {
  local status args=()
  mapfile -t args < <(gcloud_common)
  status="$(vm_status)"
  case "$status" in
    RUNNING)
      log "${INSTANCE_NAME} is already running"
      ;;
    SUSPENDED)
      log "resuming suspended ${INSTANCE_NAME}"
      run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances resume "$INSTANCE_NAME" \
        --zone="$ZONE" "${args[@]}" --quiet
      wait_for_ssh || return 2
      ;;
    TERMINATED | STOPPED)
      log "starting stopped ${INSTANCE_NAME}"
      run_filtered env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute instances start "$INSTANCE_NAME" \
        --zone="$ZONE" "${args[@]}" --quiet
      wait_for_ssh || return 2
      ;;
    NOT_FOUND)
      die "${INSTANCE_NAME} does not exist in ${PROJECT_ID}/${ZONE} — run: make gcp-tf-up ENV=${ENV_KEY}"
      ;;
    AUTH_REQUIRED)
      die "gcloud is not authenticated, so ${INSTANCE_NAME}'s state is UNKNOWN. This is NOT evidence the VM is missing — do not re-apply on this basis. Run: gcloud auth login"
      ;;
    *)
      die "could not read ${INSTANCE_NAME}'s state (got '${status}') — refusing to act on an unknown state"
      ;;
  esac
  return 0
}

# ── Delivery ────────────────────────────────────────────────────────────────

# Build the payload with `git archive`, not with a tar of the working tree.
#
# This is the security boundary of the whole lane, and the mechanism is the
# point. `git archive HEAD` ships TRACKED FILES ONLY. Every piece of secret
# material in this repo is gitignored — the tfvars, the hand-offs,
# deploy/gcp/deploy-sa, .keys — so none of it CAN ride along. That is a
# guarantee by construction. An `--exclude` list is a guarantee by somebody
# maintaining it correctly forever, which is a different and much weaker thing:
# a pattern that silently matches nothing looks exactly like one that works.
#
# It is also just better. A tar of this working tree measured 249MB, because
# `.terraform*` provider binaries and several node_modules trees survived the
# excludes. `git archive` is 35MB and ~2576 files.
#
# THE COST, stated plainly because it is real: uncommitted work is not
# delivered. HEAD is what ships, so a run against a dirty tree would test
# something other than what the operator is looking at while stamping the report
# with HEAD's SHA — the exact "green tests tested the wrong artefact" shape. So
# a dirty tree is refused rather than silently tolerated.
#
# `git archive` also ships no `.git`, which Kustomize needs as a security
# boundary for relative path traversal (`../base/` is rejected without one).
# deliver_code snapshots a throwaway repo on the VM for that. It is a marker,
# not history.
require_clean_tree() {
  [ "${GCP_TF_DEMO_ALLOW_DIRTY:-0}" != "1" ] || {
    warn "GCP_TF_DEMO_ALLOW_DIRTY=1 — delivering HEAD. Your uncommitted changes are NOT in this run, and the report will be stamped with HEAD's commit regardless."
    return 0
  }

  local dirty
  dirty="$("$GIT_CMD" -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
  [ -n "$dirty" ] || return 0

  {
    printf 'demo-up: REFUSING to deliver — the working tree has uncommitted changes.\n\n'
    printf '%s\n' "$dirty" | head -20 | while IFS= read -r entry; do printf '  %s\n' "$entry"; done
    cat <<EOF

  The payload is built with 'git archive HEAD', so only COMMITTED files travel.
  Running now would test HEAD while you are looking at something else on disk,
  and stamp the report with HEAD's commit — a verdict that is accurate about a
  tree nobody is reading.

  Commit first, or accept it explicitly:

      GCP_TF_DEMO_ALLOW_DIRTY=1 make gcp-tf-demo-up ENV=${ENV_KEY}
EOF
  } >&2
  exit 2
}

build_payload() {
  local out="$1"
  [ -n "$out" ] || die "build_payload needs an output path"

  require_clean_tree

  "$GIT_CMD" -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "${REPO_ROOT} is not a git repository, and the payload is built with 'git archive'. There is no working-tree fallback on purpose: it is the tracked-files-only property that keeps secrets out of the payload."

  # Presence before packaging. A payload that omits the pipeline produces a 127
  # on the VM twenty minutes later, by which point the obvious suspect is the VM.
  #
  # Checked against `git ls-files`, not against the filesystem: an UNTRACKED
  # pipeline exists on disk and will not be in the archive, and "it is right
  # there" is the most convincing possible wrong answer.
  "$GIT_CMD" -C "$REPO_ROOT" ls-files --error-unmatch "$PIPELINE_REL" >/dev/null 2>&1 ||
    die "no TRACKED pipeline at ${PIPELINE_REL}. If the file exists on disk it is untracked, and 'git archive' will not carry it. Commit it, or override with GCP_TF_DEMO_PIPELINE=<relative-path>."

  "$GIT_CMD" -C "$REPO_ROOT" archive --format=tar.gz -o "$out" HEAD

  # Verify the artefact, not the mechanism. Cheap, and it is the assertion that
  # survives someone swapping git archive back out for a tar with excludes.
  #
  # `\.terraform[/-]`, and the trailing character class is the whole point.
  #
  # The bare prefix `\.terraform` also matched `.terraform.lock.hcl`, which is
  # tracked ON PURPOSE — it is the provider pin, four of them are committed at
  # the repository root and in each Terraform root, and `make gcp-tf-validate`
  # re-inits when one is missing. So the guard refused every payload the moment
  # those lock files landed, with a message telling the operator to untrack
  # something that must stay tracked. `make gcp-tf-demo-up` could not build at
  # all; measured 2026-08-20 against demo-2.
  #
  # What the term is FOR is the state DIRECTORIES: `.terraform/`, the provider
  # cache, and `.terraform-<env>/`, the per-environment data dirs this repo
  # gives each lane so two applies cannot share one local state. Both are
  # gitignored and so cannot appear in `git archive HEAD` unless somebody tracks
  # one deliberately — which is exactly the case this second line exists to
  # catch. `[/-]` covers both; a plain `/` would silently stop covering the
  # per-env dirs, which is the more likely of the two to be tracked by accident
  # since it is created by a Make variable rather than by terraform itself.
  #
  # The `.tfvars` term has the same shape of collision, and is exempted rather
  # than loosened. This repo uses TWO example conventions:
  # `terraform/**/*.tfvars.example` ends in `.example` and never matched;
  # `deploy/gcp/*.example.tfvars` ends in `.tfvars` and always did — so the
  # committed, reviewed, placeholder-bearing example was reported as leaked
  # material alongside the lock files. Both forms are exempted, including the
  # one that never matched, so that neither convention can start failing if the
  # term above is ever rewritten.
  #
  # A LIVE tfvars is still caught, and the exemption cannot be used to smuggle
  # one: the live files are `deploy/gcp/<project>.tfvars`, they are gitignored,
  # and `git archive HEAD` carries tracked files only — so this verifier is the
  # second line, not the first. What it must not do is fire on the tracked file
  # the repository deliberately ships as documentation.
  local leaked
  leaked="$("$TAR_CMD" -tzf "$out" |
    grep -E '(^|/)(\.git/|\.keys/|node_modules/|\.terraform[/-])|\.tfvars($|\.json$)|\.handoff\.json$|deploy/gcp/deploy-sa$' |
    grep -vE '\.example\.tfvars$|\.tfvars\.example$' |
    head -5 || true)"
  if [ -n "$leaked" ]; then
    printf 'demo-up: REFUSING to deliver — excluded material is present in the payload:\n' >&2
    printf '%s\n' "$leaked" | while IFS= read -r entry; do printf '  %s\n' "$entry" >&2; done
    printf 'demo-up: something is TRACKED that must not be. Fix .gitignore and untrack it;\n' >&2
    printf 'demo-up: do not paper over it with an archive exclusion.\n' >&2
    rm -f "$out"
    exit 2
  fi
  return 0
}

REMOTE_DELIVERY_PATH="${GCP_TF_DEMO_REMOTE_DELIVERY:-/tmp/osramp-demo-delivery.tar.gz}"

# Confirm the bytes ARRIVED, rather than confirming the transfer command exited 0.
#
# This is not defensive padding. `gcloud compute ssh --command '…' < file` does
# not forward stdin: it exits 0 and the file lands at ZERO BYTES, and everything
# downstream — chmod, a launch, a "delivered" log line — reports success against
# an empty file. Observed live. scp is a different mechanism and does not have
# that specific defect, but the lesson generalises to every transfer here: an
# exit status describes the command, and the only thing that describes the
# artefact is the artefact.
#
# Byte count rather than a checksum: it catches the empty and truncated cases
# (which are the ones that actually happen and the ones that read as success),
# needs no sha256sum on the VM, and one round trip rather than two.
verify_delivered_size() {
  local expected="$1" remote_size
  remote_size="$(vm_ssh "stat -c %s $(printf '%q' "$REMOTE_DELIVERY_PATH") 2>/dev/null || echo MISSING" |
    strip_impersonation_warning | tr -d '[:space:]')"

  if [ "$remote_size" = "MISSING" ] || [ -z "$remote_size" ]; then
    die "the payload is not on ${INSTANCE_NAME} at ${REMOTE_DELIVERY_PATH} after a transfer that reported success. Nothing was delivered; do NOT read the run that would have followed as a result about this code."
  fi
  if [ "$remote_size" != "$expected" ]; then
    die "the delivered payload is ${remote_size} bytes and ${expected} were sent. A truncated or empty payload extracts partially and the pipeline then fails somewhere unrelated, blaming the estate."
  fi
  log "delivery verified: ${remote_size} bytes on the VM"
}

deliver_code() {
  log "delivering HEAD to ${INSTANCE_NAME}:${REMOTE_WORK_DIR}"
  local tarball
  tarball="$(mktemp "${TMPDIR:-/tmp}/osramp-demo-${ENV_KEY}.XXXXXX.tar.gz")"
  build_payload "$tarball"

  local size
  size="$(wc -c <"$tarball" | tr -d '[:space:]')"
  log "payload: ${size} bytes (git archive HEAD — tracked files only)"

  vm_scp "$tarball" "${INSTANCE_NAME}:${REMOTE_DELIVERY_PATH}"
  verify_delivered_size "$size"

  # rm -rf then re-extract, rather than extracting over the top. `tar -xzf`
  # overwrites the files in the archive and leaves everything else alone, so a
  # file deleted in this checkout would survive on the VM and the pipeline would
  # test a tree that exists nowhere in git.
  # The chown is unconditional, and when no service account is configured it
  # targets the CONNECTING user — resolved on the VM with `id -un`, not here.
  # The directory is created with sudo, so without this it belongs to root and
  # the very next step (git init, as an unprivileged user) fails with a
  # permission error that reads like an IAM problem and is a chown.
  local owner
  if [ -n "$REMOTE_USER" ]; then
    owner="$(printf '%q' "$REMOTE_USER")"
  else
    # shellcheck disable=SC2016  # deliberately unexpanded: evaluated on the VM
    owner='$(id -un)'
  fi

  vm_ssh "sudo rm -rf $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo mkdir -p $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo tar -xzf $(printf '%q' "$REMOTE_DELIVERY_PATH") -C $(printf '%q' "$REMOTE_WORK_DIR") \
    && sudo chown -R ${owner} $(printf '%q' "$REMOTE_WORK_DIR") \
    && rm -f $(printf '%q' "$REMOTE_DELIVERY_PATH")"

  provision_remote_paths "$owner"

  rm -f "$tarball"
  snapshot_remote_git
  log "delivered to ${REMOTE_WORK_DIR}"
}

# ── AFM image delivery ───────────────────────────────────────────────────────
#
# The one artifact a lane needs that `git archive HEAD` structurally cannot
# carry.
#
# KubeSec-AFM builds from a repo OUTSIDE this one (KUBESEC_AFM_ROOT). The
# manifests ship — d2-k8s-afm/ is tracked — so every lane has applied a
# Deployment for an image that was never there, and seven nginx locations
# (/afm/, /dashboard/, /clusters, /metrics/, /health, /jobs, /webhooks/) point
# at a Service in a namespace that does not exist. That is why /afm/ was a
# deterministic 502 on all four lanes and why four acceptance specs skip.
#
# ─── Why a saved image and not the source, or a registry ────────────────────
#
# VENDORING THE SOURCE was rejected. It is someone else's repository; a copy
# here has no sync story and silently becomes a fork. It would also add ~1.1GB
# to the payload and move a multi-stage Next.js + Z3 build onto the critical
# path of every lane bring-up — strictly more fragile than shipping something
# already built, for the privilege of building it again on weaker hardware.
#
# THE IN-CLUSTER ZOT REGISTRY was rejected because it is not a transport for
# this hop. Zot lives inside the lane's kind cluster; pushing to it requires
# being on the VM with the image already in the local daemon, which is the
# problem, not the solution. It distributes images WITHIN a lane — it is
# downstream of this step, not an alternative to it.
#
# A SHARED REMOTE REGISTRY (Artifact Registry) is the genuinely better answer
# at higher lane counts: push once, four lanes pull. It is not taken here
# because it would replace the bare `kubesec-afm:latest` tag in
# d2-k8s-afm/apps/afm-platform/base/ with a GCP-specific reference, put
# registry credentials on the kind node, and make `make demo-k8s-afm-up` on a
# laptop depend on a cloud project. The demo estate is self-contained today and
# that is worth keeping. Revisit if lanes outgrow four.
#
# So: build locally, `docker save`, ship the archive on its OWN scp beside the
# payload — never inside it, which is what keeps the payload tracked-files-only.
AFM_REQUIRED="${AFM_REQUIRED:-1}"
LOCAL_AFM_ARCHIVE="${AFM_IMAGE_ARCHIVE:-${REPO_ROOT}/.afm-image/kubesec-afm.tar.gz}"

# Deliberately the path scripts/k8s-afm.sh computes for itself by default:
# ${REPO_ROOT}/.afm-image/kubesec-afm.tar.gz, where REPO_ROOT on the VM is
# REMOTE_WORK_DIR. Nothing has to pass a variable across the ssh boundary and
# nothing can disagree about where the file is — the two sides derive the same
# path from the same rule rather than sharing a constant one of them can drift.
remote_afm_archive() { printf '%s/.afm-image/kubesec-afm.tar.gz' "$REMOTE_WORK_DIR"; }

# The refusal. Loud, specific, and it names the escape hatch rather than taking
# it silently — the previous behaviour warned and continued, which meant the
# only place the missing slice ever surfaced was a 502 in front of an audience.
refuse_or_warn_no_afm() {
  local reason="$1"
  if [ "$AFM_REQUIRED" = "1" ]; then
    die "cannot deliver the KubeSec-AFM image: ${reason}

  This lane would come up with d2-k8s-afm/ applied and no image behind it:
  the fe-k8s-afm namespace never becomes ready, and the SEVEN nginx locations
  that proxy to afm-platform (/afm/, /dashboard/, /clusters, /metrics/,
  /health, /jobs, /webhooks/) all answer 502. Four acceptance specs
  (afm-integration, afm-frontend, rbac-analysis, rbac-explorer) skip.

  Fix it by making the image available on THIS machine:
      KUBESEC_AFM_ROOT=/path/to/kubesec-afm make gcp-tf-demo-up ENV=${ENV_KEY}
  or point at an archive somebody else produced with 'k8s-afm.sh save':
      AFM_IMAGE_ARCHIVE=/path/to/kubesec-afm.tar.gz make gcp-tf-demo-up ENV=${ENV_KEY}

  Or state that you accept a lane with no RBAC analysis, which is a choice
  rather than an accident:
      AFM_REQUIRED=0 make gcp-tf-demo-up ENV=${ENV_KEY}"
  fi
  warn "AFM_REQUIRED=0 — delivering NO AFM image: ${reason}"
  warn "  /afm/ will answer 502 on this lane and the RBAC pages will show their unreachable banner."
}

deliver_afm_image() {
  local archive="$LOCAL_AFM_ARCHIVE"

  # Rebuild whenever the source is here: it is the only input that can be newer
  # than the last save, and shipping a stale archive would deploy an old binary
  # while the report is stamped with this commit.
  # ─── Do NOT hardcode a developer's home here ────────────────────────────
  #
  # This line used to default KUBESEC_AFM_ROOT to an absolute path under a
  # developer's home directory, and tripped the portability guard in
  # test/terraform-conventions.bats, which scans `scripts/gcp-tf/*.sh`. The
  # guard is right and its comment says why: the prohibition is on a DEVELOPER's
  # machine leaking into a committed file.
  #
  # The offending default is deliberately NOT quoted anywhere in this comment.
  # Writing it out to explain the rule re-trips the guard — the grep cannot tell
  # a violation from the sentence forbidding one, and the fix then reads exactly
  # like the original leak. The guard's own header excludes prose FILES for that
  # reason; a comment inside a scanned script gets no such exemption.
  #
  # `scripts/k8s-afm.sh` carries the same default and does NOT trip it, because
  # it sits outside the guard's globs. That is an inconsistency in coverage
  # rather than a licence — this file is in scope, so this file is portable.
  #
  # The sibling-of-the-repo default is derived rather than assumed: the AFM
  # checkout lives beside this one, so REPO_ROOT/../kubesec-afm resolves on any
  # machine laid out the same way and resolves to nothing on a machine that is
  # not — which is the correct answer there, because the elif below already
  # handles "no source checkout here" by using a pre-built archive.
  local afm_src="${KUBESEC_AFM_ROOT:-${REPO_ROOT}/../kubesec-afm}"
  if [ -f "${afm_src}/AFM/docker/backend.Dockerfile" ]; then
    log "building the AFM image archive from source"
    if ! "${REPO_ROOT}/scripts/k8s-afm.sh" save "$archive"; then
      refuse_or_warn_no_afm "'k8s-afm.sh save' failed against the source checkout"
      return 0
    fi
  elif [ -s "$archive" ]; then
    log "using the pre-built AFM image archive at ${archive} (no source checkout here)"
  else
    refuse_or_warn_no_afm "no KUBESEC_AFM_ROOT checkout and no archive at ${archive}"
    return 0
  fi

  local size digest remote_digest dest
  dest="$(remote_afm_archive)"
  size="$(wc -c <"$archive" | tr -d '[:space:]')"
  digest="$(sha256sum "$archive" | cut -d' ' -f1)"
  log "AFM image archive: ${size} bytes, sha256 ${digest:0:12}"

  # A CONTENT hash for the skip decision, not the byte count used for
  # verify_delivered_size above. The two answer different questions and the
  # weaker one is unsafe here: verifying a transfer only has to catch truncation
  # and emptiness, but SKIPPING a transfer has to establish that the bytes
  # already there are the RIGHT bytes. Two builds of different AFM commits can
  # land on the same size, and the cost of being wrong is a lane silently
  # running a stale binary — the exact failure kind-load-verified.sh's header
  # records when it moved from tag-equality to identity.
  remote_digest="$(vm_ssh "sha256sum $(printf '%q' "$dest") 2>/dev/null | cut -d' ' -f1 || true" |
    strip_impersonation_warning | tr -d '[:space:]')"
  if [ -n "$remote_digest" ] && [ "$remote_digest" = "$digest" ]; then
    log "AFM image already on ${INSTANCE_NAME} with a matching digest — skipping the ${size}-byte transfer"
    return 0
  fi

  # Staged through /tmp because the destination directory does not exist yet and
  # scp will not create it.
  local staged="/tmp/kubesec-afm-image.$$.tar.gz"
  log "delivering the AFM image to ${INSTANCE_NAME}:${dest}"
  vm_scp "$archive" "${INSTANCE_NAME}:${staged}"
  vm_ssh "mkdir -p $(printf '%q' "$(dirname "$dest")") \
    && mv -f $(printf '%q' "$staged") $(printf '%q' "$dest")"

  # Same reasoning as verify_delivered_size: an exit status describes the
  # command, and the only thing that describes the artefact is the artefact.
  # Verified by DIGEST rather than size because we already paid for the local
  # one, and because a corrupt 245MB archive fails `docker load` on the VM
  # twenty minutes later with an error that blames containerd.
  local landed
  landed="$(vm_ssh "sha256sum $(printf '%q' "$dest") 2>/dev/null | cut -d' ' -f1 || echo MISSING" |
    strip_impersonation_warning | tr -d '[:space:]')"
  if [ "$landed" = "MISSING" ] || [ -z "$landed" ]; then
    die "the AFM image is not on ${INSTANCE_NAME} at ${dest} after a transfer that reported success."
  fi
  if [ "$landed" != "$digest" ]; then
    die "the delivered AFM image hashes ${landed:0:12} and ${digest:0:12} was sent. The archive is corrupt in transit; 'docker load' on the VM would fail later and blame containerd."
  fi
  log "AFM image delivery verified: sha256 ${landed:0:12} on the VM"
}

# Creates and hands over EVERY remote path this driver tells the pipeline to
# write to. Not just the checkout — that omission is what made the first
# genuinely-addressed bring-up fail.
#
# ─── The failure, and why fixing the addressing caused it ───────────────────
#
#   tee: /opt/signalloom/demo-pipeline.log: Permission denied
#   mkdir: cannot create directory '/opt/signalloom/reports': Permission denied
#
#   drwxr-xr-x  3 root                     root  /opt/signalloom/
#   drwxr-xr-x 26 sa_1084361981201826946.. root  /opt/signalloom/repo
#
# Only `repo` was ever created and chowned; nothing created its siblings, and
# /opt/signalloom itself is root-owned 0755.
#
# This was UNREACHABLE until the SL_DEMO_/DEMO_ prefix mismatch was fixed.
# While the variables never arrived, the pipeline fell back to
# ${HOME}/demo-reports and ${HOME}/demo-pipeline.log — writable, so nothing ever
# failed here; the reports simply went where nobody collected them. Repairing
# the addressing pointed the pipeline at the paths the driver actually collects,
# and those were the ones it could not write. A latent permission assumption the
# addressing bug had been masking.
#
# ─── Why the report directory stays under /opt/signalloom ───────────────────
#
# The alternative was to move reports somewhere the pipeline user owns outright
# and stop chowning siblings. Rejected, for a reason that outlives the
# convenience: ${HOME} for an OS Login principal is /home/sa_<numeric-id>,
# DERIVED FROM WHICHEVER SERVICE ACCOUNT WAS IMPERSONATED. Two operators running
# the same environment would write verdicts to two different directories, and
# collect_reports — which packages one fixed path — would collect the wrong one
# or none. That is the same class of defect just removed: the driver and the
# pipeline disagreeing about where the evidence lives. A principal-independent
# path is the property worth keeping, and ownership is the cheap part.
#
# /var/tmp/... was considered and rejected too: it is world-writable and sticky,
# so any local account could pre-create the reports directory and control what
# the verdict is assembled from. On an estate whose subject is security posture
# that is not a trade worth making for one saved chown.
#
# ─── A writable DIRECTORY does not imply a writable FILE ────────────────────
#
# The log is pre-created and chowned, not merely its parent. This is the same
# lesson as the curl/EACCES defect in scripts/ci/install-ci-tools.sh, in a
# different tool: `tee` opens an EXISTING file for writing and is refused when
# it is owned by someone else, no matter how writable the directory is. Creating
# only the parent would work on the first run and fail on every run after a run
# that had executed as a different principal.
#
# Everything below is DERIVED from the same REMOTE_* variables that are exported
# to the pipeline, never restated. test/terraform-env-contract.bats asserts that
# correspondence, so a path added to the pipeline's environment without being
# provisioned here fails a test rather than a forty-minute run.
# The keypair directory must survive the delivery that is about to wipe the
# checkout. Refuse rather than assume, because the default is one environment
# variable away from being wrong and being wrong is SILENT.
#
# Nested under REMOTE_WORK_DIR, deliver_code's `sudo rm -rf` takes the keys with
# the tree. `make signing-keys` then mints a fresh pair, and push-local.sh's
# trust preflight refuses against a cluster that still trusts the old one — the
# exact defect this file's REMOTE_KEYS_DIR comment describes, restored in full
# and with no new symptom to distinguish it.
#
# Prefix matching on the normalised paths, with a trailing slash on both sides
# so that a sibling whose name merely STARTS with the work dir is not caught:
# /opt/signalloom/repo-keys is durable, /opt/signalloom/repo/.keys is not, and a
# bare prefix test cannot tell them apart. Equality is checked separately since
# the work dir is not a prefix of itself once a slash is appended.
assert_keys_dir_is_durable() {
  local keys="${REMOTE_KEYS_DIR%/}" work="${REMOTE_WORK_DIR%/}"

  [ -n "$keys" ] || die "GCP_TF_DEMO_REMOTE_KEYS_DIR is empty. It names the directory the cosign keypair persists in between runs; there is no meaningful default for 'nowhere'."

  case "$keys" in
    /*) ;;
    *) die "GCP_TF_DEMO_REMOTE_KEYS_DIR must be an ABSOLUTE path on the VM, got '${keys}'. A relative path resolves against whatever directory the pipeline happens to be standing in, which is the delivered tree — the one place it must not be." ;;
  esac

  if [ "$keys" = "$work" ] || [ "${keys#"${work}/"}" != "$keys" ]; then
    die "GCP_TF_DEMO_REMOTE_KEYS_DIR (${keys}) is inside GCP_TF_DEMO_REMOTE_DIR (${work}).

The delivery step runs 'sudo rm -rf ${work}' before extracting the payload, so a
keypair stored there is destroyed on every run. 'make signing-keys' would mint a
fresh one, and push-local.sh would then refuse to push because the cluster still
trusts the key the FIRST run bootstrapped it with — with the private half of
that key gone, which is unrecoverable.

Point it at a sibling that survives delivery, e.g. ${work%/*}/keys."
  fi
}

provision_remote_paths() {
  local owner="$1"
  local log_dir
  log_dir="$(dirname "$REMOTE_LOG")"

  assert_keys_dir_is_durable

  log "provisioning remote paths under $(dirname "$REMOTE_WORK_DIR")"

  # mkdir -p on the log's parent AND the report dir; chown -R both; then create
  # the log file itself and hand it over. `install -m` is not used for the log
  # because it must not truncate a log an operator may be tailing across runs.
  # REMOTE_KEYS_DIR is created here and NEVER emptied. It is the one path in this
  # function whose CONTENTS must survive, so it gets mkdir -p and a chown and
  # nothing else — no rm, no install -m, no truncation. chmod 700 because it
  # holds a cosign private key; cosign writes the key file itself 0600, but the
  # directory it lands in is created by us and would otherwise be 0755.
  vm_ssh "sudo mkdir -p $(printf '%q' "$REMOTE_REPORT_DIR") $(printf '%q' "$log_dir") $(printf '%q' "$REMOTE_KEYS_DIR") \
    && sudo chown -R ${owner} $(printf '%q' "$REMOTE_REPORT_DIR") \
    && sudo chown ${owner} $(printf '%q' "$REMOTE_KEYS_DIR") \
    && sudo chmod 700 $(printf '%q' "$REMOTE_KEYS_DIR") \
    && sudo touch $(printf '%q' "$REMOTE_LOG") \
    && sudo chown ${owner} $(printf '%q' "$REMOTE_LOG")" \
    || die "could not provision ${REMOTE_REPORT_DIR}, ${REMOTE_KEYS_DIR} and ${REMOTE_LOG} on ${INSTANCE_NAME}. The pipeline writes its verdict there and cannot start without them."
}

# Kustomize uses .git/ as a security boundary for relative path traversal:
# without one, a kustomization referencing `../base/` is rejected. `git archive`
# ships no .git, so one is created here.
#
# It is a MARKER, not history. Its SHA is meaningless — two runs of
# byte-identical code produce two different SHAs, which is why every report is
# stamped with the commit from the local checkout instead and why a report
# carrying the VM's own SHA is classified STALE.
snapshot_remote_git() {
  log "snapshotting a throwaway git repo on the VM (Kustomize path-traversal boundary)"
  remote_run "cd $(printf '%q' "$REMOTE_WORK_DIR") \
    && if [ ! -d .git ]; then \
      git init -q \
      && git add -A \
      && git -c user.name='Signal Loom demo' -c user.email='demo@signalloom.local' \
           commit -q -m 'demo snapshot' --no-gpg-sign --allow-empty; \
    fi \
    && test -d .git"
}

# ── Run state: written at every transition, starting before the VM is touched ─
#
# Lifted from scripts/ci/gcp-ci.sh, which arrived at it the hard way. The
# failure it removes is a report directory whose newest file describes a
# PREVIOUS run: a mid-run poll then reads a verdict that has already been
# superseded, and an aborted run inherits its predecessor's "all green".

rotate_reports() {
  if [ -d "$REPORT_DIR" ] && [ -n "$(ls -A "$REPORT_DIR" 2>/dev/null)" ]; then
    rm -rf "${REPORT_DIR}.prev"
    mv "$REPORT_DIR" "${REPORT_DIR}.prev"
    log "previous run rotated to $(basename "${REPORT_DIR}").prev"
  fi
  mkdir -p "$REPORT_DIR"
  return 0
}

write_run_status() {
  local outcome="$1" phase="$2" note="${3:-}" exit_code="${4:-}"
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0
  local tmp="${REPORT_DIR}/.${SUMMARY_NAME}.tmp"
  if jq -n \
    --arg outcome "$outcome" \
    --arg phase "$phase" \
    --arg note "$note" \
    --arg commit "$RUN_COMMIT" \
    --arg branch "$RUN_BRANCH" \
    --arg env "$ENV_KEY" \
    --arg instance "$INSTANCE_NAME" \
    --arg started_at "$RUN_STARTED_AT" \
    --arg written_at "$(date -Iseconds)" \
    --arg exit_code "$exit_code" \
    --arg pid "$$" \
    --arg host "$(hostname -s 2>/dev/null || echo unknown)" \
    --arg origin "$REPO_ROOT" \
    '{outcome: $outcome, overall: $outcome, phase: $phase, commit: $commit,
      branch: $branch, env: $env, instance: $instance, started_at: $started_at,
      written_at: $written_at, pid: ($pid | tonumber), host: $host,
      origin: $origin, note: $note}
     + (if $exit_code == "" then {} else {exit_code: ($exit_code | tonumber)} end)' \
    >"$tmp" 2>/dev/null; then
    mv "$tmp" "${REPORT_DIR}/${SUMMARY_NAME}"
  else
    rm -f "$tmp"
  fi
  return 0
}

set_run_phase() {
  RUN_PHASE="$1"
  write_run_status RUNNING "$1" "run in flight (pid $$ on $(hostname -s 2>/dev/null || echo unknown)); this is not a verdict"
  return 0
}

# classify_run_outcome <summary-file> <expected-commit> <pipeline-exit>
# Echoes exactly one of: PASS | FAIL | ABORTED | STALE.
#
# The two dishonest readings this exists to stop:
#   RUNNING — our own start marker survived collection, i.e. NOTHING came back
#             from the VM. Absence of a report is an abort, never a pass.
#   STALE   — the summary names a commit other than the one delivered, so it
#             describes some other run. A green run cannot reach this branch:
#             the pipeline stamps the commit this script hands it.
classify_run_outcome() {
  local summary="$1" expected_commit="$2" pipeline_exit="$3"
  [ -f "$summary" ] || {
    echo ABORTED
    return 0
  }

  local outcome commit
  outcome="$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)"
  commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"

  case "$outcome" in
    RUNNING | ABORTED | UNKNOWN | "")
      echo ABORTED
      return 0
      ;;
  esac

  if [ "$expected_commit" != "unknown" ] && [ "$commit" != "unknown" ] &&
    [ "$commit" != "$expected_commit" ]; then
    echo STALE
    return 0
  fi

  # A summary saying PASS does not outrank a non-zero pipeline exit; that pair
  # means the run died after writing its report, and exiting 0 on it would be
  # the same lie in a different file.
  if [ "$outcome" = "PASS" ] && [ "$pipeline_exit" -eq 0 ]; then
    echo PASS
  else
    echo FAIL
  fi
  return 0
}

# The one place the run's exit status is decided, so the status, the message and
# the file on disk cannot disagree with each other.
final_exit_code() {
  local verdict="$1" pipeline_exit="$2"
  case "$verdict" in
    PASS) echo 0 ;;
    FAIL) if [ "$pipeline_exit" -eq 0 ]; then echo 1; else echo "$pipeline_exit"; fi ;;
    *) if [ "$pipeline_exit" -eq 0 ]; then echo 2; else echo "$pipeline_exit"; fi ;;
  esac
  return 0
}

# Under `set -e` a failing final command in an EXIT trap replaces the status the
# script asked for; this repo has already lost a run with 8/8 green stages to
# exactly that. So rc is captured FIRST, every cleanup is `|| true`, and the last
# statement is an explicit `exit "$rc"`.
#
# `$?` alone is not enough to exit on either. bash runs this trap on SIGINT as
# well as on a normal exit, and on a signal `$?` is 0 — so a Ctrl-C'd run wrote
# ABORTED into the summary and then reported success. The status therefore comes
# from final_exit_code, the same function cmd_up uses.
run_exit_trap() {
  local rc=$?
  trap - EXIT INT TERM
  local outcome=""
  if [ -f "${REPORT_DIR}/${SUMMARY_NAME}" ]; then
    outcome="$(jq -r '.outcome // ""' "${REPORT_DIR}/${SUMMARY_NAME}" 2>/dev/null || echo "")"
  fi
  case "$outcome" in
    RUNNING)
      rc="$(final_exit_code ABORTED "$rc" 2>/dev/null || echo 2)"
      write_run_status ABORTED "$RUN_PHASE" \
        "run exited during phase '${RUN_PHASE}' without reaching a verdict; this is an ABORTED run, NOT a test failure" \
        "$rc" || true
      ;;
    ABORTED)
      rc="$(final_exit_code ABORTED "$rc" 2>/dev/null || echo 2)"
      ;;
  esac
  exit "$rc"
}

on_int() { exit 130; }
on_term() { exit 143; }

# ── The pipeline invocation ─────────────────────────────────────────────────
#
# The contract with scripts/gcp-tf/demo-pipeline.sh (chunk C), stated here
# because the two halves land on different branches and a contract that lives in
# only one of them is a contract nobody can check:
#
#   invoked as   : bash <PIPELINE_REL>, with cwd = DEMO_WORK_DIR
#   configured by: the DEMO_* environment below, nothing else
#   must write   : DEMO_REPORT_DIR/summary.json, a JSON object carrying at
#                  least {outcome: "PASS"|"FAIL"|"ABORTED", commit: "<sha>"}.
#                  The commit MUST be the DEMO_SOURCE_COMMIT it was handed —
#                  the VM's own git SHA is a throwaway snapshot and means
#                  nothing, so stamping that instead makes every run look STALE.
#   exit status  : 0 pass, non-zero otherwise. A zero exit with no summary is
#                  treated as ABORTED here, never as a pass.
#
# ─── The prefix, and why it is DEMO_ and not SL_DEMO_ ───────────────────────
#
# This block used to export ten variables named SL_DEMO_*. demo-pipeline.sh
# reads DEMO_*. Nothing in the repo consumed a single SL_DEMO_ name:
#
#   $ grep -rl 'SL_DEMO_' --include='*.sh' --include='*.bats' .
#   ./scripts/gcp-tf/demo-up.sh
#   ./test/terraform-demo-driver.bats
#
# The sender and its own test, and no reader anywhere. Both halves were green:
# this file's test asserted the string appeared in the gcloud command line, and
# demo-pipeline.sh's test drove DEMO_* directly. Each side verified its own half
# against its own fixtures, so the mismatch between them was invisible to both.
#
# Every one of the ten silently fell back to its default, and two of those
# defaults are what made `make gcp-tf-demo-up ENV=demo-2` abort:
#
#   DEMO_REPORT_DIR    the pipeline wrote its reports and summary.json to
#                      ${HOME}/demo-reports while collect_reports packaged
#                      /opt/signalloom/reports. Different directories, so no
#                      summary was ever collected and the classifier read the
#                      absent verdict as ABORTED.
#   DEMO_SOURCE_COMMIT the pipeline fell back to `git rev-parse HEAD` against
#                      the throwaway repo vm-pipeline.sh git-inits for
#                      Kustomize, and stamped THAT into summary.json — the
#                      `master@47c5ea5` in the run log. That is the exact
#                      failure the paragraph above predicts, and it disables the
#                      STALE guard: the collected commit can now never equal
#                      RUN_COMMIT, so the one mechanism that proves a verdict
#                      describes the delivered tree is dead.
#
# The build itself was never wrong. demo-pipeline.sh resolves WORK_DIR to its
# own script directory when DEMO_WORK_DIR is unset, and this file invokes it by
# path inside the tree it just delivered, so the delivered tree is always the
# tree that gets built. The detector was broken, not the thing it detects.
#
# Renaming the SENDER rather than the reader is deliberate. demo-pipeline.sh
# owns seventeen DEMO_* injectable boundaries that test/gcp-demo-pipeline.bats
# already drives; the SL_DEMO_ prefix had no implementation behind it at all.
# test/terraform-env-contract.bats now asserts every name this block exports is
# read by demo-pipeline.sh, so the two halves can no longer drift apart quietly.
#
# STILL UNIMPLEMENTED, stated rather than papered over: demo-pipeline.sh has no
# stage concept — DEMO_STAGE has no reader, only a cosmetic "STAGE:" banner per
# step — so `--stage test` and `--stage full` currently select the same work.
# The variable is exported because the contract calls for it and a future reader
# is a small change; the gap is asserted as a known gap by the contract suite so
# that implementing it turns a test red rather than passing unnoticed.
#
# Sets the global PIPELINE_EXIT rather than echoing it. That is not a style
# choice: `pipeline_exit="$(run_pipeline …)"` captures this function's stdout,
# which IS the pipeline's live output, so the operator would watch a blank
# terminal for ninety minutes and then receive the whole log at once. Streaming
# and returning a value through the same channel cannot both work.
PIPELINE_EXIT=0
run_pipeline() {
  local stage="$1"
  PIPELINE_EXIT=0

  local remote_cmd
  printf -v remote_cmd 'cd %q && bash %q' "$REMOTE_WORK_DIR" "$PIPELINE_REL"

  # APP_PORT IS DELIBERATELY NOT EXPORTED, and dropping it is a fix rather than
  # an omission. It was sent as SL_DEMO_APP_PORT, which nothing read. The only
  # port-shaped variable on the pipeline side is DEMO_DASHBOARD_LOCAL_PORT.
  # APP_PORT belongs to the separately supervised access path, while this
  # pipeline publishes the same dashboard Nginx service for its handover.
  # Exporting APP_PORT would couple independent lifecycle owners.
  local envs
  printf -v envs 'DEMO_ENV=%q DEMO_STAGE=%q DEMO_WORK_DIR=%q DEMO_REPORT_DIR=%q DEMO_SUMMARY_FILE=%q DEMO_DASHBOARD_HOSTNAME=%q DEMO_PIPELINE_LOG=%q DEMO_SOURCE_COMMIT=%q DEMO_SOURCE_BRANCH=%q DEMO_KEYS_DIR=%q' \
    "$ENV_KEY" "$stage" "$REMOTE_WORK_DIR" "$REMOTE_REPORT_DIR" \
    "${REMOTE_REPORT_DIR}/${SUMMARY_NAME}" "$DASHBOARD_HOST" \
    "$REMOTE_LOG" "$RUN_COMMIT" "$RUN_BRANCH" "$REMOTE_KEYS_DIR"

  # `env VAR=… cmd` with no sudo when no service account is configured. v1 always
  # drops to `ci`; here that account is not guaranteed to exist, and `sudo -u`
  # naming a missing user fails with a message about sudo, which reads as a
  # privilege problem rather than as a wrong assumption in this file.
  local invocation
  if [ -n "$REMOTE_USER" ]; then
    printf -v invocation 'sudo -u %q env %s bash -l -c %q' \
      "$REMOTE_USER" "$envs" "$remote_cmd"
  else
    printf -v invocation 'env %s bash -l -c %q' "$envs" "$remote_cmd"
  fi

  log "running the pipeline on ${INSTANCE_NAME} (stage=${stage}, fence=${TIMEOUT_MINUTES}m)"
  log "output streams below; it is also being written to ${REPORT_DIR}/pipeline.log"

  # The fence is enforced, not merely printed. A wedged SSH session otherwise
  # blocks the run forever. SIGTERM first and SIGKILL 60s later, so the remote
  # pipeline gets a chance to flush its report files before the tunnel is torn
  # down — a killed pipeline that wrote nothing is an ABORTED with no diagnosis.
  #
  # The impersonation warning is stripped before the tee. gcloud emits it on
  # every underlying API call — four per invocation — and left alone it
  # interleaves with the pipeline's real output at exactly the moment a human is
  # reading it for a problem.
  #
  # PIPESTATUS[0], not $?, because tee is what the shell sees last.
  set +e
  "$TIMEOUT_CMD" -k 60s "${TIMEOUT_MINUTES}m" \
    env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute ssh "$INSTANCE_NAME" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" \
    --tunnel-through-iap \
    --command="$invocation" \
    2>&1 | strip_impersonation_warning | tee -a "${REPORT_DIR}/pipeline.log"
  PIPELINE_EXIT="${PIPESTATUS[0]}"
  set -e

  if [ "$PIPELINE_EXIT" -eq 124 ]; then
    warn "the pipeline exceeded the ${TIMEOUT_MINUTES}m fence and was terminated. Raise it with GCP_TF_DEMO_TIMEOUT_MINUTES=<n>."
  fi
  return 0
}

collect_reports() {
  log "collecting reports from ${REMOTE_REPORT_DIR}"
  local archive="/tmp/osramp-demo-${ENV_KEY}-reports.tar.gz"
  # The report directory belongs to the restricted demo account while IAP SCP
  # authenticates as the operator SA, so it is packaged via sudo rather than
  # weakening the directory's permissions just to collect artefacts.
  #
  # REMOTE_USER IS EMPTY BY DEFAULT (see its definition above: it is only set
  # when GCP_TF_DEMO_REMOTE_USER names an account). Every other sudo site in
  # this file guards on that — vm_ssh, deliver, run_pipeline all branch on
  # `[ -n "$REMOTE_USER" ]`. This one did not, so it emitted `sudo -u ''`, and
  # sudo rejects an EMPTY option argument in its own argument parser, before it
  # ever looks up a user. The result is not "unknown user": it is the full
  # multi-line usage block and exit 1. Reproduced verbatim:
  #
  #   $ sudo -n -u '' tar -C /tmp -czf /tmp/x.tar.gz .
  #   usage: sudo -h | -K | -k | -V
  #   usage: sudo -v [-ABkNnS] [-g group] [-h host] [-p prompt] [-u user]
  #   ...
  #
  # The consequence is worse than the noise. Collection fails, and the verdict
  # is then "derived without" the reports — a verdict computed from missing
  # evidence, which is exactly the shape this file refuses everywhere else.
  local pack
  if [ -n "$REMOTE_USER" ]; then
    printf -v pack 'sudo -u %q tar -C %q -czf %q .' \
      "$REMOTE_USER" "$REMOTE_REPORT_DIR" "$archive"
  else
    printf -v pack 'sudo tar -C %q -czf %q .' "$REMOTE_REPORT_DIR" "$archive"
  fi
  if vm_ssh "$pack" &&
    vm_scp "${INSTANCE_NAME}:${archive}" "${REPORT_DIR}/" &&
    "$TAR_CMD" -xzf "${REPORT_DIR}/$(basename "$archive")" -C "$REPORT_DIR"; then
    rm -f "${REPORT_DIR}/$(basename "$archive")"
    # `sudo rm`, because the archive was written BY the sudo above and /tmp is
    # sticky: only the owner may unlink there, and the owner is root (or
    # REMOTE_USER), never the operator SA the tunnel authenticates as. Without
    # the elevation this silently leaks one tarball per run behind `|| true`.
    vm_ssh "sudo rm -f $(printf '%q' "$archive")" >/dev/null 2>&1 || true
    log "reports collected into ${REPORT_DIR}"
    return 0
  fi
  # Deliberately not fatal on its own: a failed collection is diagnosed by the
  # classifier below, which will read the absent summary as ABORTED. Turning it
  # into an immediate exit here would lose the pipeline's own exit status.
  warn "failed to collect report files — the verdict below is derived without them"
  return 0
}

report_verdict() {
  local verdict="$1" final_exit="$2" pipeline_exit="$3"
  local summary="${REPORT_DIR}/${SUMMARY_NAME}"

  case "$verdict" in
    PASS | FAIL)
      echo ""
      echo "──── Summary (${ENV_KEY}) ────"
      jq . "$summary" 2>/dev/null || cat "$summary"
      echo "──────────────────────────────"
      ;;
    STALE)
      local stale_commit
      stale_commit="$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)"
      {
        echo ""
        echo "ERROR: the collected summary is stamped ${stale_commit}, but this run"
        echo "       delivered ${RUN_COMMIT}. It describes a DIFFERENT run and is not a"
        echo "       verdict on this one. Treating as ABORTED."
      } >&2
      write_run_status ABORTED "$RUN_PHASE" \
        "collected summary was stamped ${stale_commit}, not the ${RUN_COMMIT} delivered" \
        "$final_exit"
      ;;
    ABORTED)
      {
        echo ""
        echo "ERROR: no verdict was produced — the pipeline did not reach the test"
        echo "       stages. This is an ABORTED run, NOT a test failure."
        echo "       Pipeline log on the VM: ${REMOTE_LOG}"
        echo "       Streamed copy locally:  ${REPORT_DIR}/pipeline.log"
        if [ -d "${REPORT_DIR}.prev" ]; then
          echo "       The previous run's reports are in $(basename "${REPORT_DIR}").prev —"
          echo "       they describe a DIFFERENT run. Do not read them as this one."
        fi
        if [ "$pipeline_exit" -eq 0 ]; then
          echo "       The pipeline exited 0 without producing a report. A missing verdict"
          echo "       is never a pass, so this is being treated as a failure."
        fi
      } >&2
      local collected=""
      if [ -f "$summary" ]; then
        collected="$(jq -r '.outcome // ""' "$summary" 2>/dev/null || echo "")"
      fi
      if [ "$collected" != "ABORTED" ]; then
        write_run_status ABORTED "$RUN_PHASE" \
          "run reached phase '${RUN_PHASE}' and produced no verdict; this is an ABORTED run, NOT a test failure" \
          "$final_exit"
      fi
      echo "       Recorded at ${summary} (outcome: ABORTED)." >&2
      ;;
  esac
  return 0
}

# ── The connect instructions ────────────────────────────────────────────────
#
# This is the deliverable the human actually sees, so it is a function of its
# own and is asserted line by line in test/terraform-demo-driver.bats.
print_connect_instructions() {
  local url="$1"
  cat <<EOF

════════════════════════════════════════════════════════════════════
  Signal Loom demo — ${ENV_KEY}
════════════════════════════════════════════════════════════════════

  URL:      ${url}

  1. There is NOTHING to add to /etc/hosts, and no certificate warning to
     click through. The tunnel forwards to the dashboard's nginx, which
     serves the app and proxies /dex/ and /api/ on the same origin — so
     there is no SNI name to match and no TLS for a browser to object to.

  2. Log in through Dex:

         username: ${DEMO_LOGIN_USER}
         password: ${DEMO_LOGIN_PASS}

  3. The port is not special. Dex's issuer and callback follow this origin,
     so if ${url} is inconvenient, pick another:

         GCP_TF_DEMO_LOCAL_PORT=<port> make gcp-tf-connect ENV=${ENV_KEY}

  Confirm the tunnel BEFORE opening a browser:

      curl ${url}/readyz

  That answers 200 when the estate is up. If it hangs, the tunnel is not
  bound. If it connects and 404s, the tunnel is fine and the estate is not.

  The tunnel runs in the FOREGROUND below. Ctrl-C closes it.

════════════════════════════════════════════════════════════════════
EOF
}

# ── Commands ────────────────────────────────────────────────────────────────

# Shared preamble for every command that reaches the cloud.
prepare() {
  require_env "$1"
  load_handoff
  require_operator_sa
}

capture_source_identity() {
  RUN_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  RUN_STARTED_AT="$(date -Iseconds)"
}

# stage is "full" (build the estate, then test it) or "test" (tests only).
run_lane() {
  local stage="$1"

  capture_source_identity
  echo "════════════════════════════════════════════════════════════"
  echo "  Signal Loom GCP demo — ${stage}"
  echo "  ENV: ${ENV_KEY}  |  project: ${PROJECT_ID}  |  VM: ${INSTANCE_NAME}"
  echo "  Source: ${RUN_BRANCH}@${RUN_COMMIT}  (started ${RUN_STARTED_AT})"
  echo "════════════════════════════════════════════════════════════"

  rotate_reports

  # Armed before the first thing that can fail: a run that dies from here on
  # would otherwise leave a RUNNING marker that reads as "still going" forever.
  trap run_exit_trap EXIT
  trap on_int INT
  trap on_term TERM

  set_run_phase "resuming-vm"
  ensure_vm_ready || exit 2

  set_run_phase "delivering-code"
  deliver_code
  # AFTER deliver_code, never before: deliver_code does `rm -rf $REMOTE_WORK_DIR`
  # and the archive lands inside that directory (see remote_afm_archive for why
  # it lands there). Delivering first would silently throw it away, and the
  # symptom would be a lane that refuses AFM having just been told it arrived.
  deliver_afm_image

  set_run_phase "pipeline"
  run_pipeline "$stage"

  set_run_phase "collecting-reports"
  collect_reports

  local verdict final_exit
  verdict="$(classify_run_outcome "${REPORT_DIR}/${SUMMARY_NAME}" "$RUN_COMMIT" "$PIPELINE_EXIT")"
  final_exit="$(final_exit_code "$verdict" "$PIPELINE_EXIT")"
  report_verdict "$verdict" "$final_exit" "$PIPELINE_EXIT"

  # File this run as the ON-VM surface, so `test-surfaces` can assert that both
  # surfaces ran rather than take it on trust.
  #
  # It is a SEPARATE file from summary.json rather than a re-read of it, and the
  # duplication is deliberate: rotate_reports() moves REPORT_DIR wholesale to
  # .prev at the start of the next run, and REPORT_DIR is not per-lane, so
  # summary.json cannot answer "did the on-vm surface run for demo-1" once any
  # other lane has run. The receipt is per-lane and outside that directory.
  #
  # `|| warn` and never fatal: the run's own verdict has already been decided
  # and printed, and failing it here would change a real PASS into a failure
  # over bookkeeping. The consequence of a missing receipt is that
  # test-surfaces reports this surface as not having run — which is the honest
  # answer when the evidence is absent.
  write_surface_receipt on-vm "$verdict" 1 "$([ "$final_exit" -eq 0 ] && echo 0 || echo 1)" \
    "on-VM pipeline verdict ${verdict} (exit ${final_exit})" ||
    warn "could not write the on-vm surface receipt under ${SURFACE_DIR}; 'make gcp-tf-test-surfaces ENV=${ENV_KEY}' will report this surface as not having run"

  echo ""
  if [ "$final_exit" -eq 0 ]; then
    echo "==> PASS — the estate is standing and tested."
    echo "    Open it with:  make gcp-tf-connect ENV=${ENV_KEY}"
  else
    echo "==> ${verdict} — the VM is left RUNNING so it can be inspected." >&2
    echo "    SSH in:   gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} \\" >&2
    echo "                --impersonate-service-account=${OPERATOR_SA} --tunnel-through-iap" >&2
    echo "    VM log:   ${REMOTE_LOG}" >&2
    echo "    Verdict:  ${REPORT_DIR}/${SUMMARY_NAME} records outcome=${verdict}" >&2
    echo "              for ${RUN_BRANCH}@${RUN_COMMIT}. Read that file, not the VM state." >&2
    echo "    Suspend it when you are done — it bills until you do:" >&2
    echo "      gcloud compute instances suspend ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} \\" >&2
    echo "        --impersonate-service-account=${OPERATOR_SA}" >&2
  fi

  exit "$final_exit"
}

cmd_up() {
  prepare up
  run_lane full
}

cmd_test() {
  prepare test
  run_lane test
}

cmd_connect() {
  prepare connect

  local port="$APP_PORT" local_port origin
  local_port="$(local_tunnel_port)"
  origin="$(iap_origin)"

  # FIRST, before the origin claim mutates this lane's Dex and before any cloud
  # call. See require_local_port_free: a taken port here is another lane's
  # tunnel, and proceeding hands this operator that lane's cluster.
  require_local_port_free "$local_port" "gcp-tf-connect"

  # There is no port refusal here any more, and its absence is the deliberate
  # part.
  #
  # This used to REFUSE any port but 30754, because Dex's callback was pinned
  # to it. That pin was a property of tunnelling to the Envoy Gateway — the
  # Gateway routed by SNI on a fixed hostname:port, so the origin could not
  # move. Now the tunnel reaches nginx and Dex's issuer and redirect URI are
  # rendered from PUBLIC_ORIGIN, so the origin follows whatever port is opened.
  # Keeping the check would refuse a correct configuration, which is worse than
  # not having it: a guard that fires on valid input is a guard that gets
  # deleted rather than understood.
  #
  # The invariant that REPLACES it is that the claimed origin tracks the port
  # actually opened. That is what iap_origin exists for and what the driver
  # tests assert against a non-default port.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" = "1" ]; then
    warn "GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 — Dex keeps its current issuer. The dashboard will load at ${origin} and the LOGIN WILL BOUNCE."
  else
    # `connect` did not need this while IAP served at the origin the manifests
    # already default to: Dex was issuing for it, so opening a tunnel was the
    # whole job. IAP now publishes an origin of its own, so skipping the claim
    # would hand over a dashboard that LOADS and a login that BOUNCES.
    #
    # Read-only check first, and before any cloud call — a run that is going to
    # be refused is refused before the VM is touched.
    require_dex_origin_mechanism "gcp-tf-connect"
    require_no_conflicting_origin "$origin"
    log "claiming the Dex origin: ${origin}"
    dex_origin apply iap "$origin" ||
      die "could not repoint Dex at ${origin}. The dashboard would load and the login would bounce, so this is a failure rather than a warning."
  fi

  # Printed BEFORE the tunnel, because the tunnel occupies the foreground and
  # anything printed after it would only appear once the operator had already
  # given up and pressed Ctrl-C.
  print_connect_instructions "$origin"

  log "opening IAP tunnel: localhost:${local_port} -> ${INSTANCE_NAME}:${port}"

  # Backgrounded and PROBED, rather than exec'd.
  #
  # `exec` was the obvious shape and it is the wrong one, because the two ways
  # this fails both look like a tunnel that is simply taking its time:
  #
  #   4033 'not authorized'              — the SA lacks iap.tunnelResourceAccessor
  #   4003 'failed to connect to backend' — the port is closed, or firewalled
  #
  # Neither mentions IAM or a firewall. Under `exec` the operator sits watching
  # a terminal that has printed a URL, waiting for something that will never
  # bind. So the tunnel is started, the local port is polled to a deadline, and
  # a failure is diagnosed with its own stderr in hand.
  local tunnel_err
  tunnel_err="$(mktemp "${TMPDIR:-/tmp}/demo-tunnel.XXXXXX.log")"

  # The two ends are named separately now. They default to the same number, but
  # only the REMOTE one is fixed by the estate (app_port, and the firewall rule
  # derived from it); the local one is whatever this machine has free.
  env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute start-iap-tunnel "$INSTANCE_NAME" "$port" \
    --local-host-port="localhost:${local_port}" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" 2>"$tunnel_err" &
  local tunnel_pid=$!

  # Killed by PID, never by pattern. `pkill -f start-iap-tunnel` would match the
  # shell running this script, because the tool that invokes it puts the whole
  # script text on that shell's command line — a self-kill that presents as a
  # silent exit with no output at all.
  local bound=0 waited=0
  while [ "$waited" -lt "$TUNNEL_WAIT_SECONDS" ]; do
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      break # the tunnel died; fall through to the diagnosis
    fi
    if "$PORT_PROBE" "$local_port"; then
      bound=1
      break
    fi
    waited=$((waited + 1))
    sleep 1
  done

  if [ "$bound" -ne 1 ]; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    local err
    err="$(strip_impersonation_warning <"$tunnel_err" | tail -5)"
    {
      printf '\ndemo-up: the tunnel did not bind localhost:%s within %ds.\n' "$local_port" "$TUNNEL_WAIT_SECONDS"
      printf '\n  gcloud said:\n'
      printf '%s\n' "${err:-(nothing on stderr)}" | while IFS= read -r line; do printf '    %s\n' "$line"; done
    } >&2
    # The REMOTE port, not the local one. 4003 is about what IAP could not
    # reach on the far side, and quoting the local port here would send the
    # reader to look for a firewall rule that has nothing to do with it.
    explain_iap_error "${err}" "$port"
    rm -f "$tunnel_err"
    exit 2
  fi

  # The port answered. That is not yet evidence it answered for US — see
  # assert_tunnel_is_ours. Checked before the URL is called live, because the
  # next thing that happens is a human clicking it.
  if ! assert_tunnel_is_ours "$local_port" "$tunnel_pid" "gcp-tf-connect"; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    rm -f "$tunnel_err"
    exit 8
  fi

  # The second layer, and the one that is shared with every other access path.
  # Ownership proved the socket is ours; this asks the estate on the far end
  # whether it agrees it is this lane. On the default IAP origin it reports
  # UNVERIFIED rather than pretending — see assert_far_side_lane_identity.
  require_far_side_lane_identity "$origin" "gcp-tf-connect"

  rm -f "$tunnel_err"
  log "tunnel is UP on localhost:${local_port} — the URL above is live. Ctrl-C to close."
  wait "$tunnel_pid"
}

# ── The single coupling to the origin mechanism ─────────────────────────────
#
# Everything this file knows about Dex's issuer goes through here, so there is
# ONE function to read rather than a call site per access method to find.
#
# INTERFACE (scripts/lib/dex-origin.sh):
#
#   apply <method> <origin>  claim the origin on behalf of <method>. Exit 0 on
#                            success. Non-zero when ANOTHER method holds it.
#                            The method is NOT optional — the mechanism records
#                            it so its next refusal can name whose teardown to
#                            run, and an origin alone cannot answer that.
#   current                  print the origin currently in force. Exit 0.
#   restore                  release the lease and return to the resting
#                            origin. Exit 0.
#   status                   human-readable. Exit 0.
#
# WHERE IT RUNS: on this lane the cluster lives on the demo VM, so the default
# is to invoke the DELIVERED copy over SSH. GCP_TF_DEMO_DEX_ORIGIN_CMD overrides
# that with a local command, which is both the escape hatch for a different
# topology and what makes every branch below testable with no cluster.
DEX_ORIGIN_REL="${GCP_TF_DEMO_DEX_ORIGIN_REL:-scripts/lib/dex-origin.sh}"
DEX_ORIGIN_CMD="${GCP_TF_DEMO_DEX_ORIGIN_CMD:-}"

# Checked against the LOCAL checkout even when the call is remote. The payload
# is `git archive HEAD` of this tree, so a file absent here is absent on the VM
# — and "T2 has not landed yet" is a far more useful message than a 127 from a
# remote shell twenty seconds later.
dex_origin_available() {
  [ -n "$DEX_ORIGIN_CMD" ] && return 0
  [ -f "${REPO_ROOT}/${DEX_ORIGIN_REL}" ]
}

dex_origin() {
  if [ -n "$DEX_ORIGIN_CMD" ]; then
    # Word-split deliberately: an operator-supplied command plus its flags.
    local parts=()
    read -r -a parts <<<"$DEX_ORIGIN_CMD"
    "${parts[@]}" "$@"
    return $?
  fi
  local remote
  printf -v remote 'cd %q && %q %s' "$REMOTE_WORK_DIR" \
    "${REMOTE_WORK_DIR}/${DEX_ORIGIN_REL}" "$(printf '%q ' "$@")"
  remote_run "$remote"
}

# Refuse when T2's mechanism is not here.
#
# `who` names the caller so the message can say what will break, because the
# consequence differs: over Tailscale a missing patch means a login that
# bounces, and behind Funnel it means the same login bouncing on a URL the
# whole internet can reach.
require_dex_origin_mechanism() {
  local who="$1"
  dex_origin_available && return 0
  cat >&2 <<EOF
demo-up: ${who} needs the Dex origin mechanism, and it is not in this checkout.

  Expected: ${REPO_ROOT}/${DEX_ORIGIN_REL}

  Serving the dashboard at a new origin without repointing Dex's issuer gives
  you a dashboard that LOADS and a login that BOUNCES. That presents as a
  broken application rather than as an origin mismatch, which is the most
  expensive wrong diagnosis available on this lane.

  There is no longer a path that sidesteps this. IAP used to serve at the
  origin the manifests already default to, so it could open a tunnel and skip
  the mechanism entirely; now that every access method terminates at the same
  nginx, every one of them publishes an origin of its own and has to claim it.

  Restore the file, or point this at an equivalent implementation:

      GCP_TF_DEMO_DEX_ORIGIN_CMD='<cmd>' make ${who} ENV=${ENV_KEY}
EOF
  exit 5
}

# Read-only conflict check, run BEFORE anything is stood up.
#
# Separated from the apply deliberately. `current` mutates nothing, so a demo
# that is going to be refused is refused before the VM is touched; the write
# happens later, once the serving path is real. Doing both at the point of
# apply would mean publishing, serving, and only then discovering that ngrok
# holds the issuer.
# The origin the cluster is publishing, and the METHOD holding it. Two separate
# questions, asked separately on purpose — see below.
dex_origin_field() {
  dex_origin "$1" 2>/dev/null | tr -d '\r' | tail -1 | tr -d '[:space:]' || true
}

require_no_conflicting_origin() {
  local want="$1" method="" active=""

  # The METHOD decides whether anything is held, NOT the origin.
  #
  # `current` falls back to the resting origin when nobody has published, so it
  # is never empty and "non-empty means somebody holds it" is wrong. This code
  # made exactly that mistake and it was invisible: the driver's suites asked a
  # stub whose `current` prints empty at rest, so every test agreed with the
  # driver while the shipped mechanism disagreed with both. Against the real
  # thing every ts-up on an idle cluster refused itself, naming the baseline as
  # the holder.
  #
  # Found by driving the real driver against the real mechanism — see
  # test/terraform-demo-driver.bats § SEAM.
  method="$(dex_origin_field holder)"
  [ -n "$method" ] || return 0

  active="$(dex_origin_field current)"
  [ "$active" != "$want" ] || return 0

  cat >&2 <<EOF
demo-up: REFUSING — another access method already holds Dex.

  currently held by: ${method}
  at origin:         ${active}
  this run wants:    ${want}

  Dex has exactly ONE issuer, so these cannot both be live. The other origin is
  almost certainly an ngrok tunnel from 'make public'; whatever it is, taking
  the issuer from underneath it breaks that demo's login without warning it.

  Release it first, then re-run:

      ./scripts/public-tunnel.sh down          # if ngrok holds it
      ${DEX_ORIGIN_REL} restore                # otherwise
EOF
  exit 6
}

# ── Publishing, and proving it before a human clicks ────────────────────────
#
# `connect` opens the tunnel and proves the LOCAL port binds. That is necessary
# and it is not sufficient, and the gap between the two is where this whole
# family earns its keep:
#
#   * A bound local port says the IAP tunnel accepted a connection. It says
#     nothing about whether anything on the VM is listening on the far side,
#     because gcloud binds locally before it ever proves the backend.
#   * The VM-side forward is the piece that actually dies. `kubectl
#     port-forward` drops on apiserver SPDY resets and pod restarts, so a demo
#     that worked an hour ago frequently has no listener now.
#   * A working tunnel to a healthy dashboard still gives a bouncing login if
#     Dex is not issuing for this origin, so the origin is claimed as part of
#     the chain rather than assumed.
#
# The third bullet here used to be about SNI: the probe had to carry the
# Gateway's hostname or the connection was closed mid-handshake. That is gone
# with the Gateway, along with `--resolve`, `-k` and the /etc/hosts preflight
# that existed to make a browser agree with the probe.
#
# So `public` does the whole chain and refuses to hand over a URL it has not
# fetched a 200 from: claim the origin, ensure the VM is publishing, open the
# tunnel, wait for the local bind, then HTTP-probe /readyz through it. Only
# then is anything printed that invites a click.

# Everything below is injectable so the control flow is exercisable against
# stubs with no cluster, no tunnel and no cloud account.
HEALTH_PATH="${GCP_TF_DEMO_HEALTH_PATH:-/readyz}"
HEALTH_WAIT_SECONDS="${GCP_TF_DEMO_HEALTH_WAIT_SECONDS:-120}"
HEALTH_INTERVAL_SECONDS="${GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS:-3}"
CURL_BIN="${GCP_TF_DEMO_CURL:-curl}"

# GATEWAY_LABEL is GONE, not merely unused.
#
# It existed because the forward targeted the Envoy Gateway service, whose name
# carries a generated hash (envoy-ingress-cluster-6b24dc08) and therefore had to
# be discovered by label at run time. The forward now targets a Service with a
# stable, hand-written name, so there is nothing to discover — and with it goes
# the `read -r ns svc < <(kubectl … -o jsonpath …)` in the remote script, which
# returned non-zero for want of a trailing newline and aborted that script
# silently under `set -e`.

# The wildcard bind address, not loopback.
#
# Loopback is the wrong value here and the failure is misleading: the operator
# arrives over an IAP tunnel that connects to the instance's INTERNAL IP, so a
# forward bound to localhost is reachable only from the VM itself and presents
# to the tunnel as 4003 'failed to connect to backend' — indistinguishable from
# a firewall block, and it sends the reader to the firewall.
#
# It is an IP literal, which the estate-identity scan in
# test/terraform-demo-driver.bats forbids. It is exempted there alongside
# 127.0.0.1 and 35.235.240.0/20 on the same stated grounds: those are constants
# of the PROTOCOL, not of the estate, and cannot go stale when the estate is
# rebuilt — which is the property that guard exists to protect.
#
# Defined here with the other constants rather than beside its consumer, because
# it is read inside a heredoc built by ensure_published and a later definition
# would expand empty.
FORWARD_BIND_ADDRESS="${GCP_TF_DEMO_FORWARD_BIND_ADDRESS:-0.0.0.0}"

# The forward is a systemd UNIT, not a nohup'd process, and the unit name is how
# it is both started and stopped.
#
# `kubectl port-forward` is not a durable tunnel. It dies on apiserver resets and
# on pod restarts, it exits ZERO when it does, and it says nothing — so the demo
# that worked at 21:00 is dead at 09:00 with no error anywhere to find. `nohup
# setsid` (what this used to be) solves a different and smaller problem: it
# survives the SSH session that started it, and nothing else. It does not survive
# the process dying, and it does not survive a reboot.
#
# ONE unit for every access method, not one per method. The forward is already
# the single entry point that IAP, Tailscale and Funnel share — giving the
# Tailscale path a private second forward would fork that, and two forwards
# racing for the same port is a worse failure than the one being fixed.
#
# The unit name replaces the recorded PID as the thing `public-down` stops. That
# is a strictly stronger identity for the same reason the PID file existed: a
# `pkill -f 'kubectl port-forward…'` issued over remote_run matches the remote
# `bash -lc` carrying the command text and kills its own shell. A unit name
# cannot match anything but the unit.
PF_UNIT="${GCP_TF_DEMO_PF_UNIT:-signalloom-dashboard-pf}"
PF_UNIT_PATH="/etc/systemd/system/${PF_UNIT}.service"

# How long to wait for the forward's port after starting the unit. Generous
# because a cold start also waits for kubectl to reach the apiserver.
PF_WAIT_SECONDS="${GCP_TF_DEMO_PF_WAIT_SECONDS:-60}"

# One HTTP probe through the tunnel. Returns the status code on stdout, or the
# empty string when the request could not be made at all.
#
# It probes THE EXACT URL it is about to hand over, which it could not do
# before. The old probe needed `--resolve` to set the connection target and the
# TLS SNI name to the Gateway's hostname, and `-k` to accept the Gateway's
# self-signed certificate — so a 200 proved the ESTATE was healthy while saying
# nothing about whether a browser here could reach the same address. That gap is
# what require_hosts_entry existed to cover. Probing the browser's own URL
# closes it at the source rather than guarding it, so both are gone.
probe_dashboard_status() {
  local origin="$1"
  "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${origin}${HEALTH_PATH}" 2>/dev/null || printf ''
}

# Poll until the dashboard answers 200, or the deadline expires.
wait_for_dashboard() {
  local origin="$1" waited=0 code=''
  while [ "$waited" -lt "$HEALTH_WAIT_SECONDS" ]; do
    code="$(probe_dashboard_status "$origin")"
    if [ "$code" = "200" ]; then
      printf '%s' "$code"
      return 0
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
    waited=$((waited + HEALTH_INTERVAL_SECONDS))
  done
  printf '%s' "$code"
  return 1
}

# ── There is no hosts-file preflight here any more ──────────────────────────
#
# `hosts_entry_present` and `require_hosts_entry` were REMOVED, not disabled,
# and the distinction matters: a passing check for a constraint that no longer
# exists is worse than no check, because it teaches the next reader that the
# constraint is still real.
#
# They existed for one reason. The Gateway routed by SNI on a name that resolves
# nowhere in the world, so every operator had to add `127.0.0.1
# dashboard.osramp.acme.local` to /etc/hosts before a browser could reach the
# demo, and the health probe could not detect its absence because `curl
# --resolve` never consults /etc/hosts. The URL handed over is now
# `http://localhost:<port>`, which resolves on every machine ever built, and the
# probe fetches that exact URL — so there is nothing left for the preflight to
# assert.
#
# It is NOT still needed elsewhere on this lane. The one other place a hosts
# entry was written was ON THE VM (`ensure_vm_hosts_alias`), so `tailscale
# serve` could dial the Gateway with an SNI name; serve now dials the same nginx
# forward over loopback HTTP and that function is gone too. The Tailscale and
# ngrok paths never needed one on the operator's machine at all — MagicDNS and
# ngrok both hand out real, resolvable names.

# Is the VM publishing the dashboard on its own interface?
#
# `ss -ltn` on the VM, not a probe from here: from here a closed port and a
# firewalled port are the same timeout, and this has to tell them apart to give
# a useful message.
# What systemd thinks of the forward unit, as a bare word (active / inactive /
# failed / activating / unknown).
#
# Reported ALONGSIDE remote_is_publishing rather than instead of it, and the two
# are deliberately separate facts. systemd reports `active` the moment the
# process forks — several seconds before kubectl has an apiserver connection,
# and forever if it never gets one. So a unit in a Restart=always loop reads
# `active` while nothing is listening, and a single merged "is it up" line would
# print that state green. Whenever these two disagree, the disagreement IS the
# diagnosis.
forward_unit_state() {
  remote_run "systemctl is-active ${PF_UNIT}.service 2>/dev/null || true" 2>/dev/null |
    tr -d '\r' | tr -d '[:space:]'
}

remote_is_publishing() {
  local port="$1"
  remote_run "ss -ltn 2>/dev/null | grep -q ':${port} ' && echo PUBLISHING || echo ABSENT" 2>/dev/null \
    | grep -q PUBLISHING
}

# Start the VM-side supervised forward if it is not already up. Idempotent.
#
# The target is the dashboard's nginx Service, by NAME. That is the whole
# refactor in one line: this used to discover the Envoy Gateway's Service by
# label, because Envoy appends a generated hash to it
# (envoy-ingress-cluster-6b24dc08) and a hardcoded name breaks the moment the
# Gateway is recreated. dashboard-signalloom is a hand-written name in a
# hand-written manifest and cannot acquire a hash, so the discovery step, its
# failure mode, and the `read -r ns svc < <(kubectl …)` that implemented it are
# all gone rather than reworked.
#
# The forward is 8080-to-8080 in spirit — <local>:8080 — where the Service's
# port is fixed by the manifest and the VM-side port is app_port. It carries
# plain HTTP, so nothing here terminates TLS and nothing needs a certificate.
ensure_published() {
  local port="$1"

  if remote_is_publishing "$port"; then
    log "the VM is already publishing on :${port}"
    return 0
  fi

  log "the VM is not publishing on :${port} — installing ${PF_UNIT}.service for ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE}:${DASHBOARD_SERVICE_PORT}"

  # 0.0.0.0, not loopback: the operator arrives over an IAP tunnel that connects
  # to the instance's INTERNAL IP, so a forward bound to localhost is reachable
  # only from the VM itself and presents to the tunnel as 4003 'failed to
  # connect to backend' — indistinguishable from a firewall problem. The
  # Tailscale path dials 127.0.0.1, which a wildcard bind already serves, so one
  # address satisfies both and no method needs its own forward.
  #
  # No `cd` into the checkout: this needs kubectl and a kubeconfig, not the
  # repository. Anchoring it to the delivery directory would make publishing an
  # already-running estate fail on a VM where the payload had been cleaned up.
  local script
  script=$(cat <<REMOTE
set -uo pipefail
# Still NOT set -e. Several probes below are EXPECTED to fail on an estate that
# is not up yet, and each needs to produce its own message; under errexit the
# script aborts at the first one and the caller sees empty stdout and a generic
# non-zero with no clue which step went missing.

KUBECTL="\$(command -v kubectl 2>/dev/null || true)"
if [ -z "\$KUBECTL" ]; then
  echo "NO_KUBECTL" >&2
  exit 3
fi

# The kubeconfig is DISCOVERED, never assumed, and this is the step that makes
# the difference between a nohup'd process and a unit. The cluster is Kind,
# created by whichever account the pipeline ran as, so its config lives in that
# user's HOME — and this command arrives over a login shell that already has it.
# systemd does not: a unit with no KUBECONFIG runs with HOME=/root, finds
# nothing, and fails authenticating to localhost:6443, which reads like a broken
# cluster rather than a missing variable.
KUBECONFIG_PATH="\${KUBECONFIG:-\${HOME}/.kube/config}"
if [ ! -r "\$KUBECONFIG_PATH" ]; then
  echo "NO_KUBECONFIG:\${KUBECONFIG_PATH}" >&2
  exit 4
fi
RUN_USER="\$(id -un)"

# The Service is asserted to EXIST before anything is forwarded, and under
# Restart=always that check earns its keep twice over. \`kubectl port-forward\`
# against a missing Service fails a few seconds later with a message about the
# service, which reads as a broken cluster; and a unit that restarts always
# turns that into an INFINITE LOOP reported as \`active\`, with the health gate
# timing out two minutes later having named nothing at all.
if ! "\$KUBECTL" get service -n '${DASHBOARD_NAMESPACE}' '${DASHBOARD_SERVICE}' >/dev/null 2>&1; then
  echo "NO_DASHBOARD_SERVICE ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE}" >&2
  exit 5
fi
echo "dashboard=${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE}"

# ExecStart takes an absolute path and no shell metacharacters — systemd does
# not run a shell, so a \$VAR or a pipe here reaches kubectl as a literal.
UNIT_BODY="[Unit]
Description=Signal Loom dashboard port-forward (shared by every access method)
Documentation=https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/docs/gcp-demo/RUNBOOK.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=\${RUN_USER}
Environment=KUBECONFIG=\${KUBECONFIG_PATH}
ExecStart=\${KUBECTL} port-forward --namespace ${DASHBOARD_NAMESPACE} svc/${DASHBOARD_SERVICE} --address ${FORWARD_BIND_ADDRESS} ${port}:${DASHBOARD_SERVICE_PORT}
# always, not on-failure: a port-forward that loses its pod exits ZERO, so
# on-failure would leave the demo dead with the unit reported cleanly finished.
Restart=always
RestartSec=5
# The forward is EXPECTED to die often — a pod roll restarts it several times in
# a minute. systemd's default rate limit gives up after 5 restarts in 10s and
# leaves the unit failed, which is worse than the problem it guards against.
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
"

# Rewritten and reloaded ONLY when the body actually changes. This is not
# tidiness: restarting drops every in-flight connection, and Dex runs
# \`storage: type: memory\`, so a gratuitous restart logs out everyone using the
# demo right now.
CHANGED=0
if [ ! -f ${PF_UNIT_PATH} ] || ! printf '%s' "\$UNIT_BODY" | sudo cmp -s - ${PF_UNIT_PATH}; then
  printf '%s' "\$UNIT_BODY" | sudo tee ${PF_UNIT_PATH} >/dev/null || { echo "UNIT_WRITE_FAILED" >&2; exit 6; }
  sudo systemctl daemon-reload || { echo "DAEMON_RELOAD_FAILED" >&2; exit 7; }
  CHANGED=1
fi
echo "unit_changed=\${CHANGED}"

# enable on BOTH branches. It is what links the unit into multi-user.target, so
# it is what makes the forward come back from a reboot without anyone SSHing in
# — which is the manual step this whole mechanism exists to delete.
if [ "\$CHANGED" = "1" ]; then
  sudo systemctl enable --now ${PF_UNIT}.service >/dev/null 2>&1 || { echo "UNIT_START_FAILED" >&2; exit 8; }
  sudo systemctl restart ${PF_UNIT}.service || { echo "UNIT_RESTART_FAILED" >&2; exit 8; }
else
  sudo systemctl enable ${PF_UNIT}.service >/dev/null 2>&1 || true
  sudo systemctl is-active --quiet ${PF_UNIT}.service || sudo systemctl start ${PF_UNIT}.service || { echo "UNIT_START_FAILED" >&2; exit 8; }
fi

# Wait for the LISTENER, not for the unit. systemd reports active the moment the
# process forks, several seconds before kubectl has an apiserver connection —
# and forever, if it never gets one. \`active\` is not the property anything
# downstream needs.
WAITED=0
while [ "\$WAITED" -lt ${PF_WAIT_SECONDS} ]; do
  if ss -ltn 2>/dev/null | grep -q ':${port} '; then
    echo PUBLISHED
    exit 0
  fi
  sleep 2
  WAITED=\$((WAITED + 2))
done
echo NOT_PUBLISHED >&2
sudo systemctl status ${PF_UNIT}.service --no-pager --lines=15 >&2 2>/dev/null || true
exit 9
REMOTE
)
  local rc=0
  remote_run "$script" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat >&2 <<EOF

demo-up: could not publish ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} on ${INSTANCE_NAME}.

  The unit is ${PF_UNIT}.service, at ${PF_UNIT_PATH}.
  The remote step exited ${rc}, which names the cause:

    3   no kubectl on the VM        — the estate was never deployed here
    4   no readable kubeconfig      — the Kind cluster belongs to another user
    5   no ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} service
                                    — the cluster is up and the app is not.
                                      Run: make gcp-tf-demo-up ENV=${ENV_KEY}
    6/7 could not write or reload the unit — sudo is refusing on the VM
    8   systemd would not start the unit
    9   the unit started and nothing ever listened on :${port}.
        systemctl status is above.

EOF
    exit 7
  fi
}

# `public` — the whole chain, proven, then handed over.
cmd_public() {
  prepare public

  local port="$APP_PORT" local_port origin
  local_port="$(local_tunnel_port)"
  origin="$(iap_origin)"

  # Ahead of even the origin claim, for the same "refuse in milliseconds"
  # reason and one stronger one: this refusal costs no cloud call AND no
  # cluster mutation. See require_local_port_free.
  require_local_port_free "$local_port" "gcp-tf-public"

  # The origin claim comes FIRST, before any cloud call, for the same reason the
  # hosts check used to: a run that is going to be refused because ngrok holds
  # the issuer should be refused in milliseconds, not after a minute of gcloud
  # and a live port-forward.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" = "1" ]; then
    warn "GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 — Dex keeps its current issuer. The dashboard will load at ${origin} and the LOGIN WILL BOUNCE."
  else
    require_dex_origin_mechanism "gcp-tf-public"
    require_no_conflicting_origin "$origin"
  fi

  ensure_published "$port"

  # Claimed AFTER the estate is publishing, unlike the read-only check above.
  # Applying restarts Dex, and Dex runs `storage: type: memory` — doing that
  # before we know the dashboard is being served would log out anyone mid-login
  # for a demo that then turns out not to come up.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" != "1" ]; then
    log "claiming the Dex origin: ${origin}"
    dex_origin apply iap "$origin" ||
      die "could not repoint Dex at ${origin}. The dashboard would load and the login would bounce, so this is a failure rather than a warning."
  fi

  log "opening IAP tunnel: localhost:${local_port} -> ${INSTANCE_NAME}:${port}"
  local tunnel_err
  tunnel_err="$(mktemp "${TMPDIR:-/tmp}/demo-tunnel.XXXXXX.log")"

  env SSH_AUTH_SOCK='' "${GCLOUD[@]}" compute start-iap-tunnel "$INSTANCE_NAME" "$port" \
    --local-host-port="localhost:${local_port}" \
    --zone="$ZONE" --project="$PROJECT_ID" \
    --impersonate-service-account="$OPERATOR_SA" 2>"$tunnel_err" &
  local tunnel_pid=$!

  # Killed by PID, never by pattern — `pkill -f start-iap-tunnel` matches the
  # shell running this script and self-terminates it silently.
  # shellcheck disable=SC2064
  trap "kill ${tunnel_pid} 2>/dev/null || true" EXIT

  local bound=0 waited=0
  while [ "$waited" -lt "$TUNNEL_WAIT_SECONDS" ]; do
    kill -0 "$tunnel_pid" 2>/dev/null || break
    if "$PORT_PROBE" "$local_port"; then bound=1; break; fi
    waited=$((waited + 1))
    sleep 1
  done

  if [ "$bound" -ne 1 ]; then
    local err
    err="$(strip_impersonation_warning <"$tunnel_err" | tail -5)"
    printf '\ndemo-up: the tunnel did not bind localhost:%s within %ds.\n\n  gcloud said:\n%s\n' \
      "$local_port" "$TUNNEL_WAIT_SECONDS" "${err:-    (nothing on stderr)}" >&2
    explain_iap_error "${err}" "$port"
    rm -f "$tunnel_err"
    exit 2
  fi

  # BEFORE the health probe, not after. The probe below is precisely the thing
  # that would launder a hijacked socket into a verdict: it would get its 200
  # from the other lane's healthy dashboard and print "verified before you
  # clicked" about an estate nobody asked for. See assert_tunnel_is_ours.
  if ! assert_tunnel_is_ours "$local_port" "$tunnel_pid" "gcp-tf-public"; then
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    rm -f "$tunnel_err"
    exit 8
  fi

  # Before the health probe, for the same reason ownership is: a 200 collected
  # through the wrong estate is a verdict about the wrong estate.
  require_far_side_lane_identity "$origin" "gcp-tf-public"

  # The bit `connect` does not do. A bound port is not a working demo.
  log "tunnel bound — probing ${origin}${HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_dashboard "$origin")"; then
    {
      printf '\ndemo-up: the tunnel is up but the dashboard did not answer %s.\n' "$HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  The tunnel and the firewall are FINE — this got far enough to ask.\n'
      printf '  What has not: the dashboard pod behind the forward. Check the estate:\n\n'
      printf '    make gcp-tf-demo-status ENV=%s\n' "$ENV_KEY"
      printf '    make gcp-tf-demo-up ENV=%s      # rebuild and re-test\n\n' "$ENV_KEY"
      printf '  An empty status means curl could not connect at all, so the\n'
      printf '  VM-side forward has died since it was started. A 502 or 504 means\n'
      printf '  nginx is up and its upstream is not. A 404 means nginx answered\n'
      printf '  and %s is not one of its locations.\n' "$HEALTH_PATH"
    } >&2
    rm -f "$tunnel_err"
    exit 3
  fi

  rm -f "$tunnel_err"
  print_connect_instructions "$origin"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n\n' \
    "$origin" "$HEALTH_PATH" "$code"
  log "the demo is live at ${origin}. Ctrl-C to close the tunnel."
  wait "$tunnel_pid"
}

# Stop the VM-side forward. The local tunnel dies with its own process.
cmd_public_down() {
  prepare public-down
  local port="$APP_PORT"
  log "stopping the VM-side forward on :${port}"

  # BY UNIT NAME, never by pattern — the same rule the local tunnel follows, and
  # for the same reason. `remote_run` hands this text to a remote `bash -lc`, so
  # the whole command string becomes that shell's /proc/<pid>/cmdline; a
  # `pkill -f 'kubectl port-forward…'` matches its own parent, kills it, and
  # everything after the pkill silently never runs. Measured in this repo as a
  # bare exit 144 with no output at all, which reads as a hung command rather
  # than a self-kill.
  #
  # This used to stop a PID recorded by ensure_published. A unit name is the same
  # discipline with a stronger identity: a PID can be recycled by an unrelated
  # process between publish and teardown, and a stale PID file after a reboot
  # names something that was never the forward. The unit is also the only thing
  # that can stop a supervised forward at all — killing the process under
  # Restart=always just makes systemd start another one five seconds later, so a
  # PID kill here would now report STOPPED and leave the port bound.
  #
  # DISABLE as well as stop: a unit that is merely stopped comes back on the next
  # reboot, which would make teardown a lie that only shows up hours later.
  #
  # An ABSENT unit is reported rather than papered over with a pattern sweep: "I
  # do not know what to stop" is a different answer from "there was nothing to
  # stop", and
  # conflating them is how a forward survives a teardown that claimed success.
  remote_run "
if [ ! -f '${PF_UNIT_PATH}' ]; then
  if ss -ltn 2>/dev/null | grep -q ':${port} '; then
    echo 'UNKNOWN_OWNER'
  else
    echo 'STOPPED'
  fi
  exit 0
fi
sudo systemctl disable --now '${PF_UNIT}.service' >/dev/null 2>&1 || true
sleep 2
ss -ltn 2>/dev/null | grep -q ':${port} ' && echo STILL_PUBLISHING || echo STOPPED"

  # Release the lease, but ONLY if this access method is what holds it.
  #
  # Unconditional restore would be a lease violation with a friendly name: an
  # operator running `public-down` on a machine whose IAP demo is already gone
  # would yank the issuer out from under a live Tailscale or ngrok demo, and the
  # victim's login would start bouncing with nothing anywhere reporting an
  # error. Comparing the published origin to our OWN is the check the mechanism
  # makes available — `current` prints the origin, and if it is not ours then
  # someone else's teardown owns it.
  #
  # Unlike funnel-down, which deliberately keeps the origin because `tailscale
  # serve` is still standing at the same URL, there is nothing left serving here
  # once the forward is stopped. Holding the lease past that point would block
  # every other method for no reason.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" != "1" ] && dex_origin_available; then
    local origin method active
    origin="$(iap_origin)"
    method="$(dex_origin_field holder)"
    active="$(dex_origin_field current)"
    if [ -z "$method" ]; then
      log "no Dex origin is held — nothing to release"
    elif [ "$active" = "$origin" ]; then
      log "releasing the Dex origin ${origin}"
      dex_origin restore || warn "could not release the Dex origin. The next access method will be refused and told that '${origin}' holds it."
    else
      log "leaving the Dex origin alone — '${method}' holds it at ${active}, not this IAP demo"
    fi
  fi
}

cmd_public_status() {
  prepare public-status
  local port="$APP_PORT" origin
  origin="$(iap_origin)"
  printf 'env:       %s\n' "$ENV_KEY"
  printf 'instance:  %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  printf 'url:       %s\n' "$origin"
  printf 'forward:   %s.service is %s\n' "$PF_UNIT" "$(forward_unit_state || true)"
  if remote_is_publishing "$port"; then
    printf 'vm:        PUBLISHING %s/%s on %s:%s\n' \
      "$DASHBOARD_NAMESPACE" "$DASHBOARD_SERVICE" "$FORWARD_BIND_ADDRESS" "$port"
  else
    printf 'vm:        NOT publishing on :%s — run: make gcp-tf-public ENV=%s\n' "$port" "$ENV_KEY"
  fi
  if dex_origin_available; then
    # Two fields, because `current` alone cannot say whether anyone holds it —
    # it reports the resting origin when nobody does. See
    # require_no_conflicting_origin for what conflating those two cost.
    local method active
    method="$(dex_origin_field holder)"
    active="$(dex_origin_field current)"
    if [ -n "$method" ]; then
      printf 'dex origin: %s (held by %s)\n' "$active" "$method"
    else
      printf 'dex origin: %s (resting origin — held by nobody)\n' "$active"
    fi
  else
    printf 'dex origin: UNKNOWN — %s is not in this checkout\n' "$DEX_ORIGIN_REL"
  fi
  local code
  code="$(probe_dashboard_status "$origin")"
  if [ "$code" = "200" ]; then
    printf 'local:     tunnel OPEN and healthy (%s%s -> %s)\n' "$origin" "$HEALTH_PATH" "$code"
  else
    printf 'local:     no healthy tunnel here (%s%s -> %s)\n' \
      "$origin" "$HEALTH_PATH" "${code:-no response}"
  fi
}

cmd_status() {
  prepare status
  printf 'env:      %s\n' "$ENV_KEY"
  printf 'project:  %s\n' "$PROJECT_ID"
  printf 'instance: %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  printf 'handoff:  %s\n' "$HANDOFF_FILE"
  local summary="${REPORT_DIR}/${SUMMARY_NAME}"
  if [ -f "$summary" ]; then
    printf 'verdict:  %s for %s@%s (as of %s)\n' \
      "$(jq -r '.outcome // .overall // "UNKNOWN"' "$summary" 2>/dev/null || echo UNKNOWN)" \
      "$(jq -r '.branch // "unknown"' "$summary" 2>/dev/null || echo unknown)" \
      "$(jq -r '.commit // "unknown"' "$summary" 2>/dev/null || echo unknown)" \
      "$(jq -r '.collected_at // .written_at // "unknown"' "$summary" 2>/dev/null || echo unknown)"
  else
    printf 'verdict:  none — no run has finished in %s\n' "$REPORT_DIR"
  fi

  # Surfaced here as well as in ts-status, because `status` is the command
  # people actually run and a signal that only appears behind a subcommand
  # nobody types is not surfaced at all.
  local ts_name_ok=0
  report_ts_name_marker || ts_name_ok=1
  if [ "$ts_name_ok" -ne 0 ]; then
    printf 'result:   FAILED — see the name mismatch above\n'
    return 1
  fi
}

# Build the payload and stop. Exists so the exclusion list is directly
# inspectable and directly testable without a cloud account: the assertion that
# no secret material rides along must not depend on reaching GCP.
cmd_payload() {
  local out="${1:-}"
  [ -n "$out" ] || die "usage: $(basename "$0") payload <output.tar.gz>"
  build_payload "$out"
  printf '%s\n' "$out"
}

# ── Tailscale: the PRIMARY access path ──────────────────────────────────────
#
# IAP (everything above) stays, tested, as the documented fallback. Tailscale
# leads because it removes the two things that make the IAP path awkward for a
# human, and it removes them for a stated reason rather than by preference:
#
#   1. NO /etc/hosts LINE. The IAP path hands over an SNI hostname that resolves
#      nowhere in the world, so every operator must edit a system file before a
#      browser can reach the demo — see require_hosts_entry, which exists purely
#      to stop that being discovered on the click. MagicDNS resolves the node's
#      name on every device already on the tailnet, so there is nothing to edit.
#   2. NO FOREGROUND TUNNEL. `public` and `connect` hold a gcloud process for as
#      long as the demo is wanted; close the terminal and the demo goes away.
#      A Tailscale node serves for as long as it is up.
#
# It no longer has to work around the SNI problem either, and that paragraph is
# worth reading if you remember the previous version of this block.
#
#   This used to serve THROUGH the Envoy Gateway, which selects its route by
#   SNI. Browsing https://<node>.<tailnet>.ts.net at a Gateway-forwarded port
#   failed exactly as https://localhost:30754 did, and the workaround was
#   ensure_vm_hosts_alias: give the Gateway's hostname a loopback alias ON THE
#   VM so `tailscale serve` could dial its backend by that name and supply the
#   SNI value. It worked, and it was one more thing to be wrong.
#
#   The forward now targets the dashboard's nginx, which routes by PATH over
#   plain HTTP. There is no name to match, so `tailscale serve` dials
#   http://127.0.0.1:<port> and the alias — along with the whole class of
#   handshake failures that read as a dead dashboard — is gone.
#
# `tailscale serve` still terminates TLS with a real, publicly-trusted
# certificate for the MagicDNS name. That is what makes this origin https://
# while the IAP one is http://, and dex-origin.sh enforces exactly that
# distinction: cleartext on loopback only.
#
# ── The origin changes, and Dex has exactly one issuer ──────────────────────
#
# A browser reaching the demo at https://<node>.<tailnet>.ts.net is at a
# DIFFERENT ORIGIN from the IAP path's http://localhost:<port>, and Dex pins its
# OIDC issuer and its callback client to one origin at a time. Left alone, the
# dashboard loads over Tailscale and the login bounces — which presents as a
# broken application, not as an origin mismatch, and is the single most
# expensive failure shape this lane has. Every path below that changes the
# browser-visible origin therefore claims it through dex_origin() and refuses
# when something else holds it.
#
# ── Funnel is the same URL, made PUBLIC ─────────────────────────────────────
#
# `tailscale serve` and `tailscale funnel` publish the same MagicDNS name with
# the same certificate; funnel additionally routes it from the public internet
# over Tailscale's edge. That is why funnel-up does not re-patch Dex — the
# origin is identical — and why funnel-down leaves serve standing: the demo is
# still live on the tailnet after the public listener is switched off.

# Injectable like everything else in this file, so the whole Tailscale control
# flow is exercisable against a stub binary with no tailnet and no cloud.
TAILSCALE_CMD="${GCP_TF_DEMO_TAILSCALE:-tailscale}"

# The status cmd_ts_logout uses to mean "I refused", distinct from every other
# status this file can produce. See the long note above cmd_ts_logout.
TS_LOGOUT_REFUSED=97

# The node's SHORT hostname. Deterministic from the environment key, because
# chunk T1 derives it the same way in Terraform and a name typed in two places
# is a name that disagrees in one of them.
#
# Resolution order mirrors OPERATOR_SA's: explicit override, then the hand-off
# field T1 publishes, then the derivation. The derivation is last rather than
# absent so this file is usable before T1's output block lands.
ts_node_hostname() {
  local from_handoff=""
  if [ -n "$HANDOFF_FILE" ] && [ -f "$HANDOFF_FILE" ]; then
    from_handoff="$(jq -r '.tailscale_hostname // ""' "$HANDOFF_FILE" 2>/dev/null || true)"
  fi
  printf '%s' "${GCP_TF_DEMO_TS_HOSTNAME:-${from_handoff:-sl-${ENV_KEY}}}"
}

# The tailnet's MagicDNS suffix is deliberately NOT a constant in this file.
#
# It could be one — it is stable per tailnet — but `tailscale status --json`
# already carries the node's fully-qualified DNSName, which is the name a
# browser and `getent` will both use. Deriving it from the live tailnet means
# there is no second place for it to be wrong, and no way for this file to
# promise a URL under a tailnet the operator is not actually on.
ts_status_json() {
  "$TAILSCALE_CMD" status --json 2>/dev/null || printf ''
}

# Where the VM records that it did NOT get the MagicDNS name it asked for.
#
# Written by assert_tailscale_node_name in
# terraform/modules/compute/startup/demo-vm.sh. The path is a contract between
# these two files and is stated in both.
TS_NAME_MARKER="${GCP_TF_DEMO_TS_NAME_MARKER:-/var/lib/signalloom/tailscale-name-mismatch}"

# The marker's contents, or empty. NEVER fails, and the distinction it refuses
# to make is deliberate: an unreachable VM, a missing file and an empty file all
# come back as "no mismatch recorded".
#
# That is the right call ONLY because this is a supplementary signal on a status
# command that has already reported whether the VM is reachable. It is not a
# health check in its own right, and callers must not treat "empty" as "the node
# name is verified" — it means "nothing on that VM says otherwise".
ts_name_marker() {
  remote_run "cat ${TS_NAME_MARKER} 2>/dev/null || true" 2>/dev/null || printf ''
}

# Is the node currently serving? Prints exactly one of: present, absent, unknown.
#
# ─── THREE answers, not a boolean ───────────────────────────────────────────
#
# The third is the whole reason this is not a boolean. Only two things are
# positive evidence of ABSENCE: `{}` from the JSON form, or the literal
# `No serve config` from the prose one. An empty reply, an SSH failure, a sudo
# refusal and a stopped tailscaled all produce nothing — and collapsing those
# into "absent" would make an unreachable node look like a safe one to log out,
# which is the exact mistake that wipes a live demo.
#
# ─── MEASURED CONTRACT, on the real image ───────────────────────────────────
#
# sl-demo-1-vm, idle node, tailscale 1.102.3, 2026-08-20:
#
#   $ sudo tailscale serve status
#   EXIT=0  STDOUT=[No serve config]  STDERR=[]  STDOUT_BYTES=15
#
#   $ sudo tailscale serve status --json
#   {}
#   EXIT=0
#
# Corroborated on demo-2 during the serve-survival experiment, where the same
# prose string appeared after a logout cycle.
#
# ─── Why BOTH forms, in this order ──────────────────────────────────────────
#
# `--json` is asked first because `{}` is a far stabler contract than a prose
# sentence: a future release is much likelier to reword "No serve config" than
# to stop emitting `{}` for an empty config.
#
# The prose form is kept as a FALLBACK rather than deleted, because the reverse
# risk is real too — an older or stripped build without `--json` would answer
# nothing, and a JSON-only probe would then return "unknown" and refuse every
# unforced logout. Asking both means either contract can break on its own and
# this still returns a usable answer. Both paths are independently tested;
# neither is dead code standing in for the other.
#
# DO NOT loosen either comparison. `{}` is matched after whitespace stripping,
# and the prose match is on the exact sentence. Widening these to something
# like "empty" or a substring of the URL is how a serving node starts reading
# as idle.
ts_serve_state() {
  local json prose

  json="$(remote_run 'sudo tailscale serve status --json 2>/dev/null' 2>/dev/null || printf '')"
  json="$(printf '%s' "$json" | tr -d '[:space:]')"

  if [ -n "$json" ]; then
    if [ "$json" = "{}" ]; then
      printf 'absent'
    else
      printf 'present'
    fi
    return 0
  fi

  prose="$(remote_run 'sudo tailscale serve status 2>&1' 2>/dev/null || printf '')"

  if [ -z "$(printf '%s' "$prose" | tr -d '[:space:]')" ]; then
    printf 'unknown'
    return 0
  fi

  case "$prose" in
    *"No serve config"*) printf 'absent' ;;
    *) printf 'present' ;;
  esac
}

# Prints the mismatch block if there is one and returns 1; prints nothing and
# returns 0 otherwise. The return value is what makes a status command FAIL, and
# failing is the point: the VM is up, Tailscale is up, and the URL is wrong.
# Reporting that as a healthy estate is how the drift survived three rebuilds.
report_ts_name_marker() {
  local marker
  marker="$(ts_name_marker)"
  [ -n "$marker" ] || return 0

  printf 'ts name:   MISMATCH — this node does not own the name the demo URL uses\n'
  printf '%s\n' "$marker" | sed 's/^/           /'
  return 1
}

# Resolved by ts_resolve_node. FQDN carries no trailing dot.
TS_FQDN=""
TS_IP=""
TS_ONLINE=""

# Find this environment's node in the tailnet and fill TS_FQDN / TS_IP /
# TS_ONLINE. Returns non-zero with a diagnosis on stderr, having named which of
# the five distinguishable causes applies — no client, no daemon, no such node,
# no MagicDNS name, or offline. They are separated because each invites a
# completely different next move, and a single "tailscale is not working"
# message sends the reader to the admin console for a missing package.
#
# Local only: it asks the tailscaled on THIS machine, so it costs milliseconds,
# needs no credentials, and — the point — runs before any cloud call, so an
# operator whose node is not up is told so immediately rather than after a
# minute of gcloud.
ts_resolve_node() {
  local host json node
  host="$(ts_node_hostname)"

  if ! command -v "$TAILSCALE_CMD" >/dev/null 2>&1; then
    cat >&2 <<EOF
demo-up: no '${TAILSCALE_CMD}' on PATH.

  The Tailscale access path needs a tailscale client on THIS machine, because
  MagicDNS is what makes the demo URL resolve here without a hosts file.

      https://tailscale.com/download

  Then join the tailnet and re-run. If you cannot install it, the IAP path is
  still fully supported:

      make gcp-tf-public ENV=${ENV_KEY}
EOF
    return 2
  fi

  json="$(ts_status_json)"
  if [ -z "$json" ]; then
    cat >&2 <<EOF
demo-up: '${TAILSCALE_CMD} status --json' returned nothing.

  tailscaled is not running here, or this machine is logged out of the tailnet.
  This says nothing about the demo VM — it is a statement about THIS machine.

      sudo tailscale up
      tailscale status
EOF
    return 2
  fi

  # .Self is included so the lookup still works when this driver is run FROM
  # the demo node itself, which is a legitimate way to debug it.
  node="$(printf '%s' "$json" |
    jq -c --arg h "$host" \
      '[.Self // empty] + [(.Peer // {}) | .[]] | map(select((.HostName // "") == $h)) | first // empty' \
      2>/dev/null || printf '')"

  if [ -z "$node" ]; then
    local seen
    seen="$(printf '%s' "$json" |
      jq -r '[.Self // empty] + [(.Peer // {}) | .[]] | map(.HostName // empty) | join(", ")' \
        2>/dev/null || printf '')"
    cat >&2 <<EOF
demo-up: no node named '${host}' in this tailnet.

  Three causes, and they are distinguishable only from the admin console:

    1. The VM has not joined. Its tailscaled is ephemeral, so a node that has
       been down long enough is REMOVED from the tailnet rather than shown
       offline — an absent node is the expected look of a suspended demo VM.
       Bring the estate up:   make gcp-tf-demo-up ENV=${ENV_KEY}
    2. The auth key expired, or 'tag:sl-demo' has no tagOwners entry, so the
       node was never approved. See docs/gcp-demo/RUNBOOK.md § "One-time
       Tailscale admin console setup".
    3. An ACL rule hides it from your user. A node you cannot see and a node
       that does not exist look identical from here.

  Nodes visible to you right now: ${seen:-(none)}
EOF
    return 2
  fi

  TS_FQDN="$(printf '%s' "$node" | jq -r '.DNSName // ""' | sed 's/\.$//')"
  TS_IP="$(printf '%s' "$node" | jq -r '.TailscaleIPs[0] // ""')"
  TS_ONLINE="$(printf '%s' "$node" | jq -r 'if .Online == true then "true" else "false" end')"

  if [ -z "$TS_FQDN" ]; then
    cat >&2 <<EOF
demo-up: node '${host}' is in the tailnet but has no MagicDNS name.

  MagicDNS is disabled for this tailnet. Without it the node has an IP and no
  name, and a certificate cannot be issued for it — so 'tailscale serve' has
  nothing to terminate TLS with and there is no URL to hand over.

  Enable it once, in the admin console:
      https://login.tailscale.com/admin/dns  ->  MagicDNS: on
EOF
    return 2
  fi

  # Checked AFTER the name, because an offline node still reports its DNSName
  # and reporting "no name" for an offline node would be a wrong diagnosis.
  if [ "$TS_ONLINE" != "true" ]; then
    cat >&2 <<EOF
demo-up: node '${TS_FQDN}' is in the tailnet but OFFLINE.

  The VM is suspended, or its tailscaled is not running.
  This is not a name resolution problem and not an ACL problem — the node is
  known to the tailnet by name, and it is not answering.

      make gcp-tf-demo-status ENV=${ENV_KEY}    # is the VM even running?
      make gcp-tf-demo-up ENV=${ENV_KEY}        # bring the estate back up
EOF
    return 2
  fi

  return 0
}

# Does THIS machine actually RESOLVE the node's name?
#
# The direct analogue of require_hosts_entry on the IAP path, and it exists for
# the same reason: a health probe that reaches the dashboard proves nothing
# about whether a browser here can reach the same URL. The difference is only
# that the fix is a tailnet setting rather than a line in a file — the failure
# it prevents, promising a URL that does not resolve on the click, is identical.
#
# ts_resolve_node has already established that the node HAS a MagicDNS name.
# This is the separate question of whether this machine's resolver returns it,
# which is what a browser will do.
#
# getent, not ping or curl: it asks the name-service switch the same question
# the browser will, so the tailscale resolver, /etc/hosts and nsswitch all
# count.
magicdns_resolves() {
  getent hosts "$TS_FQDN" >/dev/null 2>&1
}

require_magicdns() {
  if magicdns_resolves; then
    log "${TS_FQDN} resolves here — a browser on this machine can reach it"
    return 0
  fi

  if [ "${GCP_TF_DEMO_SKIP_MAGICDNS_CHECK:-0}" = "1" ]; then
    warn "${TS_FQDN} does not resolve here. Continuing because GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1 — a scripted curl against the tailnet IP will still work, a browser will not."
    return 0
  fi

  cat >&2 <<EOF
demo-up: ${TS_FQDN} does not resolve on this machine.

  The node is up and the tailnet knows its name — this check is about THIS
  machine's resolver, and it runs first precisely so you do not wait for a
  healthy estate and then discover the browser cannot use it.

  In order of likelihood:

    1. MagicDNS is off for your device. 'tailscale up --accept-dns' turns the
       tailnet's resolver back on; a device brought up with --accept-dns=false
       stays on its old DNS and resolves nothing in the tailnet.
    2. MagicDNS is off for the whole TAILNET:
       https://login.tailscale.com/admin/dns  ->  MagicDNS: on
    3. Something local overrode /etc/resolv.conf after tailscaled wrote it.
       'tailscale status' will still look perfectly healthy.

  Its tailnet IP is ${TS_IP:-unknown}, so a scripted probe can proceed without
  a resolver:

      GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1 make gcp-tf-ts-up ENV=${ENV_KEY}
EOF
  exit 4
}

# One HTTP probe at the MagicDNS URL. Status code on stdout, empty string when
# the request could not be made at all.
#
# NO -k, unlike probe_dashboard_status. That is a deliberate difference rather
# than an inconsistency: the IAP path probes a self-signed in-cluster
# certificate through a tunnel Google has already authenticated, whereas here
# the certificate is a real one issued to the MagicDNS name. If it does not
# verify, HTTPS certs are not enabled for the tailnet — which is a cause worth
# surfacing, and -k would hide it behind a healthy-looking 200.
TS_HEALTH_PATH="${GCP_TF_DEMO_TS_HEALTH_PATH:-${HEALTH_PATH}}"

probe_ts_status() {
  local base="$1"
  "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${base}${TS_HEALTH_PATH}" 2>/dev/null || printf ''
}

# ─── The readiness gate goes through wait.sh, and the boot helper does not ───
#
# This is the RUNTIME half of a deliberate split.
#
# The boot-time unit (terraform/modules/compute/startup/demo-vm.sh) polls with a
# bounded hand-rolled loop, and has to: scripts/lib/wait.sh arrives on the VM
# via deliver_code, long AFTER the startup script has run, so on a freshly built
# instance the file does not exist at the moment the serve unit needs it. That
# loop is measured rather than assumed — 37ms to completion against its 120s
# ceiling on a live node — because a ceiling nobody has watched burn is where
# decorative gates hide.
#
# Here there is no such constraint, so the instrumented primitive is used. What
# that buys over the fixed-interval loop this replaces:
#
#   * DEADLINE, not attempt count — slow-but-eventually is a pass under load.
#   * exponential backoff with jitter, instead of a synchronised 5s poll.
#   * a per-attempt hang fence, so one wedged curl cannot eat the whole budget.
#   * a one-time ⚠ warning at 60% of budget that does NOT fail the wait.
#   * a WAIT_STAT line, so `scripts/cluster-debug.sh` can rank this wait against
#     every other one in the estate. "Is tailscale serve slow on 8 cores" then
#     has an answer instead of an opinion.
#
# The STATUS CODE is still fetched separately afterwards, and that is not
# redundancy. `wait_reachable` answers a boolean — it uses `curl -f`, so 502,
# 404 and a TLS failure are all simply "not yet". The caller's diagnosis branches
# on WHICH of those it was (empty means the certificate did not verify, 502 means
# serve reached the VM and found nothing, 404 means the dashboard image predates
# this checkout), and losing that would trade three actionable messages for one
# useless one. So: wait.sh does the waiting, probe_ts_status supplies the code.
wait_for_ts_dashboard() {
  local base="$1" code=''

  # stdout redirected, and this is not tidiness. This function's stdout IS its
  # return value — the caller reads it with `code="$(wait_for_ts_dashboard …)"`
  # — so anything the wait writes there is concatenated onto the status code.
  # Caught by a test reporting `returned 200200`: the probe's own output had
  # been glued to the probe's result. stderr is left alone deliberately, because
  # the WAIT_STAT line and the slow-wait warning are the instrumentation this
  # change exists to add.
  # _wait_retry, NOT wait_reachable. The wrapper's probe string hardcodes a
  # literal `curl`; this one is built from CURL_BIN, so an injected transport is
  # actually used. See the long note beside the source of wait.sh.
  #
  # The probe is byte-for-byte wait_reachable's, with `curl` replaced by
  # "${CURL_BIN}" — same flags, same hang fence, same semantics: `-f` makes any
  # HTTP status >= 400 a failure, which is what makes this a readiness wait
  # rather than a reachability one.
  local url="${base}${TS_HEALTH_PATH}"
  if _wait_retry "$HEALTH_WAIT_SECONDS" "reachable ${url}" \
    "'${CURL_BIN}' -fsS --max-time ${WAIT_ATTEMPT_TIMEOUT:-10} -o /dev/null '${url}'" >/dev/null; then
    printf '%s' "$(probe_ts_status "$base")"
    return 0
  fi

  # One probe on the failure path, to name the cause rather than the symptom.
  code="$(probe_ts_status "$base")"
  printf '%s' "$code"
  return 1
}

# ── ensure_vm_hosts_alias is GONE ───────────────────────────────────────────
#
# It wrote `127.0.0.1 dashboard.osramp.acme.local` into the VM's /etc/hosts so
# `tailscale serve` could dial its backend BY NAME and thereby supply the SNI
# value the Envoy Gateway routed on. An IP literal sends no SNI at all and the
# Gateway closed the connection mid-handshake, which read as a dead dashboard.
#
# The backend is nginx now. It routes by path, terminates no TLS and inspects no
# hostname, so the alias has nothing left to do — and a mutation of the VM's
# /etc/hosts that is no longer required is not something to leave running "just
# in case".

# `tailscale serve` (tailnet-only) or `tailscale funnel` (public), on the VM.
#
# One function for both because they differ in exactly one word and in exactly
# one property, and writing them twice is how the two drift.
TS_SERVE_PORT="${GCP_TF_DEMO_TS_SERVE_PORT:-443}"

# ── Serving has to survive the machine, not just the session ────────────────
#
# `tailscale serve --bg` writes its config into tailscaled's state, so it does
# survive a reboot on its own. What it does NOT survive is a `tailscale logout`,
# and this estate performs one on shutdown by design
# (signalloom-tailscale-logout.service, installed by the startup script) so the
# next build can reclaim the MagicDNS name. The node then returns online, with
# the right name, resolving through MagicDNS — and serving nothing. Measured on
# demo-2; the full account is above cmd_ts_logout.
#
# So the serve config is re-asserted at every boot by a unit, for exactly the
# reason signalloom-dashboard-pf.service exists: "it is what makes the forward
# come back from a reboot without anyone SSHing in — which is the manual step
# this whole mechanism exists to delete."
#
# THIS IS CONSTRUCTION, NOT A REPAIRING DETECTOR. The distinction matters in
# this repo, which has shipped guards that fixed their own symptom and thereby
# hid the broken component. Nothing here inspects a failure and patches it; the
# unit declares what the machine should be doing, the same way the port-forward
# unit does. The DETECTOR is ts-status, and it was made able to fail in the same
# change — a durable serve and an honest health check are two halves of one fix,
# because either alone still lets a dead URL read as healthy.
#
# FUNNEL IS DELIBERATELY EXCLUDED, and this is a security property rather than
# an oversight. A boot-time unit that re-asserted `tailscale funnel` would
# restore a PUBLIC internet listener automatically after every reboot, so an
# operator who ran funnel-up once for a demo would be publishing this estate
# forever without another decision. Funnel keeps the one-shot behaviour it has
# always had: it goes on when somebody asks for it and it does not come back by
# itself. There is a test that fails if a funnel-up ever installs this unit.
TS_SERVE_UNIT="${GCP_TF_DEMO_TS_SERVE_UNIT:-signalloom-tailscale-serve}"
TS_SERVE_UNIT_PATH="/etc/systemd/system/${TS_SERVE_UNIT}.service"
TS_SERVE_HELPER_PATH="/usr/local/sbin/${TS_SERVE_UNIT}"

# How long the boot-time helper waits for tailscaled to finish authenticating
# before it gives up. Generous: on a cold boot the node has to reach the control
# plane and be re-approved, which is slower than the unit ordering suggests.
TS_SERVE_UNIT_WAIT_SECONDS="${GCP_TF_DEMO_TS_SERVE_UNIT_WAIT_SECONDS:-120}"

# Is the boot-time re-assertion in place? Prints a bare word: `enabled`, or
# whatever systemd says instead (`disabled`, `static`, `masked`), or empty when
# the question could not be asked at all.
#
# `is-enabled` rather than `is-active` — see the comment at its call site in
# cmd_ts_status. A oneshot with RemainAfterExit reports `active` after a
# successful run and `inactive` after a failed one, and neither answers the
# question this exists to ask, which is whether the next boot will serve.
ts_serve_unit_state() {
  remote_run "systemctl is-enabled ${TS_SERVE_UNIT}.service 2>/dev/null || true" 2>/dev/null |
    tr -d '\r' | tr -d '[:space:]'
}

# Install (or refresh) the boot-time re-assertion of `tailscale serve`.
#
# Two files, not one, and the split is deliberate. systemd does not run a shell,
# so an ExecStart carrying a retry loop would have to be `/bin/bash -c '…'` with
# the whole loop quoted through a heredoc inside a function — the shape that
# produces a unit nobody can read and nobody notices is subtly wrong. The unit
# stays trivial and the logic lives in a script that can be read, run by hand
# and diffed.
#
# The retry loop is not defensive padding. `tailscale serve` against a tailscaled
# that is running but not yet authenticated fails immediately, and a oneshot with
# no retry would leave the unit failed and the URL dead for the whole uptime of
# the machine — reintroducing the exact silent failure this is here to remove.
#
# Idempotent by content comparison, like ensure_published: rewriting a unit that
# is already correct means a daemon-reload and a restart for nothing.
ensure_ts_serve_unit() {
  local port="$1"
  local backend="http://127.0.0.1:${port}"

  log "installing ${TS_SERVE_UNIT}.service on ${INSTANCE_NAME} so serving survives a reboot"

  local script
  script=$(cat <<REMOTE
set -uo pipefail
# Not set -e: the probes below are expected to fail on a node that is still
# coming up, and each needs to produce its own marker rather than aborting the
# script with empty stdout.

TAILSCALE_BIN="\$(command -v tailscale 2>/dev/null || true)"
if [ -z "\$TAILSCALE_BIN" ]; then
  echo "NO_TAILSCALE" >&2
  exit 3
fi

HELPER_BODY="#!/usr/bin/env bash
# Re-assert this node's tailnet HTTPS listener at boot.
#
# WRITTEN BY scripts/gcp-tf/demo-up.sh (ensure_ts_serve_unit). Edit it there.
#
# Exists because 'tailscale logout' wipes the serve config and this estate logs
# out on shutdown so the next build can reclaim the MagicDNS name. Without this
# the node comes back online, correctly named, serving nothing.
set -uo pipefail

WAITED=0
while [ \"\\\$WAITED\" -lt ${TS_SERVE_UNIT_WAIT_SECONDS} ]; do
  if \${TAILSCALE_BIN} status --json 2>/dev/null | grep -q '\"BackendState\": *\"Running\"'; then
    break
  fi
  sleep 3
  WAITED=\\\$((WAITED + 3))
done

exec \${TAILSCALE_BIN} serve --bg --https=${TS_SERVE_PORT} '${backend}'
"

UNIT_BODY="[Unit]
Description=Signal Loom tailnet HTTPS listener (tailscale serve)
Documentation=https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/docs/gcp-demo/RUNBOOK.md
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${TS_SERVE_HELPER_PATH}
# The helper does its own waiting, so this is a ceiling on a node that never
# authenticates rather than the mechanism that makes it work.
TimeoutStartSec=${TS_SERVE_UNIT_WAIT_SECONDS}s

[Install]
WantedBy=multi-user.target
"

CHANGED=0
if [ ! -f ${TS_SERVE_HELPER_PATH} ] || ! printf '%s' "\$HELPER_BODY" | sudo cmp -s - ${TS_SERVE_HELPER_PATH}; then
  printf '%s' "\$HELPER_BODY" | sudo tee ${TS_SERVE_HELPER_PATH} >/dev/null || { echo "HELPER_WRITE_FAILED" >&2; exit 6; }
  sudo chmod 0755 ${TS_SERVE_HELPER_PATH} || { echo "HELPER_CHMOD_FAILED" >&2; exit 6; }
  CHANGED=1
fi

if [ ! -f ${TS_SERVE_UNIT_PATH} ] || ! printf '%s' "\$UNIT_BODY" | sudo cmp -s - ${TS_SERVE_UNIT_PATH}; then
  printf '%s' "\$UNIT_BODY" | sudo tee ${TS_SERVE_UNIT_PATH} >/dev/null || { echo "UNIT_WRITE_FAILED" >&2; exit 6; }
  sudo systemctl daemon-reload || { echo "DAEMON_RELOAD_FAILED" >&2; exit 7; }
  CHANGED=1
fi
echo "serve_unit_changed=\${CHANGED}"

# enable, NOT enable --now. The caller has already applied the serve config
# directly, so starting the unit here would re-run the same command for no
# benefit; what is wanted from this step is the multi-user.target link, which is
# the thing that makes the next boot serve.
sudo systemctl enable ${TS_SERVE_UNIT}.service >/dev/null 2>&1 || { echo "UNIT_ENABLE_FAILED" >&2; exit 8; }

# Asserted, never assumed. \`systemctl enable\` can exit 0 having done nothing
# useful for a unit systemd declines to link, and an unverified enable is
# precisely the shape that reports a durable listener that is not one.
STATE="\$(sudo systemctl is-enabled ${TS_SERVE_UNIT}.service 2>/dev/null || true)"
if [ "\$STATE" != "enabled" ]; then
  echo "UNIT_NOT_ENABLED:\${STATE:-unknown}" >&2
  exit 9
fi
echo SERVE_UNIT_ENABLED
exit 0
REMOTE
)

  local rc=0
  remote_run "$script" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A WARNING and not a die, and the asymmetry is the point. The URL is
    # already live at this point — ensure_ts_serve applied the serve config
    # before this ran — so failing here would take down a working handover over
    # a durability property. What must never happen is this failing SILENTLY,
    # because the operator would then believe serving survives a reboot when it
    # does not. It is loud here and it is a permanent line in ts-status.
    warn "could not install ${TS_SERVE_UNIT}.service on ${INSTANCE_NAME} (step exited ${rc}). The tailnet URL is live NOW and will NOT come back on its own after a reboot or a 'tailscale logout' — the node would return online, correctly named, serving nothing. 'make gcp-tf-ts-status ENV=${ENV_KEY}' reports this on the 'ts serve unit' line. Causes: 3 no tailscale on the VM, 6/7 sudo refused the write or the reload, 8/9 systemd would not enable the unit."
  fi
  return 0
}

ensure_ts_serve() {
  local verb="$1" port="$2" # verb: serve | funnel
  # `http://127.0.0.1:<port>`, not `https+insecure://<sni-name>:<port>`.
  #
  # Both halves of that change are load-bearing. The scheme is http because the
  # VM-side forward now carries nginx's cleartext 8080 rather than the Gateway's
  # TLS 443, so `https+insecure` would fail the handshake against a server that
  # speaks no TLS. The host is a loopback literal because there is no longer an
  # SNI name to supply — which is precisely why the /etc/hosts alias above could
  # be deleted rather than kept.
  #
  # This leg being cleartext is not a downgrade: it is loopback ON THE VM,
  # inside the same machine, and `tailscale serve` still terminates real TLS for
  # everything that arrives from outside.
  local backend="http://127.0.0.1:${port}"
  log "configuring 'tailscale ${verb}' on ${INSTANCE_NAME}: :${TS_SERVE_PORT} -> ${backend}"
  remote_run "sudo tailscale ${verb} --bg --https=${TS_SERVE_PORT} \
    '${backend}' && echo ${verb^^}_CONFIGURED" ||
    die "'tailscale ${verb}' failed on ${INSTANCE_NAME}. If it named a certificate, HTTPS certs are not enabled for this tailnet (admin console -> DNS -> HTTPS Certificates). If it named funnel, the tailnet policy has no nodeAttrs entry granting 'funnel' to tag:sl-demo. Neither is fixable from here."

  # The direct call above is what makes the URL live in this run; the unit is
  # what makes it live again after the machine restarts. Both, rather than only
  # the unit, because the direct call is the proven path that already serves
  # four lanes and a handover should not start depending on a systemd unit
  # starting correctly to work at all.
  #
  # `serve` only. Re-asserting `funnel` at boot would restore a public listener
  # nobody asked for a second time — see the long note above TS_SERVE_UNIT.
  if [ "$verb" = "serve" ]; then
    ensure_ts_serve_unit "$port"
  fi
}

print_ts_instructions() {
  local url="$1"
  cat <<EOF

════════════════════════════════════════════════════════════════════
  Signal Loom demo — ${ENV_KEY}  (Tailscale)
════════════════════════════════════════════════════════════════════

  URL:      ${url}

  1. There is NOTHING to add to /etc/hosts. MagicDNS resolves this name on
     every device already on the tailnet, which is the whole reason this is
     the primary path.

  2. The certificate is a REAL one, issued to the MagicDNS name. No browser
     warning to click through, unlike the IAP path's self-signed Gateway cert.

  3. Log in through Dex:

         username: ${DEMO_LOGIN_USER}
         password: ${DEMO_LOGIN_PASS}

  4. Reachable from any device on the tailnet — including a phone — with no
     tunnel held open in a terminal. Nothing here has to stay running.

  Confirm it from anywhere on the tailnet:

      curl ${url}${TS_HEALTH_PATH}

════════════════════════════════════════════════════════════════════
EOF
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_ts_status() {
  prepare ts-status
  local host
  host="$(ts_node_hostname)"

  printf 'env:       %s\n' "$ENV_KEY"
  printf 'instance:  %s (%s)\n' "$INSTANCE_NAME" "$(vm_status)"
  printf 'ts node:   %s\n' "$host"

  if ! ts_resolve_node; then
    printf 'ts state:  NOT USABLE — see the diagnosis above\n'
    return 1
  fi

  printf 'magicdns:  %s\n' "$TS_FQDN"
  printf 'tailnet ip: %s\n' "${TS_IP:-unknown}"
  printf 'online:    %s\n' "$TS_ONLINE"

  if magicdns_resolves; then
    printf 'resolves:  yes — a browser here can reach it\n'
  else
    printf 'resolves:  NO — this machine does not resolve %s (MagicDNS off for this device or tailnet)\n' "$TS_FQDN"
  fi

  # ─── FOUR facts, four lines, never one verdict ────────────────────────────
  #
  # Node state (above), name-marker state, serve state and forward-unit state
  # are reported SEPARATELY and in that order. Each can be wrong while the
  # other three are right, and every pairing has a real failure behind it:
  #
  #   right name, no serve     what `tailscale logout` on a live node leaves
  #   right serve, wrong name  a rebuild that inherited a suffixed name
  #   both fine, no forward    the unit died and nothing is behind the URL
  #
  # Collapsing any pair into a single "healthy" is what hides all three. This
  # ordering is also the causal one — a reader works outwards from the node to
  # the thing serving on it — so the first line that is wrong is the one to act
  # on.
  #
  # The marker comes first among these, and BEFORE the dashboard probe below,
  # because a healthy 200 from the WRONG node is the single most misleading
  # line this command can emit.
  local ts_name_ok=0
  report_ts_name_marker || ts_name_ok=1

  local serve_state
  serve_state="$(ts_serve_state)"
  case "$serve_state" in
    present) printf 'ts serve:  configured — the tailnet URL is being served\n' ;;
    absent) printf 'ts serve:  ABSENT — nothing served on the tailnet. Run: make gcp-tf-ts-up ENV=%s\n' "$ENV_KEY" ;;
    *) printf 'ts serve:  UNKNOWN — could not read serve status from %s\n' "$INSTANCE_NAME" ;;
  esac

  # The FIFTH fact, and it is about the FUTURE rather than the present: a serve
  # config that nothing re-asserts is one reboot — or one `tailscale logout` —
  # away from gone, and every other line here would still read green afterwards.
  # `is-enabled`, not `is-active`: the unit is a oneshot, so `active` says only
  # that it ran once, while `enabled` is the property that survives a boot.
  local serve_unit_state
  serve_unit_state="$(ts_serve_unit_state)"
  case "$serve_unit_state" in
    enabled) printf 'ts serve unit: %s.service is enabled — serving comes back after a reboot\n' "$TS_SERVE_UNIT" ;;
    *) printf 'ts serve unit: %s.service is %s — NOT durable. A reboot or a logout leaves this node online, correctly named and serving nothing. Run: make gcp-tf-ts-up ENV=%s\n' \
      "$TS_SERVE_UNIT" "${serve_unit_state:-unknown}" "$ENV_KEY" ;;
  esac

  printf 'forward:   %s.service is %s\n' "$PF_UNIT" "$(forward_unit_state || true)"
  if remote_is_publishing "$APP_PORT"; then
    printf 'vm:        PUBLISHING %s/%s on %s:%s\n' \
      "$DASHBOARD_NAMESPACE" "$DASHBOARD_SERVICE" "$FORWARD_BIND_ADDRESS" "$APP_PORT"
  else
    printf 'vm:        NOT publishing on :%s — run: make gcp-tf-ts-up ENV=%s\n' "$APP_PORT" "$ENV_KEY"
  fi

  if dex_origin_available; then
    # NOT "the IAP origin" when unheld. IAP claims http://localhost:<port> like
    # any other method now, so an unheld origin means nobody is publishing —
    # naming a method would send a reader hunting for a tunnel that does not
    # exist. And the holder is read from the METHOD key rather than inferred
    # from the origin string, because `current` reports the resting origin at
    # rest and is therefore never empty.
    local method active
    method="$(dex_origin_field holder)"
    active="$(dex_origin_field current)"
    if [ -n "$method" ]; then
      printf 'dex origin: %s (held by %s)\n' "$active" "$method"
    else
      printf 'dex origin: %s (resting origin — held by nobody)\n' "$active"
    fi
  else
    printf 'dex origin: UNKNOWN — %s is not in this checkout\n' "$DEX_ORIGIN_REL"
  fi

  local base code
  base="https://${TS_FQDN}"
  code="$(probe_ts_status "$base")"
  if [ "$code" = "200" ]; then
    printf 'dashboard: HEALTHY (%s%s -> 200)\n' "$base" "$TS_HEALTH_PATH"
  else
    printf 'dashboard: not answering (%s%s -> %s)\n' "$base" "$TS_HEALTH_PATH" "${code:-no response}"
  fi

  # ── The VERDICT, and why it is not just the name marker ────────────────────
  #
  # This used to return 0 for everything except a recorded name mismatch. Every
  # other fact was PRINTED and none of them could fail the command, so a node
  # that was online, correctly named, resolving, and serving absolutely nothing
  # exited 0. Measured on sl-ci-1, 2026-08-20:
  #
  #   ts serve:  ABSENT — nothing served on the tailnet.
  #   vm:        NOT publishing on :30754
  #   dashboard: not answering (https://sl-ci-1.<tailnet>.ts.net/readyz -> 000)
  #   EXIT=0
  #
  # Three lines saying the URL is dead, and a green exit status. Anything that
  # consumed the status rather than reading the prose — a sweep, a Make target,
  # a person typing `&& echo ok` — was told the lane was fine. A health check
  # that cannot see the failure it exists to catch is worse than none, because
  # it also stops anyone from writing one that can.
  #
  # Every fact is still reported SEPARATELY and in full before this runs. The
  # verdict names which of them failed rather than collapsing them, so the
  # command still answers "what is wrong" and not merely "something is".
  local -a failures=()
  [ "$ts_name_ok" -eq 0 ] || failures+=("the node name is not the one this environment publishes")
  case "$serve_state" in
    present) ;;
    absent) failures+=("nothing is being served on the tailnet") ;;
    *) failures+=("the serve state could not be read, so this cannot say the URL is live") ;;
  esac
  [ "$code" = "200" ] || failures+=("the dashboard did not answer ${TS_HEALTH_PATH} (${code:-no response})")

  if [ "${#failures[@]}" -ne 0 ]; then
    printf 'ts state:  FAILED — the tailnet URL for %s is not usable\n' "$ENV_KEY"
    local f
    for f in "${failures[@]}"; do
      printf '           - %s\n' "$f"
    done
    return 1
  fi

  # The serve unit is deliberately NOT a failure. It is a statement about
  # durability, not about whether the URL works right now, and failing a status
  # command for a lane that is serving correctly would make this the thing
  # people learn to ignore. It is loud in the fact list and silent in the
  # verdict, which is the correct weight for "this works and will not survive a
  # reboot".
  printf 'ts state:  OK — %s is served and answering\n' "$base"
  return 0
}

# Release this environment's tailnet device record. CANNOT FAIL, BY DESIGN.
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# `terraform destroy` removes the GCP instance. NOTHING removes the tailnet
# device. The corpse keeps owning sl-<env>, so the next build of the same
# environment is given sl-<env>-1, then sl-<env>-2 — the demo URL moves further
# on every rebuild, and the URL is the deliverable. Measured on 2026-08-18; the
# full account is above bring_tailscale_up in the startup script.
#
# This runs BEFORE the destroy, from here, over SSH, because that is the last
# moment at which the node is both alive and known to be going away. The systemd
# unit the startup script installs is the backstop for every teardown that does
# not come through this path.
#
# ─── LOGOUT ALSO WIPES THE SERVE AND FUNNEL CONFIG ──────────────────────────
#
# Measured deliberately on demo-2 — same node, same key, same hostname:
#
#   SERVE_BEFORE  https://sl-demo-2.<tailnet>.ts.net  -- / proxy http://127.0.0.1:9999
#   (sudo tailscale logout; rejoin with the same --hostname on the same key)
#   SERVE_AFTER   No serve config
#   SELF          sl-demo-2.<tailnet>.ts.net.          <- name reclaimed correctly
#
# The name comes back. The published URL does not. Inside a destroy that costs
# nothing, because the VM is going away. Run against a LIVE node it produces a
# node that is online, correctly named, resolving through MagicDNS, and serving
# nothing — every signal a person would check says healthy. That is the exact
# failure class the name marker exists to prevent, arriving through this door.
#
# So a live serve config makes this REFUSE unless forced, and the refusal says
# why. It does NOT re-apply serve afterwards: a mitigation that repairs its own
# symptom hides the fact that somebody ran a destructive command on a live node,
# and the next person learns nothing. The destroy path passes --force, which is
# the sanctioned case, and that is what keeps the guard meaningful rather than a
# thing everybody routes around.
#
# (A `No serve config` was first seen on demo-1 after its logout, but that one is
# NOT attributable — demo-1 had been rebuilt and serve may never have been set on
# it. The demo-2 run above is the evidence, because the config was set and
# observed live first.)
#
# ─── The node ID is RE-MINTED across this, and nothing may depend on it ─────
#
# Observed on demo-2: neJCfvjqHu11CNTRL -> nZ5ye7XzN121CNTRL. The MagicDNS name
# and the tag survive intact; the device identity does not.
#
# Nothing in this estate keys on node ID today — scripts/, terraform/, Makefile
# and test/ were checked, and every reference is to a tag or the MagicDNS name.
# KEEP IT THAT WAY. A per-device ACL grant, a tailnet-lock signature or a
# device-scoped approval would break silently across a logout while the name went
# on resolving, which is the hardest possible shape to debug.
#
# ─── Why it exits 0 for everything EXCEPT a refusal ─────────────────────────
#
# Destroy is the operator's escape hatch. A teardown that can be BLOCKED by a
# best-effort cleanup step is a worse failure than the stale device this step
# exists to prevent: the VM keeps costing money and the operator has to go
# around the tooling, which is exactly when people learn to reach for
# `terraform destroy` directly and skip this forever.
#
# So every one of these is a warning and never an error: the VM is already gone,
# the VM is unreachable, SSH is refused, tailscale is not installed, the node was
# never logged in, the hand-off file is missing, credentials have expired.
#
# The REFUSAL is the one exception, and it is safe to be one: the destroy path
# always passes --force, so a refusal cannot occur there by construction. A
# refusal that exited 0 would be a guard that only prints.
#
# TS_LOGOUT_REFUSED is 97 and NOT 2, which was the first choice and was wrong:
# `die` in this file exits 2, so a missing hand-off or an absent operator SA —
# both ordinary best-effort misses — arrived at the caller indistinguishable
# from "this node is serving, I refuse". The subshell can only signal through an
# exit status, so that status has to be one nothing else in here produces.
#
# The subshell is not decoration. `prepare` calls `die` on a missing hand-off or
# a missing operator SA, and `die` EXITS — in-process that would take the destroy
# down with it, which is the precise outcome this function promises never to
# cause. Inside `( … )` that exit is contained and observable as a status.
cmd_ts_logout() {
  local rc=0 force=0

  # Both spellings, because this is reached two ways: a human types the target
  # with FORCE=1, and the destroy recipe passes the flag.
  case "${1:-}" in
    --force) force=1 ;;
    "") ;;
    *) die "usage: $(basename "$0") ts-logout [--force]" ;;
  esac
  [ "${FORCE:-0}" != "1" ] || force=1

  (
    prepare ts-logout

    local host
    host="$(ts_node_hostname)"
    log "releasing the tailnet device record for ${host} before teardown"

    local state
    state="$(vm_status)"
    if [ "$state" != "RUNNING" ]; then
      warn "${INSTANCE_NAME} is ${state}, not RUNNING — cannot log out from here. If it shut down cleanly the on-shutdown unit already released '${host}'; otherwise the auto-reap frees it 47-100 minutes after it went offline. A rebuild sooner than that will be handed a suffixed name and will say so."
      exit 0
    fi

    # `tailscale logout` on a node that was never logged in is an error, and a
    # completely uninteresting one. `command -v` first so the common cases are
    # distinguishable in the log rather than collapsing into one opaque failure.
    if ! remote_run 'command -v tailscale >/dev/null 2>&1'; then
      warn "no tailscale on ${INSTANCE_NAME} — nothing to log out. Its device record, if it has one, is left to the auto-reap 47-100 minutes after it goes offline."
      exit 0
    fi

    # THE GUARD. Checked before the logout, never repaired after it.
    if [ "$force" != "1" ]; then
      local serve
      serve="$(ts_serve_state)"
      case "$serve" in
        present)
          cat >&2 <<EOF
demo-up: REFUSING to log out — ${host} is serving right now.

  'tailscale logout' wipes the serve and funnel configuration. The node would
  come back with the right name, resolving through MagicDNS, online, and
  serving NOTHING — and every check short of fetching the URL would call that
  healthy. Measured on demo-2.

  This is safe during a teardown and destructive on a live node, so it is not
  a decision this command will make for you.

      make gcp-tf-ts-logout ENV=${ENV_KEY} FORCE=1   # yes, take the demo down
      make gcp-tf-ts-up ENV=${ENV_KEY}               # re-serve it afterwards

  A destroy already passes --force, so this refusal never blocks a teardown.
EOF
          exit "$TS_LOGOUT_REFUSED"
          ;;
        unknown)
          cat >&2 <<EOF
demo-up: REFUSING to log out — could not determine whether ${host} is serving.

  'tailscale serve status' on ${INSTANCE_NAME} gave no usable answer, so this
  cannot tell a node that is serving from one that is not. Logging out would
  wipe a serve config if there is one.

  Not knowing is not the same as knowing there is nothing there, and this is
  the one place that distinction is expensive.

      make gcp-tf-ts-status ENV=${ENV_KEY}           # what does the node say?
      make gcp-tf-ts-logout ENV=${ENV_KEY} FORCE=1   # proceed anyway
EOF
          exit "$TS_LOGOUT_REFUSED"
          ;;
      esac
    fi

    if remote_run 'sudo tailscale logout'; then
      log "${host} released its device record — the name is free for the next build"
    else
      warn "'tailscale logout' on ${INSTANCE_NAME} did not succeed. This does NOT block the destroy. The auto-reap will free '${host}' 47-100 minutes after it goes offline, so a rebuild sooner than that gets a SUFFIXED name and the demo URL moves. To rebuild now, delete the offline '${host}' device at https://login.tailscale.com/admin/machines first. The auth key is not implicated and does not need rotating."
    fi
  ) || rc=$?

  # 2 is the refusal, and it is the ONE status that travels. Everything else is
  # a best-effort miss and must not be visible as a failure, because a destroy
  # is never blocked by this.
  if [ "$rc" -eq "$TS_LOGOUT_REFUSED" ]; then
    return 2
  fi

  if [ "$rc" -ne 0 ]; then
    warn "the tailnet logout step could not run (status ${rc}). Continuing — a destroy is never blocked by this."
  fi

  return 0
}

cmd_ts_up() {
  prepare ts-up
  local port="$APP_PORT"

  # LOCAL FIRST, before any cloud call, in this order and for the same reason
  # cmd_public checks /etc/hosts first: these cost milliseconds, and failing
  # them after publishing would mean waiting a minute to be told about a
  # setting on this machine.
  ts_resolve_node || exit 2
  require_magicdns

  local base="https://${TS_FQDN}"

  # Read-only, and before the estate is touched. Skippable for a scripted probe
  # that does not care about login, but NOT skippable by default: a dashboard
  # that loads with a bouncing login is the failure this whole block is built
  # around.
  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" = "1" ]; then
    warn "GCP_TF_DEMO_SKIP_DEX_ORIGIN=1 — Dex will keep its current issuer. The dashboard will load at ${base} and the LOGIN WILL BOUNCE."
  else
    require_dex_origin_mechanism "gcp-tf-ts-up"
    require_no_conflicting_origin "$base"
  fi

  ensure_published "$port"
  ensure_ts_serve serve "$port"

  if [ "${GCP_TF_DEMO_SKIP_DEX_ORIGIN:-0}" != "1" ]; then
    log "claiming the Dex origin: ${base}"
    # `apply <method> <origin>` — the METHOD is not optional. The mechanism
    # records which access method holds the lease so the refusal it gives the
    # next caller can name whose teardown to run; an origin alone cannot answer
    # that. This was written once against an assumed one-argument signature and
    # the seam was invisible to both suites, because each tested its own side
    # of it: the driver against a stub, the mechanism against its own CLI.
    dex_origin apply tailscale "$base" ||
      die "could not repoint Dex at ${base}. The dashboard would load and the login would bounce, so this is a failure rather than a warning."
  fi

  log "probing ${base}${TS_HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_ts_dashboard "$base")"; then
    {
      printf '\ndemo-up: the node is up but the dashboard did not answer %s.\n' "$TS_HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  MagicDNS and the tailnet are FINE — this got far enough to ask.\n'
      printf '  Three things are behind that name and any of them can be the one:\n\n'
      printf '    1. An EMPTY status usually means the TLS certificate did not verify.\n'
      printf '       HTTPS certs are not enabled for this tailnet (admin console ->\n'
      printf '       DNS -> HTTPS Certificates). Nothing in this repo can turn that on.\n'
      printf '    2. A 502 means tailscale serve reached the VM-side forward and got\n'
      printf '       nothing. Check the estate:  make gcp-tf-demo-status ENV=%s\n' "$ENV_KEY"
      printf '    3. A 404 means nginx answered and %s is not one of its\n' "$TS_HEALTH_PATH"
      printf '       locations — the dashboard image is older than this checkout.\n'
    } >&2
    exit 3
  fi

  print_ts_instructions "$base"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n' \
    "$TS_FQDN" "$TS_HEALTH_PATH" "$code"
  printf '  SCOPE:  reachable from this TAILNET only. Not from the public internet.\n'
  printf '          Making it public is a separate, deliberate act:\n'
  printf '            make gcp-tf-funnel-up ENV=%s\n\n' "$ENV_KEY"
  log "the demo is live at ${base}. Nothing is being held open — it stays up."
}

cmd_funnel_up() {
  prepare funnel-up
  local port="$APP_PORT"

  ts_resolve_node || exit 2
  require_magicdns

  local base="https://${TS_FQDN}"

  # NOT skippable here, unlike ts-up. A bouncing login on a tailnet-only URL is
  # an inconvenience; a bouncing login on a URL the whole internet can reach is
  # a broken thing published under this estate's name.
  require_dex_origin_mechanism "gcp-tf-funnel-up"
  require_no_conflicting_origin "$base"

  cat <<EOF

  ⚠  FUNNEL EXPOSES THIS DEMO TO THE PUBLIC INTERNET.

  Every other access path in this estate is closed by construction: the VM has
  no external IP, IAP requires a Google identity holding
  roles/iap.tunnelResourceAccessor, and Tailscale requires membership of this
  tailnet. Funnel is the ONLY thing here that creates a listener anyone can
  reach, and it does so under a name with a valid public certificate.

  What is behind it is a demo estate with published credentials
  (${DEMO_LOGIN_USER} / ${DEMO_LOGIN_PASS}). Treat everything in it as
  disclosed for as long as this is on.

  Switch it off the moment the demo ends — it does not expire on its own:

      make gcp-tf-funnel-down ENV=${ENV_KEY}

EOF

  ensure_published "$port"
  ensure_ts_serve funnel "$port"

  log "claiming the Dex origin: ${base}"
  # `funnel`, not `tailscale` — same URL, different method. serve and funnel
  # publish the identical origin, so the lease would be satisfied either way,
  # but the recorded holder is what a later refusal quotes back. Naming it
  # `tailscale` here would tell the next operator to run the wrong teardown and
  # leave the PUBLIC listener up.
  dex_origin apply funnel "$base" ||
    die "could not repoint Dex at ${base}. Refusing to leave a PUBLIC URL whose login bounces — run 'make gcp-tf-funnel-down ENV=${ENV_KEY}' now."

  log "probing ${base}${TS_HEALTH_PATH} (up to ${HEALTH_WAIT_SECONDS}s)"
  local code
  if ! code="$(wait_for_ts_dashboard "$base")"; then
    {
      printf '\ndemo-up: funnel is configured and the dashboard did not answer %s.\n' "$TS_HEALTH_PATH"
      printf '  last status: %s\n\n' "${code:-(no response)}"
      printf '  A PUBLIC listener may now exist in front of something that does not\n'
      printf '  work. Take it down before debugging:\n\n'
      printf '    make gcp-tf-funnel-down ENV=%s\n\n' "$ENV_KEY"
      printf '  An empty status here most often means the tailnet policy grants no\n'
      printf "  'funnel' nodeAttr to tag:sl-demo, so the edge is refusing to route.\n"
    } >&2
    exit 3
  fi

  print_ts_instructions "$base"
  printf '\n  HEALTH: %s%s returned %s — verified before you clicked.\n' \
    "$TS_FQDN" "$TS_HEALTH_PATH" "$code"
  printf '  SCOPE:  PUBLIC. This URL is reachable from the entire internet.\n'
  printf '          make gcp-tf-funnel-down ENV=%s\n\n' "$ENV_KEY"
}

cmd_funnel_down() {
  prepare funnel-down
  ts_resolve_node || exit 2

  log "switching off the public funnel listener on ${INSTANCE_NAME}"
  remote_run "sudo tailscale funnel --https=${TS_SERVE_PORT} off && echo FUNNEL_OFF" ||
    die "could not switch off funnel on ${INSTANCE_NAME}. The public listener may STILL BE UP. Check by hand: gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} --impersonate-service-account=${OPERATOR_SA} --tunnel-through-iap --command='sudo tailscale funnel status'"

  # Deliberately leaves `tailscale serve` and the Dex origin alone. The demo is
  # still live on the tailnet at the same URL after this, so restoring the
  # issuer here would break the thing the operator is still using.
  printf '\n  Funnel is OFF. The demo is still live for this tailnet at https://%s\n' "$TS_FQDN"
  printf '  Dex still points there, which is correct — only the PUBLIC listener\n'
  printf '  was removed. To stop serving entirely: make gcp-tf-public-down ENV=%s\n\n' "$ENV_KEY"
}

# ════════════════════════════════════════════════════════════════════════════
#  THE SECOND TEST SURFACE: the tailnet, from wherever the operator is
# ════════════════════════════════════════════════════════════════════════════
#
# `demo-up.sh test` runs the whole suite ON the VM. Everything it asserts
# reaches the application over `127.0.0.1` — demo-pipeline.sh's runtime stages
# make their own `kubectl port-forward`s, and its browser stages drive the
# VM-local Envoy NodePort. That is the right place for 40-odd stages of unit
# tests, bats guards, Flux convergence and staleness proofs, and NONE of them
# care what the transport is.
#
# Which is exactly the problem. Four things sit between a healthy in-cluster
# service and Andy opening the demo on his phone, and the on-VM suite is blind
# to all four BY CONSTRUCTION, not by omission:
#
#   1. The tailnet itself (WireGuard, ACLs, node online, MagicDNS).
#   2. `tailscale serve`'s TLS termination, with a REAL certificate issued to
#      the MagicDNS name. There is no certificate at all on the loopback path,
#      so no on-VM assertion can be about one.
#   3. The serve -> `http://127.0.0.1:<app_port>` hop, and the supervised
#      VM-side forward that publishes that port. The on-VM runtime stages
#      BYPASS that forward — they open their own — so it can be dead all the
#      way through a green run.
#   4. Dex's ISSUER. On the VM, Dex is reached at `http://127.0.0.1:<port>/dex`.
#      Over the tailnet it must be `https://<fqdn>/dex`, and the two are
#      different OIDC issuers. cmd_ts_up claims that origin and the header of
#      this file says what happens when the claim is wrong: the dashboard loads
#      and the login bounces. An on-VM test cannot see that, because on the VM
#      the issuer it exercises is the one it just created for itself.
#
# So this surface deliberately does NOT re-run the on-VM suite over the network.
# Duplicating 40 stages across the tailnet would be slow and would mostly re-test
# transport-independent logic. It asserts the five things where the TRANSPORT is
# the subject, and stops.
#
# ─── It needs NO cloud credentials, and that is the point ───────────────────
#
# Unlike every other command in this file, this one makes no gcloud call, opens
# no IAP tunnel and does not SSH anywhere. It is `curl` against a name, from
# wherever the operator happens to be — which is precisely the user journey
# being tested. Requiring an operator service account here would mean the test
# could only be run by someone holding rights the real user does not need, and
# a test that cannot be run the way the user runs it is testing something else.
#
# The hand-off is read when present (for `tailscale_hostname`) and its ABSENCE
# is not fatal here, again unlike everywhere else: the node name derives from
# the environment key exactly as terraform/modules/compute/main.tf derives it,
# and a wrong name fails loudly in ts_resolve_node rather than silently.
#
# ─── Concurrency ────────────────────────────────────────────────────────────
#
# Four lanes can run this at once. It binds NO local port (every request is
# outbound), every receipt path carries the environment key, and every temporary
# file carries the pid. There is no fixed filename anywhere in this block.
#
# ─── A dead lane FAILS. It never skips. ─────────────────────────────────────
#
# There is no `skip`, no `|| true` around an assertion, and no branch that exits
# 0 having asserted nothing — ts_test_verdict refuses a run that recorded zero
# checks. This repo has twice shipped the opposite: a bats suite that all-skipped
# locally and read as green, and four Playwright specs that matched no project
# and were skipped with exit 0 and no warning.

TS_TEST_TIMEOUT="${GCP_TF_DEMO_TS_TEST_TIMEOUT:-20}"

# An authenticated API route, reached through the SAME nginx the browser uses.
#
# Overridable because a route is a product detail and this file should not be
# the thing that pins one. Measured against sl-demo-1 on 2026-08-20: anonymous
# 401, bearer 200.
TS_TEST_API_PATH="${GCP_TF_DEMO_TS_TEST_API_PATH:-/api/signals/store/stats}"

# Where each surface leaves its receipt.
#
# DELIBERATELY NOT under REPORT_DIR. rotate_reports() moves that whole directory
# to .prev at the start of every on-VM run, so a tailnet receipt filed there
# would be carried off by the next `demo-up.sh test` — and the both-surfaces
# verdict would then report a missing tailnet run that had in fact just passed.
SURFACE_DIR="${GCP_TF_DEMO_SURFACE_DIR:-${REPO_ROOT}/demo-surfaces}"

# How old a receipt may be and still count as "this surface ran".
#
# Without a bound, a receipt from a fortnight ago would vouch for a lane rebuilt
# twice since. 24h is the working default; set it to 0 to disable the check when
# deliberately comparing runs made far apart.
SURFACE_MAX_AGE_SECONDS="${GCP_TF_DEMO_SURFACE_MAX_AGE_SECONDS:-86400}"

TS_TEST_TOTAL=0
TS_TEST_FAILED=0
TS_TEST_ROWS=""
TS_TEST_MARK=0
TS_TEST_STARTED=0
TS_TEST_SLOWEST_MS=0
TS_TEST_SLOWEST_NAME=""

# ── Every check reports how close it came to its fence ─────────────────────
#
# Each request runs under a hard `--max-time ${TS_TEST_TIMEOUT}` ceiling, and
# until this was added the run reported the VERDICT and nothing about the
# margin. That is the same instrumentation hole as scripts/ci/vm-pipeline.sh,
# which announces `──── TEST: <name> (timeout 900s) ────` and never prints what
# the stage actually took — so the inner waits are well instrumented, the outer
# fences are not measured at all, and nobody can say what the headroom is.
#
# The distinction worth having: "the suite passed" versus "the suite passed and
# the slowest check used 6% of its budget". Only the second one can ever tell
# you the estate is getting slower. A suite whose timings are never recorded
# cannot report a regression until it has already become a failure — and on a
# lane about to drop from 16 vCPU to 8, that is the signal most likely to move.
#
# WARN, never FAIL, at 60% of budget. This mirrors scripts/lib/wait.sh's own
# threshold deliberately rather than inventing a second convention: a slow check
# that still answered correctly is not a broken lane, and failing it would turn
# a latency signal into an outage.
TS_TEST_WARN_PERCENT="${GCP_TF_DEMO_TS_TEST_WARN_PERCENT:-60}"

now_ms() { date +%s%3N; }

ts_check() { # ts_check <ok|fail> <name> <detail>
  local state="$1" name="$2" detail="$3"
  local now ms fence_ms pct budget=""
  now="$(now_ms)"
  ms=$((now - TS_TEST_MARK))
  TS_TEST_MARK="$now"
  fence_ms=$((TS_TEST_TIMEOUT * 1000))
  pct=$((ms * 100 / fence_ms))

  if [ "$ms" -gt "$TS_TEST_SLOWEST_MS" ]; then
    TS_TEST_SLOWEST_MS="$ms"
    TS_TEST_SLOWEST_NAME="$name"
  fi

  printf -v budget '[%d.%03ds/%ss %d%%]' \
    "$((ms / 1000))" "$((ms % 1000))" "$TS_TEST_TIMEOUT" "$pct"

  TS_TEST_TOTAL=$((TS_TEST_TOTAL + 1))
  if [ "$state" = "ok" ]; then
    printf '  PASS  %-34s %-18s %s\n' "$name" "$budget" "$detail"
  else
    TS_TEST_FAILED=$((TS_TEST_FAILED + 1))
    printf '  FAIL  %-34s %-18s %s\n' "$name" "$budget" "$detail" >&2
  fi

  if [ "$pct" -ge "$TS_TEST_WARN_PERCENT" ]; then
    warn "'${name}' used ${pct}% of its ${TS_TEST_TIMEOUT}s budget. Not a failure — it answered — but this is the check that will time out first if the lane slows down further."
  fi

  TS_TEST_ROWS="${TS_TEST_ROWS}${TS_TEST_ROWS:+,}$(jq -nc \
    --arg n "$name" --arg s "$state" --arg d "$detail" \
    --argjson ms "$ms" --argjson pct "$pct" --argjson fence "$TS_TEST_TIMEOUT" \
    '{name: $n, status: (if $s == "ok" then "pass" else "fail" end), detail: $d,
      elapsed_ms: $ms, fence_seconds: $fence, budget_used_percent: $pct}')"
}

# One request. Body goes to a file, HTTP status goes to stdout, and curl's OWN
# exit status is what this returns.
#
# Both halves are load-bearing and this repo has been bitten by conflating them:
# a tool that reports failure in its OUTPUT while exiting 0 makes every
# `|| fallback` guarding it dead code. `%{http_code}` is `000` when the request
# could not be made at all, so the status alone cannot distinguish "no TLS
# handshake" from "nothing listening" — the curl exit code can, and
# ts_explain_curl below turns it into a diagnosis.
#
# NO -k. The certificate is a real one issued to the MagicDNS name; skipping
# verification would hide a tailnet without HTTPS certificates behind a
# healthy-looking 200. Cert verification IS one of the things under test.
ts_fetch() {
  local url="$1" body="$2"
  shift 2
  local code rc=0
  code="$("$CURL_BIN" -sS -o "$body" -w '%{http_code}' \
    --max-time "$TS_TEST_TIMEOUT" "$@" "$url" 2>/dev/null)" || rc=$?
  printf '%s' "${code:-000}"
  return "$rc"
}

# curl's exit status, as a sentence about THIS estate.
#
# The mapping matters more than it looks. `7` is the whole ci-lane story today:
# the node is in the tailnet, online, and answering nothing on 443 because
# `tailscale serve` was never configured on it. Reporting that as a generic
# "request failed" is what makes an operator go looking at the cluster.
ts_explain_curl() {
  case "$1" in
    0) printf 'request completed' ;;
    6) printf "curl could not resolve the name (exit 6) — MagicDNS is not answering on THIS machine, though the tailnet knows the node" ;;
    7) printf "curl could not connect (exit 7) — the node is reachable and NOTHING is listening on :%s. This lane is NOT SERVING: 'tailscale serve' has not been configured on it. Fix with: make gcp-tf-ts-up ENV=%s" "$TS_SERVE_PORT" "$ENV_KEY" ;;
    28) printf 'curl timed out after %ss (exit 28) — the node accepted the connection and never answered' "$TS_TEST_TIMEOUT" ;;
    35 | 60) printf 'the TLS handshake or certificate verification FAILED (exit %s) — HTTPS certificates are not enabled for this tailnet (admin console -> DNS -> HTTPS Certificates)' "$1" ;;
    *) printf 'curl failed with exit %s' "$1" ;;
  esac
}

# A single claim out of a JWT payload, without a JWT library.
#
# base64url is not base64: `-` and `_` are substituted, and the padding is
# stripped. Feeding the raw segment to `base64 -d` produces garbage or nothing
# for a large fraction of real tokens, so both are undone before decoding.
jwt_claim() {
  local jwt="$1" claim="$2" payload
  payload="$(printf '%s' "$jwt" | cut -d. -f2 | tr '_-' '/+')"
  while [ $((${#payload} % 4)) -ne 0 ]; do payload="${payload}="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null |
    jq -r --arg c "$claim" '.[$c] // ""' 2>/dev/null || printf ''
}

# write_surface_receipt <surface> <outcome> <total> <failed> <detail>
#
# One file per lane PER SURFACE, so four lanes times two surfaces never collide,
# and the temp file carries the pid so two concurrent writers cannot truncate
# each other's. Returns non-zero if it could not write — a receipt that was not
# filed must not read as a surface that did not run for some other reason.
write_surface_receipt() {
  local surface="$1" outcome="$2" total="$3" failed="$4" detail="$5"
  mkdir -p "$SURFACE_DIR" 2>/dev/null || return 1
  local target="${SURFACE_DIR}/${ENV_KEY}.${surface}.json"
  local tmp="${SURFACE_DIR}/.${ENV_KEY}.${surface}.$$.tmp"
  jq -n \
    --arg schema 'signalloom.surface.receipt/v1' \
    --arg surface "$surface" \
    --arg env "$ENV_KEY" \
    --arg outcome "$outcome" \
    --arg commit "$RUN_COMMIT" \
    --arg branch "$RUN_BRANCH" \
    --arg detail "$detail" \
    --arg written_at "$(date -Iseconds)" \
    --argjson written_epoch "$(date +%s)" \
    --argjson total "$total" \
    --argjson failed "$failed" \
    --argjson checks "[${TS_TEST_ROWS}]" \
    --argjson slowest_ms "${TS_TEST_SLOWEST_MS:-0}" \
    --arg slowest_name "${TS_TEST_SLOWEST_NAME:-}" \
    --argjson fence "${TS_TEST_TIMEOUT:-0}" \
    '{schema: $schema, surface: $surface, env: $env, outcome: $outcome,
      commit: $commit, branch: $branch, detail: $detail,
      written_at: $written_at, written_epoch: $written_epoch,
      checks_total: $total, checks_failed: $failed,
      checks: (if $surface == "tailnet" then $checks else [] end)}
     + (if $surface == "tailnet" then
          {slowest_check: $slowest_name, slowest_ms: $slowest_ms,
           fence_seconds: $fence}
        else {} end)' \
    >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$target" || return 1
  return 0
}

cmd_ts_test() {
  require_env ts-test
  capture_source_identity

  # Armed before the first thing that can be timed, so the node-resolution
  # check reports its own cost rather than inheriting the process start.
  TS_TEST_STARTED="$(now_ms)"
  TS_TEST_MARK="$TS_TEST_STARTED"

  # Present-but-optional, unlike every other command here. See the block header:
  # this surface needs a NAME and a tailnet, not a project and a service account.
  HANDOFF_FILE="${HANDOFF_DIR}/${ENV_KEY}.handoff.json"
  if [ -f "$HANDOFF_FILE" ]; then
    log "reading ${HANDOFF_FILE} for the tailnet hostname"
  else
    HANDOFF_FILE=""
    log "no hand-off for ${ENV_KEY}; deriving the node name as 'sl-${ENV_KEY}', the same way terraform/modules/compute/main.tf does"
  fi

  echo "════════════════════════════════════════════════════════════"
  echo "  Signal Loom — REMOTE surface (over the tailnet)"
  echo "  ENV: ${ENV_KEY}  |  source: ${RUN_BRANCH}@${RUN_COMMIT}"
  echo "════════════════════════════════════════════════════════════"

  # R1. Is the lane on the tailnet at all? ts_resolve_node emits a full
  # diagnosis on failure and distinguishes absent / offline / no-MagicDNS, so a
  # failure here is already specific. It is fatal rather than a recorded check:
  # every assertion below needs TS_FQDN, and running them against an empty name
  # would produce four more failures that all say the same thing.
  if ! ts_resolve_node; then
    printf '\ndemo-up: %s is NOT REACHABLE on the tailnet — see the diagnosis above.\n' "$ENV_KEY" >&2
    printf '  This is a FAILURE of the remote surface, not a reason to skip it.\n' >&2
    write_surface_receipt tailnet FAIL 0 0 "node for ${ENV_KEY} is absent, offline, or has no MagicDNS name" || true
    exit 2
  fi

  local base="https://${TS_FQDN}"
  local work
  work="$(mktemp -d "${TMPDIR:-/tmp}/sl-tstest-${ENV_KEY}-XXXXXX")"
  # shellcheck disable=SC2064  # $work is expanded NOW on purpose: the trap must
  # name this run's directory, not whatever the variable holds when it fires.
  trap "rm -rf '${work}'" EXIT

  log "node ${TS_FQDN} is online at ${TS_IP}; testing ${base} from this machine"
  echo ""

  ts_check ok "tailnet node online" "${TS_FQDN} (${TS_IP})"

  # R2. TLS terminates, the certificate verifies, and the front door answers.
  #
  # The FIRST check that can distinguish "serving" from "not serving", and the
  # one that catches today's ci-lane state.
  local code rc=0
  code="$(ts_fetch "${base}${TS_HEALTH_PATH}" "${work}/readyz")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    ts_check fail "TLS and ${TS_HEALTH_PATH}" "$(ts_explain_curl "$rc")"
  elif [ "$code" = "200" ]; then
    ts_check ok "TLS and ${TS_HEALTH_PATH}" "verified certificate, HTTP ${code}"
  else
    ts_check fail "TLS and ${TS_HEALTH_PATH}" "TLS is fine and the answer was HTTP ${code}, not 200. A 502 means 'tailscale serve' reached the VM-side forward and got nothing; a 404 means nginx answered and the path is not one of its locations."
  fi

  # R3. Dex's issuer IS this origin.
  #
  # THE assertion the on-VM suite structurally cannot make, and the one whose
  # failure mode — a dashboard that loads and a login that bounces — is the
  # documented reason cmd_ts_up claims an origin at all. A stale issuer from a
  # previous access method leaves everything else on this page green.
  local want_issuer="${base}/dex"
  rc=0
  code="$(ts_fetch "${base}/dex/.well-known/openid-configuration" "${work}/oidc")" || rc=$?
  local got_issuer=""
  if [ "$rc" -ne 0 ]; then
    ts_check fail "Dex discovery reachable" "$(ts_explain_curl "$rc")"
  elif [ "$code" != "200" ]; then
    ts_check fail "Dex discovery reachable" "HTTP ${code} at /dex/.well-known/openid-configuration — nginx is not proxying /dex/ to Dex"
  else
    got_issuer="$(jq -r '.issuer // ""' "${work}/oidc" 2>/dev/null || printf '')"
    ts_check ok "Dex discovery reachable" "HTTP ${code}"
    if [ "$got_issuer" = "$want_issuer" ]; then
      ts_check ok "Dex issuer is this origin" "$got_issuer"
    else
      ts_check fail "Dex issuer is this origin" "Dex issues for '${got_issuer:-(none)}' but this URL is '${want_issuer}'. The dashboard WILL LOAD HERE AND THE LOGIN WILL BOUNCE. Another access path holds the origin: make gcp-tf-ts-up ENV=${ENV_KEY}"
    fi
  fi

  # R4. A real token, minted over this transport.
  #
  # Status codes alone would not prove the auth chain works end to end — a 401
  # is equally consistent with a correct rejection and with a Dex that cannot be
  # reached. Minting a token here and reading its `iss` claim proves the token
  # this origin issues is a token for this origin. The password grant, the
  # public client_id in the form body and the audience scope all mirror
  # d2-signalloom/test/api-route-liveness.bats deliberately: auth is never
  # bypassed to make a test easier to write.
  local token=""
  rc=0
  code="$(ts_fetch "${base}/dex/token" "${work}/token" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=signalloom-dashboard' \
    --data-urlencode "username=${DEMO_LOGIN_USER}" \
    --data-urlencode "password=${DEMO_LOGIN_PASS}" \
    --data-urlencode 'scope=openid profile email groups audience:server:client_id:signalloom-api')" || rc=$?
  if [ "$rc" -ne 0 ]; then
    ts_check fail "token minted over the tailnet" "$(ts_explain_curl "$rc")"
  elif [ "$code" != "200" ]; then
    ts_check fail "token minted over the tailnet" "HTTP ${code} from ${want_issuer}/token for ${DEMO_LOGIN_USER}"
  else
    token="$(jq -r '.id_token // ""' "${work}/token" 2>/dev/null || printf '')"
    if [ -z "$token" ]; then
      ts_check fail "token minted over the tailnet" "HTTP 200 but the response carries no id_token"
    else
      local iss
      iss="$(jwt_claim "$token" iss)"
      if [ "$iss" = "$want_issuer" ]; then
        ts_check ok "token minted over the tailnet" "id_token iss=${iss}"
      else
        ts_check fail "token minted over the tailnet" "the id_token was issued by '${iss:-(unreadable)}', not '${want_issuer}'"
      fi
    fi
  fi

  # R5. The proxy hop reaches the APPLICATION, and auth is enforced across it.
  #
  # Two requests, because either one alone is worthless. A 200 with a bearer
  # proves nginx proxies /api/ to a live backend rather than serving the SPA's
  # index for every unmatched path. A 401 WITHOUT one proves the API is actually
  # checking — an open API returns 200 to both, and a suite that only ever sends
  # the token would call that a pass.
  local anon auth
  rc=0
  anon="$(ts_fetch "${base}${TS_TEST_API_PATH}" "${work}/anon")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    ts_check fail "API rejects an anonymous caller" "$(ts_explain_curl "$rc")"
  elif [ "$anon" = "401" ] || [ "$anon" = "403" ]; then
    ts_check ok "API rejects an anonymous caller" "HTTP ${anon} at ${TS_TEST_API_PATH}"
  else
    ts_check fail "API rejects an anonymous caller" "HTTP ${anon} at ${TS_TEST_API_PATH} with no credentials — expected 401 or 403"
  fi

  if [ -z "$token" ]; then
    ts_check fail "API answers an authenticated caller" "no token was minted, so this could not be asked — recorded as a failure rather than skipped, because a question not asked is not a question answered"
  else
    rc=0
    auth="$(ts_fetch "${base}${TS_TEST_API_PATH}" "${work}/auth" \
      -H "Authorization: Bearer ${token}")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      ts_check fail "API answers an authenticated caller" "$(ts_explain_curl "$rc")"
    elif [ "$auth" = "200" ]; then
      ts_check ok "API answers an authenticated caller" "HTTP ${auth} at ${TS_TEST_API_PATH}"
    else
      ts_check fail "API answers an authenticated caller" "HTTP ${auth} at ${TS_TEST_API_PATH} with a valid bearer — a 502 means nginx has no live backend for /api/"
    fi
  fi

  ts_test_verdict "$base"
}

# The one place the remote surface's status is decided, so the printed verdict,
# the exit code and the receipt on disk cannot disagree.
ts_test_verdict() {
  local base="$1" outcome exit_code

  # A run that asserted NOTHING is not a pass. Without this, deleting every
  # check above would produce a clean exit 0 and a receipt saying PASS — which
  # is the exact shape that has twice reported green in this repo while
  # measuring nothing.
  if [ "$TS_TEST_TOTAL" -eq 0 ]; then
    printf '\ndemo-up: the remote surface recorded ZERO checks.\n' >&2
    printf '  Nothing was measured, so nothing passed. This is a failure.\n' >&2
    write_surface_receipt tailnet ABORTED 0 0 'no checks were recorded' || true
    exit 2
  fi

  echo ""
  if [ "$TS_TEST_FAILED" -eq 0 ]; then
    outcome=PASS
    exit_code=0
  else
    outcome=FAIL
    exit_code=1
  fi

  local total_ms
  total_ms=$(($(now_ms) - TS_TEST_STARTED))

  local detail
  detail="$((TS_TEST_TOTAL - TS_TEST_FAILED))/${TS_TEST_TOTAL} remote checks passed against ${base}"

  # The headroom line. Printed on PASS and on FAIL alike, because a run that
  # failed slowly and a run that failed instantly are different diagnoses: the
  # first says the lane is degraded, the second says it is absent.
  printf '    TIMING: %d.%03ds total; slowest check "%s" at %d.%03ds of a %ss fence (%d%%).\n' \
    "$((total_ms / 1000))" "$((total_ms % 1000))" \
    "${TS_TEST_SLOWEST_NAME:-none}" \
    "$((TS_TEST_SLOWEST_MS / 1000))" "$((TS_TEST_SLOWEST_MS % 1000))" \
    "$TS_TEST_TIMEOUT" \
    "$((TS_TEST_SLOWEST_MS * 100 / (TS_TEST_TIMEOUT * 1000)))"

  if ! write_surface_receipt tailnet "$outcome" \
    "$TS_TEST_TOTAL" "$TS_TEST_FAILED" "$detail"; then
    printf 'demo-up: could not write the tailnet receipt under %s.\n' "$SURFACE_DIR" >&2
    printf '  The checks above stand, but the both-surfaces verdict would report\n' >&2
    printf '  this surface as never having run. Failing rather than reporting a\n' >&2
    printf '  pass that cannot be corroborated.\n' >&2
    exit 2
  fi

  if [ "$exit_code" -eq 0 ]; then
    printf '==> REMOTE PASS — %s\n' "$detail"
    printf '    Receipt: %s/%s.tailnet.json\n' "$SURFACE_DIR" "$ENV_KEY"
    printf '    This proves the TRANSPORT. It does not prove the estate:\n'
    printf '      make gcp-tf-test-surfaces ENV=%s   # did BOTH surfaces run?\n' "$ENV_KEY"
  else
    printf '==> REMOTE FAIL — %s\n' "$detail" >&2
    printf '    Receipt: %s/%s.tailnet.json\n' "$SURFACE_DIR" "$ENV_KEY" >&2
  fi
  exit "$exit_code"
}

# ── The both-surfaces verdict ───────────────────────────────────────────────
#
# "Ensure the tests are run locally on VM, and also remotely through the
# tailnet" is a claim about TWO runs, and neither run can make it alone. A
# passing on-VM suite says nothing about the tailnet; a passing tailnet suite
# says nothing about the estate behind it. So the property "both surfaces ran"
# is asserted HERE, against receipts, rather than assumed by whoever typed the
# two commands.
#
# The failure this closes is not hypothetical for this repo: a run that only
# exercised one surface, reported as a pass, is indistinguishable from a run
# that exercised both — unless something reads the artefacts and says so.
read_surface() { # read_surface <surface>; sets SURFACE_{OUTCOME,AGE,DETAIL,COMMIT}
  local surface="$1"
  local file="${SURFACE_DIR}/${ENV_KEY}.${surface}.json"
  SURFACE_OUTCOME="" SURFACE_AGE="" SURFACE_DETAIL="" SURFACE_COMMIT=""
  [ -f "$file" ] || return 1
  jq -e . "$file" >/dev/null 2>&1 || {
    SURFACE_DETAIL="the receipt is not valid JSON"
    return 2
  }
  local env_in_file
  env_in_file="$(jq -r '.env // ""' "$file")"
  if [ "$env_in_file" != "$ENV_KEY" ]; then
    SURFACE_DETAIL="the receipt describes environment '${env_in_file}', not '${ENV_KEY}'"
    return 2
  fi
  SURFACE_OUTCOME="$(jq -r '.outcome // "UNKNOWN"' "$file")"
  SURFACE_DETAIL="$(jq -r '.detail // ""' "$file")"
  SURFACE_COMMIT="$(jq -r '.commit // "unknown"' "$file")"
  SURFACE_AGE=$(($(date +%s) - $(jq -r '.written_epoch // 0' "$file")))
  return 0
}

cmd_surfaces() {
  require_env test-surfaces

  echo "════════════════════════════════════════════════════════════"
  echo "  Signal Loom — did BOTH test surfaces run for ${ENV_KEY}?"
  echo "════════════════════════════════════════════════════════════"
  echo ""

  local missing=0 failed=0 stale=0 surface rc
  for surface in on-vm tailnet; do
    rc=0
    read_surface "$surface" || rc=$?
    if [ "$rc" -eq 1 ]; then
      printf '  MISSING  %-8s no receipt at %s/%s.%s.json\n' \
        "$surface" "$SURFACE_DIR" "$ENV_KEY" "$surface" >&2
      missing=$((missing + 1))
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      printf '  INVALID  %-8s %s\n' "$surface" "$SURFACE_DETAIL" >&2
      missing=$((missing + 1))
      continue
    fi
    if [ "$SURFACE_MAX_AGE_SECONDS" -gt 0 ] &&
      [ "$SURFACE_AGE" -gt "$SURFACE_MAX_AGE_SECONDS" ]; then
      printf '  STALE    %-8s %s, but written %ss ago (limit %ss)\n' \
        "$surface" "$SURFACE_OUTCOME" "$SURFACE_AGE" "$SURFACE_MAX_AGE_SECONDS" >&2
      stale=$((stale + 1))
      continue
    fi
    if [ "$SURFACE_OUTCOME" = "PASS" ]; then
      printf '  PASS     %-8s %s  (%ss ago, %s)\n' \
        "$surface" "$SURFACE_DETAIL" "$SURFACE_AGE" "$SURFACE_COMMIT"
    else
      printf '  %-8s %-8s %s  (%ss ago, %s)\n' \
        "$SURFACE_OUTCOME" "$surface" "$SURFACE_DETAIL" "$SURFACE_AGE" "$SURFACE_COMMIT" >&2
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [ "$missing" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$stale" -eq 0 ]; then
    printf '==> BOTH SURFACES PASSED for %s.\n' "$ENV_KEY"
    printf '    The estate is tested on the VM AND over the tailnet.\n'
    exit 0
  fi

  {
    printf '==> NOT PROVEN for %s.\n\n' "$ENV_KEY"
    if [ "$missing" -gt 0 ]; then
      printf '  A surface with no receipt did not run. That is NOT a pass, and it is\n'
      printf '  not a skip either — it is an unanswered question:\n\n'
      printf '    on-vm    make gcp-tf-demo-test ENV=%s     # needs cloud credentials\n' "$ENV_KEY"
      printf '    tailnet  make gcp-tf-ts-test ENV=%s       # needs only the tailnet\n\n' "$ENV_KEY"
    fi
    if [ "$stale" -gt 0 ]; then
      printf '  A stale receipt describes a run older than %ss. The lane may have been\n' "$SURFACE_MAX_AGE_SECONDS"
      printf '  rebuilt since. Re-run that surface, or set\n'
      printf '  GCP_TF_DEMO_SURFACE_MAX_AGE_SECONDS=0 if comparing runs made far apart.\n\n'
    fi
  } >&2
  exit 1
}

case "${1:-up}" in
  up) cmd_up ;;
  test) cmd_test ;;
  ts-test) cmd_ts_test ;;
  test-surfaces) cmd_surfaces ;;
  connect) cmd_connect ;;
  public) cmd_public ;;
  public-down) cmd_public_down ;;
  public-status) cmd_public_status ;;
  ts-status) cmd_ts_status ;;
  ts-up) cmd_ts_up ;;
  ts-logout)
    shift
    cmd_ts_logout "${1:-}"
    ;;
  funnel-up) cmd_funnel_up ;;
  funnel-down) cmd_funnel_down ;;
  status) cmd_status ;;
  payload)
    shift
    cmd_payload "${1:-}"
    ;;
  -h | --help | help) sed -n '2,28p' "$0" ;;
  *) die "usage: $(basename "$0") {up|test|ts-test|test-surfaces|connect|ts-up|ts-status|ts-logout|funnel-up|funnel-down|public|public-down|public-status|status|payload <file>}" ;;
esac
