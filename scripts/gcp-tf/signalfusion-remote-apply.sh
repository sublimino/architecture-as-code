#!/usr/bin/env bash
# The VM-side half of the targeted Signal Fusion apply. Runs ON the lane.
#
# This is a FILE, shipped and executed, rather than a string passed to
# `gcloud compute ssh --command`. That is a deliberate correction: the inline
# form is one double-quoted shell string wrapping a second shell, and three
# separate attempts died in its quoting — a backtick in a comment ran as
# command substitution, then a stray quote truncated the block. Every one of
# those failures happened AFTER the file sync and BEFORE anything rolled, so
# they were harmless, but they were spending a live demo's time on syntax.
# A file has exactly one level of quoting and cannot develop this class of bug.
#
# Does four things and nothing else. Dex is never touched, nothing is
# destroyed, the Gateway is not modified.

set -eo pipefail

REPO_DIR="${REPO_DIR:-/opt/signalloom/repo}"
NS_APPS="${NS_APPS:-fe-signalloom}"
NS_INFRA="${NS_INFRA:-inf-signalloom}"

cd "$REPO_DIR"

# The signing keys are NOT in the delivered tree: the .keys directory is
# gitignored, so git archive cannot carry it. The pipeline provisions them at
# /opt/signalloom/keys and exports KEYS_DIR there. The Makefile assigns
# KEYS_DIR with ?=, which yields to the environment, so exporting it is the
# supported override.
#
# Without it, push-local.sh stops and asks for 'make signing-keys'. Running
# that would generate a NEW keypair and re-key the signer, after which every
# image the cluster already trusts fails verification with 'no matching
# signatures' — a self-inflicted outage on a live lane, dressed as a fix. So
# this refuses rather than generates.
export KEYS_DIR="${KEYS_DIR:-/opt/signalloom/keys}"
if [ ! -f "$KEYS_DIR/cosign.key" ]; then
	echo "no cosign.key under $KEYS_DIR - refusing to generate one" >&2
	exit 1
fi

# Recorded BEFORE the rollouts so the report can prove Dex never moved, rather
# than assert it. The pod name changes on any restart.
dex_before="$(kubectl -n "$NS_INFRA" get pods -l app.kubernetes.io/name=dex \
	-o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
echo "dex pods BEFORE: ${dex_before:-<none>}"

echo "--- manifests -> OCI artifact ---"
# Must go through the artifact. A bare kubectl apply of the deployment env and
# the NetworkPolicies is reverted the next time Flux reconciles.
make push-local-signalloom

echo "--- runner image ---"
make demo-signalloom-supercred-runner-image

echo "--- dashboard image ---"
make signalloom-dashboard-image

echo "--- reconcile Flux so the new manifests land ---"
# The OCIRepository must be refreshed before its Kustomization, or the
# reconcile re-applies whatever the source already had.
for target in "${NS_INFRA}/infra-configs" "${NS_APPS}/apps"; do
	ns="${target%%/*}"
	name="${target##*/}"
	src="$(kubectl get kustomization "$name" -n "$ns" -o jsonpath='{.spec.sourceRef.name}' 2>/dev/null || true)"
	if [ -n "$src" ]; then
		flux reconcile source oci "$src" -n "$ns" >/dev/null 2>&1 || true
	fi
	flux reconcile kustomization "$name" -n "$ns" >/dev/null 2>&1 || true
done

echo "--- roll ONLY the two workloads ---"
kubectl -n "$NS_APPS" rollout restart deploy/supercred-demo-runner deploy/dashboard-signalloom
kubectl -n "$NS_APPS" rollout status deploy/supercred-demo-runner --timeout=180s
kubectl -n "$NS_APPS" rollout status deploy/dashboard-signalloom --timeout=180s

# Rolling the dashboard KILLS the tailnet backend, and systemd will not notice.
#
# signalloom-dashboard-pf.service runs `kubectl port-forward svc/dashboard-
# signalloom 30754:8080`, and tailscale serve proxies the public URL at
# 127.0.0.1:30754. When the dashboard pod is replaced the forward stops
# carrying traffic, but the kubectl PROCESS stays alive - so systemd reports
# the unit active, nothing restarts it, and the unit log's last line is still
# the cheerful "Forwarding from 0.0.0.0:30754".
#
# Measured here on 2026-08-23, minutes after this script rolled the dashboard:
# unit active, NO listener on 30754, and every path through the public origin
# answering 502 - including /dex/healthz and SuperCred, neither of which this
# change touches. On-VM checks over 127.0.0.1 all passed throughout, because
# the tailnet is a separate path none of them traverse.
#
# So the restart is unconditional and belongs to whoever rolled the dashboard.
echo "--- re-establishing the tailnet backend (the dashboard roll invalidates it) ---"
sudo systemctl restart signalloom-dashboard-pf.service || true
for _ in $(seq 1 15); do
	if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:30754/readyz; then break; fi
	sleep 2
done
if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:30754/readyz; then
	echo "PUBLISH OK: 127.0.0.1:30754 answers, so the tailnet URL has a backend again"
else
	echo "*** PUBLISH DEAD: nothing answering on 30754 - the public URL will 502 ***" >&2
	exit 1
fi

dex_after="$(kubectl -n "$NS_INFRA" get pods -l app.kubernetes.io/name=dex \
	-o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
echo "dex pods AFTER : ${dex_after:-<none>}"
if [ "$dex_before" = "$dex_after" ]; then
	echo "DEX UNTOUCHED: same pod, sign-in never dropped"
else
	echo "*** DEX CHANGED — this was not supposed to happen ***" >&2
	exit 1
fi

echo "--- deployed runner: does it carry the fix? ---"
kubectl -n "$NS_APPS" exec deploy/supercred-demo-runner -- sh -c '
  ls -l /repo/scripts/signalfusion-demo.sh
  echo "SIGNALFUSION_DEMO_CWD=${SIGNALFUSION_DEMO_CWD:-<unset>}"
  echo "SIGNAL_INGEST_URL=${SIGNAL_INGEST_URL:-<unset>}"
' 2>&1 || true
