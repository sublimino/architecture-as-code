#!/usr/bin/env bats
#
# The stun sentinel image must build from its Makefile invocation.
#
# go.mod carries `replace .../apps/stun-sentinel => ../stun-sentinel`. With
# the build context at apps/signalloom-stun-sentinel/ that directory is outside
# the context, so `go mod download` in the image cannot resolve it (W6 had to
# work around it by hand). af95178a fixed the same shape for fleet-manager by
# widening the context to apps/ and copying both modules.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  d2="$repo_root/d2-signalloom"
  mod_dir="$d2/apps/signalloom-stun-sentinel"
  dockerfile="$mod_dir/Dockerfile"
  build_line="$(rg -A1 '^swarm-stun-sentinel-image:' "$d2/Makefile" | rg 'docker build')"
  # Context is the last argument of the recipe, relative to d2-signalloom/.
  context="$d2/$(awk '{print $NF}' <<<"$build_line")"
  context="$(cd "$context" && pwd)"
}

@test "Makefile builds the sentinel image with its Dockerfile named explicitly" {
  [[ "$build_line" == *"-f apps/signalloom-stun-sentinel/Dockerfile"* ]]
}

@test "every go.mod replace target is inside the build context and COPYed" {
  targets="$(awk '/^replace /{print $NF}' "$mod_dir/go.mod")"
  [ -n "$targets" ]
  while read -r rel; do
    abs="$(cd "$mod_dir/$rel" && pwd)"
    [[ "$abs" == "$context"/* ]] || { echo "replace $rel -> $abs is outside context $context"; return 1; }
    src="${abs#"$context"/}"
    rg -q "^COPY +${src}/? " "$dockerfile" || { echo "Dockerfile does not COPY $src"; return 1; }
  done <<<"$targets"
  # And the module itself, from the same context.
  rg -q "^COPY +signalloom-stun-sentinel/? " "$dockerfile"
}

@test "docker build --check accepts the Dockerfile in its Makefile context" {
  command -v docker >/dev/null || skip "docker not installed"
  docker buildx build --help 2>/dev/null | rg -q -- '--check' || skip "buildx has no --check"
  run docker buildx build --check -f "$dockerfile" "$context"
  echo "$output"
  [ "$status" -eq 0 ]
}
