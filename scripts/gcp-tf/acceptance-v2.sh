#!/usr/bin/env bash
#
# acceptance-v2.sh -- end-to-end acceptance against a deployed v2 (Signal Loom
# Terraform) environment.
#
# THIS IS THE v2 SUITE. It grades the Terraform estate in the Signal Loom
# sandbox project, reached as the Signal Loom identity impersonating the deploy
# service account. It is NOT the v1 path: v1 is the imperative ControlPlane CI
# (project cp-dev-ajm, identity andy@control-plane.io, region europe-west2, VMs
# signalloom-ci / signalloom-ci-2) driven by scripts/ci/gcp-ci.sh, which remains
# in place and working. The two estates have different identities, different
# regions and different resource names; a cross-run would report confident
# nonsense, so refuse_v1_estate() below aborts rather than grading one with the
# other's assumptions.
#
# READ-ONLY BY CONSTRUCTION, on the same mechanism preflight.sh and
# conformance.sh use: every cloud call goes through gcloud_ro(), which refuses
# any verb outside a hardcoded allowlist. The estate this runs against is LIVE
# and billable. A tool that can mutate the thing it grades is a liability, so
# the guard is a mechanism rather than a promise.
#
# There is exactly ONE deliberate widening, and it is quarantined in its own
# function rather than added to gcloud_ro: see gcloud_tunnel_probe().
#
# THE CONFIGURATION COMES FROM THE HANDOFF FILE, NOT FROM CONVENTION. Every
# resource name, port and bucket is read from deploy/gcp/<env>.handoff.json as
# emitted by `make gcp-tf-handoff`. Nothing here reconstructs a name from a
# naming rule: a script that guesses `sl-<env>-vm` will happily grade a resource
# that does not exist and report the absence as a clean estate. A key the
# handoff does not carry produces UNKNOWN, never a guess.
#
# Four verdicts, and the differences between them are the whole point:
#
#   PASS      checked, and it is as required.
#   FAIL      checked, and it is NOT as required. The named threat is live.
#   UNKNOWN   could NOT be checked -- no permission, no resource, no jq, no key.
#   N/A       there is NOTHING TO CHECK, by design. Not the same as UNKNOWN.
#
# N/A exists for exactly one reason and it is not cosmetic. A CI lane
# (kind = "ci") has no compute module, so it has no instance and no app port --
# and that is the environment working as designed, not a gap in the report.
# Folding it into UNKNOWN would mean --strict exits 3 on a perfectly correct CI
# hand-off, so CI lanes could NEVER pass a strict run. "I could not look",
# "I looked and it is wrong", and "there is nothing here to look at" are three
# different facts and the report says which one it means.
#
# N/A is fail-closed: ONLY the exact string "ci" takes it. kind = "demo", an
# absent kind, and any unrecognised value all take the strict path and report
# UNKNOWN, because the shape that would make this dangerous is a demo
# environment misclassified as something unfamiliar and handed over with blank
# instance fields. The unexpected case must never be the permissive one.
#
# UNKNOWN is never downgraded to PASS or promoted to FAIL. The single most
# useful distinction this script draws is inside the IAP check: "the tunnel
# authorises but nothing is listening on the app port" and "permission denied"
# are different facts with different owners, and conflating them sends someone
# to the wrong problem entirely. As of this writing the live demo-1 environment
# is in the first state, and a suite that reported it as the second would send
# an engineer to argue with IAM about a working IAM configuration.
#
# Usage:
#   acceptance-v2.sh [--env <key>] [--handoff <path>] [--strict]
#
# Exit codes:
#   0  no FAIL. UNKNOWNs may be present and are listed.
#   1  at least one FAIL.
#   2  usage error.
#   3  --strict, no FAIL, but at least one UNKNOWN.
#   4  a v1 (ControlPlane) estate was named. Refused, not graded.
#   5  the handoff file is absent or unreadable.
#
# shellcheck disable=SC2016
# Every jq program below is single-quoted on purpose. $sa, $want and friends are
# jq variables bound by --arg, not shell variables; letting the shell expand
# them would substitute the value into the program text and change what jq
# parses. File-level rather than a dozen identical inline directives.
set -Eeuo pipefail

readonly SCRIPT_NAME="acceptance-v2"
readonly EXIT_FAILURES=1
readonly EXIT_USAGE=2
readonly EXIT_STRICT_UNKNOWN=3
readonly EXIT_V1_ESTATE=4
readonly EXIT_NO_HANDOFF=5

# Identity-Aware Proxy's TCP-forwarding range. This governs the VPC firewall for
# SSH tunnelling; it carries no web traffic through the load balancer.
readonly IAP_TCP_RANGE="35.235.240.0/20"

# Probed as its own condition, separately from the application port.
readonly SSH_PORT="22"

# The v1 estate's fingerprints. Any of these appearing in the handoff or on the
# command line means someone is pointing the v2 suite at ControlPlane.
readonly V1_MARKERS=(
  "cp-dev-ajm"
  "andy@control-plane.io"
  "europe-west2"
  "signalloom-ci"
  "signalloom-ci-2"
)

# Binaries are injectable so the suite can put a stub on PATH and drive every
# branch below without a cloud account. A component that can only be exercised
# against the real system is a component nobody exercises.
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
JQ_BIN="${JQ_BIN:-jq}"
CURL_BIN="${CURL_BIN:-curl}"

# How long to let the IAP tunnel probe run before deciding it told us nothing.
# Short: this is a classification, not a load test.
IAP_PROBE_TIMEOUT="${IAP_PROBE_TIMEOUT:-25}"

# gcloud shells out to ssh for IAP tunnels, and a loaded ssh-agent on this
# machine answers "agent refused operation" to calls it has no business
# handling. The failure then surfaces as a VM or network error, which is the
# wrong place to look entirely.
export SSH_AUTH_SOCK=""

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0
NA_COUNT=0

# Populated by load_handoff(). Empty means the handoff did not carry the key,
# which is a reason for UNKNOWN and never a reason to guess.
HANDOFF_JSON=""
H_ENV=""
H_PROJECT=""
H_REGION=""
H_ZONE=""
H_INSTANCE=""
H_INTERNAL_IP=""
H_APP_PORT=""
H_STATE_BUCKET=""
H_DEPLOY_SA=""
H_ACCESS_MODE=""
H_HOSTNAME=""
H_KIND=""

# Set by check_instance() from the instance's own networkInterfaces, so the
# firewall checks scope to the network the VM is ACTUALLY on rather than to a
# network name this script invented.
INSTANCE_NETWORKS=""

# Did ANY cloud read succeed in this run? Set by the checks that make one, all
# of which run before the tunnel probe.
#
# This exists for one reason. When a token has expired or an API is disabled,
# gcloud answers PERMISSION_DENIED to everything, including start-iap-tunnel --
# and a tunnel probe that classifies on the text "permission denied" then
# reports "IAP refuses you", which is the single most expensive wrong answer
# this script could give. It sends someone to fix an IAM configuration that was
# never broken, and they will find nothing wrong with it, because nothing is.
#
# So a denial is only evidence about IAP if something else in the same run could
# be read. Under a total blackout it is evidence about the credential, and the
# honest verdict is UNKNOWN.
CLOUD_READS_OK=0

# Set by check_iap_tunnel(), read by check_app_port().
IAP_VERDICT="unknown"
IAP_LOCAL_PORT=""
IAP_TUNNEL_PID=""
IAP_PROBE_TAIL=""

usage() {
  cat <<'USAGE'
Usage: acceptance-v2.sh [options]

End-to-end acceptance for a deployed v2 Signal Loom Terraform environment.
Read-only against the cloud: it asserts, it does not provision. Creates,
modifies and deletes nothing. Safe to run repeatedly, safe to run during a
demo, safe to run when you are not sure the environment is up.

This is the v2 suite. v1 (the imperative ControlPlane CI in cp-dev-ajm) has its
own path at scripts/ci/gcp-ci.sh and is not graded here.

Options:
  --env <key>          Environment key, e.g. demo-1. Selects the handoff file
                       at deploy/gcp/<key>.handoff.json. Default: demo-1.
                       Also read from ACCEPTANCE_ENV.
  --handoff <path>     Read this handoff file instead of the path implied by
                       --env. Also read from ACCEPTANCE_HANDOFF.
  --strict             Exit 3 when there are no failures but something could
                       not be checked. Use in CI, where an unchecked control is
                       not the same as a checked one.
  -h, --help           Show this help.

Environment:
  GCLOUD_BIN           gcloud binary. Default: gcloud
  JQ_BIN               jq binary. Default: jq
  CURL_BIN             curl binary. Default: curl
  IAP_PROBE_TIMEOUT    Seconds to let the tunnel probe run. Default: 25

Input:
  deploy/gcp/<env>.handoff.json, as emitted by `make gcp-tf-handoff`. Every
  resource name, port and bucket comes from that file. Nothing is reconstructed
  from a naming convention, because a guessed name grades a resource that may
  not exist and reports the absence as a clean estate.

Checks:
  instance exists and is RUNNING
  instance has no external IP
  Shielded VM: secure boot, vTPM, integrity monitoring
  OS Login on, project SSH keys blocked
  per-environment runtime service account, not the default compute SA
  no 0.0.0.0/0 ingress in the instance's own network(s)
  SSH reachable only from the IAP range
  IAP tunnel authorises  -- and "authorised, nothing listening" is reported as
                            a DIFFERENT verdict from "permission denied"
  app port responds through the tunnel, if anything is listening
  state bucket: versioning, uniform access, public-access prevention
  deploy SA holds objectAdmin ONLY on the state bucket

Exit codes: 0 no FAIL, 1 one or more FAIL, 2 usage, 3 --strict unknowns,
            4 a v1 estate was named, 5 no handoff file.
USAGE
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

report() {
  local verdict="$1" item="$2" detail="$3"
  case "$verdict" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    "N/A") NA_COUNT=$((NA_COUNT + 1)) ;;
    *)
      printf '%s: internal error: unknown verdict %s\n' "$SCRIPT_NAME" "$verdict" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  printf '%-7s %-32s %s\n' "$verdict" "$item" "$detail"
}

# A note line is indented under its verdict so it reads as part of that item and
# can be copied straight out of the terminal.
note() {
  printf '        %s %s\n' '->' "$*"
}

# ---------------------------------------------------------------------------
# The read-only gate
# ---------------------------------------------------------------------------
#
# Allowlisted, not denylisted. A denylist of dangerous verbs has to anticipate
# every future gcloud surface; an allowlist of the inspection verbs this script
# legitimately uses does not, and it fails closed on anything new.
gcloud_ro() {
  local joined=" $* "
  case "$joined" in
    *' describe '* | *' list '* | *' version '*) ;;
    # get-iam-policy reads a policy and writes nothing. It is spelled with a
    # verb of its own rather than 'describe', so an allowlist of describe/list
    # alone would refuse the state-bucket role check -- the one that separates
    # objectAdmin from storage.admin. Its mutating twins, set-iam-policy and
    # add-iam-policy-binding, are NOT here and will be refused.
    *' get-iam-policy '*) ;;
    *)
      printf '%s: refusing to run a non-read-only gcloud call: gcloud %s\n' \
        "$SCRIPT_NAME" "$*" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  "$GCLOUD_BIN" "$@" 2>/dev/null
}

# The one deliberate widening, quarantined here rather than added to gcloud_ro
# so that it cannot be reached by accident from any other check.
#
# start-iap-tunnel opens a local listener and a tunnel session. It creates no
# cloud resource, modifies no configuration and deletes nothing -- it is the
# same class of operation as curling an endpoint, and it is the ONLY way to
# answer the question this script exists to answer, which is whether the tunnel
# authorises. Its genuinely mutating neighbours in the same command group --
# ssh, scp, reset, delete -- are absent and refused, because this function
# accepts start-iap-tunnel and nothing else.
gcloud_tunnel_probe() {
  local joined=" $* "
  case "$joined" in
    *' start-iap-tunnel '*) ;;
    *)
      printf '%s: refusing a non-probe call through the tunnel gate: gcloud %s\n' \
        "$SCRIPT_NAME" "$*" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  "$GCLOUD_BIN" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Kill a process and everything below it, BY PARENT PID -- never by pattern.
#
# Two reasons this is not just `kill $pid`.
#
# First, correctness: `gcloud start-iap-tunnel` is a wrapper. Killing the shell
# that launched it, or even the gcloud entrypoint, can leave the actual tunnel
# process alive, and an acceptance run that leaks a live IAP tunnel every time
# it is invoked is a worse citizen than no acceptance run at all.
#
# Second, safety: the obvious implementation is `pkill -f start-iap-tunnel`, and
# that is a trap. A shell's /proc/<pid>/cmdline contains the whole script text
# when the script is invoked through `bash -c`, so a pattern that names anything
# this script mentions can match the script's own shell and kill the run
# outright. Matching on parent PID cannot do that.
kill_tree() {
  local pid="$1" child
  [ -n "$pid" ] || return 0
  if have pgrep; then
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      kill_tree "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  fi
  kill "$pid" 2>/dev/null || true
  return 0
}

# An interrupted run must not leave a tunnel up either.
cleanup_tunnel() {
  if [ -n "${IAP_TUNNEL_PID:-}" ]; then
    kill_tree "$IAP_TUNNEL_PID"
    IAP_TUNNEL_PID=""
  fi
}
trap cleanup_tunnel EXIT INT TERM

# Fetch a resource as JSON. Returns non-zero when the call failed OR produced
# something that is not JSON, so every caller can turn "could not look" into
# UNKNOWN without inspecting exit codes twice. An empty result set from a
# successful list is '[]', which is JSON and is NOT an error -- the distinction
# between "no such resource" and "could not ask" is load-bearing here.
run_json() {
  local out=""
  out="$(gcloud_ro "$@" --format=json)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | "$JQ_BIN" -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# jq against a JSON string on stdin. Returns non-zero if the program fails, so a
# malformed response cannot be read as an empty answer.
jqr() {
  local json="$1"
  shift
  printf '%s' "$json" | "$JQ_BIN" -r "$@"
}

# ---------------------------------------------------------------------------
# The v1 refusal
# ---------------------------------------------------------------------------
#
# A real guard, not a courtesy. v1 runs as the ControlPlane identity against
# cp-dev-ajm in europe-west2 with instances named signalloom-ci*; v2 runs as the
# Signal Loom identity against the Signal Loom sandbox, in a different region,
# with instances named from the handoff. The concrete values live in
# docs/policy-as-versioned-code/V2-CICD.md and in the handoff file, not here --
# the only identifiers this script hardcodes are the v1 markers below, which it
# must name in order to refuse them.
#
# Point this suite at v1 and every check finds nothing,
# reports a tidy list of UNKNOWNs, and the reader concludes the estate is
# unreachable rather than that they graded the wrong estate. Refusing is the
# only outcome that cannot be misread.
refuse_v1_estate() {
  local haystack="$1" source_desc="$2" marker
  for marker in "${V1_MARKERS[@]}"; do
    case "$haystack" in
      *"$marker"*)
        printf '%s: REFUSING TO RUN. %s names "%s", which belongs to the v1 estate.\n' \
          "$SCRIPT_NAME" "$source_desc" "$marker" >&2
        printf '\n' >&2
        printf 'This is the v2 acceptance suite. It grades the Signal Loom Terraform\n' >&2
        printf 'estate: a different project, a different identity, a different region and\n' >&2
        printf 'different resource names.\n' >&2
        printf '\n' >&2
        printf 'v1 has its own path and is unaffected by this suite:\n' >&2
        printf '    scripts/ci/gcp-ci.sh          the imperative ControlPlane CI\n' >&2
        printf '    make ci-gcp / make ci-gcp-2   its entry points\n' >&2
        printf '\n' >&2
        printf 'Grading one estate with the other estate assumptions produces confident\n' >&2
        printf 'nonsense, so nothing was checked. Point --handoff at a v2 environment.\n' >&2
        exit "$EXIT_V1_ESTATE"
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# The handoff file
# ---------------------------------------------------------------------------
#
# Read defensively. Alternate spellings are accepted for every field because the
# emitter is a sibling component and a rename there must degrade into UNKNOWN
# rather than into a wrong answer. A field that is absent under every spelling
# stays empty, and the checks that need it report UNKNOWN.
load_handoff() {
  local path="$1"

  if [ ! -f "$path" ]; then
    printf '%s: no handoff file at %s\n' "$SCRIPT_NAME" "$path" >&2
    printf '\n' >&2
    printf 'This suite reads the deployed environment description rather than\n' >&2
    printf 'reconstructing resource names from a convention, because a guessed name\n' >&2
    printf 'grades a resource that may not exist and reports the absence as a clean\n' >&2
    printf 'estate.\n' >&2
    printf '\n' >&2
    printf 'Generate it:\n' >&2
    printf '    make gcp-tf-handoff\n' >&2
    printf '\n' >&2
    printf 'Or point at one explicitly:\n' >&2
    printf '    %s --handoff <path>\n' "$SCRIPT_NAME" >&2
    return "$EXIT_NO_HANDOFF"
  fi

  HANDOFF_JSON="$(cat "$path")" || {
    printf '%s: handoff file at %s could not be read\n' "$SCRIPT_NAME" "$path" >&2
    return "$EXIT_NO_HANDOFF"
  }

  if ! printf '%s' "$HANDOFF_JSON" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    printf '%s: handoff file at %s is not valid JSON\n' "$SCRIPT_NAME" "$path" >&2
    printf '%s: regenerate it with: make gcp-tf-handoff\n' "$SCRIPT_NAME" >&2
    return "$EXIT_NO_HANDOFF"
  fi

  # The whole document is checked for v1 markers, not just the fields this
  # script reads. A v1 project id sitting in a field added tomorrow is still a
  # v1 handoff.
  refuse_v1_estate "$HANDOFF_JSON" "the handoff file ${path}"

  # Schema first. The emitter bumps `schema` and `schema_version` together on any
  # breaking change, so an unrecognised value means the shape below may not hold.
  # Announced rather than fatal: the field-by-field reader degrades to UNKNOWN on
  # anything it cannot find, so a newer schema still produces an honest report
  # rather than a wrong one.
  local schema
  schema="$(hv '.schema')"
  case "$schema" in
    "" | "signalloom.gcp.handoff/v1") ;;
    *)
      printf '%s: note: handoff declares schema "%s", which this script does not know.\n' \
        "$SCRIPT_NAME" "$schema" >&2
      printf '%s: fields it cannot resolve will report UNKNOWN rather than a guess.\n\n' \
        "$SCRIPT_NAME" >&2
      ;;
  esac

  H_ENV="$(hv '.env // .environment_key // .env_key // .environment')"
  H_PROJECT="$(hv '.project // .project_id')"
  H_REGION="$(hv '.region')"
  H_ZONE="$(hv '.zone')"
  H_INSTANCE="$(hv '.instance // .instance_name // .vm')"
  H_INTERNAL_IP="$(hv '.internal_ip // .ip')"
  H_APP_PORT="$(hv '.app_port // .port')"
  H_STATE_BUCKET="$(hv '.state_bucket // .bucket')"
  H_DEPLOY_SA="$(hv '.deploy_sa // .deploy_service_account')"
  H_ACCESS_MODE="$(hv '.access_mode')"
  H_HOSTNAME="$(hv '.hostname')"
  H_KIND="$(hv '.kind')"
  return 0
}

# Is this environment expected to HAVE an instance at all?
#
# Returns 0 (yes, grade it) for a demo lane, an absent kind, and any value this
# script does not recognise. Returns 1 (no, it is N/A) ONLY for the exact string
# "ci", which has no compute module by design.
#
# Deliberately fail-closed, mirroring the generator's own relaxation: the
# dangerous shape is a demo environment carrying an unfamiliar kind and two
# blank instance fields, so anything unexpected must land on the strict side and
# report UNKNOWN rather than being waved through as "nothing to see here".
expects_an_instance() {
  case "$H_KIND" in
    ci) return 1 ;;
    *) return 0 ;;
  esac
}

# One field out of the handoff, empty when absent under every accepted spelling.
hv() {
  # pipefail-safe: ($1) // empty resolves one scalar JSON value; jq -r never writes more than one line, so head -1 truncates nothing live.
  printf '%s' "$HANDOFF_JSON" | "$JQ_BIN" -r "($1) // empty" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Instance posture -- one API call, five independent verdicts
# ---------------------------------------------------------------------------

check_instance() {
  local project="$1" instance="$2" zone="$3"
  local items=("instance RUNNING" "no external IP" "Shielded VM" "OS Login enforced" "runtime service account")
  local item raw

  if [ -z "$instance" ] && ! expects_an_instance; then
    # A CI lane has no compute module. Nothing is missing and nothing failed;
    # there is simply nothing here to grade.
    for item in "${items[@]}"; do
      report "N/A" "$item" "kind=ci: this lane has no instance by design"
    done
    return 0
  fi
  if [ -z "$project" ] || [ -z "$instance" ]; then
    for item in "${items[@]}"; do
      report UNKNOWN "$item" "handoff carries no project and/or instance name"
    done
    if [ -n "$H_KIND" ]; then
      note "kind=${H_KIND}, which is expected to have an instance"
    fi
    note "regenerate the handoff: make gcp-tf-handoff"
    return 0
  fi

  local -a describe_args=(compute instances describe "$instance" --project "$project")
  [ -n "$zone" ] && describe_args+=(--zone "$zone")

  if ! raw="$(run_json "${describe_args[@]}")"; then
    for item in "${items[@]}"; do
      report UNKNOWN "$item" "could not describe instance ${instance} in ${project}"
    done
    note "the environment may not be deployed, or the identity cannot read it"
    note "run scripts/gcp-tf/preflight.sh --project ${project} first"
    return 0
  fi
  CLOUD_READS_OK=1

  # 1. RUNNING. A TERMINATED instance is not a security finding, but every
  #    check below it means something different against a stopped VM and the
  #    reader needs to know which they are looking at.
  local status
  status="$(jqr "$raw" -r '.status // ""')" || status=""
  case "$status" in
    RUNNING) report PASS "instance RUNNING" "${instance} is RUNNING" ;;
    "") report UNKNOWN "instance RUNNING" "${instance}: status could not be read" ;;
    *)
      report FAIL "instance RUNNING" "${instance} is ${status}, not RUNNING"
      note "checks below still grade the configuration, but nothing is serving"
      ;;
  esac

  # 2. External IP. An accessConfigs entry on any interface is an external
  #    address, which routes around the load balancer and Cloud Armor together.
  local ext
  #    The pipe inside the collection is load-bearing. Written as
  #    `[ ...accessConfigs[]? .natIP // "assigned" ]`, jq parses the `//` as an
  #    alternative to the WHOLE preceding expression, and an empty stream -- an
  #    instance with no accessConfigs, which is the passing case -- is falsy, so
  #    the alternative fires and the array becomes ["assigned"]. Every compliant
  #    instance would then be reported as having an external address.
  ext="$(jqr "$raw" -r '[ .networkInterfaces[]? .accessConfigs[]? | (.natIP // "assigned") ] | join(", ")')" || ext="__unparseable__"
  if [ "$ext" = "__unparseable__" ]; then
    report UNKNOWN "no external IP" "${instance}: networkInterfaces could not be read"
  elif [ -n "$ext" ]; then
    report FAIL "no external IP" "${instance} has an external address: ${ext}"
    note "an access_config was added, or the VM was edited in the console; remove it"
  else
    report PASS "no external IP" "${instance}: no accessConfigs on any interface"
  fi

  # 3. Shielded VM. All three, reported by name -- "shielded: false" tells you
  #    nothing about which of the three knobs someone turned off.
  local off
  off="$(jqr "$raw" -r '
    ( .shieldedInstanceConfig // {} ) as $s
    | [ (if ($s.enableSecureBoot // false)          then empty else "secureBoot"          end),
        (if ($s.enableVtpm // false)                then empty else "vtpm"                end),
        (if ($s.enableIntegrityMonitoring // false) then empty else "integrityMonitoring" end) ]
    | join("+")')" || off="__unparseable__"
  if [ "$off" = "__unparseable__" ]; then
    report UNKNOWN "Shielded VM" "${instance}: shieldedInstanceConfig could not be read"
  elif [ -n "$off" ]; then
    report FAIL "Shielded VM" "${instance}: off: ${off}"
    note "boot integrity is not enforced; a tampered boot chain would not be detected"
  else
    report PASS "Shielded VM" "${instance}: secure boot + vTPM + integrity monitoring"
  fi

  # 4. OS Login and project-key blocking. Both, because either alone leaves a
  #    path: OS Login off means metadata keys authorise SSH, and project keys
  #    unblocked means a key pasted at project level authorises SSH here.
  local meta
  meta="$(jqr "$raw" -r '
    def m($k): ( [ .metadata.items[]? | select(.key == $k) | .value ] | first ) // "unset";
    "\(m("enable-oslogin"))|\(m("block-project-ssh-keys"))"')" || meta="__unparseable__"
  if [ "$meta" = "__unparseable__" ]; then
    report UNKNOWN "OS Login enforced" "${instance}: metadata could not be read"
  else
    local oslogin="${meta%%|*}" blockkeys="${meta##*|}"
    oslogin="$(printf '%s' "$oslogin" | tr '[:lower:]' '[:upper:]')"
    blockkeys="$(printf '%s' "$blockkeys" | tr '[:lower:]' '[:upper:]')"
    if [ "$oslogin" = "TRUE" ] && [ "$blockkeys" = "TRUE" ]; then
      report PASS "OS Login enforced" "${instance}: OS Login on, project keys blocked"
    else
      report FAIL "OS Login enforced" \
        "${instance}: enable-oslogin=${oslogin}, block-project-ssh-keys=${blockkeys}"
      note "SSH authorisation is not going through IAM on this instance"
    fi
  fi

  # 5. Runtime service account. The default compute SA is the finding worth
  #    naming: it is project-wide, it is shared by every instance that forgot to
  #    ask for something else, and it carries Editor on a default project.
  local sa
  sa="$(jqr "$raw" -r '( [ .serviceAccounts[]? .email ] | first ) // ""')" || sa="__unparseable__"
  if [ "$sa" = "__unparseable__" ]; then
    report UNKNOWN "runtime service account" "${instance}: serviceAccounts could not be read"
  elif [ -z "$sa" ]; then
    report FAIL "runtime service account" "${instance} runs with no service account"
    note "expected a per-environment runtime identity"
  # pipefail-safe: printf writes $sa (one short email, <200 bytes) in a single syscall, so grep -q's early exit never races the producer.
  elif printf '%s' "$sa" | grep -q -- '-compute@developer\.gserviceaccount\.com$'; then
    report FAIL "runtime service account" "${instance} runs the DEFAULT COMPUTE SA: ${sa}"
    note "project-wide, shared, and Editor on a default project"
  else
    report PASS "runtime service account" "${instance}: ${sa}"
  fi

  # 6. The handoff still describes this instance. A stale handoff is the quiet
  #    way this whole suite starts grading the wrong thing: the VM was rebuilt,
  #    it came back on a different address, and every check above went on
  #    reporting confidently about a machine that no longer exists in the shape
  #    the file claims. Comparing one value the emitter recorded against the
  #    live object is cheap and catches it.
  local live_ip
  live_ip="$(jqr "$raw" -r '( [ .networkInterfaces[]? .networkIP // empty ] | first ) // ""')" || live_ip="__unparseable__"
  if [ -z "$H_INTERNAL_IP" ]; then
    report UNKNOWN "handoff describes this estate" "handoff carries no internal IP to compare"
  elif [ "$live_ip" = "__unparseable__" ] || [ -z "$live_ip" ]; then
    report UNKNOWN "handoff describes this estate" "${instance}: live internal IP could not be read"
  elif [ "$live_ip" = "$H_INTERNAL_IP" ]; then
    report PASS "handoff describes this estate" "${instance} internal IP ${live_ip} matches the handoff"
  else
    report FAIL "handoff describes this estate" \
      "${instance} is at ${live_ip}; the handoff says ${H_INTERNAL_IP}"
    note "the handoff is stale -- the instance was probably rebuilt since it was written"
    note "regenerate it before trusting anything above: make gcp-tf-handoff"
  fi

  # The network(s) this instance is ACTUALLY on, for the firewall checks. Read
  # from the instance rather than assembled from a naming rule, so a VM attached
  # to an unexpected VPC is graded on the VPC it is attached to.
  INSTANCE_NETWORKS="$(jqr "$raw" -r '[ .networkInterfaces[]? .network // empty ] | map(split("/") | last) | unique | join(" ")')" || INSTANCE_NETWORKS=""
  return 0
}

# ---------------------------------------------------------------------------
# The declared access mode
# ---------------------------------------------------------------------------
#
# terraform/SECURITY.md #5 is titled "The allowlist mistaken for authentication",
# and this is the check that keeps that title honest. An IP allowlist answers
# "where is this request from"; it never answers "who is this". IAP answers the
# second question, which is the only one that makes the environment "not
# publicly accessible" in any sense a regulator or an attacker would accept.
#
# Graded from the handoff rather than from the edge, deliberately: this asserts
# what the estate was DECLARED to be. The tunnel probe below asserts what it
# does. Both matter, and a disagreement between them is worth seeing.
# access_mode is a THREE-valued enum, not a boolean. terraform/environments/
# variables.tf validates exactly:
#
#   iap                 IAP authenticates every request. No anonymous path.
#   allowlist           Cloud Armor IP allowlist ONLY. Coarse exposure control,
#                       and explicitly NOT authentication.
#   iap_and_allowlist   Both, and per the variable's own description the
#                       STRONGEST posture available.
#
# Treating this as an either/or switch is a real defect and not a cosmetic one:
# it fails the strongest configuration. It is also the mode most likely to be in
# use on a demo estate that is both IAP-gated and IP-restricted, so the wrong
# answer would show up precisely on the best-configured environment. Caught in
# review by the agent that owns the emitter.
#
# An unrecognised value is UNKNOWN rather than PASS or FAIL. This script cannot
# grade a posture it does not understand, and guessing in either direction is
# worse than saying so -- under --strict it still stops the run.
check_access_mode() {
  local mode="$1"
  case "$mode" in
    "")
      report UNKNOWN "access mode authenticates" "handoff carries no access_mode"
      note "regenerate the handoff: make gcp-tf-handoff"
      ;;
    iap)
      report PASS "access mode authenticates" "access_mode=iap -- IAP in front of the backend"
      ;;
    iap_and_allowlist)
      report PASS "access mode authenticates" \
        "access_mode=iap_and_allowlist -- IAP plus an IP allowlist, the strongest posture"
      note "authentication AND coarse exposure control; the allowlist narrows who can even try"
      ;;
    allowlist)
      report FAIL "access mode authenticates" "access_mode=allowlist -- no authentication at all"
      note "SECURITY.md #5: an allowlist says where a request came from, never who sent it"
      note "anything reaching the allowed source address reaches the application unauthenticated"
      ;;
    *)
      report UNKNOWN "access mode authenticates" "unrecognised access_mode: '${mode}'"
      note "terraform validates exactly: iap, allowlist, iap_and_allowlist"
      note "this script will not guess a posture it does not understand -- the handoff or the enum has drifted"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Firewall posture, scoped to the networks the instance is really on
# ---------------------------------------------------------------------------
#
# NO gcloud --filter IS USED FOR ANY ABSENCE CHECK. A mistyped server-side
# filter returns an empty list, an empty list reads as "clean", and the report
# goes green on a question it never asked. Every list is fetched whole and
# filtered here, where the filter is visible and testable.
check_firewall() {
  local project="$1"
  local raw scoped count offenders net

  if [ -z "$project" ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "handoff carries no project"
    report UNKNOWN "SSH only from IAP range" "handoff carries no project"
    return 0
  fi
  if [ -z "$INSTANCE_NETWORKS" ] && [ -z "$H_INSTANCE" ] && ! expects_an_instance; then
    report "N/A" "no 0.0.0.0/0 ingress" "kind=ci: no instance, so no network to scope to"
    report "N/A" "SSH only from IAP range" "kind=ci: no instance, so no network to scope to"
    return 0
  fi
  if [ -z "$INSTANCE_NETWORKS" ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "the instance's network could not be determined"
    report UNKNOWN "SSH only from IAP range" "the instance's network could not be determined"
    note "scoping firewall rules by a guessed VPC name would grade the wrong network"
    return 0
  fi

  if ! raw="$(run_json compute firewall-rules list --project "$project")"; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "could not list firewall rules in ${project}"
    report UNKNOWN "SSH only from IAP range" "could not list firewall rules in ${project}"
    return 0
  fi
  CLOUD_READS_OK=1

  # Scoped by the network the rule attaches to, not by the rule's own name. A
  # rule called anything at all still applies to every instance in the VPC, so
  # name-scoping here would miss precisely the rule someone added by hand.
  local nets_json="[]"
  for net in $INSTANCE_NETWORKS; do
    nets_json="$(printf '%s' "$nets_json" | "$JQ_BIN" -c --arg n "$net" '. + [$n]')" || nets_json="[]"
  done

  scoped="$(jqr "$raw" -c --argjson nets "$nets_json" '
    [ .[] | select( ((.network // "") | split("/") | last) as $n | $nets | index($n) ) ]')" || scoped=""
  if [ -z "$scoped" ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "firewall list could not be parsed"
    report UNKNOWN "SSH only from IAP range" "firewall list could not be parsed"
    return 0
  fi

  count="$(jqr "$scoped" 'length')" || count=0
  if [ "$count" -eq 0 ]; then
    # Not a pass. Nothing was inspected, so nothing was proved -- and a VPC with
    # no rules at all is more likely a scoping mistake than a hardened network.
    report UNKNOWN "no 0.0.0.0/0 ingress" "no rule attaches to network(s): ${INSTANCE_NETWORKS}"
    report UNKNOWN "SSH only from IAP range" "no rule attaches to network(s): ${INSTANCE_NETWORKS}"
    return 0
  fi

  # 1. World-open ingress. Only enabled ALLOW rules count: a disabled rule and a
  #    deny rule with a 0.0.0.0/0 source are both entirely normal.
  offenders="$(jqr "$scoped" -r '
    [ .[]
      | select((.direction // "INGRESS") == "INGRESS")
      | select((.disabled // false) == false)
      | select(((.allowed // []) | length) > 0)
      | select( [ .sourceRanges[]? ] | any(. == "0.0.0.0/0" or . == "::/0") )
      | .name
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "sourceRanges could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "no 0.0.0.0/0 ingress" "world-open allow rule(s): ${offenders}"
    note "these admit the whole internet to ${INSTANCE_NETWORKS} regardless of any edge policy"
  else
    report PASS "no 0.0.0.0/0 ingress" "${count} rule(s) on ${INSTANCE_NETWORKS}, none world-open"
  fi

  # 2. SSH exposure. A rule with protocol tcp and NO ports named permits every
  #    tcp port, so it permits 22 -- that case is the one a naive "does any rule
  #    list port 22" check walks straight past.
  local ssh_rules ssh_count
  ssh_rules="$(jqr "$scoped" -c '
    def covers22:
      [ .allowed[]? | select((.IPProtocol // "") | ascii_downcase | . == "tcp" or . == "all")
        | if ((.ports // []) | length) == 0 then true
          else ([ .ports[] | select(. == "22" or (test("^(\\d+)-(\\d+)$") and ((split("-")[0] | tonumber) <= 22) and ((split("-")[1] | tonumber) >= 22))) ] | length) > 0
          end ] | any(.);
    [ .[]
      | select((.direction // "INGRESS") == "INGRESS")
      | select((.disabled // false) == false)
      | select(((.allowed // []) | length) > 0)
      | select(covers22)
    ]')" || ssh_rules=""
  if [ -z "$ssh_rules" ]; then
    report UNKNOWN "SSH only from IAP range" "allowed[] could not be read"
    return 0
  fi

  ssh_count="$(jqr "$ssh_rules" 'length')" || ssh_count=0
  if [ "$ssh_count" -eq 0 ]; then
    report PASS "SSH only from IAP range" "no enabled ingress rule permits tcp/22"
    return 0
  fi

  offenders="$(jqr "$ssh_rules" -r --arg iap "$IAP_TCP_RANGE" '
    [ .[]
      | select( [ .sourceRanges[]? ] | any(. != $iap) or (length == 0) )
      | "\(.name)[\( [ .sourceRanges[]? ] | join(" ") )]"
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "SSH only from IAP range" "sourceRanges could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "SSH only from IAP range" "tcp/22 from outside ${IAP_TCP_RANGE}: ${offenders}"
    note "SSH should arrive only through Identity-Aware Proxy TCP forwarding"
  else
    report PASS "SSH only from IAP range" "${ssh_count} tcp/22 rule(s), source ${IAP_TCP_RANGE} only"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The IAP tunnel -- the distinction this whole script exists to draw
# ---------------------------------------------------------------------------
#
# There are three outcomes and they have three different owners:
#
#   permission denied            an IAM problem. The tunnel refuses the caller.
#   authorised, nothing listening  a DEPLOY problem. IAM is correct; the app is
#                                  not running. This is where demo-1 is today.
#   authorised and connected     both are fine.
#
# Reporting the middle case as the first sends an engineer to argue with an IAM
# configuration that is already right, and they will find nothing wrong with it,
# because nothing is. So "denied" is a FAIL and "authorised, nothing listening"
# is a PASS on the authorisation with an explicit note -- never the same verdict.
# The probe itself, shared by the app-port check and the SSH-path check.
#
# Sets IAP_VERDICT, IAP_LOCAL_PORT, IAP_TUNNEL_PID and IAP_PROBE_TAIL. Returns
# non-zero only when the probe exited without saying anything classifiable --
# the caller decides what each verdict MEANS, because the same three outcomes
# carry different weight on port 22 than they do on the application port.
#
# Leaves the tunnel RUNNING when it comes up, so the caller can use it. Every
# caller is responsible for tearing it down; cleanup_tunnel() catches the rest.
iap_probe() {
  local project="$1" instance="$2" zone="$3" port="$4"
  local log rc=0

  IAP_VERDICT="unknown"
  IAP_LOCAL_PORT=""
  IAP_TUNNEL_PID=""
  IAP_PROBE_TAIL=""

  log="$(mktemp)" || {
    IAP_VERDICT="no-tmpfile"
    return 1
  }

  local -a probe=(compute start-iap-tunnel "$instance" "$port"
    --project "$project" --local-host-port=localhost:0)
  [ -n "$zone" ] && probe+=(--zone "$zone")

  # Backgrounded so a tunnel that comes up and STAYS up -- the success case --
  # does not block for ever. Torn down by parent PID; never by pattern, because
  # the pattern would match this script's own command line.
  gcloud_tunnel_probe "${probe[@]}" >"$log" 2>&1 &
  IAP_TUNNEL_PID=$!

  local waited=0
  while [ "$waited" -lt "$IAP_PROBE_TIMEOUT" ]; do
    if grep -qE 'Listening on port \[[0-9]+\]' "$log" 2>/dev/null; then
      IAP_VERDICT="listening"
      # pipefail-safe: gcloud prints this banner once per tunnel; grep reads a closed file, not a live process, so head -1 truncates nothing live.
      IAP_LOCAL_PORT="$(grep -oE 'Listening on port \[[0-9]+\]' "$log" | head -1 | grep -oE '[0-9]+' | head -1)"
      break
    fi
    if grep -qiE '4033|not authoriz|not authoris|permission denied|PERMISSION_DENIED|Error while connecting.*[Ff]orbidden' "$log" 2>/dev/null; then
      IAP_VERDICT="denied"
      break
    fi
    if grep -qiE '4010|destination read failed|failed to connect to backend|connection refused|Connection refused' "$log" 2>/dev/null; then
      IAP_VERDICT="authorised-no-listener"
      break
    fi
    if ! kill -0 "$IAP_TUNNEL_PID" 2>/dev/null; then
      # The process is gone, so its log is now final -- but a fast exit (the
      # denied/no-listener stub cases print one line and exit immediately) can
      # race the three greps above: under load, the writer can land its last
      # byte and exit in the gap between this iteration's pattern checks and
      # this kill -0, which otherwise reports a correctly-denied or
      # correctly-closed tunnel as unclassified. One more pass over the now-
      # guaranteed-stable log before giving up.
      if grep -qE 'Listening on port \[[0-9]+\]' "$log" 2>/dev/null; then
        IAP_VERDICT="listening"
        # pipefail-safe: same single banner, same closed-file read as above.
        IAP_LOCAL_PORT="$(grep -oE 'Listening on port \[[0-9]+\]' "$log" | head -1 | grep -oE '[0-9]+' | head -1)"
      elif grep -qiE '4033|not authoriz|not authoris|permission denied|PERMISSION_DENIED|Error while connecting.*[Ff]orbidden' "$log" 2>/dev/null; then
        IAP_VERDICT="denied"
      elif grep -qiE '4010|destination read failed|failed to connect to backend|connection refused|Connection refused' "$log" 2>/dev/null; then
        IAP_VERDICT="authorised-no-listener"
      else
        rc=1
      fi
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  IAP_PROBE_TAIL="$(tr '\n' ' ' <"$log" | cut -c1-160)"
  rm -f "$log"
  return "$rc"
}

check_iap_tunnel() {
  local project="$1" instance="$2" zone="$3" port="$4"
  local rc=0

  if [ -z "$instance" ] && ! expects_an_instance; then
    IAP_VERDICT="not-applicable"
    report "N/A" "IAP tunnel authorises" "kind=ci: nothing to tunnel to"
    return 0
  fi
  if [ -z "$project" ] || [ -z "$instance" ] || [ -z "$port" ]; then
    IAP_VERDICT="unknown"
    report UNKNOWN "IAP tunnel authorises" "handoff carries no project, instance and/or app port"
    return 0
  fi

  iap_probe "$project" "$instance" "$zone" "$port" || rc=1
  if [ "$IAP_VERDICT" = "no-tmpfile" ]; then
    IAP_VERDICT="unknown"
    report UNKNOWN "IAP tunnel authorises" "could not create a temporary file for the probe"
    return 0
  fi

  case "$IAP_VERDICT" in
    listening)
      report PASS "IAP tunnel authorises" \
        "tunnel to ${instance}:${port} established (local port ${IAP_LOCAL_PORT:-unknown})"
      ;;
    denied)
      if [ "$CLOUD_READS_OK" -eq 0 ]; then
        # Nothing else in this run could be read either. gcloud answers
        # PERMISSION_DENIED to everything when a token has expired or an API is
        # off, so this is evidence about the credential, not about IAP.
        # Reporting it as an IAP denial would send someone to fix an IAM
        # configuration that was never broken.
        IAP_VERDICT="unknown"
        report UNKNOWN "IAP tunnel authorises" \
          "the probe was denied, but so was every other read in this run"
        note "this is an access problem for the whole run, not a verdict on IAP"
        note "run scripts/gcp-tf/preflight.sh --project ${project} to find the real cause"
      else
        report FAIL "IAP tunnel authorises" \
          "PERMISSION DENIED tunnelling to ${instance}:${port} -- this is an IAM problem"
        note "the caller lacks roles/iap.tunnelResourceAccessor, or the IAP TCP firewall rule is missing"
        note "this is NOT the same as 'nothing is listening'; the tunnel refused the caller"
      fi
      ;;
    authorised-no-listener)
      # The distinction. Authorisation is a PASS; the port is somebody else's
      # problem and is graded separately below.
      report PASS "IAP tunnel authorises" \
        "AUTHORISED -- IAM permits the tunnel to ${instance}:${port}"
      note "but nothing is listening on ${port} inside the VM: the tunnel opened and the backend refused"
      note "this is a DEPLOY problem, not an access problem. IAM is correct; the app is not running."
      ;;
    *)
      IAP_VERDICT="unknown"
      if [ "$rc" -ne 0 ]; then
        report UNKNOWN "IAP tunnel authorises" \
          "the probe exited without a classifiable result: ${IAP_PROBE_TAIL}"
      else
        report UNKNOWN "IAP tunnel authorises" \
          "the probe said nothing in ${IAP_PROBE_TIMEOUT}s; neither authorised nor denied was established"
      fi
      note "an unclassified probe is not a pass and not a failure; re-run, or raise IAP_PROBE_TIMEOUT"
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# The SSH path, and the OS Login gap named as its own condition
# ---------------------------------------------------------------------------
#
# Two different things are called "SSH access" here and they fail independently:
#
#   1. The IAP TCP tunnel to port 22. Governed by roles/iap.tunnelResourceAccessor
#      and the IAP firewall rule. This is what an acceptance run can use, and it
#      works today.
#   2. OS Login authorisation, which is what `gcloud compute ssh` additionally
#      requires. For an identity EXTERNAL to the organisation it needs
#      roles/compute.osLoginExternalUser, which is an ORG-scoped grant -- not a
#      project one, so no amount of project-level IAM will produce it.
#
# The estate is currently in the state where (1) works and (2) does not. That
# presents as "gcloud compute ssh fails", which reads as a broken VM or a broken
# tunnel and is neither. Naming it as its own condition is the whole point: a
# generic access failure sends someone to the wrong layer.
#
# Note what this check does NOT do: it never invokes `gcloud compute ssh`. That
# is a mutating verb, it is refused by both gates, and it would fail here for a
# reason that has nothing to do with the estate's posture.
check_ssh_path() {
  local project="$1" instance="$2" zone="$3"
  local rc=0

  if [ -z "$instance" ] && ! expects_an_instance; then
    report "N/A" "SSH path via IAP tunnel" "kind=ci: no instance to reach"
    return 0
  fi
  if [ -z "$project" ] || [ -z "$instance" ]; then
    report UNKNOWN "SSH path via IAP tunnel" "handoff carries no project and/or instance"
    return 0
  fi

  iap_probe "$project" "$instance" "$zone" "$SSH_PORT" || rc=1

  case "$IAP_VERDICT" in
    listening)
      report PASS "SSH path via IAP tunnel" \
        "tcp/${SSH_PORT} reachable through IAP on ${instance}"
      note "this is the supported path. \`gcloud compute ssh\` is a SEPARATE question:"
      note "it also needs OS Login authorisation, and an identity external to the org"
      note "needs roles/compute.osLoginExternalUser -- an ORG-scoped grant, not a project one."
      note "\`compute ssh\` failing while this line is PASS is that grant, not the estate."
      ;;
    denied)
      if [ "$CLOUD_READS_OK" -eq 0 ]; then
        report UNKNOWN "SSH path via IAP tunnel" \
          "the probe was denied, but so was every other read in this run"
        note "an access problem for the whole run, not a verdict on the SSH path"
      else
        report FAIL "SSH path via IAP tunnel" \
          "PERMISSION DENIED tunnelling to ${instance}:${SSH_PORT}"
        note "the caller lacks roles/iap.tunnelResourceAccessor, or the IAP firewall rule is missing"
        note "this is the tunnel, NOT OS Login: the connection never reached sshd"
      fi
      ;;
    authorised-no-listener)
      report FAIL "SSH path via IAP tunnel" \
        "AUTHORISED, but nothing is listening on tcp/${SSH_PORT} inside ${instance}"
      note "IAP is correct; sshd is not running or is bound elsewhere"
      ;;
    *)
      report UNKNOWN "SSH path via IAP tunnel" \
        "the probe was inconclusive: ${IAP_PROBE_TAIL:-no output in ${IAP_PROBE_TIMEOUT}s}"
      ;;
  esac

  # This check owns its tunnel and always tears it down: it runs last, so
  # nothing downstream needs it.
  if [ -n "$IAP_TUNNEL_PID" ]; then
    kill_tree "$IAP_TUNNEL_PID"
    wait "$IAP_TUNNEL_PID" 2>/dev/null || true
    IAP_TUNNEL_PID=""
  fi
  return 0
}

# Only meaningful once the tunnel is up. Never reports the app as down when the
# reason is that the tunnel never opened -- that is a different check with a
# different owner, and it has already reported above.
check_app_port() {
  local port="$1" code

  case "$IAP_VERDICT" in
    not-applicable)
      report "N/A" "app port responds" "kind=ci: this lane serves no application"
      ;;
    denied)
      report UNKNOWN "app port responds" "not attempted: the tunnel was refused"
      note "fix the IAP authorisation first; the app may well be fine"
      ;;
    authorised-no-listener)
      report FAIL "app port responds" "nothing is listening on ${port} inside the VM"
      note "the tunnel authorised, so this is the application, not access control"
      note "check the service on the instance; the estate itself is correctly configured"
      ;;
    listening)
      if [ -z "$IAP_LOCAL_PORT" ]; then
        report UNKNOWN "app port responds" "the tunnel is up but its local port could not be read"
      elif ! have "$CURL_BIN"; then
        report UNKNOWN "app port responds" "'${CURL_BIN}' is not on PATH"
      else
        code="$("$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 15 \
          "http://localhost:${IAP_LOCAL_PORT}/" 2>/dev/null)" || code=""
        case "$code" in
          "" | 000)
            report UNKNOWN "app port responds" "no HTTP response through the tunnel on ${port}"
            ;;
          2?? | 3??)
            report PASS "app port responds" "HTTP ${code} through the tunnel on ${port}"
            ;;
          *)
            report FAIL "app port responds" "HTTP ${code} through the tunnel on ${port}"
            note "the tunnel and the listener are both fine; the application returned an error"
            ;;
        esac
      fi
      ;;
    *)
      report UNKNOWN "app port responds" "not attempted: the tunnel probe was inconclusive"
      ;;
  esac

  # The tunnel and everything it spawned. See kill_tree(): by parent PID, never
  # by pattern.
  if [ -n "$IAP_TUNNEL_PID" ]; then
    kill_tree "$IAP_TUNNEL_PID"
    wait "$IAP_TUNNEL_PID" 2>/dev/null || true
    IAP_TUNNEL_PID=""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# State bucket protection
# ---------------------------------------------------------------------------
#
# Both gcloud storage surfaces are accepted. `gcloud storage buckets describe`
# renders snake_case top-level fields; the raw JSON API and older surfaces render
# an iamConfiguration object. Reading only one of the two would report UNKNOWN on
# a perfectly good bucket, and UNKNOWN on a control nobody re-checks is how a
# control stops being checked.
check_state_bucket() {
  local bucket="$1"
  if [ -z "$bucket" ]; then
    report UNKNOWN "state bucket protection" "handoff carries no state bucket name"
    note "regenerate the handoff: make gcp-tf-handoff"
    return 0
  fi

  local b versioning ubla pap bad=()
  if ! b="$(run_json storage buckets describe "gs://${bucket}")"; then
    report UNKNOWN "state bucket protection" "gs://${bucket} could not be described"
    return 0
  fi
  CLOUD_READS_OK=1

  versioning="$(jqr "$b" -r '(.versioning_enabled // .versioning.enabled // false) | tostring')" || versioning="unknown"
  ubla="$(jqr "$b" -r '(.uniform_bucket_level_access // .iamConfiguration.uniformBucketLevelAccess.enabled // false) | tostring')" || ubla="unknown"
  pap="$(jqr "$b" -r '(.public_access_prevention // .iamConfiguration.publicAccessPrevention // "") | tostring')" || pap="unknown"

  [ "$versioning" = "true" ] || bad+=("versioning=${versioning}")
  [ "$ubla" = "true" ] || bad+=("uniform_bucket_level_access=${ubla}")
  [ "$pap" = "enforced" ] || bad+=("public_access_prevention=${pap:-unset}")

  if [ "${#bad[@]}" -eq 0 ]; then
    report PASS "state bucket protection" "gs://${bucket}: versioning, UBLA, PAP enforced"
  else
    report FAIL "state bucket protection" "gs://${bucket}: ${bad[*]}"
    note "state holds resource ids and IAM member lists; an exposed or unversioned bucket is the whole estate"
  fi
  return 0
}

# The deploy identity's grant on the state bucket, and nothing more than it.
#
# objectAdmin reads and writes the state objects and CANNOT delete the bucket it
# stores history in. storage.admin can. A legacy bucket role (legacyBucketOwner,
# legacyBucketWriter) carries bucket-level permissions under a name that reads
# like an object role, which is exactly why it needs naming rather than
# pattern-matching on the word "admin".
check_deploy_sa_bucket_roles() {
  local bucket="$1" sa="$2"
  local pol roles bad=() r

  if [ -z "$bucket" ] || [ -z "$sa" ]; then
    report UNKNOWN "deploy SA: objectAdmin only" "handoff carries no state bucket and/or deploy SA"
    return 0
  fi

  if ! pol="$(run_json storage buckets get-iam-policy "gs://${bucket}")"; then
    report UNKNOWN "deploy SA: objectAdmin only" "the IAM policy on gs://${bucket} could not be read"
    note "needs storage.buckets.getIamPolicy"
    return 0
  fi
  CLOUD_READS_OK=1

  roles="$(jqr "$pol" -r --arg sa "serviceAccount:${sa}" '
    [ .bindings[]? | select( [ .members[]? ] | index($sa) ) | .role ] | unique | .[]')" || roles="__unparseable__"
  if [ "$roles" = "__unparseable__" ]; then
    report UNKNOWN "deploy SA: objectAdmin only" "bindings could not be parsed"
    return 0
  fi
  if [ -z "$roles" ]; then
    report FAIL "deploy SA: objectAdmin only" \
      "${sa} holds NO role on gs://${bucket}"
    note "the deploy identity cannot read or write state; apply would fail on init"
    return 0
  fi

  local has_object_admin="no"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      roles/storage.objectAdmin) has_object_admin="yes" ;;
      roles/storage.admin)
        bad+=("$r")
        ;;
      roles/storage.legacy*)
        bad+=("$r")
        ;;
      roles/owner | roles/editor)
        bad+=("$r")
        ;;
      *)
        bad+=("$r")
        ;;
    esac
  done <<<"$roles"

  if [ "${#bad[@]}" -gt 0 ]; then
    report FAIL "deploy SA: objectAdmin only" \
      "${sa} also holds on gs://${bucket}: ${bad[*]}"
    note "storage.admin and the legacy bucket roles can DELETE the bucket that holds every state version"
    note "objectAdmin at bucket scope is the whole grant the deploy identity needs"
    return 0
  fi
  if [ "$has_object_admin" = "no" ]; then
    report FAIL "deploy SA: objectAdmin only" \
      "${sa} does not hold roles/storage.objectAdmin on gs://${bucket}"
    return 0
  fi
  report PASS "deploy SA: objectAdmin only" "${sa}: roles/storage.objectAdmin, and nothing else"
  return 0
}

# ---------------------------------------------------------------------------

main() {
  local env_key="${ACCEPTANCE_ENV:-demo-1}"
  local handoff="${ACCEPTANCE_HANDOFF:-}"
  local strict="false"
  local repo_root

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  # Refused before anything is parsed, so a v1 project id typed on the command
  # line cannot reach a single cloud call.
  refuse_v1_estate " $* " "the command line"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        env_key="${2:-}"
        shift 2
        ;;
      --handoff)
        handoff="${2:-}"
        shift 2
        ;;
      --strict)
        strict="true"
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf '%s: unknown argument: %s\n\n' "$SCRIPT_NAME" "$1" >&2
        usage >&2
        return "$EXIT_USAGE"
        ;;
    esac
  done

  if [ -z "$env_key" ] && [ -z "$handoff" ]; then
    printf '%s: --env must not be empty.\n\n' "$SCRIPT_NAME" >&2
    usage >&2
    return "$EXIT_USAGE"
  fi
  [ -n "$handoff" ] || handoff="${repo_root}/deploy/gcp/${env_key}.handoff.json"

  if ! have "$GCLOUD_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; nothing can be checked.\n' "$SCRIPT_NAME" "$GCLOUD_BIN" >&2
    return "$EXIT_USAGE"
  fi
  if ! have "$JQ_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; every check would be UNKNOWN.\n' "$SCRIPT_NAME" "$JQ_BIN" >&2
    return "$EXIT_USAGE"
  fi

  load_handoff "$handoff" || return "$?"

  # The handoff's own env key wins for reporting, but a disagreement with --env
  # is worth saying out loud: it usually means the wrong file was named.
  if [ -n "$H_ENV" ] && [ -n "$env_key" ] && [ "$H_ENV" != "$env_key" ]; then
    printf '%s: note: --env is %s but the handoff describes %s. Grading %s.\n\n' \
      "$SCRIPT_NAME" "$env_key" "$H_ENV" "$H_ENV" >&2
  fi

  printf '%s: v2 acceptance for ENV=%s (kind=%s) in project %s (%s)\n' \
    "$SCRIPT_NAME" "${H_ENV:-$env_key}" "${H_KIND:-unset}" \
    "${H_PROJECT:-<unknown>}" "${H_REGION:-<no region>}"
  printf '%s: instance %s, app port %s, hostname %s\n' \
    "$SCRIPT_NAME" "${H_INSTANCE:-<unknown>}" "${H_APP_PORT:-<unknown>}" \
    "${H_HOSTNAME:-<none: no DNS name for this environment>}"
  printf '%s: handoff %s\n' "$SCRIPT_NAME" "$handoff"
  printf '%s: read-only. Nothing below creates, modifies or deletes anything.\n\n' "$SCRIPT_NAME"

  # Every check runs. None short-circuits the rest: a report that stops at the
  # first failure produces one finding per invocation, and the point of an
  # acceptance run is to hand over the whole posture at once.
  #
  # ORDER MATTERS, and only in one place: every check that makes an ordinary
  # cloud read runs BEFORE the tunnel probe, so that CLOUD_READS_OK is fully
  # determined by the time the probe has to decide whether a denial is evidence
  # about IAP or evidence about the credential. Moving the probe earlier would
  # silently restore the wrong-owner failure it exists to avoid.
  check_instance "$H_PROJECT" "$H_INSTANCE" "$H_ZONE" || true
  check_firewall "$H_PROJECT" || true
  check_access_mode "$H_ACCESS_MODE" || true
  check_state_bucket "$H_STATE_BUCKET" || true
  check_deploy_sa_bucket_roles "$H_STATE_BUCKET" "$H_DEPLOY_SA" || true
  check_iap_tunnel "$H_PROJECT" "$H_INSTANCE" "$H_ZONE" "$H_APP_PORT" || true
  check_app_port "${H_APP_PORT:-<unset>}" || true
  # Last, because it opens a second tunnel and owns its teardown.
  check_ssh_path "$H_PROJECT" "$H_INSTANCE" "$H_ZONE" || true

  if [ "$NA_COUNT" -gt 0 ]; then
    printf '\n%s: %d pass, %d fail, %d unknown, %d n/a\n' \
      "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT" "$NA_COUNT"
    printf '%s: n/a = nothing to check by design (kind=%s), NOT a gap in the report.\n' \
      "$SCRIPT_NAME" "${H_KIND:-unset}"
  else
    printf '\n%s: %d pass, %d fail, %d unknown\n' \
      "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT"
  fi

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s: NOT ACCEPTED -- each FAIL above names what it re-opens.\n' "$SCRIPT_NAME" >&2
    return "$EXIT_FAILURES"
  fi
  if [ "$UNKNOWN_COUNT" -gt 0 ]; then
    printf '%s: no failures, but %d control(s) could not be checked. An unchecked control is not a passing one.\n' \
      "$SCRIPT_NAME" "$UNKNOWN_COUNT"
    if [ "$strict" = "true" ]; then
      return "$EXIT_STRICT_UNKNOWN"
    fi
  fi
  return 0
}

# Guarded so the suite can source this file and drive gcloud_ro() and
# refuse_v1_estate() directly. A guard nobody can call in isolation is a guard
# nobody tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
