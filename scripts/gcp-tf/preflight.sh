#!/usr/bin/env bash
#
# preflight.sh -- answer "can the demo-1 apply succeed?" before anyone spends an
# evening discovering that it cannot.
#
# READ-ONLY BY CONSTRUCTION. Every cloud call goes through gcloud_ro(), which
# refuses any verb outside a hardcoded allowlist of describe/list/version. That
# is a mechanism, not a promise: a future edit that reaches for `services
# enable` or `buckets create` aborts on the spot rather than quietly mutating a
# project during what everyone believes is an inspection.
#
# Every item reports exactly one of three verdicts, and the difference between
# the last two is the whole point of the script:
#
#   PASS      checked, and it is as required.
#   FAIL      checked, and it is NOT as required. Actionable, with the fix named.
#   UNKNOWN   could NOT be checked -- no permission, no tool, nothing supplied.
#
# UNKNOWN is never downgraded to FAIL. A preflight that reports "API not
# enabled" when it merely could not look sends someone to enable an API that was
# already on, and the next person trusts the report a little less. Reporting
# ignorance as ignorance is the only way the PASS lines stay worth reading.
#
# Usage:
#   preflight.sh --project <id> [--bucket <name>] [--dns-zone <name>] [--env demo-1]
#
# Exit codes:
#   0  no FAIL. UNKNOWNs may be present and are listed.
#   1  at least one FAIL.
#   2  usage error.
set -Eeuo pipefail

readonly SCRIPT_NAME="preflight"
readonly EXIT_FAILURES=1
readonly EXIT_USAGE=2
readonly TF_MIN_MAJOR=1
readonly TF_MIN_MINOR=9

# Binaries are injectable so the test suite can put a stub on PATH and drive
# every branch below without a cloud account. A component that can only be
# exercised against the real system is a component nobody exercises.
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"

# gcloud shells out to ssh for IAP tunnels, and a loaded ssh-agent on this
# machine answers "agent refused operation" to calls it has no business
# handling. The failure surfaces as a VM or network error, which is the wrong
# place to look entirely. An empty value makes gcloud use its own key.
export SSH_AUTH_SOCK=""

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0

# Set by check_active_account, read by check_project_reachable so its failure
# message can name the identity that actually failed rather than "someone".
ACTIVE_ACCOUNT=""

usage() {
  cat <<'USAGE'
Usage: preflight.sh --project <id> [options]

Read-only readiness check for a Signal Loom Terraform environment. Creates,
modifies and deletes nothing. Safe to run repeatedly, safe to run while an
apply is in flight, safe to run before you are sure which project you meant.

Required:
  --project <id>       GCP project id the environment is applied into.
                       Also read from PREFLIGHT_PROJECT.

Options:
  --env <key>          Environment key, for reporting only. Default: demo-1
  --bucket <name>      Terraform state bucket, as produced by
                       'make gcp-tf-bootstrap'. Omitted means the bucket check
                       reports UNKNOWN rather than guessing a name.
                       Also read from PREFLIGHT_STATE_BUCKET.
  --dns-zone <name>    Cloud DNS managed zone NAME (not the domain). Omitted
                       means DNS is not configured for this environment and the
                       zone check reports UNKNOWN.
                       Also read from PREFLIGHT_DNS_ZONE.
  -h, --help           Show this help.

Environment:
  GCLOUD_BIN           gcloud binary. Default: gcloud
  TERRAFORM_BIN        terraform binary. Default: terraform

Exit codes: 0 no FAIL, 1 one or more FAIL, 2 usage error.
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
    *)
      printf '%s: internal error: unknown verdict %s\n' "$SCRIPT_NAME" "$verdict" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  printf '%-7s %-28s %s\n' "$verdict" "$item" "$detail"
}

# A fix line is indented under its verdict so it reads as part of that item and
# can be copied straight out of the terminal.
fix() {
  printf '        %s %s\n' '->' "$*"
}

# ---------------------------------------------------------------------------
# The read-only gate
# ---------------------------------------------------------------------------
#
# Allowlisted, not denylisted. A denylist of dangerous verbs has to anticipate
# every future gcloud surface; an allowlist of the four inspection verbs this
# script legitimately uses does not, and it fails closed on anything new.
gcloud_ro() {
  local joined=" $* "
  case "$joined" in
    *' describe '* | *' list '* | *' version '*) ;;
    *)
      printf '%s: refusing to run a non-read-only gcloud call: gcloud %s\n' \
        "$SCRIPT_NAME" "$*" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  "$GCLOUD_BIN" "$@" 2>/dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_gcloud_present() {
  if have "$GCLOUD_BIN"; then
    report PASS "gcloud installed" "$(command -v "$GCLOUD_BIN")"
    return 0
  fi
  report FAIL "gcloud installed" "'$GCLOUD_BIN' is not on PATH"
  fix "install the Google Cloud SDK, then re-run this script"
  return 1
}

check_active_account() {
  local account
  account="$(gcloud_ro auth list --filter=status:ACTIVE --format='value(account)' || true)"
  if [ -z "$account" ]; then
    report FAIL "gcloud active account" "no account is active"
    fix "gcloud auth login <account>"
    return 1
  fi
  report PASS "gcloud active account" "$account"
  ACTIVE_ACCOUNT="$account"
  return 0
}

# The check that currently fails, and the reason this script exists. The active
# account cannot reach the project, and the error gcloud returns for that reads
# as "the project does not exist" -- so the obvious conclusion is that the
# project id is wrong, and the obvious fix is to go hunting for a different id.
# Naming the identity fix here is the entire value of the check.
check_project_reachable() {
  local project="$1" out other
  out="$(gcloud_ro projects describe "$project" --format='value(projectId)' || true)"
  if [ "$out" = "$project" ]; then
    report PASS "project reachable" "$project"
    return 0
  fi
  report FAIL "project reachable" \
    "account '${ACTIVE_ACCOUNT:-<none>}' cannot describe project '$project'"
  fix "gcloud auth login <account>          # an account with access to $project"
  fix "gcloud config set account <account>"
  fix "gcloud auth application-default login   # Terraform uses ADC, a SEPARATE grant"
  other="$(gcloud_ro auth list --format='value(account)' || true)"
  if [ -n "$other" ]; then
    printf '        %s %s\n' 'authenticated accounts on this machine:' \
      "$(printf '%s' "$other" | tr '\n' ' ')"
  fi
  return 1
}

# Returns 0 if every required API is enabled; reports UNKNOWN and returns 0 if
# the enabled set could not be read at all, because "I could not look" and
# "they are off" are different facts and only one of them is actionable.
check_apis() {
  local project="$1" enabled missing=() api
  local required=(
    compute.googleapis.com
    iap.googleapis.com
    iam.googleapis.com
    cloudresourcemanager.googleapis.com
    storage.googleapis.com
  )

  enabled="$(gcloud_ro services list --enabled --project "$project" \
    --format='value(config.name)' || true)"
  if [ -z "$enabled" ]; then
    report UNKNOWN "required APIs" "could not read the enabled service list"
    fix "usually the same cause as a failed 'project reachable' above"
    return 0
  fi

  for api in "${required[@]}"; do
    case $'\n'"$enabled"$'\n' in
      *$'\n'"$api"$'\n'*) ;;
      *) missing+=("$api") ;;
    esac
  done

  # Certificates and DNS are an either/or, not two requirements. A managed
  # certificate on the classic load balancer needs neither API when the
  # environment runs without a hostname, so demanding both would produce a FAIL
  # on a configuration that is entirely valid.
  local cert_ok="no"
  case $'\n'"$enabled"$'\n' in
    *$'\n'certificatemanager.googleapis.com$'\n'* | *$'\n'dns.googleapis.com$'\n'*) cert_ok="yes" ;;
  esac
  if [ "$cert_ok" = "no" ]; then
    missing+=(dns.googleapis.com)
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    report PASS "required APIs" "${#required[@]} required, all enabled"
    return 0
  fi

  report FAIL "required APIs" "not enabled: ${missing[*]}"
  fix "gcloud services enable ${missing[*]} --project $project"
  return 1
}

check_state_bucket() {
  local bucket="$1" out
  if [ -z "$bucket" ]; then
    report UNKNOWN "state bucket" "not supplied"
    fix "re-run with --bucket <name> once 'make gcp-tf-bootstrap' has been applied"
    return 0
  fi
  out="$(gcloud_ro storage buckets describe "gs://${bucket}" --format='value(name)' || true)"
  if [ -n "$out" ]; then
    report PASS "state bucket" "gs://${bucket} exists and is readable"
    return 0
  fi
  report FAIL "state bucket" "gs://${bucket} is missing or unreadable"
  fix "make gcp-tf-bootstrap    # then apply the reviewed plan by hand"
  return 1
}

check_terraform_version() {
  local raw version major minor
  if ! have "$TERRAFORM_BIN"; then
    report FAIL "terraform >= ${TF_MIN_MAJOR}.${TF_MIN_MINOR}" "'$TERRAFORM_BIN' is not on PATH"
    fix "install Terraform ${TF_MIN_MAJOR}.${TF_MIN_MINOR} or newer"
    return 1
  fi
  raw="$("$TERRAFORM_BIN" version 2>/dev/null | head -1 || true)"
  version="${raw#*v}"
  version="${version%% *}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  case "${major}${minor}" in
    *[!0-9]* | '')
      report UNKNOWN "terraform >= ${TF_MIN_MAJOR}.${TF_MIN_MINOR}" \
        "could not parse a version from '${raw}'"
      return 0
      ;;
  esac
  if [ "$major" -gt "$TF_MIN_MAJOR" ] ||
    { [ "$major" -eq "$TF_MIN_MAJOR" ] && [ "$minor" -ge "$TF_MIN_MINOR" ]; }; then
    report PASS "terraform >= ${TF_MIN_MAJOR}.${TF_MIN_MINOR}" "$version"
    return 0
  fi
  report FAIL "terraform >= ${TF_MIN_MAJOR}.${TF_MIN_MINOR}" "found $version"
  fix "upgrade Terraform; the roots pin required_version >= 1.9"
  return 1
}

check_dns_zone() {
  local project="$1" zone="$2" out
  if [ -z "$zone" ]; then
    report UNKNOWN "DNS managed zone" "none configured for this environment"
    fix "expected when dns_managed_zone = \"\"; the LB then has no name and no certificate"
    return 0
  fi
  out="$(gcloud_ro dns managed-zones describe "$zone" --project "$project" \
    --format='value(name)' || true)"
  if [ "$out" = "$zone" ]; then
    report PASS "DNS managed zone" "$zone"
    return 0
  fi
  report FAIL "DNS managed zone" "zone '$zone' not found in project '$project'"
  fix "check the zone NAME, not the domain: gcloud dns managed-zones list --project $project"
  return 1
}

check_billing() {
  local project="$1" out
  out="$(gcloud_ro billing projects describe "$project" \
    --format='value(billingEnabled)' || true)"
  case "$out" in
    True | true)
      report PASS "billing enabled" "$project"
      return 0
      ;;
    False | false)
      report FAIL "billing enabled" "no billing account is linked to '$project'"
      fix "link a billing account in the console; every resource below fails without it"
      return 1
      ;;
    *)
      # Needs cloudbilling API plus billing.resourceAssociations.list, which a
      # project-level role does not grant. Genuinely unknown, not off.
      report UNKNOWN "billing enabled" "could not read the billing association"
      fix "needs cloudbilling.googleapis.com and billing viewer rights"
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------

main() {
  local project="${PREFLIGHT_PROJECT:-}"
  local bucket="${PREFLIGHT_STATE_BUCKET:-}"
  local dns_zone="${PREFLIGHT_DNS_ZONE:-}"
  local env_key="demo-1"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        project="${2:-}"
        shift 2
        ;;
      --bucket)
        bucket="${2:-}"
        shift 2
        ;;
      --dns-zone)
        dns_zone="${2:-}"
        shift 2
        ;;
      --env)
        env_key="${2:-}"
        shift 2
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

  if [ -z "$project" ]; then
    printf '%s: --project is required.\n\n' "$SCRIPT_NAME" >&2
    usage >&2
    return "$EXIT_USAGE"
  fi

  printf '%s: read-only readiness check for ENV=%s in project %s\n' \
    "$SCRIPT_NAME" "$env_key" "$project"
  printf '%s: nothing below creates, modifies or deletes anything.\n\n' "$SCRIPT_NAME"

  # Every check runs. None short-circuits the rest, because a run that stops at
  # the first failure produces one finding per invocation, and the point of a
  # preflight is to hand over the whole list at once.
  local gcloud_ok="yes"
  check_gcloud_present || gcloud_ok="no"

  if [ "$gcloud_ok" = "yes" ]; then
    check_active_account || true
    check_project_reachable "$project" || true
    check_apis "$project" || true
    check_state_bucket "$bucket" || true
    check_dns_zone "$project" "$dns_zone" || true
    check_billing "$project" || true
  else
    report UNKNOWN "gcloud active account" "gcloud is not available"
    report UNKNOWN "project reachable" "gcloud is not available"
    report UNKNOWN "required APIs" "gcloud is not available"
    report UNKNOWN "state bucket" "gcloud is not available"
    report UNKNOWN "DNS managed zone" "gcloud is not available"
    report UNKNOWN "billing enabled" "gcloud is not available"
  fi

  check_terraform_version || true

  printf '\n%s: %d pass, %d fail, %d unknown\n' \
    "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s: NOT READY -- fix the FAIL lines above, then re-run.\n' "$SCRIPT_NAME" >&2
    return "$EXIT_FAILURES"
  fi
  if [ "$UNKNOWN_COUNT" -gt 0 ]; then
    printf '%s: no failures, but %d item(s) could not be checked. Read them before applying.\n' \
      "$SCRIPT_NAME" "$UNKNOWN_COUNT"
  fi
  return 0
}

main "$@"
