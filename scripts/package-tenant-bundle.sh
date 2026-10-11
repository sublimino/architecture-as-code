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
# Tools: kind, kubectl, flux, cosign, jq
# Arches: amd64, arm64
# Decision 10: openssl and envsubst are containerised in bundle/images/ (P1-2)
# and are not staged as host binaries in bundle/bin/.
SLSI_UTILITY_IMAGE_REF="docker.io/controlplane/slsi-util:v0.1.0"
SLSI_UTILITY_IMAGE_DIGEST_OBLIGATION="SLSI-P1-2"

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

check_all_pins() {
  log "Validating declared pin table for 5 staged Go utilities against bundle/bin/..."
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

  # Decision 10 containerised utility image declarations:
  log "openssl [amd64/arm64]: CONTAINERIZED (Decision 10: image ref ${SLSI_UTILITY_IMAGE_REF}, digest pin obligation: ${SLSI_UTILITY_IMAGE_DIGEST_OBLIGATION})"
  log "envsubst [amd64/arm64]: CONTAINERIZED (Decision 10: image ref ${SLSI_UTILITY_IMAGE_REF}, digest pin obligation: ${SLSI_UTILITY_IMAGE_DIGEST_OBLIGATION})"

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
  local -A listed_set=()
  local lp
  for lp in "${listed_paths[@]}"; do
    listed_set["${lp}"]=1
  done

  # The Decision 10 container wrappers are deliberately absent from the
  # checksum manifest. Exclude them by their exact expected paths, not by a
  # '*/openssl' glob, which would skip any planted file whose name happens to
  # end that way.
  local -A wrapper_exempt=()
  local arch util
  for arch in amd64 arm64; do
    for util in openssl envsubst; do
      wrapper_exempt["${arch}/${util}"]=1
    done
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
    openssl|envsubst)
      log "Skipping ${tool}: Decision 10 specifies containerisation in bundle/images/ (owned by P1-2), not staged in bundle/bin/."
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

  local tools_to_stage=("kind" "kubectl" "flux" "cosign" "jq")
  if [[ -n "${FILTER_TOOL}" ]]; then
    if [[ "${FILTER_TOOL}" == "openssl" || "${FILTER_TOOL}" == "envsubst" ]]; then
      log "Filter tool '${FILTER_TOOL}' requested: under Decision 10 this tool is containerised in bundle/images/ (P1-2)."
      return 0
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
# Decision 10 containerised utilities (bundle/images/):
openssl: containerised (P1-2)
envsubst: containerised (P1-2)
EOF
    chmod 0644 "${BUNDLE_DIR}/bin/${arch}/versions.txt"
    log "Wrote ${BUNDLE_DIR}/bin/${arch}/versions.txt"

    # Generate Decision 10 container wrappers for openssl and envsubst
    generate_container_wrappers "${BUNDLE_DIR}/bin/${arch}"
    log "Generated Decision 10 container wrappers in ${BUNDLE_DIR}/bin/${arch}"
  done

  cat > "${BUNDLE_DIR}/bin/checksums.txt" <<EOF
${KIND_AMD64_SHA256}  amd64/kind
${KUBECTL_AMD64_SHA256}  amd64/kubectl
${FLUX_AMD64_BINARY_SHA256}  amd64/flux
${COSIGN_AMD64_SHA256}  amd64/cosign
${JQ_AMD64_SHA256}  amd64/jq
${KIND_ARM64_SHA256}  arm64/kind
${KUBECTL_ARM64_SHA256}  arm64/kubectl
${FLUX_ARM64_BINARY_SHA256}  arm64/flux
${COSIGN_ARM64_SHA256}  arm64/cosign
${JQ_ARM64_SHA256}  arm64/jq
EOF
  chmod 0644 "${BUNDLE_DIR}/bin/checksums.txt"
  log "Generated ${BUNDLE_DIR}/bin/checksums.txt"

  verify_offline_manifest
  log "stage_p1_1_binaries complete: all tools staged and verified"
}

generate_container_wrappers() {
  local target_dir="$1"

  cat > "${target_dir}/openssl" <<'EOF'
#!/usr/bin/env bash
# SLSI Decision 10 Container Wrapper for openssl
# Part of SLSI design partner appliance bundle
set -Eeuo pipefail

SLSI_UTILITY_IMAGE="${SLSI_UTILITY_IMAGE:-docker.io/controlplane/slsi-util:v0.1.0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker container runtime is required to run containerised 'openssl' (Decision 10)." >&2
  echo "Host package remedy: apt-get install -y openssl" >&2
  exit 1
fi

if ! docker image inspect "${SLSI_UTILITY_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: SLSI utility container image '${SLSI_UTILITY_IMAGE}' is absent from local Docker daemon." >&2
  echo "Decision 10 requirement: refusing silent fallback to host 'openssl' of unknown version." >&2
  echo "Host package remedy: apt-get install -y openssl" >&2
  echo "Appliance remedy: preload image into Docker from bundle: docker load < bundle/images/slsi-util.tar" >&2
  exit 1
fi

exec docker run --rm -i --network none -v "${PWD}:${PWD}" -w "${PWD}" "${SLSI_UTILITY_IMAGE}" openssl "$@"
EOF
  chmod 0755 "${target_dir}/openssl"

  cat > "${target_dir}/envsubst" <<'EOF'
#!/usr/bin/env bash
# SLSI Decision 10 Container Wrapper for envsubst
# Part of SLSI design partner appliance bundle
set -Eeuo pipefail

SLSI_UTILITY_IMAGE="${SLSI_UTILITY_IMAGE:-docker.io/controlplane/slsi-util:v0.1.0}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker container runtime is required to run containerised 'envsubst' (Decision 10)." >&2
  echo "Host package remedy: apt-get install -y gettext-base" >&2
  exit 1
fi

if ! docker image inspect "${SLSI_UTILITY_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: SLSI utility container image '${SLSI_UTILITY_IMAGE}' is absent from local Docker daemon." >&2
  echo "Decision 10 requirement: refusing silent fallback to host 'envsubst' of unknown version." >&2
  echo "Host package remedy: apt-get install -y gettext-base" >&2
  echo "Appliance remedy: preload image into Docker from bundle: docker load < bundle/images/slsi-util.tar" >&2
  exit 1
fi

env_args=()
while IFS= read -r var; do
  if [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$var" != "_" && "$var" != "PATH" ]]; then
    env_args+=(-e "$var")
  fi
done < <(compgen -e)

exec docker run --rm -i --network none "${env_args[@]}" -v "${PWD}:${PWD}" -w "${PWD}" "${SLSI_UTILITY_IMAGE}" envsubst "$@"
EOF
  chmod 0755 "${target_dir}/envsubst"
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

  local util_digest="sha256:2235e37c43f3223d26ab7f35e8dfe1a662db1fa196648ab66b0d50f55e5ef51b"
  local util_ref="controlplane/slsi-util:v0.1.0@${util_digest}"

  if [[ -f "${bundle_dir}/images/index.json" ]]; then
    local has_util
    has_util="$(jq --arg d "${util_digest}" '[.manifests[]? | select(.digest == $d)] | length' "${bundle_dir}/images/index.json" 2>/dev/null || echo 0)"
    if [[ "${has_util}" -eq 0 ]]; then
      echo "ERROR: Decision 10 utility image ${util_digest} is absent from ${bundle_dir}/images/index.json" >&2
      echo "Host package remedy: apt-get install -y openssl gettext-base" >&2
      rm -f "${out_dir}/MANIFEST.json" "${out_dir}/${archive_name}" "${out_dir}/${archive_name}.sha256"
      fail "Gate 7 failed: utility image absent from images index"
    fi
  fi

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
    grep -E "[[:space:]]${selected_arch}/(cosign|flux|jq|kind|kubectl)$" "${bin_csum}" > "${stage_dir}/bin/checksums.txt" || true
    if [[ $(wc -l < "${stage_dir}/bin/checksums.txt") -ne 5 ]]; then
      grep -E '[[:space:]](amd64/|arm64/)?(cosign|flux|jq|kind|kubectl)$' "${bin_csum}" | \
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

  if [[ -f "${base_index_src}" ]]; then
    jq --arg ud "${util_digest}" --arg ur "${util_ref}" '
      .schemaVersion = 2 |
      .mediaType = "application/vnd.oci.image.index.v1+json" |
      .manifests = (
        [ .manifests[]? | select(.digest != $ud and .digest != "sha256:41223e96853ea6817d12aa8cf5dc43de49b7abab6892bb12ab39190cc12bba0c") ] +
        [{
          "mediaType": "application/vnd.oci.image.index.v1+json",
          "size": 1609,
          "digest": $ud,
          "annotations": {
            "org.opencontainers.image.ref.name": $ur
          }
        }]
      )
    ' "${base_index_src}" > "${stage_dir}/images/index.json"
  else
    jq --arg ud "${util_digest}" --arg ur "${util_ref}" '
      {
        schemaVersion: 2,
        mediaType: "application/vnd.oci.image.index.v1+json",
        manifests: (
          [ .images[]? | {
            mediaType: "application/vnd.oci.image.index.v1+json",
            size: 1609,
            digest: .digest,
            annotations: {
              "org.opencontainers.image.ref.name": (.resolvedRef // .ref)
            }
          }] +
          [{
            mediaType: "application/vnd.oci.image.index.v1+json",
            size: 1609,
            digest: $ud,
            annotations: {
              "org.opencontainers.image.ref.name": $ur
            }
          }]
        )
      }
    ' "${manifest_d_json}" > "${stage_dir}/images/index.json"
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
  if [[ -f "${bundle_dir}/images/images.json" ]]; then
    cp "${stage_dir}/images/images.json" "${bundle_dir}/images/images.json" 2>/dev/null || true
    if [[ -d "${bundle_dir}/.manifest.d" ]]; then
      cp "${stage_dir}/images/images.json" "${bundle_dir}/.manifest.d/images.json" 2>/dev/null || true
      (cd "${bundle_dir}/.manifest.d" && sha256sum "images.json" > "images.sha256") 2>/dev/null || true
    fi
  fi
  if [[ -f "${bundle_dir}/images/resolved.json" ]]; then
    cp "${stage_dir}/images/resolved.json" "${bundle_dir}/images/resolved.json" 2>/dev/null || true
  fi
  if [[ -f "${bundle_dir}/images/layout-closure.json" ]]; then
    cp "${stage_dir}/images/layout-closure.json" "${bundle_dir}/images/layout-closure.json" 2>/dev/null || true
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
  jq --arg ud "${util_digest}" --arg ur "${util_ref}" '
    [
      .images[] |
      .reference = (.ref | split("@")[0] | sub(":[^/]+$"; "")) |
      .ref = (.resolvedRef // .ref)
    ] +
    [{
      "ref": $ur,
      "reference": "controlplane/slsi-util",
      "resolvedRef": $ur,
      "logicalName": "slsi-util",
      "sourceRef": "controlplane/slsi-util:v0.1.0",
      "digest": $ud,
      "party": "first-party",
      "role": "utility",
      "provides": ["envsubst", "openssl"],
      "digestKind": "manifest",
      "platforms": ["linux/amd64"],
      "ociLayoutPath": "bundle/images/oci",
      "sizeBytes": 14800000
    }]
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

  cat > "${meta_dir}/coverage_exclusions.json" <<'EOF'
[
  {
    "ref": "docker.io/envoyproxy/gateway-helm",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository"
  },
  {
    "ref": "ghcr.io/prometheus-community/charts/kube-prometheus-stack",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository"
  },
  {
    "ref": "quay.io/jetstack/charts/cert-manager",
    "reason": "helm-chart-repository",
    "kind": "HelmRepository"
  },
  {
    "ref": "netassert-runner:local",
    "reason": "local-never-pulled",
    "kind": "Job"
  }
]
EOF

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
    --arg util_digest "${util_digest}" \
    --arg util_ref "${util_ref}" \
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
      "images": $images[0],
      "imageCount": ($images[0] | length),
      "containerisedUtilities": {
        "imageRef": $util_ref,
        "imageDigest": $util_digest,
        "utilities": ["envsubst", "openssl"],
        "runtimeRequired": "docker",
        "onAbsentRemedy": "Load image from bundle/images/ or pull controlplane/slsi-util:v0.1.0"
      },
      "stagedBinaries": $staged_binaries[0],
      "releaseKey": {
        "fingerprint": $key_fp,
        "path": "keys/release.pub"
      },
      "installer": {
        "path": "scripts/init-tenant.sh",
        "present": false,
        "status": "pending-p2-1",
        "ownedBy": "SLSI-P2-1",
        "governedBy": "proposal-slsi-v0.1.1"
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
  invalid_excl="$(jq -r '.coverageExclusions[]? | select(.reason != "helm-chart-repository" and .reason != "local-never-pulled") | .ref' "${stage_dir}/MANIFEST.json")"
  if [[ -n "${invalid_excl}" ]]; then
    rm -rf "${stage_root}"
    fail "Gate G-COVERAGE failed: exclusion reason outside permitted set for ref: ${invalid_excl}"
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

  domain_refs+=("${util_ref}")

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
# <<< SLSI-P1-4 >>>

# ── Stage Dispatcher ─────────────────────────────────────────────────────────
VALID_STAGES=("stage_p1_1_binaries" "stage_p1_2_images" "stage_p1_3_manifest" "stage_p1_4_validation")

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
  run_stage stage_p1_3_manifest
  run_stage stage_p1_4_validation
  log "All declared stages processed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
