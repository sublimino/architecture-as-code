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

# "Could not look" and "looked and found nothing" are different answers, and a
# guard that writes the second over the first is check-flux-substitution.sh
# printing "no unsubstituted tokens" against no cluster at all. Measured before
# this existed: pointing PIPELINE at a path that does not exist produced a full
# page of MISSING and the words "CI does not build what it deploys" — a
# confident diagnosis of a file the guard had never opened, sending the reader
# to add build steps to something that is not there. The Makefile side surfaced
# as awk's own "fatal: cannot open file" and exit 2, accurate only by accident.
#
# Both remain exit 1: a check that could not run must stop CI exactly as hard as
# a check that failed. The distinction lives in the words, next to the NO STEPS
# refusal below, which is the same refusal aimed at the other way of seeing
# nothing.
for input in "$MAKEFILE" "$PIPELINE"; do
  if [ ! -f "$input" ] || [ ! -r "$input" ]; then
    printf '\n  CANNOT READ %s\n' "$input" >&2
    printf '              The guard cannot compare what it cannot open, so nothing\n' >&2
    printf '              was checked. This is not a parity result. If the file moved,\n' >&2
    printf '              point MAKEFILE/PIPELINE at it; if it was deleted, the\n' >&2
    printf '              hand-copied recipe this guard exists for is gone too.\n\n' >&2
    exit 1
  fi
done

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

# ── Strip what will never execute ───────────────────────────────────────────
#
# Reads `<n>:<body>` and emits `<n>:<body with any comment removed>`.
#
# Both kinds of comment are text the shell never runs, and only one of them used
# to be handled here:
#
#   # make signalloom-images        full-line — dropped, correctly
#   retry 3 true # make foo         trailing  — NOT dropped, and that was the gap
#
# The second shape was measured against test/guard-falsification-proof.sh on
# 2026-08-16. Replacing the pipeline's live `make demo-signalloom-supercred-images`
# with `true # make demo-signalloom-supercred-images` — a step that genuinely
# stops running — left this guard green and printed
#
#   BUILT       demo-signalloom-supercred-images         vm-pipeline.sh:267
#
# citing, as proof that the image was built, the exact line that had stopped
# building it. The full-line filter dropped nothing (the line is live), the
# extractor matched ` make demo-…` inside the dead text, and the trailing `sed
# s/.*make[[:space:]]+//` lifted the target name back out of it. Deleting the
# same line outright went red, so the guard was live with one narrow blind spot:
# it read a disabled step's own name as its receipt. `true #` is how a step gets
# disabled in a hurry — during a bisect, or to skip one slow build "just for this
# run" — which makes it the likelier drift of the two, not the more exotic.
#
# Quote-aware, because `#` opens a comment only at the start of a word outside
# quotes. `${#done_stages[@]}` appears four times in the real pipeline; cutting
# at the first `#` would delete the rest of those lines and manufacture MISSING
# entries for steps that are right there. Trading blindness for false alarms is
# not a fix — a guard that cries wolf gets muted, and a muted guard is the
# blindness again with extra steps.
strip_shell_comments() {
  awk -v SQ="'" -v DQ='"' '
    {
      colon = index($0, ":")
      num = substr($0, 1, colon)
      s   = substr($0, colon + 1)
      q = ""; out = ""; ws = 1   # ws: the next character starts a word
      i = 1
      while (i <= length(s)) {
        c = substr(s, i, 1)
        if (q == "") {
          if (c == "\\") { out = out c substr(s, i + 1, 1); i += 2; ws = 0; continue }
          if (c == "#" && ws) break
          if (c == SQ || c == DQ) { q = c; out = out c; i++; ws = 0; continue }
          out = out c
          ws = (c == " " || c == "\t" || c == ";" || c == "&" \
                || c == "|" || c == "(" || c == ")")
          i++
          continue
        }
        if (q == DQ) {
          if (c == "\\") { out = out c substr(s, i + 1, 1); i += 2; continue }
          if (c == DQ) q = ""
        } else if (c == SQ) {   # single quotes are literal: no escapes inside
          q = ""
        }
        out = out c
        i++
      }
      print num out
    }
  '
}

# The recipe line that hands over from building to deploying. Everything the
# recipe builds BEFORE this point must also be built before the pipeline reaches
# its own copy of it — a build step that runs after activation is the
# ImagePullBackOff again, just later in the log.
DEPLOY_ANCHOR_RE='signalloom-local\.sh up'

# Same stripping, because the anchor has the same exposure: a handover named only
# inside a trailing comment is a handover that does not happen, and an anchor in
# the wrong place silently decides the TOO LATE verdict for every step.
anchor_line() {  # anchor_line <file> ; empty when the file has no anchor
  grep -n '' "$1" 2>/dev/null | strip_shell_comments \
    | grep -E "$DEPLOY_ANCHOR_RE" | head -1 | cut -d: -f1 || true
}

# ── Read the pipeline ───────────────────────────────────────────────────────
#
# Emits `<line-number> <target>` for every `make <target>` the pipeline actually
# RUNS. Comments are stripped first — both kinds, see strip_shell_comments above:
# the pipeline discusses `make up` and `make signalloom-images` in prose and
# explains the very step it omits, and a guard that counts its own documentation
# as coverage proves nothing.
pipeline_steps() {
  local numbered n body t
  while IFS= read -r numbered; do
    n="${numbered%%:*}"; body="${numbered#*:}"
    while IFS= read -r t; do
      [ -n "$t" ] && printf '%s %s\n' "$n" "$t"
    done < <(printf '%s\n' "$body" \
               | grep -oE '(^|[;&|(]|[[:space:]])make[[:space:]]+[A-Za-z0-9_][A-Za-z0-9_.-]*' \
               | sed -E 's/.*make[[:space:]]+//' || true)
  done < <(grep -n '' "$PIPELINE" 2>/dev/null | strip_shell_comments || true)
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
