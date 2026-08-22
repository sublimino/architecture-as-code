# shellcheck shell=bash
# fleet-source.sh — materialise the fleet source tree for the current
# ENABLE_OBSERVABILITY setting, and refuse to do it quietly wrong.
#
# ─── The incident this exists to prevent ────────────────────────────────────
#
# `ENABLE_OBSERVABILITY ?= false` is the intended state: the monitoring and
# trivy-system tenants must not be installed. Enforcing that has two halves
# which MUST agree:
#
#   push side     `acme/infra/monitoring` and `acme/infra/trivy-system` are
#                 never pushed to Zot.
#   reconcile side the `infra` ResourceSet in tenants/base/infra.yaml must not
#                 declare those tenants, or Flux creates a namespace, an
#                 OCIRepository and two Kustomizations pointing at artifacts
#                 that will never exist.
#
# Until 2026-08-22 the filtering lived inside push_foundation() alone. That was
# correct as far as it went — the sed matched, and `make push-local-foundation`
# published a two-tenant fleet. But THREE other paths publish the same
# `acme/fleet` artifact:
#
#   scripts/ci/vm-pipeline.sh:283   retry 3 make push-local-fleet
#   Makefile:455  demo-agent-trust-up:   $(MAKE) push-local-fleet
#   Makefile:506  demo-signalloom-up:    $(MAKE) push-local-fleet
#
# all of which reach `push-local.sh fleet` -> push_fleet, whose default argument
# was the raw, UNFILTERED `d2-osramp-fleet`. So every bring-up published the
# correct fleet at bootstrap and then overwrote it with the wrong one minutes
# later. Measured on sl-demo-1-vm 2026-08-22:
#
#   cert-manager/infra-controllers   12h   True    Applied
#   ingress/infra-controllers        12h   True    Applied
#   monitoring/infra-controllers      9h   False   Source artifact not found
#   trivy-system/infra-controllers    9h   False   Source artifact not found
#
# The three-hour age gap IS the bug: the two real tenants date from bootstrap,
# the two phantom ones from the later unfiltered push. Those four Kustomizations
# retry forever against NAME_UNKNOWN, the estate never converges, and three of
# four lanes ABORT at stage [5/8] on `context deadline exceeded`.
#
# ─── Why the filtering is a library and not an inline case ──────────────────
#
# Because the defect was not the sed. The defect was that ONE of four callers
# performed it. Putting the decision behind a single function that every fleet
# publisher must call makes the divergence unrepresentable rather than merely
# currently-absent.
#
# ─── Why every step asserts ─────────────────────────────────────────────────
#
# A range-delete sed that matches nothing deletes nothing and exits 0. This repo
# has been burned by scripted edits that no-op while printing success, so each
# removal here is bracketed: the tenant MUST be present before, and MUST be
# absent after. Removing a tenant that was never there is just as loud as
# failing to remove one that was — either means this file's assumptions about
# the fleet layout have drifted, and silently publishing a fleet that was not
# the one intended is exactly the failure mode above.

# The tenants that exist only when observability is enabled. The single source
# of truth for both halves — see fleet_infra_tenants() for how the push side
# derives its artifact list from the same place.
OBSERVABILITY_TENANTS=(monitoring trivy-system)

# Print the tenants a rendered fleet declares, one per line, in file order.
# Anchored at four spaces so it reads the ResourceSet's spec.inputs entries and
# nothing else.
fleet_infra_tenants() {
  local infra="$1"
  test -f "$infra" || {
    echo "fleet_infra_tenants: no such file: $infra" >&2
    return 1
  }
  sed -n 's/^    - tenant: "\([^"]*\)".*/\1/p' "$infra"
}

# Remove one tenant's spec.inputs entry from a fleet's base/infra.yaml.
#
# Loud on both edges: absent-before is an error, present-after is an error.
_fleet_strip_tenant() {
  local infra="$1" tenant="$2" before after

  before="$(grep -c "^    - tenant: \"${tenant}\"\$" "$infra" || true)"
  if [[ "$before" -eq 0 ]]; then
    echo "FATAL: fleet tenant '${tenant}' is not declared in ${infra}." >&2
    echo "       Nothing was removed. Either the tenant was already dropped or" >&2
    echo "       the spec.inputs layout changed and this filter no longer matches." >&2
    echo "       Refusing to publish a fleet whose contents are not the intended ones." >&2
    return 1
  fi

  sed -i "/^    - tenant: \"${tenant}\"\$/,/^      artifactSubjectGitRef: /d" "$infra"

  after="$(grep -c "tenant: \"${tenant}\"" "$infra" || true)"
  if [[ "$after" -ne 0 ]]; then
    echo "FATAL: fleet tenant '${tenant}' survived removal in ${infra}" >&2
    echo "       (${before} before, ${after} after). The range-delete did not" >&2
    echo "       consume the whole entry; publishing now would reinstate a tenant" >&2
    echo "       whose infra artifact is never pushed." >&2
    return 1
  fi
  return 0
}

# Materialise the fleet directory to publish for the given observability setting.
#
#   fleet_source_dir <src_fleet_dir> <dest_dir> <enable_observability>
#
# Prints the directory to publish on stdout. With observability enabled that is
# <src_fleet_dir> untouched; disabled, it is <dest_dir> holding a filtered copy.
#
# dest_dir is a caller-supplied path rather than an internal mktemp so the caller
# owns the lifetime (push-local.sh's cleanup trap) and so tests can point it
# anywhere — the injectable boundary that makes this verifiable without a
# cluster, a registry or a signing key.
fleet_source_dir() {
  local src="$1" dest="$2" enable="$3"

  case "$enable" in
    true)
      printf '%s\n' "$src"
      return 0
      ;;
    false) ;;
    *)
      echo "ENABLE_OBSERVABILITY must be true or false (got '${enable}')" >&2
      return 64
      ;;
  esac

  test -d "$src" || {
    echo "fleet_source_dir: no such fleet directory: $src" >&2
    return 1
  }

  mkdir -p "$dest"
  cp -a "$src/." "$dest"

  local infra="${dest}/tenants/base/infra.yaml"
  test -f "$infra" || {
    echo "FATAL: ${infra} is missing from the fleet copy; the observability" >&2
    echo "       filter has nothing to act on and would publish an unfiltered fleet." >&2
    return 1
  }

  local tenant
  for tenant in "${OBSERVABILITY_TENANTS[@]}"; do
    _fleet_strip_tenant "$infra" "$tenant" || return 1
  done

  # Belt and braces: the entries are gone from spec.inputs, but a tenant named
  # anywhere else in the fleet (an overlay patch, a dependsOn, a second
  # ResourceSet) is still a route back into the cluster and the range-delete
  # above would not have touched it.
  #
  # Scoped to YAML because Flux applies YAML and nothing else. d2-osramp-fleet's
  # own README.md documents the ResourceSet by quoting a `- tenant: "monitoring"`
  # block verbatim, and an unscoped grep reads that prose as a live manifest and
  # refuses every filtered push. Documentation describing a tenant is not a
  # delivery path for it.
  local stray
  for tenant in "${OBSERVABILITY_TENANTS[@]}"; do
    stray="$(grep -rl --include='*.yaml' --include='*.yml' \
      "tenant: \"${tenant}\"" "$dest" 2>/dev/null || true)"
    if [[ -n "$stray" ]]; then
      echo "FATAL: observability tenant '${tenant}' still referenced after filtering:" >&2
      # Unquoted on purpose: grep -rl emits one path per line and the split is
      # what gives printf one argument per file, hence one indented line each.
      # shellcheck disable=SC2086
      printf '       %s\n' $stray >&2
      return 1
    fi
  done

  # A filter that removed everything is as wrong as one that removed nothing.
  local remaining
  remaining="$(fleet_infra_tenants "$infra" | wc -l)"
  if [[ "$remaining" -eq 0 ]]; then
    echo "FATAL: filtering left no tenants at all in ${infra}" >&2
    return 1
  fi

  printf '%s\n' "$dest"
  return 0
}
