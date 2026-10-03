#!/usr/bin/env bats
# @id      rendered-env-unique
# @target  every kustomization path below (rendered manifests)
# @doc     docs/signalloom/sltm-governor-log.md (entry 3: the live deploy this caught)
#
# A container that declares the same env name twice renders fine under
# `kubectl kustomize` and fails only at server-side apply ("duplicate entries
# for key [name=...]"), so a merge that keeps both sides of an env conflict
# ships a manifest Flux refuses. Found live on 2026-10-03: fe-signalloom carried
# SIGNAL_INGEST_KEY_FILE twice and the whole apps Kustomization stopped.

PATHS=(
  d2-signalloom/apps/fe-signalloom/local
  d2-signalloom/apps/fe-signalloom/base
  d2-signalloom/apps/signal-ingest/base
  $(ls -d d2-signalloom/infra/agent-swarm/signalloom-* 2>/dev/null | grep -E '(warden|sentinel)$' | head -n 1)
  $(ls -d d2-signalloom/infra/agent-swarm/signalloom-*-overlays/kind-osramp 2>/dev/null | grep -E '(warden|sentinel)' | head -n 1)
)

dups_in() {
  kubectl kustomize "$1" 2>/dev/null | yq -o=json -I=0 \
    'select(.spec.template.spec != null) | .metadata.name as $w | .spec.template.spec | ((.containers // []) + (.initContainers // []))[] | {"w": $w, "c": .name, "env": [(.env // [])[].name]}' |
    jq -r '. as $o | ($o.env | group_by(.) | map(select(length > 1) | .[0]))[] | "\($o.w)/\($o.c): \(.)"'
}

@test "no rendered container declares an env name twice" {
  cd "${BATS_TEST_DIRNAME}/.."
  local out="" p
  for p in "${PATHS[@]}"; do
    [ -d "$p" ] || { echo "missing path $p"; return 1; }
    out+="$(dups_in "$p")"
  done
  [ -z "$out" ] || { echo "duplicate env names:"; echo "$out"; return 1; }
}

@test "the duplicate detector is not vacuous: a planted duplicate is reported" {
  local d="${BATS_TEST_TMPDIR}/k"; mkdir -p "$d"
  cat >"$d/deploy.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: planted}
spec:
  selector: {matchLabels: {a: b}}
  template:
    metadata: {labels: {a: b}}
    spec:
      containers:
        - name: c
          image: x
          env: [{name: A, value: "1"}, {name: A, value: "2"}]
YAML
  printf 'resources: [deploy.yaml]\n' >"$d/kustomization.yaml"
  run dups_in "$d"
  [ "$output" = "planted/c: A" ]
}
