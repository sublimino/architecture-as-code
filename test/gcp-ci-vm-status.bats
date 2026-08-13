#!/usr/bin/env bats
# `NOT_FOUND` must mean "the API answered and the VM is absent", never "we could
# not ask".
#
# vm_status() was `gcloud ... 2>/dev/null || echo NOT_FOUND`, which collapses
# every failure into absence. On 2026-08-13 an expired credential produced
#
#   ERROR: VM not found. Run './scripts/ci/gcp-ci.sh provision' first.
#
# against a VM that was present and healthy. Following that instruction spends
# ~11 minutes provisioning a duplicate — and for signalloom-ci the destroy path
# deletes the shared VPC that BOTH CI VMs depend on, so a misdiagnosis here is
# costlier than elsewhere.
#
# The function is extracted and driven against a stub gcloud so the three
# outcomes are exercised without touching GCP.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  script="${repo_root}/scripts/ci/gcp-ci.sh"
  stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"
}

# Runs the real vm_status() from the script against a stubbed gcloud.
run_vm_status() {
  local stderr_text="$1" exit_code="$2"
  cat >"$stub_dir/gcloud" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$stderr_text" >&2
exit $exit_code
STUB
  chmod +x "$stub_dir/gcloud"
  # Lift the function out rather than re-implementing it, so a reworded
  # implementation cannot silently stop being covered.
  local fn
  fn="$(sed -n '/^vm_status() {/,/^}/p' "$script")"
  PATH="$stub_dir:$PATH" bash -c "
    VM_NAME=stub; ZONE=stub; PROJECT=stub
    $fn
    vm_status
  "
}

@test "GCPSTATUS a healthy VM returns its real status" {
  cat >"$stub_dir/gcloud" <<'STUB'
#!/usr/bin/env bash
printf 'RUNNING\n'
STUB
  chmod +x "$stub_dir/gcloud"
  local fn
  fn="$(sed -n '/^vm_status() {/,/^}/p' "$script")"
  run env PATH="$stub_dir:$PATH" bash -c "VM_NAME=s; ZONE=s; PROJECT=s; $fn; vm_status"
  [ "$status" -eq 0 ]
  [ "$output" = "RUNNING" ]
}

@test "GCPSTATUS a genuinely absent VM is NOT_FOUND" {
  run run_vm_status "ERROR: (gcloud.compute.instances.describe) Could not fetch resource: - The resource 'projects/x/zones/y/instances/z' was not found" 1
  [ "$output" = "NOT_FOUND" ]
}

@test "GCPSTATUS an expired credential is AUTH_REQUIRED, not NOT_FOUND" {
  # The exact message seen on 2026-08-13.
  run run_vm_status "ERROR: (gcloud.compute.instances.list) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution." 1
  [ "$output" = "AUTH_REQUIRED" ]
  [ "$output" != "NOT_FOUND" ]
}

@test "GCPSTATUS a 'gcloud auth login' hint is AUTH_REQUIRED" {
  run run_vm_status "Please run: gcloud auth login to obtain new credentials." 1
  [ "$output" = "AUTH_REQUIRED" ]
}

@test "GCPSTATUS any other failure is QUERY_FAILED, never absence" {
  # A network blip must not read as "the VM is gone".
  run run_vm_status "ERROR: (gcloud.compute.instances.describe) Backend Error: connection reset by peer" 1
  [ "$output" = "QUERY_FAILED" ]
  [ "$output" != "NOT_FOUND" ]
}

@test "GCPSTATUS run refuses to advise provisioning when the state is unknown" {
  # The dangerous outcome is not the wrong word, it is the wrong ADVICE:
  # "run provision" against a healthy signalloom-ci risks the shared VPC.
  grep -Fq 'AUTH_REQUIRED)' "$script"
  grep -Fq 'QUERY_FAILED)' "$script"
  grep -Fq 'do NOT provision on this basis' "$script"
}
