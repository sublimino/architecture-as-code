#!/usr/bin/env bash
# Targeted apply of the Signal Fusion fix to a STANDING lane.
#
# Deliberately NOT `gcp-tf-demo-up`. That path converges but is not
# non-disruptive: it reaches dex_origin_apply, whose _dex_origin_restart_dex is
# unconditional, so every run rolls Dex and drops sign-in whether or not the
# origin changed. On a lane someone is demoing from, that is the one thing that
# must not happen. It is also ~40 minutes, because demo-pipeline.sh only accepts
# DEMO_STAGE=full.
#
# This does the four things the fix actually needs and nothing else:
#
#   1. sync the changed files into the delivered checkout -- file-by-file, NOT
#      the pipeline's `sudo rm -rf $REMOTE_WORK_DIR` delivery, which would take
#      .keys/ with it;
#   2. push the manifests as an OCI artifact and reconcile Flux, so the
#      deployment env and NetworkPolicies land durably. A bare `kubectl apply`
#      would be silently reverted on the next reconcile;
#   3. rebuild ONLY the runner and dashboard images;
#   4. roll ONLY those two Deployments.
#
# Dex is never touched. Nothing is destroyed. The Gateway is not modified.
#
#   signalfusion-targeted-apply.sh <vm-name> [--verify-only]

set -eo pipefail

VM="${1:?usage: signalfusion-targeted-apply.sh <vm-name> [--verify-only]}"
MODE="${2:-apply}"

ZONE="${ZONE:-us-east4-a}"
PROJECT="${PROJECT:-sl-port-over-sandbox}"
SA="${SA:-sl-operator@sl-port-over-sandbox.iam.gserviceaccount.com}"
REMOTE_DIR="${REMOTE_DIR:-/opt/signalloom/repo}"
NS_APPS="${NS_APPS:-fe-signalloom}"
REMOTE_KEYS_DIR="${REMOTE_KEYS_DIR:-/opt/signalloom/keys}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# SSH_AUTH_SOCK must be empty: gcloud hands the agent's keys to ssh, the agent
# refuses, and the failure surfaces as a provisioning timeout rather than an
# auth error.
ssh_vm() {
	SSH_AUTH_SOCK= timeout "${SSH_TIMEOUT:-900}" gcloud compute ssh "$VM" \
		--zone "$ZONE" --project "$PROJECT" --tunnel-through-iap \
		--impersonate-service-account="$SA" --command "$1" 2>&1 | grep -v '^WARNING'
}

# Every file this fix touches that the VM's build reads. Listed rather than
# derived from `git diff` so a stray edit elsewhere in the tree cannot ride
# along into a live lane.
FILES=(
	"d2-signalloom/apps/supercred-demo-runner/Dockerfile"
	"d2-signalloom/apps/supercred-demo-runner/base/deployment.yaml"
	"d2-signalloom/apps/supercred-demo-runner/base/networkpolicy.yaml"
	"d2-signalloom/apps/signal-ingest/base/networkpolicy.yaml"
	"d2-signalloom/apps/dashboard-signalloom/nginx.conf"
	"d2-signalloom/apps/dashboard-signalloom/src/api/signalFusionDemo.ts"
	"d2-signalloom/apps/fe-signalloom/src/demo_runner.py"
	"scripts/signalfusion-demo.sh"
	"scripts/gcp-tf/signalfusion-remote-apply.sh"
)

sync_files() {
	echo "==> syncing $(( ${#FILES[@]} )) files to ${VM}:${REMOTE_DIR}"
	local f
	for f in "${FILES[@]}"; do
		[ -f "$repo_root/$f" ] || { echo "MISSING LOCALLY: $f" >&2; exit 1; }
	done
	# One tar over stdin: no per-file ssh round trip, and --no-same-owner so the
	# extracted files belong to the login user rather than root.
	tar -C "$repo_root" -czf - "${FILES[@]}" \
		| SSH_AUTH_SOCK= gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" \
			--tunnel-through-iap --impersonate-service-account="$SA" \
			--command "sudo tar -C '$REMOTE_DIR' -xzf - --no-same-owner && sudo chmod 0755 '$REMOTE_DIR/scripts/signalfusion-demo.sh'" \
		2>&1 | grep -v '^WARNING' || true
	echo "==> synced"
}

verify_sync() {
	echo "==> verifying the delivered tree carries the fix"
	ssh_vm "
		set -e
		cd '$REMOTE_DIR'
		printf 'runner Dockerfile COPY : '; grep -c '^COPY scripts/signalfusion-demo.sh ' d2-signalloom/apps/supercred-demo-runner/Dockerfile
		printf 'deployment env        : '; grep -c 'SIGNALFUSION_DEMO_CWD' d2-signalloom/apps/supercred-demo-runner/base/deployment.yaml
		printf 'nginx rewrite         : '; grep -c 'rewrite \^/demo-api/signalfusion' d2-signalloom/apps/dashboard-signalloom/nginx.conf
		printf 'client prefix         : '; grep -c \"SF_DEMO_API = '/demo-api/signalfusion'\" d2-signalloom/apps/dashboard-signalloom/src/api/signalFusionDemo.ts
		printf 'allowlist entry       : '; grep -c 'SIGNAL_INGEST_URL' d2-signalloom/apps/fe-signalloom/src/demo_runner.py
		printf 'script uses real route: '; grep -c 'api/v1/observations' scripts/signalfusion-demo.sh
	"
}

build_and_roll() {
	echo "==> pushing manifests, rebuilding two images, rolling two workloads"
	# One level of quoting. The remote body is a FILE (shipped in FILES above),
	# not a string wrapping a second shell -- see that file's header for why.
	ssh_vm "sudo chmod 0755 '$REMOTE_DIR/scripts/gcp-tf/signalfusion-remote-apply.sh' && REPO_DIR='$REMOTE_DIR' NS_APPS='$NS_APPS' KEYS_DIR='$REMOTE_KEYS_DIR' bash '$REMOTE_DIR/scripts/gcp-tf/signalfusion-remote-apply.sh'"
}

case "$MODE" in
apply)
	sync_files
	verify_sync
	build_and_roll
	;;
--verify-only)
	verify_sync
	;;
*)
	echo "unknown mode: $MODE" >&2
	exit 2
	;;
esac

echo "==> targeted apply complete on $VM"
