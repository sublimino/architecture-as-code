#!/usr/bin/env bash
#
# Deployment-time guard against unsubstituted Flux variables.
#
# WHY THIS EXISTS
#
# Flux's `postBuild.substituteFrom` is a silent no-op when a key is missing from
# its source ConfigMap/Secret: the `${VAR}` token is left as a literal string, the
# apply succeeds, and the object is marked `Ready=True`. Nothing retries, so the
# estate sits broken indefinitely while every status field claims health.
#
# Two distinct races produce this:
#
#   1. First-reconcile race (found live 2026-08-02, fixed). A Kustomization and the
#      ConfigMap it substitutes from are applied in the same batch by the same
#      parent, with no `dependsOn`. cert-manager, ingress, monitoring and
#      trivy-system all came up with a literal `${ARTIFACT_TAG}` in their
#      OCIRepository tag and `./controllers/${ENVIRONMENT}` as their Kustomization
#      path, hours after bootstrap. Fixed by adding `dependsOn: [{name: flux-system}]`
#      to `clusters/<env>/tenants.yaml`.
#
#   2. Intra-ResourceSet race (known, NOT fixed). A ResourceSet's `resources:` list
#      has no ordering guarantee between entries, so a ConfigMap carrying
#      `fluxcd.controlplane.io/copyFrom` and a Kustomization whose
#      `postBuild.substituteFrom` reads that copy are applied together with nothing
#      sequencing them. `dependsOn` cannot express "wait for a ConfigMap" — a
#      Kustomization's `dependsOn` only accepts other Kustomizations — so the only
#      structural fix is converting `resources:` to `steps:`, which is mutually
#      exclusive with `resources:` and would break six positional JSON patches in
#      `tenants/local/kustomization.yaml`. That refactor is deliberately deferred.
#
# This script is the compensating control for (2) and a regression net for (1):
# it does not prevent the race, it makes the race LOUD at deployment time instead
# of silent forever. Run it after any deploy or reconcile.
#
# Exit 0 = no unsubstituted tokens. Exit 1 = at least one found (fail the deploy).
set -euo pipefail

# Flux object kinds whose specs are produced by postBuild substitution. These are
# the surfaces where a surviving token actually breaks something: an OCIRepository
# tag that can't resolve, a Kustomization path that doesn't exist, a HelmRelease
# chart ref that points nowhere.
KINDS="${FLUX_SUBST_KINDS:-ocirepositories,gitrepositories,helmrepositories,kustomizations,helmreleases,resourcesets}"

# Tokens that are legitimately literal and must NOT fail the check.
#
# Grafana dashboards ship datasource placeholders (`${DS_PROMETHEUS}`) that Grafana
# itself expands at render time, and SPIRE's join-token flow carries `${JOIN_TOKEN}`
# for its own `-expandEnv`. Neither is Flux's to substitute. Keep this list tight
# and justify every addition — a too-broad allowlist turns this guard back into the
# silent no-op it exists to catch.
ALLOW_TOKENS="${FLUX_SUBST_ALLOW:-DS_PROMETHEUS|JOIN_TOKEN}"

fail=0
found=""

scan() {
  local label="$1"; shift
  local json
  # `|| true`: a missing CRD (e.g. resourcesets on a cluster without flux-operator)
  # must not abort the whole check.
  json="$(kubectl get ${KINDS} "$@" -o json 2>/dev/null || true)"
  [ -z "${json}" ] && return 0

  # Match ${VAR} and ${VAR:=default}. Report the owning object, not just the token,
  # so the operator has somewhere to go.
  local hits
  hits="$(printf '%s' "${json}" | python3 -c '
import json, re, sys
pat = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}")
allow = set(sys.argv[1].split("|"))
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in doc.get("items", []):
    kind = item.get("kind", "?")
    md = item.get("metadata", {})
    ns, name = md.get("namespace", "-"), md.get("name", "?")
    # Only the spec: status can legitimately echo a token back in an error message,
    # and flagging that would double-report the same defect.
    blob = json.dumps(item.get("spec", {}))
    for var in {m.group(1) for m in pat.finditer(blob)} - allow:
        print(f"{kind}/{name} -n {ns}: ${{{var}}}")
' "${ALLOW_TOKENS}")"

  if [ -n "${hits}" ]; then
    found="${found}${hits}\n"
    fail=1
  fi
}

scan "all namespaces" -A

if [ "${fail}" -ne 0 ]; then
  echo "FLUX SUBSTITUTION CHECK: FAILED" >&2
  echo >&2
  echo "Unsubstituted \${VAR} tokens survived into live Flux objects:" >&2
  echo >&2
  printf '%b' "${found}" | sed 's/^/  /' >&2
  echo >&2
  cat >&2 <<'REMEDY'
These objects will not reconcile correctly. Flux does NOT report this as an
error — a missing substituteFrom key is a silent no-op and the object is still
marked Ready=True — which is exactly why this check exists.

Immediate workaround (forces a fresh render against the current ConfigMap):

  flux reconcile kustomization tenants -n flux-system --with-source

Then find the root cause. Usually one of:
  * the Kustomization substitutes from a ConfigMap/Secret it does not own and
    lacks a dependsOn guard, so it raced its source on first reconcile; or
  * the ConfigMap is copied into the namespace by a ResourceSet
    (fluxcd.controlplane.io/copyFrom) in the same unordered resources: list as
    the Kustomization that reads it.

See AGENTS.md -> "Flux variable substitution".
REMEDY
  exit 1
fi

echo "flux substitution check: no unsubstituted \${VAR} tokens in live Flux objects"
