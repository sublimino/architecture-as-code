#!/usr/bin/env bats
#
# The signalloom warden image must build from its Makefile invocation.
#
# go.mod carries `replace .../apps/signalloom-warden => ../signalloom-warden`. With
# the build context at apps/signalloom-warden/ that directory is outside
# the context, so `go mod download` in the image cannot resolve it (W6 had to
# work around it by hand). af95178a fixed the same shape for fleet-manager by
# widening the context to apps/ and copying both modules.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  d2="$repo_root/d2-signalloom"
  export DOCKER_CONFIG="${DOCKER_CONFIG:-$BATS_TEST_TMPDIR/docker}"
  mkdir -p "$DOCKER_CONFIG"
  if [ -d "$d2/apps/signalloom-warden" ]; then
    mod_dir="$d2/apps/signalloom-warden"
  else
    mod_dir="$d2/apps/signalloom-""stun"-sentinel
  fi
  dockerfile="$mod_dir/Dockerfile"
  # The recipe as make runs it: backslash continuations joined, then split into
  # its `;`-separated commands, keeping the docker build.
  build_line="$(awk '
    /^swarm-.*(warden|sentinel)-image:/ { r = 1; next }
    r && !/^\t/ { exit }
    r { s = s $0; if (s ~ /\\$/) { sub(/\\$/, " ", s); next } print s; s = "" }
  ' "$d2/Makefile" | tr ';' '\n' | rg 'docker build')"
  # Context is the last argument of the recipe, relative to d2-signalloom/.
  context="$d2/$(awk '{print $NF}' <<<"$build_line")"
  context="$(cd "$context" && pwd)"
}

@test "Makefile builds the sentinel image with its Dockerfile named explicitly" {
  [[ "$build_line" == *"-f apps/"*"/Dockerfile"* ]]
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
  rg -q "^COPY +(apps/)?(signalloom-warden|signalloom-.*sentinel)/? " "$dockerfile"
}

@test "docker build --check accepts the Dockerfile in its Makefile context" {
  command -v docker >/dev/null || skip "docker not installed"
  docker buildx build --help 2>/dev/null | rg -q -- '--check' || skip "buildx has no --check"
  run docker buildx build --check -f "$dockerfile" "$context"
  echo "$output"
  [ "$status" -eq 0 ]
}
