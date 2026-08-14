#!/usr/bin/env bats
# KEYS_DIR is absolute almost everywhere. Nothing may concatenate a prefix onto
# it.
#
# 72d0166 made KEYS_DIR resolve through `git rev-parse --git-common-dir` so that
# every worktree of a clone shares one signing key. That was right, but it
# changed the variable from always-relative to almost-always-absolute, and one
# caller had been walking back to the repo root by hand:
#
#   $(MAKE) -C d2-osramp-fleet bootstrap-local COSIGN_PUB=../$(KEYS_DIR)/cosign.pub
#
# which then produced
#
#   ..//home/ci/osramp-demo-ci-2/.keys/cosign.pub not found;
#     run 'make signing-keys' at the repo root
#
# The leading slash is swallowed by the concatenation. Both GCP CI lanes aborted
# on it before stage 1 — not a test failure, no summary.json, so the wrapper had
# nothing to report and both VMs suspended into a state indistinguishable from a
# clean pass.
#
# The error is worse than the outage. It names a file that exists and is valid,
# and it tells you to run `make signing-keys`, which had already succeeded two
# minutes earlier. Anyone following that instruction is sent away from the bug.
#
# This is the SECOND time this exact class shipped. 5d31ff6 swept for it, added
# keys_dir_abs() to scripts/lib/keys.sh and $(abspath …) to AUDIT_ANCHOR_KEYS,
# and wrote test/audit-anchor-keys-path.bats — but scoped all of it to the
# audit-anchor entry points and missed the identical concatenation 500 lines
# earlier. A guard aimed at one site does not cover a class, so this one is
# derived from the Makefile itself and covers every use.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  makefile="${repo_root}/Makefile"
}

@test "KEYSPATH no Makefile line concatenates a prefix onto \$(KEYS_DIR)" {
  # The signature of the bug is a path separator immediately before the
  # reference: `../$(KEYS_DIR)`, `foo/$(KEYS_DIR)`. Passing $(KEYS_DIR) bare, or
  # wrapped in $(abspath …), is correct and stays silent here.
  local offenders
  # Comment lines are skipped deliberately: this file and the Makefile both
  # SPELL the anti-pattern out to explain it, and a guard that fires on its own
  # documentation gets muted, which is worse than no guard at all.
  offenders="$(grep -vE '^[[:space:]]*#' "$makefile" | grep -nE '[^ 	="'"'"'(]/\$\(KEYS_DIR\)' || true)"

  if [ -n "$offenders" ]; then
    echo "A prefix is concatenated onto \$(KEYS_DIR). KEYS_DIR is absolute in" >&2
    echo "any tree with a .git, which is every checkout, every worktree, AND the" >&2
    echo "CI VM (vm-pipeline.sh runs git init after extracting the tarball)." >&2
    echo "Use \$(abspath \$(KEYS_DIR)) instead, as AUDIT_ANCHOR_KEYS does:" >&2
    echo "$offenders" >&2
    return 1
  fi
}

@test "KEYSPATH no shell script concatenates a prefix onto \${KEYS_DIR}" {
  # Same class on the shell side. keys_dir_abs() in scripts/lib/keys.sh exists
  # for callers that must change directory; nothing should hand-roll a prefix.
  local offenders
  offenders="$(grep -rnE '[^ 	="'"'"'$]/\$\{?KEYS_DIR\}?' \
    --include='*.sh' "${repo_root}/scripts" | grep -vE ':[[:space:]]*#' || true)"

  if [ -n "$offenders" ]; then
    echo "A prefix is concatenated onto \${KEYS_DIR}; use keys_dir_abs instead:" >&2
    echo "$offenders" >&2
    return 1
  fi
}

# The two above read the source. This one reads what make actually expands, so a
# concatenation written in a form the patterns do not anticipate still fails.
@test "KEYSPATH bootstrap-local expands to a path with no doubled slash" {
  local expanded
  # `make -n` echoes recipe COMMENT lines too, and the recipe explains this very
  # bug, so filter them out before pattern-matching the commands.
  expanded="$(cd "$repo_root" && make -n bootstrap-local 2>/dev/null \
    | grep -vE '^[[:space:]]*#' || true)"
  [ -n "$expanded" ] || skip "make -n bootstrap-local produced nothing"

  # `..//abs/path` is the exact shape that aborted both lanes.
  if printf '%s' "$expanded" | grep -qE '\.\./+/'; then
    echo "bootstrap-local expands a '../' onto an absolute path:" >&2
    printf '%s\n' "$expanded" | grep -E '\.\./+/' >&2
    return 1
  fi

  # Any doubled slash mid-path is the same defect wearing a different prefix.
  if printf '%s' "$expanded" | grep -oE '[A-Za-z0-9_.-]+=[^ ]*//[^ ]*' | grep -q .; then
    echo "bootstrap-local expands an argument containing a doubled slash:" >&2
    printf '%s' "$expanded" | grep -oE '[A-Za-z0-9_.-]+=[^ ]*//[^ ]*' >&2
    return 1
  fi
}

@test "KEYSPATH the COSIGN_PUB handed to the fleet sub-make resolves to a real file" {
  # The end-to-end statement of intent: whatever path is constructed, the file it
  # names must be the one `make signing-keys` created. The assertion this guards
  # lives at d2-osramp-fleet/Makefile:29 and was reached on every CI run.
  local pub
  pub="$(cd "$repo_root" && make -n bootstrap-local 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | grep -oE 'COSIGN_PUB=[^ ]+' | head -1 | cut -d= -f2- || true)"
  [ -n "$pub" ] || skip "no COSIGN_PUB in the bootstrap-local expansion"

  # The sub-make runs with -C d2-osramp-fleet, so resolve relative paths there —
  # exactly as the assertion being guarded does.
  case "$pub" in
    /*) [ -f "$pub" ] || { echo "COSIGN_PUB=$pub does not exist" >&2; return 1; } ;;
    *)  [ -f "${repo_root}/d2-osramp-fleet/${pub}" ] \
          || { echo "COSIGN_PUB=$pub does not resolve from d2-osramp-fleet/" >&2; return 1; } ;;
  esac
}
