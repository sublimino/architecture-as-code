#!/usr/bin/env bats
#
# Static wiring assertions for the dashboard supply-chain pipeline. Runs no
# docker/cosign/buildx — it only proves the build+sign script and the Makefile
# target exist and carry the required flags, so it is safe on any host.

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  script="$root/scripts/build-sign-dashboard.sh"
  makefile="$root/Makefile"
}

@test "Dashboard build-sign script exists and is executable" {
  [ -f "$script" ]
  [ -x "$script" ]
}

@test "Dashboard build-sign script generates BuildKit SBOM and provenance" {
  run grep -F -- '--sbom=true' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--provenance' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard build-sign script signs the digest with the local cosign key" {
  run grep -F 'cosign sign' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--key "${COSIGN_KEY}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--signing-config' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--allow-insecure-registry' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--registry-referrers-mode=legacy' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard build-sign script keeps the transparency log disabled" {
  # No-tlog is enforced via a --signing-config with empty rekor services (the
  # non-deprecated cosign v3 replacement for --tlog-upload=false).
  run grep -F -- '--signing-config' "$script"
  [ "$status" -eq 0 ]
  # The deprecated flag must not return, and the tlog must never be enabled.
  run grep -F -- '--tlog-upload' "$script"
  [ "$status" -ne 0 ]
}

@test "Dashboard build-sign script writes the three evidence artifacts" {
  run grep -F 'dashboard-signalloom.sbom.spdx.json' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'dashboard-signalloom.provenance.slsa.json' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'dashboard-signalloom.digest.txt' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard delivery uses one Buildx solve for the runnable OCI archive" {
  run bash -c "grep -Ec '^[[:space:]]*docker buildx build' '$script'"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -F -- '--output "type=oci,dest=${OCI_TAR}"' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard delivery fingerprints sources before application cache layers" {
  run grep -F 'SOURCE_ID="$(tar ' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--build-arg "SOURCE_ID=${SOURCE_ID}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'ARG SOURCE_ID' "$root/d2-signalloom/apps/dashboard-signalloom/Dockerfile"
  [ "$status" -eq 0 ]
  run awk '/ARG SOURCE_ID/{source_arg=NR} /^COPY \. \./{source_copy=NR} END {exit !(source_arg && source_arg < source_copy)}' "$root/d2-signalloom/apps/dashboard-signalloom/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "Dashboard source fingerprint changes when build-context content changes" {
  tmp_dir="$(mktemp -d)"
  cp -a "$root/d2-signalloom/apps/dashboard-signalloom/." "$tmp_dir/"

  fingerprint() {
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
      --exclude-vcs --exclude='./node_modules' --exclude='./dist' --exclude='./coverage' \
      -cf - -C "$1" . | sha256sum | awk '{print $1}'
  }

  before="$(fingerprint "$tmp_dir")"
  printf '\nsource-fingerprint-regression-probe\n' >> "$tmp_dir/index.html"
  after="$(fingerprint "$tmp_dir")"
  [ "$before" != "$after" ]
  rm -rf "$tmp_dir"
}

@test "Dashboard delivery loads and pushes the single OCI archive" {
  run grep -F '"oci-archive:${OCI_TAR}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F '"docker-daemon:${IMAGE_REF}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F '"docker://${LOCAL_REF}"' "$script"
  [ "$status" -eq 0 ]
}

@test "Makefile exposes the signed dashboard image target" {
  run grep -F '.PHONY: signalloom-dashboard-image' "$makefile"
  [ "$status" -eq 0 ]
  run grep -E '^signalloom-dashboard-image:' "$makefile"
  [ "$status" -eq 0 ]
  run grep -F './scripts/build-sign-dashboard.sh' "$makefile"
  [ "$status" -eq 0 ]
}
