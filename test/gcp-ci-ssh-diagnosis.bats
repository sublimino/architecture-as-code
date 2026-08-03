#!/usr/bin/env bats
#
# gcp-ci.sh must tell a local SSH failure apart from a VM that is still coming up.
#
# `wait_for_provision` polls for a marker file over IAP SSH and used to discard
# stderr entirely, which made two very different situations identical:
#
#   * the VM has not finished provisioning yet  -> keep waiting, correct
#   * ssh on THIS machine cannot authenticate   -> waiting is futile
#
# Observed 2026-08-03: an ssh-agent refusing to sign produced "ERROR: Timed out
# waiting for VM startup provisioning" after ten minutes, pointing at a VM that
# had finished in 124s with `startup-script exit status 0` on the serial console
# and the marker file present throughout. Roughly ten minutes lost looking in
# the wrong place.
#
# The classifier is the whole fix, so it gets a table test. It also nearly
# shipped a far worse bug than the one it fixes: gcloud prints "External IP
# address was not found; defaulting to using IAP tunneling." on EVERY IAP
# connection, and a bare `*"was not found"*` pattern therefore classified every
# healthy run as terminal and aborted it on the first attempt. That is why the
# benign-chatter cases below are as important as the failure cases.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  script="$root/scripts/ci/gcp-ci.sh"
  # Source only the classifier. gcp-ci.sh is `set -euo pipefail` with top-level
  # readonly config and a subcommand dispatch, so sourcing the whole file would
  # execute it.
  eval "$(awk '/^ssh_probe_error\(\)/,/^}/' "$script")"
}

# Terminal: no amount of waiting fixes these, so fail fast with the real reason.
@test "GCPSSH an ssh-agent refusing to sign is terminal, not a slow VM" {
  run ssh_probe_error "sign_and_send_pubkey: signing failed for RSA key from agent: agent refused operation"
  [ "$status" -eq 1 ]
}

@test "GCPSSH publickey rejection is terminal" {
  run ssh_probe_error "ci@vm: Permission denied (publickey)."
  [ "$status" -eq 1 ]
}

@test "GCPSSH too many authentication failures is terminal" {
  run ssh_probe_error "Received disconnect: Too many authentication failures"
  [ "$status" -eq 1 ]
}

@test "GCPSSH a missing instance is terminal" {
  run ssh_probe_error "ERROR: (gcloud.compute.ssh) Instance [signalloom-ci] was not found in zone [europe-west2-a]"
  [ "$status" -eq 1 ]
}

@test "GCPSSH an IAP IAM denial is terminal" {
  run ssh_probe_error "PERMISSION_DENIED: Required 'iap.tunnelInstances.accessViaIAP' permission"
  [ "$status" -eq 1 ]
}

# Retryable: the VM is genuinely still coming up, or gcloud is just talking.
@test "GCPSSH an absent marker file with no error is retryable" {
  run ssh_probe_error ""
  [ "$status" -eq 0 ]
}

@test "GCPSSH sshd not yet listening is retryable" {
  run ssh_probe_error "ssh: connect to host 10.0.0.13 port 22: Connection refused"
  [ "$status" -eq 0 ]
}

@test "GCPSSH a connection timeout is retryable" {
  run ssh_probe_error "ssh: connect to host 10.0.0.13 port 22: Connection timed out"
  [ "$status" -eq 0 ]
}

@test "GCPSSH gcloud's routine IAP notice must NOT abort the run" {
  # THE regression guard. This string appears on every single IAP connection.
  # Classifying it terminal aborts every healthy run on the first attempt --
  # strictly worse than the timeout bug this change set out to fix.
  run ssh_probe_error "External IP address was not found; defaulting to using IAP tunneling."
  [ "$status" -eq 0 ]
}

@test "GCPSSH the benign notice stays retryable even alongside a transient error" {
  run ssh_probe_error "External IP address was not found; defaulting to using IAP tunneling.
ssh: connect to host 10.0.0.13 port 22: Connection refused"
  [ "$status" -eq 0 ]
}

@test "GCPSSH the real failure is still caught when gcloud's notice precedes it" {
  # stderr carries both lines in practice; the terminal one must still win.
  run ssh_probe_error "External IP address was not found; defaulting to using IAP tunneling.
sign_and_send_pubkey: signing failed for RSA key from agent: agent refused operation"
  [ "$status" -eq 1 ]
}

@test "GCPSSH the polling loop captures SSH stderr instead of discarding it" {
  # Scope matters here. There are two probes for the marker file:
  #
  #   1. the retry loop inside wait_for_provision -- MUST capture stderr, because
  #      it is the only thing that can tell "still booting" from "ssh is broken";
  #   2. a one-shot guard in cmd_provision (`if RUNNING && ! marker; then
  #      wait_for_provision; fi`) -- may discard it, because a failure there just
  #      routes into (1), which then produces the real diagnosis.
  #
  # An earlier version of this test asserted the string was absent from the whole
  # file. That was too broad -- it flagged (2), which is fine. It is kept scoped
  # rather than deleted because the loop is the part that regressed.
  loop="$(awk '/^wait_for_provision\(\)/,/^}/' "$script")"
  echo "$loop" | grep -qF 'iap_ssh "sudo test -f /home/ci/.provisioned" 2>/dev/null' \
    && { echo "wait_for_provision is discarding SSH stderr again"; return 1; }
  echo "$loop" | grep -qF 'err_file'
}

@test "GCPSSH the timeout message points at the serial console" {
  # The old message blamed the VM with no way to check. Whatever the cause, the
  # reader should be told how to see what the VM actually did.
  run grep -F 'get-serial-port-output' "$script"
  [ "$status" -eq 0 ]
}
