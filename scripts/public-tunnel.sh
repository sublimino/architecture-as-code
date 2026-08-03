#!/usr/bin/env bash
# public-tunnel.sh — Expose the SignalLoom dashboard publicly via an ngrok tunnel.
#
# Subcommands:
#   up      Start port-forward + ngrok, patch Dex for the public URL, print access info
#   down    Tear down tunnel, restore Dex config
#   status  Show tunnel status and URL
#   url     Print the public URL (for scripting; exits 1 if no tunnel)
#
# The tunnel bypasses the Envoy Gateway and port-forwards directly to the
# dashboard nginx (dashboard-signalloom:8080). nginx already proxies /dex/,
# /api/, /supercred-api/, /dashboard/ etc. to their in-cluster backends, so the
# full OIDC flow works without any Gateway SNI matching.
#
# Dex's issuer and redirect URIs are patched to match the ngrok URL. On teardown
# the original secret is restored from a backup taken at tunnel-up time.
#
# Security: a ngrok traffic policy auto-sets a cookie on first browser visit.
# Requests without the cookie get a gate page instead of the dashboard. This
# blocks scrapers and bots but lets anyone with a browser through — appropriate
# for a demo share link, not for production.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${SCRIPT_DIR}/lib/wait.sh"
# shellcheck source=scripts/lib/expose.sh
source "${SCRIPT_DIR}/lib/expose.sh"

# ── Configuration ────────────────────────────────────────────────────
TUNNEL_DIR="${REPO_ROOT}/.tunnel"
PF_PID_FILE="${TUNNEL_DIR}/pf.pid"
NGROK_PID_FILE="${TUNNEL_DIR}/ngrok.pid"
NGROK_URL_FILE="${TUNNEL_DIR}/ngrok-url"
NGROK_LOG_FILE="${TUNNEL_DIR}/ngrok.log"
PF_LOG_FILE="${TUNNEL_DIR}/port-forward.log"
PF_SUPERVISOR_PID_FILE="${TUNNEL_DIR}/pf-supervisor.pid"
COOKIE_TOKEN_FILE="${TUNNEL_DIR}/cookie-token"
DEX_BACKUP_FILE="${TUNNEL_DIR}/dex-backup.yaml"
API_ISSUER_BACKUP_FILE="${TUNNEL_DIR}/api-issuer-backup"
FLUX_SUSPENDED_FILE="${TUNNEL_DIR}/flux-suspended"
POLICY_FILE="${TUNNEL_DIR}/traffic-policy.yaml"
SNAP_POLICY_COPY="${REPO_ROOT}/tunnel-policy.yaml"

DEX_NAMESPACE="inf-signalloom"
DEX_SECRET_NAME="dex-local-auth"
DEX_DEPLOYMENT="dex"
API_NAMESPACE="fe-signalloom"
API_DEPLOYMENT="fe-signalloom"
DASHBOARD_NAMESPACE="fe-signalloom"
DASHBOARD_SERVICE="dashboard-signalloom"
DASHBOARD_PORT=8080
LOCAL_PORT="${PUBLIC_LOCAL_PORT:-19080}"
NGROK_API="http://127.0.0.1:4040/api/tunnels"

# Original values for Dex restore validation.
ORIGINAL_ISSUER="https://dashboard.osramp.acme.local:30754/dex"

# ── Helpers ──────────────────────────────────────────────────────────
find_ngrok() {
  if [[ -n "${NGROK_BIN:-}" ]] && [[ -x "$NGROK_BIN" ]]; then
    echo "$NGROK_BIN"; return
  fi
  for candidate in /snap/bin/ngrok "$HOME/bin/ngrok" /usr/local/bin/ngrok; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  if command -v ngrok >/dev/null 2>&1; then command -v ngrok; return; fi
  return 1
}

ensure_ngrok() {
  if find_ngrok >/dev/null 2>&1; then return 0; fi

  echo "==> ngrok not found — downloading standalone binary..."
  local dest="${HOME}/bin/ngrok"
  mkdir -p "$(dirname "$dest")"
  local url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"
  curl -fsSL "$url" | tar -xzf - -C "$(dirname "$dest")" ngrok
  chmod +x "$dest"
  echo "==> Installed ngrok to ${dest}"

  if [[ -n "${NGROK_AUTHTOKEN:-}" ]]; then
    "$dest" config add-authtoken "$NGROK_AUTHTOKEN"
  fi

  if ! "$dest" config check >/dev/null 2>&1; then
    echo "ERROR: ngrok authtoken not configured." >&2
    echo "       Set NGROK_AUTHTOKEN or run: ngrok config add-authtoken <token>" >&2
    return 1
  fi
}

pid_alive() {
  [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

# PID currently listening on a local port, via ss -- not a cmdline pattern.
# Pattern-matching processes from inside this script risks matching the shell
# that is running it.
pid_on_port() {
  # "No process on that port" is a normal answer, not an error. Without the
  # trailing `|| true` the unmatched grep returns 1, pipefail promotes it to
  # the whole pipeline, and `set -e` kills the caller mid-teardown -- which is
  # how a "successful" `down` left .tunnel and a live agent behind.
  #
  # head is deliberately last-but-one rather than piping into another grep:
  # closing the pipe early sends SIGPIPE upstream, which pipefail also turns
  # into a fatal 141.
  { (ss -ltnp 2>/dev/null || true) | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1; } || true
}

# A previous run's ngrok that outlived its teardown still owns port 4040 and
# the public URL. Starting a second agent then fails silently: the new process
# exits, and extract_ngrok_url reads the ORPHAN's API and returns a URL this
# script neither owns nor can tear down. Reap it first.
reap_orphan_ngrok() {
  local owner
  owner="$(pid_on_port 4040)"
  [[ -z "$owner" ]] && return 0
  # Ours already? Nothing to do.
  if [[ -f "$NGROK_PID_FILE" ]] && [[ "$owner" == "$(cat "$NGROK_PID_FILE")" ]]; then
    return 0
  fi
  echo "==> Found an orphaned ngrok on :4040 (PID ${owner}) from a previous run — stopping it"
  kill "$owner" 2>/dev/null || true
  local i=0
  while kill -0 "$owner" 2>/dev/null && ((i < 20)); do sleep 0.5; ((++i)); done
  kill -9 "$owner" 2>/dev/null || true
}

kill_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local pid
    pid="$(cat "$file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      # Wait briefly for clean shutdown.
      local i=0
      while kill -0 "$pid" 2>/dev/null && ((i < 10)); do
        sleep 0.5
        ((++i))
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  fi
}

# ── Traffic policy ───────────────────────────────────────────────────
generate_traffic_policy() {
  local token="$1"
  # Single rule: if the cookie is ABSENT, return a gate page that sets the
  # cookie and meta-refreshes. If the cookie IS present, no rule matches
  # and the request passes straight through to the upstream.
  #
  # The 302+Set-Cookie approach does NOT work with ngrok custom-responses
  # (tested 2026-08-02). Use 200+meta-refresh instead.
  cat > "$POLICY_FILE" <<EOF
on_http_request:
  - name: cookie-gate
    expressions:
      - "!(req.headers.exists(k, k == 'cookie') && req.headers['cookie'].exists(v, v.contains('_sl_gate=${token}')))"
    actions:
      - type: custom-response
        config:
          status_code: 200
          headers:
            content-type: "text/html; charset=utf-8"
            set-cookie: "_sl_gate=${token}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400"
          body: '<html><head><meta http-equiv="refresh" content="0"></head><body style="background:#0f172a;color:#94a3b8;font-family:system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><p>Authorizing\u2026</p></body></html>'
EOF
}

# ── Dex secret management ───────────────────────────────────────────
backup_dex_secret() {
  # Store only the config.yaml content, not the full k8s YAML. The full
  # object carries resourceVersion which goes stale the moment we patch,
  # making `kubectl apply` fail with a conflict on restore.
  kubectl get secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    -o jsonpath='{.data.config\.yaml}' | base64 -d > "$DEX_BACKUP_FILE"
  echo "    Dex config backed up to ${DEX_BACKUP_FILE}"
}

patch_dex_secret() {
  local ngrok_url="$1"
  local config
  config=$(kubectl get secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    -o jsonpath='{.data.config\.yaml}' | base64 -d)

  # Replace the issuer.
  config=$(echo "$config" | sed "s|issuer: ${ORIGINAL_ISSUER}|issuer: ${ngrok_url}/dex|")

  # Add the ngrok callback to redirectURIs, matching the anchor line's OWN
  # indentation.
  #
  # This previously hardcoded ten spaces while the list items use six, so the
  # appended line was not parsed as a member of redirectURIs at all. Everything
  # downstream looked healthy -- secret patched, Dex restarted, tunnel serving
  # HTTP 200 -- and the browser still died on the login redirect with Dex
  # logging: Unregistered redirect_uri ("https://<id>.ngrok.app/callback").
  # Deriving the indent from the matched line cannot drift out of step with it.
  config=$(printf '%s\n' "$config" | awk -v url="${ngrok_url}/callback" '
    { print }
    /- http:\/\/localhost:5173\/callback/ && !done {
      match($0, /^[[:space:]]*/)
      printf "%s- %s\n", substr($0, 1, RLENGTH), url
      done = 1
    }')

  # Assert the URI really landed as a list entry before we ship it to the
  # cluster. A silent mis-indent here is invisible until a human tries to log in.
  if ! printf '%s\n' "$config" | awk -v want="- ${ngrok_url}/callback" '
      /redirectURIs:/ { inlist = 1; match($0, /^[[:space:]]*/); indent = RLENGTH; next }
      inlist {
        match($0, /^[[:space:]]*/)
        if (RLENGTH <= indent) { inlist = 0; next }
        line = $0; sub(/^[[:space:]]+/, "", line)
        if (line == want) { found = 1 }
      }
      END { exit !found }'; then
    echo "ERROR: ngrok callback was not added as a redirectURIs entry." >&2
    echo "       Dex would reject the login with 'Unregistered redirect_uri'." >&2
    return 1
  fi

  # Reconstruct and apply. Preserves labels via --save-config.
  kubectl create secret generic "$DEX_SECRET_NAME" \
    -n "$DEX_NAMESPACE" \
    --from-literal="config.yaml=${config}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  # Re-apply the labels the Kustomization expects.
  kubectl label secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    app.kubernetes.io/name=dex \
    app.kubernetes.io/part-of=signalloom-demo \
    --overwrite

  echo "    Dex issuer patched to ${ngrok_url}/dex"
  kubectl rollout restart "deployment/${DEX_DEPLOYMENT}" -n "$DEX_NAMESPACE"
  sleep 2
  wait_rollout "$DEX_DEPLOYMENT" -n "$DEX_NAMESPACE" 120
  echo "    Dex restarted and ready"
}

# ── Flux reconciliation ──────────────────────────────────────────────
#
# THE reason the tunnel "worked and then stopped working".
#
# Both the Dex secret and the fe-signalloom deployment are owned by Flux
# Kustomizations reconciling on a 30-minute interval. Every patch this script
# makes is therefore live for AT MOST 30 minutes: Flux restores the in-git
# values, Dex goes back to issuing for dashboard.osramp.acme.local, and the
# public URL starts failing every login with "Unregistered redirect_uri".
#
# Nothing logs an error when this happens. ngrok is still up, the port-forward
# is still serving, `status` still says HEALTHY -- so it presents as an
# application bug in the browser, minutes to half an hour after a successful
# `make public`. Measured directly: the ngrok issuer patch was gone from the
# cluster while the tunnel was still reporting healthy.
#
# So the owning Kustomizations are suspended for the tunnel's lifetime. Only
# the ones WE suspended are resumed, because a Kustomization somebody else
# deliberately suspended must stay suspended.
FLUX_TARGETS=(
  "inf-signalloom/infra-configs"   # owns the Dex secret
  "fe-signalloom/apps"             # owns the fe-signalloom deployment
)

suspend_flux() {
  : > "$FLUX_SUSPENDED_FILE"
  local target ns name already
  for target in "${FLUX_TARGETS[@]}"; do
    ns="${target%%/*}"; name="${target##*/}"
    already="$(kubectl get kustomization "$name" -n "$ns" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
    if [[ "$already" == "true" ]]; then
      echo "    ${target} already suspended — leaving it alone"
      continue
    fi
    if kubectl patch kustomization "$name" -n "$ns" \
        --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1; then
      echo "$target" >> "$FLUX_SUSPENDED_FILE"
      echo "    suspended ${target}"
    else
      echo "    WARNING: could not suspend ${target}; Flux will revert the tunnel config" >&2
    fi
  done
}

resume_flux() {
  [[ -f "$FLUX_SUSPENDED_FILE" ]] || return 0
  local target ns name
  while read -r target; do
    [[ -z "$target" ]] && continue
    ns="${target%%/*}"; name="${target##*/}"
    if kubectl patch kustomization "$name" -n "$ns" \
        --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1; then
      echo "    resumed ${target}"
    else
      echo "    WARNING: could not resume ${target}" >&2
    fi
  done < "$FLUX_SUSPENDED_FILE"
  rm -f "$FLUX_SUSPENDED_FILE"
}

# ── API issuer ───────────────────────────────────────────────────────
#
# Patching Dex alone is not enough. The API validates the `iss` claim against
# API_JWT_ISSUER, so the moment Dex starts issuing under the ngrok host, every
# token the dashboard presents is rejected: you log in successfully and then
# watch an empty dashboard while every request 401s. That is a far more
# confusing failure than being unable to log in at all.
#
# API_JWKS_URL is left alone deliberately -- it points at the in-cluster Dex
# service and the signing keys do not change with the issuer.
patch_api_issuer() {
  local ngrok_url="$1" current
  current="$(kubectl get deploy "$API_DEPLOYMENT" -n "$API_NAMESPACE" \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='API_JWT_ISSUER')].value}" 2>/dev/null || true)"

  if [[ -n "$current" ]]; then
    printf '%s' "$current" > "$API_ISSUER_BACKUP_FILE"
  fi

  kubectl set env "deploy/${API_DEPLOYMENT}" -n "$API_NAMESPACE" \
    "API_JWT_ISSUER=${ngrok_url}/dex" >/dev/null
  echo "    API issuer patched to ${ngrok_url}/dex"
  wait_rollout "$API_DEPLOYMENT" -n "$API_NAMESPACE" 180
  echo "    API restarted and ready"
}

restore_api_issuer() {
  if [[ ! -f "$API_ISSUER_BACKUP_FILE" ]]; then
    echo "    No API issuer backup found — skipping restore"
    return 0
  fi
  kubectl set env "deploy/${API_DEPLOYMENT}" -n "$API_NAMESPACE" \
    "API_JWT_ISSUER=$(cat "$API_ISSUER_BACKUP_FILE")" >/dev/null
  echo "    API issuer restored"
  wait_rollout "$API_DEPLOYMENT" -n "$API_NAMESPACE" 180
}

restore_dex_secret() {
  if [[ ! -f "$DEX_BACKUP_FILE" ]]; then
    echo "    No Dex backup found — skipping restore"
    return 0
  fi
  local config
  config="$(cat "$DEX_BACKUP_FILE")"

  kubectl create secret generic "$DEX_SECRET_NAME" \
    -n "$DEX_NAMESPACE" \
    --from-literal="config.yaml=${config}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  kubectl label secret "$DEX_SECRET_NAME" -n "$DEX_NAMESPACE" \
    app.kubernetes.io/name=dex \
    app.kubernetes.io/part-of=signalloom-demo \
    --overwrite

  echo "    Dex config restored from backup"
  kubectl rollout restart "deployment/${DEX_DEPLOYMENT}" -n "$DEX_NAMESPACE"
  sleep 2
  wait_rollout "$DEX_DEPLOYMENT" -n "$DEX_NAMESPACE" 120
  echo "    Dex restarted and ready"
}

# ── ngrok URL extraction ─────────────────────────────────────────────
extract_ngrok_url() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    local url
    url=$(curl -fsS "$NGROK_API" 2>/dev/null \
      | jq -r '.tunnels[0].public_url // empty' 2>/dev/null) || true
    if [[ -n "$url" ]]; then
      echo "$url" > "$NGROK_URL_FILE"
      echo "$url"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Failed to extract ngrok URL within 30s" >&2
  echo "       Check ${NGROK_LOG_FILE} for errors" >&2
  return 1
}

# ── Port-forward ─────────────────────────────────────────────────────
#
# `kubectl port-forward` is not a durable tunnel. It dies on pod restarts, on
# idle timeouts, when the laptop sleeps, and whenever the apiserver drops the
# SPDY stream. When it died here, ngrok stayed up and kept accepting public
# traffic, so the URL still resolved and every request 502'd:
#
#   "failed to open private leg" ... "dial tcp [::1]:19080: connect: connection refused"
#
# The tunnel looked up (`ngrok: running`) and was completely broken. So the
# port-forward gets a supervisor that restarts it, and everything that reports
# tunnel health checks the port, not just the PID.

port_forward_healthy() {
  # The PID being alive proves nothing -- kubectl can survive with a dead
  # stream. The listening socket is the thing callers actually depend on.
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":${LOCAL_PORT} "
}

# One attempt. The supervisor loops on this.
spawn_port_forward() {
  kubectl port-forward -n "$DASHBOARD_NAMESPACE" \
    "svc/${DASHBOARD_SERVICE}" "${LOCAL_PORT}:${DASHBOARD_PORT}" &>>"$PF_LOG_FILE" &
  echo $! > "$PF_PID_FILE"
}

# Restarts the port-forward whenever the local port stops accepting.
supervise_port_forward() {
  # Record OUR pid, from inside. `setsid ... & echo $!` records the launcher,
  # which exits as soon as it has forked -- so teardown killed a pid that was
  # already dead and left this loop running. It then resurrected the
  # port-forward within 5s, and the next `up` died on "port 19080 already bound
  # by another process" with no clue who held it. Cost two debugging rounds.
  echo $$ > "$PF_SUPERVISOR_PID_FILE"
  while true; do
    sleep 5
    if ! port_forward_healthy; then
      echo "$(date -Is) port-forward down — restarting" >> "$PF_LOG_FILE"
      kill_pid_file "$PF_PID_FILE"
      spawn_port_forward
      wait_tcp 127.0.0.1 "$LOCAL_PORT" 30 >/dev/null 2>&1 || true
    fi
  done
}

start_port_forward() {
  # Guard against port already in use by something that is not ours.
  if port_forward_healthy && ! pid_alive "$PF_PID_FILE"; then
    # Name the holder. A bare "already bound" sends the reader hunting; the
    # usual culprit is a supervisor from a tunnel started in ANOTHER checkout,
    # whose .tunnel state this invocation cannot see.
    local holder parent
    holder="$(pid_on_port "$LOCAL_PORT")"
    echo "ERROR: port ${LOCAL_PORT} is already bound" >&2
    if [[ -n "$holder" ]]; then
      echo "       held by PID ${holder}: $(ps -o cmd= -p "$holder" 2>/dev/null | cut -c1-80)" >&2
      parent="$(ps -o ppid= -p "$holder" 2>/dev/null | tr -d ' ')"
      if [[ -n "$parent" && "$parent" != "1" ]]; then
        echo "       supervised by PID ${parent} — kill that first or it will respawn" >&2
      fi
      echo "       If it belongs to another checkout, run 'make public-down' there." >&2
    fi
    echo "       Or set PUBLIC_LOCAL_PORT to a different value." >&2
    return 1
  fi

  spawn_port_forward
  echo "    port-forward: ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} → localhost:${LOCAL_PORT}"
  wait_tcp 127.0.0.1 "$LOCAL_PORT" 30 || return 1

  # Supervisor in its own process group so it survives this script exiting.
  setsid bash -c "$(declare -f port_forward_healthy spawn_port_forward kill_pid_file supervise_port_forward wait_tcp 2>/dev/null); \
    LOCAL_PORT='${LOCAL_PORT}' DASHBOARD_NAMESPACE='${DASHBOARD_NAMESPACE}' \
    DASHBOARD_SERVICE='${DASHBOARD_SERVICE}' DASHBOARD_PORT='${DASHBOARD_PORT}' \
    PF_PID_FILE='${PF_PID_FILE}' PF_LOG_FILE='${PF_LOG_FILE}' \
    supervise_port_forward" &>/dev/null &
  echo $! > "$PF_SUPERVISOR_PID_FILE"
  echo "    supervisor:   restarts the port-forward if it drops"
}

# ── Subcommands ──────────────────────────────────────────────────────
cmd_up() {
  # Already fully up: nothing to do.
  if tunnel_healthy && [[ -f "$NGROK_URL_FILE" ]]; then
    local url
    url="$(cat "$NGROK_URL_FILE")"
    echo "Tunnel is already running."
    print_access_info "$url"
    return 0
  fi

  # ngrok alive but the local leg is dead -- the exact state that serves 502s
  # to every visitor. Repair in place: a full re-up would issue a NEW ngrok URL
  # and re-patch Dex, invalidating a link that may already have been shared.
  if pid_alive "$NGROK_PID_FILE" && [[ -f "$NGROK_URL_FILE" ]] && ! port_forward_healthy; then
    echo "==> ngrok is up but the port-forward is down — repairing without changing the URL"
    kill_pid_file "$PF_SUPERVISOR_PID_FILE"
    kill_pid_file "$PF_PID_FILE"
    start_port_forward || return 1
    local url
    url="$(cat "$NGROK_URL_FILE")"
    verify_public_url "$url" || return 1
    print_access_info "$url"
    return 0
  fi

  # Clean up any partial state from a previous crash.
  cmd_down_quiet

  ensure_ngrok
  local ngrok_bin
  ngrok_bin="$(find_ngrok)"

  mkdir -p "$TUNNEL_DIR"

  echo "════════════════════════════════════════════════════════════"
  echo "  SignalLoom — Public Tunnel"
  echo "════════════════════════════════════════════════════════════"
  echo ""

  # 1. Cookie gate token.
  local token
  token="$(openssl rand -hex 16)"
  echo "$token" > "$COOKIE_TOKEN_FILE"
  echo "==> Cookie gate token generated"

  # 2. Traffic policy.
  generate_traffic_policy "$token"
  echo "==> Traffic policy written"

  # 3. (was: back up the Dex secret)
  #
  # Removed, not disabled. `backup_dex_secret` wrote ${DEX_BACKUP_FILE} and the
  # only reader of that file is `restore_dex_secret`, which nothing calls any
  # more — so `up` was taking a backup that `down` would never restore, and
  # printing "Backing up Dex secret..." implied a rollback contract that did
  # not exist. Since the origin is now delivered by Flux substitution, there is
  # no live patch to roll back from: teardown re-publishes the default origin
  # and reconciliation restores the manifest's own values. The function is left
  # defined but is dead — see the DEAD CODE note above its definition.

  # 4. Port-forward.
  echo "==> Starting port-forward..."
  start_port_forward

  # 5. ngrok tunnel.
  echo "==> Starting ngrok tunnel..."
  local policy_path="$POLICY_FILE"
  # Snap confinement workaround: snap apps cannot read hidden directories.
  if [[ "$ngrok_bin" == /snap/* ]]; then
    cp "$POLICY_FILE" "$SNAP_POLICY_COPY"
    policy_path="$SNAP_POLICY_COPY"
  fi

  reap_orphan_ngrok

  # setsid so the whole agent lands in its own process group and teardown can
  # take the group down. /snap/bin/ngrok is a wrapper that execs the real
  # binary; killing only the recorded PID left the real agent running, still
  # bound to :4040 and still serving the public URL after `down` reported
  # "torn down".
  setsid "$ngrok_bin" http "$LOCAL_PORT" \
    --traffic-policy-file="$policy_path" \
    --log=stdout --log-format=json > "$NGROK_LOG_FILE" 2>&1 &
  echo $! > "$NGROK_PID_FILE"

  # 6. Extract URL -- but only after confirming OUR agent is alive. If it
  #    exited (port already taken, bad token, policy rejected), the 4040 API
  #    may still answer from somebody else's agent, and we would publish a URL
  #    we do not control.
  sleep 2
  if ! pid_alive "$NGROK_PID_FILE"; then
    echo "ERROR: ngrok exited immediately after start." >&2
    echo "       Last lines of ${NGROK_LOG_FILE}:" >&2
    tail -5 "$NGROK_LOG_FILE" >&2 2>/dev/null || true
    return 1
  fi

  echo "==> Waiting for ngrok URL..."
  local url
  url="$(extract_ngrok_url)"
  echo "    ${url}"

  # 7. Publish the origin.
  #
  # This step used to suspend Flux and patch Dex live, and until now it still
  # ANNOUNCED that it did — the "Suspending Flux reconciliation" line survived
  # the rewrite that removed the suspension. Anyone reading the output would
  # reasonably conclude their shared cluster had just been frozen, and go
  # looking for a resume that never has to happen. The output now describes
  # what the code does.
  #
  # Publish the origin as a GitOps input rather than patching Dex and the API
  # directly.
  #
  # Direct patching no longer works, and worse, fails silently: Dex's issuer and
  # redirect URI are now rendered from ${PUBLIC_ORIGIN}, so the next reconcile
  # regenerates the secret from the manifest and overwrites the patch. The
  # tunnel keeps serving, `status` still says HEALTHY, and every login dies with
  # "Unregistered redirect_uri" — exactly the failure this whole mechanism
  # exists to remove.
  #
  # Setting PUBLIC_ORIGIN makes reconciliation the delivery path, so nothing has
  # to be suspended and the value survives every future reconcile.
  echo "==> Publishing the origin to the cluster..."
  publish_origin "$url"

  # 8. Prove it actually serves before telling anyone it is up. Everything
  #    above can succeed against a tunnel that 502s on every request.
  echo "==> Verifying the public URL end to end..."
  verify_public_url "$url" || return 1

  echo ""
  print_access_info "$url"
}

# Proves the tunnel serves AND that the login it hands people actually works.
#
# Checking only the front door was not enough: with the redirect_uri
# mis-indented into oblivion, the root URL returned a cheerful HTTP 200 from
# the cookie gate while every real visitor hit "Error" the instant Dex saw the
# callback. So this also drives the OIDC authorize endpoint the dashboard will
# send people to, and treats a 400 there as a failure of the tunnel.
verify_public_url() {
  local url="$1" code i=0 jar
  jar="$(mktemp)"

  while ((i < 12)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -c "$jar" -b "$jar" -H 'ngrok-skip-browser-warning: 1' "$url" 2>/dev/null || echo 000)"
    case "$code" in
      200|302|303|401|403) break ;;
    esac
    sleep 2
    ((++i))
  done

  case "$code" in
    200|302|303|401|403) echo "    HTTP ${code} — tunnel is serving" ;;
    *)
      echo "ERROR: public URL returned HTTP ${code} after retries — tunnel is not serving" >&2
      echo "       port-forward log: ${PF_LOG_FILE}" >&2
      echo "       ngrok log:        ${NGROK_LOG_FILE}" >&2
      rm -f "$jar"; return 1 ;;
  esac

  # The authorize endpoint, with the redirect_uri the dashboard really sends.
  # Retry, because publishing the origin restarts Dex and this runs straight
  # afterwards -- a single shot raced the rollout and reported 000 against a
  # tunnel that was about to be fine.
  #
  # No `|| echo 000` fallback: curl already prints 000 in %{http_code} when it
  # fails, so the fallback CONCATENATED a second one and produced the
  # uninterpretable "HTTP 000000".
  local auth_code="" attempt=0
  while ((attempt < 10)); do
    auth_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -c "$jar" -b "$jar" -H 'ngrok-skip-browser-warning: 1' \
      "${url}/dex/auth?client_id=signalloom-dashboard&redirect_uri=${url}/callback&response_type=code&scope=openid+profile+email" \
      2>/dev/null)"
    case "$auth_code" in
      200|302|303|400) break ;;
    esac
    sleep 3
    ((++attempt))
  done

  # Allow-list, not a deny-list. Rejecting only "400" let everything else
  # through, including curl's own 000 (connection failed) -- which printed the
  # nonsense "HTTP 000000 — Dex accepts ..." and passed the gate on a request
  # that never completed. A verification step that cannot fail is not one.
  case "$auth_code" in
    200|302|303)
      echo "    HTTP ${auth_code} — Dex accepts ${url}/callback" ;;
    400)
      echo "ERROR: Dex rejected the login redirect (HTTP 400)." >&2
      echo "       Almost always an unregistered redirect_uri. Check:" >&2
      echo "       kubectl logs -n ${DEX_NAMESPACE} deploy/${DEX_DEPLOYMENT} | grep redirect_uri" >&2
      rm -f "$jar"; return 1 ;;
    000|"")
      echo "ERROR: could not reach Dex through the tunnel at all (curl exit)." >&2
      echo "       ngrok log: ${NGROK_LOG_FILE}" >&2
      rm -f "$jar"; return 1 ;;
    *)
      echo "ERROR: Dex returned an unexpected HTTP ${auth_code} for the login redirect." >&2
      rm -f "$jar"; return 1 ;;
  esac
  rm -f "$jar"
}

# The whole chain, not one PID. This is what every caller should ask.
tunnel_healthy() {
  pid_alive "$NGROK_PID_FILE" && port_forward_healthy
}

print_access_info() {
  local url="$1"
  echo "════════════════════════════════════════════════════════════"
  echo "  SignalLoom is now publicly accessible"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "  URL:         ${url}"
  echo "  Credentials: demo-user@signalloom.local / demo-user"
  echo ""
  echo "  The cookie gate auto-authenticates on first browser visit."
  echo "  Share the URL directly — no token needed."
  echo ""
  echo "  Remote test:  make public-test"
  echo "  Tear down:    make public-down"
  echo ""
  echo "════════════════════════════════════════════════════════════"
}

# ngrok runs under setsid, so it owns its process group; kill the group rather
# than the single recorded PID. Then confirm :4040 is actually free -- a
# teardown that leaves the agent running is worse than no teardown, because the
# next `up` silently adopts its URL.
kill_ngrok_group() {
  if [[ -f "$NGROK_PID_FILE" ]]; then
    local pid; pid="$(cat "$NGROK_PID_FILE")"
    kill -- "-${pid}" 2>/dev/null || kill "$pid" 2>/dev/null || true
    local i=0
    while kill -0 "$pid" 2>/dev/null && ((i < 20)); do sleep 0.5; ((++i)); done
    kill -9 -- "-${pid}" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    rm -f "$NGROK_PID_FILE"
  fi
  # Belt and braces: whoever still holds :4040 is a leftover agent.
  local owner; owner="$(pid_on_port 4040)"
  if [[ -n "$owner" ]]; then
    kill "$owner" 2>/dev/null || true
    sleep 1
    kill -9 "$owner" 2>/dev/null || true
  fi
}

cmd_down() {
  echo "==> Tearing down public tunnel..."

  # 1. Restore our patches first, then hand control back to Flux. Resuming
  #    before restoring would let Flux race the restore.
  # Set the origin back to the in-git default. NOT a key deletion: the tenant
  # ConfigMap copies keep the last value when the key disappears, so removing it
  # leaves the demo published on a dead origin while the cluster looks reset.
  echo "==> Reverting the public origin..."
  unpublish_origin

  cmd_down_quiet

  echo "==> Public tunnel torn down."
}

# Quiet teardown for cleanup during up (no Dex restore).
cmd_down_quiet() {
  # Supervisor first: it restarts the port-forward within 5s, so killing the
  # forward before its supervisor just resurrects it.
  kill_pid_file "$PF_SUPERVISOR_PID_FILE"
  kill_ngrok_group
  kill_pid_file "$PF_PID_FILE"
  rm -f "$SNAP_POLICY_COPY"
  rm -rf "$TUNNEL_DIR"
}

cmd_status() {
  local running=true
  if ! pid_alive "$NGROK_PID_FILE"; then
    echo "ngrok: not running"
    running=false
  else
    echo "ngrok: running (PID $(cat "$NGROK_PID_FILE"))"
  fi

  # Health is the listening socket, not the PID: kubectl can survive with a
  # dead stream, and a dead PID with a live socket means someone else has the port.
  if ! port_forward_healthy; then
    echo "port-forward: not serving on ${LOCAL_PORT}"
    running=false
  else
    echo "port-forward: serving on ${LOCAL_PORT} (PID $(cat "$PF_PID_FILE" 2>/dev/null || echo '?'))"
  fi

  # A verdict, not two facts to correlate. "ngrok: running" alongside
  # "port-forward: not running" means the public URL is serving 502s, and that
  # read as healthy at a glance.
  if [[ -f "$NGROK_URL_FILE" ]] && $running; then
    echo "url: $(cat "$NGROK_URL_FILE")"
    echo "tunnel: HEALTHY"
    return 0
  fi
  if pid_alive "$NGROK_PID_FILE" && ! port_forward_healthy; then
    echo "tunnel: BROKEN — ngrok is accepting traffic with no local backend;"
    echo "        every visitor gets a 502. Run 'make public' to repair."
  else
    echo "tunnel: DOWN"
  fi
  return 1
}

cmd_url() {
  # Requires the WHOLE chain. `make public-test` feeds this straight into the
  # acceptance suite; handing back a URL whose backend is dead turned an
  # infrastructure outage into a page full of application test failures.
  if [[ -f "$NGROK_URL_FILE" ]] && tunnel_healthy; then
    cat "$NGROK_URL_FILE"
    return 0
  fi
  if pid_alive "$NGROK_PID_FILE"; then
    echo "ERROR: tunnel is broken — ngrok is up but nothing is serving on ${LOCAL_PORT}." >&2
    echo "       Run 'make public' to repair before testing." >&2
  else
    echo "ERROR: no tunnel running" >&2
  fi
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────
case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  url)    cmd_url ;;
  *)
    echo "Usage: $0 {up|down|status|url}" >&2
    echo "" >&2
    echo "  up      Start port-forward + ngrok, patch Dex, print access info" >&2
    echo "  down    Tear down tunnel, restore Dex config" >&2
    echo "  status  Show tunnel status and URL" >&2
    echo "  url     Print the public URL (for scripting)" >&2
    exit 1
    ;;
esac
