#!/usr/bin/env bash
# bao-admin.sh - administer OpenBao from a host script as role inf-bao-admin.
#
# @id     bao-admin-lib
# @tests  test/bao-admin-lib.bats
# @doc    d2-signalloom/infra/inf-bao/controllers/base/openbao-admin.yaml
#
# There is no static root token any more (SA-TODO-003). The openbao-admin pod
# in inf-bao holds a 15-minute inf-bao-admin token, minted from its SPIFFE
# identity by a bao agent. These helpers kubectl-exec into that pod, where
# the wrappers bao-admin and with-bao-admin set the token in their own
# environment. Nothing here puts a token on argv.
#
#   bao_admin ARGS...          one bao command
#   bao_admin_stdin ARGS...    one bao command with stdin attached (write PATH -)
#   bao_admin_sh 'SCRIPT'      a shell script with BAO_ADDR/BAO_TOKEN set
#   bao_admin_token            print the current 15-minute token, ONLY for a
#                              tool that must call OpenBao over HTTP from the
#                              host; prefer the three above
#
# BAO_NAMESPACE (default inf-bao) and BAO_ADMIN_KUBECTL_ARGS (for example
# "--context kind-osramp") select the cluster.

_bao_admin_kubectl() {
  local -a extra=()
  # shellcheck disable=SC2206 # deliberate word split of an args string
  [ -n "${BAO_ADMIN_KUBECTL_ARGS:-}" ] && extra=(${BAO_ADMIN_KUBECTL_ARGS})
  kubectl ${extra[@]+"${extra[@]}"} -n "${BAO_NAMESPACE:-inf-bao}" "$@"
}

bao_admin() {
  _bao_admin_kubectl exec deployment/openbao-admin -c bao -- bao-admin "$@"
}

bao_admin_stdin() {
  _bao_admin_kubectl exec -i deployment/openbao-admin -c bao -- bao-admin "$@"
}

bao_admin_sh() {
  _bao_admin_kubectl exec deployment/openbao-admin -c bao -- with-bao-admin sh -ec "$1"
}

bao_admin_token() {
  _bao_admin_kubectl exec deployment/openbao-admin -c bao -- cat /var/run/secrets/openbao/token \
    | tr -d '\r\n'
}
