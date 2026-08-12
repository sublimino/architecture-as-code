#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  mkdir -p "$bin"

  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$*" == *'token generate'* ]]; then
  printf 'Token: local-demo-token\n'
elif [[ "$*" == *'entry show'* ]]; then
  exit 1
elif [[ "$*" == *'entry create'* ]]; then
  printf 'entry created\n'
elif [[ "$*" == *'bundle show -format spiffe'* ]]; then
  printf '{"keys":[{"use":"jwt-svid","kty":"EC","crv":"P-256","x":"Sm_8qNnrAGgIreZrJYZoxYSBoLnQrIR5wuvRXpM-moM","y":"Bw4Nxy8aEwIlVQZxjoHr2qAXCpbQ2J2-syBUYOXkYzA"}]}'
fi
SCRIPT
  cat >"$bin/flux" <<'SCRIPT'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$COMMAND_LOG"
SCRIPT
  chmod +x "$bin/kubectl" "$bin/flux"
}

line_number() {
  grep -n -F "$1" "$log" | cut -d: -f1 | head -n1
}

@test "clean-cluster lifecycle reconciles Bao then Signal Loom infra then frontend" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" SIGNALLOOM_SKIP_PREPARE=1 \
    "$root/scripts/signalloom-local.sh" up

  [ "$status" -eq 0 ]
  [[ "$output" == *"Signal Loom Phase 1 local reconciliation converged"* ]]

  bao=$(line_number 'flux reconcile kustomization infra-controllers -n inf-bao --with-source')
  infra=$(line_number 'flux reconcile kustomization infra-controllers -n inf-signalloom --with-source')
  frontend=$(line_number 'flux reconcile kustomization apps -n fe-signalloom --with-source')
  registration=$(line_number 'entry create -spiffeID spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom')
  proof_reset=$(line_number 'delete job bao-spire-positive-proof bao-spire-negative-proof --ignore-not-found --wait=true')
  [ -n "$bao" ]
  [ -n "$infra" ]
  [ -n "$frontend" ]
  [ -n "$registration" ]
  [ -n "$proof_reset" ]
  [ "$bao" -lt "$infra" ]
  [ "$infra" -lt "$frontend" ]
  [ "$registration" -lt "$proof_reset" ]
  [ "$proof_reset" -lt "$frontend" ]
  grep -Fq 'patch resourceset/signalloom-infra --type merge' "$log"
  grep -Fq 'patch resourceset/signalloom-apps --type merge' "$log"
  grep -Fq 'annotate resourceset/signalloom-infra reconcile.fluxcd.io/requestedAt=' "$log"
  grep -Fq 'annotate resourceset/signalloom-apps reconcile.fluxcd.io/requestedAt=' "$log"
  grep -Fq 'wait resourceset/signalloom-infra --for=condition=ready' "$log"
  grep -Fq 'wait resourceset/signalloom-apps --for=condition=ready' "$log"
	 grep -Fq 'rollout restart deployment/dex' "$log"
	 grep -Fq 'rollout status deploy/dex' "$log"
	 grep -Fq 'rollout restart deployment/fe-signalloom deployment/dashboard-signalloom' "$log"
	 grep -Fq 'rollout status deploy/fe-signalloom' "$log"
	 grep -Fq 'rollout status deploy/dashboard-signalloom' "$log"
}

@test "local lifecycle builds the SPIRE helper before loading the portal image" {
  script="$root/scripts/signalloom-local.sh"
  helper=$(grep -n 'signalloom-spire-helper' "$script" | cut -d: -f1)
  image=$(grep -n 'signalloom-images' "$script" | cut -d: -f1)
  [ -n "$helper" ]
  [ -n "$image" ]
  [ "$helper" -lt "$image" ]
}

# These asserted the literal `kind load docker-image --name osramp <image>`
# until 770e523 routed the images most at risk through
# scripts/kind-load-verified.sh: on a Docker daemon backed by the containerd
# image store, plain `kind load` exits 0 having transferred nothing, and
# fake-integration-proxy:dev and fe-signalloom:latest are the two it drops.
# The pods then sit in ImagePullBackOff and CI stages 6-8 fail together naming
# no image at all -- masked on a warm VM whose node cache survives, fatal on
# every cold run.
#
# Pinned to the raw command, these guards demanded the exact form that fix
# removed, so they failed against a tree that is strictly more correct. Assert
# that each image reaches the Kind node and accept either loader; the verified
# one is a strict improvement, and dashboard-signalloom still uses the plain
# call, so both spellings are live in the same target.
assert_kind_loaded() {
  local image="$1" out="$2"
  [[ "$out" == *"kind load docker-image --name osramp ${image}"* ]] && return 0
  [[ "$out" == *"kind-load-verified.sh"*"${image}"* ]] && return 0
  echo "no kind load of ${image} in \`make -n signalloom-images\`" >&2
  return 1
}

@test "local lifecycle loads the fake integration proxy image into Kind" {
  run make -n signalloom-images

  [ "$status" -eq 0 ]
  [[ "$output" == *"docker build -t fake-integration-proxy:dev"* ]]
  assert_kind_loaded "fake-integration-proxy:dev" "$output"
}

@test "local lifecycle refreshes both portal images in Kind" {
  run make -n signalloom-images

  [ "$status" -eq 0 ]
  assert_kind_loaded "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest" "$output"
  assert_kind_loaded "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest" "$output"
}

@test "Phase 1 is exposed through the approved demo lifecycle rather than a new wrapper" {
  run make -n demo-signalloom-up demo-signalloom-test demo-signalloom-down

  [ "$status" -eq 0 ]
  [[ "$output" == *"signalloom-local.sh up"* ]]
  [[ "$output" == *"signalloom-local.sh verify"* ]]
  [[ "$output" == *"signalloom-down.sh"* ]]
  [[ "$output" != *"signalloom-up:"* ]]
}

@test "verify performs focused Flux readiness checks without bootstrap work" {
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" \
    "$root/scripts/signalloom-local.sh" verify

  [ "$status" -eq 0 ]
  [[ "$output" == *"Signal Loom Phase 1 Flux verification passed"* ]]
  grep -Fq 'get resourceset -n flux-system signalloom-infra signalloom-apps -o json' "$log"
  grep -Fq 'wait kustomization/apps --for=condition=ready' "$log"
  ! grep -Fq 'flux reconcile' "$log"
}
