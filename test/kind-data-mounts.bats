#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/kind-data-mounts.bats : Verify Kind data mounts, shared renderer, and local-path stability

setup() {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "MOUNTS: rendered config for osramp and signalloom-hub carries all three data mounts and eBPF binds" {
  source "$repo_root/scripts/lib/kind-data-mounts.sh"

  local osramp_out="$BATS_TEST_TMPDIR/osramp.yaml"
  local hub_out="$BATS_TEST_TMPDIR/hub.yaml"

  kind_data_render_config "osramp" "$repo_root/infra/kind/cluster-osramp.yaml" "$osramp_out"
  kind_data_render_config "signalloom-hub" "$repo_root/infra/kind/cluster-signalloom-hub.yaml" "$hub_out"

  # Verify 3 data mounts in osramp config
  grep -Fq "containerPath: /var/local/signalloom-postgres-data" "$osramp_out"
  grep -Fq "containerPath: /var/local/osramp-zot-cache" "$osramp_out"
  grep -Fq "containerPath: /var/local-path-provisioner" "$osramp_out"

  # Verify eBPF mounts in osramp config
  grep -Fq "containerPath: /lib/modules" "$osramp_out"
  grep -Fq "containerPath: /sys/kernel/btf" "$osramp_out"

  # Verify 3 data mounts in hub config
  grep -Fq "containerPath: /var/local/signalloom-postgres-data" "$hub_out"
  grep -Fq "containerPath: /var/local/osramp-zot-cache" "$hub_out"
  grep -Fq "containerPath: /var/local-path-provisioner" "$hub_out"

  # Verify hub gained eBPF mounts
  grep -Fq "containerPath: /lib/modules" "$hub_out"
  grep -Fq "containerPath: /sys/kernel/btf" "$hub_out"
}

@test "MOUNTS: create-kind-cluster.sh and dual-cluster-up.sh render identical mount containerPaths" {
  source "$repo_root/scripts/lib/kind-data-mounts.sh"

  local dual_out="$BATS_TEST_TMPDIR/dual-osramp.yaml"
  kind_data_render_config "osramp" "$repo_root/infra/kind/cluster-osramp.yaml" "$dual_out"

  local create_out="$BATS_TEST_TMPDIR/create-osramp.yaml"
  kind_data_render_config "osramp" "" "$create_out"

  local dual_mounts
  dual_mounts="$(grep "containerPath:" "$dual_out" | awk '{print $2}' | sort)"
  local create_mounts
  create_mounts="$(grep "containerPath:" "$create_out" | awk '{print $2}' | sort)"

  [ "$dual_mounts" = "$create_mounts" ]

  # Also check hub mount containerPaths match
  local hub_out="$BATS_TEST_TMPDIR/dual-hub.yaml"
  kind_data_render_config "signalloom-hub" "$repo_root/infra/kind/cluster-signalloom-hub.yaml" "$hub_out"
  local hub_mounts
  hub_mounts="$(grep "containerPath:" "$hub_out" | awk '{print $2}' | sort)"

  [ "$dual_mounts" = "$hub_mounts" ]
}

@test "MOUNTS: osramp and signalloom-hub host paths are disjoint" {
  source "$repo_root/scripts/lib/kind-data-mounts.sh"

  local osramp_out="$BATS_TEST_TMPDIR/osramp-disjoint.yaml"
  local hub_out="$BATS_TEST_TMPDIR/hub-disjoint.yaml"

  kind_data_render_config "osramp" "$repo_root/infra/kind/cluster-osramp.yaml" "$osramp_out"
  kind_data_render_config "signalloom-hub" "$repo_root/infra/kind/cluster-signalloom-hub.yaml" "$hub_out"

  # Extract hostPaths for data directories (excluding /lib/modules and /sys/kernel/btf)
  local osramp_pg osramp_zot osramp_lp
  osramp_pg="$(grep -B1 "/var/local/signalloom-postgres-data" "$osramp_out" | grep "hostPath:" | awk '{print $NF}')"
  osramp_zot="$(grep -B1 "/var/local/osramp-zot-cache" "$osramp_out" | grep "hostPath:" | awk '{print $NF}')"
  osramp_lp="$(grep -B1 "/var/local-path-provisioner" "$osramp_out" | grep "hostPath:" | awk '{print $NF}')"

  local hub_pg hub_zot hub_lp
  hub_pg="$(grep -B1 "/var/local/signalloom-postgres-data" "$hub_out" | grep "hostPath:" | awk '{print $NF}')"
  hub_zot="$(grep -B1 "/var/local/osramp-zot-cache" "$hub_out" | grep "hostPath:" | awk '{print $NF}')"
  hub_lp="$(grep -B1 "/var/local-path-provisioner" "$hub_out" | grep "hostPath:" | awk '{print $NF}')"

  [ -n "$osramp_pg" ]
  [ -n "$hub_pg" ]
  [ "$osramp_pg" != "$hub_pg" ]
  [ "$osramp_zot" != "$hub_zot" ]
  [ "$osramp_lp" != "$hub_lp" ]
}

@test "MOUNTS: host directories are created and custom overrides are honoured before kind create" {
  fake_kind="$BATS_TEST_TMPDIR/kind"
  fake_docker="$BATS_TEST_TMPDIR/docker"
  log="$BATS_TEST_TMPDIR/call-order.log"

  cat >"$fake_kind" <<SCRIPT
#!/usr/bin/env bash
if [ "\$1" = get ]; then
  exit 0
fi
echo "kind \$*" >> "$log"
config="\${@: -1}"
cp "\$config" "$BATS_TEST_TMPDIR/captured-kind.yaml"
SCRIPT
  chmod +x "$fake_kind"

  cat >"$fake_docker" <<SCRIPT
#!/usr/bin/env bash
echo "docker \$*" >> "$log"
SCRIPT
  chmod +x "$fake_docker"

  custom_pg="$BATS_TEST_TMPDIR/custom-pg"
  custom_zot="$BATS_TEST_TMPDIR/custom-zot"
  custom_lp="$BATS_TEST_TMPDIR/custom-lp"

  run env KIND_BIN="$fake_kind" DOCKER_BIN="$fake_docker" \
    POSTGRES_DATA_DIR="$custom_pg" ZOT_CACHE_DIR="$custom_zot" LOCAL_PATH_DATA_DIR="$custom_lp" \
    CLUSTER_NAME="osramp" \
    "$repo_root/scripts/create-kind-cluster.sh"

  [ "$status" -eq 0 ]
  [ -d "$custom_pg" ]
  [ -d "$custom_zot" ]
  [ -d "$custom_lp" ]

  grep -Fq "hostPath: $custom_pg" "$BATS_TEST_TMPDIR/captured-kind.yaml"
  grep -Fq "hostPath: $custom_zot" "$BATS_TEST_TMPDIR/captured-kind.yaml"
  grep -Fq "hostPath: $custom_lp" "$BATS_TEST_TMPDIR/captured-kind.yaml"

  # Verify kind create was called
  grep -Fq "kind create cluster --name osramp" "$log"
}

@test "MOUNTS: in-node ownership preparation sets uid 70 for postgres and 65532 for zot" {
  fake_docker="$BATS_TEST_TMPDIR/docker-ownership"
  docker_log="$BATS_TEST_TMPDIR/docker-ownership.log"

  cat >"$fake_docker" <<SCRIPT
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
SCRIPT
  chmod +x "$fake_docker"

  source "$repo_root/scripts/lib/kind-data-mounts.sh"
  DOCKER_BIN="$fake_docker" prepare_node_data_mounts "test-cluster"

  grep -Fq "exec test-cluster-control-plane chown -R 70:70 /var/local/signalloom-postgres-data" "$docker_log"
  grep -Fq "exec test-cluster-control-plane chmod 0700 /var/local/signalloom-postgres-data" "$docker_log"
  grep -Fq "exec test-cluster-control-plane chown -R 65532:65532 /var/local/osramp-zot-cache" "$docker_log"
  grep -Fq "exec test-cluster-control-plane chmod 0750 /var/local/osramp-zot-cache" "$docker_log"
  grep -Fq "exec test-cluster-control-plane chmod 0777 /var/local-path-provisioner" "$docker_log"
}

@test "LOCALPATH: provisioner ConfigMap carries pathPattern and maps PVC to deterministic path" {
  local config_file="$repo_root/infra/kind/local-path-config.yaml"
  [ -f "$config_file" ]

  grep -Fq '"pathPattern": "{{ .PVC.Namespace }}/{{ .PVC.Name }}"' "$config_file"

  # Simulate path resolution for PVC "signal-store" in "d2-signalloom"
  local base_dir="/var/local-path-provisioner"
  local pattern='{{ .PVC.Namespace }}/{{ .PVC.Name }}'
  local pvc_ns="d2-signalloom"
  local pvc_name="signal-store"

  local resolved_rel
  resolved_rel="$(echo "$pattern" | sed "s/{{ \.PVC\.Namespace }}/$pvc_ns/g" | sed "s/{{ \.PVC\.Name }}/$pvc_name/g")"
  local full_path="$base_dir/$resolved_rel"

  [ "$full_path" = "/var/local-path-provisioner/d2-signalloom/signal-store" ]

  # Deleting and recreating the same PVC maps to identical path
  local recreated_pvc_ns="d2-signalloom"
  local recreated_pvc_name="signal-store"
  local recreated_rel
  recreated_rel="$(echo "$pattern" | sed "s/{{ \.PVC\.Namespace }}/$recreated_pvc_ns/g" | sed "s/{{ \.PVC\.Name }}/$recreated_pvc_name/g")"

  [ "$resolved_rel" = "$recreated_rel" ]
}
