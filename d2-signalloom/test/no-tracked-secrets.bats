#!/usr/bin/env bats
# d2-signalloom/test/no-tracked-secrets.bats — no API key may be tracked by git
#
# Andy's constraint, verbatim: the key may exist ONLY in local files that are
# untracked. This makes that enforceable rather than a matter of discipline.
#
# TRACKED, not "present on disk". `.env` containing a real key is the intended
# state and lives in the working directory of the main checkout; a build that
# failed because of it would be wrong and would train people to disable the
# check. The subject is `git ls-files` — what a commit would carry.
#
# Two ways a guard like this quietly stops guarding, both of which have already
# bitten this branch once:
#   - it matches its own source, so it can never go green and gets deleted;
#   - its pattern is wrong, so it matches nothing and reads as "clean".
# Both are tested below rather than assumed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SELF="$(basename "$BATS_TEST_FILENAME")"

  # An Anthropic key is `sk-ant-` followed by a long run of [A-Za-z0-9_-].
  # Andy's live key is 108 characters. The 40-character floor is well below a
  # real key and well above any plausible prose or placeholder, which is what
  # lets test fixtures coexist with the guard: a fixture that breaks the
  # character run early (with a '.') cannot match, a real key always can.
  KEY_SHAPE='sk-ant-[A-Za-z0-9_-]{40,}'
}

# The subject of every test below. Kept in one function so the guard and its
# own arming test cannot drift apart into "correct comment, incorrect code".
tracked_key_hits() {
  local root="$1"
  ( cd "$root" && git ls-files -z 2>/dev/null \
      | xargs -0 -r grep -lE "$KEY_SHAPE" 2>/dev/null \
      | grep -vF "$SELF" || true )
}

@test "no-tracked-secrets: no tracked file carries an Anthropic API key" {
  hits="$(tracked_key_hits "$REPO_ROOT")"
  [ -z "$hits" ] || {
    echo "An Anthropic API key shape appears in tracked file(s):"
    echo "$hits"
    echo ""
    echo "The key belongs in .env (gitignored) — never in a tracked file."
    return 1
  }
}

@test "no-tracked-secrets: no tracked file carries an OpenAI-shaped key either" {
  # Cheap to add, and the same mistake with a different provider is the same
  # incident. Scoped tightly enough not to fire on prose.
  hits="$( cd "$REPO_ROOT" && git ls-files -z 2>/dev/null \
             | xargs -0 -r grep -lE 'sk-proj-[A-Za-z0-9_-]{40,}' 2>/dev/null \
             | grep -vF "$SELF" || true )"
  [ -z "$hits" ]
}

@test "no-tracked-secrets: the guard is armed — a planted real-shaped key is caught" {
  # Without this, a broken pattern and a clean tree are indistinguishable: both
  # print nothing and pass. Plants a key of realistic shape in a real git repo,
  # because the guard's subject is `git ls-files` and an untracked plant would
  # prove nothing.
  scratch="${BATS_TEST_TMPDIR}/armed"
  mkdir -p "$scratch"
  ( cd "$scratch" && git init -q . && git config user.email t@t && git config user.name t )
  printf 'apiKey: "sk-ant-api03-%s"\n' "$(printf 'A%.0s' {1..95})" >"${scratch}/leak.yaml"
  ( cd "$scratch" && git add -A )

  hits="$(tracked_key_hits "$scratch")"
  [ -n "$hits" ] || {
    echo "the guard did NOT catch a planted key — its pattern is broken,"
    echo "which means every green run above meant 'unsearchable', not 'clean'"
    return 1
  }
  [[ "$hits" == *"leak.yaml"* ]]
}

@test "no-tracked-secrets: an untracked file holding a key is NOT flagged" {
  # .env is exactly this case and is the intended home for the key. If the
  # guard fired here it would be wrong every single day and would be switched
  # off, which is worse than not having it.
  scratch="${BATS_TEST_TMPDIR}/untracked"
  mkdir -p "$scratch"
  ( cd "$scratch" && git init -q . && git config user.email t@t && git config user.name t )
  printf 'ANTHROPIC_API_KEY=sk-ant-api03-%s\n' "$(printf 'A%.0s' {1..95})" >"${scratch}/.env"
  printf '.env\n' >"${scratch}/.gitignore"
  ( cd "$scratch" && git add .gitignore )

  hits="$(tracked_key_hits "$scratch")"
  [ -z "$hits" ] || {
    echo "the guard flagged an UNTRACKED file: $hits"
    return 1
  }
}

@test "no-tracked-secrets: the empty .env.example placeholder does not false-positive" {
  # .env.example is tracked and must stay tracked — it is how this repo makes a
  # required key discoverable. An empty placeholder must never trip the guard.
  scratch="${BATS_TEST_TMPDIR}/placeholder"
  mkdir -p "$scratch"
  ( cd "$scratch" && git init -q . && git config user.email t@t && git config user.name t )
  printf '# Anthropic key for the kagent agents.\nANTHROPIC_API_KEY=\n' >"${scratch}/.env.example"
  ( cd "$scratch" && git add -A )

  hits="$(tracked_key_hits "$scratch")"
  [ -z "$hits" ]
}

@test "no-tracked-secrets: this file excludes itself, and the exclusion is real" {
  # This file necessarily contains the pattern it hunts, so it must exclude
  # itself — but a self-exclusion is also the classic way a guard is silently
  # neutered. Proving the exclusion is narrow: without the filter this file IS
  # matched, with it nothing else is lost.
  raw="$( cd "$REPO_ROOT" && git ls-files -z | xargs -0 -r grep -lE "$KEY_SHAPE" 2>/dev/null || true )"
  filtered="$(tracked_key_hits "$REPO_ROOT")"

  # Whatever the raw scan finds, the only thing the filter may remove is this file.
  removed="$(comm -23 <(printf '%s\n' "$raw" | sort -u) <(printf '%s\n' "$filtered" | sort -u) | grep -v '^$' || true)"
  [ -z "$removed" ] || [ "$removed" = "d2-signalloom/test/${SELF}" ] || {
    echo "the self-exclusion is removing more than this file: $removed"
    return 1
  }
}

@test "no-tracked-secrets: .env is ignored by git and is not tracked" {
  # The ignore rule is the thing that keeps the key out of the tree in the
  # first place. An ignore rule nobody tested is not a guarantee.
  #
  # Asserted against the MAIN checkout: .env is untracked, so it only exists
  # there, and `git check-ignore` in a worktree would be answering about a file
  # that is not the one the operator filled in.
  main_root="$( cd "$REPO_ROOT" && dirname "$(git rev-parse --path-format=absolute --git-common-dir)" )"

  run git -C "$main_root" check-ignore -v .env
  [ "$status" -eq 0 ]
  [[ "$output" == *".gitignore"* ]]

  run git -C "$main_root" ls-files --error-unmatch .env
  [ "$status" -ne 0 ]
}
