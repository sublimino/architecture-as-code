#!/usr/bin/env bats
#
# @id      signal-ingest-image-tag
# @target  scripts/signal-ingest-image-tag.sh, d2-signalloom/apps/signal-ingest/internal/imagetag
#
# signal-ingest's tag names the committed source, with source-id.sh's
# semantics (test/source-id-tracked.bats): go list reports the .go files on
# disk, so an untracked or gitignored .go file in a package directory was
# hashed into the tag and compiled into the image, and the guard (no
# --ignored) let an ignored one through. Now the tag hashes tracked inputs
# only, and the guard refuses modified, untracked and ignored inputs.
#
# Runs in a shared clone of this tree (objects borrowed, nothing written to
# this repository) holding HEAD plus this worktree's uncommitted tracked edits,
# committed there, so it exercises the code under test and starts clean.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  c="$BATS_TEST_TMPDIR/repo"
  git clone -q --shared --no-checkout "$repo_root" "$c"
  git -C "$c" checkout -q --detach "$(git -C "$repo_root" rev-parse HEAD)"
  local f
  git -C "$repo_root" diff --name-only -z HEAD | while IFS= read -r -d '' f; do
    if [ -e "$repo_root/$f" ]; then cp -p "$repo_root/$f" "$c/$f"; else rm -f "$c/$f"; fi
  done
  git -C "$c" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -am "worktree overlay"
  mod="$c/d2-signalloom/apps/signal-ingest"
  if [ "${GOPATH:-}" = "/usr/local/src/gocode" ] || [ -z "${GOPATH:-}" ]; then
    export GOPATH=/tmp/gopath
  fi
  export GOCACHE="${GOCACHE:-/tmp/gocache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" GONOSUMDB="*"
  mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"
  export GOFLAGS="${GOFLAGS:-}" CGO_ENABLED=0
}

tag() { (cd "$c/d2-signalloom" && ../scripts/signal-ingest-image-tag.sh); }
raw_tag() { (cd "$mod" && go run ./cmd/image-tag); }

@test "clean: the guard passes and prints the tag" {
  run tag
  [ "$status" -eq 0 ] && [[ "$output" =~ ^src-[0-9a-f]{16}$ ]] || { echo "status=$status $output"; return 1; }
}

@test "an ignored .go file the build would compile: tag unchanged, guard refuses" {
  local before
  before="$(raw_tag)"
  printf 'package main\n' >"$mod/zz_probe_ignored.go"
  printf 'zz_probe_ignored.go\n' >>"$c/.git/info/exclude" # ignored, without touching tracked .gitignore
  git -C "$c" check-ignore -q d2-signalloom/apps/signal-ingest/zz_probe_ignored.go
  rg -q -e '^apps/signal-ingest/zz_probe_ignored\.go$' <<<"$(cd "$mod" && go run ./cmd/image-tag -inputs)" # go build compiles it
  [ "$(raw_tag)" = "$before" ] || { echo "the ignored file moved the tag"; return 1; }
  run tag
  [ "$status" -ne 0 ] && [[ "$output" == *'!! d2-signalloom/apps/signal-ingest/zz_probe_ignored.go'* ]] || { echo "guard did not refuse: status=$status $output"; return 1; }
}

@test "an untracked .go file: tag unchanged, guard refuses" {
  local before
  before="$(raw_tag)"
  printf 'package main\n' >"$mod/zz_probe_untracked.go"
  [ "$(raw_tag)" = "$before" ] || { echo "the untracked file moved the tag"; return 1; }
  run tag
  [ "$status" -ne 0 ] && [[ "$output" == *'?? d2-signalloom/apps/signal-ingest/zz_probe_untracked.go'* ]] || { echo "status=$status $output"; return 1; }
}

@test "a tracked edit moves the tag and the guard refuses it" {
  local before
  before="$(raw_tag)"
  printf '\n// edited\n' >>"$mod/main.go"
  [ "$(raw_tag)" != "$before" ] || { echo "a tracked edit did not move the tag"; return 1; }
  run tag
  [ "$status" -ne 0 ] && [[ "$output" == *'signal-ingest/main.go'* ]] || { echo "status=$status $output"; return 1; }
}

@test "the umask of a checkout does not move the tag" {
  local here other
  here="$(raw_tag)"
  other="$BATS_TEST_TMPDIR/repo022"
  (umask 022 && git clone -q --shared "$c" "$other")
  [ "$(cd "$other/d2-signalloom/apps/signal-ingest" && go run ./cmd/image-tag)" = "$here" ]
}
