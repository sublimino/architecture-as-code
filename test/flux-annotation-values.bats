#!/usr/bin/env bats
# @id      flux-annotation-values
# @target  every Flux-applied manifest in the repository
# @doc     docs/signalloom/sltm-governor-log.md (entry 3)
#
# kustomize-controller honours `kustomize.toolkit.fluxcd.io/force` only for the
# value "Enabled", and `kustomize.toolkit.fluxcd.io/ssa` only for "Merge",
# "IfNotPresent" or "Ignore". Any other value is silently ignored. Eight Jobs
# carried force: "true", so a changed pod template was never recreated: on
# 2026-10-03 inf-bao/infra-controllers stopped on "Job ... spec.template:
# Invalid value" (immutable) even though the Job was annotated to be forced.

scan() { # <root>: prints file:line:value for every bad force/ssa value
  rg -n --no-heading -e 'kustomize\.toolkit\.fluxcd\.io/(force|ssa):' --glob '*.yaml' --glob '*.yml' \
     --glob '!**/node_modules/**' "$1" |
  awk -F'kustomize.toolkit.fluxcd.io/' '{
      split($2, kv, ":"); key=kv[1]; v=kv[2]; gsub(/^[ \t"]+|[ \t"]+$/, "", v)
      if (key=="force" && v!="Enabled") print $0
      if (key=="ssa" && v!="Merge" && v!="IfNotPresent" && v!="Ignore") print $0 }'
}

@test "every Flux force/ssa annotation uses a value kustomize-controller honours" {
  cd "${BATS_TEST_DIRNAME}/.."
  run scan .
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "ignored annotation values:"; echo "$output"; return 1; }
}

@test "the scan is not vacuous: a planted force: \"true\" is reported" {
  mkdir -p "${BATS_TEST_TMPDIR}/m"
  printf 'metadata:\n  annotations:\n    kustomize.toolkit.fluxcd.io/force: "true"\n' >"${BATS_TEST_TMPDIR}/m/job.yaml"
  run scan "${BATS_TEST_TMPDIR}/m"
  [[ "$output" == *'force: "true"'* ]]
}
