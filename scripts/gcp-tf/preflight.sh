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
    # print-access-token mints a token from credentials that already exist on
    # this machine. It creates no cloud resource and changes no cloud state, so
    # it belongs on the read side of this guard -- and it is the only way to ask
    # who ADC actually is, which is the question that matters most here because
    # Terraform authenticates with ADC and not with the CLI login.
    *' auth application-default print-access-token '*) ;;
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

# Terraform does NOT use the gcloud CLI login. It uses Application Default
# Credentials, which are a SEPARATE grant stored in a separate file, and the two
# routinely disagree: `gcloud auth login` does not refresh ADC, and ADC survives
# unchanged when you switch CLI accounts.
#
# This check exists because that disagreement is invisible until apply time and
# then presents as a permission error against the project, which reads as an IAM
# problem and is an identity problem. Observed on this machine: CLI was
# sublimino@gmail.com with full access while ADC was a months-old grant for a
# different account that could not see the project at all.
#
# The quota project is reported too. ADC attributes API calls to it, so a quota
# project pointing somewhere else produces "API not enabled" errors naming a
# project you are not deploying to.
check_adc() {
  local project="$1" token email adc_file quota
  adc_file="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"

  if [ ! -f "$adc_file" ]; then
    report FAIL "ADC present" "no application default credentials"
    fix "gcloud auth application-default login   # SEPARATE from 'gcloud auth login'"
    return 1
  fi

  token="$(gcloud_ro auth application-default print-access-token || true)"
  if [ -z "$token" ]; then
    report FAIL "ADC usable" "credentials exist but no token could be minted"
    fix "gcloud auth application-default login"
    return 1
  fi

  email="$(curl -s --max-time 15 "https://www.googleapis.com/oauth2/v1/userinfo?access_token=${token}" 2>/dev/null |
    sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$email" ]; then
    report UNKNOWN "ADC identity" "token minted but the identity could not be resolved"
    return 0
  fi

  if [ -n "${ACTIVE_ACCOUNT:-}" ] && [ "$email" != "$ACTIVE_ACCOUNT" ]; then
    report FAIL "ADC identity" "ADC is '${email}' but the CLI is '${ACTIVE_ACCOUNT}' -- Terraform will use ADC"
    fix "gcloud auth application-default login   # then pick ${ACTIVE_ACCOUNT}"
    return 1
  fi
  report PASS "ADC identity" "$email"

  # Reachability under ADC specifically. The CLI check above proves nothing
  # about this: they are different credentials.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${project}" 2>/dev/null)"
  case "$code" in
  200) report PASS "ADC reaches project" "$project" ;;
  403 | 404)
    report FAIL "ADC reaches project" "ADC identity cannot access '${project}' (HTTP ${code})"
    fix "gcloud auth application-default login   # with an account that can reach ${project}"
    return 1
    ;;
  *) report UNKNOWN "ADC reaches project" "unexpected HTTP ${code} from cloudresourcemanager" ;;
  esac

  quota="$(sed -n 's/.*"quota_project_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$adc_file" | head -1)"
  if [ -n "$quota" ] && [ "$quota" != "$project" ]; then
    report UNKNOWN "ADC quota project" "'${quota}' is not '${project}'; API calls bill and quota there"
    fix "gcloud auth application-default set-quota-project ${project}"
  elif [ -n "$quota" ]; then
    report PASS "ADC quota project" "$quota"
  fi
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

# ---------------------------------------------------------------------------
# Quota headroom
# ---------------------------------------------------------------------------
#
# This check exists because the estate hit two quota ceilings in one afternoon
# and both of them failed in the worst possible place: MID-APPLY.
#
# On 2026-08-20 `make gcp-tf-up ENV=demo-2` ran for several minutes, created a
# VPC, a subnet, a router, a Cloud NAT, a DNS zone and all nine firewall rules,
# and then failed on `CPUS_ALL_REGIONS exceeded. Limit: 32.0`. What it left
# behind was a half-built lane -- resources in state, no instance -- which reads
# as a broken apply rather than as a ceiling that was always going to be hit.
# The information needed to refuse in one second was available before the first
# resource was created. Nobody asked for it.
#
# The second ceiling was subtler and would have cost a SECOND failed rebuild:
# `pd-balanced` boot disks bill against the regional SSD_TOTAL_GB quota, not
# against DISKS_TOTAL_GB. DISKS_TOTAL_GB sat at 32/4096 and looked reassuring
# while SSD_TOTAL_GB was at 400/500 and was the thing that actually binds.
# Checking the wrong metric is worse than checking nothing, so this names both.
#
# ─── Two facts that are not guessable and were established by experiment ────
#
#   * A SUSPENDED instance RELEASES its CPU quota. Measured: suspending one
#     n2-standard-8 moved CPUS_ALL_REGIONS usage from 32.0 to 24.0.
#   * A SUSPENDED instance KEEPS its disk, and therefore keeps its SSD quota.
#     Only a destroy frees that.
#
# So "suspend something" is a real remedy for a CPU ceiling and is NO remedY at
# all for a disk ceiling. Those two sentences are the reason this check reports
# the two metrics separately with different fix lines, rather than collapsing
# them into one "insufficient quota" verdict that would send an operator to
# suspend a lane and watch it not help.
#
# ─── Why "at exactly the limit" is reported rather than passed silently ─────
#
# COMPUTE-RULE-01-MACHINE-TYPE-VCPU floors machine_type at 8 vCPU, so four
# lanes cost at least 32 vCPU and the project's CPUS_ALL_REGIONS limit is 32.
# The floor and the ceiling are the same number: there is no four-lane
# configuration with CPU headroom, and no tfvars edit can create one. That is a
# property an operator needs told, because at exactly 32/32 a rolling replace, a
# resize, or any operation that transiently runs N+1 instances fails -- and it
# fails with the same message as genuine exhaustion.
check_quota_headroom() {
  local project="$1" region="$2" machine_type="$3" disk_gb="$4"
  local vcpus quotas cpu_usage cpu_limit ssd_usage ssd_limit rc=0

  # Derived with the SAME regex COMPUTE-RULE-01 uses, so a type this check
  # measures is a type that module accepts. A non-matching name yields empty
  # and is reported UNKNOWN rather than assumed to be zero -- a machine type
  # this script cannot parse is one it must not vouch for.
  vcpus="$(printf '%s' "$machine_type" \
    | sed -nE 's/^[a-z0-9]+-(standard|highmem|highcpu|custom)-([0-9]+)([-].*)?$/\2/p')"
  if [ -z "$vcpus" ]; then
    report UNKNOWN "quota: vCPU headroom" "cannot derive vCPU count from machine_type '${machine_type}'"
    fix "custom types carry no parseable vCPU count here; check quota by hand before applying"
    return 0
  fi

  # CPUS_ALL_REGIONS is a PROJECT-level quota and lives on project-info, not on
  # the region. Reading the regional CPUS metric instead is the mistake this
  # comment exists to prevent: regional CPUS was 0/200 and N2_CPUS 32/200 while
  # the global cap was the thing refusing the apply.
  quotas="$(gcloud_ro compute project-info describe --project "$project" --format=json || true)"
  if [ -z "$quotas" ]; then
    report UNKNOWN "quota: vCPU headroom" "could not read project quotas for '${project}'"
    fix "needs compute.projects.get; the apply may still succeed, this check simply could not look"
  else
    cpu_usage="$(printf '%s' "$quotas" | jq -r '.quotas[]? | select(.metric=="CPUS_ALL_REGIONS") | .usage' 2>/dev/null || true)"
    cpu_limit="$(printf '%s' "$quotas" | jq -r '.quotas[]? | select(.metric=="CPUS_ALL_REGIONS") | .limit' 2>/dev/null || true)"
    if [ -z "$cpu_usage" ] || [ -z "$cpu_limit" ]; then
      report UNKNOWN "quota: vCPU headroom" "CPUS_ALL_REGIONS absent from the quota list"
    else
      local cpu_free
      cpu_free="$(awk "BEGIN{print ${cpu_limit} - ${cpu_usage}}")"
      if awk "BEGIN{exit !(${cpu_free} < ${vcpus})}"; then
        report FAIL "quota: vCPU headroom" \
          "need ${vcpus}, have ${cpu_free} free (CPUS_ALL_REGIONS ${cpu_usage}/${cpu_limit})"
        fix "SUSPEND an idle lane to free CPU (measured: suspend releases CPU quota), or destroy one"
        fix "gcloud compute instances suspend <name> --zone ${region}-a --project ${project}"
        rc=1
      elif awk "BEGIN{exit !(${cpu_free} == ${vcpus})}"; then
        report PASS "quota: vCPU headroom" \
          "need ${vcpus}, have ${cpu_free} free -- EXACTLY enough, zero spare (${cpu_usage}/${cpu_limit})"
        fix "this apply fits, but no resize or rolling replace will: those need N+1 instances briefly"
      else
        report PASS "quota: vCPU headroom" \
          "need ${vcpus}, have ${cpu_free} free (CPUS_ALL_REGIONS ${cpu_usage}/${cpu_limit})"
      fi
    fi
  fi

  # SSD_TOTAL_GB is REGIONAL and is what pd-balanced bills against. Checking
  # DISKS_TOTAL_GB here would report healthy while the apply fails.
  local rquotas
  rquotas="$(gcloud_ro compute regions describe "$region" --project "$project" --format=json || true)"
  if [ -z "$rquotas" ]; then
    report UNKNOWN "quota: SSD headroom" "could not read regional quotas for '${region}'"
    return "$rc"
  fi
  ssd_usage="$(printf '%s' "$rquotas" | jq -r '.quotas[]? | select(.metric=="SSD_TOTAL_GB") | .usage' 2>/dev/null || true)"
  ssd_limit="$(printf '%s' "$rquotas" | jq -r '.quotas[]? | select(.metric=="SSD_TOTAL_GB") | .limit' 2>/dev/null || true)"
  if [ -z "$ssd_usage" ] || [ -z "$ssd_limit" ]; then
    report UNKNOWN "quota: SSD headroom" "SSD_TOTAL_GB absent from ${region}'s quota list"
    return "$rc"
  fi
  local ssd_free
  ssd_free="$(awk "BEGIN{print ${ssd_limit} - ${ssd_usage}}")"
  if awk "BEGIN{exit !(${ssd_free} < ${disk_gb})}"; then
    report FAIL "quota: SSD headroom" \
      "need ${disk_gb}GB, have ${ssd_free}GB free (SSD_TOTAL_GB ${ssd_usage}/${ssd_limit} in ${region})"
    fix "pd-balanced bills against SSD_TOTAL_GB, NOT DISKS_TOTAL_GB -- do not be reassured by the latter"
    fix "SUSPENDING a lane does NOT help: a suspended instance keeps its disk. Only destroy frees this."
    rc=1
  else
    report PASS "quota: SSD headroom" \
      "need ${disk_gb}GB, have ${ssd_free}GB free (SSD_TOTAL_GB ${ssd_usage}/${ssd_limit} in ${region})"
  fi
  return "$rc"
}

main() {
  local project="${PREFLIGHT_PROJECT:-}"
  local bucket="${PREFLIGHT_STATE_BUCKET:-}"
  local dns_zone="${PREFLIGHT_DNS_ZONE:-}"
  local env_key="demo-1"
  local region="${PREFLIGHT_REGION:-us-east4}"
  local machine_type="${PREFLIGHT_MACHINE_TYPE:-n2-standard-8}"
  local disk_gb="${PREFLIGHT_DISK_GB:-100}"

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
      --region)
        region="${2:-}"
        shift 2
        ;;
      --machine-type)
        machine_type="${2:-}"
        shift 2
        ;;
      --disk-gb)
        disk_gb="${2:-}"
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
    check_adc "$project" || true
    check_state_bucket "$bucket" || true
    check_dns_zone "$project" "$dns_zone" || true
    check_billing "$project" || true
    check_quota_headroom "$project" "$region" "$machine_type" "$disk_gb" || true
  else
    report UNKNOWN "gcloud active account" "gcloud is not available"
    report UNKNOWN "project reachable" "gcloud is not available"
    report UNKNOWN "required APIs" "gcloud is not available"
    report UNKNOWN "state bucket" "gcloud is not available"
    report UNKNOWN "DNS managed zone" "gcloud is not available"
    report UNKNOWN "billing enabled" "gcloud is not available"
    report UNKNOWN "quota: vCPU headroom" "gcloud is not available"
    report UNKNOWN "quota: SSD headroom" "gcloud is not available"
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
