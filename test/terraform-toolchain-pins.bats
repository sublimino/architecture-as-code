#!/usr/bin/env bats
#
# Toolchain version pins must not diverge across the three installers.
#
# ─── The failure this exists to prevent ────────────────────────────────────
#
# terraform/modules/compute/startup/demo-vm.sh pinned kind at v0.24.0.
# scripts/ci/install-ci-tools.sh pinned 0.29.0. scripts/setup.sh pinned v0.29.0.
# One outlier against two that agreed. The startup script installs its version
# at boot AS ROOT; the pipeline then detects the mismatch and tries to upgrade,
# and the upgrade failed because curl cannot open a root-owned file for writing
# even in a writable directory. `make gcp-tf-demo-up ENV=demo-2` aborted there.
#
# Neither file was wrong on its own. That is precisely why a test has to compare
# them: there is no single file a reviewer could have read to see the defect.
#
# ─── Why this is a test rather than a shared constants file ────────────────
#
# demo-vm.sh is delivered as `metadata_startup_script` and executes before any
# repository exists on the instance. It cannot source a shared file. Duplication
# is therefore forced by the deployment mechanism. What is not forced is the
# duplication being unchecked — this suite is the enforcement half of "single
# source of truth", and it derives both sides rather than restating them.
#
# ─── Why nothing below hardcodes a version number ──────────────────────────
#
# A test that asserted `KIND_VERSION == 0.29.0` would need editing on every
# legitimate bump, and the edit that bumps one file is the edit that forgets the
# other — the same failure, one layer up. These read the pins out of the files
# and compare them to each other, so a correct bump to all three passes with no
# test change and a bump to one fails immediately.
#
# Offline: reads files. No network, no cloud, no terraform, no VM.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export STARTUP="${REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh"
  export CI_TOOLS="${REPO_ROOT}/scripts/ci/install-ci-tools.sh"
  export SETUP="${REPO_ROOT}/scripts/setup.sh"
}

setup() {
  load helpers/toolchain-contract
  # Presence first, always. A missing file makes every extractor below return
  # empty, and "no disagreements found" over two empty sets is a vacuous pass —
  # the exact shape this repo's suite-registration test exists to outlaw.
  [ -f "${STARTUP}" ]
  [ -f "${CI_TOOLS}" ]
  [ -f "${SETUP}" ]
}

# ── The extractors must actually extract ────────────────────────────────────
#
# Run FIRST and deliberately. Every assertion in this file is of the form "the
# two sets agree", and two empty sets agree perfectly. If the greps silently
# stopped matching — a reformat, a `readonly` added, quotes changed — this suite
# would go green having compared nothing at all. These tests are what make the
# green meaningful.

@test "the pin extractor finds pins in every installer (no vacuous pass)" {
  run toolchain_pins "${STARTUP}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # demo-vm.sh installs exactly two version-pinned tools.
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 2 ]

  run toolchain_pins "${CI_TOOLS}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 10 ]

  run toolchain_pins "${SETUP}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -ge 10 ]
}

@test "the pin extractor ignores a version string that appears only in a comment" {
  # install-ci-tools.sh carries the literal 'VEXCTL_VERSION=v0.3.0' inside a
  # prose comment, several lines above the real assignment. An unanchored grep
  # matches the comment, which would let the real pin be deleted while this
  # suite stayed green on the paragraph explaining it.
  local fixture="${BATS_TEST_TMPDIR}/comment-only.sh"
  cat >"${fixture}" <<'FIXTURE'
# Pinned to the same version setup.sh declares (VEXCTL_VERSION=v0.9.9). If the
# two ever disagree, whichever installer runs FIRST wins.
REAL_VERSION="1.0.0"
FIXTURE

  run toolchain_pin_for "${fixture}" VEXCTL
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run toolchain_pin_for "${fixture}" REAL
  [ "$status" -eq 0 ]
  [ "$output" = "1.0.0" ]
}

@test "the pin extractor normalises the v prefix" {
  local fixture="${BATS_TEST_TMPDIR}/prefixed.sh"
  printf 'readonly KIND_VERSION="v1.2.3"\nOTHER_VERSION="1.2.3"\n' >"${fixture}"

  [ "$(toolchain_pin_for "${fixture}" KIND)" = "1.2.3" ]
  [ "$(toolchain_pin_for "${fixture}" OTHER)" = "1.2.3" ]
}

# ── The contract itself ─────────────────────────────────────────────────────

@test "demo-vm.sh pins kind, and pins it to the version install-ci-tools.sh installs" {
  local startup_pin ci_pin
  startup_pin="$(toolchain_pin_for "${STARTUP}" KIND)"
  ci_pin="$(toolchain_pin_for "${CI_TOOLS}" KIND)"

  [ -n "$startup_pin" ] || {
    echo "demo-vm.sh declares no KIND_VERSION" >&2
    return 1
  }
  [ -n "$ci_pin" ] || {
    echo "install-ci-tools.sh declares no KIND_VERSION" >&2
    return 1
  }
  [ "$startup_pin" = "$ci_pin" ] || {
    echo "kind pin diverged: demo-vm.sh=${startup_pin} install-ci-tools.sh=${ci_pin}" >&2
    echo "The startup script installs its version at boot as root; the pipeline" >&2
    echo "then tries to upgrade over a root-owned binary. That is the demo-2 abort." >&2
    return 1
  }
}

@test "demo-vm.sh pins kubectl rather than resolving it at boot" {
  # The regression guarded here is not a wrong number, it is the ABSENCE of a
  # number: install_kubectl used to curl dl.k8s.io/release/stable.txt and
  # install whatever it named.
  local startup_pin ci_pin
  startup_pin="$(toolchain_pin_for "${STARTUP}" KUBECTL)"
  ci_pin="$(toolchain_pin_for "${CI_TOOLS}" KUBECTL)"

  [ -n "$startup_pin" ] || {
    echo "demo-vm.sh declares no KUBECTL_VERSION — kubectl is unpinned at boot" >&2
    return 1
  }
  [ "$startup_pin" = "$ci_pin" ] || {
    echo "kubectl pin diverged: demo-vm.sh=${startup_pin} install-ci-tools.sh=${ci_pin}" >&2
    return 1
  }
}

@test "demo-vm.sh never resolves a tool version over the network at boot" {
  # Matches the MECHANISM (a stable.txt fetch) rather than the tool name, so the
  # next tool wired up that way fails too.
  #
  # COMMENT LINES ARE STRIPPED FIRST, and that is not tidiness. The first draft
  # of this test grepped the whole file and failed against the two comments in
  # demo-vm.sh that EXPLAIN why stable.txt was removed. A guard that fires on the
  # prose documenting the fix is worse than no guard: it is loud, it looks like a
  # real finding, and the obvious way to silence it is to delete the explanation.
  # The repo has already lost a real signal to this exact shape.
  local code
  code="$(grep -v '^[[:space:]]*#' "${STARTUP}")"
  [ -n "$code" ] || { echo "stripped every line of ${STARTUP}" >&2; return 1; }

  printf '%s\n' "$code" | grep -q 'stable\.txt' && {
    echo "demo-vm.sh resolves a version from the network at boot:" >&2
    printf '%s\n' "$code" | grep -n 'stable\.txt' >&2
    echo "Two VMs built a week apart then run different versions, with nothing" >&2
    echo "recording which. Pin it beside KIND_VERSION instead." >&2
    return 1
  }
  return 0
}

@test "the comment-stripping in the stable.txt guard does not disarm it" {
  # Mutation control for the test above. Strip comments from a file that DOES
  # fetch stable.txt in code, and the match must survive; the guard must still
  # be able to fail. Without this, `grep -v '^#'` could be widened until nothing
  # was ever checked and both tests would stay green.
  local fixture="${BATS_TEST_TMPDIR}/fetches.sh"
  cat >"${fixture}" <<'FIXTURE'
# This comment mentions stable.txt and must not be what triggers the guard.
install_kubectl() {
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
}
FIXTURE

  local code
  code="$(grep -v '^[[:space:]]*#' "${fixture}")"
  printf '%s\n' "$code" | grep -q 'stable\.txt' || {
    echo "the guard cannot detect a real stable.txt fetch — it is disarmed" >&2
    return 1
  }

  # And the comment alone must NOT trigger it.
  #
  # `|| true` on the strip: when EVERY line is a comment, grep -v prints nothing
  # and exits 1, which under bats' errexit kills the test at the assignment
  # rather than at an assertion. That failure looks like a broken guard and is
  # actually a working one — the all-comments file is the case being tested.
  local prose="${BATS_TEST_TMPDIR}/prose.sh"
  printf '%s\n' '# We used to fetch https://dl.k8s.io/release/stable.txt at boot.' >"${prose}"
  code="$(grep -v '^[[:space:]]*#' "${prose}" || true)"
  printf '%s\n' "$code" | grep -q 'stable\.txt' && {
    echo "the guard fires on a comment" >&2
    return 1
  }
  return 0
}

@test "every tool pinned in both demo-vm.sh and install-ci-tools.sh agrees" {
  # The general form. Catches the NEXT tool someone adds to both files, which is
  # the failure mode the two named tests above cannot see.
  local tool a b disagreements=0 common
  common="$(toolchain_common_tools "${STARTUP}" "${CI_TOOLS}")"
  [ -n "$common" ] || {
    echo "no tool is pinned in both files — the comparison would be vacuous" >&2
    return 1
  }
  for tool in $common; do
    a="$(toolchain_pin_for "${STARTUP}" "$tool")"
    b="$(toolchain_pin_for "${CI_TOOLS}" "$tool")"
    if [ "$a" != "$b" ]; then
      echo "DIVERGED ${tool}: demo-vm.sh=${a} install-ci-tools.sh=${b}" >&2
      disagreements=$((disagreements + 1))
    fi
  done
  [ "$disagreements" -eq 0 ]
}

@test "every tool pinned in both setup.sh and install-ci-tools.sh agrees" {
  local tool a b disagreements=0 common
  common="$(toolchain_common_tools "${SETUP}" "${CI_TOOLS}")"
  [ -n "$common" ] || {
    echo "no tool is pinned in both files — the comparison would be vacuous" >&2
    return 1
  }
  for tool in $common; do
    a="$(toolchain_pin_for "${SETUP}" "$tool")"
    b="$(toolchain_pin_for "${CI_TOOLS}" "$tool")"
    if [ "$a" != "$b" ]; then
      echo "DIVERGED ${tool}: setup.sh=${a} install-ci-tools.sh=${b}" >&2
      disagreements=$((disagreements + 1))
    fi
  done
  [ "$disagreements" -eq 0 ]
}

# ── The install mechanism (defect 1) ────────────────────────────────────────

@test "install-ci-tools.sh never curls directly onto a path under BIN" {
  # The defect verbatim: `${SUDO} curl -fsSL -o "${BIN}/kind" ...`. SUDO is
  # empty whenever the DIRECTORY is writable, but the FILE was root-owned, so
  # curl took EACCES and exited 23.
  #
  # Matches the mechanism (`curl` with `-o` naming something under ${BIN}), not
  # a tool name, so the next tool added the old way fails too.
  run grep -nE 'curl[^|]*-o[[:space:]]+"?\$\{BIN\}/' "${CI_TOOLS}"
  [ "$status" -ne 0 ] || {
    echo "install-ci-tools.sh writes a download straight onto its destination:" >&2
    echo "$output" >&2
    echo "Use install_binary, which downloads to a temp file and unlinks the" >&2
    echo "destination before installing." >&2
    return 1
  }
}

@test "install-ci-tools.sh unlinks a destination before installing over it" {
  # `install` alone is NOT sufficient and this is the assertion that says so:
  # GNU install opens the destination with O_TRUNC and takes the same EACCES on
  # a root-owned file. Removing the directory entry needs write permission on
  # the DIRECTORY, which is what the SUDO probe already established.
  #
  # Scoped to the two helper function bodies rather than the whole file, so the
  # long comment above them cannot satisfy it.
  local body
  body="$(sed -n '/^install_binary() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || {
    echo "install_binary is not defined in ${CI_TOOLS}" >&2
    return 1
  }
  # The unlink now lives in bin_place, which every placement goes through, so
  # this asserts DELEGATION here and the mechanism there. Asserting the old
  # inline `${SUDO} rm -f` would be asserting a mechanism that legitimately
  # moved — a test failing because the code improved.
  printf '%s\n' "$body" | grep -q 'bin_place ' || {
    echo "install_binary does not place through bin_place:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
  local place
  place="$(sed -n '/^bin_place() {/,/^}/p' "${CI_TOOLS}")"
  printf '%s\n' "$place" | grep -qE 'rm -f "\$dest"' || {
    echo "bin_place does not unlink the destination before installing" >&2
    printf '%s\n' "$place" >&2
    return 1
  }
  printf '%s\n' "$place" | grep -qE 'install -m "\$mode"' || {
    echo "bin_place does not install with an explicit mode" >&2
    return 1
  }

  body="$(sed -n '/^install_from_tarball() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || {
    echo "install_from_tarball is not defined in ${CI_TOOLS}" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -q 'bin_place ' || {
    echo "install_from_tarball does not place through bin_place" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "the anchore installer also unlinks before installing" {
  # install_anchore_tool used `${SUDO} install` with no preceding rm, so it
  # carried the identical defect one function further down.
  local body
  body="$(sed -n '/^install_anchore_tool() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || {
    echo "install_anchore_tool is not defined" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -q 'bin_place ' || {
    echo "install_anchore_tool installs without going through bin_place" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

# ── The three tools v2 dropped ──────────────────────────────────────────────
#
# scripts/ci/vm-startup.sh (the v1 CI VM) installs node, bun and uv.
# terraform/modules/compute/startup/demo-vm.sh (v2) installs none of them and
# claimed "node arrives with the Playwright setup", which is false — the
# Playwright step RUNS `npx playwright install chrome` and has never provided
# npx. Every fresh v2 VM therefore failed on npx, then bun, then uv, one full
# forty-minute run apart.
#
# Derived from the CONSUMERS, not from a list kept here: the assertion is "every
# command the pipeline invokes is installed by something", so a tool added to
# demo-pipeline.sh later is covered without editing this file.

@test "every tool the demo pipeline invokes is installed by install-ci-tools.sh" {
  local pipe="${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
  local vmpipe="${REPO_ROOT}/scripts/ci/vm-pipeline.sh"
  [ -f "$pipe" ]
  [ -f "$vmpipe" ]

  # The runtime interpreters the two pipelines shell out to. Each is a real
  # call site, cited so this list is auditable rather than asserted:
  #   node/npx  vm-pipeline.sh   `sudo npx playwright install chrome`
  #   bun/bunx  demo-pipeline.sh `bun install --frozen-lockfile`, `bun run test`
  #   uv        demo-pipeline.sh `uv run --python 3.12 --with pytest`
  local missing=""
  local tool
  for tool in node bun uv; do
    toolchain_pin_for "${CI_TOOLS}" "$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')" \
      | grep -q . || missing="${missing} ${tool}"
  done

  [ -z "$missing" ] || {
    echo "install-ci-tools.sh pins no version for:${missing}" >&2
    echo "" >&2
    echo "These are invoked by the pipelines and provided by nothing in the v2" >&2
    echo "lane. v1's scripts/ci/vm-startup.sh installs all three; demo-vm.sh does" >&2
    echo "not. That gap is three separate forty-minute failures, one per run." >&2
    return 1
  }
}

@test "the pipeline's own tool contract names nothing that is unprovided" {
  # demo-pipeline.sh states its dependencies in prose:
  #   "Everything below needs only the tools installed above: bats, bun, uv, go"
  # uv was named there while being installed by nobody. Parsing the claim and
  # checking it turns that comment into something testable.
  local pipe="${REPORT_UNUSED:-${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh}"
  local claim
  claim="$(grep -oE 'needs only the tools installed above: [a-z, ]+' "$pipe" | head -1)"
  [ -n "$claim" ] || skip "the pipeline no longer states a tool contract in prose"

  local tools tool missing=""
  tools="$(printf '%s' "$claim" | sed 's/.*above: //' | tr ',' ' ')"
  for tool in $tools; do
    case "$tool" in
      # Provided by setup.sh or the base image rather than by pinned download.
      go | bats) continue ;;
    esac
    grep -qE "^${tool^^}_VERSION=" "${CI_TOOLS}" || missing="${missing} ${tool}"
  done

  [ -z "$missing" ] || {
    echo "demo-pipeline.sh claims these tools are installed, and none pins them:${missing}" >&2
    return 1
  }
}

@test "node, bun and uv are fetched as pinned artefacts, never piped into a shell" {
  # v1 does `curl https://bun.sh/install | bash` and `curl
  # https://astral.sh/uv/install.sh | sh`, both as root. The pinned VERSION is
  # an argument to an UNPINNED PROGRAM, and it is the program that holds the
  # privileges — the same defect the syft/grype block in this file documents.
  #
  # Comment lines stripped, because the block explaining this quotes both of
  # those commands.
  local code
  code="$(grep -v '^[[:space:]]*#' "${CI_TOOLS}")"
  [ -n "$code" ]

  printf '%s\n' "$code" | grep -qE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' && {
    echo "install-ci-tools.sh pipes a downloaded script into a shell:" >&2
    printf '%s\n' "$code" | grep -nE 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' >&2
    return 1
  }
  return 0
}

@test "every pinned artefact download is checksum-verified before it is unpacked" {
  # PER TOOL, not a global count. The first version of this test counted
  # occurrences and asserted >= 4 on the theory that the definition line would
  # match too — it does not (`verify_against_sidecar() {` has no quote after the
  # name), so the threshold was wrong by one and the test failed for a reason
  # that had nothing to do with the code under test.
  #
  # Counting is the weaker assertion anyway: three calls could all sit in one
  # block while another tool went unverified. Scoping to each tool's own install
  # block is what actually proves "every download is checked".
  local tool block missing=""
  for tool in node bun uv; do
    # From the tool's version gate to the `fi` that closes it.
    block="$(sed -n "/^if ! ${tool} --version/,/^fi\$/p" "${CI_TOOLS}")"
    if [ -z "$block" ]; then
      missing="${missing} ${tool}(no-install-block)"
      continue
    fi
    printf '%s\n' "$block" | grep -q 'verify_against_sidecar "' \
      || missing="${missing} ${tool}(unverified)"
    # And the verification must precede the unpack/install, which the `&&` chain
    # is what guarantees — a verify on its own line after the unpack would be
    # decoration.
    printf '%s\n' "$block" | grep -qE '&&[[:space:]]*(\\)?$|&& verify_against_sidecar' \
      || missing="${missing} ${tool}(not-chained)"
  done

  [ -z "$missing" ] || {
    echo "artefact verification is missing or unchained for:${missing}" >&2
    echo "" >&2
    echo "Each of node/bun/uv must fetch, then verify against the publisher's" >&2
    echo "sidecar, then unpack — && chained so a bad checksum aborts before tar" >&2
    echo "or unzip ever reads the file." >&2
    return 1
  }

  # And the verifier itself must exist and fail closed.
  local body
  body="$(sed -n '/^verify_against_sidecar() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || { echo "verify_against_sidecar is not defined" >&2; return 1; }
  printf '%s\n' "$body" | grep -q 'return 1' || {
    echo "verify_against_sidecar has no failure path" >&2
    return 1
  }
}

@test "verify_against_sidecar actually rejects a bad digest and accepts a good one" {
  # Executes the real function rather than reading it. A checksum verifier that
  # returns success on a mismatch is the single worst failure mode available
  # here, and this repo has already caught one: install_anchore_tool's first
  # version printed its warning, carried on, and returned the exit status of a
  # trailing `rm -rf` — zero.
  #
  # No network: the sidecar is a file:// URL, which curl handles natively.
  local dir="${BATS_TEST_TMPDIR}/sidecar"
  mkdir -p "$dir"
  printf 'payload contents\n' >"${dir}/artefact.tar.gz"
  local real
  real="$(sha256sum "${dir}/artefact.tar.gz" | cut -d' ' -f1)"

  # shellcheck source=/dev/null
  source <(sed -n '/^log() {/,/^}/p;/^verify_against_sidecar() {/,/^}/p' "${CI_TOOLS}")

  printf '%s  artefact.tar.gz\n' "$real" >"${dir}/good.txt"
  run verify_against_sidecar "${dir}/artefact.tar.gz" "file://${dir}/good.txt"
  [ "$status" -eq 0 ] || {
    echo "a CORRECT digest was rejected: ${output}" >&2
    return 1
  }

  printf '%s  artefact.tar.gz\n' "$(printf '0%.0s' {1..64})" >"${dir}/bad.txt"
  run verify_against_sidecar "${dir}/artefact.tar.gz" "file://${dir}/bad.txt"
  [ "$status" -ne 0 ] || {
    echo "a WRONG digest was accepted — the verifier is decorative" >&2
    return 1
  }

  # A sidecar that lists other files but not ours must be refused, not silently
  # treated as "nothing to check".
  printf '%s  some-other-file.tar.gz\n' "$real" >"${dir}/absent.txt"
  run verify_against_sidecar "${dir}/artefact.tar.gz" "file://${dir}/absent.txt"
  [ "$status" -ne 0 ] || {
    echo "a sidecar with no entry for our artefact was accepted" >&2
    return 1
  }
}

@test "demo-vm.sh names the real provider for node, bun and uv" {
  # A POSITIVE assertion, deliberately, and the choice matters.
  #
  # The defect was a comment: demo-vm.sh's prerequisite list claimed "node
  # arrives with the Playwright setup", which is false, and that single sentence
  # cost three forty-minute runs. The obvious guard is "the file must not
  # contain that phrase" — and it is a bad guard twice over. First, the file now
  # RECOUNTS the false claim in order to explain it, so an absence check either
  # fires on the explanation or has to be narrowed until it means nothing.
  # Second, absence-of-bad is trivially satisfied by nothing-present: delete the
  # whole prerequisite list and the check goes green.
  #
  # So this asserts the list makes the CORRECT claim instead. Deleting the
  # comment fails it; rewriting it back to the Playwright story fails it; only
  # naming the file that genuinely installs them passes.
  local list
  list="$(sed -n '/^# Deliberately NOT here/,/^install_base_packages() {/p' "${STARTUP}")"
  [ -n "$list" ] || {
    echo "demo-vm.sh has no 'Deliberately NOT here' prerequisite list" >&2
    return 1
  }
  printf '%s\n' "$list" | grep -qE 'node/bun/uv[[:space:]]+scripts/ci/install-ci-tools\.sh' || {
    echo "the prerequisite list does not name install-ci-tools.sh as the" >&2
    echo "provider of node, bun and uv:" >&2
    printf '%s\n' "$list" >&2
    return 1
  }
}

@test "the summary loop reports the tools this script installs" {
  # The trailing `for t in ...` loop is what an operator reads to confirm a VM
  # is complete. A tool installed but absent from that list is invisible in the
  # one place someone looks.
  local loop
  loop="$(grep -oE '^for t in [a-z0-9 ]+; do' "${CI_TOOLS}")"
  [ -n "$loop" ] || {
    echo "no summary loop found in ${CI_TOOLS}" >&2
    return 1
  }
  local tool missing=""
  for tool in node bun uv; do
    printf '%s' "$loop" | grep -qE "[[:space:]]${tool}[[:space:]]" || missing="${missing} ${tool}"
  done
  [ -z "$missing" ] || {
    echo "the summary loop omits:${missing}" >&2
    echo "loop: ${loop}" >&2
    return 1
  }
}

@test "no tool is placed into BIN except through bin_place" {
  # bun and uv failed on a rebuilt VM with "install: cannot create regular file
  # '/usr/local/bin/bun': Permission denied", while node succeeded on the same
  # run — node uses ${PKG_SUDO} (always sudo when not root), bun and uv used
  # ${SUDO}, which is a snapshot of a directory mode the CALLER mutates on both
  # sides of this script. Routing every placement through one helper is what
  # makes the privilege decision happen at write time instead of at line 27.
  # bin_place's OWN body contains `${SUDO} install -m "$mode"` — that is the
  # one legitimate occurrence, and an unscoped grep fires on it. Fourth time
  # tonight a guard has matched its own source; excluding the helper's body is
  # what makes the assertion mean "no CALLER bypasses the helper".
  local code
  code="$(
    grep -v '^[[:space:]]*#' "${CI_TOOLS}" \
      | sed '/^bin_place() {/,/^}/d'
  )"
  [ -n "$code" ]

  printf '%s\n' "$code" | grep -qE '\$\{SUDO\} install ' && {
    echo "a raw '\${SUDO} install' remains outside bin_place:" >&2
    printf '%s\n' "$code" | grep -nE '\$\{SUDO\} install ' >&2
    return 1
  }
  printf '%s\n' "$code" | grep -q 'bin_place ' || {
    echo "bin_place is never called" >&2
    return 1
  }
  return 0
}

@test "bin_place escalates when the cached probe was wrong, and verifies the result" {
  local body
  body="$(sed -n '/^bin_place() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || { echo "bin_place is not defined" >&2; return 1; }

  printf '%s\n' "$body" | grep -q 'sudo -n install' || {
    echo "bin_place never escalates; a wrong probe stays fatal" >&2; return 1; }
  printf '%s\n' "$body" | grep -q 'NOTE:' || {
    echo "bin_place escalates SILENTLY. A repair with no alarm is how the broken" >&2
    echo "assumption survives — the run goes green and nobody learns the probe" >&2
    echo "was wrong." >&2
    return 1; }
  printf '%s\n' "$body" | grep -qE '\[ ! -x "\$dest" \]' || {
    echo "bin_place does not verify the destination exists afterwards" >&2
    return 1; }
}

@test "bin_place really places, really escalates, and really fails — executed" {
  # Executed against the real function, with SUDO forced empty, which is the
  # exact state that produced the live failure.
  local dir="${BATS_TEST_TMPDIR}/bin" src="${BATS_TEST_TMPDIR}/src"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho hi\n' >"$src"

  # `log` is a ONE-LINER — `log() { printf ...; }` — so a
  # `sed '/^log() {/,/^}/p'` range never terminates on its own line and swallows
  # everything up to the next line that STARTS with `}`, producing an unparseable
  # fragment (observed: source exits 2). Only bin_place is extracted; log is
  # stubbed here.
  log() { printf '[ci-tools] %s\n' "$*"; }
  # shellcheck source=/dev/null
  source <(sed -n '/^bin_place() {/,/^}/p' "${CI_TOOLS}")
  SUDO=""
  BIN="$dir"

  # 1. Writable destination: succeeds without escalating.
  run bin_place "$src" "${dir}/tool"
  [ "$status" -eq 0 ] || { echo "failed on a writable dir: $output" >&2; return 1; }
  [ -x "${dir}/tool" ]
  [[ "$output" != *"NOTE:"* ]] || {
    echo "escalated when it did not need to: $output" >&2; return 1; }

  # 2. Unwritable destination with no usable sudo: must FAIL, not pretend.
  #    PATH is emptied so `sudo` cannot be found, modelling "escalation is not
  #    available" without depending on this machine's sudoers.
  chmod 0555 "$dir"
  run env PATH=/nonexistent bash -c "
    $(declare -f log bin_place)
    SUDO=''; BIN='${dir}'
    bin_place '${src}' '${dir}/blocked'
  "
  chmod 0755 "$dir"
  [ "$status" -ne 0 ] || {
    echo "bin_place reported success into an unwritable directory" >&2
    echo "$output" >&2
    return 1
  }
}

@test "a tool that fails to install stops the run at the point of failure" {
  # It did not. bun and uv each logged one ERROR line and the pipeline carried
  # on to Chrome and ffmpeg before aborting for an unrelated reason twenty
  # minutes later, so the verdict described the symptom furthest from the cause.
  local body tool
  body="$(sed -n '/^die_tool() {/,/^}/p' "${CI_TOOLS}")"
  [ -n "$body" ] || { echo "die_tool is not defined" >&2; return 1; }
  printf '%s\n' "$body" | grep -q 'exit 1' || {
    echo "die_tool does not exit" >&2; return 1; }

  # Each of the three must actually call it on its failure branch.
  for tool in node bun uv; do
    sed -n "/^if ! ${tool} /,/^fi\$/p" "${CI_TOOLS}" | grep -q 'die_tool' || {
      echo "${tool}'s install block does not abort the run when it fails" >&2
      return 1
    }
  done
}

@test "the mutation harness refuses to start on a leaked sentinel, and does not repair" {
  # A bash EXIT trap survives SIGTERM (tested, contrary to common belief) but not
  # SIGKILL — which is what a tool timeout escalates to. A killed harness leaves
  # a mutated REAL file in the tree, and the next gate then reports a failure in
  # a file nobody edited, on a green branch, from a conflict-free merge. That
  # reads as a merge regression and cost a teammate half an hour tonight.
  #
  # The sentinel turns that into one clear line. This test proves three things:
  # it refuses, it names the file, and it does NOT quietly fix the tree —
  # auto-repair would hide that a destructive run was interrupted, which is the
  # "mitigation that silences its own alarm" shape being removed everywhere else
  # in this change.
  local proof="${REPO_ROOT}/test/toolchain-mutation-proof.sh"
  [ -f "$proof" ]

  local sentinel="${REPO_ROOT}/.mutation-in-progress"
  [ ! -e "$sentinel" ] || skip "a real mutation run is in progress"

  # A canary: if the harness repaired rather than refused, it would restore
  # every file it manages, so an unrelated edit here must survive untouched.
  local canary="${BATS_TEST_TMPDIR}/canary"
  cp "${REPO_ROOT}/scripts/ci/install-ci-tools.sh" "$canary"

  printf 'mutation:  synthetic\nfile:      scripts/ci/install-ci-tools.sh\n' >"$sentinel"
  run bash "$proof"
  local status_seen="$status" output_seen="$output"
  rm -f "$sentinel"

  [ "$status_seen" -eq 4 ] || {
    echo "expected exit 4 on a leaked sentinel, got ${status_seen}" >&2
    echo "$output_seen" >&2
    return 1
  }
  [[ "$output_seen" == *"did not complete"* ]] || {
    echo "the refusal does not explain itself: ${output_seen}" >&2
    return 1
  }
  [[ "$output_seen" == *"install-ci-tools.sh"* ]] || {
    echo "the refusal does not name the mutated file" >&2
    return 1
  }
  [[ "$output_seen" == *"will not repair"* ]] || {
    echo "the refusal does not state that it declines to repair" >&2
    return 1
  }
  # And it really did not touch the tree.
  cmp -s "$canary" "${REPO_ROOT}/scripts/ci/install-ci-tools.sh" || {
    echo "the harness modified the tree when it should only have refused" >&2
    return 1
  }
}

@test "install-ci-tools.sh is syntactically valid" {
  run bash -n "${CI_TOOLS}"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}

@test "demo-vm.sh is syntactically valid" {
  run bash -n "${STARTUP}"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
}
