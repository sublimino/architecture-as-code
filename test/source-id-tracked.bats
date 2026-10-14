#!/usr/bin/env bats
#
# @id      source-id-tracked
# @target  scripts/lib/source-id.sh, d2-signalloom/Makefile (sentinel-image-source-id, sentinel-image-tag)
#
# An image fingerprint names exactly the committed source, and the dirty
# guard refuses whatever else would enter the build context.
#
# 2026-10-03: two checkouts of the same commit disagreed on the sentinel tag
# (src-b428555d307e vs src-b23c561661a5). One held a gitignored build artefact,
# apps/signalloom-warden/bpf/sentinel_probe.o, which source_id_hash_paths hashed
# (it tarred the directories on disk) while sentinel-image-tag's guard
# (`git status --porcelain --untracked-files=all`, no --ignored) never saw it.
# A wrong pin was committed from that tree. The file was also in the docker
# build context, so it would have shipped under a tag claiming committed
# source.
#
# Now: the fingerprint hashes `git ls-files` (tracked files, their on-disk
# content) under the inputs, so ignored and untracked files cannot move it;
# the guard (source_id_dirty_inputs) also lists ignored files, so it refuses
# them. Which files are "ignored" depends on each machine's global excludes
# (*.o is ignored here only by ~/.gitignore_global); tracked-only hashing does
# not, and the guard refuses the file either way (`!!` or `??`).

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  # shellcheck source=../scripts/lib/source-id.sh
  source "$repo_root/scripts/lib/source-id.sh"
  fx="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$fx/app/src"
  git -C "$fx" init -q
  git -C "$fx" config user.email t@example.invalid
  git -C "$fx" config user.name t
  git -C "$fx" config core.excludesFile /dev/null # this machine's global excludes must not decide
  git -C "$fx" config commit.gpgsign false # a fixture commit must never reach for a signing key
  printf 'build/\n*.cache\n' >"$fx/.gitignore"
  printf 'package main\n' >"$fx/app/src/main.go"
  printf 'v1\n' >"$fx/app/VERSION"
  git -C "$fx" add -A
  git -C "$fx" commit -q -m init
}

@test "an ignored file under a hashed path leaves the fingerprint unchanged" {
  local before after
  before="$(source_id_hash_paths "$fx" app)"
  mkdir -p "$fx/app/build"
  printf 'artefact\n' >"$fx/app/build/probe.o"
  printf 'x\n' >"$fx/app/src/go.cache"
  git -C "$fx" check-ignore -q app/build/probe.o
  git -C "$fx" check-ignore -q app/src/go.cache
  after="$(source_id_hash_paths "$fx" app)"
  [ -n "$before" ] && [ "$before" = "$after" ]
}

@test "an untracked file leaves the fingerprint unchanged (the guard refuses it instead)" {
  local before
  before="$(source_id_hash_paths "$fx" app)"
  printf 'new\n' >"$fx/app/src/new.go"
  [ "$(source_id_hash_paths "$fx" app)" = "$before" ]
}

# The deployed-staleness fingerprints (source_id_for) have no dirty guard: a
# new source file ships the moment it exists, so it must move them; an
# ignored artefact still must not.
@test "staleness mode: a new untracked source file moves the fingerprint, an ignored one does not" {
  local before
  before="$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_paths "$fx" app)"
  mkdir -p "$fx/app/build" && printf 'artefact\n' >"$fx/app/build/probe.o"
  [ "$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_paths "$fx" app)" = "$before" ]
  printf 'new\n' >"$fx/app/src/new.go"
  [ "$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_paths "$fx" app)" != "$before" ]
}

@test "a tracked edit, or a tracked deletion, moves the fingerprint" {
  local before
  before="$(source_id_hash_paths "$fx" app)"
  printf 'package main // edited\n' >"$fx/app/src/main.go"
  local edited
  edited="$(source_id_hash_paths "$fx" app)"
  [ "$edited" != "$before" ]
  rm "$fx/app/VERSION"
  local deleted
  deleted="$(source_id_hash_paths "$fx" app)"
  [ -n "$deleted" ] && [ "$deleted" != "$edited" ]
}

@test "the fingerprint is the same in a fresh clone of the same commit" {
  local here clone
  mkdir -p "$fx/app/build" && printf 'artefact\n' >"$fx/app/build/probe.o"
  here="$(source_id_hash_paths "$fx" app)"
  git clone -q "$fx" "$BATS_TEST_TMPDIR/clone"
  clone="$(source_id_hash_paths "$BATS_TEST_TMPDIR/clone" app)"
  [ "$here" = "$clone" ]
}

# Git records only the executable bit. Modes beyond it come from the umask of
# whoever wrote the file (a fresh checkout under umask 0002 makes 664; the
# bpf2go container wrote the committed probe objects 644), so hashing them
# made the same commit fingerprint differently per checkout -- measured
# 2026-10-03, src-03d7750d795e vs src-2552a03be825 on one sentinel tree.
@test "permission bits git does not track leave the fingerprint unchanged; the executable bit moves it" {
  local before
  chmod 664 "$fx/app/VERSION"
  before="$(source_id_hash_paths "$fx" app)"
  chmod 600 "$fx/app/VERSION"
  [ "$(source_id_hash_paths "$fx" app)" = "$before" ] || { echo "a umask difference moved the fingerprint"; return 1; }
  chmod 644 "$fx/app/VERSION"
  [ "$(source_id_hash_paths "$fx" app)" = "$before" ]
  chmod 755 "$fx/app/VERSION"
  [ "$(source_id_hash_paths "$fx" app)" != "$before" ] || { echo "the executable bit (which git tracks) did not move it"; return 1; }
}

@test "tracked files a workload's .dockerignore excludes do not move its fingerprint" {
  mkdir -p "$fx/app/.astro"
  printf 'generated v1\n' >"$fx/app/.astro/types.d.ts"
  git -C "$fx" add -A && git -C "$fx" commit -q -m astro
  local before
  before="$(source_id_hash_files "$fx" '^app/\.astro/' app)"
  printf 'generated v2\n' >"$fx/app/.astro/types.d.ts"
  [ "$(source_id_hash_files "$fx" '^app/\.astro/' app)" = "$before" ]
  printf 'v2\n' >"$fx/app/VERSION"
  [ "$(source_id_hash_files "$fx" '^app/\.astro/' app)" != "$before" ]
}

@test "docs fingerprint ignores engineering build outputs but includes engineering source" {
  local app="$fx/d2-signalloom/apps/docs-signalloom" before
  mkdir -p "$app/dev-docs/.astro" "$app/dist-dev-docs" "$app/dev-docs/src/content/docs"
  printf 'cache v1\n' >"$app/dev-docs/.astro/types.d.ts"
  printf 'output v1\n' >"$app/dist-dev-docs/index.html"
  printf 'source v1\n' >"$app/dev-docs/src/content/docs/index.md"
  git -C "$fx" add -A && git -C "$fx" commit -q -m docs
  before="$(SOURCE_ID_REPO_ROOT="$fx" source_id_for docs-signalloom)"
  printf 'cache v2\n' >"$app/dev-docs/.astro/types.d.ts"
  printf 'output v2\n' >"$app/dist-dev-docs/index.html"
  [ "$(SOURCE_ID_REPO_ROOT="$fx" source_id_for docs-signalloom)" = "$before" ]
  printf 'source v2\n' >"$app/dev-docs/src/content/docs/index.md"
  [ "$(SOURCE_ID_REPO_ROOT="$fx" source_id_for docs-signalloom)" != "$before" ]
}

@test "outside a git repository, or with nothing tracked, there is no fingerprint" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/app" && printf 'x\n' >"$BATS_TEST_TMPDIR/plain/app/f"
  run source_id_hash_paths "$BATS_TEST_TMPDIR/plain" app
  [ "$status" -ne 0 ] && ! [[ "$output" =~ (^|$'\n')[0-9a-f]{64}($|$'\n') ]] || { echo "status=$status output=$output"; return 1; }
  mkdir -p "$fx/untracked-only" && printf 'x\n' >"$fx/untracked-only/f"
  run source_id_hash_paths "$fx" untracked-only
  [ "$status" -ne 0 ] || { echo "hashed an empty set: $output"; return 1; }
}

# A file tar cannot read must fail the fingerprint, not drop out of it.
@test "a tracked file that cannot be read fails the fingerprint instead of hashing a partial archive" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  chmod 000 "$fx/app/VERSION"
  run source_id_hash_paths "$fx" app
  chmod 644 "$fx/app/VERSION"
  [ "$status" -ne 0 ] && ! [[ "$output" =~ (^|$'\n')[0-9a-f]{64}($|$'\n') ]] || { echo "status=$status output=$output"; return 1; }
}

@test "the dirty guard lists ignored, untracked and modified inputs, and nothing when clean" {
  run source_id_dirty_inputs "$fx" app
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "clean tree: status=$status output=$output"; return 1; }
  mkdir -p "$fx/app/build" && printf 'artefact\n' >"$fx/app/build/probe.o"
  run source_id_dirty_inputs "$fx" app
  [[ "$output" == *'!! app/build/'* ]] || { echo "ignored file not refused: $output"; return 1; }
  rm -r "$fx/app/build"
  printf 'new\n' >"$fx/app/src/new.go"
  run source_id_dirty_inputs "$fx" app
  [[ "$output" == *'?? app/src/new.go'* ]] || { echo "untracked file not refused: $output"; return 1; }
  rm "$fx/app/src/new.go"
  printf 'package main // edited\n' >"$fx/app/src/main.go"
  run source_id_dirty_inputs "$fx" app
  [[ "$output" == *'app/src/main.go'* ]] || { echo "modified file not refused: $output"; return 1; }
}

@test "the dirty guard fails closed outside a git repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/app"
  run source_id_dirty_inputs "$BATS_TEST_TMPDIR/plain" app
  [ "$status" -ne 0 ]
}

# The real image, in a shared clone (objects borrowed, nothing written to this
# repository) holding this worktree's tracked state committed: HEAD plus any
# uncommitted tracked edits (this change's own library and Makefile, before it
# is committed). Untracked and ignored files of the worktree stay behind, so
# the clone starts clean and each test adds exactly the file it is about.
sentinel_clone() {
  local c="$BATS_TEST_TMPDIR/repo" f
  git clone -q --shared --no-checkout "$repo_root" "$c"
  git -C "$c" checkout -q --detach "$(git -C "$repo_root" rev-parse HEAD)"
  git -C "$repo_root" diff --name-only -z HEAD | while IFS= read -r -d '' f; do
    if [ -e "$repo_root/$f" ]; then cp -p "$repo_root/$f" "$c/$f"; else rm -f "$c/$f"; fi
  done
  git -C "$c" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -am "worktree overlay"
  printf '%s' "$c"
}

@test "sentinel: an ignored build artefact leaves the tag unchanged and the guard refuses" {
  local c id_before id_after sentinel_app
  c="$(sentinel_clone)"
  if [ -d "$c/d2-signalloom/apps/signalloom-warden/bpf" ]; then
    sentinel_app="$c/d2-signalloom/apps/signalloom-warden"
  else
    sentinel_app="$c/d2-signalloom/apps/stun-sentinel"
  fi
  id_before="$(make -s -C "$c/d2-signalloom" sentinel-image-tag)"
  [[ "$id_before" == src-* ]]
  printf 'stale bytecode\n' >"$sentinel_app/bpf/sentinel_probe.o"
  id_after="$(make -s -C "$c/d2-signalloom" sentinel-image-source-id)"
  [ "$id_after" = "$id_before" ] || { echo "source id moved: $id_before -> $id_after"; return 1; }
  run make -s -C "$c/d2-signalloom" sentinel-image-tag
  [ "$status" -ne 0 ] && [[ "$output" == *"sentinel_probe.o"* ]] || { echo "guard did not refuse: status=$status $output"; return 1; }
}

@test "sentinel: a tracked edit moves the source id and the guard refuses it" {
  local c before sentinel_app
  c="$(sentinel_clone)"
  if [ -d "$c/d2-signalloom/apps/signalloom-warden/pkg/correlator" ]; then
    sentinel_app="$c/d2-signalloom/apps/signalloom-warden"
  else
    sentinel_app="$c/d2-signalloom/apps/stun-sentinel"
  fi
  before="$(make -s -C "$c/d2-signalloom" sentinel-image-source-id)"
  printf '\n// edited\n' >>"$sentinel_app/pkg/correlator/runtime_lookup.go"
  [ "$(make -s -C "$c/d2-signalloom" sentinel-image-source-id)" != "$before" ]
  run make -s -C "$c/d2-signalloom" sentinel-image-tag
  [ "$status" -ne 0 ] || { echo "a modified input was not refused: $output"; return 1; }
}

# The guard is what keeps an ignored file out of a shipped image: every
# sentinel build, pin and publish target takes its tag from sentinel-image-tag.
# A docker shim records whether the build ever starts. Clean: it does (the
# shim is wired, so its silence below means something). With an ignored file
# under a COPY path: make fails and docker is never invoked.
@test "sentinel: the image build never starts with an ignored file in the build context" {
  local c shim="$BATS_TEST_TMPDIR/shim" sentinel_app target
  c="$(sentinel_clone)"
  if [ -d "$c/d2-signalloom/apps/signalloom-warden/bpf" ]; then
    sentinel_app="$c/d2-signalloom/apps/signalloom-warden"
  else
    sentinel_app="$c/d2-signalloom/apps/stun-sentinel"
  fi
  if grep -q '^swarm-signalloom-warden-image:' "$c/d2-signalloom/Makefile"; then
    target="swarm-signalloom-warden-image"
  else
    target="swarm-stun-sentinel-image"
  fi
  mkdir -p "$shim"
  printf '#!/bin/sh\necho "$@" >>"%s/docker.calls"\n' "$shim" >"$shim/docker"
  chmod +x "$shim/docker"
  PATH="$shim:$PATH" run make -s -C "$c/d2-signalloom" "$target"
  [ "$status" -eq 0 ] && rg -q -e '^build ' "$shim/docker.calls" || { echo "clean build did not reach docker: status=$status $output"; return 1; }
  rm "$shim/docker.calls"
  printf 'stale bytecode\n' >"$sentinel_app/bpf/sentinel_probe.o"
  PATH="$shim:$PATH" run make -s -C "$c/d2-signalloom" "$target"
  [ "$status" -ne 0 ] || { echo "build with an ignored input succeeded: $output"; return 1; }
  [ ! -e "$shim/docker.calls" ] || { echo "docker was invoked:"; cat "$shim/docker.calls"; return 1; }
}
