# shellcheck shell=bash
# eap-evidence.sh: the SLDC Appendix F.2 forensic bundle contract, shared by
# scripts/package-eap-evidence.sh (which refuses to sign evidence that breaks
# it) and scripts/verify-eap-evidence.sh (which refuses to accept a bundle
# that breaks it). One definition, so the two can never disagree about what a
# valid bundle is.
#
# Spec: docs/eap/FORENSIC-BUNDLE-SPECIFICATION.md
# Schema: schemas/eap-evidence-bundle-schema.json

# The seven raw artifacts, in manifest order. The eighth artifact,
# audit-signature.sha256, is derived from these.
EAP_RAW_ARTIFACTS=(
  preflight-manifest.json
  step1-flux-reconcile.txt
  step2-registry-claim.json
  step3-provocation-act.log
  step4-ebpf-observation.json
  step5-cgroup-freeze.txt
  step5-cadvisor-metrics.prom
)
EAP_MANIFEST=audit-signature.sha256
# shellcheck disable=SC2034 # consumed by the scripts that source this file
EAP_HEADER=bundle-header.json
# shellcheck disable=SC2034
EAP_HEADER_SIG=bundle-header.json.sig
# shellcheck disable=SC2034
EAP_PUBKEY_FILE=signing-key.pub.pem

# JSON artifact -> $defs pointer in the schema ('$defs' is literal).
# shellcheck disable=SC2016
eap_schema_ptr() {
  case "$1" in
    preflight-manifest.json) printf '#/$defs/preflightManifest' ;;
    step2-registry-claim.json) printf '#/$defs/registryClaim' ;;
    step4-ebpf-observation.json) printf '#/$defs/ebpfObservation' ;;
    *) return 1 ;;
  esac
}

EAP_FAILS=0
eap_ok() { [ "${EAP_QUIET:-0}" = 1 ] || printf 'OK   %s\n' "$1"; }
eap_warn() { printf 'WARN %s\n' "$1" >&2; }
eap_fail() {
  printf 'FAIL %s\n' "$1" >&2
  EAP_FAILS=$((EAP_FAILS + 1))
}

# eap_validate_json SCHEMA FILE PTR: prints violations; returns 1 if any.
eap_validate_json() {
  local schema="$1" file="$2" ptr="$3" lib errs
  lib="$(dirname "${BASH_SOURCE[0]}")/json-schema-lite.jq"
  errs="$(jq -n -r --slurpfile schema "$schema" --slurpfile doc "$file" --arg ptr "$ptr" -f "$lib")" || return 1
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs"
    return 1
  fi
}

# eap_content_checks DIR SCHEMA: every check on the seven raw artifacts that
# does not depend on the manifest or signature. Adds to EAP_FAILS.
eap_content_checks() {
  local dir="$1" schema="$2" f missing=0 errs ptr

  for f in "${EAP_RAW_ARTIFACTS[@]}"; do
    if [ -L "$dir/$f" ]; then
      eap_fail "artifact $f is a symlink; evidence must be regular files"
      missing=1
    elif [ ! -f "$dir/$f" ]; then
      eap_fail "artifact $f is missing"
      missing=1
    elif [ ! -s "$dir/$f" ]; then
      eap_fail "artifact $f is empty (0 bytes)"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    return 0
  fi
  eap_ok "all ${#EAP_RAW_ARTIFACTS[@]} raw artifacts present and non-empty"

  for f in preflight-manifest.json step2-registry-claim.json step4-ebpf-observation.json; do
    if ! jq empty "$dir/$f" 2>/dev/null; then
      eap_fail "$f is not valid JSON"
      continue
    fi
    ptr="$(eap_schema_ptr "$f")"
    if errs="$(eap_validate_json "$schema" "$dir/$f" "$ptr")"; then
      eap_ok "$f conforms to schema ${ptr}"
    else
      eap_fail "$f violates schema ${ptr}: $(printf '%s' "$errs" | tr '\n' ';')"
    fi
  done

  # Primary forensic proof (hard blocker): the kernel must report the
  # container cgroup frozen. Any 'frozen 0' line voids the bundle, even if a
  # 'frozen 1' line is also present.
  if grep -Eq '^[[:space:]]*frozen[[:space:]]+0[[:space:]]*$' "$dir/step5-cgroup-freeze.txt"; then
    eap_fail "PRIMARY FORENSIC PROOF INVALID: step5-cgroup-freeze.txt reports 'frozen 0'"
  elif grep -Eq '^[[:space:]]*frozen[[:space:]]+1[[:space:]]*$' "$dir/step5-cgroup-freeze.txt"; then
    eap_ok "step5-cgroup-freeze.txt reports frozen 1"
  else
    eap_fail "PRIMARY FORENSIC PROOF INVALID: step5-cgroup-freeze.txt has no 'frozen 1' line"
  fi

  # Forensic preservation (Shared Pattern 3): every recorded restartCount is 0,
  # and step 5 records one.
  local counts
  counts="$(grep -Eho 'restartCount:[[:space:]]*[0-9]+' "$dir/step1-flux-reconcile.txt" "$dir/step5-cgroup-freeze.txt" | grep -Eo '[0-9]+$' || true)"
  if ! grep -Eq 'restartCount:[[:space:]]*[0-9]+' "$dir/step5-cgroup-freeze.txt"; then
    eap_fail "step5-cgroup-freeze.txt records no restartCount"
  elif printf '%s\n' "$counts" | grep -Eqv '^0$'; then
    eap_fail "restartCount is not 0 (found: $(printf '%s' "$counts" | tr '\n' ' '))"
  else
    eap_ok "restartCount is 0 in every text artifact that records it"
  fi

  # Shared Pattern 2 needs the cgroup of every normalised event; the sentinel
  # emits it top-level or under labels, which anyOf cannot express alongside
  # the target alternatives, so it is checked here.
  if jq -e '(if has("observations") then .observations else [.] end)
            | all(((.cgroup_path // .labels.cgroup_path // "") | type == "string" and length > 0))' \
    "$dir/step4-ebpf-observation.json" >/dev/null 2>&1; then
    eap_ok "every eBPF observation carries a cgroup_path"
  else
    eap_fail "step4-ebpf-observation.json has an observation without cgroup_path (or labels.cgroup_path)"
  fi

  # 0 mCPU flatline, proven either by the scrape itself (a
  # container_cpu_usage_seconds_total series with >= 2 samples, all equal) or
  # by step 5's two-scrape record 'cadvisor_cpu_seconds: A -> B' with A == B,
  # backed by a scrape that contains the metric.
  local txt_cpu
  txt_cpu="$(awk '
      /^[[:space:]]*cadvisor_cpu_seconds:/ {
        seen = 1
        if (!($3 == "->" && $2 == $4 && $2 ~ /^[0-9.eE+-]+$/)) moved = 1
      }
      END { print (!seen ? "absent" : (moved ? "moved" : "flat")) }' "$dir/step5-cgroup-freeze.txt")"
  if ! grep -Eq '^container_cpu_usage_seconds_total[{ ]' "$dir/step5-cadvisor-metrics.prom"; then
    eap_fail "step5-cadvisor-metrics.prom contains no container_cpu_usage_seconds_total sample"
  elif [ "$txt_cpu" = moved ]; then
    eap_fail "step5-cgroup-freeze.txt records a moving cAdvisor CPU counter (not 0 mCPU)"
  elif [ "$txt_cpu" = flat ]; then
    eap_ok "step5-cgroup-freeze.txt records an unchanged cAdvisor CPU counter (0 mCPU)"
  elif awk '
      /^container_cpu_usage_seconds_total[{ ]/ {
        series = $1; value = $2
        n[series]++
        if (!(series in first)) first[series] = value
        else if (value != first[series]) moved[series] = 1
      }
      END {
        for (s in n) if (n[s] >= 2 && !(s in moved)) exit 0
        exit 1
      }' "$dir/step5-cadvisor-metrics.prom"; then
    eap_ok "step5-cadvisor-metrics.prom shows a flat container_cpu_usage_seconds_total series (0 mCPU)"
  else
    eap_fail "0 mCPU not proven: no 'cadvisor_cpu_seconds: A -> A' in step5-cgroup-freeze.txt and no container_cpu_usage_seconds_total series with >=2 equal samples"
  fi

  # Canonical tenant vector (Shared Pattern 1): the legacy typo fails closed.
  if grep -Eiq 'kurasi|6f82ad81' "${EAP_RAW_ARTIFACTS[@]/#/$dir/}"; then
    eap_fail "legacy tenant 'kurasi' / '6f82ad81' found in evidence (Shared Pattern 1: fail closed)"
  else
    eap_ok "no legacy tenant vector (kurasi / 6f82ad81) in evidence"
  fi
}

# eap_manifest_format_check FILE: exactly one sha256sum text-mode line per raw
# artifact, in manifest order, each a 64-hex digest.
eap_manifest_format_check() {
  local manifest="$1" expected actual
  expected="$(printf '%s\n' "${EAP_RAW_ARTIFACTS[@]}")"
  if grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._-]+$' "$manifest"; then
    eap_fail "$EAP_MANIFEST has a line that is not '<64 hex>  <name>'"
    return 0
  fi
  actual="$(sed -E 's/^[0-9a-f]{64}  //' "$manifest")"
  if [ "$actual" != "$expected" ]; then
    eap_fail "$EAP_MANIFEST does not list exactly the seven raw artifacts in order (got: $(printf '%s' "$actual" | tr '\n' ' '))"
    return 0
  fi
  eap_ok "$EAP_MANIFEST lists 7 valid 64-hex SHA-256 digests"
}

# eap_pubkey_fingerprint PEM: sha256 of the DER SubjectPublicKeyInfo.
eap_pubkey_fingerprint() {
  # Parse first: a failed openssl piped into sha256sum would otherwise yield
  # the digest of the empty string, which looks like a real fingerprint.
  openssl pkey -pubin -in "$1" -noout 2>/dev/null || return 1
  openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1
}
