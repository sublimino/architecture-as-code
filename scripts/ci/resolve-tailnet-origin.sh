#!/usr/bin/env bash
#
# Print this node's own tailnet origin — `https://<node>.<tailnet>.ts.net`.
#
# The user-surface gate must be aimed at the URL a human actually opens. That
# URL is not derivable from the hostname: the tailnet suffix is only known to
# tailscaled, and a node whose name drifted (sl-demo-1 -> sl-demo-1-1) serves
# on the name it HAS, not the one anyone remembers. So this reads DNSName from
# `tailscale status --json`, the same source scripts/gcp-tf/tailscale-cert-state.sh
# uses for the same reason.
#
# Exits non-zero and prints nothing usable when there is no tailnet identity.
# That is deliberate: the caller must fail, not fall back to localhost. A
# localhost fallback here would silently restore the exact blind spot the gate
# exists to close — the demo lane already proves the estate over a port-forward
# and that is what let two dead demos score 29/29.

set -o pipefail

TS_CMD="${TS_CMD:-tailscale}"

command -v "$TS_CMD" >/dev/null 2>&1 || {
  echo "resolve-tailnet-origin: no '${TS_CMD}' binary on PATH" >&2
  exit 1
}

json="$("$TS_CMD" status --json 2>/dev/null)" || {
  echo "resolve-tailnet-origin: 'tailscale status --json' failed — is tailscaled up?" >&2
  exit 1
}

# Self.DNSName is the first DNSName in the document. Matching the first
# occurrence is what tailscale-cert-state.sh does; peers appear after Self.
name="$(printf '%s' "$json" \
  | tr ',' '\n' \
  | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -n 1)"
name="${name%.}"

[ -n "$name" ] || {
  echo "resolve-tailnet-origin: tailscale reported no DNSName — node is not on a tailnet" >&2
  exit 1
}

printf 'https://%s\n' "$name"
