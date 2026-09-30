#!/usr/bin/env bash
# ==============================================================================
# SLDC-P5-2: independently verify a Kusari EAP forensic evidence bundle.
#
# Accepts the tarball written by scripts/package-eap-evidence.sh or a signed
# evidence directory. Needs only bash, coreutils (sha256sum), GNU tar, gzip,
# jq and openssl, so a customer auditor can run it without this repository's
# toolchain; the same checks can be done by hand as described in
# docs/eap/FORENSIC-BUNDLE-SPECIFICATION.md.
#
# Checks (every one is reported as OK/FAIL; any FAIL makes the verdict FAIL):
#   archive   tarball only: sibling .sha256 matches; entries are one top-level
#             directory of regular files, no absolute or '..' paths, files 0644,
#             directory 0755, nothing beyond the eleven bundle files
#   content   the seven raw artifacts: present, regular, non-empty; JSON parses
#             and conforms to schemas/eap-evidence-bundle-schema.json; 'frozen 1'
#             and no 'frozen 0'; restartCount 0; 0 mCPU flatline; no legacy tenant
#   manifest  audit-signature.sha256 lists exactly the seven artifacts with
#             64-hex digests, and `sha256sum -c` reports zero mismatches
#   header    bundle-header.json conforms to the schema and its manifest and
#             artifact digests/sizes match the files on disk
#   signature Ed25519 signature over bundle-header.json verifies against the
#             trusted public key, whose fingerprint equals the header's
#   origin    evidence_origin; 'fixture' is a warning, or a FAIL under --require-live
#
# Trusted public key, first found: --pubkey, $EAP_VERIFY_PUBKEY,
# <keys dir>/witness-pub.pem. If none exists the bundle's own
# signing-key.pub.pem is used and a warning names its fingerprint, which the
# auditor must compare with the one ControlPlane published.
#
# Usage:
#   verify-eap-evidence.sh BUNDLE.tar.gz|EVIDENCE_DIR [--pubkey PEM] [--require-live] [--quiet]
#
# Exit: 0 verified; 1 verification failed; 2 usage error.
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/eap-evidence.sh
. "$here/lib/eap-evidence.sh"
# shellcheck source=scripts/lib/keys.sh
. "$here/lib/keys.sh"

schema="${EAP_SCHEMA:-$here/../schemas/eap-evidence-bundle-schema.json}"

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

target="" pubkey="${EAP_VERIFY_PUBKEY:-}" require_live=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pubkey) [ "$#" -ge 2 ] || usage; pubkey="$2"; shift 2 ;;
    --require-live) require_live=1; shift ;;
    --quiet) export EAP_QUIET=1; shift ;;
    -h | --help) usage ;;
    -*) printf 'verify-eap-evidence: unknown option %s\n' "$1" >&2; usage ;;
    *) [ -z "$target" ] || usage; target="$1"; shift ;;
  esac
done
[ -n "$target" ] || usage

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bundle_files=("${EAP_RAW_ARTIFACTS[@]}" "$EAP_MANIFEST" "$EAP_HEADER" "$EAP_HEADER_SIG" "$EAP_PUBKEY_FILE")

# --- resolve the target to a directory ---------------------------------------
if [ -d "$target" ]; then
  dir="$(cd "$target" && pwd)"
  mode=directory
elif [ -f "$target" ]; then
  mode=tarball
  if [ -f "$target.sha256" ]; then
    want="$(cut -d' ' -f1 "$target.sha256")"
    have="$(sha256sum "$target" | cut -d' ' -f1)"
    if [ "$want" = "$have" ]; then
      eap_ok "bundle checksum matches $(basename "$target").sha256"
    else
      eap_fail "bundle checksum mismatch: $(basename "$target").sha256 says $want, tarball is $have"
    fi
  else
    eap_warn "no $(basename "$target").sha256 beside the tarball; bundle checksum not checked"
  fi

  if ! listing="$(LC_ALL=C tar -tvzf "$target" 2>&1)"; then
    eap_fail "cannot read $target as a gzip tar archive: $listing"
    printf 'VERDICT: FAIL (%d check(s) failed)\n' "$EAP_FAILS"
    exit 1
  fi
  names="$(LC_ALL=C tar -tzf "$target")"
  top="$(printf '%s\n' "$names" | head -n 1)"
  top="${top%%/*}"
  archive_ok=1
  if ! printf '%s' "$top" | grep -Eq '^kusari-eap-evidence-[0-9]{8}T[0-9]{6}Z$'; then
    eap_fail "archive top-level entry '$top' is not kusari-eap-evidence-<UTC timestamp>"
    archive_ok=0
  fi
  while IFS= read -r n; do
    case "$n" in
      /* | *..*) eap_fail "archive entry '$n' has an absolute or parent path"; archive_ok=0 ;;
      "$top" | "$top/") ;;
      "$top"/*)
        base="${n#"$top"/}"
        if ! printf '%s\n' "${bundle_files[@]}" | grep -Fxq -- "$base"; then
          eap_fail "archive entry '$n' is not part of the bundle contract"
          archive_ok=0
        fi
        ;;
      *) eap_fail "archive entry '$n' is outside $top/"; archive_ok=0 ;;
    esac
  done <<<"$names"
  # tar -tv mode column: files -rw-r--r--, the directory drwxr-xr-x, nothing else.
  bad_modes="$(printf '%s\n' "$listing" | awk '$1 != "-rw-r--r--" && $1 != "drwxr-xr-x" {print $1, $NF}')"
  if [ -n "$bad_modes" ]; then
    eap_fail "archive entries with non-standard type/permissions: $(printf '%s' "$bad_modes" | tr '\n' ';')"
    archive_ok=0
  fi
  [ "$archive_ok" -eq 0 ] || eap_ok "archive layout: one directory (0755) of bundle files (0644)"

  if [ "$archive_ok" -eq 1 ]; then
    LC_ALL=C tar -xzf "$target" -C "$work" --no-same-owner --no-same-permissions
    dir="$work/$top"
  else
    printf 'VERDICT: FAIL (%d check(s) failed)\n' "$EAP_FAILS"
    exit 1
  fi
else
  printf 'verify-eap-evidence: %s is neither a file nor a directory\n' "$target" >&2
  exit 2
fi

# --- content -------------------------------------------------------------------
eap_content_checks "$dir" "$schema"

# --- manifest ------------------------------------------------------------------
if [ ! -s "$dir/$EAP_MANIFEST" ] || [ -L "$dir/$EAP_MANIFEST" ]; then
  eap_fail "$EAP_MANIFEST is missing, empty, or a symlink"
else
  eap_manifest_format_check "$dir/$EAP_MANIFEST"
  if check_log="$(cd "$dir" && LC_ALL=C sha256sum --check --strict "$EAP_MANIFEST" 2>&1)"; then
    eap_ok "sha256sum -c $EAP_MANIFEST: $(printf '%s\n' "$check_log" | grep -c ': OK$') OK, 0 mismatches"
  else
    eap_fail "sha256sum -c $EAP_MANIFEST reported mismatches: $(printf '%s\n' "$check_log" | grep -v ': OK$' | tr '\n' ';')"
  fi
fi

# --- header --------------------------------------------------------------------
header="$dir/$EAP_HEADER"
header_ok=0
if [ ! -s "$header" ] || [ -L "$header" ] || ! jq empty "$header" 2>/dev/null; then
  eap_fail "$EAP_HEADER is missing, empty, a symlink, or not JSON"
elif ! errs="$(eap_validate_json "$schema" "$header" '#')"; then
  eap_fail "$EAP_HEADER violates the schema: $(printf '%s' "$errs" | tr '\n' ';')"
else
  header_ok=1
  mismatch=""
  if [ -f "$dir/$EAP_MANIFEST" ] &&
    [ "$(jq -r '.manifest.sha256' "$header")" != "$(sha256sum "$dir/$EAP_MANIFEST" | cut -d' ' -f1)" ]; then
    mismatch="$mismatch manifest-digest"
  fi
  for f in "${EAP_RAW_ARTIFACTS[@]}"; do
    [ -f "$dir/$f" ] || continue
    rec="$(jq -c --arg n "$f" '[.artifacts[] | select(.name == $n)]' "$header")"
    if [ "$(jq 'length' <<<"$rec")" != 1 ] ||
      [ "$(jq -r '.[0].sha256' <<<"$rec")" != "$(sha256sum "$dir/$f" | cut -d' ' -f1)" ] ||
      [ "$(jq -r '.[0].bytes' <<<"$rec")" != "$(stat -c %s "$dir/$f")" ]; then
      mismatch="$mismatch $f"
    fi
  done
  if [ -n "$mismatch" ]; then
    eap_fail "$EAP_HEADER does not match the files:$mismatch"
  else
    eap_ok "$EAP_HEADER matches the manifest and all seven artifacts (commit $(jq -r '.git.commit' "$header"), signed $(jq -r '.signed_at' "$header") by $(jq -r '.operator.identity' "$header"))"
  fi
fi

# --- signature -----------------------------------------------------------------
if [ -z "$pubkey" ]; then
  default_pub="$(keys_dir_abs "$(cd "$here/.." && pwd)")/witness-pub.pem"
  [ ! -f "$default_pub" ] || pubkey="$default_pub"
fi
embedded="$dir/$EAP_PUBKEY_FILE"
if [ -z "$pubkey" ]; then
  if [ -f "$embedded" ] && fp="$(eap_pubkey_fingerprint "$embedded")"; then
    eap_warn "no trusted public key; verifying against the bundle's own key sha256:$fp - compare it with the published ControlPlane fingerprint"
    pubkey="$embedded"
  fi
fi
if [ -z "$pubkey" ] || [ ! -f "$pubkey" ]; then
  eap_fail "no public key available to verify $EAP_HEADER_SIG"
elif ! trusted_fp="$(eap_pubkey_fingerprint "$pubkey")"; then
  eap_fail "public key $pubkey cannot be parsed"
elif [ ! -s "$dir/$EAP_HEADER_SIG" ] || [ ! -s "$header" ]; then
  eap_fail "$EAP_HEADER_SIG or $EAP_HEADER is missing"
else
  if [ "$header_ok" -eq 1 ] && [ "$(jq -r '.signature.public_key_sha256' "$header")" != "$trusted_fp" ]; then
    eap_fail "$EAP_HEADER names signing key sha256:$(jq -r '.signature.public_key_sha256' "$header"), trusted key is sha256:$trusted_fp"
  fi
  if [ -f "$embedded" ] && [ "$(eap_pubkey_fingerprint "$embedded" || true)" != "$trusted_fp" ]; then
    eap_fail "bundled $EAP_PUBKEY_FILE is not the trusted key sha256:$trusted_fp"
  fi
  if openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin -in "$header" -sigfile "$dir/$EAP_HEADER_SIG" >/dev/null 2>&1; then
    eap_ok "ed25519 signature over $EAP_HEADER verifies (key sha256:$trusted_fp)"
  else
    eap_fail "ed25519 signature over $EAP_HEADER does NOT verify against key sha256:$trusted_fp"
  fi
fi

# --- origin --------------------------------------------------------------------
origin="$(jq -r '.evidence_origin // "unknown"' "$dir/preflight-manifest.json" 2>/dev/null || echo unknown)"
if [ "$header_ok" -eq 1 ] && [ "$(jq -r '.evidence_origin' "$header")" != "$origin" ]; then
  eap_fail "evidence_origin disagrees: header '$(jq -r '.evidence_origin' "$header")', preflight-manifest.json '$origin'"
fi
if [ "$origin" = live ]; then
  eap_ok "evidence_origin: live"
elif [ "$require_live" -eq 1 ]; then
  eap_fail "evidence_origin is '$origin' and --require-live was given"
else
  eap_warn "evidence_origin is '$origin': not proof of a live containment run"
fi

if [ "$EAP_FAILS" -eq 0 ]; then
  printf 'VERDICT: PASS (%s %s)\n' "$mode" "$target"
  exit 0
fi
printf 'VERDICT: FAIL (%d check(s) failed)\n' "$EAP_FAILS"
exit 1
