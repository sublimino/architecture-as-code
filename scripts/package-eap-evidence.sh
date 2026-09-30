#!/usr/bin/env bash
# ==============================================================================
# SLDC-P5-2: package and sign the Kusari EAP forensic evidence bundle.
#
# Takes the evidence directory written by the five-step containment run
# (test/e2e-dual-cluster-containment.bats, ~/kusari-e2e/<timestamp>/), checks
# the seven raw Appendix F.2 artifacts against the bundle contract, and:
#
#   1. writes audit-signature.sha256 (artifact 8) into the evidence directory:
#      one `sha256sum` line per raw artifact;
#   2. writes bundle-header.json (signing timestamp, git commit, operator,
#      host kernel/runtime/arch, per-artifact digests, manifest digest) and an
#      Ed25519 detached signature over it, bundle-header.json.sig, plus the
#      signer's public key, signing-key.pub.pem;
#   3. packs all eleven files into a reproducible
#      kusari-eap-evidence-<UTC timestamp>.tar.gz (sorted names, fixed mtime,
#      uid/gid 0, files 0644, directory 0755, gzip -n) with a .sha256 beside it;
#   4. verifies its own tarball with scripts/verify-eap-evidence.sh and deletes
#      it if that fails.
#
# It refuses (exit 1, reason on stderr) to sign evidence that breaks the
# contract: a missing, empty or symlinked artifact; invalid JSON or a schema
# violation; 'frozen 0' or no 'frozen 1' in step5-cgroup-freeze.txt (the
# primary forensic proof); a non-zero restartCount; no 0 mCPU flatline; the
# legacy tenant 'kurasi'/'6f82ad81'; an existing audit-signature.sha256 that no
# longer matches the files (tampered evidence is never re-blessed); or a
# missing / unparseable / non-Ed25519 signing key.
#
# Signing is non-interactive: .keys/witness.pem is an unencrypted Ed25519 key
# (openssl pkeyutl). No gpg, no cosign password prompt.
#
# Injectable boundaries:
#   EAP_EVIDENCE_ROOT   where to find the latest run  (default: $HOME/kusari-e2e)
#   EAP_OUT_DIR         tarball destination           (default: <repo>/ci-evidence)
#   EAP_SIGNING_KEY     Ed25519 private key PEM       (default: <keys dir>/witness.pem)
#   EAP_REPO            git repo whose HEAD is recorded (default: this script's repo)
#   EAP_OPERATOR        signing operator identity     (default: git user.email, else $USER@host)
#   EAP_CONTAINER_RUNTIME  runtime version string     (default: probe docker, then containerd)
#   SOURCE_DATE_EPOCH   signing time; fixing it makes the tarball byte-reproducible
#
# Usage:
#   package-eap-evidence.sh [EVIDENCE_DIR] [--out DIR] [--quiet]
#
# Exit: 0 bundle written and self-verified; 1 contract violation or signing
# failure; 2 usage error.
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/eap-evidence.sh
. "$here/lib/eap-evidence.sh"
# shellcheck source=scripts/lib/keys.sh
. "$here/lib/keys.sh"

repo="${EAP_REPO:-$(cd "$here/.." && pwd)}"
schema="$here/../schemas/eap-evidence-bundle-schema.json"

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  printf 'package-eap-evidence: %s\n' "$*" >&2
  exit 1
}

evidence_dir=""
out_dir="${EAP_OUT_DIR:-$repo/ci-evidence}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out | --output-dir) [ "$#" -ge 2 ] || usage; out_dir="$2"; shift 2 ;;
    --quiet) export EAP_QUIET=1; shift ;;
    -h | --help) usage ;;
    -*) printf 'package-eap-evidence: unknown option %s\n' "$1" >&2; usage ;;
    *) [ -z "$evidence_dir" ] || usage; evidence_dir="$1"; shift ;;
  esac
done

# Resolve out_dir to absolute path before any cd
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

if [ -z "$evidence_dir" ]; then
  root="${EAP_EVIDENCE_ROOT:-$HOME/kusari-e2e}"
  if [ -d "$root" ]; then
    evidence_dir="$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort -V | tail -n 1)"
    [ -n "$evidence_dir" ] && evidence_dir="$root/$evidence_dir"
  fi
  if [ -z "$evidence_dir" ] || [ ! -d "$evidence_dir" ]; then
    if [ -d "$repo/test/fixtures/eap-evidence" ]; then
      evidence_dir="$repo/test/fixtures/eap-evidence"
    else
      die "no evidence directory given and neither $root nor fixtures exist"
    fi
  fi
fi
[ -d "$evidence_dir" ] || die "evidence directory $evidence_dir does not exist"
evidence_dir="$(cd "$evidence_dir" && pwd)"

# --- signing key (hard blocker if missing or corrupt) -------------------------
signing_key="${EAP_SIGNING_KEY:-$(keys_dir_abs "$repo")/witness.pem}"
[ -f "$signing_key" ] || die "signing key $signing_key is missing (run: make signing-keys)"
[ -r "$signing_key" ] || die "signing key $signing_key is not readable"
signing_key="$(cd "$(dirname "$signing_key")" && pwd)/$(basename "$signing_key")"
key_text="$(openssl pkey -in "$signing_key" -passin pass: -noout -text 2>/dev/null)" ||
  die "signing key $signing_key is corrupted, encrypted, or not a private key"
case "$key_text" in
  ED25519\ Private-Key*) ;;
  *) die "signing key $signing_key is not an Ed25519 private key" ;;
esac

# --- contract checks on the raw artifacts, before anything is written --------
printf 'evidence: %s\n' "$evidence_dir"
eap_content_checks "$evidence_dir" "$schema"
[ "$EAP_FAILS" -eq 0 ] || die "refusing to sign: $EAP_FAILS evidence contract violation(s) above"

cd "$evidence_dir"

# An existing manifest is a prior signature. If the files no longer match it,
# the evidence changed after signing: stop rather than bless the change.
if [ -e "$EAP_MANIFEST" ]; then
  if ! LC_ALL=C sha256sum --check --quiet --strict "$EAP_MANIFEST" >&2; then
    die "existing $EAP_MANIFEST does not match the evidence; refusing to re-sign tampered evidence"
  fi
fi

# --- artifact 8: the SHA-256 manifest ----------------------------------------
LC_ALL=C sha256sum "${EAP_RAW_ARTIFACTS[@]}" >"$EAP_MANIFEST.tmp"
mv -f "$EAP_MANIFEST.tmp" "$EAP_MANIFEST"
eap_manifest_format_check "$EAP_MANIFEST"
[ "$EAP_FAILS" -eq 0 ] || die "generated $EAP_MANIFEST is malformed"

# --- bundle header ------------------------------------------------------------
epoch="${SOURCE_DATE_EPOCH:-$(date -u +%s)}"
case "$epoch" in '' | *[!0-9]*) die "SOURCE_DATE_EPOCH must be an integer, got '$epoch'" ;; esac
signed_at="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
bundle_name="kusari-eap-evidence-$(date -u -d "@$epoch" +%Y%m%dT%H%M%SZ)"

commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || die "$repo is not a git repository; cannot record the commit"
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
dirty=false
[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ] || dirty=true

if [ -n "${EAP_OPERATOR:-}" ]; then
  operator="$EAP_OPERATOR" operator_source="EAP_OPERATOR"
elif operator="$(git -C "$repo" config user.email 2>/dev/null)" && [ -n "$operator" ]; then
  operator_source="git config user.email"
else
  operator="${USER:-$(id -un)}@$(hostname)" operator_source="user@hostname"
fi

if [ -n "${EAP_CONTAINER_RUNTIME:-}" ]; then
  runtime="$EAP_CONTAINER_RUNTIME"
elif v="$(timeout 5 docker version --format '{{.Server.Version}}' 2>/dev/null)" && [ -n "$v" ]; then
  runtime="docker $v"
elif v="$(timeout 5 containerd --version 2>/dev/null)" && [ -n "$v" ]; then
  runtime="$v"
else
  runtime="unavailable"
fi

pub_fp="$(openssl pkey -in "$signing_key" -pubout -outform DER | sha256sum | cut -d' ' -f1)"
origin="$(jq -r '.evidence_origin // "unknown"' preflight-manifest.json)"

for f in "${EAP_RAW_ARTIFACTS[@]}"; do
  jq -n -c --arg name "$f" --arg sha "$(sha256sum "$f" | cut -d' ' -f1)" \
    --argjson bytes "$(stat -c %s "$f")" '{name: $name, sha256: $sha, bytes: $bytes}'
done | jq -s \
  --arg bundle_name "$bundle_name" --arg signed_at "$signed_at" --argjson epoch "$epoch" \
  --arg origin "$origin" --arg commit "$commit" --arg branch "$branch" --argjson dirty "$dirty" \
  --arg operator "$operator" --arg operator_source "$operator_source" \
  --arg os "$(uname -s)" --arg kernel "$(uname -r)" --arg arch "$(uname -m)" --arg runtime "$runtime" \
  --arg manifest_sha "$(sha256sum "$EAP_MANIFEST" | cut -d' ' -f1)" --arg pub_fp "$pub_fp" \
  'if length != 7 then error("expected 7 artifact records, got \(length)") else . end
   | {
       schema: "sldc-eap-evidence-bundle/v1",
       bundle_name: $bundle_name,
       signed_at: $signed_at,
       source_date_epoch: $epoch,
       evidence_origin: $origin,
       git: {commit: $commit, branch: $branch, dirty: $dirty},
       operator: {identity: $operator, source: $operator_source},
       host: {os: $os, kernel_release: $kernel, architecture: $arch, container_runtime: $runtime},
       artifacts: .,
       manifest: {name: "audit-signature.sha256", sha256: $manifest_sha},
       signature: {algorithm: "ed25519", file: "bundle-header.json.sig", public_key_sha256: $pub_fp}
     }' >"$EAP_HEADER.tmp"
mv -f "$EAP_HEADER.tmp" "$EAP_HEADER"

errs="$(eap_validate_json "$schema" "$EAP_HEADER" '#')" || die "generated $EAP_HEADER violates the schema: $errs"

# --- detached Ed25519 signature over the header ------------------------------
openssl pkey -in "$signing_key" -pubout -out "$EAP_PUBKEY_FILE.tmp"
mv -f "$EAP_PUBKEY_FILE.tmp" "$EAP_PUBKEY_FILE"
openssl pkeyutl -sign -inkey "$signing_key" -rawin -in "$EAP_HEADER" -out "$EAP_HEADER_SIG.tmp" ||
  die "signing $EAP_HEADER with $signing_key failed"
[ -s "$EAP_HEADER_SIG.tmp" ] || die "signature over $EAP_HEADER is empty"
mv -f "$EAP_HEADER_SIG.tmp" "$EAP_HEADER_SIG"
eap_ok "signed $EAP_HEADER (ed25519, key sha256:$pub_fp)"

# --- reproducible tarball -----------------------------------------------------
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$bundle_name"
cp -- "${EAP_RAW_ARTIFACTS[@]}" "$EAP_MANIFEST" "$EAP_HEADER" "$EAP_HEADER_SIG" "$EAP_PUBKEY_FILE" "$stage/$bundle_name/"
find "$stage/$bundle_name" -type d -exec chmod 0755 {} +
find "$stage/$bundle_name" -type f -exec chmod 0644 {} +

tarball="$out_dir/$bundle_name.tar.gz"
LC_ALL=C tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner --format=gnu \
  -C "$stage" -cf - "$bundle_name" | gzip -n -9 >"$tarball.tmp"
mv -f "$tarball.tmp" "$tarball"
(cd "$out_dir" && sha256sum "$bundle_name.tar.gz" >"$bundle_name.tar.gz.sha256")

# --- self-verification --------------------------------------------------------
pub_tmp="$stage/trusted.pub.pem"
openssl pkey -in "$signing_key" -pubout -out "$pub_tmp"
if ! "$here/verify-eap-evidence.sh" --quiet --pubkey "$pub_tmp" "$tarball"; then
  rm -f "$tarball" "$tarball.sha256"
  die "self-verification of $tarball failed; bundle deleted"
fi

# Aliases only for a bundle that verified.
cp -f "$EAP_MANIFEST" "$out_dir/$EAP_MANIFEST"
cp -f "$tarball" "$out_dir/eap-kusari-containment.tar.gz"
(cd "$out_dir" && sha256sum "eap-kusari-containment.tar.gz" >"eap-kusari-containment.tar.gz.sha256")

[ "$origin" = live ] || eap_warn "evidence_origin is '$origin': this bundle is not proof of a live containment run"
printf 'manifest: %s\n' "$evidence_dir/$EAP_MANIFEST"
printf 'bundle: %s\n' "$tarball"
printf 'bundle sha256: %s\n' "$(cut -d' ' -f1 "$tarball.sha256")"
