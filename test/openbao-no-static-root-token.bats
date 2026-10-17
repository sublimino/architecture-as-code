#!/usr/bin/env bats
# @id     openbao-no-static-root-token
# @target d2-signalloom/infra/inf-bao
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   SA-TODO-003: no tracked file names the old static OpenBao root token,
#         no manifest gives OpenBao a token as a literal value, the platform
#         OpenBao never runs in dev mode, and nothing reads a dev root token out
#         of the platform OpenBao Deployment. Administration is the
#         SPIFFE-bound inf-bao-admin role (scripts/lib/bao-admin.sh).
#
# Throwaway dev servers that a test starts for itself and destroys (docker
# labs, the phase-2 hub fixture's own OpenBao) are not the platform OpenBao
# and are listed in ALLOWED_DEV_READERS with the reason.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  cd "${REPO_ROOT}"
  # Assembled from halves so this file cannot match its own search.
  OLD_TOKEN="signalloom-demo-root""-token"
  SELF="test/openbao-no-static-root-token.bats"
}

tracked_matches() {
  git ls-files -z | xargs -0 rg -l --no-messages -F -- "$1" | rg -v -x -F "${SELF}" || true
}

@test "no tracked file names the old static root token" {
  run tracked_matches "${OLD_TOKEN}"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "still named in:"; echo "$output"; return 1; }
}

@test "no manifest gives a workload BAO_TOKEN as a literal value" {
  run rg -n -U --glob '*.yaml' --glob '*.yml' 'name: (BAO_TOKEN|BAO_ROOT_TOKEN|VAULT_TOKEN)\n\s*value:' d2-signalloom d2-osramp-fleet
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "the platform OpenBao never runs in dev mode" {
  run rg -n --glob '*.yaml' -e '"-dev"|-dev-root-token|BAO_DEV_ROOT_TOKEN_ID' d2-signalloom/infra d2-signalloom/apps
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "no host script reads a dev root token out of the platform OpenBao" {
  # ALLOWED_DEV_READERS: they talk to a dev server they own, never inf-bao.
  #   scripts/lib/p2gov-bao.sh                          phase-2 hub fixture (namespace sldc-p2-gov)
  #   d2-signalloom/test/openbao-agent-generic-role-lab.sh  docker lab, own dev server
  #   test/spire-federation-openbao-jwt.bats            docker lab, own dev server
  #   test/phase2-governor-verification.bats            asserts p2gov-bao.sh's shape
  #   test/fixtures/phase2-governor/hub-fixture.yaml    the hub fixture itself
  #   d2-signalloom/test/fixtures/kubectl-evidence-stub.sh  stub output for a retired evidence path
  #   d2-signalloom/test/openbao-persistent-server.bats asserts the server has no dev token
  #   scripts/openbao-migrate.sh                        one-shot export off the retiring dev server, read inside its pod
  run rg -l -- 'BAO_DEV_ROOT_TOKEN_ID|BAO_ROOT_TOKEN' scripts test d2-signalloom/test terraform
  allowed='^(scripts/lib/p2gov-bao.sh|d2-signalloom/test/openbao-agent-generic-role-lab.sh|test/spire-federation-openbao-jwt.bats|test/phase2-governor-verification.bats|test/fixtures/phase2-governor/hub-fixture.yaml|d2-signalloom/test/fixtures/kubectl-evidence-stub.sh|d2-signalloom/test/openbao-persistent-server.bats|scripts/openbao-migrate.sh|test/openbao-no-static-root-token.bats)$'
  offenders="$(printf '%s\n' "$output" | rg -v -- "${allowed}" || true)"
  [ -z "${offenders}" ] || { echo "reads a dev root token:"; echo "${offenders}"; return 1; }
}

@test "guard self-check: the search does find a planted token" {
  planted="${BATS_TEST_TMPDIR}/planted.sh"
  printf 'BAO_TOKEN=%s\n' "${OLD_TOKEN}" >"${planted}"
  run rg -l -F -- "${OLD_TOKEN}" "${planted}"
  [ "$status" -eq 0 ]
}
