#!/usr/bin/env bats
# The runner image COPYs scripts one by one, so a script the API shells out to
# is either named in the Dockerfile or simply absent from the pod.
#
# That failure is invisible locally: the endpoint works perfectly from a
# developer's terminal, where the repo is on disk, and returns 503
# evidence_script_unavailable on every request in-cluster. Nothing else in the
# suite would notice — demo_runner's unit tests point SUPERCRED_EVIDENCE_SCRIPT
# at a tmp fixture, precisely so they do not need the image.
#
# So assert the invariant directly: every script demo_runner can execute must be
# COPYd into the image.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  dockerfile="${repo_root}/d2-signalloom/apps/supercred-demo-runner/Dockerfile"
  runner="${repo_root}/d2-signalloom/apps/fe-signalloom/src/demo_runner.py"
}

@test "SUPERCRED runner image ships every script demo_runner shells out to" {
  [ -f "$dockerfile" ]
  [ -f "$runner" ]

  local missing=0 script
  # Each `_repo_root() / "scripts" / "<name>"` in demo_runner is a script the
  # API can execute at runtime.
  while read -r script; do
    [ -z "$script" ] && continue
    if ! grep -Fq "COPY scripts/${script} " "$dockerfile"; then
      echo "demo_runner.py can execute scripts/${script}, but the runner Dockerfile never COPYs it" >&2
      echo "  the endpoint that uses it will 503 in-cluster while working from a terminal" >&2
      missing=1
    fi
  done < <(grep -oE '"scripts"[[:space:]]*/[[:space:]]*"[a-z0-9._-]+"' "$runner" \
             | grep -oE '"[a-z0-9._-]+\.sh"' | tr -d '"' | sort -u)

  [ "$missing" -eq 0 ]
}

@test "SUPERCRED the evidence probe is executable in the repo" {
  # COPY preserves the mode, so a non-executable script in the tree is a
  # non-executable script in the image, and _script_is_available() checks X_OK.
  [ -x "${repo_root}/scripts/supercred-evidence.sh" ]
}

@test "SUPERCRED the image-ships-scripts audit can actually fail" {
  # A guard nobody has watched fail is not a guard.
  run bash -c '
    dockerfile="$(mktemp)"; runner="$(mktemp)"
    printf "COPY scripts/present.sh /repo/scripts/present.sh\n" > "$dockerfile"
    printf "_repo_root() / \"scripts\" / \"absent.sh\"\n" > "$runner"
    missing=0
    while read -r s; do
      [ -z "$s" ] && continue
      grep -Fq "COPY scripts/${s} " "$dockerfile" || missing=1
    done < <(grep -oE "\"scripts\"[[:space:]]*/[[:space:]]*\"[a-z0-9._-]+\"" "$runner" \
               | grep -oE "\"[a-z0-9._-]+\.sh\"" | tr -d "\"" | sort -u)
    rm -f "$dockerfile" "$runner"
    exit "$missing"'
  [ "$status" -eq 1 ]
}
