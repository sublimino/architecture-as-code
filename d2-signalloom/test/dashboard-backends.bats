#!/usr/bin/env bats
# Every backend the dashboard proxies to must be deployable and deployed.
#
# Twice a complete, tested slice sat in the repo and was never deployed, and the
# failure reached a human as a cryptic error rather than "not deployed":
#
#   fleet-manager  no nginx location, no kustomization entry, no build target.
#                  The SPA catch-all answered its API calls with index.html at
#                  200 OK -> `Unexpected token '<', "<!doctype "...`.
#   afm-platform   never deployed at all, namespace absent -> /rbac-explorer
#                  failed with `[Errno -2] Name or service not known`.
#
# Every existing test passed through both. Unit tests mock fetch, contract tests
# mock the upstream, and the BATS suites assert manifest CONTENT rather than
# deployed PRESENCE. Nothing asserted the system was whole.
#
# nginx.conf is the source of truth because the dashboard reaches every backend
# through a proxy_pass, so adding a proxy without deploying its upstream is
# exactly the bug — and this reads the proxy.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  script="${repo_root}/scripts/check-backends.sh"
  nginx_conf="${repo_root}/d2-signalloom/apps/dashboard-signalloom/nginx.conf"
}

@test "BACKENDS the checker exists and is executable" {
  [ -x "$script" ]
}

@test "BACKENDS every nginx upstream is declared by some D2 slice" {
  # Static: needs no cluster, so it runs in CI and at review time.
  run "$script" static
  [ "$status" -eq 0 ]
  [[ "$output" != *UNDECLARED* ]]
}

@test "BACKENDS the static audit names every upstream it found" {
  run "$script" static
  [ "$status" -eq 0 ]
  # The two that historically went missing must both be covered.
  [[ "$output" == *fleet-manager* ]]
  [[ "$output" == *afm-platform* ]]
}

@test "BACKENDS an undeclared upstream fails the audit" {
  # A guard nobody has watched fail is not a guard. Point the checker at an
  # nginx.conf proxying to a service no manifest declares — exactly the
  # fleet-manager/afm-platform shape — and it must go red.
  local fake="$BATS_TEST_TMPDIR/nginx.conf"
  cat >"$fake" <<'CONF'
server {
  location /ghost-api/ {
    set $ghost http://ghost-service.nowhere.svc.cluster.local:9999;
    proxy_pass $ghost;
  }
}
CONF
  NGINX_CONF="$fake" run "$script" static
  [ "$status" -ne 0 ]
  [[ "$output" == *UNDECLARED* ]] || [[ "$output" == *ghost-service* ]]
}

@test "BACKENDS doctor runs the backend check" {
  # doctor is where an engineer looks first, so a missing backend has to surface
  # there rather than only in a page's console.
  grep -Fq 'check-backends.sh' "${repo_root}/scripts/doctor.sh"
}

@test "BACKENDS the checker distinguishes absent from unreachable" {
  # Collapsing "was never deployed" into "is not answering" sends the next
  # engineer to the wrong place entirely.
  grep -Fq 'ABSENT' "$script"
  grep -Fq 'NO BACKEND' "$script"
  grep -Fq 'UNAVAILABLE' "$script"
}

@test "BACKENDS live mode FAILS when there is no cluster to ask" {
  # The defect this test was written for, measured on the parent commit: with
  # no reachable cluster, `check_live` returned 1, the caller discarded it with
  # `|| true`, and the script exited 0 having printed BOTH
  #
  #   UNAVAILABLE no reachable cluster — deployment state unproven
  #   All nginx upstreams are declared and reachable.
  #
  # — a confident all-clear about a cluster it never opened a connection to.
  #
  # Harmless while the only caller was doctor.sh in front of a human. Not
  # harmless now that this gates a pipeline stage, where a missing or
  # misdirected kubeconfig is exactly how a guard becomes decoration: every
  # backend absent, stage green.
  KUBECONFIG="$BATS_TEST_TMPDIR/nonexistent-kubeconfig" run "$script" live
  [ "$status" -ne 0 ]
  [[ "$output" == *UNPROVEN* ]]
  # And it must NOT claim the estate is healthy on the way out.
  [[ "$output" != *"All nginx upstreams are declared and reachable"* ]]
}

@test "BACKENDS the CI pipeline runs the backend check" {
  # doctor.sh needs a human to type it. This check was written FOR the
  # afm-platform incident and, until it was wired in, no pipeline invoked it —
  # so it caught the bug it was designed for exactly zero times. The Makefile
  # recipe and the hand-copied CI pipeline must both carry it.
  #
  # COMMENT-BLIND, deliberately. Both files explain this wiring at length in
  # comments containing the literal "check-backends", so `grep -Fq` is satisfied
  # by the prose that describes the rule even once the rule is gone. Measured:
  # test/afm-delivery-mutation-proof.sh M9 replaced the pipeline's live
  # invocation with `true` and this test stayed GREEN, citing the comment above
  # the line it had just disabled. Anchoring on the INVOCATION rather than the
  # name is what makes it a guard.
  grep -Eq '^[^#]*\$\(MAKE\) check-backends' "${repo_root}/Makefile"
  grep -Eq '^[^#]*make check-backends' "${repo_root}/scripts/ci/vm-pipeline.sh"
}
