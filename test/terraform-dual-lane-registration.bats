#!/usr/bin/env bats
#
# A suite can be registered and still run in only one lane.
#
# ── Why this is a SECOND guard and not a tightening of the first ────────────
#
# d2-signalloom/test/bats-registry-coverage.bats asks "does ANY runner invoke
# this suite". That is the correct definition of an ORPHAN, and it is the
# question that ended the 33-suites-invoked-by-nothing defect. It is not the
# question a lane cares about.
#
# This repository has two hand-maintained pipeline lists:
#
#   scripts/gcp-tf/demo-pipeline.sh   the demo lane
#   scripts/ci/vm-pipeline.sh         the CI lane
#
# A suite named in one and not the other is invoked, so the orphan guard is
# satisfied and reports coverage -- while the suite runs in half the estate.
# Reproduced independently by two agents before this file existed: deleting a
# suite from vm-pipeline.sh alone left bats-registry-coverage.bats 9/9 green.
#
# Tightening the orphan guard to demand dual registration was considered and
# rejected. Some suites are legitimately lane-specific, so that change would
# trade a false negative for a false positive in a guard that currently has
# neither -- and a guard that cries wolf is one people learn to skip, at which
# point the real orphan it exists for goes past unread. That argument is already
# written down at bats-registry-coverage.bats:392. So: separate file, narrower
# question, and an explicit policy for the asymmetries that are real decisions.
#
# ── The policy ─────────────────────────────────────────────────────────────
#
# Dual registration is the default. An asymmetry must be named in
# SINGLE_LANE_ALLOWED below WITH a stated reason, in the shape EXCLUDED_BATS
# uses in d2-signalloom/Makefile -- entries plus a comment naming each file.
#
# The allowlist is held to the same standard as the thing it excuses. An entry
# must name a file that exists (test 4), must carry a reason (test 5), and must
# still be genuinely single-lane (test 6). Test 6 is the one that stops this
# list rotting into blanket pre-approval: an entry whose suite has since been
# registered in both lanes is a stale permission slip, and it would silently
# excuse a FUTURE de-registration of that same suite.
#
# ── Single-lane allowlist ──────────────────────────────────────────────────
#
#   test/gcp-demo-pipeline.bats
#       Demo lane only. It is the demo pipeline's OWN control-flow suite: it
#       drives scripts/gcp-tf/demo-pipeline.sh against stubs and asserts what
#       that file exports. There is nothing for it to assert about the CI lane,
#       and demo-pipeline.sh:809 states the reason at its run_stage.
#
#   test/supervise-port-forward-knobs.bats
#       Demo lane only, and deliberately paired with gcp-demo-pipeline.bats in
#       the same stage rather than filed with the static guards. Its sibling
#       asserts the CALLER (PF_ADDRESS, the TLS probe URL) against a stub
#       supervisor and cannot say whether the real script honours them; this one
#       asserts the callee. demo-pipeline.sh:819-826 states the reason, and
#       records a standing unexplained CI-VM-only failure of that stage
#       (2026-08-20) which is a further reason not to widen its blast radius to
#       a second lane until it is understood.
#
# Offline: reads two files and the test/ directory. No network, no cluster, no
# make, no bats-in-bats.

SINGLE_LANE_ALLOWED="test/gcp-demo-pipeline.bats test/supervise-port-forward-knobs.bats"

# The extraction floor. Both lists held 52 suites when this file was written.
# A floor rather than an equality so the guard does not need editing every time
# a suite lands, and it exists at all because the failure mode of a comment
# stripper or a token regex is to return NOTHING -- at which point every set
# difference below is empty and this file passes by measuring nothing.
DUAL_LANE_FLOOR=40

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export DEMO_PIPELINE="${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
  export VM_PIPELINE="${REPO_ROOT}/scripts/ci/vm-pipeline.sh"
}

setup() {
  # Presence first, always. A missing pipeline file would make every extraction
  # empty, and "empty" is indistinguishable from "symmetric" in a set diff.
  [ -f "${DEMO_PIPELINE}" ]
  [ -f "${VM_PIPELINE}" ]
}

# Every repo-root bats suite a pipeline file INVOKES, one per line.
#
# Comments are stripped before matching, and that is load-bearing. Both files
# discuss suites by name in their rationale comments at length -- this file's
# own header names four -- so a reader of the raw text cannot distinguish a
# registration from a sentence about one. `grep -rl` counting a MENTION as an
# invocation has already shipped here once (bats-registry-coverage.bats:432).
#
# The token pattern captures the WHOLE path, directory prefix included, and the
# comparison is `grep -qxF` on whole lines. Both halves of that are anchoring,
# and both were got wrong in a first draft:
#
#   * `\btest/[^ ]+\.bats` looks path-anchored and is not. `\b` sits happily
#     between the `/` and the `t` of `d2-signalloom/test/runtime.bats`, so that
#     suite extracted as `test/runtime.bats` and would have collided with a
#     repo-root suite of the same name -- two different files reported as one.
#     Both lanes list the same d2-signalloom suites, so the collision cancelled
#     out and every test passed. A guard that is wrong symmetrically is still
#     wrong; it just cannot be caught by looking at the result.
#   * an unanchored `grep -qF` treats `test/ci-lock.bats` as present when only
#     `test/ci-lock2.bats` is, so RENAMING a suite in one lane leaves every test
#     about it green. That is the trap that cost another guard in this repo five
#     tests; the mutation proof drives the rename case specifically.
lane_suites() {
  sed 's/#.*//' "$1" \
    | grep -oE '(^|[^A-Za-z0-9._/-])[A-Za-z0-9._/-]*test/[A-Za-z0-9._-]+\.bats' \
    | sed 's|^[^A-Za-z0-9._/-]||' \
    | sort -u
}

allowed() {
  printf '%s\n' ${SINGLE_LANE_ALLOWED}
}

@test "DUALREG both lane suite lists are non-empty and above the floor" {
  # The mechanism assertion. Everything below is a set difference, and a set
  # difference against an empty set is empty -- so a broken stripper or a
  # regex that stopped matching would make this whole file pass while looking
  # at nothing. That is the precise shape the guard family exists to end, so
  # the family's own newest member asserts its own mechanism first.
  local demo vm dn vn
  demo="$(lane_suites "${DEMO_PIPELINE}")"
  vm="$(lane_suites "${VM_PIPELINE}")"

  dn="$(printf '%s\n' "$demo" | grep -c . || true)"
  vn="$(printf '%s\n' "$vm" | grep -c . || true)"

  [ "$dn" -ge "${DUAL_LANE_FLOOR}" ] || {
    echo "extracted only ${dn} suite(s) from ${DEMO_PIPELINE} (floor ${DUAL_LANE_FLOOR})"
    echo "The extractor is broken, not the pipeline. Refusing to compare."
    return 1
  }
  [ "$vn" -ge "${DUAL_LANE_FLOOR}" ] || {
    echo "extracted only ${vn} suite(s) from ${VM_PIPELINE} (floor ${DUAL_LANE_FLOOR})"
    echo "The extractor is broken, not the pipeline. Refusing to compare."
    return 1
  }

  # And the allowlist must be readable as a list, not as one blob. EXCLUDED_BATS
  # shipped exactly that bug: a space-separated variable fed to `grep -vxF`
  # matched no filename at all and BOTH exclusions became silent no-ops.
  local an
  an="$(grep -c . <<< "$(allowed)" || true)"
  [ "$an" -ge 1 ]
  # ANCHORED, and the anchoring is the point. The first draft asked
  # `[[ "$e" == test/*.bats ]]`, which a blob passes: glob `*` spans spaces, so
  # the single line "test/a.bats test/b.bats" starts with test/ and ends in
  # .bats and was accepted as one well-formed entry. The mutation proof reported
  # it as a HOLE (MUT-ALLOWLIST-BLOB) — this repo's exact EXCLUDED_BATS defect
  # reproduced in the guard written to remember it.
  local e
  while read -r e; do
    [ -n "$e" ] || continue
    [[ "$e" =~ ^test/[A-Za-z0-9._-]+\.bats$ ]] || {
      echo "allowlist entry '${e}' is not a single test/<name>.bats path."
      echo "A space-separated blob reaching here means the allowlist is being"
      echo "read as one string, so every entry in it excuses nothing."
      return 1
    }
  done < <(allowed)
}

@test "DUALREG every suite the demo lane runs is also run by the CI lane" {
  local demo vm allow missing="" s
  demo="$(lane_suites "${DEMO_PIPELINE}")"
  vm="$(lane_suites "${VM_PIPELINE}")"
  # Materialised, then matched with a here-string. `allowed | grep -q` is the
  # form to avoid: `grep -q` exits the moment it matches and closes the pipe, so
  # the writer can take SIGPIPE and under `set -o pipefail` the pipeline reports
  # FAILURE precisely when the pattern MATCHED. It survives on a two-line
  # allowlist because printf finishes first, which makes it a latent flake that
  # appears when the list grows -- the worst kind, since it inverts a policy
  # decision rather than erroring.
  allow="$(allowed)"

  while read -r s; do
    [ -n "$s" ] || continue
    # terraform-*.bats are owned by `make gcp-tf-validate` and are asserted to be
    # absent from vm-pipeline.sh by bats-registry-coverage.bats. If one appears
    # in a pipeline at all that is the other guard's finding, not this one's.
    case "$s" in test/terraform-*.bats) continue ;; esac
    grep -qxF "$s" <<< "$vm" && continue
    grep -qxF "$s" <<< "$allow" && continue
    missing="${missing}${s} "
  done <<< "$demo"

  [ -z "$missing" ] || {
    echo "Registered in the demo lane and NOT in the CI lane:"
    echo "  ${missing}"
    echo ""
    echo "Such a suite is invoked -- so the orphan guard is satisfied -- and runs"
    echo "in one of the two lanes. Either name it in scripts/ci/vm-pipeline.sh"
    echo "too, or add it to SINGLE_LANE_ALLOWED in this file WITH a reason."
    return 1
  }
}

@test "DUALREG every suite the CI lane runs is also run by the demo lane" {
  local demo vm allow missing="" s
  demo="$(lane_suites "${DEMO_PIPELINE}")"
  vm="$(lane_suites "${VM_PIPELINE}")"
  allow="$(allowed)"

  while read -r s; do
    [ -n "$s" ] || continue
    case "$s" in test/terraform-*.bats) continue ;; esac
    grep -qxF "$s" <<< "$demo" && continue
    grep -qxF "$s" <<< "$allow" && continue
    missing="${missing}${s} "
  done <<< "$vm"

  [ -z "$missing" ] || {
    echo "Registered in the CI lane and NOT in the demo lane:"
    echo "  ${missing}"
    echo ""
    echo "This is the direction that has already happened twice unnoticed:"
    echo "acceptance-gateway-forward.bats and resourceset-inputs-declarative.bats"
    echo "were both added to vm-pipeline.sh alone. Either name it in"
    echo "scripts/gcp-tf/demo-pipeline.sh too, or add it to SINGLE_LANE_ALLOWED"
    echo "in this file WITH a reason."
    return 1
  }
}

@test "DUALREG every allowlisted single-lane suite exists on disk" {
  # A stale allowlist entry is worse than none: it reads as reviewed-and-accepted
  # while describing nothing, and it would silently pre-approve a file of that
  # name if one were reintroduced later. This is also the RENAME detector -- an
  # entry survives a rename of its suite looking perfectly healthy.
  local stale="" e
  while read -r e; do
    [ -n "$e" ] || continue
    [ -f "${REPO_ROOT}/${e}" ] || stale="${stale}${e} "
  done < <(allowed)

  [ -z "$stale" ] || {
    echo "SINGLE_LANE_ALLOWED names suite(s) that do not exist:"
    echo "  ${stale}"
    echo "Renamed or deleted? Update the entry and its reason, or drop both."
    return 1
  }
}

@test "DUALREG every allowlisted single-lane suite has a stated reason" {
  # An exclusion without a reason is an accident wearing a decision's clothes.
  # The reason must be a comment IN THIS FILE naming the suite -- the allowlist
  # assignment line itself names every entry, so the match must exclude it or
  # every entry would document itself.
  local missing="" e reasons
  reasons="$(grep '^#' "${BATS_TEST_FILENAME}")"
  while read -r e; do
    [ -n "$e" ] || continue
    grep -qF "$(basename "$e")" <<< "$reasons" || missing="${missing}${e} "
  done < <(allowed)

  [ -z "$missing" ] || {
    echo "SINGLE_LANE_ALLOWED entries with no stated reason in this file:"
    echo "  ${missing}"
    return 1
  }
}

@test "DUALREG no allowlist entry is stale: each is registered in exactly one lane" {
  # The entry that has quietly stopped being an exception. Once a suite is in
  # both lanes its allowlist entry excuses nothing -- and worse, it standing
  # permission for a future de-registration of that suite, which is the thing
  # this file exists to catch. Also fires on an entry naming a suite that is in
  # NEITHER lane, which is an orphan wearing an exemption.
  local demo vm bad="" e ind ivm
  demo="$(lane_suites "${DEMO_PIPELINE}")"
  vm="$(lane_suites "${VM_PIPELINE}")"

  while read -r e; do
    [ -n "$e" ] || continue
    ind=0; ivm=0
    grep -qxF "$e" <<< "$demo" && ind=1
    grep -qxF "$e" <<< "$vm" && ivm=1
    [ $((ind + ivm)) -eq 1 ] || bad="${bad}${e}(demo=${ind},ci=${ivm}) "
  done < <(allowed)

  [ -z "$bad" ] || {
    echo "SINGLE_LANE_ALLOWED entries that are not single-lane:"
    echo "  ${bad}"
    echo ""
    echo "demo=1,ci=1 means the exemption is spent -- delete the entry and its"
    echo "reason so a later de-registration is caught. demo=0,ci=0 means the"
    echo "suite is in neither lane, which is an orphan holding an exemption."
    return 1
  }
}
