#!/usr/bin/env bash
#
# teardown-verify.sh -- run this AFTER a destroy, and believe the destroy only
# once it has passed.
#
# `terraform destroy` reporting success means Terraform removed everything IT
# knows about. That is a narrower claim than "the environment is gone", and the
# gap between the two is where the bill comes from:
#
#   * a static IP reserved outside the module, or promoted from ephemeral, which
#     keeps charging at the unattached rate precisely BECAUSE nothing uses it,
#   * a persistent disk whose instance is gone but whose auto_delete was false,
#   * a snapshot taken by hand during the demo,
#   * a resource created in the console that state never learned about.
#
# None of those appear in a destroy plan, and none of them appear in a check
# that only reads state.
#
# The second half of this script matters more than the first. A teardown check
# that only asserts ABSENCE gives a destroy that deleted the Terraform state
# bucket, or another environment, a perfect score -- absence is exactly what it
# would find. So the protected foundations are asserted PRESENT, and losing one
# is a FAIL as loud as any leftover.
#
# READ-ONLY BY CONSTRUCTION, on the same gcloud_ro() gate preflight.sh and
# conformance.sh use. No server-side --filter is used for any absence check: a
# mistyped filter returns an empty list, an empty list is what "destroyed" looks
# like, and the report would go green on a question it never asked.
#
# Usage:
#   teardown-verify.sh --project <id> --env <key> [--bucket <name>]
#                      [--other-env <key>]... [--strict]
#
# Exit codes:
#   0  no FAIL. UNKNOWNs may be present and are listed.
#   1  at least one FAIL -- something survived, or something protected did not.
#   2  usage error.
#   3  --strict, no FAIL, but at least one UNKNOWN.
#
# shellcheck disable=SC2016
# The jq programs below are single-quoted on purpose: $p and $e are jq variables
# bound by --arg, not shell variables. Letting the shell expand them would
# substitute values into the program text and change what jq parses.
set -Eeuo pipefail

readonly SCRIPT_NAME="teardown-verify"
readonly EXIT_FAILURES=1
readonly EXIT_USAGE=2
readonly EXIT_STRICT_UNKNOWN=3

GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
JQ_BIN="${JQ_BIN:-jq}"

export SSH_AUTH_SOCK=""

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0

# Raw list responses are cached here so the "other environments untouched"
# checks read the same bytes the absence checks read, rather than re-asking and
# risking a different answer from a different moment.
CACHE_DIR=""

# Whether any cloud read succeeded in this run. Read only by the state-bucket
# check, to tell "the bucket is gone" apart from "nothing worked at all".
#
# It is a FILE, not a variable, and that is not an accident: every run_json call
# happens inside a command substitution, which is a subshell, so a counter
# incremented there is discarded the moment the substitution closes. A variable
# here would read 0 on every run and the discrimination below would silently
# never happen -- a guard that can only ever take one branch.
READS_OK_MARKER=""

usage() {
  cat <<'USAGE'
Usage: teardown-verify.sh --project <id> --env <key> [options]

Read-only verification that an environment is GONE and that the protected
foundations are STILL THERE. Run after 'make gcp-tf-destroy'. Creates, modifies
and deletes nothing.

Required:
  --project <id>       GCP project id the environment was deployed into.
                       Also read from TEARDOWN_PROJECT.
  --env <key>          Environment key that was destroyed, e.g. demo-1.
                       Resources are named sl-<key>-<role>.
                       Also read from TEARDOWN_ENV.

Options:
  --bucket <name>      Terraform state bucket. It must SURVIVE the destroy.
                       Omitted means that check reports UNKNOWN, which on this
                       one item is a poor substitute for checking it.
                       Also read from TEARDOWN_STATE_BUCKET.
  --other-env <key>    An environment that must be untouched. Repeatable.
                       Omitted means the collateral-damage check is UNKNOWN:
                       with nothing named, "nothing else was harmed" is not a
                       finding, it is an assumption.
  --strict             Exit 3 when there are no failures but something could
                       not be checked.
  -h, --help           Show this help.

Environment:
  GCLOUD_BIN           gcloud binary. Default: gcloud
  JQ_BIN               jq binary. Default: jq

What is asserted ABSENT (leftovers):
  instance, instance group, subnet, VPC, forwarding rules, backend service,
  Cloud Armor policy, per-environment runtime service account

What is asserted ABSENT and costs money while it survives:
  reserved static IP addresses, persistent disks, snapshots

What is asserted PRESENT (a destroy that took these is the emergency):
  the Terraform state bucket, the CI plan/apply service accounts,
  every environment named with --other-env

Exit codes: 0 no FAIL, 1 one or more FAIL, 2 usage error, 3 --strict unknowns.
USAGE
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

report() {
  local verdict="$1" item="$2" kind="$3" detail="$4"
  case "$verdict" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    *)
      printf '%s: internal error: unknown verdict %s\n' "$SCRIPT_NAME" "$verdict" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  printf '%-7s %-30s [%s] %s\n' "$verdict" "$item" "$kind" "$detail"
}

fix() {
  printf '        %s %s\n' '->' "$*"
}

# ---------------------------------------------------------------------------
# The read-only gate -- identical in shape to preflight.sh and conformance.sh
# ---------------------------------------------------------------------------

gcloud_ro() {
  local joined=" $* "
  case "$joined" in
    *' describe '* | *' list '* | *' version '*) ;;
    *' get-iam-policy '*) ;;
    *)
      printf '%s: refusing to run a non-read-only gcloud call: gcloud %s\n' \
        "$SCRIPT_NAME" "$*" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  "$GCLOUD_BIN" "$@" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

run_json() {
  local out=""
  out="$(gcloud_ro "$@" --format=json)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | "$JQ_BIN" -e . >/dev/null 2>&1 || return 1
  [ -n "$READS_OK_MARKER" ] && : >"$READS_OK_MARKER"
  printf '%s' "$out"
}

jqr() {
  local json="$1"
  shift
  printf '%s' "$json" | "$JQ_BIN" -r "$@"
}

cache_put() { printf '%s' "$2" >"${CACHE_DIR}/$1.json"; }
cache_get() { [ -f "${CACHE_DIR}/$1.json" ] && cat "${CACHE_DIR}/$1.json"; }

# ---------------------------------------------------------------------------
# Absence
# ---------------------------------------------------------------------------
#
# check_absent <cache-key> <item> <prefix> -- <gcloud args...>
#
# Every compute resource type answers to .name, so one function covers eight
# checks. Filtering is client-side and the trailing hyphen on the prefix is
# load-bearing: sl-demo-1 is a prefix of sl-demo-10, and grading another
# environment's survivors as this one's leftovers would be a false alarm that
# teaches people to ignore the report.
check_absent() {
  local key="$1" item="$2" prefix="$3"
  shift 4 # drop the literal '--'
  local raw names count

  if ! raw="$(run_json "$@")"; then
    report UNKNOWN "$item" "leftover" "could not list ${item}"
    return 0
  fi
  cache_put "$key" "$raw"

  names="$(jqr "$raw" -r --arg p "${prefix}-" \
    '[ .[] | select((.name // "") | startswith($p)) | .name ] | join(", ")')" || names="__unparseable__"
  if [ "$names" = "__unparseable__" ]; then
    report UNKNOWN "$item" "leftover" "response could not be parsed"
    return 0
  fi
  if [ -n "$names" ]; then
    # Counted by jq, not by piping the joined string into wc -l: printf without
    # a trailing newline makes wc -l report 0 for a single survivor, and "0
    # survived: sl-demo-1-vm" is a FAIL line nobody would trust.
    count="$(jqr "$raw" -r --arg p "${prefix}-" \
      '[ .[] | select((.name // "") | startswith($p)) ] | length')" || count="?"
    report FAIL "$item" "leftover" "${count} survived: ${names}"
    return 0
  fi
  report PASS "$item" "leftover" "none named ${prefix}-*"
  return 0
}

# ---------------------------------------------------------------------------
# Orphans -- the leftovers that keep charging
# ---------------------------------------------------------------------------
#
# These are separated from the plain absence checks because they are the ones a
# destroy classically leaves behind, and because their failure has a running
# cost rather than a security cost. A reserved static IP is billed at a HIGHER
# rate when it is unattached than when it is in use, so "nothing is using it" is
# the expensive state, not the harmless one.
check_orphan_addresses() {
  local project="$1" prefix="$2" raw rows
  if ! raw="$(run_json compute addresses list --project "$project")"; then
    report UNKNOWN "reserved static IPs" "orphan" "could not list addresses"
    return 0
  fi
  cache_put addresses "$raw"
  rows="$(jqr "$raw" -r --arg p "${prefix}-" '
    [ .[] | select((.name // "") | startswith($p))
      | "\(.name)=\(.address // "?")(\(.status // "?"))" ] | join(", ")')" || rows="__unparseable__"
  if [ "$rows" = "__unparseable__" ]; then
    report UNKNOWN "reserved static IPs" "orphan" "address list could not be parsed"
  elif [ -n "$rows" ]; then
    report FAIL "reserved static IPs" "orphan" "$rows"
    fix "an unattached reserved address is billed at the higher idle rate; release it"
    fix "gcloud compute addresses delete <name> --project ${project} --global   # or --region"
  else
    report PASS "reserved static IPs" "orphan" "none named ${prefix}-*"
  fi
  return 0
}

check_orphan_disks() {
  local project="$1" prefix="$2" raw rows
  if ! raw="$(run_json compute disks list --project "$project")"; then
    report UNKNOWN "persistent disks" "orphan" "could not list disks"
    return 0
  fi
  cache_put disks "$raw"
  # An attached disk cannot outlive its instance here, so anything found is
  # unattached by construction -- but the users[] field is reported anyway,
  # because a disk that IS attached means the instance check above was wrong.
  rows="$(jqr "$raw" -r --arg p "${prefix}-" '
    [ .[] | select((.name // "") | startswith($p))
      | "\(.name)=\(.sizeGb // "?")GB(\(if ((.users // []) | length) == 0 then "unattached" else "ATTACHED" end))" ]
    | join(", ")')" || rows="__unparseable__"
  if [ "$rows" = "__unparseable__" ]; then
    report UNKNOWN "persistent disks" "orphan" "disk list could not be parsed"
  elif [ -n "$rows" ]; then
    report FAIL "persistent disks" "orphan" "$rows"
    fix "a disk with auto_delete=false outlives its instance and keeps charging"
  else
    report PASS "persistent disks" "orphan" "none named ${prefix}-*"
  fi
  return 0
}

check_orphan_snapshots() {
  local project="$1" prefix="$2" raw rows
  if ! raw="$(run_json compute snapshots list --project "$project")"; then
    report UNKNOWN "snapshots" "orphan" "could not list snapshots"
    return 0
  fi
  cache_put snapshots "$raw"
  rows="$(jqr "$raw" -r --arg p "${prefix}-" '
    [ .[] | select((.name // "") | startswith($p))
      | "\(.name)=\(.storageBytes // "?")B" ] | join(", ")')" || rows="__unparseable__"
  if [ "$rows" = "__unparseable__" ]; then
    report UNKNOWN "snapshots" "orphan" "snapshot list could not be parsed"
  elif [ -n "$rows" ]; then
    report FAIL "snapshots" "orphan" "$rows"
    fix "snapshots survive both the disk and the destroy, and are billed monthly"
  else
    report PASS "snapshots" "orphan" "none named ${prefix}-*"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Service accounts -- one list, an absence and a presence
# ---------------------------------------------------------------------------

check_service_accounts() {
  local project="$1" env_key="$2" raw rt_left ci_missing=()
  if ! raw="$(run_json iam service-accounts list --project "$project")"; then
    report UNKNOWN "runtime service account" "leftover" "could not list service accounts"
    report UNKNOWN "CI service accounts" "protected" "could not list service accounts"
    return 0
  fi
  cache_put service_accounts "$raw"

  rt_left="$(jqr "$raw" -r --arg e "sl-rt-${env_key}@" '
    [ .[] | select((.email // "") | startswith($e)) | .email ] | join(", ")')" || rt_left="__unparseable__"
  if [ "$rt_left" = "__unparseable__" ]; then
    report UNKNOWN "runtime service account" "leftover" "service account list could not be parsed"
  elif [ -n "$rt_left" ]; then
    report FAIL "runtime service account" "leftover" "$rt_left"
    fix "a surviving runtime SA keeps its role bindings; delete it or the next apply reuses it"
  else
    report PASS "runtime service account" "leftover" "sl-rt-${env_key}@ is gone"
  fi

  # The CI identities are platform, not environment. An environment destroy that
  # reached them has taken the estate's ability to deploy anything at all, and
  # an absence-only check would have called that a clean teardown.
  local sa
  for sa in sl-ci-plan sl-ci-apply; do
    if ! jqr "$raw" -e --arg e "${sa}@" \
      'any(.[]; (.email // "") | startswith($e))' >/dev/null 2>&1; then
      ci_missing+=("$sa")
    fi
  done
  if [ "${#ci_missing[@]}" -gt 0 ]; then
    report FAIL "CI service accounts" "protected" "MISSING: ${ci_missing[*]}"
    fix "these are platform identities; an environment destroy must not reach them"
  else
    report PASS "CI service accounts" "protected" "sl-ci-plan and sl-ci-apply present"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The state bucket -- the check that makes this script worth running
# ---------------------------------------------------------------------------
#
# Narrow, deliberate exception to the UNKNOWN rule that governs every other
# check here -- and it is narrowed by evidence rather than by assertion.
#
# If the describe fails while every OTHER read in this run also failed, the
# credential or the network is broken and the bucket's fate is genuinely
# unknown. Screaming "the state bucket is gone" at someone whose token expired
# is the exact failure this repo's preflight was written against, and after the
# second false alarm nobody reads the line at all.
#
# If the describe fails while other reads SUCCEEDED, the identity works, the
# project is reachable, and this one bucket did not answer. That is a FAIL, and
# it is the loudest one in the file.
check_state_bucket_survives() {
  local bucket="$1" b name
  if [ -z "$bucket" ]; then
    report UNKNOWN "state bucket survives" "protected" "--bucket not supplied"
    fix "supply it. Losing this bucket orphans every resource in every environment."
    return 0
  fi
  if ! b="$(run_json storage buckets describe "gs://${bucket}")"; then
    if [ -n "$READS_OK_MARKER" ] && [ ! -e "$READS_OK_MARKER" ]; then
      report UNKNOWN "state bucket survives" "protected" \
        "gs://${bucket} could not be read, and neither could anything else -- this is an access problem, not a verdict on the bucket"
      fix "scripts/gcp-tf/preflight.sh --project <id>   # resolve the credential first, then re-run"
      return 0
    fi
    report FAIL "state bucket survives" "protected" \
      "gs://${bucket} could not be read, while other reads in this run succeeded -- it is GONE or its ACLs changed"
    fix "STOP. Do not apply anything until this is resolved."
    fix "gcloud storage buckets describe gs://${bucket}   # read the actual error"
    fix "if it is gone, every environment's state is gone with it"
    return 0
  fi
  name="$(jqr "$b" -r '(.bucket // .name // "") | tostring')" || name=""
  report PASS "state bucket survives" "protected" "gs://${bucket} exists and is readable${name:+ (${name})}"
  return 0
}

# ---------------------------------------------------------------------------
# Collateral damage
# ---------------------------------------------------------------------------
#
# Reads the cached lists rather than re-asking. If nothing at all belonging to
# another environment is visible, that environment is either gone or was never
# there -- and this script cannot tell the two apart, so it says so.
check_other_envs() {
  local -a others=("$@")
  if [ "${#others[@]}" -eq 0 ]; then
    report UNKNOWN "other environments untouched" "protected" "no --other-env supplied"
    fix "name the environments that must survive; otherwise this is an assumption, not a check"
    return 0
  fi

  local key other_prefix total raw n found_any=0
  for key in "${others[@]}"; do
    other_prefix="sl-${key}"
    total=0
    found_any=0
    local src
    for src in instances networks backend_services security_policies; do
      raw="$(cache_get "$src")" || continue
      [ -n "$raw" ] || continue
      found_any=1
      n="$(jqr "$raw" -r --arg p "${other_prefix}-" \
        '[ .[] | select((.name // "") | startswith($p)) ] | length')" || n=0
      total=$((total + n))
    done
    raw="$(cache_get service_accounts)" || raw=""
    if [ -n "$raw" ]; then
      found_any=1
      n="$(jqr "$raw" -r --arg e "sl-rt-${key}@" \
        '[ .[] | select((.email // "") | startswith($e)) ] | length')" || n=0
      total=$((total + n))
    fi

    if [ "$found_any" -eq 0 ]; then
      report UNKNOWN "environment ${key} untouched" "protected" "no list could be read to check against"
    elif [ "$total" -eq 0 ]; then
      report FAIL "environment ${key} untouched" "protected" \
        "nothing named sl-${key}-* is present -- the destroy may have taken it"
      fix "if ${key} was never deployed, drop it from --other-env; otherwise this is collateral damage"
    else
      report PASS "environment ${key} untouched" "protected" "${total} resource(s) named sl-${key}-* still present"
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------

main() {
  local project="${TEARDOWN_PROJECT:-}"
  local env_key="${TEARDOWN_ENV:-}"
  local bucket="${TEARDOWN_STATE_BUCKET:-}"
  local strict="false"
  local -a other_envs=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        project="${2:-}"
        shift 2
        ;;
      --env)
        env_key="${2:-}"
        shift 2
        ;;
      --bucket)
        bucket="${2:-}"
        shift 2
        ;;
      --other-env)
        other_envs+=("${2:-}")
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

  if [ -z "$project" ] || [ -z "$env_key" ]; then
    printf '%s: --project and --env are both required.\n\n' "$SCRIPT_NAME" >&2
    usage >&2
    return "$EXIT_USAGE"
  fi

  if ! have "$GCLOUD_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; nothing can be checked.\n' "$SCRIPT_NAME" "$GCLOUD_BIN" >&2
    return "$EXIT_USAGE"
  fi
  if ! have "$JQ_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; every check would be UNKNOWN.\n' "$SCRIPT_NAME" "$JQ_BIN" >&2
    return "$EXIT_USAGE"
  fi

  local prefix="sl-${env_key}"

  CACHE_DIR="$(mktemp -d)"
  READS_OK_MARKER="${CACHE_DIR}/.any-read-succeeded"
  # 'or true' so a failed cleanup cannot rewrite the exit status of the run --
  # under errexit the last command in an EXIT trap becomes the script's verdict.
  trap 'rm -rf "${CACHE_DIR}" 2>/dev/null || true' EXIT

  printf '%s: read-only teardown verification for ENV=%s (resources named %s-*) in project %s\n' \
    "$SCRIPT_NAME" "$env_key" "$prefix" "$project"
  printf '%s: nothing below creates, modifies or deletes anything.\n\n' "$SCRIPT_NAME"

  check_absent instances "instance" "$prefix" -- \
    compute instances list --project "$project"
  check_absent instance_groups "instance group" "$prefix" -- \
    compute instance-groups list --project "$project"
  check_absent networks "VPC network" "$prefix" -- \
    compute networks list --project "$project"
  check_absent subnets "subnet" "$prefix" -- \
    compute networks subnets list --project "$project"
  check_absent forwarding_rules "forwarding rule" "$prefix" -- \
    compute forwarding-rules list --project "$project"
  check_absent backend_services "backend service" "$prefix" -- \
    compute backend-services list --project "$project"
  check_absent security_policies "Cloud Armor policy" "$prefix" -- \
    compute security-policies list --project "$project"

  check_orphan_addresses "$project" "$prefix"
  check_orphan_disks "$project" "$prefix"
  check_orphan_snapshots "$project" "$prefix"

  check_service_accounts "$project" "$env_key"
  check_state_bucket_survives "$bucket"
  check_other_envs "${other_envs[@]+"${other_envs[@]}"}"

  printf '\n%s: %d pass, %d fail, %d unknown\n' \
    "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s: TEARDOWN NOT VERIFIED -- something survived, or something protected did not.\n' \
      "$SCRIPT_NAME" >&2
    return "$EXIT_FAILURES"
  fi
  if [ "$UNKNOWN_COUNT" -gt 0 ]; then
    printf '%s: no failures, but %d item(s) could not be checked.\n' \
      "$SCRIPT_NAME" "$UNKNOWN_COUNT"
    if [ "$strict" = "true" ]; then
      return "$EXIT_STRICT_UNKNOWN"
    fi
  fi
  return 0
}

# Guarded so the suite can source this file and drive gcloud_ro() directly. A
# read-only gate nobody can call in isolation is a gate nobody tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
