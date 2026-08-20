#!/usr/bin/env bash
#
# preserve-check.sh -- prove the unrecoverable things survived a destroy.
#
# `make gcp-tf-destroy` refuses to target the platform or bootstrap roots, and
# the state bucket, the audit bucket and the Tailscale auth key all live outside
# the environments root's state. That is a real protection and it is entirely
# INDIRECT: it argues that the destroy cannot reach them. Nothing anywhere
# afterwards ASSERTS that it did not. "The design means it cannot happen" and
# "we looked, and it did not happen" are different claims, and this repo has a
# long history of the gap between them mattering.
#
# So this script looks. Run it BEFORE a destroy to record the world, and AFTER
# to prove the world is still there.
#
# WHAT IS BEING PROTECTED, and why each is worth a script:
#
#   * gs://<project>-osramp-tfstate -- the Terraform state for EVERY root,
#     including platform and bootstrap. Destroying it orphans the whole estate
#     with no way to reconcile: the resources keep existing and billing, and
#     nothing left on disk knows their identifiers.
#   * gs://<project>-signalloom-audit -- the audit log bucket, deliberately in
#     a different bucket from the state it describes. Co-locating them means one
#     deletion takes both the record and the evidence of the deletion.
#   * the Tailscale bootstrap auth key -- created out of band (see
#     terraform/modules/compute/main.tf: it is a `data` source, never a
#     resource). Losing it means re-minting a key by hand in the Tailscale
#     console, which blocks every rebuild until a human is at a browser.
#
# CAPTURE THEN COMPARE, NOT HARDCODED EXPECTATIONS. A guard that asserts
# today's inventory is a guard that goes stale the first time a second
# environment is added, and a stale guard gets disabled rather than fixed.
# `--capture` writes a manifest of what is there; the default mode reads that
# manifest back and reports anything that regressed against it. Accepting an
# intentional change is a re-capture, which is a deliberate act with a diff.
#
# HOLLOW RESOURCES ARE THE WHOLE POINT. Every check here guards CONTENT, not
# names, because the dangerous shapes all pass an existence check:
#
#   * a state bucket that still exists and has been emptied of objects
#   * a secret that still exists and whose only version has been destroyed or
#     disabled
#   * a service account that still exists and has been disabled
#
# Each of those is a live outage that `gcloud ... describe` returns 0 for.
#
# READ-ONLY BY CONSTRUCTION. Every cloud call goes through gcloud_ro(), which
# allowlists the four inspection verbs and refuses anything else. This machine
# has working gcloud credentials and this script exists to be run either side of
# a real destroy, so a preservation guard that could itself mutate the estate
# would be the single worst tool in the repo.
#
# NO SECRET MATERIAL IS EVER READ OR WRITTEN. `gcloud secrets versions access`
# is not on the allowlist and is not called. The manifest records version counts
# and enabled/disabled states -- never a payload, never a length that could
# narrow one.
#
# NO gcloud --filter IS USED FOR ANY COUNTING OR ABSENCE CHECK. A mistyped
# server-side filter returns an empty list, an empty list reads as "nothing
# wrong", and the report goes green on a question it never asked. Every list is
# fetched whole and filtered here, in jq, where the filter is visible and the
# suite can turn it red.
#
# Usage:
#   preserve-check.sh --capture --project <id> --state-bucket <name> \
#       [--audit-bucket <name>] [--secret <name>]... \
#       [--service-account <email>]... [--sa-prefix <prefix>]... \
#       [--baseline <path>]
#   preserve-check.sh [--baseline <path>] [--project <id>] [--allow-unknown]
#
# Exit codes:
#   0  every protected resource is present and intact.
#
# shellcheck disable=SC2016
# Every jq program below is single-quoted on purpose. $i, $base, $live, $role
# and friends are jq variables bound by --arg/--argjson, not shell variables;
# letting the shell expand them would substitute the value into the program text
# and change what jq parses. File-level rather than seventeen identical inline
# directives, matching conformance.sh in this directory.
#   1  at least one REGRESSION against the baseline.
#   2  usage error, or a non-read-only call was refused.
#   3  no regression, but at least one check could not be run (see
#      --allow-unknown below).
#
# UNKNOWN DEFAULTS TO FAILURE HERE, which is the opposite of conformance.sh and
# is deliberate. conformance.sh grades a posture; being unable to read one IAM
# policy leaves the other twenty verdicts meaningful. This script answers one
# question -- "did the state bucket survive?" -- and "I could not tell" is not
# an acceptable answer to it immediately after a destroy. `--allow-unknown`
# exists for the pre-destroy capture-time sanity run, where a missing permission
# is a setup problem rather than a data-loss report.
set -Eeuo pipefail

readonly SCRIPT_NAME="preserve-check"
readonly EXIT_REGRESSION=1
readonly EXIT_USAGE=2
readonly EXIT_UNKNOWN=3
readonly MANIFEST_SCHEMA=1

GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
JQ_BIN="${JQ_BIN:-jq}"
PRESERVE_BASELINE="${PRESERVE_BASELINE:-deploy/gcp/preserve-baseline.json}"

REGRESSION_COUNT=0
PASS_COUNT=0
UNKNOWN_COUNT=0

# gcloud_ro() runs inside command substitution in almost every call site, so an
# `exit` there would only end the subshell and the caller would read the failure
# as "the cloud did not answer" -- a refused mutation laundered into an UNKNOWN.
# The refusal is therefore recorded in a file, which survives the subshell, and
# main() aborts on it.
REFUSAL_FLAG=""

usage() {
  cat <<'USAGE'
preserve-check.sh -- verify the resources a destroy must never take with it.

MODES
  --capture         Record the current state of the protected resources to the
                    baseline manifest. Run this BEFORE the first destroy, and
                    again whenever a change to the protected set is intended.
  (default)         Compare the live estate against the baseline manifest and
                    report every regression. Run this AFTER every destroy.

CAPTURE OPTIONS
  --project <id>            GCP project. Required for --capture.
  --state-bucket <name>     Terraform state bucket, without the gs:// scheme.
                            Required for --capture. Its object inventory is
                            recorded per top-level prefix, because an emptied
                            state bucket still exists.
  --audit-bucket <name>     Audit log bucket. Recorded, not inventoried.
  --secret <name>           Secret Manager secret to protect. Repeatable.
  --service-account <email> Service account to protect. Repeatable.
  --sa-prefix <prefix>      Record every service account in the project whose
                            account id starts with <prefix>. Repeatable. This
                            is how a second environment's runtime account joins
                            the protected set without editing this script.

COMMON OPTIONS
  --baseline <path>   Manifest path. Default: deploy/gcp/preserve-baseline.json
  --allow-unknown     Exit 0 rather than 3 when checks could not be run.
  -h, --help          This text.

ENVIRONMENT
  GCLOUD_BIN          gcloud binary. Default: gcloud
  JQ_BIN              jq binary. Default: jq
  PRESERVE_BASELINE   Default baseline path.

EXIT CODES
  0 intact   1 regression   2 usage or refused call   3 unchecked
USAGE
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_USAGE"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
#
# REGRESSION is reserved for "checked, and the protected thing is gone or
# degraded". UNKNOWN is "could not check". Collapsing the two in either
# direction is how a preservation report becomes untrustworthy: an UNKNOWN
# printed as a regression trains the operator to ignore regressions, and a
# regression printed as UNKNOWN is a data-loss event reported as a hiccup.
report() {
  local verdict="$1" item="$2" detail="$3"
  case "$verdict" in
    OK) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    REGRESSION) REGRESSION_COUNT=$((REGRESSION_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    *)
      printf '%s: internal error: unknown verdict %s\n' "$SCRIPT_NAME" "$verdict" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  printf '%-11s %-46s %s\n' "$verdict" "$item" "$detail"
}

fix() {
  printf '            %s %s\n' '->' "$*"
}

# ---------------------------------------------------------------------------
# The read-only gate
# ---------------------------------------------------------------------------
#
# Allowlisted, not denylisted. A denylist has to anticipate every gcloud surface
# that will ever exist; an allowlist of the verbs this script legitimately uses
# fails closed on everything else, including surfaces added after this was
# written.
#
# 'access' is conspicuously absent. `gcloud secrets versions access` is the one
# call that would put an auth key on this script's stdout, and the gate refuses
# it by construction rather than by anyone remembering not to type it.
gcloud_ro() {
  local joined=" $* "
  case "$joined" in
    *' describe '* | *' list '* | *' version '* | *' get-iam-policy '*) ;;
    *)
      printf '%s: refusing to run a non-read-only gcloud call: gcloud %s\n' \
        "$SCRIPT_NAME" "$*" >&2
      [ -n "$REFUSAL_FLAG" ] && printf 'refused: gcloud %s\n' "$*" >>"$REFUSAL_FLAG"
      return 99
      ;;
  esac
  "$GCLOUD_BIN" "$@"
}

refusal_tripped() {
  [ -n "$REFUSAL_FLAG" ] && [ -s "$REFUSAL_FLAG" ]
}

# probe() -- one cloud read, three distinguishable outcomes.
#
#   0  answered; JSON on stdout
#   1  the resource is genuinely NOT THERE (gcloud said NOT_FOUND / 404)
#   2  could not tell -- permission denied, no network, malformed answer
#
# Separating 1 from 2 is the single most load-bearing thing in this file. Both
# are a non-zero gcloud exit, and treating them alike means either every
# expired credential is reported as "the state bucket was deleted", or every
# deleted bucket is reported as "could not check". The classification is on
# gcloud's own error text, which is why stderr is captured rather than
# discarded.
probe() {
  local out="" err="" rc=0
  err="$(mktemp)"
  # shellcheck disable=SC2064
  # Expanded now on purpose: $err is rebound on the next call, and a deferred
  # expansion would delete whichever temp file happens to be current at exit.
  trap "rm -f '$err'" RETURN

  out="$(gcloud_ro "$@" --format=json 2>"$err")" || rc=$?

  if [ "$rc" -eq 99 ]; then
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'NOT_FOUND|not found|404|does not exist|no such' "$err"; then
      return 1
    fi
    return 2
  fi
  [ -n "$out" ] || return 2
  printf '%s' "$out" | "$JQ_BIN" -e . >/dev/null 2>&1 || return 2
  printf '%s' "$out"
}

jqr() {
  local json="$1"
  shift
  printf '%s' "$json" | "$JQ_BIN" -r "$@"
}

# Slurp zero or more compact JSON objects, given one per argument, into an
# array. Zero arguments must yield '[]' rather than an error, because a capture
# may legitimately record no audit bucket -- and an error there would be
# reported as a failed capture rather than as an absent optional input.
json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | "$JQ_BIN" -s -c .
}

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

# Inventory a bucket's objects by the directory that contains them.
#
# The count is what makes the check non-vacuous: an existence check passes on a
# state bucket that has been emptied, and an emptied state bucket is exactly as
# unrecoverable as a deleted one. Prefixes are DISCOVERED from the listing, not
# supplied, so every root and every environment that gets added later joins the
# protected set on the next capture with no edit here.
#
# THREE THINGS HERE WERE WRONG UNTIL A RUN AGAINST THE REAL BUCKET CORRECTED
# THEM, and all three were invisible to the stub fixtures, which returned
# whatever shape they were written to return.
#
#   1. THE '/**' IS MANDATORY. `gcloud storage objects list gs://bucket` returns
#      NOTHING -- not an error, an empty list. Only `gs://bucket/**` recurses.
#      Without it this function reported zero objects for a perfectly healthy
#      bucket, which the verifier would have printed as "THE STATE BUCKET IS
#      EMPTY": a false alarm on the single most alarming condition it can
#      report, on every run. The capture-time refusal to record an empty
#      baseline is what surfaced it.
#
#   2. DISTINCT NAMES ARE COUNTED, NOT RECORDS. The state bucket has object
#      versioning enabled, and `objects list` returns EVERY GENERATION: the real
#      bucket answered with 42 records for 4 live objects. A record count rises
#      on every apply and falls whenever lifecycle expiry collects old
#      generations, so comparing it against a baseline would report deletions
#      that never happened. The live-object count is the stable quantity, and it
#      is the one that answers "is the state still there".
#
#   3. GROUPING IS ON THE CONTAINING DIRECTORY, NOT THE FIRST PATH SEGMENT.
#      Every object in the real bucket lives under one shared top-level prefix,
#      so grouping on the first segment collapsed the whole estate into a single
#      count and threw away exactly the resolution this check exists for --
#      noticing that ONE root's state disappeared while the bucket as a whole
#      still looked busy.
#
# Lock files are excluded. A `.tflock` exists only while an apply is in flight,
# so a baseline captured during one records a file that is legitimately gone
# afterwards, and the verifier would call that a deletion. A lock is not state
# and losing one costs nothing. The pattern is overridable for testing.
PRESERVE_OBJECT_EXCLUDE="${PRESERVE_OBJECT_EXCLUDE:-\\.tflock$}"

inventory_prefixes() {
  local bucket="$1" raw rc=0

  raw="$(probe storage objects list "gs://${bucket}/**")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  # Fetched whole and grouped here rather than through `gcloud --filter`: a
  # mistyped server-side filter returns an empty list, an empty list reads as
  # "the bucket is empty", and this function would report a catastrophe it never
  # actually looked for.
  #
  # An object at the bucket root has no '/' and is grouped under '(root)' so it
  # is counted rather than silently dropped.
  jqr "$raw" --arg exclude "$PRESERVE_OBJECT_EXCLUDE" -c '
    [ .[] | .name // empty | select(test($exclude) | not) ]
    | unique
    | map(if test("/") then (.[0:(rindex("/") + 1)]) else "(root)" end)
    | group_by(.)
    | map({prefix: .[0], objects: length})
    | sort_by(.prefix)
  '
}

# Normalise the four bucket settings out of a `buckets describe` response.
#
# ONE code path, called by both capture and verify, and that is the entire
# reason it is a function. Two jq programs reading the same field is a
# comparison between two parsers rather than between two estates: the day one
# of them starts returning "false" for an absent key while the other returns
# "unknown", every bucket reports a regression that is not there -- or worse,
# both drift to the same wrong constant and every bucket reports OK forever.
#
# Both spellings are handled because `gcloud storage buckets describe` emits
# snake_case while the older `gsutil`-derived and REST shapes emit camelCase,
# and which one a machine gets depends on its gcloud version. Type is tested
# rather than truthiness: `uniform_bucket_level_access` is an OBJECT in one
# shape and a BOOLEAN in another, and `{"enabled": false}` is truthy, so a
# `//` chain would silently report a disabled setting as enabled.
bucket_settings() {
  local raw="$1"
  jqr "$raw" -c '{
    versioning: (
      if (.versioning | type) == "object" then (.versioning.enabled // false)
      elif (.versioning_enabled | type) == "boolean" then .versioning_enabled
      else false end
    ),
    retention_seconds: (
      ((.retentionPolicy.retentionPeriod) // (.retention_policy.retention_period) // 0) | tonumber
    ),
    public_access_prevention: (
      .publicAccessPrevention // .public_access_prevention // "unknown"
    ),
    uniform_bucket_level_access: (
      if (.uniformBucketLevelAccess | type) == "object" then (.uniformBucketLevelAccess.enabled // false)
      elif (.uniform_bucket_level_access | type) == "object" then (.uniform_bucket_level_access.enabled // false)
      elif (.uniform_bucket_level_access | type) == "boolean" then .uniform_bucket_level_access
      else false end
    )
  }'
}

capture_bucket() {
  local bucket="$1" role="$2" raw rc=0 prefixes="[]" total=0

  raw="$(probe storage buckets describe "gs://${bucket}")" || rc=$?
  case "$rc" in
    1) die "cannot capture a baseline: bucket gs://${bucket} does not exist" ;;
    2) die "cannot capture a baseline: could not read gs://${bucket}" ;;
  esac

  if [ "$role" = "state" ]; then
    rc=0
    prefixes="$(inventory_prefixes "$bucket")" || rc=$?
    [ "$rc" -eq 0 ] || die "cannot capture a baseline: could not list objects in gs://${bucket}"
    total="$(jqr "$prefixes" '[.[].objects] | add // 0')"
    # A state bucket with no objects is not a baseline worth recording; every
    # later comparison against it would pass by comparing nothing to nothing.
    [ "$total" -gt 0 ] || die "refusing to record an empty state bucket as the baseline for gs://${bucket}"
  fi

  "$JQ_BIN" -n \
    --arg name "$bucket" \
    --arg role "$role" \
    --argjson settings "$(bucket_settings "$raw")" \
    --argjson prefixes "$prefixes" \
    -c '$settings + {
      name: $name,
      role: $role,
      prefixes: $prefixes,
      total_objects: ([$prefixes[].objects] | add // 0)
    }'
}

capture_secret() {
  local project="$1" secret="$2" raw rc=0 versions

  raw="$(probe secrets describe "$secret" --project "$project")" || rc=$?
  case "$rc" in
    1) die "cannot capture a baseline: secret ${secret} does not exist" ;;
    2) die "cannot capture a baseline: could not read secret ${secret}" ;;
  esac

  rc=0
  versions="$(probe secrets versions list "$secret" --project "$project")" || rc=$?
  [ "$rc" -eq 0 ] || die "cannot capture a baseline: could not list versions of ${secret}"

  # ENABLED is counted, not total. A secret whose versions are all DESTROYED or
  # DISABLED still describes cleanly and is useless, and that is the shape this
  # whole file exists to catch.
  jqr "$versions" --arg name "$secret" -c '{
    name: $name,
    enabled_versions: ([ .[] | select((.state // .STATE // "") | ascii_upcase == "ENABLED") ] | length),
    total_versions: length
  }'
}

capture_service_account() {
  local project="$1" email="$2" raw rc=0

  raw="$(probe iam service-accounts describe "$email" --project "$project")" || rc=$?
  case "$rc" in
    1) die "cannot capture a baseline: service account ${email} does not exist" ;;
    2) die "cannot capture a baseline: could not read service account ${email}" ;;
  esac

  jqr "$raw" --arg email "$email" -c '{email: $email, disabled: (.disabled // false)}'
}

# Expand every --sa-prefix into concrete service account emails.
#
# Client-side matching on a whole list, for the reason at the top of the file: a
# server-side --filter that matches nothing is indistinguishable from a project
# with no such accounts, and the manifest would record an empty protected set
# that every later verify passes trivially.
discover_service_accounts() {
  local project="$1"
  shift
  local raw rc=0 prefixes_json

  raw="$(probe iam service-accounts list --project "$project")" || rc=$?
  [ "$rc" -eq 0 ] || die "cannot capture a baseline: could not list service accounts in ${project}"

  prefixes_json="$(printf '%s\n' "$@" | "$JQ_BIN" -R . | "$JQ_BIN" -s -c .)"
  jqr "$raw" --argjson prefixes "$prefixes_json" -r '
    [ .[] | .email // empty ]
    | map(select(. as $e | $prefixes | any(. as $p | ($e | startswith($p)))))
    | .[]
  '
}

do_capture() {
  local project="$1" state_bucket="$2" audit_bucket="$3" baseline="$4"
  shift 4
  local -a secrets=() accounts=() sa_prefixes=()
  local mode=""
  local arg
  # The three lists arrive as one argv separated by sentinels so this stays a
  # plain function call rather than a nameref dance.
  for arg in "$@"; do
    case "$arg" in
      --@secrets) mode="secrets" ;;
      --@accounts) mode="accounts" ;;
      --@prefixes) mode="prefixes" ;;
      *)
        case "$mode" in
          secrets) secrets+=("$arg") ;;
          accounts) accounts+=("$arg") ;;
          prefixes) sa_prefixes+=("$arg") ;;
        esac
        ;;
    esac
  done

  local buckets_json secrets_json accounts_json
  local -a bucket_objs=() secret_objs=() account_objs=()

  bucket_objs+=("$(capture_bucket "$state_bucket" state)")
  if [ -n "$audit_bucket" ]; then
    bucket_objs+=("$(capture_bucket "$audit_bucket" audit)")
  fi

  local s
  for s in ${secrets[@]+"${secrets[@]}"}; do
    secret_objs+=("$(capture_secret "$project" "$s")")
  done

  local resolved=""
  if [ "${#sa_prefixes[@]}" -gt 0 ]; then
    resolved="$(discover_service_accounts "$project" "${sa_prefixes[@]}")"
  fi
  local email
  # Word splitting on newlines only: service account emails cannot contain
  # whitespace, and IFS is restored immediately.
  local old_ifs="$IFS"
  IFS=$'\n'
  for email in ${resolved}; do
    accounts+=("$email")
  done
  IFS="$old_ifs"

  # De-duplicate: an email can arrive both explicitly and via a prefix.
  local -a unique=()
  for email in ${accounts[@]+"${accounts[@]}"}; do
    case " ${unique[*]-} " in
      *" ${email} "*) continue ;;
    esac
    unique+=("$email")
  done
  for email in ${unique[@]+"${unique[@]}"}; do
    account_objs+=("$(capture_service_account "$project" "$email")")
  done

  # One newline-delimited stream per list, slurped by jq. Deliberately NOT
  # `"${arr[*]}"` piped through `tr ' ' '\n'`: that only works while jq -c
  # output happens to contain no spaces, and it would corrupt the manifest
  # silently the first time one did.
  buckets_json="$(json_array ${bucket_objs[@]+"${bucket_objs[@]}"})"
  secrets_json="$(json_array ${secret_objs[@]+"${secret_objs[@]}"})"
  accounts_json="$(json_array ${account_objs[@]+"${account_objs[@]}"})"

  mkdir -p "$(dirname "$baseline")"
  "$JQ_BIN" -n \
    --argjson schema "$MANIFEST_SCHEMA" \
    --arg project "$project" \
    --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson buckets "$buckets_json" \
    --argjson secrets "$secrets_json" \
    --argjson service_accounts "$accounts_json" \
    '{schema: $schema, captured_at: $captured_at, project: $project,
      buckets: $buckets, secrets: $secrets, service_accounts: $service_accounts}' \
    >"$baseline"

  printf '%s: baseline written to %s\n' "$SCRIPT_NAME" "$baseline"
  printf '  buckets: %s  secrets: %s  service accounts: %s\n' \
    "$(jqr "$(cat "$baseline")" '.buckets | length')" \
    "$(jqr "$(cat "$baseline")" '.secrets | length')" \
    "$(jqr "$(cat "$baseline")" '.service_accounts | length')"
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

# A manifest that protects nothing produces a run that reports nothing and exits
# 0 -- the purest form of the vacuous pass. Every count below is therefore
# asserted before a single cloud call is made, and a hollow manifest is a usage
# error rather than a clean report.
assert_manifest_is_not_hollow() {
  local m="$1" schema buckets secrets accounts state_buckets state_objects

  schema="$(jqr "$m" '.schema // 0')"
  [ "$schema" = "$MANIFEST_SCHEMA" ] ||
    die "baseline schema is '${schema}', expected ${MANIFEST_SCHEMA}; re-capture it"

  buckets="$(jqr "$m" '.buckets | length')"
  secrets="$(jqr "$m" '.secrets | length')"
  accounts="$(jqr "$m" '.service_accounts | length')"
  state_buckets="$(jqr "$m" '[.buckets[] | select(.role == "state")] | length')"
  state_objects="$(jqr "$m" '[.buckets[] | select(.role == "state") | .total_objects] | add // 0')"

  [ "$buckets" -gt 0 ] || die "baseline protects no buckets; it would pass by checking nothing"
  [ "$secrets" -gt 0 ] || die "baseline protects no secrets; it would pass by checking nothing"
  [ "$accounts" -gt 0 ] || die "baseline protects no service accounts; it would pass by checking nothing"
  [ "$state_buckets" -gt 0 ] || die "baseline names no bucket with role 'state'"
  [ "$state_objects" -gt 0 ] || die "baseline records a state bucket with zero objects; re-capture against a real estate"
}

# Compare one recorded setting. Any divergence is a regression, in EITHER
# direction, because the contract is "unchanged from the baseline" rather than
# "at least as strong as". Turning versioning on is a good change and it is
# still a change nobody recorded; accepting it silently here means the next
# person cannot tell which of the two states the estate is supposed to be in.
# The sanctioned way to accept a change is `--capture`, which leaves a diff.
compare_setting() {
  local bucket="$1" setting="$2" want="$3" got="$4"

  if [ "$want" = "$got" ]; then
    report OK "gs://${bucket} ${setting}" "$got"
    return 0
  fi
  report REGRESSION "gs://${bucket} ${setting}" "baseline '${want}', live '${got}'"
  fix "if this change was intended, re-run with --capture and commit the new baseline"
  return 0
}

verify_bucket() {
  local m="$1" idx="$2"
  local bucket role raw rc=0

  bucket="$(jqr "$m" --argjson i "$idx" -r '.buckets[$i].name')"
  role="$(jqr "$m" --argjson i "$idx" -r '.buckets[$i].role')"

  raw="$(probe storage buckets describe "gs://${bucket}")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    report REGRESSION "gs://${bucket} (${role})" "THE BUCKET IS GONE"
    fix "this is unrecoverable from here; stop and work out what deleted it before rebuilding"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    report UNKNOWN "gs://${bucket} (${role})" "could not read the bucket; this is NOT a clean result"
    return 0
  fi
  report OK "gs://${bucket} (${role})" "exists and is readable"

  # Same parser as capture used, so a divergence here is a divergence in the
  # estate rather than in how the two sides read a JSON key. The settings are
  # iterated by key from the parser's own output: a setting added to
  # bucket_settings() therefore starts being compared without anyone
  # remembering to add a line here, which is the failure mode that leaves a
  # newly-recorded setting silently unchecked.
  local live_settings setting want got
  live_settings="$(bucket_settings "$raw")"

  local -a setting_names=()
  local sn
  while IFS= read -r sn; do
    [ -n "$sn" ] && setting_names+=("$sn")
  done <<<"$(jqr "$live_settings" -r 'keys_unsorted[]')"

  for setting in ${setting_names[@]+"${setting_names[@]}"}; do
    got="$(jqr "$live_settings" --arg k "$setting" -r '.[$k] | tostring')"
    want="$(jqr "$m" --argjson i "$idx" --arg k "$setting" -r '.buckets[$i][$k] | tostring')"
    compare_setting "$bucket" "$setting" "$want" "$got"
  done

  [ "$role" = "state" ] || return 0

  rc=0
  local live_prefixes
  live_prefixes="$(inventory_prefixes "$bucket")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    report UNKNOWN "gs://${bucket} object inventory" "could not list objects; the emptied-bucket check did not run"
    return 0
  fi

  # An emptied state bucket is as unrecoverable as a deleted one and looks
  # identical to `describe`. It is called out separately from a per-prefix
  # shortfall because the operator response differs: total emptiness means
  # something ran against the bucket itself.
  local live_total
  live_total="$(jqr "$live_prefixes" '[.[].objects] | add // 0')"
  if [ "$live_total" -eq 0 ]; then
    report REGRESSION "gs://${bucket} object inventory" "THE STATE BUCKET IS EMPTY (baseline had $(jqr "$m" --argjson i "$idx" -r '.buckets[$i].total_objects') objects)"
    fix "every root's state is gone; do not run terraform against this project until this is understood"
    return 0
  fi

  # Per-prefix, so that losing one environment's state is caught even when the
  # bucket total looks healthy because another root grew.
  local report_lines
  report_lines="$(
    "$JQ_BIN" -n -r \
      --argjson base "$(jqr "$m" --argjson i "$idx" -c '.buckets[$i].prefixes')" \
      --argjson live "$live_prefixes" '
      ($live | map({key: .prefix, value: .objects}) | from_entries) as $l
      | $base[]
      | . as $b
      | ($l[$b.prefix] // 0) as $now
      | if $now == 0 then "GONE\t\($b.prefix)\t\($b.objects)\t0"
        elif $now < $b.objects then "SHRANK\t\($b.prefix)\t\($b.objects)\t\($now)"
        else "OK\t\($b.prefix)\t\($b.objects)\t\($now)"
        end
    '
  )"

  local kind prefix was now
  while IFS=$'\t' read -r kind prefix was now; do
    [ -n "$kind" ] || continue
    case "$kind" in
      GONE)
        report REGRESSION "gs://${bucket} ${prefix}" "prefix emptied: baseline ${was} objects, live 0"
        fix "this root's state is gone; its resources still exist and are unmanaged"
        ;;
      SHRANK)
        report REGRESSION "gs://${bucket} ${prefix}" "objects deleted: baseline ${was}, live ${now}"
        ;;
      OK)
        report OK "gs://${bucket} ${prefix}" "${now} objects (baseline ${was})"
        ;;
    esac
    # A trailing newline is not guaranteed from jq -r on some builds, so the
    # loop is fed by a here-string rather than a process substitution: `read`
    # returning non-zero on the final unterminated line would otherwise drop it
    # under errexit, silently skipping the last prefix.
  done <<<"$report_lines"
}

verify_secret() {
  local m="$1" idx="$2" project="$3"
  local secret rc=0 raw versions live_enabled base_enabled

  secret="$(jqr "$m" --argjson i "$idx" -r '.secrets[$i].name')"

  raw="$(probe secrets describe "$secret" --project "$project")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    report REGRESSION "secret ${secret}" "THE SECRET IS GONE"
    fix "re-mint a Tailscale auth key by hand and re-capture; every rebuild is blocked until then"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    report UNKNOWN "secret ${secret}" "could not read the secret; this is NOT a clean result"
    return 0
  fi
  report OK "secret ${secret}" "exists"

  rc=0
  versions="$(probe secrets versions list "$secret" --project "$project")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    report UNKNOWN "secret ${secret} versions" "could not list versions; the usable-key check did not run"
    return 0
  fi

  live_enabled="$(jqr "$versions" '[ .[] | select((.state // .STATE // "") | ascii_upcase == "ENABLED") ] | length')"
  base_enabled="$(jqr "$m" --argjson i "$idx" -r '.secrets[$i].enabled_versions')"

  # THE CHECK THAT MATTERS. A secret with every version destroyed or disabled
  # still exists, still describes cleanly, and cannot start a VM. `describe`
  # alone would have reported this as fine.
  if [ "$live_enabled" -eq 0 ]; then
    report REGRESSION "secret ${secret} versions" "NO ENABLED VERSION (baseline had ${base_enabled}); the secret exists but is unusable"
    fix "add a new enabled version, or re-enable one, before any rebuild"
    return 0
  fi
  if [ "$live_enabled" -lt "$base_enabled" ]; then
    report REGRESSION "secret ${secret} versions" "enabled versions fell from ${base_enabled} to ${live_enabled}"
    return 0
  fi
  report OK "secret ${secret} versions" "${live_enabled} enabled (baseline ${base_enabled})"
}

verify_service_account() {
  local m="$1" idx="$2" project="$3"
  local email rc=0 raw disabled

  email="$(jqr "$m" --argjson i "$idx" -r '.service_accounts[$i].email')"

  raw="$(probe iam service-accounts describe "$email" --project "$project")" || rc=$?
  if [ "$rc" -eq 1 ]; then
    report REGRESSION "service account ${email}" "THE SERVICE ACCOUNT IS GONE"
    fix "recreating it does not restore its IAM bindings; expect a platform re-apply"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    report UNKNOWN "service account ${email}" "could not read it; this is NOT a clean result"
    return 0
  fi

  # A disabled service account exists. It authenticates nothing.
  disabled="$(jqr "$raw" '(.disabled // false) | tostring')"
  if [ "$disabled" = "true" ]; then
    report REGRESSION "service account ${email}" "exists but is DISABLED"
    return 0
  fi
  report OK "service account ${email}" "exists and is enabled"
}

do_verify() {
  local baseline="$1" project_override="$2" allow_unknown="$3"
  local m project n i

  [ -f "$baseline" ] || die "no baseline at ${baseline}; run --capture before the first destroy"
  m="$(cat "$baseline")"
  printf '%s' "$m" | "$JQ_BIN" -e . >/dev/null 2>&1 || die "baseline at ${baseline} is not valid JSON"

  assert_manifest_is_not_hollow "$m"

  project="${project_override:-$(jqr "$m" -r '.project')}"
  [ -n "$project" ] && [ "$project" != "null" ] || die "baseline names no project"

  printf '%s: verifying %s against %s (captured %s)\n\n' \
    "$SCRIPT_NAME" "$project" "$baseline" "$(jqr "$m" -r '.captured_at')"

  n="$(jqr "$m" '.buckets | length')"
  for ((i = 0; i < n; i++)); do verify_bucket "$m" "$i"; done

  n="$(jqr "$m" '.secrets | length')"
  for ((i = 0; i < n; i++)); do verify_secret "$m" "$i" "$project"; done

  n="$(jqr "$m" '.service_accounts | length')"
  for ((i = 0; i < n; i++)); do verify_service_account "$m" "$i" "$project"; done

  printf '\n%s: %d ok, %d regression(s), %d unchecked\n' \
    "$SCRIPT_NAME" "$PASS_COUNT" "$REGRESSION_COUNT" "$UNKNOWN_COUNT"

  if refusal_tripped; then
    printf '%s: a non-read-only gcloud call was refused; the run is not trustworthy\n' "$SCRIPT_NAME" >&2
    return "$EXIT_USAGE"
  fi
  if [ "$REGRESSION_COUNT" -gt 0 ]; then
    return "$EXIT_REGRESSION"
  fi
  if [ "$UNKNOWN_COUNT" -gt 0 ] && [ "$allow_unknown" != "true" ]; then
    printf '%s: no regression found, but %d check(s) never ran. After a destroy that is not a pass.\n' \
      "$SCRIPT_NAME" "$UNKNOWN_COUNT" >&2
    return "$EXIT_UNKNOWN"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local mode="verify" project="" state_bucket="" audit_bucket=""
  local baseline="$PRESERVE_BASELINE" allow_unknown="false"
  local -a secrets=() accounts=() sa_prefixes=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --capture) mode="capture" ;;
      --project)
        [ "$#" -ge 2 ] || die "--project needs a value"
        project="$2"
        shift
        ;;
      --state-bucket)
        [ "$#" -ge 2 ] || die "--state-bucket needs a value"
        state_bucket="${2#gs://}"
        shift
        ;;
      --audit-bucket)
        [ "$#" -ge 2 ] || die "--audit-bucket needs a value"
        audit_bucket="${2#gs://}"
        shift
        ;;
      --secret)
        [ "$#" -ge 2 ] || die "--secret needs a value"
        secrets+=("$2")
        shift
        ;;
      --service-account)
        [ "$#" -ge 2 ] || die "--service-account needs a value"
        accounts+=("$2")
        shift
        ;;
      --sa-prefix)
        [ "$#" -ge 2 ] || die "--sa-prefix needs a value"
        sa_prefixes+=("$2")
        shift
        ;;
      --baseline)
        [ "$#" -ge 2 ] || die "--baseline needs a value"
        baseline="$2"
        shift
        ;;
      --allow-unknown) allow_unknown="true" ;;
      -h | --help)
        usage
        return 0
        ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  have "$GCLOUD_BIN" || die "'${GCLOUD_BIN}' is not on PATH; nothing can be checked"
  have "$JQ_BIN" || die "'${JQ_BIN}' is not on PATH; every check would be unreadable"

  REFUSAL_FLAG="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$REFUSAL_FLAG'" EXIT

  if [ "$mode" = "capture" ]; then
    [ -n "$project" ] || die "--capture needs --project"
    [ -n "$state_bucket" ] || die "--capture needs --state-bucket"
    # A capture with no secrets and no accounts writes a manifest that verify
    # then rejects as hollow. Failing here instead names the missing flag.
    [ "${#secrets[@]}" -gt 0 ] ||
      die "--capture needs at least one --secret; a baseline that protects no secret protects nothing"
    [ "${#accounts[@]}" -gt 0 ] || [ "${#sa_prefixes[@]}" -gt 0 ] ||
      die "--capture needs at least one --service-account or --sa-prefix"

    do_capture "$project" "$state_bucket" "$audit_bucket" "$baseline" \
      --@secrets ${secrets[@]+"${secrets[@]}"} \
      --@accounts ${accounts[@]+"${accounts[@]}"} \
      --@prefixes ${sa_prefixes[@]+"${sa_prefixes[@]}"}

    if refusal_tripped; then
      printf '%s: a non-read-only gcloud call was refused during capture\n' "$SCRIPT_NAME" >&2
      return "$EXIT_USAGE"
    fi
    return 0
  fi

  do_verify "$baseline" "$project" "$allow_unknown"
}

# Guarded so the suite can source this file and drive gcloud_ro() and probe()
# in isolation. A read-only gate nobody can call on its own is a gate nobody
# tests, and this one is the reason the script is safe to run beside a destroy.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
