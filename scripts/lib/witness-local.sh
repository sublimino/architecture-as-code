#!/usr/bin/env bash
# Hermetic local-only Witness invocation helpers.

witness_local_validate_environment() {
  if [ -n "${ARCHIVISTA_URL:-}" ]; then
    echo "Stale remote evidence configuration is forbidden for local evidence: ARCHIVISTA_URL" >&2
    return 1
  fi
  if [ -n "${AUDIT_ANCHOR_REQUIRE_LOG:-}" ]; then
    echo "Stale remote evidence configuration is forbidden for local evidence: AUDIT_ANCHOR_REQUIRE_LOG" >&2
    return 1
  fi
  if env | grep -Eq '^ARCHIVISTA_|^WITNESS_.*ARCHIVIST'; then
    echo "Archivista environment configuration is forbidden for local evidence" >&2
    return 1
  fi
}

witness_local_prepare() {
  local working_dir=$1
  witness_local_validate_environment || return
  mkdir -p "${working_dir}"
  cat > "${working_dir}/.witness.yaml" <<'YAML'
run:
  enable-archivista: false
  enable-archivist: false
verify:
  enable-archivista: false
  enable-archivist: false
YAML
}

witness_local_trust_bundle() {
  local keys_dir=$1
  local trust_dir=$2
  if [ ! -f "${keys_dir}/policy.pem" ]; then
    openssl genpkey -algorithm ed25519 -out "${keys_dir}/policy.pem"
    openssl pkey -in "${keys_dir}/policy.pem" -pubout -out "${keys_dir}/policy-pub.pem"
  fi
  mkdir -p "${trust_dir}"
  cp "${keys_dir}/witness-pub.pem" "${trust_dir}/witness-pub.pem"
  cp "${keys_dir}/policy-pub.pem" "${trust_dir}/policy-pub.pem"
  (
    cd "${trust_dir}" || exit
    sha256sum witness-pub.pem policy-pub.pem > public-key-fingerprints.sha256
  )
}

witness_local_run() {
  local working_dir=$1
  shift
  (
    cd "${working_dir}" || exit
    HOME="${WITNESS_LOCAL_HOME}" XDG_CONFIG_HOME="${WITNESS_LOCAL_HOME}/.config" \
      witness run --workingdir "${working_dir}" --attestations= "$@"
  )
}

witness_local_verify() {
  local working_dir=$1
  shift
  (
    cd "${working_dir}" || exit
    HOME="${WITNESS_LOCAL_HOME}" XDG_CONFIG_HOME="${WITNESS_LOCAL_HOME}/.config" \
      witness verify "$@"
  )
}

witness_local_expect_policy_rejection() {
  local diagnostic_file=$1
  local step=$2
  local classification=${3:-artifact}

  test -s "${diagnostic_file}" || {
    echo "Witness rejection diagnostic is missing: ${diagnostic_file}" >&2
    return 1
  }
  grep -Fq 'policy signature verified' "${diagnostic_file}"
  grep -Fq 'Verification failed' "${diagnostic_file}"
  grep -Fq "failed to verify artifacts for step ${step}: no passed collections present" \
    "${diagnostic_file}"
  grep -Fq 'failed to verify policy: policy verification failed' "${diagnostic_file}"
  if [ "${classification}" = wrong-signer ]; then
    grep -Fq "collection rejected: ${step}, Reason: no verifiers present to validate against collection verifiers" \
      "${diagnostic_file}"
  fi
  if grep -Eqi 'unknown (flag|command)|failed to (read|load|parse)|no such file|permission denied|^usage:' \
      "${diagnostic_file}"; then
    echo "unexpected Witness verification failure: ${diagnostic_file}" >&2
    return 1
  fi
}
