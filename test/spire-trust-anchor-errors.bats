#!/usr/bin/env bats

# Unit tests for spire-trust-anchor.sh error paths.
#
# These run locally with stubbed kubectl — no cluster needed. They verify that
# spire_jwt_svid_keys and sync_openbao_jwt_validation propagate errors with
# actionable messages instead of silently succeeding with empty output.
#
# The live membership tests are in test/spire-openbao-trust-drift.bats. This
# suite covers the code paths that only fire when something is broken.

setup_file() {
  export ANCHOR_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

setup() {
  root="$ANCHOR_ROOT"
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
}

# ── spire_jwt_svid_keys error paths ──────────────────────────────────────────

@test "spire_jwt_svid_keys fails with clear message when SPIRE is unreachable" {
  printf '#!/usr/bin/env bash\necho "error: unable to connect" >&2; exit 1\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPIRE server unreachable"* ]]
}

@test "spire_jwt_svid_keys fails when bundle has no JWT-SVID keys" {
  # kubectl succeeds but returns a bundle with only x509 keys (no jwt-svid)
  printf '#!/usr/bin/env bash\n' >"$stub/kubectl"
  cat >>"$stub/kubectl" <<'KUBECTL'
cat <<'JSON'
{"keys":[{"kty":"EC","crv":"P-256","x":"abc","y":"def","use":"x509-svid"}]}
JSON
KUBECTL
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"no P-256 JWT-SVID validation key"* ]]
}

@test "spire_jwt_svid_keys fails when bundle is not valid JSON" {
  printf '#!/usr/bin/env bash\necho "not json at all"\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
}

# ── sync_openbao_jwt_validation error paths ──────────────────────────────────

@test "sync_openbao_jwt_validation writes the namespace-local SPIRE JWKS URL" {
	cat >"$stub/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KUBECTL_LOG"
KUBECTL
	chmod +x "$stub/kubectl"

	run env PATH="$stub:$PATH" KUBECTL_LOG="$BATS_TEST_TMPDIR/kubectl.log" bash -c "
		source '$root/scripts/lib/spire-trust-anchor.sh'
		sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
	"
	[ "$status" -eq 0 ]
	grep -Fq 'bao write auth/jwt/config jwks_url=http://spire-oidc.inf-bao.svc.cluster.local:8008/keys' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "sync_openbao_jwt_validation does not read SPIRE static key material" {
	cat >"$stub/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
[[ "$*" == *spire-server* ]] && { echo "unexpected SPIRE read" >&2; exit 70; }
exit 0
KUBECTL
	chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
	[ "$status" -eq 0 ]
	[[ "$output" == *"live jwks_url="* ]]
}

@test "sync_openbao_jwt_validation does not depend on local PEM conversion" {
	cat >"$stub/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
exit 0
KUBECTL
  chmod +x "$stub/kubectl"

  # openssl stub that always fails
  printf '#!/usr/bin/env bash\necho "openssl error" >&2; exit 1\n' >"$stub/openssl"
  chmod +x "$stub/openssl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
	[ "$status" -eq 0 ]
	[[ "$output" == *"configured OpenBao"* ]]
}

@test "sync_openbao_jwt_validation fails when OpenBao write fails" {
  # The sole write fails, simulating OpenBao being unreachable.
  cat >"$stub/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
if [[ "$*" == *"openbao"* ]]; then
  echo "Error writing data to auth/jwt/config: connection refused" >&2
  exit 2
fi
exit 0
KUBECTL
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
  [ "$status" -ne 0 ]
	[[ "$output" == *"OpenBao refused jwks_url write"* ]]
}

# ── CronJob manifest validation ─────────────────────────────────────────────

@test "CronJob manifest exists with expected schedule and policy" {
  local manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"
  [ -f "$manifest" ]

  # Schedule: every 8 hours
  grep -q 'schedule:.*0 \*/8' "$manifest"

  # backoffLimit: 1
  grep -q 'backoffLimit: 1' "$manifest"

  # concurrencyPolicy: Forbid
  grep -q 'concurrencyPolicy: Forbid' "$manifest"
}

@test "CronJob sync script is syntactically valid bash" {
  local manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"

  # Extract the sync.sh content from the ConfigMap
  # The script is between 'sync.sh: |' and the next '---' separator
  local script
  script="$(sed -n '/^  sync\.sh: |$/,/^---$/{ /^  sync\.sh: |$/d; /^---$/d; s/^    //; p; }' "$manifest")"
  [ -n "$script" ]

  # bash -n checks syntax without executing
  echo "$script" | bash -n
}

@test "retired periodic sync CronJob is absent from the rendered controller slice" {
	local kustomization="$root/d2-signalloom/infra/inf-bao/controllers/base/kustomization.yaml"
	local rendered="$BATS_TEST_TMPDIR/controllers.yaml"
	kubectl kustomize "${kustomization%/*}" >"$rendered"
	run yq eval-all -N -r \
		'[select(.kind == "CronJob" and .metadata.name == "spire-openbao-sync")] | length' \
		"$rendered"
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

# ── No new vacuous mapfile patterns ──────────────────────────────────────────

@test "no test file uses the vacuous mapfile-or-return pattern" {
  # The pattern `mapfile -t arr < <(cmd) || return 1` is vacuous: mapfile
  # always returns 0 regardless of cmd's exit status, so `|| return 1` is
  # dead code. Plain `mapfile < <(cmd)` without the error guard is fine in
  # tests where the caller checks the array contents directly.
  #
  # COMMENT LINES ARE EXCLUDED, and that is load-bearing rather than tidy.
  # Until 2026-08-30 this grep matched any occurrence of the literal, which
  # included the four lines of prose directly above it and one more in
  # spire-openbao-trust-drift.bats. The guard therefore reported two hits on a
  # clean tree and had been failing on every branch since it was written — so
  # it could never have caught a real occurrence, because it was already red.
  # A permanently-red guard is worse than no guard: it teaches the reader to
  # skip it, and it cannot distinguish "someone reintroduced the pattern" from
  # its own noise. Same shape as the `-registrationUDSPath` guard in this
  # branch that matched the comment explaining why the flag was absent.
  #
  # Matches are collected into a variable and tested with `[ -z ]` rather than
  # counted: a count tells you the guard fired but not what tripped it, and
  # the whole failure mode here was not knowing that the hits were its own
  # prose. The offenders are printed so the next reader sees them immediately.
  local offenders
  offenders="$(grep -rn 'mapfile.*< <(.*) *|| *return' "$root/test/" --include='*.bats' 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  [ -z "$offenders" ] || {
    echo "vacuous 'mapfile ... || return' found in non-comment code:"
    echo "$offenders"
    return 1
  }
}
