#!/usr/bin/env bash
# check-ci-build-parity.sh — does CI build everything the demo bring-up builds?
#
#   check-ci-build-parity.sh          # compare demo-signalloom-up against CI
#   check-ci-build-parity.sh --target demo-agent-trust-up
#
# No cluster, no docker, no network. Reads two text files and exits non-zero.
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# scripts/ci/vm-pipeline.sh does not call `make demo-signalloom-up`. It cannot:
# the shared `wait` target expects OSRAMP ResourceSets the signalloom-only path
# does not create until later, which is why the pipeline says "Use individual
# targets instead of `make up`" and then hand-copies the body of the bring-up
# target. A hand-copied recipe is a fork, and forks drift silently.
#
# It has now drifted twice, and the second time cost a full lane:
#
#   Makefile:429 added `$(MAKE) demo-signalloom-supercred-images` to
#   demo-signalloom-up, under a comment ending "Always-deployed has to mean
#   always-built" — because supercred-demo-runner/base has been an
#   unconditional member of apps/fe-signalloom/base/kustomization.yaml since
#   0233217 and every bring-up therefore DEPLOYS it. The CI copy never got the
#   line. The workload uses a bare `supercred-demo-runner:local` tag, so
#   containerd resolved it to docker.io/library, Docker Hub answered with an
#   HTML error page, and the kubelet reported
#     unexpected media type text/html ... : not found
#   which reads as a registry problem rather than a missing build step.
#
# The cost is the shape worth remembering. ONE missing build line failed THREE
# stages ~40 minutes in: 6b (check-deployed-staleness correctly refused to call
# an unreadable workload verified), and then 8 and 8b, whose every test PASSED
# — 11 passed (9.8s) and 18 passed (23.4s) — and which failed on the preflight
# that calls 6b. Three red stages, no failing test, and the actual defect was a
# line missing from a shell script.
#
# ─── Why the comparison is DERIVED, not listed ──────────────────────────────
#
# A hand-maintained list of "steps CI must run" is the same artefact as the
# hand-copied recipe: it drifts the moment someone edits the Makefile and not
# the list, which is precisely the failure being guarded. So this reads the
# `$(MAKE) <target>` lines straight out of the bring-up recipe and the `make
# <target>` invocations straight out of the pipeline, and compares the two sets.
# Add a step to demo-signalloom-up and forget CI, and this goes red in ~1s in
# stage 1 instead of red in ~40 minutes across stages 6b, 8 and 8b.
#
# Same reasoning as scripts/check-backends.sh, which derives the set of backends
# that must be deployed from nginx.conf's proxy_pass lines rather than a list,
# and test/keys-dir-path-safety.bats, which derives its offender set from the
# Makefile. Aimed here at build parity rather than at deployment or at paths.
#
# ─── The allowlist is a decision record, not an escape hatch ────────────────
#
# Some omissions are deliberate — CI opts out of things that only matter to an
# interactive operator. Those belong here with a reason, so the next reader can
# tell a decision from an accident. To keep the allowlist from rotting into a
# blanket exemption it is itself checked: an entry naming a target the recipe no
# longer runs, or one CI turns out to run after all, is a failure. A stale
# exemption silently re-opens the hole it was written to document.

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="${MAKEFILE:-${repo_root}/Makefile}"
PIPELINE="${PIPELINE:-${repo_root}/scripts/ci/vm-pipeline.sh}"
TARGET="${CI_PARITY_TARGET:-demo-signalloom-up}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ── Deliberate CI opt-outs: target|reason ───────────────────────────────────
#
# CI_PARITY_ALLOW overrides this list (space-separated `target=reason`) so the
# BATS suite can drive the guard against fixture trees that do not contain these
# targets. Unset means "use the reasons below", which is what CI and humans get.
ALLOWED=(
  # Builds the pinned netassert v2.1.5 runner. The image has exactly one
  # consumer — NETASSERT_RUNNER_IMAGE in apps/netassert-controller/server.py —
  # which materialises a Job only when an operator presses Scan Now. No
  # kustomization deploys it, check-deployed-staleness does not track it, and no
  # acceptance spec presses the button, so in CI the build is pure cost. If a
  # spec ever drives Scan Now, delete this entry rather than debugging the pull.
  "netassert-runner-image|runtime-only: built on demand by the Scan Now button, which no CI stage presses"
  # Deploys the KubeSec-AFM slice from a source repo OUTSIDE this one
  # (KUBESEC_AFM_ROOT, default /home/andy/src/cp/kubesec-afm). The CI VM
  # extracts a tarball of this repo alone, so the source is absent by
  # construction. The target is already warn-not-fail for exactly this reason;
  # calling it in CI would add a guaranteed warning and nothing else.
  "demo-signalloom-afm-up|unavailable: needs the external kubesec-afm source tree, absent on the CI VM"
)
if [ -n "${CI_PARITY_ALLOW+x}" ]; then
  ALLOWED=()
  for entry in $CI_PARITY_ALLOW; do
    ALLOWED+=("${entry%%=*}|${entry#*=}")
  done
fi

allow_reason() {
  local t="$1" entry
  for entry in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
    [ "${entry%%|*}" = "$t" ] && { printf '%s' "${entry#*|}"; return 0; }
  done
  return 1
}

# ── Read the bring-up recipe ────────────────────────────────────────────────
#
# Emits `<line-number> <target>` for each `$(MAKE) <target>` in the recipe body.
# `$(MAKE) -C <dir> <target>` is skipped deliberately: a sub-make into a slice
# directory is not a root-Makefile target CI could invoke by this name, and the
# leading `-` keeps it out of the pattern. Comment lines are skipped so the
# Makefile can explain itself without being parsed.
recipe_steps() {
  awk -v target="$TARGET" '
    index($0, target ":") == 1 { inrecipe = 1; next }
    inrecipe && /^\t/ {
      line = $0
      sub(/^\t+/, "", line)
      sub(/^[@+-]+/, "", line)
      if (line ~ /^#/) next
      if (match(line, /\$\(MAKE\)[ \t]+[A-Za-z0-9_][A-Za-z0-9_.-]*/)) {
        step = substr(line, RSTART, RLENGTH)
        sub(/\$\(MAKE\)[ \t]+/, "", step)
        print NR " " step
      }
      next
    }
    inrecipe && !/^\t/ && !/^[ \t]*$/ { inrecipe = 0 }
  ' "$MAKEFILE"
}

# The recipe line that hands over from building to deploying. Everything the
# recipe builds BEFORE this point must also be built before the pipeline reaches
# its own copy of it — a build step that runs after activation is the
# ImagePullBackOff again, just later in the log.
DEPLOY_ANCHOR_RE='signalloom-local\.sh up'

anchor_line() {  # anchor_line <file> ; empty when the file has no anchor
  grep -nE "$DEPLOY_ANCHOR_RE" "$1" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' \
    | head -1 | cut -d: -f1 || true
}

# ── Read the pipeline ───────────────────────────────────────────────────────
#
# Emits `<line-number> <target>` for every `make <target>` the pipeline actually
# runs. Full-line comments are dropped first: the pipeline discusses `make up`
# and `make signalloom-images` in prose, and a guard that counts its own
# documentation as coverage proves nothing.
pipeline_steps() {
  local numbered n body t
  while IFS= read -r numbered; do
    n="${numbered%%:*}"; body="${numbered#*:}"
    while IFS= read -r t; do
      [ -n "$t" ] && printf '%s %s\n' "$n" "$t"
    done < <(printf '%s\n' "$body" \
               | grep -oE '(^|[;&|(]|[[:space:]])make[[:space:]]+[A-Za-z0-9_][A-Za-z0-9_.-]*' \
               | sed -E 's/.*make[[:space:]]+//' || true)
  done < <(grep -nvE '^[[:space:]]*#' "$PIPELINE" || true)
}

fail=0

printf '\n── build steps %s runs, and whether CI runs them ──\n\n' "$TARGET"

steps="$(recipe_steps)"

# Cannot pass vacuously. A renamed target, a reindented recipe or a broken
# pattern would otherwise produce an empty set and a confident green — the guard
# would then certify parity it never looked for, which is how the last two
# incidents were able to reach a VM at all.
if [ -z "$steps" ]; then
  # shellcheck disable=SC2016  # "$(MAKE)" is the literal text being reported on.
  printf '  NO STEPS    %s in %s yields no $(MAKE) lines.\n' "$TARGET" "$MAKEFILE" >&2
  printf '              Either the target was renamed or this parser no longer\n' >&2
  printf '              matches the recipe. Refusing to report parity it did not check.\n\n' >&2
  exit 1
fi

pipeline="$(pipeline_steps)"
recipe_anchor="$(anchor_line "$MAKEFILE")"
pipeline_anchor="$(anchor_line "$PIPELINE")"

while read -r recipe_line step; do
  [ -z "$step" ] && continue
  hit="$(printf '%s\n' "$pipeline" | awk -v s="$step" '$2 == s { print $1; exit }')"
  reason="$(allow_reason "$step" || true)"

  if [ -n "$hit" ]; then
    if [ -n "$reason" ]; then
      printf '  STALE ALLOW %-40s allowlisted as "%s"\n' "$step" "$reason" >&2
      printf '              but %s runs it at line %s. Drop the entry.\n' "$(basename "$PIPELINE")" "$hit" >&2
      fail=1
      continue
    fi
    # Ordering, derived the same way the membership is: a step the recipe runs
    # before handing over to signalloom-local.sh must be built before the
    # pipeline's own handover, or the deploy races the build it depends on.
    if [ -n "$recipe_anchor" ] && [ -n "$pipeline_anchor" ] \
       && [ "$recipe_line" -lt "$recipe_anchor" ] && [ "$hit" -gt "$pipeline_anchor" ]; then
      printf '  TOO LATE    %-40s built at line %s, after the deploy at line %s\n' \
        "$step" "$hit" "$pipeline_anchor" >&2
      printf '              The workload is scheduled before its image exists.\n' >&2
      fail=1
      continue
    fi
    printf '  BUILT       %-40s %s:%s\n' "$step" "$(basename "$PIPELINE")" "$hit"
    continue
  fi

  if [ -n "$reason" ]; then
    printf '  OPT-OUT     %-40s %s\n' "$step" "$reason"
    continue
  fi

  printf '  MISSING     %-40s %s runs it; %s never does\n' \
    "$step" "$TARGET" "$(basename "$PIPELINE")" >&2
  fail=1
done <<< "$steps"

# An allowlist entry for a step the recipe no longer runs is a decision record
# for a decision nobody faces any more. Left in place it silently pre-approves
# whatever reclaims that name later.
for entry in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  t="${entry%%|*}"
  if ! printf '%s\n' "$steps" | awk -v s="$t" '$2 == s { found = 1 } END { exit !found }'; then
    printf '  DEAD ALLOW  %-40s allowlisted, but %s no longer runs it\n' "$t" "$TARGET" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  printf '\n  CI does not build what it deploys.\n' >&2
  printf '  %s hand-copies the body of %s (it cannot call it —\n' "$(basename "$PIPELINE")" "$TARGET" >&2
  printf '  see the "Use individual targets" comment), so every step added to the\n' >&2
  printf '  recipe has to be added there too. Add the missing step to stage [4/7],\n' >&2
  printf '  or add it above with a reason if the omission is deliberate.\n\n' >&2
  exit 1
fi

printf '\n  Every build step %s runs is run or explicitly opted out of by CI.\n\n' "$TARGET"
