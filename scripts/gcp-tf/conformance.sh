#!/usr/bin/env bash
#
# conformance.sh -- ask the RUNNING cloud whether the posture actually landed.
#
# Everything else in this repo asserts on Terraform configuration: `terraform
# test` reads evaluated plan attributes, bats reads the tree. Both answer "is
# the config right?". Neither answers "is the estate right?", and those two
# diverge in exactly the ways that hurt --
#
#   * a firewall rule that exists in config and is shadowed by another in the
#     same network,
#   * an IAP IAM binding that applied to a different backend than the one the
#     forwarding rule points at,
#   * a bucket whose public-access-prevention was overridden by an org policy
#     after apply,
#   * a console change made at 19:00 on the evening of the demo.
#
# READ-ONLY BY CONSTRUCTION, on the same mechanism preflight.sh uses: every
# cloud call goes through gcloud_ro(), which refuses any verb outside a
# hardcoded allowlist. A conformance tool that can mutate the thing it is
# grading is a liability, so the guard is a mechanism rather than a promise.
#
# Three verdicts, and the difference between the last two is the whole point:
#
#   PASS      checked, and it is as required.
#   FAIL      checked, and it is NOT as required. The named threat is live.
#   UNKNOWN   could NOT be checked -- no permission, no resource, no jq.
#
# UNKNOWN is never downgraded to FAIL. "I could not read the IAP policy" and
# "the IAP policy names allAuthenticatedUsers" are different facts, and only one
# of them means the demo is open to the internet.
#
# NO gcloud --filter IS USED FOR ANY ABSENCE CHECK. A mistyped server-side
# filter returns an empty list, an empty list reads as "clean", and the report
# goes green on a question it never asked. Every list is fetched whole and
# filtered here, where the filter is visible and testable.
#
# Usage:
#   conformance.sh --project <id> --env <key> [--bucket <name>] [--strict]
#
# Exit codes:
#   0  no FAIL. UNKNOWNs may be present and are listed.
#   1  at least one FAIL.
#   2  usage error.
#   3  --strict, no FAIL, but at least one UNKNOWN.
#
# shellcheck disable=SC2016
# Every jq program below is single-quoted on purpose. $p, $vpc, $want and $iap
# are jq variables bound by --arg, not shell variables; letting the shell expand
# them would substitute the value into the program text and change what jq
# parses. File-level rather than eight identical inline directives.
set -Eeuo pipefail

readonly SCRIPT_NAME="conformance"
readonly EXIT_FAILURES=1
readonly EXIT_USAGE=2
readonly EXIT_STRICT_UNKNOWN=3

# Identity-Aware Proxy's TCP-forwarding range. This governs the VPC firewall for
# SSH tunnelling; it carries no web traffic through the load balancer.
readonly IAP_TCP_RANGE="35.235.240.0/20"

# The Compute API's synthetic priority for a security policy's default rule.
readonly ARMOR_DEFAULT_PRIORITY="2147483647"

# Binaries are injectable so the suite can put a stub on PATH and drive every
# branch below without a cloud account. A component that can only be exercised
# against the real system is a component nobody exercises.
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
JQ_BIN="${JQ_BIN:-jq}"

# gcloud shells out to ssh for IAP tunnels, and a loaded ssh-agent on this
# machine answers "agent refused operation" to calls it has no business
# handling. The failure then surfaces as a VM or network error, which is the
# wrong place to look entirely.
export SSH_AUTH_SOCK=""

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0

usage() {
  cat <<'USAGE'
Usage: conformance.sh --project <id> --env <key> [options]

Read-only conformance assertions against a LIVE Signal Loom environment.
Creates, modifies and deletes nothing. Safe to run repeatedly, safe to run
during a demo, safe to run when you are not sure the environment is up.

Required:
  --project <id>       GCP project id the environment is deployed into.
                       Also read from CONFORMANCE_PROJECT.
  --env <key>          Environment key, e.g. demo-1. Resources are named
                       sl-<key>-<role>; the key selects what is inspected.
                       Also read from CONFORMANCE_ENV.

Options:
  --bucket <name>      Terraform state bucket. Omitted means the bucket checks
                       report UNKNOWN rather than guessing a name.
                       Also read from CONFORMANCE_STATE_BUCKET.
  --strict             Exit 3 when there are no failures but something could
                       not be checked. Use in CI, where an unchecked control is
                       not the same as a checked one.
  -h, --help           Show this help.

Environment:
  GCLOUD_BIN           gcloud binary. Default: gcloud
  JQ_BIN               jq binary. Default: jq

Checks, and the terraform/SECURITY.md threat each one keeps closed:
  no external IP on any instance                   SECURITY.md #3
  OS Login on, project SSH keys blocked            SECURITY.md #3
  Shielded VM: secure boot, vTPM, integrity        SECURITY.md #3
  per-environment runtime service account          SECURITY.md #2
  no 0.0.0.0/0 ingress in the environment network  SECURITY.md #3
  SSH reachable only from the IAP range            SECURITY.md #3
  Cloud Armor attached, default rule denies        SECURITY.md #5
  IAP enabled on the backend service               SECURITY.md #5a
  IAP names a principal, and not allUsers /
    allAuthenticatedUsers                          SECURITY.md #5a
  state bucket versioning / UBLA / PAP enforced    SECURITY.md #1
  no user-managed service account key              SECURITY.md #2

Exit codes: 0 no FAIL, 1 one or more FAIL, 2 usage error, 3 --strict unknowns.
USAGE
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

report() {
  local verdict="$1" item="$2" threat="$3" detail="$4"
  case "$verdict" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    *)
      printf '%s: internal error: unknown verdict %s\n' "$SCRIPT_NAME" "$verdict" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  printf '%-7s %-34s [%s] %s\n' "$verdict" "$item" "$threat" "$detail"
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
# every future gcloud surface; an allowlist of the inspection verbs this script
# legitimately uses does not, and it fails closed on anything new.
gcloud_ro() {
  local joined=" $* "
  case "$joined" in
    *' describe '* | *' list '* | *' version '*) ;;
    # get-iam-policy reads a policy and writes nothing. It is spelled with a
    # verb of its own rather than 'describe', so an allowlist of describe/list
    # alone would refuse the single most important check in this file -- whether
    # IAP names allAuthenticatedUsers. Its mutating twin is set-iam-policy,
    # which is NOT here and will be refused.
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
# Instance posture -- one API call, four independent verdicts
# ---------------------------------------------------------------------------

check_instances() {
  local project="$1" prefix="$2"
  local raw scoped count offenders

  if ! raw="$(run_json compute instances list --project "$project")"; then
    report UNKNOWN "no external IP" "SECURITY.md #3" "could not list instances in ${project}"
    report UNKNOWN "OS Login enforced" "SECURITY.md #3" "could not list instances in ${project}"
    report UNKNOWN "Shielded VM" "SECURITY.md #3" "could not list instances in ${project}"
    report UNKNOWN "per-environment runtime SA" "SECURITY.md #2" "could not list instances in ${project}"
    fix "needs compute.instances.list; run scripts/gcp-tf/preflight.sh first"
    return 0
  fi

  # Client-side scoping, deliberately. The trailing hyphen matters: startswith
  # "sl-demo-1" also matches sl-demo-10-vm, which is a different environment.
  scoped="$(jqr "$raw" -c --arg p "${prefix}-" '[.[] | select(.name | startswith($p))]')" || scoped=""
  if [ -z "$scoped" ]; then
    report UNKNOWN "no external IP" "SECURITY.md #3" "instance list could not be parsed"
    report UNKNOWN "OS Login enforced" "SECURITY.md #3" "instance list could not be parsed"
    report UNKNOWN "Shielded VM" "SECURITY.md #3" "instance list could not be parsed"
    report UNKNOWN "per-environment runtime SA" "SECURITY.md #2" "instance list could not be parsed"
    return 0
  fi

  count="$(jqr "$scoped" 'length')" || count=0
  if [ "$count" -eq 0 ]; then
    # Not a pass. Nothing was inspected, so nothing was proved.
    report UNKNOWN "no external IP" "SECURITY.md #3" "no instance named ${prefix}-* exists"
    report UNKNOWN "OS Login enforced" "SECURITY.md #3" "no instance named ${prefix}-* exists"
    report UNKNOWN "Shielded VM" "SECURITY.md #3" "no instance named ${prefix}-* exists"
    report UNKNOWN "per-environment runtime SA" "SECURITY.md #2" "no instance named ${prefix}-* exists"
    fix "the environment is not deployed, or --env does not match what was applied"
    return 0
  fi

  # 1. External IP. An accessConfigs entry on any interface is an external
  #    address, which routes around the load balancer and Cloud Armor together.
  offenders="$(jqr "$scoped" -r '
    [ .[] | select( ([ .networkInterfaces[]? .accessConfigs[]? ] | length) > 0 ) | .name ] | join(", ")')" || offenders=""
  if [ -n "$offenders" ]; then
    report FAIL "no external IP" "SECURITY.md #3" "external address on: ${offenders}"
    fix "an access_config was added, or the VM was edited in the console; remove it"
  else
    report PASS "no external IP" "SECURITY.md #3" "${count} instance(s), no accessConfigs"
  fi

  # 2. OS Login and project-key blocking. Both, because either alone leaves a
  #    path: OS Login off means metadata keys authorise SSH, and project keys
  #    unblocked means a key pasted at project level authorises SSH here.
  offenders="$(jqr "$scoped" -r '
    def meta($k): ( [ .metadata.items[]? | select(.key == $k) | .value ] | first ) // "";
    [ .[]
      | . as $i
      | ( (meta("enable-oslogin")         | ascii_upcase) as $os
        | (meta("block-project-ssh-keys") | ascii_upcase) as $bk
        | if $os == "TRUE" and $bk == "TRUE" then empty
          else "\($i.name)(enable-oslogin=\($os // "unset"),block-project-ssh-keys=\($bk // "unset"))"
          end )
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "OS Login enforced" "SECURITY.md #3" "instance metadata could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "OS Login enforced" "SECURITY.md #3" "$offenders"
    fix "SSH authorisation is not going through IAM on these instances"
  else
    report PASS "OS Login enforced" "SECURITY.md #3" "${count} instance(s), OS Login on, project keys blocked"
  fi

  # 3. Shielded VM. All three, reported by name -- "shielded: false" tells you
  #    nothing about which of the three knobs someone turned off.
  offenders="$(jqr "$scoped" -r '
    [ .[]
      | . as $i
      | ( .shieldedInstanceConfig // {} ) as $s
      | [ (if ($s.enableSecureBoot // false)         then empty else "secureBoot"         end),
          (if ($s.enableVtpm // false)               then empty else "vtpm"               end),
          (if ($s.enableIntegrityMonitoring // false) then empty else "integrityMonitoring" end) ] as $bad
      | if ($bad | length) == 0 then empty else "\($i.name)(off: \($bad | join("+")))" end
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "Shielded VM" "SECURITY.md #3" "shieldedInstanceConfig could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "Shielded VM" "SECURITY.md #3" "$offenders"
    fix "boot integrity is not enforced; a tampered boot chain would not be detected"
  else
    report PASS "Shielded VM" "SECURITY.md #3" "${count} instance(s), secure boot + vTPM + integrity on"
  fi

  # 4. Runtime service account. The default compute SA is the finding worth
  #    naming: it is project-wide, it is shared by every instance that forgot to
  #    ask for something else, and it carries Editor on a default project.
  local expect_sa="sl-rt-${prefix#sl-}@${project}.iam.gserviceaccount.com"
  offenders="$(jqr "$scoped" -r --arg want "$expect_sa" '
    [ .[]
      | . as $i
      | ( [ .serviceAccounts[]? .email ] | first ) // "" as $e
      | if $e == $want then empty
        elif ($e | test("-compute@developer\\.gserviceaccount\\.com$")) then "\($i.name)=DEFAULT-COMPUTE-SA(\($e))"
        elif $e == "" then "\($i.name)=none"
        else "\($i.name)=\($e)"
        end
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "per-environment runtime SA" "SECURITY.md #2" "serviceAccounts could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "per-environment runtime SA" "SECURITY.md #2" "$offenders"
    fix "expected ${expect_sa}"
  else
    report PASS "per-environment runtime SA" "SECURITY.md #2" "$expect_sa"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Firewall posture
# ---------------------------------------------------------------------------

check_firewall() {
  local project="$1" prefix="$2"
  local raw scoped count offenders vpc="${prefix}-vpc"

  if ! raw="$(run_json compute firewall-rules list --project "$project")"; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "SECURITY.md #3" "could not list firewall rules in ${project}"
    report UNKNOWN "SSH only from IAP range" "SECURITY.md #3" "could not list firewall rules in ${project}"
    return 0
  fi

  # Scoped by the network the rule attaches to, not by the rule's own name. A
  # rule called anything at all still applies to every instance in the VPC, so
  # name-scoping here would miss precisely the rule someone added by hand.
  scoped="$(jqr "$raw" -c --arg vpc "$vpc" '
    [ .[] | select((.network // "") | endswith("/" + $vpc)) ]')" || scoped=""
  if [ -z "$scoped" ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "SECURITY.md #3" "firewall list could not be parsed"
    report UNKNOWN "SSH only from IAP range" "SECURITY.md #3" "firewall list could not be parsed"
    return 0
  fi

  count="$(jqr "$scoped" 'length')" || count=0
  if [ "$count" -eq 0 ]; then
    report UNKNOWN "no 0.0.0.0/0 ingress" "SECURITY.md #3" "no rule attaches to network ${vpc}"
    report UNKNOWN "SSH only from IAP range" "SECURITY.md #3" "no rule attaches to network ${vpc}"
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
    report UNKNOWN "no 0.0.0.0/0 ingress" "SECURITY.md #3" "sourceRanges could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "no 0.0.0.0/0 ingress" "SECURITY.md #3" "world-open allow rule(s): ${offenders}"
    fix "these admit the whole internet to ${vpc} regardless of what Cloud Armor says"
  else
    report PASS "no 0.0.0.0/0 ingress" "SECURITY.md #3" "${count} rule(s) on ${vpc}, none world-open"
  fi

  # 2. SSH exposure. A rule with protocol tcp and NO ports named permits every
  #    tcp port, so it permits 22 -- that case is the one a naive "does any rule
  #    list port 22" check walks straight past.
  local ssh_rules
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
    report UNKNOWN "SSH only from IAP range" "SECURITY.md #3" "allowed[] could not be read"
    return 0
  fi

  local ssh_count
  ssh_count="$(jqr "$ssh_rules" 'length')" || ssh_count=0
  if [ "$ssh_count" -eq 0 ]; then
    report PASS "SSH only from IAP range" "SECURITY.md #3" "no enabled ingress rule on ${vpc} permits tcp/22"
    return 0
  fi

  offenders="$(jqr "$ssh_rules" -r --arg iap "$IAP_TCP_RANGE" '
    [ .[]
      | select( [ .sourceRanges[]? ] | any(. != $iap) or (length == 0) )
      | "\(.name)[\( [ .sourceRanges[]? ] | join(" ") )]"
    ] | join(", ")')" || offenders="__unparseable__"
  if [ "$offenders" = "__unparseable__" ]; then
    report UNKNOWN "SSH only from IAP range" "SECURITY.md #3" "sourceRanges could not be read"
  elif [ -n "$offenders" ]; then
    report FAIL "SSH only from IAP range" "SECURITY.md #3" "tcp/22 from outside ${IAP_TCP_RANGE}: ${offenders}"
    fix "SSH should arrive only through Identity-Aware Proxy TCP forwarding"
  else
    report PASS "SSH only from IAP range" "SECURITY.md #3" "${ssh_count} tcp/22 rule(s), source ${IAP_TCP_RANGE} only"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The edge -- IAP and Cloud Armor. One backend service fetch, three verdicts.
# ---------------------------------------------------------------------------
#
# The Armor policy is read from the backend service's securityPolicy field
# rather than from a name this script guessed. A policy that exists and denies
# by default protects nothing if it is not the one attached to the backend the
# forwarding rule points at, and a name-guessing check cannot see that.
check_edge() {
  local project="$1" prefix="$2"
  local backend="${prefix}-backend"
  local bs iap_enabled policy_url policy_name

  if ! bs="$(run_json compute backend-services describe "$backend" --global --project "$project")"; then
    report UNKNOWN "IAP enabled on backend" "SECURITY.md #5a" "could not describe backend service ${backend}"
    report UNKNOWN "IAP principals" "SECURITY.md #5a" "could not describe backend service ${backend}"
    report UNKNOWN "Cloud Armor default denies" "SECURITY.md #5" "could not describe backend service ${backend}"
    fix "the environment may not be deployed; check --env and --project"
    return 0
  fi

  # 1. IAP enabled.
  iap_enabled="$(jqr "$bs" -r '(.iap.enabled // false) | tostring')" || iap_enabled="unknown"
  case "$iap_enabled" in
    true)
      report PASS "IAP enabled on backend" "SECURITY.md #5a" "$backend"
      ;;
    false)
      local has_iap
      has_iap="$(jqr "$bs" -r 'if (.iap // null) == null then "absent" else "present-but-disabled" end')" || has_iap="absent"
      report FAIL "IAP enabled on backend" "SECURITY.md #5a" "${backend}: iap ${has_iap}"
      fix "every request reaches the backend unauthenticated; access_mode is not 'iap'"
      ;;
    *)
      report UNKNOWN "IAP enabled on backend" "SECURITY.md #5a" "iap block could not be read"
      ;;
  esac

  # 2. The IAP IAM policy. THIS is the control that makes the demo "not publicly
  #    accessible", so it gets the loudest failure in the file.
  #
  #    allAuthenticatedUsers is the value that reads as a restriction and is not.
  #    In IAP it means any Google account on earth -- every Gmail address, every
  #    Workspace tenant. It is functionally public access wearing the vocabulary
  #    of access control, and it is more dangerous than allUsers precisely
  #    because allUsers is honest about what it does.
  local pol members wildcards member_count
  if ! pol="$(run_json iap web get-iam-policy --project "$project" \
    --resource-type=backend-services --service="$backend")"; then
    report UNKNOWN "IAP principals" "SECURITY.md #5a" "could not read the IAP IAM policy for ${backend}"
    fix "needs iap.webServiceVersions.getIamPolicy on the backend service"
  else
    members="$(jqr "$pol" -c '
      [ .bindings[]? | select(.role == "roles/iap.httpsResourceAccessor") | .members[]? ]')" || members=""
    if [ -z "$members" ]; then
      report UNKNOWN "IAP principals" "SECURITY.md #5a" "IAP IAM bindings could not be parsed"
    else
      wildcards="$(jqr "$members" -r '
        [ .[] | select(. == "allUsers" or . == "allAuthenticatedUsers") ] | join(", ")')" || wildcards=""
      member_count="$(jqr "$members" 'length')" || member_count=0
      if [ -n "$wildcards" ]; then
        report FAIL "IAP principals" "SECURITY.md #5a" \
          "roles/iap.httpsResourceAccessor granted to ${wildcards} on ${backend} -- THE DEMO IS PUBLIC"
        fix "allAuthenticatedUsers means ANY Google account on earth. It is not a restriction."
        fix "remove the binding, then re-run; iap_members must name real principals"
      elif [ "$member_count" -eq 0 ]; then
        report FAIL "IAP principals" "SECURITY.md #5a" \
          "IAP is enabled on ${backend} but no principal holds roles/iap.httpsResourceAccessor"
        fix "a locked door with no key: nobody, including you, can reach the demo"
      else
        report PASS "IAP principals" "SECURITY.md #5a" \
          "${member_count} named principal(s), no allUsers / allAuthenticatedUsers"
      fi
    fi
  fi

  # 3. Cloud Armor, resolved from the backend rather than guessed.
  policy_url="$(jqr "$bs" -r '.securityPolicy // ""')" || policy_url=""
  if [ -z "$policy_url" ]; then
    report FAIL "Cloud Armor default denies" "SECURITY.md #5" "no security policy is attached to ${backend}"
    fix "Cloud Armor is not in the request path at all; rate limiting and WAF rules do nothing"
    return 0
  fi
  policy_name="${policy_url##*/}"

  local sp default_action default_preview
  if ! sp="$(run_json compute security-policies describe "$policy_name" --project "$project")"; then
    report UNKNOWN "Cloud Armor default denies" "SECURITY.md #5" "could not describe policy ${policy_name}"
    return 0
  fi

  default_action="$(jqr "$sp" -r --arg p "$ARMOR_DEFAULT_PRIORITY" '
    ([ .rules[]? | select((.priority | tostring) == $p) ] | first | .action) // ""')" || default_action="__unparseable__"
  default_preview="$(jqr "$sp" -r --arg p "$ARMOR_DEFAULT_PRIORITY" '
    ([ .rules[]? | select((.priority | tostring) == $p) ] | first | .preview // false) | tostring')" || default_preview="false"

  if [ "$default_action" = "__unparseable__" ]; then
    report UNKNOWN "Cloud Armor default denies" "SECURITY.md #5" "rules[] could not be read on ${policy_name}"
  elif [ -z "$default_action" ]; then
    report FAIL "Cloud Armor default denies" "SECURITY.md #5" "${policy_name} has no default rule at priority ${ARMOR_DEFAULT_PRIORITY}"
    fix "without a default rule the policy is allow-by-default"
  elif [ "$default_preview" = "true" ]; then
    # A denying rule in preview logs the request and serves it. The report reads
    # 'deny' and the behaviour is 'allow'.
    report FAIL "Cloud Armor default denies" "SECURITY.md #5" \
      "${policy_name} default rule is ${default_action} but preview=true -- it is NOT enforced"
    fix "preview mode logs the decision and serves the request anyway"
  else
    case "$default_action" in
      deny*)
        report PASS "Cloud Armor default denies" "SECURITY.md #5" "${policy_name} default=${default_action}"
        ;;
      *)
        report FAIL "Cloud Armor default denies" "SECURITY.md #5" \
          "${policy_name} default rule action is '${default_action}' -- the policy is allow-by-default"
        fix "the allowlist is then decoration: anything not explicitly denied is served"
        ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
# State bucket
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
    report UNKNOWN "state bucket protection" "SECURITY.md #1" "--bucket not supplied"
    fix "re-run with --bucket <name> from 'make gcp-tf-bootstrap'"
    return 0
  fi

  local b versioning ubla pap bad=()
  if ! b="$(run_json storage buckets describe "gs://${bucket}")"; then
    report UNKNOWN "state bucket protection" "SECURITY.md #1" "gs://${bucket} could not be described"
    return 0
  fi

  versioning="$(jqr "$b" -r '(.versioning_enabled // .versioning.enabled // false) | tostring')" || versioning="unknown"
  ubla="$(jqr "$b" -r '(.uniform_bucket_level_access // .iamConfiguration.uniformBucketLevelAccess.enabled // false) | tostring')" || ubla="unknown"
  pap="$(jqr "$b" -r '(.public_access_prevention // .iamConfiguration.publicAccessPrevention // "") | tostring')" || pap="unknown"

  [ "$versioning" = "true" ] || bad+=("versioning=${versioning}")
  [ "$ubla" = "true" ] || bad+=("uniform_bucket_level_access=${ubla}")
  [ "$pap" = "enforced" ] || bad+=("public_access_prevention=${pap:-unset}")

  if [ "${#bad[@]}" -eq 0 ]; then
    report PASS "state bucket protection" "SECURITY.md #1" "gs://${bucket}: versioning, UBLA, PAP enforced"
  else
    report FAIL "state bucket protection" "SECURITY.md #1" "gs://${bucket}: ${bad[*]}"
    fix "state holds resource ids and IAM member lists; an exposed or unversioned bucket is the whole estate"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Service account keys
# ---------------------------------------------------------------------------
#
# Only user-managed keys are a finding. Every service account also carries
# Google-managed keys that are rotated by Google and cannot be exported; counting
# those would report a permanent FAIL on a perfectly clean project, and a check
# that always fails stops being read.
check_sa_keys() {
  local project="$1"
  local raw emails email keys found=() unreadable=0

  if ! raw="$(run_json iam service-accounts list --project "$project")"; then
    report UNKNOWN "no service account keys" "SECURITY.md #2" "could not list service accounts in ${project}"
    return 0
  fi
  emails="$(jqr "$raw" -r '[ .[] .email ] | .[]')" || {
    report UNKNOWN "no service account keys" "SECURITY.md #2" "service account list could not be parsed"
    return 0
  }
  if [ -z "$emails" ]; then
    report PASS "no service account keys" "SECURITY.md #2" "no service accounts in ${project}"
    return 0
  fi

  while IFS= read -r email; do
    [ -n "$email" ] || continue
    if ! keys="$(run_json iam service-accounts keys list \
      --iam-account="$email" --managed-by=user --project "$project")"; then
      unreadable=$((unreadable + 1))
      continue
    fi
    local n
    n="$(jqr "$keys" 'length')" || n=0
    [ "$n" -gt 0 ] && found+=("${email}(${n})")
  done <<<"$emails"

  if [ "${#found[@]}" -gt 0 ]; then
    report FAIL "no service account keys" "SECURITY.md #2" "user-managed key(s) on: ${found[*]}"
    fix "CI authenticates by Workload Identity Federation; a downloadable key is a credential that outlives its owner"
  elif [ "$unreadable" -gt 0 ]; then
    report UNKNOWN "no service account keys" "SECURITY.md #2" "${unreadable} service account(s) could not be read"
    fix "needs iam.serviceAccountKeys.list"
  else
    report PASS "no service account keys" "SECURITY.md #2" "no user-managed keys on any service account"
  fi
  return 0
}

# ---------------------------------------------------------------------------

main() {
  local project="${CONFORMANCE_PROJECT:-}"
  local env_key="${CONFORMANCE_ENV:-}"
  local bucket="${CONFORMANCE_STATE_BUCKET:-}"
  local strict="false"

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

  local prefix="sl-${env_key}"

  printf '%s: read-only conformance for ENV=%s (resources named %s-*) in project %s\n' \
    "$SCRIPT_NAME" "$env_key" "$prefix" "$project"
  printf '%s: nothing below creates, modifies or deletes anything.\n\n' "$SCRIPT_NAME"

  if ! have "$GCLOUD_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; nothing can be checked.\n' "$SCRIPT_NAME" "$GCLOUD_BIN" >&2
    return "$EXIT_USAGE"
  fi
  if ! have "$JQ_BIN"; then
    printf '%s: '\''%s'\'' is not on PATH; every check would be UNKNOWN.\n' "$SCRIPT_NAME" "$JQ_BIN" >&2
    return "$EXIT_USAGE"
  fi

  # Every check runs. None short-circuits the rest: a report that stops at the
  # first failure produces one finding per invocation, and the point of a
  # conformance run is to hand over the whole posture at once.
  check_instances "$project" "$prefix" || true
  check_firewall "$project" "$prefix" || true
  check_edge "$project" "$prefix" || true
  check_state_bucket "$bucket" || true
  check_sa_keys "$project" || true

  printf '\n%s: %d pass, %d fail, %d unknown\n' \
    "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    printf '%s: NOT CONFORMANT -- each FAIL above names the threat it re-opens.\n' "$SCRIPT_NAME" >&2
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

# Guarded so the suite can source this file and drive gcloud_ro() directly. A
# read-only gate nobody can call in isolation is a gate nobody tests.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
