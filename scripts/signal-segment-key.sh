#!/usr/bin/env bash
#
# signal-segment-key.sh - mint the signal-ingest segment pseudonymisation key.
#
# @id     signal-segment-key
# @tests  test/signal-segment-key.bats
# @doc    docs/signalloom/sldp-downstream-contract.md
#
# signal-ingest with SIGNAL_STORE=frostdb refuses to start without
# SIGNAL_SEGMENT_PSEUDONYM_KEY (store/segment_pseudonymiser.go: at least 32
# bytes of hex-encoded root key material) and an epoch. policy-engine refuses
# to LOAD a bundle that declares actor_vars without the same two values
# (apps/policy-engine/store.go), and exits at boot when it cannot.
#
# The key is per CLUSTER, not per service: it is an HMAC domain. signal-ingest
# (fe-signalloom) and policy-engine (fe-signalloom, and inf-signalloom where
# scripts/supercred-demo.sh applies the same base) must derive IDENTICAL
# pseudonyms or a cross-component join silently produces non-matching values
# and compares two pseudonyms of the same actor as different actors. So ONE key
# is read or generated, and that one key is applied to EVERY namespace that
# mounts the Secret. Generating a second key for a second namespace splits the
# domain, which fails silently — never do it.
#
# Targets default to fe-signalloom and inf-signalloom; override with
# SIGNAL_SEGMENT_NAMESPACES="ns-a ns-b". The key never appears on argv: it
# reaches kubectl on stdin.
#
# A Secret that already exists is kept, and its key is propagated to any target
# namespace that lacks it or holds a different one (re-running with every target
# in sync is a no-op); --rotate writes one fresh key and one bumped epoch to all
# targets together, which starts a new pseudonym domain (the downstream
# contract, section 2): rotate only with that consequence in mind.
#
# Usage: scripts/signal-segment-key.sh --context CONTEXT [--rotate]
set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
NS_PRIMARY="fe-signalloom"
read -r -a NS_TARGETS <<<"${SIGNAL_SEGMENT_NAMESPACES:-fe-signalloom inf-signalloom}"
SECRET="signal-ingest-segment-pseudonym"

usage() { sed -n '3,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'signal-segment-key: %s\n' "$1" >&2; exit "${2:-1}"; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -d 2>/dev/null || true; }

# secret_field CONTEXT NS FIELD -> the stored (base64) value, or empty.
secret_field() {
  ${KUBECTL} --context "$1" -n "$2" get secret "${SECRET}" \
    -o "jsonpath={.data.$3}" 2>/dev/null || true
}

# apply_secret CONTEXT NS KEY_B64 EPOCH_B64
#
# kubectl apply reads the manifest from stdin: printf is a builtin, so the key
# is never an argument to an exec'd process. (Shell function arguments are not
# in any process's /proc cmdline either.)
apply_secret() {
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  SIGNAL_SEGMENT_PSEUDONYM_KEY: %s\n  SIGNAL_SEGMENT_PSEUDONYM_EPOCH: %s\n' \
    "${SECRET}" "$2" "$3" "$4" \
    | ${KUBECTL} --context "$1" apply -f - >/dev/null \
    || die "kubectl apply failed for context $1 (namespace $2)" 1
}

# The read order: the primary namespace first when it is a target, so a run
# where fe-signalloom already holds a key brings the others up to THAT key.
read_order() {
  local ns found=0
  for ns in "${NS_TARGETS[@]}"; do
    [ "${ns}" = "${NS_PRIMARY}" ] && found=1
  done
  [ "${found}" -eq 1 ] && printf '%s\n' "${NS_PRIMARY}"
  for ns in "${NS_TARGETS[@]}"; do
    [ "${ns}" = "${NS_PRIMARY}" ] || printf '%s\n' "${ns}"
  done
}

main() {
  local context="" rotate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (the key is per cluster)" 2
  [ "${#NS_TARGETS[@]}" -gt 0 ] || die "SIGNAL_SEGMENT_NAMESPACES is empty" 2
  ${KUBECTL} --context "${context}" cluster-info >/dev/null 2>&1 \
    || die "cluster context ${context} is unreachable" 1

  # Read the existing key ONCE, from the first target that has one.
  local src_ns="" existing_key="" existing_epoch="" ns
  while IFS= read -r ns; do
    local candidate
    candidate="$(secret_field "${context}" "${ns}" SIGNAL_SEGMENT_PSEUDONYM_KEY)"
    if [ -n "${candidate}" ]; then
      src_ns="${ns}"
      existing_key="${candidate}"
      existing_epoch="$(secret_field "${context}" "${ns}" SIGNAL_SEGMENT_PSEUDONYM_EPOCH)"
      break
    fi
  done < <(read_order)

  local key_b64 epoch_b64 epoch action
  if [ "${rotate}" -eq 1 ]; then
    # One new key, one bumped epoch, for every target together.
    local old_epoch; old_epoch="$(unb64 "${existing_epoch}")"
    case "${old_epoch}" in
      '') epoch="1" ;;
      *[!0-9]*) epoch="2" ;;
      *) epoch="$((old_epoch + 1))" ;;
    esac
    key_b64="$(b64 "$(generate_key_hex)")"
    epoch_b64="$(b64 "${epoch}")"
    action="rotated"
  elif [ -n "${existing_key}" ]; then
    # Propagate the EXISTING key. Generating a fresh one here would split the
    # HMAC domain between namespaces, which no component would ever report.
    key_b64="${existing_key}"
    epoch_b64="${existing_epoch}"
    [ -n "${epoch_b64}" ] || epoch_b64="$(b64 1)"
    epoch="$(unb64 "${epoch_b64}")"
    action="propagated"
  else
    epoch="1"
    key_b64="$(b64 "$(generate_key_hex)")"
    epoch_b64="$(b64 "${epoch}")"
    action="created"
  fi
  [ -n "${key_b64}" ] || die "could not generate 32 bytes of key material" 1

  # Only the targets that do not already hold exactly this key and epoch.
  local -a pending=()
  for ns in "${NS_TARGETS[@]}"; do
    local have_key have_epoch
    have_key="$(secret_field "${context}" "${ns}" SIGNAL_SEGMENT_PSEUDONYM_KEY)"
    have_epoch="$(secret_field "${context}" "${ns}" SIGNAL_SEGMENT_PSEUDONYM_EPOCH)"
    if [ "${have_key}" != "${key_b64}" ] || [ "${have_epoch}" != "${epoch_b64}" ]; then
      pending+=("${ns}")
    fi
  done

  if [ "${#pending[@]}" -eq 0 ]; then
    printf 'segment pseudonym key kept on %s (%s in %s, epoch %s)\n' \
      "${context}" "${SECRET}" "$(IFS=,; printf '%s' "${NS_TARGETS[*]}")" "${epoch}"
    return 0
  fi

  for ns in "${pending[@]}"; do
    apply_secret "${context}" "${ns}" "${key_b64}" "${epoch_b64}"
  done

  if [ "${action}" = "propagated" ]; then
    printf 'segment pseudonym key propagated from %s on %s (%s in %s, epoch %s)\n' \
      "${src_ns}" "${context}" "${SECRET}" "$(IFS=,; printf '%s' "${pending[*]}")" "${epoch}"
  else
    printf 'segment pseudonym key %s on %s (%s in %s, epoch %s)\n' \
      "${action}" "${context}" "${SECRET}" "$(IFS=,; printf '%s' "${pending[*]}")" "${epoch}"
  fi
}

generate_key_hex() {
  local key_hex
  key_hex="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ "${#key_hex}" -eq 64 ] || return 1
  printf '%s' "${key_hex}"
}

main "$@"
