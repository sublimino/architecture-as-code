#!/usr/bin/env bats
# d2-signalloom/test/env-file.bats — .env resolves from the MAIN checkout
#
# The bug: `.env` is gitignored, so it is never checked out into a linked
# worktree. Every .env reader in this repo resolved it against $PWD, so run from
# a worktree they found nothing, took the "no credentials configured" branch,
# and exited 0 — reporting no key while the operator's key sat in the main
# checkout the whole time.
#
# Tests build real git worktrees rather than mocking git, because the entire
# defect is a disagreement between two directories about one file. A mocked
# `git rev-parse` would assert my belief about git, not git's behaviour.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="${REPO_ROOT}/scripts/lib/env-file.sh"
  [ -f "$LIB" ]

  # A real repo with a real linked worktree, built fresh per test.
  MAIN="${BATS_TEST_TMPDIR}/main"
  WT="${BATS_TEST_TMPDIR}/wt"
  mkdir -p "$MAIN"
  (
    cd "$MAIN"
    git init -q -b main .
    git config user.email t@t; git config user.name t
    printf '.env\n' >.gitignore
    printf 'seed\n' >file.txt
    git add -A
    git commit -q -m init --no-gpg-sign
    git worktree add -q "$WT" -b side >/dev/null 2>&1
  )
  printf 'ANTHROPIC_API_KEY=from-the-main-checkout\nOTHER=xyz\n' >"${MAIN}/.env"

  unset SIGNALLOOM_ENV_FILE ANTHROPIC_API_KEY OTHER
}

# Runs a snippet with the library sourced, in a given directory.
in_dir() {
  local dir="$1"; shift
  ( cd "$dir" && . "$LIB" && eval "$*" )
}

@test "env-file: .env genuinely is absent from the linked worktree" {
  # The premise of everything below. If this ever stops being true the rest of
  # this file is testing a problem that no longer exists.
  [ -f "${MAIN}/.env" ]
  [ ! -f "${WT}/.env" ]
}

@test "env-file: resolves to the main checkout when run from the main checkout" {
  run in_dir "$MAIN" 'signalloom_env_file'
  [ "$status" -eq 0 ]
  [ "$output" = "${MAIN}/.env" ]
}

@test "env-file: resolves to the MAIN checkout when run from a linked worktree" {
  # The whole point. A relative-path or \$PWD-based resolver returns
  # "${WT}/.env", which does not exist.
  run in_dir "$WT" 'signalloom_env_file'
  [ "$status" -eq 0 ]
  [ "$output" = "${MAIN}/.env" ]
}

@test "env-file: the path returned from the main checkout is absolute" {
  # `git rev-parse --git-common-dir` returns a RELATIVE ".git" from the main
  # worktree root. Un-normalised, that yields "./.env" — which happens to work
  # from that directory and breaks the moment anything cd's.
  run in_dir "$MAIN" 'signalloom_env_file'
  [[ "$output" == /* ]]
}

@test "env-file: loads the key from the main checkout while sitting in a worktree" {
  run in_dir "$WT" 'signalloom_load_env; printf "%s" "${ANTHROPIC_API_KEY:-EMPTY}"'
  [ "$status" -eq 0 ]
  [ "$output" = "from-the-main-checkout" ]
}

@test "env-file: reports that it loaded, and from where" {
  run in_dir "$WT" 'signalloom_load_env; printf "%s %s" "$SIGNALLOOM_ENV_LOADED" "$SIGNALLOOM_ENV_FILE_RESOLVED"'
  [ "$output" = "1 ${MAIN}/.env" ]
}

@test "env-file: SIGNALLOOM_ENV_FILE overrides everything" {
  # CI and the GCP lanes have no git repo in play.
  printf 'ANTHROPIC_API_KEY=from-the-override\n' >"${BATS_TEST_TMPDIR}/elsewhere.env"
  run env SIGNALLOOM_ENV_FILE="${BATS_TEST_TMPDIR}/elsewhere.env" \
      bash -c "cd '$WT' && . '$LIB' && signalloom_load_env && printf '%s' \"\$ANTHROPIC_API_KEY\""
  [ "$output" = "from-the-override" ]
}

@test "env-file: an already-set environment variable wins over the file" {
  # Documented deviation from the previous `set -a; . ./.env` behaviour, which
  # clobbered the environment. `ANTHROPIC_API_KEY=x make …` must do what it says.
  run env ANTHROPIC_API_KEY=from-the-environment \
      bash -c "cd '$WT' && . '$LIB' && signalloom_load_env && printf '%s' \"\$ANTHROPIC_API_KEY\""
  [ "$output" = "from-the-environment" ]
}

@test "env-file: a variable absent from the environment still comes from the file" {
  # The other half of the precedence rule — without this, "environment wins"
  # could be implemented as "the file is ignored" and still pass the test above.
  run env ANTHROPIC_API_KEY=from-the-environment \
      bash -c "cd '$WT' && . '$LIB' && signalloom_load_env && printf '%s' \"\$OTHER\""
  [ "$output" = "xyz" ]
}

@test "env-file: an EMPTY environment variable does not win over the file" {
  # `export ANTHROPIC_API_KEY=` is the shape a half-written shell profile
  # produces. Treating it as "set" would silently defeat a correct .env.
  run env ANTHROPIC_API_KEY= \
      bash -c "cd '$WT' && . '$LIB' && signalloom_load_env && printf '%s' \"\$ANTHROPIC_API_KEY\""
  [ "$output" = "from-the-main-checkout" ]
}

@test "env-file: a missing .env is not an error" {
  rm -f "${MAIN}/.env"
  run in_dir "$WT" 'signalloom_load_env; printf "%s" "$SIGNALLOOM_ENV_LOADED"'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "env-file: outside a git repo it degrades to \$PWD rather than exploding" {
  outside="${BATS_TEST_TMPDIR}/notgit"
  mkdir -p "$outside"
  printf 'ANTHROPIC_API_KEY=from-cwd\n' >"${outside}/.env"
  # GIT_CEILING_DIRECTORIES stops git walking up into any enclosing repo.
  run env GIT_CEILING_DIRECTORIES="${BATS_TEST_TMPDIR}" \
      bash -c "cd '$outside' && . '$LIB' && signalloom_load_env && printf '%s' \"\$ANTHROPIC_API_KEY\""
  [ "$status" -eq 0 ]
  [ "$output" = "from-cwd" ]
}

@test "env-file: sourcing the file does not leak values into an xtrace" {
  # `bash -x` over a script that sources credentials prints every one of them.
  run bash -xc "cd '$WT' && . '$LIB' && signalloom_load_env; true"
  leaked="$(printf '%s' "$output" | grep -F 'from-the-main-checkout' || true)"
  [ -z "$leaked" ]
}

@test "env-file: xtrace is restored after loading, not left disabled" {
  # The shield must be a shield, not an off switch — silently disabling xtrace
  # for the rest of a debugging session is its own hard-to-spot defect.
  run bash -xc "cd '$WT' && . '$LIB' && signalloom_load_env; echo MARKER_AFTER"
  [[ "$output" == *"+ echo MARKER_AFTER"* ]]
}

@test "env-file: provenance distinguishes the file from the environment" {
  run in_dir "$WT" 'signalloom_load_env; signalloom_env_provenance ANTHROPIC_API_KEY'
  [ "$output" = "${MAIN}/.env" ]

  run env ANTHROPIC_API_KEY=from-the-environment \
      bash -c "cd '$WT' && . '$LIB' && signalloom_load_env && signalloom_env_provenance ANTHROPIC_API_KEY"
  [ "$output" = "environment" ]
}

@test "env-file: provenance says unset when there is no key anywhere" {
  rm -f "${MAIN}/.env"
  run in_dir "$WT" 'signalloom_load_env; signalloom_env_provenance ANTHROPIC_API_KEY'
  [ "$output" = "unset" ]
}

@test "env-file: provenance does not leak the value into an xtrace" {
  # signalloom_env_provenance tests the VALUE for emptiness, and `[ -z "$v" ]`
  # under `bash -x` prints it. Caught by the credential suite's leak test after
  # provenance reporting was added — the shield in load_env did not cover it,
  # because this is a different function expanding the same variable.
  run bash -xc "cd '$WT' && . '$LIB' && signalloom_load_env && signalloom_env_provenance ANTHROPIC_API_KEY"
  leaked="$(printf '%s' "$output" | grep -F 'from-the-main-checkout' || true)"
  [ -z "$leaked" ]
}

@test "env-file: provenance still restores xtrace afterwards" {
  run bash -xc "cd '$WT' && . '$LIB' && signalloom_load_env && signalloom_env_provenance ANTHROPIC_API_KEY >/dev/null; echo MARKER_AFTER"
  [[ "$output" == *"+ echo MARKER_AFTER"* ]]
}
