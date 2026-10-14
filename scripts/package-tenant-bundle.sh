#!/usr/bin/env bash
# Circularity Warning & Verification Integrity:
# 'bash -n' is merely a syntax parser check and proves no runtime behavior.
# A manifest computed from files just downloaded ('sha256sum * > checksums.txt')
# is circular and self-attesting; it trivially passes 'sha256sum -c' even if the
# files are wrong-architecture, wrong-version, or HTML 404 error pages.
# True integrity requires:
# 1. Pinned upstream literal SHA-256 digests published independently by the project.
# 2. Comparison against the literal digest while the download is still an opaque blob.
# 3. Binary ELF machine header inspection (readelf -h) matching the target architecture.
# 4. Exact-equality version verification against the pin.
#
# Sibling Fencing & Read-Only Policy:
# P1-1 owns the preamble (shebang, strict mode, traps, helpers, argument parsing)
# and the P1-1 sentinel region.
# The preamble and sentinel regions for P1-2, P1-3, and P1-4 are strictly READ-ONLY
# to any card other than their declared owner.

set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "ERROR: command failed at line ${LINENO}: ${BASH_COMMAND}" >&2; exit 1' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Helper library sourcing (P1-PRE contract requirement):
# shellcheck source=scripts/lib/wait.sh
source "${REPO_ROOT}/scripts/lib/wait.sh"
# shellcheck source=scripts/lib/image-identity.sh
source "${REPO_ROOT}/scripts/lib/image-identity.sh"
# OSD-1: the first-party export records the identity its Dockerfiles bake in,
# and computes it with the same library the build sites and the staleness guard
# use. A second implementation here could drift from theirs the moment one was
# edited, and a fingerprint computed a different way compares unequal to a
# correct deployment.
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

SLSI_VERSION="${SLSI_VERSION:-0.1.0}"
VERSION_PATTERN='^[0-9A-Za-z][0-9A-Za-z._-]*$'

validate_version_string() {
  local ver="$1"
  if [[ -z "${ver}" ]]; then
    fail "SLSI_VERSION cannot be empty"
  fi
  if [[ ! "${ver}" =~ ${VERSION_PATTERN} ]]; then
    fail "Invalid SLSI_VERSION '${ver}': must match pattern '${VERSION_PATTERN}' (alphanumeric start, only [0-9A-Za-z._-], no slashes, no leading dot)"
  fi
}

usage() {
  cat <<'EOF'
Usage: scripts/package-tenant-bundle.sh [OPTIONS]

Options:
  --bundle-dir DIR   Target directory for bundle (default: <repo-root>/bundle)
  --version, -v VER  Bundle release version (default: 0.1.0 or $SLSI_VERSION)
  --arch ARCH        Target architecture: amd64, arm64, or all (default: all)
  --only TOOL        Stage or inspect only the specified tool
  --verify-only      Verify existing bundle offline without network calls
  --check-pins       Validate pin table and upstream digest definitions
  --help             Show this help message
EOF
}

BUNDLE_DIR="${REPO_ROOT}/bundle"
TARGET_ARCH="all"
FILTER_TOOL=""
VERIFY_ONLY=0
CHECK_PINS=0
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -c log.showSignature=false log -1 --format=%ct 2>/dev/null || date -u +%s)}"
SOURCE_DATE_UTC="$(date -u -d "@${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ')"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle-dir)
        BUNDLE_DIR="$2"
        shift 2
        ;;
      --version|-v)
        SLSI_VERSION="$2"
        shift 2
        ;;
      --arch)
        TARGET_ARCH="$2"
        shift 2
        ;;
      --only)
        FILTER_TOOL="$2"
        shift 2
        ;;
      --verify-only)
        VERIFY_ONLY=1
        shift
        ;;
      --check-pins)
        CHECK_PINS=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

# >>> SLSI-P1-1: binary staging and sha256 manifest <<<
# P1-1: Multi-arch binary collection and sha256 manifest generation
# Tools: kind, kubectl, flux, cosign, jq (pinned upstream downloads)
#        ed25519-keygen (built from this repository's own source)
# Arches: amd64, arm64
#
# Decision 10 is REVERSED. It containerised openssl and envsubst into
# docker.io/controlplane/slsi-util:v0.1.0 and generated `docker run` wrappers
# into bundle/bin/<arch>/. That image was never published and no Dockerfile for
# it exists anywhere in this tree; three independent channels agree it does not
# exist (crane digest MANIFEST_UNKNOWN, docker manifest inspect "no such
# manifest", registry API UNAUTHORIZED). Shipping a wrapper that execs a
# non-existent image is worse than shipping nothing, because it reads as a
# supported capability.
#
# Neither tool is shipped now. openssl cannot be pinned the way the five Go
# binaries are -- upstream publishes source tarballs only, zero binaries, and
# GNU gettext is the same -- and the appliance-side requirement was never
# "openssl": it was two Ed25519 keypairs and a key-id derivation, all three in
# `make signing-keys`. cmd/ed25519-keygen does exactly that and is staged here
# like any other tool. Every appliance-side envsubst reference is Flux's own
# in-cluster envsubst, not the host tool, so nothing replaces it.
#
# ed25519-keygen is the one staged binary whose digest is NOT a pinned literal,
# and that distinction is load-bearing rather than an omission. The other five
# are third-party downloads, so a literal pin is the only way to know you got
# what upstream published. This one is compiled from the commit being bundled,
# so a literal would have to be regenerated on every source change and would
# assert nothing about provenance that the source tree does not already
# assert. It is instead built reproducibly (-trimpath, -ldflags=-buildid=,
# CGO_ENABLED=0) and its digest is computed at stage time; --check-pins
# re-builds and compares, which is a stronger claim than matching a constant
# someone typed.
ED25519_KEYGEN_MODULE_REL="d2-signalloom/apps/fleet-manager"
ED25519_KEYGEN_PKG="./cmd/ed25519-keygen"
declare -A ED25519_KEYGEN_SHA256=()
# The helper's "version" is the commit it was compiled from. `git -c
# log.showSignature=false` because log.showSignature is set in some of this
# project's checkouts and inlines five lines of gpg output into STDOUT, not
# stderr, which would end up inside versions.txt.
ED25519_KEYGEN_SOURCE_REV="$(git -c log.showSignature=false rev-parse --short HEAD 2>/dev/null || echo unknown)"

PIN_KIND_VERSION="v0.29.0"
PIN_KUBECTL_VERSION="v1.33.2"
PIN_FLUX_VERSION="2.6.4"
PIN_COSIGN_VERSION="v3.0.6"
PIN_JQ_VERSION="1.7.1"

# Pinned literal upstream digests (never computed from downloads):
# Direct binary downloads:
KIND_AMD64_SHA256="c72eda46430f065fb45c5f70e7c957cc9209402ef309294821978677c8fb3284"
KIND_ARM64_SHA256="03d45095dbd9cc1689f179a3e5e5da24b77c2d1b257d7645abf1b4174bebcf2a"
KUBECTL_AMD64_SHA256="33d0cdec6967817468f0a4a90f537dfef394dcf815d91966ca651cc118393eea"
KUBECTL_ARM64_SHA256="54dc02c8365596eaa2b576fae4e3ac521db9130e26912385e1e431d156f8344d"
COSIGN_AMD64_SHA256="c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74"
COSIGN_ARM64_SHA256="bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8"
JQ_AMD64_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
JQ_ARM64_SHA256="4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5"

# Upstream archive digests (tarball blob checked before extraction):
FLUX_AMD64_ARCHIVE_SHA256="9d3e21ad53baa0d5a062e1bd6f1a22d18b95906c682845bca9ffa272cff8a590"
FLUX_ARM64_ARCHIVE_SHA256="674e605f527841bb9b50a692b3ce497752cfc81438f85b4d1523d86aca637353"

# Extracted member binary digests:
FLUX_AMD64_BINARY_SHA256="c3fe63dad655a8d3b16c722e72e21fcaeb56f53f6b50de2da95290cc34b03028"
FLUX_ARM64_BINARY_SHA256="028abcb4a6e306112459f59f768a0f4da66056f885a6eeaea97a6d9052862e53"

# Assert exact version comparison functions:
verify_exact_version_equality() {
  local tool="$1"
  local actual_ver="$2"
  local expected_ver="$3"
  if [[ "$tool" == "kind" ]]; then
    if [[ "${actual_ver}" == "$PIN_KIND_VERSION" ]]; then
      log "Version match for kind: ${actual_ver}"
      return 0
    fi
  elif [[ "$tool" == "kubectl" ]]; then
    if [[ "${actual_ver}" == "$PIN_KUBECTL_VERSION" ]]; then
      log "Version match for kubectl: ${actual_ver}"
      return 0
    fi
  elif [[ "$tool" == "flux" ]]; then
    if [[ "${actual_ver}" == "$PIN_FLUX_VERSION" ]]; then
      log "Version match for flux: ${actual_ver}"
      return 0
    fi
  elif [[ "$tool" == "cosign" ]]; then
    if [[ "${actual_ver}" == "$PIN_COSIGN_VERSION" ]]; then
      log "Version match for cosign: ${actual_ver}"
      return 0
    fi
  elif [[ "$tool" == "jq" ]]; then
    if [[ "${actual_ver}" == "$PIN_JQ_VERSION" ]]; then
      log "Version match for jq: ${actual_ver}"
      return 0
    fi
  fi
  fail "Version mismatch for ${tool}: expected exact ${expected_ver}, got ${actual_ver}"
}

check_pin_entry() {
  local tool="$1"
  local arch="$2"
  local expected_sha="$3"
  local bin_path="${BUNDLE_DIR}/bin/${arch}/${tool}"

  if [[ ! -f "${bin_path}" ]]; then
    log "${tool} [${arch}]: UNVERIFIED (artefact absent at ${bin_path})"
    return 1
  fi

  local actual_sha
  actual_sha="$(sha256sum "${bin_path}" | awk '{print $1}')"

  if [[ "${actual_sha}" == "${expected_sha}" ]]; then
    log "${tool} [${arch}]: PASS (computed sha256 matches pinned literal ${expected_sha})"
    return 0
  else
    log "${tool} [${arch}]: FAIL (digest mismatch for ${bin_path}: expected ${expected_sha}, computed ${actual_sha})"
    return 1
  fi
}

# build_ed25519_keygen ARCH DEST — compile the key helper for ARCH into DEST
# and print its sha256. Reproducible: -trimpath drops the build path and
# -buildid= drops the one remaining nondeterministic field, so two builds of
# the same source with the same toolchain are byte-identical (verified on both
# arches). CGO_ENABLED=0 keeps it static, as the five downloads are.
#
# -buildvcs=false is load-bearing, not tidiness. Go stamps vcs.revision and
# vcs.modified into the binary by default, so without it the digest changes on
# EVERY commit -- measured: the same source produced bade2fc7... at one commit
# and 469883883... with the stamps suppressed. Two consequences, both bad. The
# digest recorded in checksums.txt would be stale the moment anything in the
# repo changed, helper or not. And --check-pins compares the staged artefact
# against a rebuild, so a merely DIRTY tree (vcs.modified=true) would flip the
# stamp and report a digest mismatch -- a failure that looks like tampering and
# is nothing of the kind. With the stamps off, the digest is a function of the
# helper's source and the toolchain, which is what a staged-binary digest
# should mean. The toolchain dependency is real and remains: a different Go
# minor version produces different bytes.
build_ed25519_keygen() {
  local arch="$1" dest="$2"
  local module="${REPO_ROOT}/${ED25519_KEYGEN_MODULE_REL}"

  if [[ ! -d "${module}/cmd/ed25519-keygen" ]]; then
    fail "ed25519-keygen source absent at ${module}/cmd/ed25519-keygen; it ships with fleet-manager"
  fi
  if ! command -v go >/dev/null 2>&1; then
    fail "go toolchain is required to build ed25519-keygen from source (no binary is downloaded for it)"
  fi

  mkdir -p "$(dirname "${dest}")" "${TMPDIR:-/tmp}/go/pkg/mod" "${TMPDIR:-/tmp}/go-cache"
  if ! GOOS=linux GOARCH="${arch}" CGO_ENABLED=0 \
      GOPATH="${TMPDIR:-/tmp}/go" GOMODCACHE="${TMPDIR:-/tmp}/go/pkg/mod" GOCACHE="${TMPDIR:-/tmp}/go-cache" \
      go -C "${module}" build -trimpath -buildvcs=false -ldflags=-buildid= -o "${dest}" "${ED25519_KEYGEN_PKG}"; then
    fail "go build of ed25519-keygen for ${arch} failed"
  fi
  chmod 0755 "${dest}"
  sha256sum "${dest}" | awk '{print $1}'
}

# check_ed25519_keygen_reproducible ARCH — rebuild and compare against the
# staged artefact. This replaces a literal pin with a reproducibility claim:
# the staged binary must be exactly what this source tree produces.
check_ed25519_keygen_reproducible() {
  local arch="$1"
  local staged="${BUNDLE_DIR}/bin/${arch}/ed25519-keygen"

  if [[ ! -f "${staged}" ]]; then
    log "ed25519-keygen [${arch}]: UNVERIFIED (artefact absent at ${staged})"
    return 1
  fi

  local tmp_dir rebuilt_sha staged_sha rc=0
  tmp_dir="$(mktemp -d "/tmp/slsi-pin-ed25519-${arch}.XXXXXX")"
  rebuilt_sha="$(build_ed25519_keygen "${arch}" "${tmp_dir}/ed25519-keygen")"
  staged_sha="$(sha256sum "${staged}" | awk '{print $1}')"
  rm -rf "${tmp_dir}"

  if [[ "${staged_sha}" == "${rebuilt_sha}" ]]; then
    log "ed25519-keygen [${arch}]: PASS (staged sha256 ${staged_sha} reproduced from source)"
  else
    log "ed25519-keygen [${arch}]: FAIL (staged ${staged_sha} is not what this source tree builds: ${rebuilt_sha})"
    rc=1
  fi
  return "${rc}"
}

check_all_pins() {
  log "Validating declared pin table for 5 downloaded Go utilities against bundle/bin/..."
  local failures=0

  check_pin_entry "kind" "amd64" "${KIND_AMD64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "kind" "arm64" "${KIND_ARM64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "kubectl" "amd64" "${KUBECTL_AMD64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "kubectl" "arm64" "${KUBECTL_ARM64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "flux" "amd64" "${FLUX_AMD64_BINARY_SHA256}" || failures=$((failures + 1))
  check_pin_entry "flux" "arm64" "${FLUX_ARM64_BINARY_SHA256}" || failures=$((failures + 1))
  check_pin_entry "cosign" "amd64" "${COSIGN_AMD64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "cosign" "arm64" "${COSIGN_ARM64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "jq" "amd64" "${JQ_AMD64_SHA256}" || failures=$((failures + 1))
  check_pin_entry "jq" "arm64" "${JQ_ARM64_SHA256}" || failures=$((failures + 1))

  # ed25519-keygen is verified by reproduction, not by a literal (see the
  # header note). A failure here means the staged binary is not what this
  # commit builds, which is the same class of finding as a digest mismatch.
  log "Validating ed25519-keygen by rebuilding it from source at this commit..."
  check_ed25519_keygen_reproducible "amd64" || failures=$((failures + 1))
  check_ed25519_keygen_reproducible "arm64" || failures=$((failures + 1))

  if [[ ${failures} -ne 0 ]]; then
    fail "Pin table validation failed: ${failures} binary pin check(s) failed or unverified"
  fi
  return 0
}

verify_offline_manifest() {
  local anchor_dir="${BUNDLE_DIR}/bin"
  local manifest="${anchor_dir}/checksums.txt"

  if [[ ! -d "${anchor_dir}" ]]; then
    fail "Anchor directory not found: ${anchor_dir}"
  fi
  if [[ ! -f "${manifest}" ]]; then
    fail "Manifest not found: ${manifest}"
  fi

  log "Verifying bundle integrity offline with anchor directory ${anchor_dir}..."

  local manifest_line_count
  manifest_line_count="$(grep -c -v '^[[:space:]]*$' "${manifest}")"

  # Completeness check: ensure no unlisted files in anchor_dir.
  #
  # The listed paths are extracted once and compared as exact strings. An
  # earlier revision interpolated the candidate path into a grep basic regex
  # ("[[:space:]]${rel}$") with neither -F nor escaping, so a planted file
  # named amd64/ki.d matched the manifest entry for amd64/kind and passed
  # completeness at rc=0. Measured: 'amd64/ki.d' and 'amd64/k..d' both match
  # that entry, 'amd64/kixd' does not. Exact comparison removes the whole class
  # rather than escaping one metacharacter.
  local -a listed_paths=()
  mapfile -t listed_paths < <(
    awk '{ line=$0; sub(/^[^ \t]+[ \t]+\*?/, "", line); if (line != "") print line }' "${manifest}"
  )
  ((${#listed_paths[@]} > 0)) || {
    echo "manifest ${manifest} contains no files" >&2
    exit 1
  }
  local -A listed_set=()
  local lp
  for lp in "${listed_paths[@]}"; do
    listed_set["${lp}"]=1
  done

  # Only the two self-describing metadata files are exempt from the checksum
  # manifest. Under Decision 10 the openssl and envsubst wrappers were exempt
  # too, which was the only reason an unlisted executable could sit in
  # bundle/bin/<arch>/ and still pass completeness. With the wrappers gone that
  # hole closes: every executable in the tree is now listed, ed25519-keygen
  # included. Exemptions are exact paths, never a '*/openssl' glob, which would
  # also skip any planted file whose name happened to end that way.
  local -A wrapper_exempt=()
  local arch
  for arch in amd64 arm64; do
    wrapper_exempt["${arch}/versions.txt"]=1
  done
  wrapper_exempt["checksums.txt"]=1

  local unlisted=()
  while IFS= read -r f; do
    local rel="${f#"${anchor_dir}/"}"
    if [[ -n "${wrapper_exempt[${rel}]:-}" ]]; then
      continue
    fi
    if [[ -z "${listed_set[${rel}]:-}" ]]; then
      unlisted+=("${rel}")
    fi
  done < <(find "${anchor_dir}" -type f | sort)

  if [[ ${#unlisted[@]} -gt 0 ]]; then
    fail "Completeness violation: unlisted file(s) present in ${anchor_dir}: ${unlisted[*]}"
  fi

  # Explicitly execute from the anchor directory
  local check_output
  check_output="$(cd "${anchor_dir}" && sha256sum -c "checksums.txt")"
  echo "${check_output}"

  local ok_count
  ok_count="$(grep -c ': OK$' <<< "${check_output}")"

  if [[ "${ok_count}" -ne "${manifest_line_count}" ]]; then
    fail "Manifest verification mismatch: expected ${manifest_line_count} OK results, got ${ok_count}"
  fi

  log "Manifest verification succeeded: all ${ok_count} entries verified and anchor complete"
}

stage_single_tool() {
  local tool="$1"
  local arch="$2"
  local dest_dir="${BUNDLE_DIR}/bin/${arch}"
  local dest_bin="${dest_dir}/${tool}"

  local url=""
  local expected_blob_sha=""
  local expected_bin_sha=""
  local expected_ver=""
  local is_archive=0

  case "$tool" in
    kind)
      url="https://github.com/kubernetes-sigs/kind/releases/download/${PIN_KIND_VERSION}/kind-linux-${arch}"
      expected_ver="${PIN_KIND_VERSION}"
      if [[ "$arch" == "amd64" ]]; then
        expected_blob_sha="${KIND_AMD64_SHA256}"
      else
        expected_blob_sha="${KIND_ARM64_SHA256}"
      fi
      expected_bin_sha="${expected_blob_sha}"
      ;;
    kubectl)
      url="https://dl.k8s.io/release/${PIN_KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
      expected_ver="${PIN_KUBECTL_VERSION}"
      if [[ "$arch" == "amd64" ]]; then
        expected_blob_sha="${KUBECTL_AMD64_SHA256}"
      else
        expected_blob_sha="${KUBECTL_ARM64_SHA256}"
      fi
      expected_bin_sha="${expected_blob_sha}"
      ;;
    flux)
      url="https://github.com/fluxcd/flux2/releases/download/v${PIN_FLUX_VERSION}/flux_${PIN_FLUX_VERSION}_linux_${arch}.tar.gz"
      expected_ver="${PIN_FLUX_VERSION}"
      is_archive=1
      if [[ "$arch" == "amd64" ]]; then
        expected_blob_sha="${FLUX_AMD64_ARCHIVE_SHA256}"
        expected_bin_sha="${FLUX_AMD64_BINARY_SHA256}"
      else
        expected_blob_sha="${FLUX_ARM64_ARCHIVE_SHA256}"
        expected_bin_sha="${FLUX_ARM64_BINARY_SHA256}"
      fi
      ;;
    cosign)
      url="https://github.com/sigstore/cosign/releases/download/${PIN_COSIGN_VERSION}/cosign-linux-${arch}"
      expected_ver="${PIN_COSIGN_VERSION}"
      if [[ "$arch" == "amd64" ]]; then
        expected_blob_sha="${COSIGN_AMD64_SHA256}"
      else
        expected_blob_sha="${COSIGN_ARM64_SHA256}"
      fi
      expected_bin_sha="${expected_blob_sha}"
      ;;
    jq)
      url="https://github.com/jqlang/jq/releases/download/jq-${PIN_JQ_VERSION}/jq-linux-${arch}"
      expected_ver="${PIN_JQ_VERSION}"
      if [[ "$arch" == "amd64" ]]; then
        expected_blob_sha="${JQ_AMD64_SHA256}"
      else
        expected_blob_sha="${JQ_ARM64_SHA256}"
      fi
      expected_bin_sha="${expected_blob_sha}"
      ;;
    ed25519-keygen)
      # Built, not downloaded, so none of the curl/digest/version machinery
      # below applies. Handled before the download path rather than inside it.
      local dest_dir_src="${BUNDLE_DIR}/bin/${arch}"
      mkdir -p "${dest_dir_src}"
      local built_sha
      built_sha="$(build_ed25519_keygen "${arch}" "${dest_dir_src}/ed25519-keygen")"
      ED25519_KEYGEN_SHA256["${arch}"]="${built_sha}"
      local km
      km="$(readelf -h "${dest_dir_src}/ed25519-keygen" | awk -F: '/Machine:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
      if [[ "${arch}" == "amd64" && "${km}" != "Advanced Micro Devices X86-64" ]]; then
        fail "ELF machine mismatch for ed25519-keygen [amd64]: got '${km}'"
      fi
      if [[ "${arch}" == "arm64" && "${km}" != "AArch64" ]]; then
        fail "ELF machine mismatch for ed25519-keygen [arm64]: got '${km}'"
      fi
      log "Built ${dest_dir_src}/ed25519-keygen from ${ED25519_KEYGEN_MODULE_REL} (mode 0755, sha256: ${built_sha}, ELF ${km})"
      return 0
      ;;
    *)
      fail "Unknown tool: ${tool}"
      ;;
  esac

  mkdir -p "${dest_dir}"

  if [[ -f "${dest_bin}" ]]; then
    local cur_sha
    cur_sha="$(sha256sum "${dest_bin}" | awk '{print $1}')"
    if [[ "${cur_sha}" == "${expected_bin_sha}" ]]; then
      log "${tool} [${arch}] already staged and matches pinned digest (${cur_sha})"
      chmod 0755 "${dest_bin}"
      return 0
    fi
  fi

  local tmp_work
  tmp_work="$(mktemp -d "/tmp/slsi-pkg-${tool}-${arch}.XXXXXX")"
  local tmp_file="${tmp_work}/download.tmp"

  log "Fetching ${tool} [${arch}] from ${url}..."
  curl --fail --location --proto '=https' --tlsv1.2 -o "${tmp_file}" "${url}"
  local curl_rc=$?
  if [[ ${curl_rc} -ne 0 ]]; then
    rm -rf "${tmp_work}"
    fail "curl failed with exit code ${curl_rc} for ${url}"
  fi

  local file_bytes
  file_bytes="$(wc -c < "${tmp_file}")"
  if [[ ${file_bytes} -lt 50000 ]]; then
    rm -rf "${tmp_work}"
    fail "Downloaded file is suspiciously small (${file_bytes} bytes): ${url}"
  fi

  local first_byte
  first_byte="$(head -c 1 "${tmp_file}")"
  if [[ "${first_byte}" == "<" ]]; then
    rm -rf "${tmp_work}"
    fail "Downloaded file starts with '<' (likely HTML error page): ${url}"
  fi

  if [[ ${is_archive} -eq 1 ]]; then
    local magic2
    magic2="$(od -An -tx1 -N2 "${tmp_file}" | tr -d ' \n')"
    if [[ "${magic2}" != "1f8b" ]]; then
      rm -rf "${tmp_work}"
      fail "Downloaded archive does not have gzip magic bytes (got: ${magic2}): ${url}"
    fi
  else
    local magic4
    magic4="$(od -An -tx1 -N4 "${tmp_file}" | tr -d ' \n')"
    if [[ "${magic4}" != "7f454c46" ]]; then
      rm -rf "${tmp_work}"
      fail "Downloaded file does not have ELF magic bytes (got: ${magic4}): ${url}"
    fi
  fi

  local actual_blob_sha
  actual_blob_sha="$(sha256sum "${tmp_file}" | awk '{print $1}')"
  if [[ "${actual_blob_sha}" != "${expected_blob_sha}" ]]; then
    rm -rf "${tmp_work}"
    fail "Blob SHA-256 mismatch for ${tool} [${arch}]: expected literal ${expected_blob_sha}, got ${actual_blob_sha}"
  fi
  log "Cryptographic digest match for ${tool} [${arch}] blob: ${actual_blob_sha}"

  local bin_src="${tmp_file}"
  if [[ ${is_archive} -eq 1 ]]; then
    tar -xzf "${tmp_file}" -C "${tmp_work}" "${tool}"
    bin_src="${tmp_work}/${tool}"
    if [[ ! -f "${bin_src}" ]]; then
      rm -rf "${tmp_work}"
      fail "Archive did not contain member ${tool}: ${url}"
    fi
    local member_magic
    member_magic="$(od -An -tx1 -N4 "${bin_src}" | tr -d ' \n')"
    if [[ "${member_magic}" != "7f454c46" ]]; then
      rm -rf "${tmp_work}"
      fail "Extracted member ${tool} does not have ELF magic bytes (got: ${member_magic})"
    fi
    local actual_bin_sha
    actual_bin_sha="$(sha256sum "${bin_src}" | awk '{print $1}')"
    if [[ "${actual_bin_sha}" != "${expected_bin_sha}" ]]; then
      rm -rf "${tmp_work}"
      fail "Extracted binary SHA-256 mismatch for ${tool} [${arch}]: expected literal ${expected_bin_sha}, got ${actual_bin_sha}"
    fi
    log "Cryptographic digest match for extracted ${tool} [${arch}] binary: ${actual_bin_sha}"
  fi

  local elf_machine
  elf_machine="$(readelf -h "${bin_src}" | awk -F: '/Machine:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
  if [[ "${arch}" == "amd64" ]]; then
    if [[ "${elf_machine}" != "Advanced Micro Devices X86-64" ]]; then
      rm -rf "${tmp_work}"
      fail "ELF machine mismatch for ${tool} [${arch}]: expected 'Advanced Micro Devices X86-64', got '${elf_machine}'"
    fi
  elif [[ "${arch}" == "arm64" ]]; then
    if [[ "${elf_machine}" != "AArch64" ]]; then
      rm -rf "${tmp_work}"
      fail "ELF machine mismatch for ${tool} [${arch}]: expected 'AArch64', got '${elf_machine}'"
    fi
  fi
  log "ELF machine header confirmed for ${tool} [${arch}]: ${elf_machine}"

  install -m 0755 "${bin_src}" "${dest_bin}"

  local host_machine
  host_machine="$(uname -m)"
  if [[ ("${host_machine}" == "x86_64" && "${arch}" == "amd64") || ("${host_machine}" == "aarch64" && "${arch}" == "arm64") ]]; then
    local actual_ver=""
    case "$tool" in
      kind)
        actual_ver="$("${dest_bin}" version | awk '{print $2}')"
        ;;
      kubectl)
        actual_ver="$("${dest_bin}" version --client=true | awk '/Client Version:/ {print $3}')"
        ;;
      flux)
        actual_ver="$("${dest_bin}" --version | awk '{print $3}')"
        ;;
      cosign)
        actual_ver="$("${dest_bin}" version 2>&1 | awk '/GitVersion:/ {print $2}')"
        ;;
      jq)
        actual_ver="$("${dest_bin}" --version | sed 's/^jq-//')"
        ;;
    esac
    verify_exact_version_equality "${tool}" "${actual_ver}" "${expected_ver}"
  else
    local raw_ver="${expected_ver#v}"
    if ! strings "${dest_bin}" | awk -v v="${expected_ver}" -v r="${raw_ver}" 'index($0, v) || index($0, r) { found=1 } END { exit !found }'; then
      rm -rf "${tmp_work}"
      fail "Cross-architecture binary ${dest_bin} does not contain expected version string ${expected_ver} or ${raw_ver}"
    fi
    log "Cross-architecture version string confirmed for ${tool} [${arch}]: ${expected_ver}"
  fi

  rm -rf "${tmp_work}"
  log "Staged ${dest_bin} (mode 0755, sha256: ${expected_bin_sha})"
}

stage_p1_1_binaries() {
  log "Executing stage_p1_1_binaries (target arch: ${TARGET_ARCH}, filter: ${FILTER_TOOL:-none})"

  if [[ "$CHECK_PINS" -eq 1 ]]; then
    check_all_pins
    return 0
  fi

  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    verify_offline_manifest
    return 0
  fi

  local target_arches=()
  if [[ "${TARGET_ARCH}" == "all" ]]; then
    target_arches=("amd64" "arm64")
  elif [[ "${TARGET_ARCH}" == "amd64" || "${TARGET_ARCH}" == "arm64" ]]; then
    target_arches=("${TARGET_ARCH}")
  else
    fail "Unsupported architecture: ${TARGET_ARCH} (must be amd64, arm64, or all)"
  fi

  local tools_to_stage=("kind" "kubectl" "flux" "cosign" "jq" "ed25519-keygen")
  if [[ -n "${FILTER_TOOL}" ]]; then
    if [[ "${FILTER_TOOL}" == "openssl" || "${FILTER_TOOL}" == "envsubst" ]]; then
      fail "Tool '${FILTER_TOOL}' is not part of this bundle. Decision 10 is reversed: neither openssl nor envsubst is shipped, and the appliance-side need they were containerised for is served by ed25519-keygen. Use --only ed25519-keygen."
    fi
    tools_to_stage=("${FILTER_TOOL}")
  fi

  for arch in "${target_arches[@]}"; do
    mkdir -p "${BUNDLE_DIR}/bin/${arch}"
    for tool in "${tools_to_stage[@]}"; do
      stage_single_tool "${tool}" "${arch}"
    done

    cat > "${BUNDLE_DIR}/bin/${arch}/versions.txt" <<EOF
kind: ${PIN_KIND_VERSION}
kubectl: ${PIN_KUBECTL_VERSION}
flux: ${PIN_FLUX_VERSION}
cosign: ${PIN_COSIGN_VERSION}
jq: ${PIN_JQ_VERSION}
# Built from this repository's source, not downloaded. Its "version" is the
# commit it was compiled from; its digest is in checksums.txt like any other.
ed25519-keygen: source@${ED25519_KEYGEN_SOURCE_REV}
EOF
    chmod 0644 "${BUNDLE_DIR}/bin/${arch}/versions.txt"
    log "Wrote ${BUNDLE_DIR}/bin/${arch}/versions.txt"
  done

  # Six entries per arch now, not five. ed25519-keygen's digest is the one
  # computed at stage time rather than pinned as a literal; see the header.
  #
  # The manifest lists both arches unconditionally -- that is pre-existing
  # behaviour for the five literal pins and is not changed here. So a digest is
  # needed for any arch this run did not stage; it is computed by building into
  # a scratch directory, never left blank. A blank field would produce a
  # two-space-leading manifest line that sha256sum -c parses as a path, which
  # fails with a message about the wrong thing entirely.
  local kg_arch
  for kg_arch in amd64 arm64; do
    if [[ -z "${ED25519_KEYGEN_SHA256[${kg_arch}]:-}" ]]; then
      local kg_tmp
      kg_tmp="$(mktemp -d "/tmp/slsi-kg-digest-${kg_arch}.XXXXXX")"
      ED25519_KEYGEN_SHA256["${kg_arch}"]="$(build_ed25519_keygen "${kg_arch}" "${kg_tmp}/ed25519-keygen")"
      rm -rf "${kg_tmp}"
      log "Computed ed25519-keygen [${kg_arch}] digest for the manifest without staging it (arch not selected this run)"
    fi
  done
  local kg_amd64="${ED25519_KEYGEN_SHA256[amd64]}"
  local kg_arm64="${ED25519_KEYGEN_SHA256[arm64]}"

  cat > "${BUNDLE_DIR}/bin/checksums.txt" <<EOF
${KIND_AMD64_SHA256}  amd64/kind
${KUBECTL_AMD64_SHA256}  amd64/kubectl
${FLUX_AMD64_BINARY_SHA256}  amd64/flux
${COSIGN_AMD64_SHA256}  amd64/cosign
${JQ_AMD64_SHA256}  amd64/jq
${kg_amd64}  amd64/ed25519-keygen
${KIND_ARM64_SHA256}  arm64/kind
${KUBECTL_ARM64_SHA256}  arm64/kubectl
${FLUX_ARM64_BINARY_SHA256}  arm64/flux
${COSIGN_ARM64_SHA256}  arm64/cosign
${JQ_ARM64_SHA256}  arm64/jq
${kg_arm64}  arm64/ed25519-keygen
EOF
  chmod 0644 "${BUNDLE_DIR}/bin/checksums.txt"
  log "Generated ${BUNDLE_DIR}/bin/checksums.txt"

  verify_offline_manifest
  log "stage_p1_1_binaries complete: all tools staged and verified"
}

# <<< SLSI-P1-1 >>>

# >>> SLSI-P1-2: offline OCI image bundler and digest pinning <<<
# Stage P1-2: Export platform images into OCI layout under bundle/images/
# Digest-pin all third-party images and sign at bundle time with SLSI release key.
# This region is owned by P1-2 and is READ-ONLY to other cards.

# ─── Verification Doctrine for 4 GB OCI Layouts ──────────────────────────────
# A binary pass/fail (0 vs 1) verdict is epistemologically dishonest for a
# multi-gigabyte, multi-arch OCI tree containing dozens of container images.
# In a large tree, failures fall into two fundamentally distinct classes:
#
#   1. MISMATCH (exit 1): Cryptographic or structural falsification. An artifact
#      was found on disk, but its content hash does not match its expected digest,
#      a signature is cryptographically invalid, an illegal mutable tag (e.g.
#      ':latest' or 'semver: *') was detected, or private key material was leaked.
#      This represents a proven integrity violation or supply-chain defect.
#
#   3. COULD-NOT-VERIFY (exit 3): Inconclusive or absent evidence. A required
#      descriptor or blob is missing, an index is truncated, resolved.json is
#      absent, network egress was attempted while offline, or an unreadable media
#      type was encountered.
#
# Upgrading COULD-NOT-VERIFY to PASS (0) is a fatal silent-acceptance defect
# (as proven by the image-identity.sh CRI truncation bug). Degrading
# COULD-NOT-VERIFY to MISMATCH (1) falsely claims proof of corruption when the
# actual state is missing or unverified inputs. Therefore, P1-2 strictly enforces
# the three-way contract: 0 = VERIFIED, 1 = MISMATCH, 3 = COULD-NOT-VERIFY.
# ─────────────────────────────────────────────────────────────────────────────

SLSI_VERIFY_EXIT_VERIFIED=0
SLSI_VERIFY_EXIT_MISMATCH=1
SLSI_VERIFY_EXIT_COULD_NOT_VERIFY=3

SLSI_RELEASE_KEY_URI="${SLSI_RELEASE_KEY_URI:-openbao://slsi-release}"
SLSI_BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
SLSI_BAO_TOKEN="${BAO_TOKEN:-root}"

SLSI_IMAGES_ONLY=0
SLSI_RESOLVE_ONLY=0
SLSI_PROCESS_IMAGES=0

# Intercept command-line arguments for P1-2 flags
eval "$(declare -f parse_args | sed '1s/parse_args/_orig_parse_args_p1_1/')"

parse_args() {
  local passthru_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --images-only)
        SLSI_IMAGES_ONLY=1
        SLSI_PROCESS_IMAGES=1
        shift
        ;;
      --resolve-only)
        SLSI_RESOLVE_ONLY=1
        SLSI_PROCESS_IMAGES=1
        shift
        ;;
      --images)
        SLSI_PROCESS_IMAGES=1
        shift
        ;;
      *)
        passthru_args+=("$1")
        shift
        ;;
    esac
  done
  _orig_parse_args_p1_1 "${passthru_args[@]}"
}

# Wrap stage_p1_1_binaries to honor --images-only and --resolve-only
eval "$(declare -f stage_p1_1_binaries | sed '1s/stage_p1_1_binaries/_orig_stage_p1_1_binaries/')"

stage_p1_1_binaries() {
  if [[ "${SLSI_IMAGES_ONLY:-0}" -eq 1 || "${SLSI_RESOLVE_ONLY:-0}" -eq 1 ]]; then
    log "stage_p1_1_binaries: skipped (--images-only/--resolve-only requested)"
    return 0
  fi
  _orig_stage_p1_1_binaries "$@"
}

check_capacity_gate() {
  local target_dir="$1"
  mkdir -p "${target_dir}"
  local free_bytes
  free_bytes="$(df -B1 --output=avail "${target_dir}" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
  # Estimated bundle image footprint is ~4 GB; 3x required headroom is 12 GB.
  local min_required_bytes="${SLSI_CAPACITY_GATE_MIN_FREE_BYTES:-12884901888}"
  if [[ "${free_bytes}" -lt "${min_required_bytes}" ]]; then
    echo "ERROR: Insufficient disk space for OCI bundle staging." >&2
    echo "Required minimum: ${min_required_bytes} bytes, Available: ${free_bytes} bytes in ${target_dir}." >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  log "Capacity gate passed: ${free_bytes} bytes free (threshold: ${min_required_bytes} bytes)"
}

probe_openbao_kms() {
  export BAO_ADDR="${SLSI_BAO_ADDR}"
  export BAO_TOKEN="${SLSI_BAO_TOKEN}"

  if ! curl -sf "${SLSI_BAO_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    echo "ERROR: OpenBao is unreachable at ${SLSI_BAO_ADDR}." >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi

  if ! cosign public-key --key "${SLSI_RELEASE_KEY_URI}" >/dev/null 2>&1; then
    echo "ERROR: Cosign failed to retrieve public key from ${SLSI_RELEASE_KEY_URI} via OpenBao." >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  log "OpenBao KMS probe passed for ${SLSI_RELEASE_KEY_URI}"
}

walk_oci_closure() {
  local oci_dir="$1"
  local index_file="${oci_dir}/index.json"
  local blobs_dir="${oci_dir}/blobs/sha256"

  if [[ ! -f "${index_file}" || ! -d "${blobs_dir}" ]]; then
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi

  declare -A reachable=()
  declare -A seen=()
  local queue=()

  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    local h="${d#sha256:}"
    reachable["$h"]=1
    queue+=("$h")
  done < <(jq -r '.manifests[]?.digest // empty' "${index_file}")

  local dangling=()
  local q_idx=0
  while [[ $q_idx -lt ${#queue[@]} ]]; do
    local cur="${queue[$q_idx]}"
    q_idx=$((q_idx + 1))
    [[ -z "${seen["$cur"]:-}" ]] || continue
    seen["$cur"]=1

    local blob_path="${blobs_dir}/${cur}"
    if [[ ! -f "${blob_path}" ]]; then
      dangling+=("sha256:${cur}")
      continue
    fi

    while IFS= read -r child_digest; do
      [[ -n "$child_digest" ]] || continue
      local child_h="${child_digest#sha256:}"
      reachable["$child_h"]=1
      [[ -n "${seen["$child_h"]:-}" ]] || queue+=("$child_h")
    done < <(jq -r '(.manifests[]?.digest // empty), (.config?.digest // empty), (.layers[]?.digest // empty)' "${blob_path}" 2>/dev/null || true)
  done

  local orphans=()
  local disk_count=0
  for f in "${blobs_dir}"/*; do
    [[ -f "$f" ]] || continue
    disk_count=$((disk_count + 1))
    local b="$(basename "$f")"
    if [[ -z "${reachable["$b"]:-}" ]]; then
      orphans+=("sha256:${b}")
    fi
  done

  CLOSURE_TOTAL_REACHABLE="${#reachable[@]}"
  CLOSURE_TOTAL_DISK="${disk_count}"
  CLOSURE_DANGLING_COUNT="${#dangling[@]}"
  CLOSURE_ORPHANS_COUNT="${#orphans[@]}"
  CLOSURE_DANGLING_JSON="$(printf '%s\n' "${dangling[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"
  CLOSURE_ORPHANS_JSON="$(printf '%s\n' "${orphans[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"

  if [[ ${CLOSURE_DANGLING_COUNT} -gt 0 ]]; then
    log "Closure walk failure: ${CLOSURE_DANGLING_COUNT} dangling descriptors found"
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  if [[ ${CLOSURE_ORPHANS_COUNT} -gt 0 ]]; then
    log "Closure walk failure: ${CLOSURE_ORPHANS_COUNT} orphan blobs found"
    return "${SLSI_VERIFY_EXIT_MISMATCH}"
  fi
  return "${SLSI_VERIFY_EXIT_VERIFIED}"
}

prune_oci_closure() {
  local oci_dir="$1"
  local index_file="${oci_dir}/index.json"
  local blobs_dir="${oci_dir}/blobs/sha256"

  [[ -f "${index_file}" && -d "${blobs_dir}" ]] || return 0

  declare -A reachable=()
  declare -A seen=()
  local queue=()

  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    local h="${d#sha256:}"
    reachable["$h"]=1
    queue+=("$h")
  done < <(jq -r '.manifests[]?.digest // empty' "${index_file}")

  local q_idx=0
  while [[ $q_idx -lt ${#queue[@]} ]]; do
    local cur="${queue[$q_idx]}"
    q_idx=$((q_idx + 1))
    [[ -z "${seen["$cur"]:-}" ]] || continue
    seen["$cur"]=1

    local blob_path="${blobs_dir}/${cur}"
    [[ -f "${blob_path}" ]] || continue

    while IFS= read -r child_digest; do
      [[ -n "$child_digest" ]] || continue
      local child_h="${child_digest#sha256:}"
      reachable["$child_h"]=1
      [[ -n "${seen["$child_h"]:-}" ]] || queue+=("$child_h")
    done < <(jq -r '(.manifests[]?.digest // empty), (.config?.digest // empty), (.layers[]?.digest // empty)' "${blob_path}" 2>/dev/null || true)
  done

  local pruned=0
  for f in "${blobs_dir}"/*; do
    [[ -f "$f" ]] || continue
    local b="$(basename "$f")"
    if [[ -z "${reachable["$b"]:-}" ]]; then
      rm -f "$f"
      pruned=$((pruned + 1))
    fi
  done
  if [[ $pruned -gt 0 ]]; then
    log "Pruned ${pruned} unreferenced orphan blob(s) from ${blobs_dir}"
  fi
}

verify_offline_images() {
  local images_dir="${BUNDLE_DIR}/images"
  local oci_dir="${images_dir}/oci"
  local resolved_file="${images_dir}/resolved.json"
  local closure_file="${images_dir}/layout-closure.json"
  local pubkey_file="${BUNDLE_DIR}/keys/release.pub"
  local sig_dir="${images_dir}/signatures"

  log "Executing Phase C: air-gap offline image verification"

  if [[ ! -f "${resolved_file}" ]]; then
    echo "ERROR: resolved.json is absent at ${resolved_file}" >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  if [[ ! -f "${oci_dir}/index.json" ]]; then
    echo "ERROR: OCI index.json is absent at ${oci_dir}/index.json" >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  if [[ ! -f "${pubkey_file}" ]]; then
    echo "ERROR: Release public key is absent at ${pubkey_file}" >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi

  # 1. Structural layout closure walk
  local walk_rc=0
  walk_oci_closure "${oci_dir}" || walk_rc=$?
  if [[ $walk_rc -ne 0 ]]; then
    if [[ ! -f "${closure_file}" ]]; then
      cat > "${closure_file}" <<EOF
{
  "layoutPath": "bundle/images/oci",
  "totalReachableDescriptors": ${CLOSURE_TOTAL_REACHABLE:-0},
  "totalBlobsOnDisk": ${CLOSURE_TOTAL_DISK:-0},
  "danglingDescriptors": ${CLOSURE_DANGLING_JSON:-[]},
  "orphanBlobs": ${CLOSURE_ORPHANS_JSON:-[]},
  "closureVerified": false,
  "verifiedAt": "${SOURCE_DATE_UTC}"
}
EOF
    fi
    return "${walk_rc}"
  fi

  if [[ ! -f "${closure_file}" ]]; then
    cat > "${closure_file}" <<EOF
{
  "layoutPath": "bundle/images/oci",
  "totalReachableDescriptors": ${CLOSURE_TOTAL_REACHABLE},
  "totalBlobsOnDisk": ${CLOSURE_TOTAL_DISK},
  "danglingDescriptors": [],
  "orphanBlobs": [],
  "closureVerified": true,
  "verifiedAt": "${SOURCE_DATE_UTC}"
}
EOF
  else
    local recorded_reachable recorded_disk
    recorded_reachable="$(jq -r '.totalReachableDescriptors // 0' "${closure_file}")"
    recorded_disk="$(jq -r '.totalBlobsOnDisk // 0' "${closure_file}")"
    if [[ "${recorded_reachable}" -ne "${CLOSURE_TOTAL_REACHABLE}" || "${recorded_disk}" -ne "${CLOSURE_TOTAL_DISK}" ]]; then
      echo "ERROR: Layout closure mismatch! Expected reachable: ${recorded_reachable}, actual: ${CLOSURE_TOTAL_REACHABLE}" >&2
      return "${SLSI_VERIFY_EXIT_MISMATCH}"
    fi
  fi

  # 2. Check each resolved image entry
  local entries_count
  entries_count="$(jq '. | length' "${resolved_file}")"
  log "Verifying ${entries_count} resolved image entries against OCI layout..."

  local i=0
  while [[ $i -lt $entries_count ]]; do
    local digest ref
    digest="$(jq -r ".[$i].manifestDigest" "${resolved_file}")"
    ref="$(jq -r ".[$i].ref" "${resolved_file}")"
    local hash="${digest#sha256:}"
    local blob_path="${oci_dir}/blobs/sha256/${hash}"

    if [[ ! -f "${blob_path}" ]]; then
      echo "ERROR: Missing blob for image ${ref} (digest: ${digest})" >&2
      return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
    fi

    # Content hash equality check
    local actual_sha
    actual_sha="$(sha256sum "${blob_path}" | awk '{print $1}')"
    if [[ "${actual_sha}" != "${hash}" ]]; then
      echo "ERROR: Digest mismatch on blob for image ${ref}! Expected ${hash}, got ${actual_sha}" >&2
      return "${SLSI_VERIFY_EXIT_MISMATCH}"
    fi

    # Bundle-time signature verification
    local bundle_file="${sig_dir}/${hash}.bundle"
    if [[ ! -f "${bundle_file}" ]]; then
      echo "ERROR: Missing signature bundle for ${ref} at ${bundle_file}" >&2
      return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
    fi

    if ! cosign verify-blob --insecure-ignore-tlog=true --key "${pubkey_file}" --bundle "${bundle_file}" "${blob_path}" >/dev/null 2>&1; then
      echo "ERROR: Cryptographic signature verification failed for ${ref} (${digest})" >&2
      return "${SLSI_VERIFY_EXIT_MISMATCH}"
    fi

    i=$((i + 1))
  done

  # 3. Vendored Flux manifests inspection
  local flux_manifests_dir="${images_dir}/flux/manifests"
  if [[ -d "${flux_manifests_dir}" ]]; then
    if grep -rn -E "(:latest|semver:[[:space:]]*['\"]?\*)" "${flux_manifests_dir}" >/dev/null 2>&1; then
      echo "ERROR: Floating tag or unpinned semver found in vendored Flux manifests!" >&2
      return "${SLSI_VERIFY_EXIT_MISMATCH}"
    fi
  fi

  # 4. Bounded private key leak check
  local leaked_keys=()
  while IFS= read -r text_file; do
    [[ -n "$text_file" ]] || continue
    if grep -I -q "BEGIN.*PRIVATE KEY" "${text_file}" 2>/dev/null; then
      leaked_keys+=("${text_file}")
    fi
    local base_f
    base_f="$(basename "${text_file}")"
    if [[ "${base_f}" == *.key || "${base_f}" == *.priv || "${base_f}" == id_rsa* || "${base_f}" == id_ed25519* || "${base_f}" == id_ecdsa* ]]; then
      leaked_keys+=("${text_file}")
    fi
  done < <(find "${BUNDLE_DIR}" -type f ! -path "*/blobs/*" ! -path "*/bin/*" 2>/dev/null)

  if [[ ${#leaked_keys[@]} -gt 0 ]]; then
    echo "ERROR: Private key material detected inside bundle: ${leaked_keys[*]}" >&2
    return "${SLSI_VERIFY_EXIT_MISMATCH}"
  fi

  log "Phase C: verification complete (0 VERIFIED) - 30 images, layout closure, and signatures verified"
  return "${SLSI_VERIFY_EXIT_VERIFIED}"
}

stage_p1_2_images() {
  log "Executing stage_p1_2_images (offline OCI image bundler & digest pinning)"

  local images_dir="${BUNDLE_DIR}/images"
  local oci_dir="${images_dir}/oci"
  local flux_dir="${images_dir}/flux"
  local keys_dir="${BUNDLE_DIR}/keys"
  local sig_dir="${images_dir}/signatures"
  local resolved_file="${images_dir}/resolved.json"
  local images_json_file="${images_dir}/images.json"
  local staging_oci="${images_dir}/.staging-oci"

  mkdir -p "${images_dir}" "${keys_dir}" "${sig_dir}"

  # Verification mode short-circuit
  if [[ "${VERIFY_ONLY:-0}" -eq 1 ]]; then
    verify_offline_images || exit $?
    return 0
  fi

  # Preflight Capacity Gate & OpenBao KMS probe
  check_capacity_gate "${images_dir}" || exit $?
  probe_openbao_kms || exit $?

  local foundation_file="${REPO_ROOT}/scripts/foundation-images.txt"
  local kagent_file="${REPO_ROOT}/scripts/kagent-images.txt"

  if [[ ! -f "${foundation_file}" || ! -f "${kagent_file}" ]]; then
    fail "Image list files missing: ${foundation_file} or ${kagent_file}"
  fi

  local foundation_active_count kagent_active_count
  foundation_active_count="$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "${foundation_file}")"
  kagent_active_count="$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "${kagent_file}")"

  if [[ "${foundation_active_count}" -ne 22 ]]; then
    fail "Foundation image count mismatch: expected 22 active entries, found ${foundation_active_count}"
  fi
  if [[ "${kagent_active_count}" -ne 8 ]]; then
    fail "Kagent image count mismatch: expected 8 active entries, found ${kagent_active_count}"
  fi

  # ── Phase A: Resolution ──────────────────────────────────────────────────
  log "Phase A: resolving 30 platform images via registry inspection..."

  local resolved_records=()
  local all_active_refs=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local ref
    ref="$(echo "$line" | awk '{print $1}')"
    [[ -n "$ref" ]] || continue
    all_active_refs+=("$ref")
  done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${foundation_file}")

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local ref
    ref="$(echo "$line" | awk '{print $1}')"
    [[ -n "$ref" ]] || continue
    all_active_refs+=("$ref")
  done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${kagent_file}")

  for ref in "${all_active_refs[@]}"; do
    local repo tag
    if [[ "$ref" == *@sha256:* ]]; then
      repo="${ref%@*}"
      tag="${ref#*@}"
    elif [[ "$ref" == *:* ]]; then
      repo="${ref%:*}"
      tag="${ref##*:}"
    else
      repo="$ref"
      tag="latest"
    fi

    log "Resolving digest for ${ref}..."
    local digest media_type
    digest="$(crane digest --platform all "${ref}" 2>/dev/null || true)"
    if [[ -z "$digest" || "$digest" != sha256:* ]]; then
      # Fallback for references already pinned by digest
      if [[ "$ref" == *@sha256:* ]]; then
        digest="${ref#*@}"
      else
        echo "ERROR: Failed to resolve digest for ${ref}" >&2
        digest="DIGEST-UNRESOLVED: not present"
      fi
    fi

    media_type="$(crane manifest "${ref}" 2>/dev/null | jq -r '.mediaType // empty' || true)"
    if [[ -z "$media_type" ]]; then
      media_type="application/vnd.docker.distribution.manifest.list.v2+json"
    fi

    local rec
    rec="$(jq -n \
      --arg ref "$ref" \
      --arg repo "$repo" \
      --arg tag "$tag" \
      --arg digest "$digest" \
      --arg mediaType "$media_type" \
      --arg resolvedAt "${SOURCE_DATE_UTC}" \
      --arg resolverCommand "crane digest --platform all ${ref}" \
      '{ref: $ref, repo: $repo, tag: $tag, manifestDigest: $digest, mediaType: $mediaType, resolvedAt: $resolvedAt, resolverCommand: $resolverCommand}')"
    resolved_records+=("$rec")
  done

  # Write bundle/images/resolved.json sorted by ref before any export
  printf '%s\n' "${resolved_records[@]}" | jq -s 'sort_by(.ref)' > "${resolved_file}"
  log "Phase A complete: wrote pre-export attestation to ${resolved_file}"

  if [[ "${SLSI_RESOLVE_ONLY:-0}" -eq 1 ]]; then
    log "Resolved only mode requested; exiting."
    return 0
  fi

  # ── Phase B: Export, Vendoring & Signing ──────────────────────────────────
  log "Phase B: exporting multi-arch OCI layout and vendoring Flux..."

  # Export release public key
  cat << EOF > "${keys_dir}/release.pub"
# Provenance: cosign public-key --key ${SLSI_RELEASE_KEY_URI}
$(BAO_ADDR="${SLSI_BAO_ADDR}" BAO_TOKEN="${SLSI_BAO_TOKEN}" cosign public-key --key "${SLSI_RELEASE_KEY_URI}")
EOF
  chmod 0644 "${keys_dir}/release.pub"

  rm -rf "${staging_oci}"
  mkdir -p "${staging_oci}/blobs/sha256"

  # Link existing blobs to support fast, zero-download idempotent re-runs
  if [[ -d "${oci_dir}/blobs/sha256" ]]; then
    cp -al "${oci_dir}/blobs/sha256"/* "${staging_oci}/blobs/sha256/" 2>/dev/null || true
  fi

  # Export each image by digest into staging OCI layout
  local count
  count="$(jq '. | length' "${resolved_file}")"
  local idx=0
  while [[ $idx -lt $count ]]; do
    local entry_repo entry_digest entry_ref
    entry_repo="$(jq -r ".[$idx].repo" "${resolved_file}")"
    entry_digest="$(jq -r ".[$idx].manifestDigest" "${resolved_file}")"
    entry_ref="$(jq -r ".[$idx].ref" "${resolved_file}")"

    if [[ "$entry_digest" == sha256:* ]]; then
      log "Staging image [$(($idx + 1))/${count}]: ${entry_repo}@${entry_digest}"
      crane pull --format=oci --annotate-ref "${entry_repo}@${entry_digest}" "${staging_oci}"
    fi
    idx=$((idx + 1))
  done

  # Vendor Flux Operator helm chart (0.57.0)
  mkdir -p "${flux_dir}/charts"
  log "Vendoring Flux Operator helm chart 0.57.0..."
  helm pull oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --version 0.57.0 -d "${flux_dir}/charts"

  # Vendor Flux Operator manifests artifact (0.57.0)
  local flux_manifests_digest="sha256:41223e96853ea6817d12aa8cf5dc43de49b7abab6892bb12ab39190cc12bba0c"
  log "Vendoring Flux Operator manifests artifact..."
  crane pull --format=oci "ghcr.io/controlplaneio-fluxcd/flux-operator-manifests@${flux_manifests_digest}" "${staging_oci}"

  # Vendor and rewrite fleet manifest copies under bundle/images/flux/manifests/<cluster>/
  local clusters=("local" "staging" "prod-eu" "prod-us" "update")
  local substitutions=()

  for c in "${clusters[@]}"; do
    local src_cluster_dir="${REPO_ROOT}/d2-osramp-fleet/clusters/${c}/flux-system"
    local dest_cluster_dir="${flux_dir}/manifests/${c}"
    mkdir -p "${dest_cluster_dir}"

    if [[ -d "${src_cluster_dir}" ]]; then
      cp -r "${src_cluster_dir}"/* "${dest_cluster_dir}/"

      # Rewrite flux-operator.yaml
      if [[ -f "${dest_cluster_dir}/flux-operator.yaml" ]]; then
        sed -i.bak -e "s/semver: '\*'/semver: '0.57.0'/" "${dest_cluster_dir}/flux-operator.yaml"
        awk '
          /matchOIDCIdentity:/ {
            print "          secretRef:"
            print "            name: cosign-pub"
            skip = 1
            next
          }
          skip && /^[[:space:]]+- issuer:/ { next }
          skip && /^[[:space:]]+subject:/ { skip = 0; next }
          { print }
        ' "${dest_cluster_dir}/flux-operator.yaml" > "${dest_cluster_dir}/flux-operator.yaml.tmp"
        mv "${dest_cluster_dir}/flux-operator.yaml.tmp" "${dest_cluster_dir}/flux-operator.yaml"
        rm -f "${dest_cluster_dir}/flux-operator.yaml.bak"

        substitutions+=("{\"target\":\"bundle/images/flux/manifests/${c}/flux-operator.yaml\",\"original\":\"semver: *\",\"replacement\":\"semver: 0.57.0\"}")
        substitutions+=("{\"target\":\"bundle/images/flux/manifests/${c}/flux-operator.yaml\",\"original\":\"matchOIDCIdentity\",\"replacement\":\"secretRef: name: cosign-pub\"}")
      fi

      # Rewrite flux-instance.yaml
      if [[ -f "${dest_cluster_dir}/flux-instance.yaml" ]]; then
        sed -i.bak -e "s|artifact: \"oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:latest\"|artifact: \"oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests@${flux_manifests_digest}\"|" "${dest_cluster_dir}/flux-instance.yaml"
        rm -f "${dest_cluster_dir}/flux-instance.yaml.bak"

        substitutions+=("{\"target\":\"bundle/images/flux/manifests/${c}/flux-instance.yaml\",\"original\":\":latest\",\"replacement\":\"@${flux_manifests_digest}\"}")
      fi
    fi
  done

  # Bundle-time signing of all staged image manifests with OpenBao transit key
  log "Signing bundled image manifests with release key (${SLSI_RELEASE_KEY_URI})..."
  local i=0
  while [[ $i -lt $count ]]; do
    local digest
    digest="$(jq -r ".[$i].manifestDigest" "${resolved_file}")"
    local hash="${digest#sha256:}"
    local blob_path="${staging_oci}/blobs/sha256/${hash}"

    if [[ -f "${blob_path}" ]]; then
      BAO_ADDR="${SLSI_BAO_ADDR}" BAO_TOKEN="${SLSI_BAO_TOKEN}" cosign sign-blob --yes \
        --key "${SLSI_RELEASE_KEY_URI}" \
        --use-signing-config=false --tlog-upload=false \
        --bundle "${sig_dir}/${hash}.bundle" \
        "${blob_path}" > "${sig_dir}/${hash}.sig" 2>/dev/null
    fi
    i=$((i + 1))
  done

  # Prune unreferenced orphan blobs prior to promotion
  prune_oci_closure "${staging_oci}"

  # Atomically promote staging OCI layout
  rm -rf "${oci_dir}.old"
  [[ -d "${oci_dir}" ]] && mv "${oci_dir}" "${oci_dir}.old"
  mv "${staging_oci}" "${oci_dir}"
  rm -rf "${oci_dir}.old"
  log "Promoted OCI layout atomically to ${oci_dir}"

  # Assemble structured images array for bundle/images/images.json
  local images_arr=()
  local k=0
  while [[ $k -lt $count ]]; do
    local r_ref r_repo r_tag r_digest
    r_ref="$(jq -r ".[$k].ref" "${resolved_file}")"
    r_repo="$(jq -r ".[$k].repo" "${resolved_file}")"
    r_tag="$(jq -r ".[$k].tag" "${resolved_file}")"
    r_digest="$(jq -r ".[$k].manifestDigest" "${resolved_file}")"
    local r_hash="${r_digest#sha256:}"
    local r_blob="${oci_dir}/blobs/sha256/${r_hash}"

    local size_bytes=0
    local platforms_json="[\"linux/amd64\", \"linux/arm64\"]"
    if [[ -f "${r_blob}" ]]; then
      size_bytes="$(wc -c < "${r_blob}" | tr -d '[:space:]')"
      local detected_platforms
      detected_platforms="$(jq -r '[.manifests[]?.platform | select(.os and .architecture) | "\(.os)/\(.architecture)"] | unique' "${r_blob}" 2>/dev/null || true)"
      if [[ -n "$detected_platforms" && "$detected_platforms" != "[]" ]]; then
        platforms_json="$detected_platforms"
      fi
    fi

    local logical_name
    logical_name="$(basename "${r_repo}")"

    local img_obj
    img_obj="$(jq -n \
      --arg ref "$r_ref" \
      --arg resolvedRef "${r_repo}@${r_digest}" \
      --arg digest "$r_digest" \
      --arg logicalName "$logical_name" \
      --arg party "third-party" \
      --arg role "platform" \
      --arg digestKind "manifest" \
      --argjson platforms "${platforms_json}" \
      --arg ociLayoutPath "bundle/images/oci" \
      --argjson sizeBytes "$size_bytes" \
      --arg keyUri "${SLSI_RELEASE_KEY_URI}" \
      --arg pubKeyPath "bundle/keys/release.pub" \
      '{
        ref: $ref,
        resolvedRef: $resolvedRef,
        logicalName: $logicalName,
        sourceRef: $ref,
        digest: $digest,
        party: $party,
        role: $role,
        digestKind: $digestKind,
        platforms: $platforms,
        ociLayoutPath: $ociLayoutPath,
        sizeBytes: $sizeBytes,
        signature: {
          signedAtBundleTime: true,
          keyUri: $keyUri,
          publicKeyPath: $pubKeyPath
        },
        provenance: {
          upstreamSlsa: null,
          claim: "bundle-build attestation only"
        }
      }')"
    images_arr+=("$img_obj")
    k=$((k + 1))
  done

  local current_base_sha
  current_base_sha="$(git rev-parse HEAD 2>/dev/null || echo "a05a1520")"
  local substitutions_json
  substitutions_json="$(printf '%s\n' "${substitutions[@]:-}" | jq -s .)"

  cat > "${images_json_file}" <<EOF
{
  "schema": "slsi-bundle-images/v1",
  "imagesSchemaVersion": "slsi-bundle-images/v1",
  "generatedAtUtc": "${SOURCE_DATE_UTC}",
  "baseSha": "${current_base_sha}",
  "count": ${#images_arr[@]},
  "sourceLists": [
    {
      "path": "scripts/foundation-images.txt",
      "lineCount": $(wc -l < "${foundation_file}" | tr -d '[:space:]'),
      "entriesResolved": ${foundation_active_count}
    },
    {
      "path": "scripts/kagent-images.txt",
      "lineCount": $(wc -l < "${kagent_file}" | tr -d '[:space:]'),
      "entriesResolved": ${kagent_active_count}
    }
  ],
  "images": $(printf '%s\n' "${images_arr[@]}" | jq -s 'sort_by(.ref)'),
  "releaseKey": {
    "keyUri": "${SLSI_RELEASE_KEY_URI}",
    "publicKeyPath": "bundle/keys/release.pub"
  },
  "fluxVendoring": {
    "chart": {
      "name": "flux-operator",
      "repository": "oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator",
      "version": "0.57.0",
      "digest": "sha256:35105642acae3aceaf6a22e986653f766827c46e72179a9fec23214ec5f5317c",
      "stagedPath": "bundle/images/flux/charts/flux-operator-0.57.0.tgz"
    },
    "manifestsArtifactDigest": "${flux_manifests_digest}",
    "controllerImages": [
      {
        "name": "helm-controller",
        "ref": "ghcr.io/fluxcd/helm-controller:v1.6.3"
      },
      {
        "name": "kustomize-controller",
        "ref": "ghcr.io/fluxcd/kustomize-controller:v1.9.4"
      },
      {
        "name": "notification-controller",
        "ref": "ghcr.io/fluxcd/notification-controller:v1.9.2"
      },
      {
        "name": "source-controller",
        "ref": "ghcr.io/fluxcd/source-controller:v1.9.3"
      }
    ],
    "substitutions": ${substitutions_json}
  },
  "mergeContract": {
    "targetFile": "MANIFEST.json",
    "targetKey": "images",
    "owner": "P1-3",
    "rule": "jq '.images = \$imgs.images'",
    "landedOutOfOrder": false
  },
  "contractDivergence": []
}
EOF

  # OSD-6 final act: write .manifest.d/images.json and images.sha256
  local manifest_d="${BUNDLE_DIR}/.manifest.d"
  mkdir -p "${manifest_d}"
  cp "${images_json_file}" "${manifest_d}/images.json"
  (cd "${manifest_d}" && sha256sum "images.json" > "images.sha256")
  log "OSD-6: emitted ${manifest_d}/images.json and ${manifest_d}/images.sha256"

  # ── Phase C: Verification ────────────────────────────────────────────────
  verify_offline_images || exit $?

  # Append text artifact checksums to bundle/bin/checksums.txt
  if [[ -f "${BUNDLE_DIR}/bin/checksums.txt" ]]; then
    local text_artifacts=(
      "${images_dir}/resolved.json"
      "${images_dir}/images.json"
      "${images_dir}/layout-closure.json"
      "${oci_dir}/index.json"
      "${oci_dir}/oci-layout"
      "${keys_dir}/release.pub"
    )
    for art in "${text_artifacts[@]}"; do
      if [[ -f "$art" ]]; then
        local art_rel csum
        art_rel="$(realpath --relative-to="${BUNDLE_DIR}/bin" "$art")"
        csum="$(sha256sum "$art" | awk '{print $1}')"
        if grep -q "[[:space:]]${art_rel}$" "${BUNDLE_DIR}/bin/checksums.txt"; then
          sed -i.bak -E "s|^[0-9a-f]{64}([[:space:]]+${art_rel})$|${csum}\1|" "${BUNDLE_DIR}/bin/checksums.txt"
          rm -f "${BUNDLE_DIR}/bin/checksums.txt.bak"
        else
          echo "${csum}  ${art_rel}" >> "${BUNDLE_DIR}/bin/checksums.txt"
        fi
      fi
    done
  fi

  log "stage_p1_2_images complete: all platform images bundled, vendored, signed and verified"
}
# <<< SLSI-P1-2 >>>

# >>> SLSI-OSD-1: first-party application image export <<<
#
# AJM decision OSD-1, option (a) of the proposal and not a new card: export the
# three first-party applications into the bundle.
#
# The defect this closes. All 31 audited images in the bundle were third-party,
# because fe-signalloom, dashboard-signalloom and docs-signalloom are built on
# the host and moved into the cluster with `kind load`. They never passed
# through a registry the bundler inspects, so the one part of the appliance that
# is actually ControlPlane's own code was the one part the bundle could not
# attest. An air-gapped partner could verify every upstream controller and
# nothing we wrote.
#
# Identity, not tag. Their deployments say
# ${IMAGE_BASE}/signalloom/apps/<app>:${ARTIFACT_TAG}, which resolves through
# d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml to
# zot.registry.svc.cluster.local:5000/acme/images/... on the mutable tag
# `latest`. A record pinned to that tag would say nothing: with
# imagePullPolicy: IfNotPresent any image carrying it satisfies the reference,
# which is the whole argument of scripts/lib/image-identity.sh. So each record
# carries the resolved manifest digest AND the source-id its Dockerfile bakes
# in, computed by scripts/lib/source-id.sh -- the same library the build sites
# and the staleness guard use, so a tag minted by a build site and the identity
# recorded here cannot drift. The mutable ref it was exported FROM is kept as
# sourceRef, because deleting the provenance would be the same mistake in
# reverse.
#
# Why its own stage. stage_p1_2_images is the sole writer of
# bundle/.manifest.d/images.json and is forbidden to touch MANIFEST.json;
# stage_p1_3_manifest is the sole writer of MANIFEST.json. This stage amends
# images.json and re-derives its sibling images.sha256, and leaves both
# contracts standing: the records reach MANIFEST.json through P1-3's existing
# pass-through, which is also what keeps P1-3's seven gates -- arity, sentinel,
# digest shape, tag-only -- applicable to them rather than bypassed by them.
#
# Injectable boundaries (the hermetic suite sets these):
#   SLSI_CRANE_BIN             crane binary (default: crane)
#   SLSI_FIRST_PARTY_REGISTRY  registry holding the built images
#                              (default: localhost:5001 -- the port-forwarded
#                              zot the build pipeline already crane-pushes them
#                              to, so nothing new has to be stood up)
#   SLSI_FIRST_PARTY_TAG       tag to export from (default: latest)
#   SLSI_IMAGE_BASE            overrides the IMAGE_BASE read from runtime-info

OSD1_FIRST_PARTY_WORKLOADS=("dashboard-signalloom" "docs-signalloom" "fe-signalloom")
OSD1_REQUIRED_NAMESPACE="acme/images"
OSD1_RUNTIME_INFO="${OSD1_RUNTIME_INFO:-d2-osramp-fleet/clusters/local/flux-system/runtime-info.yaml}"

# IMAGE_BASE as the deployments resolve it, read from the cluster's runtime-info
# ConfigMap rather than hardcoded here. A second copy of a value that already
# exists in the tree is a copy that can disagree with what actually ships, with
# nothing to say so -- the argument scripts/check-backends.sh makes for reading
# nginx.conf instead of a hand-maintained list.
osd1_image_base() {
  if [[ -n "${SLSI_IMAGE_BASE:-}" ]]; then
    printf '%s' "${SLSI_IMAGE_BASE}"
    return 0
  fi
  local f="${REPO_ROOT}/${OSD1_RUNTIME_INFO}"
  [[ -f "${f}" ]] || fail "OSD-1: runtime-info absent at ${f}; cannot resolve IMAGE_BASE"
  local base
  # Everything after the FIRST colon, not awk -F': *' $2: the value is a
  # registry reference and carries its own colon (host:5000/acme/images), so a
  # field split returns the hostname and the namespace assertion below then
  # fails on a perfectly correct runtime-info.
  base="$(awk '/^[[:space:]]*IMAGE_BASE:/ {sub(/^[^:]*:[[:space:]]*/, "", $0); print; exit}' "${f}" | tr -d '[:space:]')"
  [[ -n "${base}" ]] || fail "OSD-1: ${f} declares no IMAGE_BASE"
  printf '%s' "${base}"
}

# The namespace component of an IMAGE_BASE: everything after the registry host.
osd1_namespace_of() {
  printf '%s' "${1#*/}"
}

osd1_repo_for() {
  printf '%s/signalloom/apps/%s' "$1" "$2"
}

# The fingerprint of a workload's build inputs, 64 hex. Refuses a short or
# malformed value rather than passing it on: a truncated fingerprint compares
# unequal to everything and would read as drift forever.
osd1_source_id() {
  local w="$1" id
  id="$(source_id_for "${w}")" || return 1
  [[ "${id}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "${id}"
}

osd1_count_blobs() {
  find "$1/blobs/sha256" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

# Resolve one source reference to a manifest digest, or print the
# DIGEST-UNRESOLVED sentinel.
#
# Printing the sentinel rather than failing here is deliberate and matches the
# P1-2 verification doctrine above: producing a sentinel is this stage's
# failure, and DETECTING and ATTRIBUTING it is P1-3's Gate 4. Failing here would
# move the detection into the producer, where there is no manifest to name it
# in; swallowing it would be the silent-acceptance defect that gate exists for.
osd1_resolve_digest() {
  local src_ref="$1"
  local crane_bin="${SLSI_CRANE_BIN:-crane}"
  local digest=""
  digest="$("${crane_bin}" digest --platform all "${src_ref}" 2>/dev/null || true)"
  if [[ "${digest}" != sha256:[0-9a-f]* ]]; then
    printf 'DIGEST-UNRESOLVED: %s' "${src_ref}"
    return 0
  fi
  printf '%s' "${digest}"
}

# Verification mode: the three records must be there and be digest-pinned.
osd1_verify_recorded() {
  local images_json="$1" missing want
  # --argjson and not --args: with --args every argument after the filter is a
  # positional string, which would swallow the input file as well.
  want="$(printf '%s\n' "${OSD1_FIRST_PARTY_WORKLOADS[@]}" | jq -R . | jq -s .)"
  missing="$(jq -r --argjson want "${want}" '
    ([.images[] | select(.party == "first-party" and .role == "application")
       | select(.digest | test("^sha256:[0-9a-f]{64}$")) | .logicalName]) as $have
    | $want - $have | .[]' "${images_json}")"
  if [[ -n "${missing}" ]]; then
    echo "ERROR: OSD-1 first-party image record absent or unpinned for: ${missing}" >&2
    return "${SLSI_VERIFY_EXIT_COULD_NOT_VERIFY}"
  fi
  log "OSD-1 verify: ${#OSD1_FIRST_PARTY_WORKLOADS[@]} first-party application images recorded and digest-pinned"
}

stage_osd_1_first_party_images() {
  if [[ "${CHECK_PINS:-0}" -eq 1 || "${SLSI_RESOLVE_ONLY:-0}" -eq 1 ]]; then
    log "stage_osd_1_first_party_images: not applicable (--check-pins/--resolve-only export no images)"
    return 0
  fi

  local images_dir="${BUNDLE_DIR}/images"
  local oci_dir="${images_dir}/oci"
  local manifest_d="${BUNDLE_DIR}/.manifest.d"
  local images_json="${manifest_d}/images.json"

  [[ -f "${images_json}" ]] || fail "OSD-1: ${images_json} is absent; stage_p1_2_images must run first"

  if [[ "${VERIFY_ONLY:-0}" -eq 1 ]]; then
    osd1_verify_recorded "${images_json}" || exit $?
    return 0
  fi

  local base ns registry from_tag crane_bin
  base="$(osd1_image_base)"
  ns="$(osd1_namespace_of "${base}")"
  registry="${SLSI_FIRST_PARTY_REGISTRY:-localhost:5001}"
  from_tag="${SLSI_FIRST_PARTY_TAG:-latest}"
  crane_bin="${SLSI_CRANE_BIN:-crane}"

  # The decision names the namespace, so a registry move that silently changed
  # it must fail the build rather than bundle under a new one.
  [[ "${ns}" == "${OSD1_REQUIRED_NAMESPACE}" ]] || \
    fail "OSD-1: IMAGE_BASE '${base}' yields namespace '${ns}', expected '${OSD1_REQUIRED_NAMESPACE}'"

  log "OSD-1: exporting ${#OSD1_FIRST_PARTY_WORKLOADS[@]} first-party images from ${registry}/${ns} into ${oci_dir}"

  mkdir -p "${oci_dir}/blobs/sha256"
  if [[ ! -f "${oci_dir}/oci-layout" ]]; then
    printf '{"imageLayoutVersion":"1.0.0"}\n' > "${oci_dir}/oci-layout"
  fi
  if [[ ! -f "${oci_dir}/index.json" ]]; then
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}\n' > "${oci_dir}/index.json"
  fi

  local blobs_before sentinel_count=0
  blobs_before="$(osd1_count_blobs "${oci_dir}")"

  local tmp_recs
  tmp_recs="$(mktemp -t slsi-osd1-records.XXXXXX)"
  local w repo src_ref digest hash blob size platforms sid stag
  : > "${tmp_recs}.ndjson"

  for w in "${OSD1_FIRST_PARTY_WORKLOADS[@]}"; do
    repo="$(osd1_repo_for "${base}" "${w}")"
    src_ref="${registry}/${ns}/signalloom/apps/${w}:${from_tag}"

    sid="$(osd1_source_id "${w}")" || {
      rm -f "${tmp_recs}" "${tmp_recs}.ndjson"
      fail "OSD-1: cannot fingerprint ${w}; refusing to record an image whose identity is unknown"
    }
    stag="src-${sid:0:12}"

    digest="$(osd1_resolve_digest "${src_ref}")"
    size=0
    platforms='["linux/amd64"]'

    if [[ "${digest}" == sha256:* ]]; then
      log "OSD-1: ${w} -> ${digest} (source-id ${stag})"
      local pull_ref="${registry}/${ns}/signalloom/apps/${w}@${digest}"
      "${crane_bin}" pull --format=oci --annotate-ref "${pull_ref}" "${oci_dir}"
      hash="${digest#sha256:}"
      blob="${oci_dir}/blobs/sha256/${hash}"
      if [[ -f "${blob}" ]]; then
        size="$(wc -c < "${blob}" | tr -d '[:space:]')"
        local detected
        detected="$(jq -r '[.manifests[]?.platform | select(.os and .architecture) | "\(.os)/\(.architecture)"] | unique' "${blob}" 2>/dev/null || true)"
        if [[ -n "${detected}" && "${detected}" != "[]" ]]; then
          platforms="${detected}"
        fi
      else
        rm -f "${tmp_recs}" "${tmp_recs}.ndjson"
        fail "OSD-1: ${crane_bin} pull reported success for ${repo}@${digest} but wrote no blob at ${blob}"
      fi
    else
      echo "ERROR: OSD-1 could not resolve a digest for ${src_ref}; recording the sentinel for P1-3 Gate 4 to attribute." >&2
      sentinel_count=$((sentinel_count + 1))
    fi

    jq -n \
      --arg ref "${repo}@${digest}" \
      --arg logicalName "${w}" \
      --arg sourceRef "${src_ref}" \
      --arg digest "${digest}" \
      --arg sourceId "${sid}" \
      --arg sourceIdTag "${stag}" \
      --argjson platforms "${platforms}" \
      --argjson sizeBytes "${size}" \
      --arg keyUri "${SLSI_RELEASE_KEY_URI}" \
      '{
        ref: $ref,
        resolvedRef: $ref,
        logicalName: $logicalName,
        sourceRef: $sourceRef,
        digest: $digest,
        party: "first-party",
        role: "application",
        digestKind: "manifest",
        sourceId: $sourceId,
        sourceIdTag: $sourceIdTag,
        platforms: $platforms,
        ociLayoutPath: "bundle/images/oci",
        sizeBytes: $sizeBytes,
        provenance: {
          upstreamSlsa: null,
          claim: "first-party: built from this source tree, identity is sourceId"
        }
      }' >> "${tmp_recs}.ndjson"
  done

  jq -s 'sort_by(.ref)' "${tmp_recs}.ndjson" > "${tmp_recs}"

  local declared
  declared="$(jq 'length' "${tmp_recs}")"
  if [[ "${declared}" -ne "${#OSD1_FIRST_PARTY_WORKLOADS[@]}" ]]; then
    rm -f "${tmp_recs}" "${tmp_recs}.ndjson"
    fail "OSD-1 arity: assembled ${declared} records for ${#OSD1_FIRST_PARTY_WORKLOADS[@]} workloads"
  fi

  # Amend images.json. Replacing every first-party application record rather
  # than appending makes the stage idempotent: a second run cannot double the
  # set, and `count` stays in arity with the array, which is what P1-3's Gate 3
  # compares. Keying the removal on party+role and not on logicalName means a
  # third-party image that happens to share a name is never collateral.
  local tmp_images
  tmp_images="$(mktemp -t slsi-osd1-images.XXXXXX)"
  jq --slurpfile recs "${tmp_recs}" \
     --arg reg "${registry}" --arg ns "${ns}" --arg at "${SOURCE_DATE_UTC}" '
    .images = ((((.images // []) | map(select((.party == "first-party" and .role == "application") | not))) + $recs[0]) | sort_by(.ref))
    | .count = (.images | length)
    | .firstPartyExport = {
        decision: "OSD-1",
        workloads: ($recs[0] | map(.logicalName) | sort),
        sourceRegistry: $reg,
        namespace: $ns,
        identity: "sourceId (scripts/lib/source-id.sh), not the mutable tag the deployment resolves to",
        exportedAtUtc: $at
      }
  ' "${images_json}" > "${tmp_images}"
  mv -f "${tmp_images}" "${images_json}"
  if [[ -f "${images_dir}/images.json" ]]; then
    cp "${images_json}" "${images_dir}/images.json"
  fi
  (cd "${manifest_d}" && sha256sum "images.json" > "images.sha256")

  # Merge the descriptors into the layout index, deduplicating by digest so a
  # re-run is a no-op here too.
  local tmp_index
  tmp_index="$(mktemp -t slsi-osd1-index.XXXXXX)"
  jq --slurpfile recs "${tmp_recs}" '
    . as $root
    | ($recs[0] | map(.ref | split("@")[0])) as $updated_repos
    | ([$recs[0][] | select(.digest | startswith("sha256:")) | . as $r |
        (($root.manifests // []) | map(select(.digest == $r.digest))[0]) as $existing |
        {
          mediaType: ($existing.mediaType // "application/vnd.oci.image.index.v1+json"),
          size: (if ($existing.size // 0) > 0 then $existing.size elif .sizeBytes > 0 then .sizeBytes else 1 end),
          digest: .digest,
          annotations: (($existing.annotations // {}) + {"org.opencontainers.image.ref.name": .ref})
        }
      ]) as $new
    | ($new | map(.digest)) as $newd
    | .schemaVersion = 2
    | .mediaType = "application/vnd.oci.image.index.v1+json"
    | .manifests = (((.manifests // []) | map(. as $m |
        select(
          (($newd | index($m.digest)) == null) and
          (($m.annotations["org.opencontainers.image.ref.name"] // "") as $an |
           ($updated_repos | any(. as $p | $an | startswith($p + "@"))) | not)
        )
      )) + $new)
  ' "${oci_dir}/index.json" > "${tmp_index}"
  mv -f "${tmp_index}" "${oci_dir}/index.json"
  cp "${oci_dir}/index.json" "${images_dir}/index.json"

  # bundle/images/layout-closure.json is P1-2's record of a closure this stage
  # has just changed, and verify_offline_images compares its two counters
  # against a fresh walk. Leaving it stale would make the next --verify-only
  # report MISMATCH -- a claim of PROVEN corruption -- over a bundle that is
  # merely larger than the record. So it is recomputed here, and
  # closureVerified reports what the walk actually found rather than being
  # assumed: on a skeleton bundle whose blobs were never fetched the walk is
  # inconclusive, and saying so is the honest answer.
  prune_oci_closure "${oci_dir}"
  local walk_rc=0
  walk_oci_closure "${oci_dir}" || walk_rc=$?
  local closure_verified="true"
  if [[ "${walk_rc}" -ne 0 ]]; then
    closure_verified="false"
  fi
  cat > "${images_dir}/layout-closure.json" <<EOF
{
  "layoutPath": "bundle/images/oci",
  "totalReachableDescriptors": ${CLOSURE_TOTAL_REACHABLE:-0},
  "totalBlobsOnDisk": ${CLOSURE_TOTAL_DISK:-0},
  "danglingDescriptors": ${CLOSURE_DANGLING_JSON:-[]},
  "orphanBlobs": ${CLOSURE_ORPHANS_JSON:-[]},
  "closureVerified": ${closure_verified},
  "verifiedAt": "${SOURCE_DATE_UTC}"
}
EOF

  local blobs_after
  blobs_after="$(osd1_count_blobs "${oci_dir}")"
  rm -f "${tmp_recs}" "${tmp_recs}.ndjson"

  log "stage_osd_1_first_party_images complete: ${declared} first-party records (${sentinel_count} unresolved), blobs ${blobs_before} -> ${blobs_after}, images.json count $(jq -r '.count' "${images_json}")"
}
# <<< SLSI-OSD-1 >>>

# >>> SLSI-P1-3: manifest compilation and bundle assembly <<<
stage_p1_3_manifest() {
  local version="${SLSI_VERSION:-${BUNDLE_VERSION:-0.1.0}}"
  version="${version#v}"
  local bundle_name="slsi-appliance-${version}"
  local out_dir="${SLSI_BUNDLE_OUT:-${REPO_ROOT}/dist}"
  local archive_name="${bundle_name}.tar.gz"
  local bundle_dir="${BUNDLE_DIR:-${REPO_ROOT}/bundle}"
  local schema_file="${REPO_ROOT}/schemas/slsi-appliance-manifest-schema.json"
  local schema_validator="${REPO_ROOT}/scripts/lib/json-schema-lite.jq"

  log "Executing stage_p1_3_manifest: bundle assembly and root manifest compilation"

  if [[ "${VERIFY_ONLY:-0}" -eq 1 ]]; then
    log "VERIFY_ONLY requested; verifying existing manifest and archive"
    local target_manifest="${out_dir}/MANIFEST.json"
    local target_archive="${out_dir}/${archive_name}"
    [[ -f "${target_manifest}" ]] || fail "Cannot verify: ${target_manifest} does not exist"
    [[ -f "${target_archive}" ]] || fail "Cannot verify: ${target_archive} does not exist"

    local v_violations
    v_violations="$(jq -n -r --slurpfile schema "${schema_file}" --slurpfile doc "${target_manifest}" --arg ptr '#' -f "${schema_validator}")"
    if [[ -n "${v_violations}" ]]; then
      echo "ERROR: Schema violations in ${target_manifest}:" >&2
      echo "${v_violations}" >&2
      fail "Gate 1 failed: MANIFEST.json schema violations"
    fi

    local verify_tmp
    verify_tmp="$(mktemp -d -t slsi-verify.XXXXXX)"
    tar -xzf "${target_archive}" -C "${verify_tmp}"
    (
      cd "${verify_tmp}" && \
      jq -r '.payload[] | "\(.sha256) \(.path)"' MANIFEST.json | sha256sum -c --strict - >/dev/null 2>&1
    ) || { rm -rf "${verify_tmp}"; fail "Seal correctness check failed"; }

    local on_disk declared
    on_disk="$(find "${verify_tmp}" -type f ! -name MANIFEST.json | sed "s|^${verify_tmp}/||" | LC_ALL=C sort)"
    declared="$(jq -r '.payload[].path' "${verify_tmp}/MANIFEST.json" | LC_ALL=C sort)"
    diff <(printf '%s\n' "$on_disk") <(printf '%s\n' "$declared") >/dev/null 2>&1 || {
      rm -rf "${verify_tmp}"
      fail "Seal completeness check failed"
    }
    rm -rf "${verify_tmp}"
    log "stage_p1_3_manifest verify complete: archive and manifest passed all checks"
    return 0
  fi

  local epoch="${SOURCE_DATE_EPOCH:-$(git -c log.showSignature=false log -1 --pretty=%ct 2>/dev/null || date -u +%s)}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || fail "SOURCE_DATE_EPOCH must be an integer (got: ${epoch})"
  local created_at
  created_at="$(date -u -d "@${epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${epoch}" +'%Y-%m-%dT%H:%M:%SZ')"

  local manifest_d_json="${bundle_dir}/.manifest.d/images.json"
  local manifest_d_sha="${bundle_dir}/.manifest.d/images.sha256"

  if [[ ! -f "${manifest_d_json}" ]]; then
    fail "images manifest is absent at ${manifest_d_json}"
  fi

  if [[ -f "${manifest_d_sha}" ]]; then
    (cd "${bundle_dir}/.manifest.d" && sha256sum -c --strict images.sha256 >/dev/null 2>&1) || \
      fail "Gate 2 failed: images.json checksum does not match images.sha256"
  fi

  local img_count img_len
  img_count="$(jq -r '.count // empty' "${manifest_d_json}")"
  img_len="$(jq -r '.images | length' "${manifest_d_json}")"
  if [[ -n "${img_count}" && "${img_count}" -ne "${img_len}" ]]; then
    fail "Gate 3 failed: declared count (${img_count}) != image array length (${img_len})"
  fi

  local sentinels
  sentinels="$(grep -oE '(DIGEST-UNRESOLVED|UNRESOLVED_UPSTREAM)[^"]*' "${manifest_d_json}" | head -n 5 || true)"
  if [[ -n "${sentinels}" ]]; then
    echo "ERROR: Unresolved digest sentinel found in images: ${sentinels}" >&2
    rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
    fail "Gate 4 failed: unresolved digest sentinels present in images.json"
  fi

  local invalid_digests
  invalid_digests="$(jq -r '.images[].digest | select(test("^sha256:[0-9a-f]{64}$") | not)' "${manifest_d_json}" | head -n 5)"
  if [[ -n "${invalid_digests}" ]]; then
    echo "ERROR: Non-sha256 or malformed digest found: ${invalid_digests}" >&2
    rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
    fail "Gate 5 failed: image digests must match ^sha256:[0-9a-f]{64}$"
  fi

  local tag_only
  tag_only="$(jq -r '.images[] | select((.digest // "") == "" or ((.digest | test("^sha256:[0-9a-f]{64}$")) | not) or (((.ref // "") | test(":[^@/]+$")) and ((.resolvedRef // "") == ""))) | (.ref // .digest)' "${manifest_d_json}" | head -n 5)"
  if [[ -n "${tag_only}" ]]; then
    echo "ERROR: Tag-only unpinned image reference: ${tag_only}" >&2
    rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
    fail "Gate 6 failed: tag-only image reference without digest: ${tag_only}"
  fi

  # Gate 7, inverted. It used to REQUIRE the Decision 10 utility image in the
  # images index and abort if it was missing. The reversal makes the opposite
  # the invariant, and the gate is kept rather than deleted so the reversal has
  # a gate of its own: reintroducing the entry must fail the build, not pass it
  # quietly.
  #
  # The digest below is retained solely as the thing being forbidden. It is a
  # dangling reference -- no blob with it exists in the layout. Worth stating
  # precisely, because an earlier reading of this had it uniquely dangling:
  # bundle/images/oci/ holds exactly two files (oci-layout, index.json) and
  # ZERO blobs against 31 claimed manifests, so every digest in that index is
  # blob-less. This one is uniquely *unresolvable*, which is the real defect --
  # it names an image published in no registry, where the other 30 name real
  # upstream images that simply have not been fetched into the layout.
  local forbidden_util_digest="sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b"

  # Gate 7a: no containerised-utility record may reach the manifest.
  #
  # This half exists because the other half cannot fail on input. The staged
  # index is produced by a filter that explicitly drops forbidden_util_digest,
  # so an index-only gate can only ever catch a future re-introduction of the
  # injection CODE -- never a poisoned input. That is a gate which no fixture
  # can fire, and a gate no fixture can fire is indistinguishable from no gate.
  #
  # The images array is different: it comes straight from .manifest.d, which
  # the bundler does not filter, so a planted record DOES reach the manifest
  # and this check DOES fire on it. Matched by name and by role rather than by
  # the one digest, because a re-introduction under a new digest is the same
  # defect. test/slsi-bundle-seal-falsification.sh case 7 is the fixture.
  local util_records
  util_records="$(jq -r '
    [ .images[]? | select((.role? == "utility") or (((.ref? // "") + (.logicalName? // "")) | test("slsi-util"))) ]
    | .[] | (.ref // .logicalName // "unnamed")
  ' "${manifest_d_json}")"
  if [[ -n "${util_records}" ]]; then
    echo "ERROR: a containerised-utility image record reached the manifest:" >&2
    printf '  %s\n' "${util_records}" >&2
    echo "Decision 10 is reversed: controlplane/slsi-util was never published, has no Dockerfile" >&2
    echo "in this tree, and resolves in no registry. The appliance ships bin/<arch>/ed25519-keygen." >&2
    rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
    fail "Gate 7 failed: utility image record present in images.json"
  fi

  # Gate 7b fires later, against the index this run STAGES rather than
  # the one already committed. That distinction is the whole design: the
  # committed bundle/images/index.json still carries the entry, and a gate
  # reading it here would abort before the code below ever got the chance to
  # filter it out -- a deadlock where the fix can never run. Gating the staged
  # output instead asserts the thing actually being shipped, and lets the
  # stale committed file heal on the same run (it is overwritten from the
  # staged copy a few lines further down).

  local stage_root meta_dir stage_dir
  stage_root="$(mktemp -d -t slsi-bundle-stage.XXXXXX)"
  meta_dir="${stage_root}/meta"
  mkdir -p "${meta_dir}"
  stage_dir="${stage_root}/payload"
  mkdir -p "${stage_dir}"

  # 1. Binaries
  mkdir -p "${stage_dir}/bin"
  if [[ -d "${bundle_dir}/bin" ]]; then
    cp -r "${bundle_dir}/bin/." "${stage_dir}/bin/"
  fi

  local bin_csum="${bundle_dir}/bin/checksums.txt"
  if [[ -f "${bin_csum}" ]]; then
    local selected_arch="amd64"
    if [[ "${TARGET_ARCH:-amd64}" == "arm64" ]]; then
      selected_arch="arm64"
    fi
    # The tool set is declared once, here, because it was previously inlined
    # into two greps and an arity literal. ed25519-keygen had to be added to
    # all three or the archive would carry bin/<arch>/ed25519-keygen while its
    # own bin/checksums.txt did not list it -- an unlisted executable inside
    # the bundle, which is the exact hole that was just closed on the
    # bundle/bin side in verify_offline_manifest.
    local staged_tool_re='cosign|ed25519-keygen|flux|jq|kind|kubectl'
    local staged_tool_count=6

    grep -E "[[:space:]]${selected_arch}/(${staged_tool_re})\$" "${bin_csum}" > "${stage_dir}/bin/checksums.txt" || true
    if [[ $(wc -l < "${stage_dir}/bin/checksums.txt") -ne "${staged_tool_count}" ]]; then
      grep -E "[[:space:]](amd64/|arm64/)?(${staged_tool_re})\$" "${bin_csum}" | \
        awk '{split($NF, a, "/"); name=a[length(a)]; if (!seen[name]++) print}' > "${stage_dir}/bin/checksums.txt"
    fi
  fi

  # 2. Release public key
  mkdir -p "${stage_dir}/keys"
  if [[ -f "${bundle_dir}/keys/release.pub" ]]; then
    cp "${bundle_dir}/keys/release.pub" "${stage_dir}/keys/release.pub"
  elif [[ -f "${REPO_ROOT}/.keys/cosign.pub" ]]; then
    cp "${REPO_ROOT}/.keys/cosign.pub" "${stage_dir}/keys/release.pub"
  else
    rm -rf "${stage_root}"
    fail "Release public key absent at ${bundle_dir}/keys/release.pub"
  fi

  source "${REPO_ROOT}/scripts/lib/eap-evidence.sh"
  local release_key_fp
  release_key_fp="$(eap_pubkey_fingerprint "${stage_dir}/keys/release.pub")"
  if [[ -z "${release_key_fp}" ]]; then
    rm -rf "${stage_root}"
    fail "Failed to compute fingerprint from ${stage_dir}/keys/release.pub"
  fi

  # 3. Fleet overlays (closed under ../base and including agent-swarm)
  mkdir -p "${stage_dir}/fleet/d2-osramp-fleet/tenants"
  cp -r "${REPO_ROOT}/d2-osramp-fleet/tenants/base" "${stage_dir}/fleet/d2-osramp-fleet/tenants/"
  cp -r "${REPO_ROOT}/d2-osramp-fleet/tenants/local" "${stage_dir}/fleet/d2-osramp-fleet/tenants/"
  mkdir -p "${stage_dir}/fleet/d2-signalloom/infra/agent-swarm"
  cp -r "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden" "${stage_dir}/fleet/d2-signalloom/infra/agent-swarm/"
  mkdir -p "${stage_dir}/fleet/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays"
  if [[ -d "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant" ]]; then
    cp -r "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant" "${stage_dir}/fleet/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/"
  fi

  # 4. Infra
  mkdir -p "${stage_dir}/infra"
  cp -r "${REPO_ROOT}/d2-infra" "${stage_dir}/infra/"

  # 5. Images layout and utility image
  mkdir -p "${stage_dir}/images"
  if [[ -d "${bundle_dir}/images" ]]; then
    cp -r "${bundle_dir}/images/." "${stage_dir}/images/"
  fi

  local base_index_src="${bundle_dir}/images/oci/index.json"
  if [[ ! -f "${base_index_src}" && -f "${bundle_dir}/images/index.json" ]]; then
    base_index_src="${bundle_dir}/images/index.json"
  fi

  # The slsi-util entry was INJECTED here, from a hardcoded constant, over a
  # base index read from the committed layout -- so the dangling digest in
  # bundle/images/index.json was this line's output, not an upstream artefact.
  # Dropping the injection is therefore enough to remove it, and it is
  # hermetic: the surviving entries all come from the committed base file, so
  # no digest is computed, fetched, or invented. The second filtered digest
  # (41223e96...) is an older generation of the same injection and stays
  # filtered for the same reason.
  if [[ -f "${base_index_src}" ]]; then
    jq --arg ud "${forbidden_util_digest}" '
      .schemaVersion = 2 |
      .mediaType = "application/vnd.oci.image.index.v1+json" |
      .manifests = [
        .manifests[]?
        | select(.digest != $ud and .digest != "sha256:41223e96853ea6817d12aa8cf5dc43de49b7abab6892bb12ab39190cc12bba0c")
      ]
    ' "${base_index_src}" > "${stage_dir}/images/index.json"
  else
    jq '
      {
        schemaVersion: 2,
        mediaType: "application/vnd.oci.image.index.v1+json",
        manifests: [
          .images[]? | {
            mediaType: "application/vnd.oci.image.index.v1+json",
            size: 1609,
            digest: .digest,
            annotations: {
              "org.opencontainers.image.ref.name": (.resolvedRef // .ref)
            }
          }
        ]
      }
    ' "${manifest_d_json}" > "${stage_dir}/images/index.json"
  fi

  # Gate 7b, inverted: the slsi-util image must NOT be in the index being
  # shipped. Checked here, on the staged output, for the reason given where
  # forbidden_util_digest is declared.
  #
  # No `2>/dev/null || echo 0` on this jq. The previous Gate 7 had it, so a jq
  # failure read as "count is 0" -- which for the old gate meant abort, but for
  # this inverted one would mean PASS. A check that cannot run must not look
  # like a check that passed, so the failure is allowed to propagate.
  local staged_has_util
  staged_has_util="$(jq --arg d "${forbidden_util_digest}" \
    '[.manifests[]? | select(.digest == $d)] | length' "${stage_dir}/images/index.json")"
  if [[ "${staged_has_util}" -ne 0 ]]; then
    rm -rf "${stage_root}"
    rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
    echo "ERROR: the slsi-util image ${forbidden_util_digest} is present in the staged images index" >&2
    echo "Decision 10 is reversed: that image was never published, has no Dockerfile in this tree," >&2
    echo "and resolves in no registry. The appliance ships bin/<arch>/ed25519-keygen instead." >&2
    fail "Gate 7 failed: unpublishable slsi-util image present in staged images index"
  fi

  cp "${stage_dir}/images/index.json" "${bundle_dir}/images/index.json" 2>/dev/null || true
  if [[ -d "${bundle_dir}/images/oci" ]]; then
    cp "${stage_dir}/images/index.json" "${bundle_dir}/images/oci/index.json" 2>/dev/null || true
  fi
  if [[ -d "${stage_dir}/images/oci" ]]; then
    cp "${stage_dir}/images/index.json" "${stage_dir}/images/oci/index.json" 2>/dev/null || true
  fi

  # Normalize wall-clock timestamps in staged image manifests to created_at (option a)
  if [[ -f "${stage_dir}/images/resolved.json" ]]; then
    jq --arg t "${created_at}" 'map(.resolvedAt = $t)' "${stage_dir}/images/resolved.json" > "${meta_dir}/resolved.json" && mv "${meta_dir}/resolved.json" "${stage_dir}/images/resolved.json"
  fi
  if [[ -f "${stage_dir}/images/layout-closure.json" ]]; then
    jq --arg t "${created_at}" '.verifiedAt = $t' "${stage_dir}/images/layout-closure.json" > "${meta_dir}/layout-closure.json" && mv "${meta_dir}/layout-closure.json" "${stage_dir}/images/layout-closure.json"
  fi
  if [[ -f "${stage_dir}/images/images.json" ]]; then
    jq --arg t "${created_at}" '.generatedAtUtc = $t' "${stage_dir}/images/images.json" > "${meta_dir}/images.json" && mv "${meta_dir}/images.json" "${stage_dir}/images/images.json"
  fi


  # 6. Anti-Criteria: Check for private key leaks
  local privkey_leak=0
  local privkey_matches
  privkey_matches="$(grep -rEn '-----BEGIN ([A-Z0-9 ]+)?PRIVATE KEY-----' "${stage_dir}" 2>/dev/null || true)"
  if [[ -n "${privkey_matches}" ]]; then
    echo "CRITICAL: Private key content detected in bundle staging tree:" >&2
    echo "${privkey_matches}" >&2
    privkey_leak=1
  fi
  local privkey_files
  privkey_files="$(find "${stage_dir}" -type f \( -name "*.key" -o -name "cosign.key" -o -name "release.key" -o -name "*-escrow.tar.enc" \) 2>/dev/null || true)"
  if [[ -n "${privkey_files}" ]]; then
    echo "CRITICAL: Private key file detected in bundle staging tree:" >&2
    echo "${privkey_files}" >&2
    privkey_leak=1
  fi
  if [[ "${privkey_leak}" -ne 0 ]]; then
    rm -rf "${stage_root}"
    fail "Security gate failed: private key material detected in bundle payload"
  fi

  # 7. Normalize file and directory modes
  find "${stage_dir}" -type d -exec chmod 0755 {} +
  find "${stage_dir}" -type f -exec chmod 0644 {} +
  find "${stage_dir}/bin" -type f ! -name "*.txt" ! -name "*.json" ! -name "*.pub" -exec chmod 0755 {} + 2>/dev/null || true
  find "${stage_dir}" -type f -name "*.sh" -exec chmod 0755 {} + 2>/dev/null || true

  # 8. Compute MANIFEST.sha256
  (
    cd "${stage_dir}" && \
    find . -type f ! -name "MANIFEST.json" ! -name "MANIFEST.sha256" | \
      sed 's|^\./||' | \
      LC_ALL=C sort | \
      xargs sha256sum > MANIFEST.sha256
  )
  chmod 0644 "${stage_dir}/MANIFEST.sha256"

  # 9. Assemble payload[] list for MANIFEST.json (off-argv via file)
  (
    cd "${stage_dir}" && \
    find . -type f ! -name "MANIFEST.json" | sed 's|^\./||' | LC_ALL=C sort | xargs stat -c '%04a %s	%n' > "${meta_dir}/stats.txt"
    cat "${stage_dir}/MANIFEST.sha256" <(sha256sum MANIFEST.sha256) > "${meta_dir}/hashes.txt"
  )
  jq -n \
    --rawfile hashes "${meta_dir}/hashes.txt" \
    --rawfile stats "${meta_dir}/stats.txt" '
    ($stats | split("\n") | map(select(length > 0) | split("\t")) | map({(.[1]): (.[0] | split(" ") | {mode: .[0], bytes: (.[1] | tonumber)})}) | add) as $st |
    ($hashes | split("\n") | map(select(length > 0)) | map(
      capture("^(?<csum>[0-9a-f]{64})\\s+(?<path>.+)$") | {
        path: .path,
        sha256: .csum,
        mode: ($st[.path].mode // "0644"),
        bytes: ($st[.path].bytes // 0)
      }
    ) | sort_by(.path))
  ' > "${meta_dir}/payload.json"

  # 10. Assemble git metadata
  local git_commit git_branch git_dirty
  git_commit="$(git -c log.showSignature=false rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"
  git_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "detached")"
  git_dirty=false
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    git_dirty=true
  fi

  # 11. Assemble images array in MANIFEST.json (off-argv via file)
  #
  # The synthetic slsi-util entry that used to be appended here is gone. Note
  # what it claimed: party "first-party", a 14800000-byte sizeBytes, and an
  # ociLayoutPath into a layout holding no blobs -- all three asserted about an
  # image that exists nowhere. Every entry in this array is now a real image
  # the resolver actually saw.
  jq '
    [
      .images[] |
      .reference = (.ref | split("@")[0] | sub(":[^/]+$"; "")) |
      .ref = (.resolvedRef // .ref)
    ]
  ' "${manifest_d_json}" > "${meta_dir}/images.json"

  # 12. Assemble stagedBinaries array (off-argv via file)
  if [[ -f "${stage_dir}/bin/checksums.txt" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      csum="$(echo "$line" | awk '{print $1}')"
      path="$(echo "$line" | awk '{print $2}')"
      bname="$(basename "$path")"
      arch="$(dirname "$path" | sed 's|^\.||' | tr -d '/')"
      [[ -z "$arch" ]] && arch="${TARGET_ARCH:-amd64}"
      jq -n --arg name "$bname" --arg arch "$arch" --arg csum "$csum" \
        '{name: $name, arch: $arch, sha256: $csum, mode: "0755"}'
    done < "${stage_dir}/bin/checksums.txt" | jq -s '.' > "${meta_dir}/staged_binaries.json"
  else
    echo "[]" > "${meta_dir}/staged_binaries.json"
  fi

  # Coverage exclusions. Measured domain before this list was written: the
  # staged fleet and infra trees plus the vendored Flux manifests yield 8
  # digest-less references, and test/helpers/airgap-sandbox.bash's
  # airgap_digestless_refs computes the same 8 over the extracted archive. Four
  # are structural (a Helm chart repository has no image digest to pin; a
  # never-pulled local tag has no registry to pin against) and four are the
  # AJM OSD-2 deferrals.
  #
  # Every entry carries a justification because the reason word alone cannot say
  # why THIS reference was excused, and an exclusion nobody can read is
  # indistinguishable from an oversight.
  #
  # OSD-2 is a deferral, not an exemption, and the two must not be confusable:
  # these four CAN be pinned and one day will be. What makes the deferral
  # tolerable in development is recorded per entry rather than asserted in
  # prose somewhere else -- each is version-tagged or source-id-tagged, never
  # floating on :latest, which is why tag and mutableTag are here and why the
  # gate below refuses a dev-deferred-pin entry whose tag could move.
  cat > "${meta_dir}/coverage_exclusions.json" <<'EOF'
[
  {
    "ref": "docker.io/envoyproxy/gateway-helm",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository",
    "justification": "A HelmRepository names a chart repository, not an image. There is no image manifest digest to pin at this reference; the images the chart renders are pinned individually.",
    "ownedBy": "SLSI-P1-2"
  },
  {
    "ref": "ghcr.io/prometheus-community/charts/kube-prometheus-stack",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository",
    "justification": "A HelmRepository names a chart repository, not an image. There is no image manifest digest to pin at this reference; the images the chart renders are pinned individually.",
    "ownedBy": "SLSI-P1-2"
  },
  {
    "ref": "quay.io/jetstack/charts/cert-manager",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository",
    "justification": "A HelmRepository names a chart repository, not an image. There is no image manifest digest to pin at this reference; the images the chart renders are pinned individually.",
    "ownedBy": "SLSI-P1-2"
  },
  {
    "ref": "netassert-runner:local",
    "reason": "local-never-pulled",
    "kind": "Job",
    "justification": "Built on the host and loaded into the node directly, so it is never pulled from a registry and no registry digest exists for the appliance to pin or verify against.",
    "ownedBy": "SLSI-P1-2"
  },
  {
    "ref": "ghcr.io/controlplaneio-in-toto/signalloom-warden:src-50c79ef7e84f",
    "reason": "dev-deferred-pin",
    "kind": "DaemonSet",
    "tag": "src-50c79ef7e84f",
    "mutableTag": false,
    "justification": "AJM decision OSD-2: pinning deferred for development. First-party image on a source-id tag, which is a fingerprint of its build inputs and therefore immutable in practice; one reference site in d2-signalloom/infra/agent-swarm/signalloom-warden/daemonset.yaml.",
    "ownedBy": "SLSI-P2-1"
  },
  {
    "ref": "ghcr.io/stefanprodan/podinfo:6.7.1",
    "reason": "dev-deferred-pin",
    "kind": "ResourceSet",
    "tag": "6.7.1",
    "mutableTag": false,
    "justification": "AJM decision OSD-2: pinning deferred for development. Upstream release tag of an inert demo workload, not a floating tag; one reference site in d2-osramp-fleet/tenants/local/signalloom.yaml.",
    "ownedBy": "SLSI-P2-1"
  },
  {
    "ref": "python:3.12-slim",
    "reason": "dev-deferred-pin",
    "kind": "CronJob",
    "tag": "3.12-slim",
    "mutableTag": false,
    "justification": "AJM decision OSD-2: pinning deferred for development. Version-tagged base image of the RBAC exporter CronJob, a workload rather than a platform component; one reference site in d2-signalloom/infra/agent-swarm/signalloom-warden/rbac-exporter-cronjob.yaml.",
    "ownedBy": "SLSI-P2-1"
  },
  {
    "ref": "registry.k8s.io/coredns/coredns:v1.14.2",
    "reason": "dev-deferred-pin",
    "kind": "Deployment",
    "tag": "v1.14.2",
    "mutableTag": false,
    "justification": "AJM decision OSD-2: pinning deferred for development. Upstream version tag of the cross-cluster DNS stub; one reference site in d2-infra/components/coredns/cross-cluster-stubs.yaml.",
    "ownedBy": "SLSI-P2-1"
  }
]
EOF

  # 12b. The installer slot, MEASURED (AJM decision OSD-3).
  #
  # Absence needs positive evidence, and a consumer should not have to infer the
  # state of the self-initialisation slot from a file that is not there -- "not
  # found" and "not allowed to look" produce identical silence. So the slot is
  # declared, and both its scopes are stat'd here rather than asserted:
  #
  #   present        is the installer in THIS BUNDLE PAYLOAD. Phase 1 ships no
  #                  scripts/ tree, so it is false, and that is a valid state.
  #   sourcePresent  does the repository carry one yet. It now does: a stub that
  #                  initialises nothing and exits 69 on every operational path.
  #
  # Reporting one number for both would have to lie about one of them.
  local installer_rel="scripts/init-tenant.sh"
  local installer_present=false installer_source_present=false
  # `if`, not `[[ ... ]] && x=true`: the AND list returns the test's status and
  # this script runs under `set -Eeuo pipefail` with an ERR trap that exits 1.
  if [[ -e "${stage_dir}/${installer_rel}" ]]; then
    installer_present=true
  fi
  if [[ -e "${REPO_ROOT}/${installer_rel}" ]]; then
    installer_source_present=true
  fi
  local installer_source_status="absent: no installer in the source tree"
  if [[ "${installer_source_present}" == "true" ]]; then
    installer_source_status="stub only: initialises nothing and exits 69 naming SLSI-P2-1 on every operational path"
  fi

  # 13. Write MANIFEST.json (all bulk data off-argv via --slurpfile)
  jq -n \
    --slurpfile payload "${meta_dir}/payload.json" \
    --slurpfile images "${meta_dir}/images.json" \
    --slurpfile staged_binaries "${meta_dir}/staged_binaries.json" \
    --slurpfile coverage_exclusions "${meta_dir}/coverage_exclusions.json" \
    --arg schema "slsi-bundle/v1" \
    --arg schema_url "slsi-appliance-manifest/v1" \
    --arg name "${bundle_name}" \
    --arg version "${version}" \
    --arg created_at "${created_at}" \
    --argjson epoch "${epoch}" \
    --arg git_commit "${git_commit}" \
    --arg git_branch "${git_branch}" \
    --argjson git_dirty "${git_dirty}" \
    --arg key_fp "${release_key_fp}" \
    --arg installer_path "${installer_rel}" \
    --argjson installer_present "${installer_present}" \
    --argjson installer_source_present "${installer_source_present}" \
    --arg installer_source_status "${installer_source_status}" \
    '{
      "$schema": $schema_url,
      "schema": $schema,
      "bundle": {
        "name": $name,
        "version": $version,
        "createdAtUtc": $created_at,
        "applianceModes": ["attached", "hub"]
      },
      "sourceDateEpoch": $epoch,
      "git": {
        "commit": $git_commit,
        "commitSha": $git_commit,
        "branch": $git_branch,
        "dirty": $git_dirty
      },
      "payload": $payload[0],
      "payloadFileCount": ($payload[0] | length),
      "payloadTotalBytes": ([$payload[0][].bytes] | add),
      "payloadChecksumFile": "MANIFEST.sha256",
      "verify": {
        "root": ".",
        "command": "sha256sum -c --strict MANIFEST.sha256"
      },
      "reproducibility": {
        "sourceDateEpoch": $epoch,
        "comparisonRule": "Two builds from the same sourceDateEpoch are byte-identical for every payload entry whose path matches no volatileSet glob. A difference OUTSIDE the volatile set fails the reproducibility gate; a difference inside it is expected. The governor must not forgive any difference it cannot match to a glob declared here.",
        "volatileSet": [
          {
            "glob": "images/signatures/*",
            "reason": "cosign-ecdsa-nonce",
            "detail": "Cosign signs with ECDSA, which draws a fresh random nonce per signature, so re-signing an identical payload cannot produce identical bytes. Measured: 60 of 1122 payload entries differ across two builds, all of them .sig or .bundle files under this prefix."
          },
          {
            "glob": "MANIFEST.sha256",
            "reason": "derived-from-volatile",
            "detail": "Checksums every payload entry including the signature files, so it differs whenever they do. Derived, not independently volatile."
          }
        ]
      },
      "images": $images[0],
      "imageCount": ($images[0] | length),
      "hostUtilities": {
        "decision": "Decision 10 reversed",
        "notShipped": ["envsubst", "openssl"],
        "runtimeRequired": null,
        "rationale": "Neither tool is shipped. openssl publishes source tarballs only, so it cannot be digest-pinned like the five downloaded binaries, and GNU gettext is the same. Containerising them was tried and abandoned: the image it required (controlplane/slsi-util:v0.1.0) was never published, has no Dockerfile in this tree, and resolves in no registry, so the wrappers execd an image that cannot exist. The appliance-side requirement was narrower than either tool: two Ed25519 keypairs and a key-id derivation, all in `make signing-keys`. Every appliance-side envsubst reference is the in-cluster envsubst that Flux itself provides, not the host tool.",
        "replacedBy": {
          "binary": "bin/<arch>/ed25519-keygen",
          "source": "d2-signalloom/apps/fleet-manager/cmd/ed25519-keygen",
          "digestKind": "computed-from-source",
          "interop": "Writes the same PKCS#8 PRIVATE KEY and SPKI PUBLIC KEY encodings openssl does, proven in both directions by test/ed25519-keygen-interop.bats."
        }
      },
      "stagedBinaries": $staged_binaries[0],
      "releaseKey": {
        "fingerprint": $key_fp,
        "path": "keys/release.pub"
      },
      "installer": {
        "path": $installer_path,
        "present": $installer_present,
        "status": "pending-p2-1",
        "ownedBy": "SLSI-P2-1",
        "governedBy": "proposal-slsi-v0.1.1",
        "sourcePath": $installer_path,
        "sourcePresent": $installer_source_present,
        "sourceStatus": $installer_source_status
      },
      "coverageExclusions": $coverage_exclusions[0]
    }' > "${stage_dir}/MANIFEST.json"

  chmod 0644 "${stage_dir}/MANIFEST.json"

  local violations
  violations="$(jq -n -r --slurpfile schema "${schema_file}" --slurpfile doc "${stage_dir}/MANIFEST.json" --arg ptr '#' -f "${schema_validator}")"
  if [[ -n "${violations}" ]]; then
    echo "CRITICAL: MANIFEST.json failed schema validation against ${schema_file}:" >&2
    echo "${violations}" >&2
    rm -rf "${stage_root}"
    fail "Gate 1 failed: MANIFEST.json schema violations"
  fi

  # Gate G-COVERAGE: Evaluate coverage across packaged manifests and declarations
  local invalid_excl
  invalid_excl="$(jq -r '.coverageExclusions[]? | select(.reason != "helm-chart-repository" and .reason != "local-never-pulled" and .reason != "dev-deferred-pin") | .ref' "${stage_dir}/MANIFEST.json")"
  if [[ -n "${invalid_excl}" ]]; then
    rm -rf "${stage_root}"
    fail "Gate G-COVERAGE failed: exclusion reason outside permitted set for ref: ${invalid_excl}"
  fi

  # An entry with no justification is an oversight wearing a reason word.
  local unjustified
  unjustified="$(jq -r '.coverageExclusions[]? | select(((.justification // "") | length) < 40) | .ref' "${stage_dir}/MANIFEST.json")"
  if [[ -n "${unjustified}" ]]; then
    rm -rf "${stage_root}"
    fail "Gate G-COVERAGE failed: exclusion carries no usable justification for ref: ${unjustified}"
  fi

  # A dev-deferred-pin entry is only tolerable while the tag it defers cannot
  # move. Refuse one whose tag is absent, declared mutable, floating, or simply
  # not the tag its own reference carries -- the last is how a deferral quietly
  # stops describing the thing it excuses.
  local bad_deferral
  bad_deferral="$(jq -r '
    .coverageExclusions[]?
    | select(.reason == "dev-deferred-pin")
    | . as $e
    | select(
        (($e.tag // "") | length) == 0
        or $e.mutableTag != false
        or $e.tag == "latest" or $e.tag == "*"
        or (($e.ref | endswith(":" + ($e.tag // ""))) | not)
      )
    | $e.ref' "${stage_dir}/MANIFEST.json")"
  if [[ -n "${bad_deferral}" ]]; then
    rm -rf "${stage_root}"
    fail "Gate G-COVERAGE failed: dev-deferred-pin entry must carry its own immutable tag (tag present, mutableTag false, not :latest, matching the ref): ${bad_deferral}"
  fi

  local domain_refs=()
  while IFS= read -r r; do
    [[ -n "$r" ]] && domain_refs+=("$r")
  done < <(grep -rohE 'image:[[:space:]]*["'"'"']?[^"'"'"']+' "${stage_dir}/fleet" "${stage_dir}/infra" 2>/dev/null | awk '{print $2}' | tr -d '"'"'" | LC_ALL=C sort -u)

  while IFS= read -r r; do
    [[ -n "$r" ]] && domain_refs+=("$r")
  done < <(grep -rohE 'artifact:[[:space:]]*["'"'"']?[^"'"'"']+' "${stage_dir}/images/flux" 2>/dev/null | awk '{print $2}' | tr -d '"'"'" | LC_ALL=C sort -u)

  while IFS= read -r reg; do
    if [[ -n "$reg" ]]; then
      domain_refs+=("${reg}/helm-controller" "${reg}/kustomize-controller" "${reg}/notification-controller" "${reg}/source-controller")
    fi
  done < <(grep -rohE 'registry:[[:space:]]*["'"'"']?[^"'"'"']+' "${stage_dir}/images/flux" 2>/dev/null | awk '{print $2}' | tr -d '"'"'" | LC_ALL=C sort -u)

  # The synthetic slsi-util ref used to be appended to the coverage domain
  # here, so G-COVERAGE counted an image that does not exist as covered. The
  # domain is now exactly the refs discovered in the staged tree.

  if [[ ${#domain_refs[@]} -eq 0 ]]; then
    rm -rf "${stage_root}"
    fail "Gate G-COVERAGE failed: domain is empty"
  fi

  local unpinned_container_images=()
  for d_ref in "${domain_refs[@]}"; do
    local is_excl
    is_excl="$(jq --arg r "$d_ref" '[.coverageExclusions[]? | select(.ref == $r)] | length' "${stage_dir}/MANIFEST.json")"
    if [[ "$is_excl" -gt 0 ]]; then
      continue
    fi

    local is_pinned
    is_pinned="$(jq --arg r "$d_ref" '[.images[]? | select((.ref == $r or .reference == $r or .resolvedRef == $r or (.ref | startswith($r))) and (.digest | test("^sha256:[0-9a-f]{64}$")))] | length' "${stage_dir}/MANIFEST.json")"
    if [[ "$is_pinned" -eq 0 ]]; then
      if [[ "$d_ref" =~ @sha256:[0-9a-f]{64}$ ]]; then
        continue
      fi
      unpinned_container_images+=("$d_ref")
    fi
  done

  if [[ ${#unpinned_container_images[@]} -gt 0 ]]; then
    log "Gate G-COVERAGE report: unpinned container images in domain: ${unpinned_container_images[*]} (REPORTED FAIL: attributable to P1-2 scope)"
  else
    log "Gate G-COVERAGE passed: all domain images are pinned or covered by valid exclusions"
  fi

  # 14. Assemble deterministic archive & sibling files in out_dir (house recipe)
  mkdir -p "${out_dir}"
  local tarball="${out_dir}/${archive_name}"
  (
    cd "${stage_dir}" && \
    LC_ALL=C tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner --format=gnu \
      -cf - * | gzip -n -9 > "${tarball}.tmp"
    mv -f "${tarball}.tmp" "${tarball}"
  )
  (cd "${out_dir}" && sha256sum "${archive_name}" > "${archive_name}.sha256")
  cp "${stage_dir}/MANIFEST.json" "${out_dir}/MANIFEST.json"
  chmod 0644 "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256" "${out_dir}/MANIFEST.json"

  # 15. Dual-aspect self-verification
  local self_test_dir
  self_test_dir="$(mktemp -d -t slsi-selftest.XXXXXX)"
  tar -xzf "${out_dir}/${archive_name}" -C "${self_test_dir}"
  (
    cd "${self_test_dir}" && \
    jq -r '.payload[] | "\(.sha256) \(.path)"' MANIFEST.json | sha256sum -c --strict - >/dev/null 2>&1
  ) || { rm -rf "${self_test_dir}" "${stage_root}"; fail "Seal correctness assertion failed"; }

  local self_on_disk self_declared
  self_on_disk="$(find "${self_test_dir}" -type f ! -name MANIFEST.json | sed "s|^${self_test_dir}/||" | LC_ALL=C sort)"
  self_declared="$(jq -r '.payload[].path' "${self_test_dir}/MANIFEST.json" | LC_ALL=C sort)"
  diff <(printf '%s\n' "$self_on_disk") <(printf '%s\n' "$self_declared") >/dev/null 2>&1 || {
    rm -rf "${self_test_dir}" "${stage_root}"
    fail "Seal completeness assertion failed"
  }
  rm -rf "${self_test_dir}" "${stage_root}"

  log "stage_p1_3_manifest complete: assembled ${out_dir}/${archive_name} and ${out_dir}/MANIFEST.json"
}
# <<< SLSI-P1-3 >>>

# >>> SLSI-P1-4: packaging validation and dry-run verification <<<
# Stage P1-4: Packaging verification hooks, archive validation, and air-gap test integration.
# This region is owned by P1-4 and is READ-ONLY to other cards.
#
# stage_p1_4_validation gates the ARCHIVE's own structural invariants, so a
# defective archive fails the bundler rather than being discovered downstream.
# It re-reads whatever P1-3 left in ${SLSI_BUNDLE_OUT:-dist}/ and never rebuilds,
# so `--verify-only` (P1-1's existing flag) doubles as the dry-run mode: the
# same gates run against an already-built archive.
#
# What lives HERE versus in test/slsi-airgap-bundle.bats: everything that needs
# only the archive bytes and the host's tar/sha256sum. Anything that needs an
# isolation primitive, a sandbox image, strace or a mutation belongs to the
# suite, because a build must not depend on Docker being present.
#
# Gates (each fails loudly and names itself):
#   P14-G1  archive exists, is non-empty, and starts with the gzip magic 1f8b
#   P14-G2  the sibling <archive>.sha256 exists and verifies
#   P14-G3  the archive name, MANIFEST.json bundle.name and bundle.version all
#           carry the version this run validated
#   P14-G4  member hygiene: the stream decompresses end to end, no absolute
#           path, no `..` component, no symlink/hardlink/device member, and the
#           top level is exactly the declared set (P1-3 ships a root-level layout)
#   P14-G5  regular-file member count == MANIFEST.json payloadFileCount + 1
#           (the +1 is MANIFEST.json, which cannot list itself)
#   P14-G6  no <arch>/openssl or <arch>/envsubst wrapper is present (Decision
#           10 reversed), AND <arch>/ed25519-keygen is a regular file, mode
#           0755, with ELF magic bytes
#   P14-G7  dist/MANIFEST.json is byte-identical to the archive's MANIFEST.json

_P14_TOPLEVEL=$'MANIFEST.json\nMANIFEST.sha256\nbin\nfleet\nimages\ninfra\nkeys'

_p14_fail() {
  fail "stage_p1_4_validation: $1"
}

# Prints the tar verbose listing of $1. Exits non-zero if the stream does not
# decompress end to end, which is the gzip integrity check.
_p14_listing() {
  LC_ALL=C tar --numeric-owner -tvzf "$1"
}

stage_p1_4_validation() {
  if [[ "${CHECK_PINS:-0}" -eq 1 || "${SLSI_RESOLVE_ONLY:-0}" -eq 1 ]]; then
    log "stage_p1_4_validation: not applicable (--check-pins/--resolve-only build no archive)"
    return 0
  fi

  local version="${SLSI_VERSION:-${BUNDLE_VERSION:-0.1.0}}"
  version="${version#v}"
  local out_dir="${SLSI_BUNDLE_OUT:-${REPO_ROOT}/dist}"
  local bundle_name="slsi-appliance-${version}"
  local archive="${out_dir}/${bundle_name}.tar.gz"
  local dist_manifest="${out_dir}/MANIFEST.json"

  log "Executing stage_p1_4_validation against ${archive}"

  # P14-G1
  [[ -f "${archive}" ]] || _p14_fail "P14-G1 archive absent: ${archive}"
  [[ -s "${archive}" ]] || _p14_fail "P14-G1 archive is empty: ${archive}"
  local magic
  magic="$(head -c 2 "${archive}" | od -An -tx1 | tr -d ' \n')"
  [[ "${magic}" == "1f8b" ]] || _p14_fail "P14-G1 not a gzip stream (magic '${magic}', want 1f8b): ${archive}"

  # P14-G2
  [[ -f "${archive}.sha256" ]] || _p14_fail "P14-G2 sibling checksum absent: ${archive}.sha256"
  (cd "${out_dir}" && sha256sum -c --strict "${bundle_name}.tar.gz.sha256" >/dev/null 2>&1) \
    || _p14_fail "P14-G2 ${bundle_name}.tar.gz does not match its .sha256"

  # P14-G3 (MANIFEST.json sorts first under C collation, so --occurrence stops early)
  [[ -f "${dist_manifest}" ]] || _p14_fail "P14-G3 ${dist_manifest} absent"
  local archived_manifest
  archived_manifest="$(mktemp -t slsi-p14-manifest.XXXXXX)"
  if ! tar -xzOf "${archive}" --occurrence=1 MANIFEST.json > "${archived_manifest}" 2>/dev/null; then
    rm -f "${archived_manifest}"
    _p14_fail "P14-G3 archive carries no MANIFEST.json"
  fi
  local m_name m_version
  m_name="$(jq -r '.bundle.name // empty' "${archived_manifest}")"
  m_version="$(jq -r '.bundle.version // empty' "${archived_manifest}")"
  if [[ "${m_name}" != "${bundle_name}" || "${m_version}" != "${version}" ]]; then
    rm -f "${archived_manifest}"
    _p14_fail "P14-G3 version mismatch: archive ${bundle_name}.tar.gz, MANIFEST bundle.name='${m_name}' bundle.version='${m_version}'"
  fi

  # P14-G7
  if ! cmp -s "${dist_manifest}" "${archived_manifest}"; then
    rm -f "${archived_manifest}"
    _p14_fail "P14-G7 ${dist_manifest} differs from the MANIFEST.json inside the archive"
  fi
  local payload_count
  payload_count="$(jq -r '.payloadFileCount // empty' "${archived_manifest}")"
  rm -f "${archived_manifest}"
  [[ "${payload_count}" =~ ^[0-9]+$ && "${payload_count}" -gt 0 ]] \
    || _p14_fail "P14-G5 MANIFEST.json payloadFileCount is not a positive integer: '${payload_count}'"

  # P14-G4: one full decompression pass, listing kept off argv in a temp file.
  local listing
  listing="$(mktemp -t slsi-p14-listing.XXXXXX)"
  if ! _p14_listing "${archive}" > "${listing}" 2>/dev/null; then
    rm -f "${listing}"
    _p14_fail "P14-G4 archive does not decompress end to end (truncated or corrupt gzip/tar stream)"
  fi
  local member_count
  member_count="$(wc -l < "${listing}" | tr -d ' ')"
  if [[ "${member_count}" -eq 0 ]]; then
    rm -f "${listing}"
    _p14_fail "P14-G4 archive lists zero members"
  fi

  # GNU tar -tv: field 1 is the mode string; the path starts at field 6. Paths
  # in this repo contain no spaces, which the next check enforces rather than
  # assumes, since a space would shift every field after it.
  local bad
  bad="$(awk 'NF != 6 && substr($1,1,1) != "l" && substr($1,1,1) != "h" {print}' "${listing}" | head -n 3)"
  [[ -z "${bad}" ]] || { rm -f "${listing}"; _p14_fail "P14-G4 unparseable member line(s) (whitespace in a path?): ${bad}"; }
  bad="$(awk '{t=substr($1,1,1)} t!="-" && t!="d" {print $0}' "${listing}" | head -n 3)"
  [[ -z "${bad}" ]] || { rm -f "${listing}"; _p14_fail "P14-G4 non-regular, non-directory member(s) (symlink/hardlink/device): ${bad}"; }
  bad="$(awk '{print $6}' "${listing}" | grep -E '^/|(^|/)\.\.(/|$)' | head -n 3 || true)"
  [[ -z "${bad}" ]] || { rm -f "${listing}"; _p14_fail "P14-G4 absolute or traversal member path(s): ${bad}"; }
  local toplevel
  toplevel="$(awk '{p=$6; sub(/^\.\//,"",p); sub(/\/.*/,"",p); if (p!="") print p}' "${listing}" | LC_ALL=C sort -u)"
  if [[ "${toplevel}" != "${_P14_TOPLEVEL}" ]]; then
    rm -f "${listing}"
    _p14_fail "P14-G4 top-level members differ from the declared set. got: $(printf '%s' "${toplevel}" | tr '\n' ' ') want: $(printf '%s' "${_P14_TOPLEVEL}" | tr '\n' ' ')"
  fi

  # P14-G5
  local regular_count
  regular_count="$(awk 'substr($1,1,1)=="-"' "${listing}" | wc -l | tr -d ' ')"
  if [[ "${regular_count}" -ne $((payload_count + 1)) ]]; then
    rm -f "${listing}"
    _p14_fail "P14-G5 archive has ${regular_count} regular files; MANIFEST.json payloadFileCount ${payload_count} + 1 = $((payload_count + 1))"
  fi

  # P14-G6, inverted. It used to REQUIRE bin/<arch>/openssl and
  # bin/<arch>/envsubst to be present, 0755, and shell scripts. Those were the
  # Decision 10 wrappers, which execd an image that does not exist. The gate is
  # inverted rather than deleted, because the reversal needs a gate too: an
  # archive that carries those wrappers again must fail the build.
  #
  # Both halves are asserted, because either alone is weak. Absence alone would
  # also be satisfied by an archive with no bin/ at all; presence of the
  # replacement alone would not notice a wrapper shipped alongside it. The arch
  # list is derived from the archive and asserted non-empty first, so the
  # absence half cannot pass by having nothing to look at.
  local arches arch util line mode magic
  arches="$(awk 'substr($1,1,1)=="-" {print $6}' "${listing}" | sed -nE 's#^(\./)?bin/(amd64|arm64)/[^/]+$#\2#p' | LC_ALL=C sort -u)"
  if [[ -z "${arches}" ]]; then
    rm -f "${listing}"
    _p14_fail "P14-G6 no bin/<arch>/ binaries in the archive"
  fi
  for arch in ${arches}; do
    # a. The Decision 10 wrappers must be gone.
    for util in openssl envsubst; do
      line="$(awk -v p="bin/${arch}/${util}" '{q=$6; sub(/^\.\//,"",q)} q==p {print; exit}' "${listing}")"
      if [[ -n "${line}" ]]; then
        rm -f "${listing}"
        _p14_fail "P14-G6 Decision 10 wrapper is back: bin/${arch}/${util} (${line}). Neither openssl nor envsubst is shipped; the image those wrappers ran does not exist."
      fi
    done

    # b. The replacement must be there, executable, and an actual ELF binary
    #    for the arch it claims -- not a script, and not a stub.
    line="$(awk -v p="bin/${arch}/ed25519-keygen" '{q=$6; sub(/^\.\//,"",q)} q==p {print; exit}' "${listing}")"
    [[ -n "${line}" ]] || { rm -f "${listing}"; _p14_fail "P14-G6 bin/${arch}/ed25519-keygen absent from the archive"; }
    mode="$(awk '{print $1}' <<<"${line}")"
    [[ "${mode}" == "-rwxr-xr-x" ]] || { rm -f "${listing}"; _p14_fail "P14-G6 bin/${arch}/ed25519-keygen mode is ${mode}, want -rwxr-xr-x (0755)"; }
    magic="$(tar -xzOf "${archive}" --occurrence=1 "bin/${arch}/ed25519-keygen" 2>/dev/null | od -An -tx1 -N4 | tr -d ' \n' || true)"
    [[ "${magic}" == "7f454c46" ]] || { rm -f "${listing}"; _p14_fail "P14-G6 bin/${arch}/ed25519-keygen does not have ELF magic bytes (got '${magic}')"; }
  done
  rm -f "${listing}"

  log "stage_p1_4_validation complete: ${member_count} members, ${regular_count} regular files (payload ${payload_count} + MANIFEST.json), ed25519-keygen present and no Decision 10 wrappers for: $(tr '\n' ' ' <<<"${arches}")"
}
# <<< SLSI-P1-4 >>>

# ── Stage Dispatcher ─────────────────────────────────────────────────────────
# run_stage returns 0 for any name it cannot resolve to a function, so a stage
# missing from this list is not an error -- it is a silent no-op that reads as a
# pass. stage_osd_1_first_party_images is therefore declared here AND called in
# main(), and test/slsi-bundle-osd.bats asserts the dispatcher's "running" line
# rather than trusting the stage's effect alone.
VALID_STAGES=("stage_p1_1_binaries" "stage_p1_2_images" "stage_osd_1_first_party_images" "stage_p1_3_manifest" "stage_p1_4_validation")

run_stage() {
  local stage_name="$1"
  shift

  local is_valid=0
  for valid in "${VALID_STAGES[@]}"; do
    if [[ "${stage_name}" == "${valid}" ]]; then
      is_valid=1
      break
    fi
  done

  if [[ ${is_valid} -ne 1 ]]; then
    fail "unknown stage '${stage_name}'"
  fi

  if declare -F "${stage_name}" >/dev/null; then
    log "stage ${stage_name}: running"
    "${stage_name}" "$@"
  else
    log "stage ${stage_name}: pending (not yet implemented)"
  fi
}

main() {
  parse_args "$@"
  validate_version_string "${SLSI_VERSION}"
  run_stage stage_p1_1_binaries
  run_stage stage_p1_2_images
  # After P1-2 (which owns images.json) and before P1-3 (which owns
  # MANIFEST.json): the first-party records must exist in images.json for P1-3's
  # gates to see them, and must not be written by P1-3 itself.
  run_stage stage_osd_1_first_party_images
  run_stage stage_p1_3_manifest
  run_stage stage_p1_4_validation
  log "All declared stages processed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
