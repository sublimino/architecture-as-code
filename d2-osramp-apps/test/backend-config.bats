#!/usr/bin/env bats

setup() {
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  backend="$repo/components/backend/base"
}

@test "backend base manifests render" {
  run kubectl kustomize "$backend"
  [ "$status" -eq 0 ]
}

@test "PostgreSQL bootstrap declares the archive database grant" {
  run yq -r 'select(.kind == "ConfigMap" and .metadata.name == "postgres-init-scripts") | .data["init.sql.sh"]' "$backend/postgres.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CREATE DATABASE task_archive;"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON DATABASE task_archive TO \$POSTGRES_USER;"* ]]
}

@test "Redis source and drift policy remain explicit" {
  run yq -r 'select(.kind == "OCIRepository" and .metadata.name == "redis-chart") | [.spec.url, .spec.ref.semver] | @tsv' "$backend/redis.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = $'oci://registry-1.docker.io/bitnamicharts/redis\t20.13.4' ]

  run yq -r 'select(.kind == "HelmRelease" and .metadata.name == "redis") | .spec.driftDetection.mode' "$backend/redis.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "disabled" ]
}

@test "MinIO binds its advertised console port" {
  run yq -r 'select(.kind == "Deployment" and .metadata.name == "minio") | .spec.template.spec.containers[] | select(.name == "minio") | .args | join(" ")' "$backend/minio.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "server /data --console-address :9001" ]
}

@test "MinIO bucket bootstrap tolerates a restarted sidecar" {
  run yq -r 'select(.kind == "Deployment" and .metadata.name == "minio") | .spec.template.spec.containers[] | select(.name == "mc-create-bucket") | .args[0]' "$backend/minio.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mc mb --ignore-existing local/attestations"* ]]
}
