#!/usr/bin/env bash
# Lifecycle script for the KubeSec-AFM D2 demo slice.
#
#   k8s-afm.sh preflight  Report which image source is available here. No side effects.
#   k8s-afm.sh save [OUT] Build the image and write a portable archive for delivery.
#   k8s-afm.sh build    Obtain the image and kind-load it. No deploy, no cluster writes.
#   k8s-afm.sh up       Obtain image, kind-load, deploy, wait, import the live cluster.
#   k8s-afm.sh down     Remove the AFM platform namespace + resources.
#   k8s-afm.sh test     Run the backend pytest suite inside the source repo.
#   k8s-afm.sh seed     POST the demo cluster YAML so the dashboard has data.
#   k8s-afm.sh status   Show pods + /health.
#
# ─── Two ways to obtain the image, and why there had to be two ───────────────
#
# The image is BUILT from a source repo that lives outside this one
# (KUBESEC_AFM_ROOT). That was the only mechanism, and it is why no remote lane
# has ever run AFM: a lane's entire payload is `git archive HEAD` of this repo,
# tracked files only, so the AFM source cannot reach it by construction. The
# manifests in d2-k8s-afm/ shipped and the image never did, which is why
# https://sl-<lane>.../afm/ was a deterministic nginx 502 on all four lanes —
# seven nginx locations point at afm-platform.fe-k8s-afm and the namespace did
# not exist.
#
# So building is now separated from CONSUMING. `save` produces a portable
# archive from the source; every consumer takes either the source or the
# archive. A lane receives the archive over the same side channel that delivers
# the payload (scripts/gcp-tf/demo-up.sh:deliver_afm_image) and never needs the
# source at all.
#
# Source wins when both are present: it is the only one of the two that can be
# newer than the last `save`, and a stale archive silently deploying an old
# binary is the "green tests tested the wrong artefact" shape this repo has
# already been bitten by.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
# Derived as a sibling of this repo, never an absolute path under someone's
# home. test/terraform-conventions.bats scans for committed developer home
# directories but its globs do not reach scripts/k8s-afm.sh, so this line sat
# green while being the original of the two copies that DID trip the guard in
# scripts/gcp-tf/ and scripts/ci/. Out of the guard's reach is not the same as
# correct, and leaving it would have made the next copy of it look sanctioned.
AFM_SOURCE="${KUBESEC_AFM_ROOT:-$(cd "$REPO_ROOT/.." 2>/dev/null && pwd)/kubesec-afm}"
# Gitignored: a 245MB binary has no business in `git archive HEAD`, and keeping
# it out is what preserves the payload's tracked-files-only security property.
AFM_IMAGE_ARCHIVE="${AFM_IMAGE_ARCHIVE:-${REPO_ROOT}/.afm-image/kubesec-afm.tar.gz}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NS="fe-k8s-afm"
IMAGE="kubesec-afm:latest"

cmd="${1:-up}"

have_afm_source() { [ -f "$AFM_SOURCE/AFM/docker/backend.Dockerfile" ]; }
have_afm_archive() { [ -s "$AFM_IMAGE_ARCHIVE" ]; }

# When neither mechanism is available, `docker build -f <missing>` fails with a
# bare "no such file or directory" naming a path nobody set explicitly, which
# reads as a broken Makefile rather than a missing checkout. Name BOTH routes
# and the variable that relocates each, before spending anything on a build.
refuse_no_image() {
  cat >&2 <<EOF
error: no way to obtain the KubeSec-AFM image here. Both routes are unavailable:

  1. source checkout   NOT FOUND at: $AFM_SOURCE
       Expected: \$AFM_SOURCE/AFM/docker/backend.Dockerfile
       The image is built from a separate checkout, not from this repo.
       Clone it, then place it at that path or set KUBESEC_AFM_ROOT:
           KUBESEC_AFM_ROOT=/path/to/kubesec-afm make demo-k8s-afm-up

  2. delivered archive NOT FOUND at: $AFM_IMAGE_ARCHIVE
       This is the route a remote lane uses, because the lane's payload is
       'git archive HEAD' of this repo and the AFM source is not in it.
       Produce one on a machine that HAS the source, then set AFM_IMAGE_ARCHIVE:
           ./scripts/k8s-afm.sh save /tmp/kubesec-afm.tar.gz

  Until AFM is deployed, Signal Loom's RBAC Explorer reports
  "KubeSec-AFM is not deployed", the RBAC Analysis page shows its
  "platform is not reachable" banner, and /afm/ answers 502 — that page and
  those seven nginx locations read their data from this slice.
EOF
  exit 1
}

# Put $IMAGE in the local docker daemon by whichever route is available.
ensure_image() {
  if have_afm_source; then
    echo "==> Building kubesec-afm image from source (multi-stage: Next.js + FastAPI + Z3)..."
    docker build -q -f "$AFM_SOURCE/AFM/docker/backend.Dockerfile" \
      -t "$IMAGE" "$AFM_SOURCE/AFM" 2>&1 | tail -2
  elif have_afm_archive; then
    echo "==> Loading kubesec-afm image from delivered archive: $AFM_IMAGE_ARCHIVE"
    # `docker load` detects the gzip itself. Its exit status is necessary but
    # not sufficient — the same lesson kind-load-verified.sh was written for —
    # so the image store is asked directly afterwards.
    docker load -i "$AFM_IMAGE_ARCHIVE" 2>&1 | tail -2
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
      echo "error: $AFM_IMAGE_ARCHIVE loaded without error but produced no $IMAGE." >&2
      echo "       The archive is for a different tag, or it is truncated. Re-run 'k8s-afm.sh save'." >&2
      exit 1
    }
  else
    refuse_no_image
  fi
}

# One loader for every caller, and it is the repo's VERIFIED one.
#
# `kind load docker-image` prints "loading..." and exits 0 having transferred
# nothing often enough that scripts/kind-load-verified.sh exists specifically to
# catch it; see that file's header for the four-stage failure it caused in CI.
# AFM is the largest image in the estate at 655MB, so it is the most exposed to
# exactly that, and a silent non-transfer here surfaces as ImagePullBackOff and
# a 502 — indistinguishable from AFM never having been deployed at all.
load_into_kind() {
  echo "==> Loading into kind cluster ${CLUSTER_NAME} (verified)..."
  CLUSTER_NAME="$CLUSTER_NAME" "$REPO_ROOT/scripts/kind-load-verified.sh" "$IMAGE"
}

case "$cmd" in
  preflight)
    # Single source of truth for "can the AFM slice be deployed here?", so
    # callers that must decide (make demo-signalloom-afm-up) probe it rather
    # than duplicating the path. Says WHICH route it found, because "AFM is
    # available" via a three-week-old archive and via a fresh source checkout
    # are different enough facts that a log reading the same for both is a log
    # that cannot be used to diagnose a stale deployment.
    if have_afm_source; then
      echo "KubeSec-AFM image route: source checkout at $AFM_SOURCE"
    elif have_afm_archive; then
      echo "KubeSec-AFM image route: delivered archive at $AFM_IMAGE_ARCHIVE"
    else
      refuse_no_image
    fi
    ;;
  has-source)
    # Silent predicate: can this machine BUILD the image? Exits 0/1, prints
    # nothing, touches nothing. It exists so callers can decide whether to
    # build WITHOUT each carrying its own copy of the default source path —
    # there were three copies, and two of them were committed developer home
    # directories that test/terraform-conventions.bats duly caught. One owner
    # for the default, asked rather than copied.
    have_afm_source
    ;;
  save)
    # Produce the artifact a lane consumes. Requires the source: this is the
    # one subcommand that genuinely cannot fall back to an archive, because
    # producing the archive is what it is for.
    out="${2:-$AFM_IMAGE_ARCHIVE}"
    have_afm_source || {
      echo "error: 'save' builds the image and so needs the source checkout." >&2
      echo "       Not found at: $AFM_SOURCE  (set KUBESEC_AFM_ROOT to relocate)" >&2
      echo "       There is no archive-to-archive path: an archive is the OUTPUT of this command." >&2
      exit 1
    }
    mkdir -p "$(dirname "$out")"
    ensure_image
    echo "==> Saving $IMAGE to $out ..."
    # gzip -1: the archive is transferred over an IAP tunnel where wall-clock is
    # dominated by the link, not the CPU. -1 gives 245MB in ~10s where -6 gives
    # ~230MB in ~90s — 6% smaller for 9x the local cost, which is the wrong
    # trade for a file that gets rebuilt on every source change.
    #
    # docker save WITHOUT --platform, deliberately: kind-load-verified.sh's
    # header records that the single-platform form leaves an image `ctr` lists
    # and `crictl` does not, which is a dead end. The index form imports cleanly.
    docker save "$IMAGE" | gzip -1 > "$out"
    [ -s "$out" ] || { echo "error: $out is empty after docker save reported success." >&2; exit 1; }
    echo "kubesec-afm archive: $out ($(du -h "$out" | cut -f1))"
    ;;
  build)
    # Image acquisition only — no kubectl apply, no rollout, no seeding. This is
    # what `make images-afm` calls, so the AFM slice can be rebuilt alongside
    # every other slice without deploying to (or otherwise touching) a cluster.
    ensure_image
    load_into_kind
    echo "kubesec-afm image ready and loaded: $IMAGE"
    ;;
  up)
    ensure_image
    load_into_kind
    echo "==> Deploying AFM platform to ${NS}..."
    kubectl apply -k "$REPO_ROOT/d2-k8s-afm/apps/afm-platform/local" 2>&1
    echo "==> Waiting for rollout..."
    wait_rollout afm-platform -n "$NS" 120 2>&1 | tail -1

    # ─── Import the live cluster NOW, rather than within half an hour ─────────
    #
    # afm-cluster-import is a CronJob on `*/30 * * * *`, and a CronJob does not
    # run on creation. On a lane, where there is no source checkout and so no
    # sample clusters to POST below, that left AFM deployed and healthy holding
    # ZERO clusters for up to 30 minutes: /afm/health answers 200 (so the 502 is
    # gone and the slice looks fine) while the RBAC Analysis page renders
    # "0 clusters" and the embedded dashboard is empty. That is a worse failure
    # than the 502 because everything downstream reports success.
    #
    # Materialising a Job from the CronJob template reuses the manifest as the
    # single definition of what an import IS — a hand-written duplicate here
    # would be a second spelling free to drift from the scheduled one.
    echo "==> Importing this cluster's RBAC (the CronJob will not run for up to 30m)..."
    kubectl -n "$NS" delete job afm-cluster-import-now --ignore-not-found >/dev/null 2>&1 || true
    if kubectl -n "$NS" create job afm-cluster-import-now --from=cronjob/afm-cluster-import >/dev/null 2>&1; then
      if kubectl -n "$NS" wait --for=condition=complete job/afm-cluster-import-now --timeout=180s >/dev/null 2>&1; then
        echo "  imported: cluster id=local"
      else
        # Not fatal on its own — the analysis wait below is the real gate, and
        # it reports the consequence. But say that the import is why, rather
        # than leaving the next reader to infer it from an empty cluster list.
        echo "  WARNING: the import Job did not complete in 180s. /afm/clusters will be empty"
        echo "           and the RBAC Analysis page will show 0 clusters. Logs:"
        kubectl -n "$NS" logs job/afm-cluster-import-now --tail=20 2>&1 | sed 's/^/           /' || true
      fi
    else
      echo "  WARNING: could not create the import Job from cronjob/afm-cluster-import."
    fi

    echo "==> Seeding demo cluster data..."
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    for sample in "$AFM_SOURCE"/AFM/backend/samples/clusters/*.yaml "$AFM_SOURCE"/AFM/backend/samples/clusters/*.json; do
      [ -f "$sample" ] || continue
      name="$(basename "$sample")"
      if python3 -c "
import urllib.request, json, sys, pathlib
data = pathlib.Path('$sample').read_text()
ct = 'application/x-yaml' if '$sample'.endswith('.yaml') else 'application/json'
try:
    r = urllib.request.urlopen(urllib.request.Request('http://localhost:18000/clusters/upload', data=data.encode(), headers={'Content-Type': ct}), timeout=10)
    print(f'  seeded: $name ({r.status})')
except Exception as e:
    print(f'  skip: $name ({e})')
" 2>&1; then true; fi
    done
    # Trigger the escalation analysis so /clusters/local/analysis/latest is
    # populated before acceptance tests run. The CronJob imports the live cluster
    # RBAC as id=local; this POST kicks off the async analysis and waits for it.
    echo "==> Triggering escalation analysis for local cluster..."
    curl -sS -X POST http://localhost:18000/clusters/local/analysis/escalation \
      -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    if _wait_retry 60 "local cluster analysis ready" "curl -fsS http://localhost:18000/clusters/local/analysis/latest 2>/dev/null | jq -e '.metadata.non_admins' >/dev/null 2>&1"; then
      count=$(curl -fsS http://localhost:18000/clusters/local/analysis/latest 2>/dev/null | jq -r '.metadata.non_admins | length // 0')
      echo "  analysis ready: ${count} non-admin subjects"
    else
      echo "  analysis not ready after 60s (tests may fail on /analysis/latest)"
    fi
    kill "$PF" 2>/dev/null || true
    echo "==> KubeSec-AFM deployed."
    kubectl -n "$NS" get pods
    echo ""
    echo "    port-forward: kubectl -n $NS port-forward svc/afm-platform 8000:8000"
    echo "    dashboard:    http://localhost:8000/dashboard"
    echo "    API health:   http://localhost:8000/health"
    ;;
  down)
    echo "==> Removing KubeSec-AFM platform..."
    kubectl delete -k "$REPO_ROOT/d2-k8s-afm/apps/afm-platform/local" --ignore-not-found 2>&1
    echo "==> Done."
    ;;
  test)
    # The pytest suite lives in the AFM repo and reads its source tree. An
    # image archive cannot substitute — it holds the built artifact, not the
    # tests — so this is the second subcommand that genuinely requires source.
    have_afm_source || {
      echo "error: 'test' runs the AFM repo's own pytest suite and so needs the source checkout." >&2
      echo "       Not found at: $AFM_SOURCE  (set KUBESEC_AFM_ROOT to relocate)" >&2
      echo "       A delivered image archive cannot stand in: it carries the built artifact, not the tests." >&2
      exit 1
    }
    echo "==> Running backend pytest from source repo..."
    cd "$AFM_SOURCE/AFM/backend"
    if [ -d "$AFM_SOURCE/AFM/.venv" ]; then
      "$AFM_SOURCE/AFM/.venv/bin/python" -m pytest -q 2>&1
    else
      echo "  No .venv found; running: make -C $AFM_SOURCE/AFM setup && make -C $AFM_SOURCE/AFM test"
      make -C "$AFM_SOURCE/AFM" setup 2>&1 | tail -3
      make -C "$AFM_SOURCE/AFM" test 2>&1
    fi
    ;;
  seed)
    # Sample clusters ship with the source, not with the image, so this is a
    # source-only convenience. On a lane the equivalent data comes from the
    # cluster-import Job that `up` now materialises.
    have_afm_source || {
      echo "error: 'seed' POSTs the sample clusters that live in the AFM source tree." >&2
      echo "       Not found at: $AFM_SOURCE  (set KUBESEC_AFM_ROOT to relocate)" >&2
      echo "       On a lane with no source, 'k8s-afm.sh up' imports this cluster's own RBAC instead." >&2
      exit 1
    }
    echo "==> Seeding sample clusters..."
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    bash "$AFM_SOURCE/scripts/seed-demo.sh" 2>&1 || true
    kill "$PF" 2>/dev/null || true
    ;;
  status)
    echo "==> Pods in $NS:"
    kubectl -n "$NS" get pods 2>&1
    echo "==> Health:"
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    python3 -c "import urllib.request,json; print(json.load(urllib.request.urlopen('http://localhost:18000/health',timeout=5)))" 2>&1 || echo "  (unreachable)"
    kill "$PF" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 [preflight|build|up|down|test|seed|status]" >&2
    exit 64
    ;;
esac
