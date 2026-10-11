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
# <<< SLSI-P1-2 >>>

# >>> SLSI-P1-3: manifest compilation and bundle assembly <<<
# Stage P1-3: Manifest compilation, fleet overlay packaging, and root MANIFEST.json.
# This region is owned by P1-3 and is READ-ONLY to other cards.
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
