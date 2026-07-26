#!/usr/bin/env bats

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  manifest="$root/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
}

@test "Discovery Portal package has the frozen runtime contract" {
  run yq -r 'select(.kind == "Deployment") | [.metadata.name, .spec.replicas, .spec.template.spec.serviceAccountName, .spec.template.spec.containers[0].ports[0].containerPort, .spec.template.spec.initContainers[0].name, (.spec.template.spec.initContainers[0].command | join(" "))] | @tsv' "$manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == $'fe-signalloom\t1\tfe-signalloom\t8000\twait-for-postgresql\t'* ]]
  [[ "$output" == *"postgresql.inf-signalloom.svc.cluster.local"* ]]
}

@test "Discovery Portal probes and dependency service URLs are explicit" {
  run yq -r 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].startupProbe.httpGet.path, .spec.template.spec.containers[0].livenessProbe.httpGet.path, .spec.template.spec.containers[0].readinessProbe.httpGet.path, ([.spec.template.spec.containers[0].env[] | select(.name == "REDIS_URL").value] | .[0]), ([.spec.template.spec.containers[0].env[] | select(.name == "S3_ENDPOINT_URL").value] | .[0])] | @tsv' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = $'/livez\t/livez\t/readyz\tredis://redis.inf-signalloom.svc.cluster.local:6379/0\thttp://minio.inf-signalloom.svc.cluster.local:9000' ]
}

@test "Discovery Portal specifies the image user numerically" {
  run yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "discovery-portal") | (.securityContext.runAsUser == 999 and (.securityContext.runAsUser | tag) == "!!int")' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "Discovery Portal has a service and named demo Secrets" {
  run yq -e 'select(.kind == "Secret") | (.metadata.name == "discovery-portal-database" or .metadata.name == "discovery-portal-storage")' "$root/d2-signalloom/apps/fe-signalloom/base/secrets.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"true"* ]]
  run yq -e '(.kind == "Service" and .metadata.name == "fe-signalloom" and .spec.ports[0].port == 8000)' "$root/d2-signalloom/apps/fe-signalloom/base/service.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
