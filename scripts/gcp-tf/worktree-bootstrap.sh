#!/usr/bin/env bash
#
# worktree-bootstrap.sh — carry the untracked operational state of this repo
# from a source checkout into a linked git worktree, and refuse to proceed when
# it is absent.
#
# WHY THIS EXISTS
#
# Everything this platform needs to reach a real GCP estate lives in gitignored
# files under deploy/gcp/ (plus .keys/). `git worktree add` copies TRACKED
# content only, so a fresh worktree gets none of it. That would be a small
# annoyance if it failed clearly. It does not. Each absence surfaces as a
# failure that names a different subsystem:
#
#   deploy/gcp/deploy-sa absent
#       TF_DEPLOY_SA resolves empty (the Makefile reads it with `sed ... 2>/dev/null`,
#       so a missing file and an empty file are indistinguishable). Then
#       gcp_tf_require_impersonation's first arm needs TF_DEPLOY_SA to be NON-empty
#       to refuse, so an absent file takes the second arm — a WARNING — and the
#       run continues. `make gcp-tf-up` therefore performs a COMPLETE, SUCCESSFUL
#       terraform apply and dies afterwards in gcp-tf-handoff with
#       "the terraform outputs do not carry every value the hand-off contract
#       requires ... deploy_sa". That message then offers two causes, and on this
#       path BOTH ARE WRONG: the output block is present and the state is current.
#       The cost is a full apply cycle before a misdirected diagnosis.
#
#   deploy/gcp/<env>.handoff.json absent
#       The demo driver refuses clearly (it names the file and the target that
#       writes it). Cheap, and not the expensive case — but the file it tells you
#       to regenerate is produced by gcp-tf-handoff, which is the target above.
#
#   deploy/gcp/bootstrap.tfvars absent
#       Two tests in test/terraform-make-contract.bats go red on every fresh
#       worktree, for reasons that have nothing to do with the branch under test.
#
#   .keys/ absent
#       cosign signing refuses.
#
#   KUBESEC_AFM_ROOT
#       Defaults to ${REPO_ROOT}/../kubesec-afm. In the main checkout that is a
#       real sibling. In a worktree under ~/src/.worktrees/<repo>/<branch>/ it
#       resolves beside the BRANCH, which does not exist — and the abort lands
#       late, after a multi-hundred-MB archive has been built. This script cannot
#       fix that by copying (it is a separate repository); it names it and prints
#       the export instead.
#
# COPY OR SYMLINK — the decision, and why it is not uniform
#
# The manifest below splits every item into one of two classes, because getting
# this wrong writes into the source checkout from a worktree run:
#
#   input   read-only for every consumer in this repo. Safe to symlink, so an
#           edit in the source checkout propagates rather than going stale.
#           Copied by default anyway; LINK=1 opts into symlinks.
#
#   output  REGENERATED in place by tooling in this repo. Must always be a real
#           copy. `gcp-tf-handoff` writes its target with a truncating `>`, and
#           `preserve-check.sh --capture` rewrites the baseline. A `>` through a
#           symlink follows the link and overwrites the SOURCE CHECKOUT's file —
#           silently repointing the main checkout's lane at whatever estate the
#           worktree was talking to. LINK=1 is refused for this class rather than
#           quietly honoured, because a flag that half-applies is worse than one
#           that errors.
#
# SAFETY
#
# `provision` plans before it acts. If a required source file is absent, or a
# destination is newer than its source and would be clobbered, NOTHING is copied
# and the command exits non-zero listing every problem at once. A half-provisioned
# tree is the state this script exists to prevent, so it will not create one.
#
# USAGE
#
#   scripts/gcp-tf/worktree-bootstrap.sh check       # refuse early, name the file
#   scripts/gcp-tf/worktree-bootstrap.sh status      # per-item report, exit 0
#   scripts/gcp-tf/worktree-bootstrap.sh provision   # copy from the source checkout
#
#   SOURCE_CHECKOUT=<path>  Where to copy from. Default: the main checkout that
#                           owns this worktree, derived from `git rev-parse
#                           --git-common-dir` — no path is hardcoded.
#   FORCE=1                 Overwrite destinations that are newer than source.
#   LINK=1                  Symlink the `input` class instead of copying it.
#   ENV=<key>               Also require deploy/gcp/<key>.handoff.json in `check`.
#   REQUIRE_ALSO=<lines>    Extra paths this particular caller cannot run without,
#                           one per line, as `<path>` or `<path>|<consequence>`.
#                           Repo-relative, or absolute for things outside the tree.
#
# WHY REQUIRE_ALSO EXISTS — it is the reconciliation, not a convenience
#
# The manifest's `required` column is deliberately conservative, because `check`
# gates `gcp-tf-up` and a main checkout without a lane tfvars or without .keys is
# a legitimate, supported state. A caller with a STRICTER need — the four-lane
# loop signs images and passes a specific tfvars as GCP_TF_VAR_FILE, so neither is
# optional for it — used to carry its own second copy of "is the file there, and
# what breaks without it". Two implementations of one invariant is the drift this
# repo punishes: they diverge, and the one nobody is looking at is the one that
# stops matching reality. A caller's stricter required-set is a PARAMETER of this
# check, not a reason to write another one, so it is passed in and travels the
# same code path, producing the same `MISSING` + `Consequence:` message.
#
set -euo pipefail

readonly PROGNAME="worktree-bootstrap"

die() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; exit 2; }
log() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$REPO_ROOT" ] || die "not inside a git working tree, and REPO_ROOT is not set"

FORCE="${FORCE:-}"
LINK="${LINK:-}"
ENV_KEY="${ENV:-}"

# ---------------------------------------------------------------------------
# Is this a linked worktree?
#
# In a linked worktree `--git-dir` points into <main>/.git/worktrees/<name> while
# `--git-common-dir` points at <main>/.git. In the main checkout the two are the
# same. Comparing them is exact; testing whether `.git` is a regular file is a
# proxy that also matches submodules.
# ---------------------------------------------------------------------------
git_common_dir() {
  local d
  d="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$d" ] || return 1
  case "$d" in
    /*) printf '%s\n' "$d" ;;
    *)  printf '%s\n' "${REPO_ROOT}/${d}" ;;
  esac
}

is_linked_worktree() {
  local gd cd_
  gd="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
  cd_="$(git_common_dir || true)"
  [ -n "$gd" ] && [ -n "$cd_" ] || return 1
  [ "$(cd "$gd" 2>/dev/null && pwd -P)" != "$(cd "$cd_" 2>/dev/null && pwd -P)" ]
}

# The checkout that owns the shared .git — i.e. the main working tree. Derived,
# never hardcoded, so this works for any clone on any machine.
default_source_checkout() {
  local cd_
  cd_="$(git_common_dir || true)"
  [ -n "$cd_" ] || return 1
  (cd "${cd_}/.." 2>/dev/null && pwd -P) || return 1
}

SOURCE_CHECKOUT="${SOURCE_CHECKOUT:-$(default_source_checkout || true)}"

# ---------------------------------------------------------------------------
# The manifest. Fields: <relative-path>|<class>|<required>|<what-breaks-without-it>
#
# `required` marks the items whose absence produces a misdirected failure rather
# than a clear one — those are what `check` refuses on. The rest are reported.
# ---------------------------------------------------------------------------
readonly MANIFEST="\
deploy/gcp/deploy-sa|input|yes|terraform runs as your own user; gcp-tf-up applies fully, then gcp-tf-handoff blames terraform outputs
deploy/gcp/bootstrap.tfvars|input|yes|gcp-tf-bootstrap has no inputs; two terraform-make-contract tests go red
deploy/gcp/platform.tfvars|input|no|the platform root has no inputs
deploy/gcp/sl-port-over-sandbox.tfvars|input|no|lane definitions absent (pass as GCP_TF_VAR_FILE; it is not auto-loaded)
deploy/gcp/preserve-baseline.json|output|no|preserve-check has no baseline to verify against
.keys|output|no|cosign signing refuses"

manifest_rows() { printf '%s\n' "$MANIFEST"; }

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# Handoffs are enumerated, not listed: one per environment key, and which keys
# exist is a property of the source checkout, not of this file.
source_handoffs() {
  [ -n "$SOURCE_CHECKOUT" ] || return 0
  local f
  for f in "${SOURCE_CHECKOUT}"/deploy/gcp/*.handoff.json; do
    [ -e "$f" ] || continue
    printf 'deploy/gcp/%s\n' "$(basename "$f")"
  done
}

# ---------------------------------------------------------------------------
# KUBESEC_AFM_ROOT: a worktree-resolution problem this script cannot copy away.
#
# Returns 0 when the default resolves nowhere from HERE but does resolve from the
# source checkout — i.e. exactly the worktree-induced case, not "you never cloned
# kubesec-afm", which is a different problem with a different fix.
# ---------------------------------------------------------------------------
afm_default_here() { printf '%s/../kubesec-afm\n' "$REPO_ROOT"; }
afm_from_source()  { [ -n "$SOURCE_CHECKOUT" ] && printf '%s/../kubesec-afm\n' "$SOURCE_CHECKOUT"; }

afm_broken_by_worktree() {
  [ -z "${KUBESEC_AFM_ROOT:-}" ] || return 1
  local here there
  here="$(afm_default_here)"
  there="$(afm_from_source || true)"
  [ ! -d "$here" ] || return 1
  [ -n "$there" ] && [ -d "$there" ]
}

afm_resolved_source() { (cd "$(afm_from_source)" && pwd -P); }

# ---------------------------------------------------------------------------
# Per-item state. Prints one of: ok | absent | differs | newer | nosource
# ---------------------------------------------------------------------------
item_state() {
  local rel="$1" src dst
  src="${SOURCE_CHECKOUT:-}/${rel}"
  dst="${REPO_ROOT}/${rel}"

  if [ ! -e "$dst" ]; then
    if [ -n "${SOURCE_CHECKOUT:-}" ] && [ -e "$src" ]; then printf 'absent\n'; else printf 'nosource\n'; fi
    return
  fi
  if [ -z "${SOURCE_CHECKOUT:-}" ] || [ ! -e "$src" ]; then printf 'ok\n'; return; fi
  if same_content "$src" "$dst"; then printf 'ok\n'; return; fi
  if [ "$dst" -nt "$src" ]; then printf 'newer\n'; else printf 'differs\n'; fi
}

same_content() {
  local a="$1" b="$2"
  if [ -d "$a" ] || [ -d "$b" ]; then
    [ -d "$a" ] && [ -d "$b" ] || return 1
    diff -qr "$a" "$b" >/dev/null 2>&1
  else
    cmp -s "$a" "$b"
  fi
}

# ---------------------------------------------------------------------------
# check — fail fast, name the real cause
# ---------------------------------------------------------------------------
cmd_check() {
  local problems=0 rel required state why

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rel="$(field "$row" 1)"; required="$(field "$row" 3)"; why="$(field "$row" 4)"
    [ "$required" = "yes" ] || continue
    if [ ! -e "${REPO_ROOT}/${rel}" ]; then
      problems=$((problems + 1))
      printf '\n  MISSING  %s\n' "$rel" >&2
      printf '           Consequence: %s\n' "$why" >&2
    fi
  done <<EOF
$(manifest_rows)
EOF

  # Extras this particular caller cannot run without. Same loop body, same two
  # printf lines, deliberately: the value of routing a caller's stricter
  # required-set through here rather than letting it check for itself is that
  # there is exactly ONE piece of code in this repo that decides what a missing
  # piece of untracked state looks like when it is reported.
  local abs
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rel="${row%%|*}"
    why="${row#*|}"
    # A bare path (no `|`) leaves `why` equal to the whole entry.
    [ "$why" != "$row" ] || why="required by the caller that ran this check"
    # Absolute entries are for state that lives outside the repo — KUBESEC_AFM_ROOT
    # is a separate clone, not a file under REPO_ROOT, and prefixing it would
    # produce a path that exists nowhere and a message naming it wrongly.
    case "$rel" in
      /*) abs="$rel" ;;
      *)  abs="${REPO_ROOT}/${rel}" ;;
    esac
    if [ ! -e "$abs" ]; then
      problems=$((problems + 1))
      printf '\n  MISSING  %s\n' "$rel" >&2
      printf '           Consequence: %s\n' "$why" >&2
    fi
  done <<EOF
${REQUIRE_ALSO:-}
EOF

  # A hand-off is required only when a caller has named the environment it needs.
  if [ -n "$ENV_KEY" ] && [ ! -e "${REPO_ROOT}/deploy/gcp/${ENV_KEY}.handoff.json" ]; then
    problems=$((problems + 1))
    printf '\n  MISSING  deploy/gcp/%s.handoff.json\n' "$ENV_KEY" >&2
    printf '           Consequence: the demo driver cannot tell which estate to talk to.\n' >&2
  fi

  # KUBESEC_AFM_ROOT is reported here but does NOT fail `check` by default, and
  # that split is deliberate. It is the same class of bug — a path that resolves
  # in the main checkout and nowhere else — so it belongs in the same preflight
  # rather than in a second one nobody runs. But it gates a DIFFERENT stage: the
  # AFM image build, not terraform. Failing `check` on it would make gcp-tf-up
  # refuse for a reason that has no bearing on the apply it is about to do, which
  # is how a guard earns a reputation for crying wolf and then gets bypassed.
  # Callers that genuinely need AFM ask for it with REQUIRE_AFM=1.
  if afm_broken_by_worktree; then
    if [ -n "${REQUIRE_AFM:-}" ]; then
      problems=$((problems + 1))
      printf '\n  UNRESOLVED  KUBESEC_AFM_ROOT\n' >&2
    else
      printf '\n  WARNING  KUBESEC_AFM_ROOT (does not block terraform; blocks the AFM stage)\n' >&2
    fi
    printf '           It defaults to <repo>/../kubesec-afm, which from THIS worktree is\n' >&2
    printf '             %s\n' "$(afm_default_here)" >&2
    printf '           and does not exist. It resolves only from the source checkout. The\n' >&2
    printf '           AFM stage aborts on this LATE, after building the image archive.\n' >&2
    printf '           This is not copyable — it is a separate repository. Export it:\n' >&2
    printf '             export KUBESEC_AFM_ROOT=%s\n' "$(afm_resolved_source)" >&2
  fi

  if [ "$problems" -eq 0 ]; then
    printf '%s: this worktree carries the untracked state it needs.\n' "$PROGNAME"
    return 0
  fi

  {
    printf '\n%s: refusing — this worktree is missing untracked operational state.\n\n' "$PROGNAME"
    printf '  These files are gitignored, so `git worktree add` did not bring them.\n'
    printf '  They are NOT a terraform problem and NOT a GCP IAM problem, which is what\n'
    printf '  their absence otherwise presents as.\n\n'
    printf '  Fix:  make gcp-tf-worktree-bootstrap\n'
    if [ -n "${SOURCE_CHECKOUT:-}" ]; then
      printf '        (copies from %s)\n' "$SOURCE_CHECKOUT"
    fi
    printf '\n'
  } >&2
  return 2
}

# ---------------------------------------------------------------------------
# status — report everything, decide nothing
# ---------------------------------------------------------------------------
cmd_status() {
  printf 'repo root:        %s\n' "$REPO_ROOT"
  printf 'linked worktree:  %s\n' "$(is_linked_worktree && echo yes || echo 'no (this is the main checkout)')"
  printf 'source checkout:  %s\n' "${SOURCE_CHECKOUT:-<undetermined>}"
  printf '\n%-46s %-8s %s\n' "ITEM" "STATE" "CLASS"
  local rel class row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rel="$(field "$row" 1)"; class="$(field "$row" 2)"
    printf '%-46s %-8s %s\n' "$rel" "$(item_state "$rel")" "$class"
  done <<EOF
$(manifest_rows)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%-46s %-8s %s\n' "$rel" "$(item_state "$rel")" "output"
  done <<EOF
$(source_handoffs)
EOF
  if afm_broken_by_worktree; then
    printf '\nKUBESEC_AFM_ROOT   unresolved from this worktree; export %s\n' "$(afm_resolved_source)"
  fi
}

# ---------------------------------------------------------------------------
# provision — plan, then act. Never half-apply.
# ---------------------------------------------------------------------------
place_one() {
  local rel="$1" class="$2" src dst
  src="${SOURCE_CHECKOUT}/${rel}"
  dst="${REPO_ROOT}/${rel}"

  mkdir -p "$(dirname "$dst")"

  if [ -n "$LINK" ] && [ "$class" = "input" ]; then
    rm -rf "$dst"
    ln -s "$src" "$dst"
    printf '  linked   %s\n' "$rel"
    return
  fi

  rm -rf "$dst"
  # -p preserves mode: .keys/cosign.key is 0600 and must stay that way.
  if [ -d "$src" ]; then cp -Rp "$src" "$dst"; else cp -p "$src" "$dst"; fi
  printf '  copied   %s\n' "$rel"
}

cmd_provision() {
  [ -n "${SOURCE_CHECKOUT:-}" ] ||
    die "cannot determine a source checkout; pass SOURCE_CHECKOUT=<path to the main checkout>"
  [ -d "$SOURCE_CHECKOUT" ] ||
    die "SOURCE_CHECKOUT=${SOURCE_CHECKOUT} is not a directory"

  local srcreal dstreal
  srcreal="$(cd "$SOURCE_CHECKOUT" && pwd -P)"
  dstreal="$(cd "$REPO_ROOT" && pwd -P)"
  [ "$srcreal" != "$dstreal" ] ||
    die "SOURCE_CHECKOUT and this worktree are the same directory (${dstreal}); nothing to do"

  if [ -n "$LINK" ]; then
    log "LINK=1: symlinking the 'input' class only. The 'output' class is copied"
    log "        regardless — gcp-tf-handoff and preserve-check --capture rewrite"
    log "        those paths, and a write through a symlink lands in ${srcreal}."
  fi

  # ---- plan ----------------------------------------------------------------
  local -a todo=() blocked=() skipped=()
  local row rel class required state

  add_plan() {
    local rel="$1" class="$2" required="$3" state
    state="$(item_state "$rel")"
    case "$state" in
      ok)       skipped+=("${rel} (already identical)") ;;
      absent|differs) todo+=("${rel}|${class}") ;;
      newer)
        if [ -n "$FORCE" ]; then
          todo+=("${rel}|${class}")
        else
          blocked+=("${rel} — the copy in this worktree is NEWER than the one in the source checkout")
        fi
        ;;
      nosource)
        if [ "$required" = "yes" ]; then
          blocked+=("${rel} — required, and absent from ${srcreal} too")
        else
          skipped+=("${rel} (not present in the source checkout)")
        fi
        ;;
    esac
  }

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rel="$(field "$row" 1)"; class="$(field "$row" 2)"; required="$(field "$row" 3)"
    add_plan "$rel" "$class" "$required"
  done <<EOF
$(manifest_rows)
EOF

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    add_plan "$rel" output no
  done <<EOF
$(source_handoffs)
EOF

  # ---- refuse, as a whole, before touching anything ------------------------
  if [ "${#blocked[@]}" -gt 0 ]; then
    {
      printf '\n%s: refusing to provision. Nothing has been written.\n\n' "$PROGNAME"
      local b
      for b in "${blocked[@]}"; do printf '  BLOCKED  %s\n' "$b"; done
      printf '\n  A partly-provisioned worktree is the failure this command exists to\n'
      printf '  prevent, so none of the other items were copied either.\n'
      printf '  Re-run with FORCE=1 to overwrite newer destinations.\n\n'
    } >&2
    return 2
  fi

  # ---- act ----------------------------------------------------------------
  if [ "${#todo[@]}" -eq 0 ]; then
    printf '%s: nothing to do — this worktree already matches %s.\n' "$PROGNAME" "$srcreal"
  else
    printf '%s: provisioning from %s\n' "$PROGNAME" "$srcreal"
    local entry
    for entry in "${todo[@]}"; do
      place_one "${entry%%|*}" "${entry##*|}"
    done
  fi

  local s
  for s in "${skipped[@]:-}"; do [ -n "$s" ] && printf '  skipped  %s\n' "$s"; done

  if afm_broken_by_worktree; then
    printf '\n%s: KUBESEC_AFM_ROOT is still unresolved and cannot be copied.\n' "$PROGNAME"
    printf '  It is a separate repository, not a file. Export it before any AFM stage:\n'
    printf '    export KUBESEC_AFM_ROOT=%s\n' "$(afm_resolved_source)"
  fi
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-check}"
  case "$cmd" in
    check)     cmd_check ;;
    status)    cmd_status ;;
    provision) cmd_provision ;;
    gate)
      # What the Makefile guard calls. A NO-OP outside a linked worktree, and
      # that is the whole point: a main checkout with no deploy-sa is a
      # legitimate, supported state (the Makefile warns and runs as the current
      # gcloud identity). Only a worktree gets the untracked state silently
      # stripped from underneath it, so only a worktree is refused.
      is_linked_worktree || exit 0
      cmd_check
      ;;
    -h|--help|help)
      # The header block, however long it is. A hardcoded line range silently
      # truncates the help the first time the header grows — which it just did.
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      ;;
    *) die "unknown command '${cmd}' (expected: check | status | provision)" ;;
  esac
}

main "$@"
