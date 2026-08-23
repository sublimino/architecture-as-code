#!/usr/bin/env bash
# Runtime proof for the one intentionally bounded OpenBao/SPIRE relationship.
#
# ── Why this script recreates the Jobs instead of just waiting on them ──────
#
# A Kubernetes Job is TERMINAL. Once it reaches Complete it stays Complete
# forever, so `kubectl wait --for=condition=complete` against a Job that
# finished days ago returns INSTANTLY and SUCCESSFULLY. Until 2026-08-23 this
# script only waited, so it re-read history rather than re-proving anything.
#
# Measured on kind-osramp: both proof Jobs were Complete and 2d20h old while
# every SPIFFE login on that lane was failing. This script would have reported
# a two-day-old pass throughout the outage. Job age was the only tell, and
# nothing looked at it. Same shape as an unwired guard — green because nobody
# asked again.
#
# Two mechanisms, and both are deliberate:
#   RECREATE   deletes both Jobs and lets Flux rebuild them, which is what
#              actually produces fresh evidence.
#   FRESHNESS  asserts each Job was created during THIS run. It cannot produce
#              evidence, only refuse stale evidence — its purpose is to fail if
#              someone later removes the recreate.
#
# `backoffLimit: 0` on both Jobs means a recreated Job's Complete status is
# genuinely meaningful, so staleness really was the whole defect.
set -euo pipefail

namespace="${SIGNALLOOM_NAMESPACE:-fe-signalloom}"
positive="${BAO_SPIRE_POSITIVE_JOB:-bao-spire-positive-proof}"
negative="${BAO_SPIRE_NEGATIVE_JOB:-bao-spire-negative-proof}"
timeout="${DEMO_WAIT_TIMEOUT:-10m}"
# Tolerance for clock skew between this host and the API server that stamps
# creationTimestamp. Minutes, against a staleness measured in days — large
# enough that skew cannot cause a false failure, small enough that the 2d20h
# case this exists for is still caught by three orders of magnitude.
skew="${BAO_PROOF_MAX_SKEW_SECONDS:-300}"
run_start_epoch="$(date -u +%s)"

command -v kubectl >/dev/null 2>&1 || { echo 'kubectl is required for Bao/SPIRE proof' >&2; exit 1; }

# Delete, then ask Flux to rebuild. Matches how scripts/demo-lifecycle.sh
# refreshes these same two Jobs during signalloom_up — one mechanism, not two.
recreate_proof_jobs() {
  command -v flux >/dev/null 2>&1 || {
    echo 'flux is required to rebuild the proof Jobs; set BAO_PROOF_RECREATE=0 only when you have just created them yourself' >&2
    return 1
  }
  kubectl -n "$namespace" delete job "$positive" "$negative" --ignore-not-found --wait=true
  flux reconcile kustomization apps -n "$namespace" --with-source
}

# A Job created before this run started cannot be evidence about this run.
assert_job_fresh() {
  local job="$1" created created_epoch
  created="$(kubectl -n "$namespace" get job "$job" -o jsonpath='{.metadata.creationTimestamp}')" || {
    printf 'could not read creationTimestamp for job/%s; refusing to treat it as evidence\n' "$job" >&2
    return 1
  }
  [[ -n "$created" ]] || {
    printf 'job/%s reported an empty creationTimestamp; refusing to treat it as evidence\n' "$job" >&2
    return 1
  }
  created_epoch="$(date -u -d "$created" +%s)" || {
    printf 'could not parse creationTimestamp %q for job/%s\n' "$created" "$job" >&2
    return 1
  }
  if ((created_epoch < run_start_epoch - skew)); then
    printf 'job/%s predates this run (created %s, run started %s): it is a terminal Job carrying an OLD verdict, not a proof of the estate as it is now\n' \
      "$job" "$created" "$(date -u -d "@$run_start_epoch" +%Y-%m-%dT%H:%M:%SZ)" >&2
    printf 'a Complete Job stays Complete forever, so waiting on one this run did not create proves nothing\n' >&2
    return 1
  fi
}

if [[ "${BAO_PROOF_RECREATE:-1}" == 1 ]]; then
  recreate_proof_jobs
fi

kubectl -n "$namespace" wait "job/$positive" --for=condition=complete --timeout="$timeout"
kubectl -n "$namespace" wait "job/$negative" --for=condition=complete --timeout="$timeout"

assert_job_fresh "$positive"
assert_job_fresh "$negative"

# Read into a variable rather than piping into `grep -q`. Under `set -o
# pipefail` a quiet grep that matches EARLY exits first, the producer takes
# SIGPIPE, and the pipeline reports 141 — so a PRESENT marker could be read as
# absent. It never fired here because the log is short enough that grep consumes
# it all, which is exactly the kind of luck that stops holding in production.
negative_logs="$(kubectl -n "$namespace" logs "job/$negative" -c jwt-svid)"
if ! grep -Fq 'denied as expected' <<<"$negative_logs"; then
  echo 'negative Bao/SPIRE proof did not emit its denial marker' >&2
  exit 1
fi
printf 'bounded Bao/SPIRE positive and negative identity proof passed\n'
