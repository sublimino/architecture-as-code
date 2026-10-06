#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      kusari-e2e-live
# @target  d2-signalloom/apps/signal-ingest/e2e (the offline suite this mirrors)
# @doc     docs/EAP/kusari-e2e.md
# @spec    SLAWS v2 §3, §4, D3, D6 -- stage 1 and stage 2 over AWS telemetry
#
# The LIVE tier of the Kusari AWS signal e2e.
#
# `make test-kusari-e2e` proves the pipeline offline, against the bundle FILES.
# It cannot prove that the bundles Flux reconciled into the cluster are those
# files, or that the running signal-ingest is producing findings from them. That
# is what this does, and it is the whole of its scope: it OBSERVES, it never
# writes an observation and never edits a cluster object.
#
# It runs only when KUSARI_LIVE=1 and a real KUBECONFIG is set, and skips
# cleanly otherwise -- so it is safe to leave in a suite that runs on a laptop.
# The skip message names both conditions, because a test that skips for an
# unstated reason is indistinguishable from a test that passed.
#
# Keys never touch argv: curl gets the evidence-reader token from a 0600 header
# FILE, so it cannot appear in /proc/*/cmdline or in shell history.
#
# WHY THE READER KEY. The read route needs observations:read, which the probe and
# collector keys do not carry (they are write-only by design -- see
# test/sltm-probe-apikey.bats). sldc-evidence-reader is the named read key, held
# in Secret signal-ingest-key-sldc-evidence-reader in fe-signalloom.

bats_require_minimum_version 1.5.0

setup_file() {
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    export BUNDLE_DIR="${REPO_ROOT}/policy/bundles/kusari"
    export WL_CONTEXT="${WL_CONTEXT:-kind-osramp}"
    export INGEST_NS="${INGEST_NS:-fe-signalloom}"
    export READER_SECRET="${READER_SECRET:-signal-ingest-key-sldc-evidence-reader}"
    # Empty LIVE_PORT lets kubectl pick a free local port. A fixed default
    # collided with a port-forward another session had left bound, so the test
    # silently curled someone else's tunnel.
    export LIVE_PORT="${KUSARI_LIVE_PORT:-}"
    # The observations route caps a page at MaxPageSize (100 by default; it
    # answers 400 above that) and has no cursor, so one page is all a read gets.
    export LIVE_LIMIT="${KUSARI_LIVE_LIMIT:-100}"
}

# live_or_skip gates every test in this file. KUBECONFIG=/dev/null is the value
# the offline suites set, so it is treated as "no cluster" rather than as a
# cluster that happens to be empty.
live_or_skip() {
    [ "${KUSARI_LIVE:-}" = 1 ] && [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG}" != /dev/null ] \
        || skip "live tier: set KUSARI_LIVE=1 and a real KUBECONFIG (currently KUSARI_LIVE='${KUSARI_LIVE:-}', KUBECONFIG='${KUBECONFIG:-}')"
    need kubectl
    need jq
    need yq
    need curl
}

# need fails rather than skips on a missing tool. Once the operator has asked for
# the live tier, a silent skip would report "nothing to see here" for a missing
# binary, which is the one answer that is never true.
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "live tier requires $1 on PATH" >&2
        return 1
    }
}

# hdr writes an Authorization header into a 0600 file.
hdr() {
    ( umask 077; printf 'Authorization: Bearer %s\n' "$2" >"$1" )
}

# reader_hdr puts the evidence-reader key into a header file. The key is read
# into a local and interpolated into a redirect, never passed as an argument.
reader_hdr() {
    local k
    k="$(kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" get secret "${READER_SECRET}" \
        -o 'jsonpath={.data.token}' 2>/dev/null | base64 -d || true)"
    [ -n "$k" ] || {
        echo "no token in ${INGEST_NS}/${READER_SECRET}; mint it with scripts/sldc-ingest-bearer.sh --context ${WL_CONTEXT} --key sldc-evidence-reader" >&2
        return 1
    }
    hdr "$1" "$k"
}

# pf_start opens a port-forward to svc/signal-ingest:8082 and sets PF_PID and
# PF_URL. Readiness is kubectl's own "Forwarding from" line, not a GET /readyz:
# on 8082 every route is behind the API-key router, so /readyz answers 401/403
# to the reader key (the kubelet probes it on the separate probe port 8083),
# and each denied poll is an audit row in the shared cluster. A port-forward
# that exits (bind failure, no endpoints) fails here with kubectl's own words.
# 3>&- keeps the port-forward off bats' fd 3, which otherwise makes bats wait.
pf_start() {
    local log="${BATS_TEST_TMPDIR}/port-forward.log" port
    : >"$log"
    kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" port-forward svc/signal-ingest "${LIVE_PORT}:8082" \
        >"$log" 2>&1 3>&- &
    PF_PID=$!
    for _ in $(seq 1 40); do
        port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 8082$/\1/p' "$log" | head -n1)"
        [ -n "$port" ] && break
        kill -0 "$PF_PID" 2>/dev/null || break
        sleep 0.25
    done
    if [ -z "$port" ]; then
        pf_stop
        echo "port-forward to ${INGEST_NS}/svc/signal-ingest:8082 did not come up: $(cat "$log")" >&2
        return 1
    fi
    PF_URL="http://127.0.0.1:${port}"
}

# pf_stop ends the port-forward. A killed kubectl exits 143, which is the
# expected outcome here and must not trip bats' errexit.
pf_stop() {
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
}

# observations_window fetches one page of the observation list through a
# port-forward and writes it to $1. $2/$3, if non-empty, are RFC3339
# after/before filters appended to the query string -- there is no cursor,
# only the after/before time filters handled by
# d2-signalloom/apps/signal-ingest/api/handlers.go:544-560.
observations_window() {
    local out="$1" after="${2:-}" before="${3:-}" code url
    local h="${BATS_TEST_TMPDIR}/reader.hdr"
    reader_hdr "$h" || return 1
    pf_start || return 1

    url="${PF_URL}/api/v1/observations?limit=${LIVE_LIMIT}"
    [ -n "$after" ] && url="${url}&after=${after}"
    [ -n "$before" ] && url="${url}&before=${before}"

    code="$(curl -s -o "$out" -w '%{http_code}' -H @"$h" "$url")"
    pf_stop

    [ "$code" = 200 ] || {
        echo "GET /api/v1/observations returned ${code}: $(head -c 400 "$out")" >&2
        return 1
    }
    # The route serialises an empty result as [] and never as null, so a
    # non-array here is a contract break rather than an empty estate.
    jq -e 'type == "array"' "$out" >/dev/null || {
        echo "the observations route did not return a JSON array" >&2
        return 1
    }
}

# _obs_fetch_width fetches the window [max(0,hi-w), hi) into $1 and echoes its
# row count. hi and w are epoch seconds; lo<=0 means "from the beginning" (no
# 'after' sent) -- the server itself folds an absent 'after' down to its own
# retention floor (FrostDBStore.QueryRange, store/frostdb.go), so this never
# under-shoots the true start of the store.
_obs_fetch_width() {
    local out="$1" hi="$2" w="$3" lo lo_ts hi_ts
    lo=$((hi - w))
    if [ "$lo" -le 0 ]; then
        lo_ts=""
    else
        lo_ts="$(date -u -d "@${lo}" +%Y-%m-%dT%H:%M:%SZ)"
    fi
    hi_ts="$(date -u -d "@${hi}" +%Y-%m-%dT%H:%M:%SZ)"
    observations_window "$out" "$lo_ts" "$hi_ts" || return 1
    jq length "$out"
}

# observations_all pages through the WHOLE store and writes the de-duplicated
# union of every window to $1.
#
# Neither store implementation sorts (store/memory.go iterates Append order;
# store/frostdb.go's QueryRange has no ORDER BY, only pushed-down filters --
# store/frostdb.go:479-519), and FrostDB's scan order is not even STABLE:
# two identical, back-to-back, unfiltered requests for the same 100-row page
# returned 18 different ids each way on a live cluster. So a full page's
# membership cannot be trusted at all -- "take the max timestamp on a full
# page and page forward from there" can silently and non-reproducibly drop
# rows that just happened not to make that particular full page.
#
# The only read that is provably complete is one whose result is SHORT: a
# window with fewer than LIVE_LIMIT rows was never truncated (the handler
# only slices when more than `limit` rows matched -- scopeObservations in
# api/tenancy_grants.go), so every row in it, in any order, is present. This
# resolves one such window at a time, working backward from "now":
#   1. Widen w (doubling from 60s) until [hi-w, hi) comes back full, or until
#      w has swallowed everything back to the beginning and is STILL short.
#   2. If it went full, bisect w between the last short value and the first
#      full value to find the maximal short width.
#   3. Re-fetch at that resolved width (the last probe during bisection may
#      itself have been the full one) to get a guaranteed-short page, merge
#      it (de-duplicated by id -- abutting windows can share a boundary row),
#      then continue the sweep with hi set to this window's lower bound.
# A window that is still full even at a resolved width of zero seconds means
# more than LIVE_LIMIT rows share that single second, which time-bisection
# cannot resolve -- that fails loudly, naming it, as does a hard cap of 200
# requests if neither stop condition is ever met.
observations_all() {
    local out="$1"
    local merged="${BATS_TEST_TMPDIR}/obs-merged.json" page="${BATS_TEST_TMPDIR}/obs-page.json"
    local now_epoch hi requests=0
    echo '[]' >"$merged"
    now_epoch="$(date -u +%s)"
    hi=$((now_epoch + 60)) # +60s covers rows created while this very loop runs

    while :; do
        local w=60 w_short=0 w_full=0 page_len lo

        while :; do
            requests=$((requests + 1))
            [ "$requests" -le 200 ] || {
                echo "observations_all: hit the hard cap of 200 requests widening the window; stopping rather than looping forever" >&2
                return 1
            }
            page_len="$(_obs_fetch_width "$page" "$hi" "$w")" || return 1
            if [ "$page_len" -lt "${LIVE_LIMIT}" ]; then
                w_short=$w
                [ "$((hi - w))" -le 0 ] && { w_full=0; break; }
                w=$((w * 2))
                continue
            fi
            w_full=$w
            break
        done

        while [ "$((w_full - w_short))" -gt 1 ]; do
            requests=$((requests + 1))
            [ "$requests" -le 200 ] || {
                echo "observations_all: hit the hard cap of 200 requests bisecting the window; stopping rather than looping forever" >&2
                return 1
            }
            local w_mid=$(((w_short + w_full) / 2))
            page_len="$(_obs_fetch_width "$page" "$hi" "$w_mid")" || return 1
            if [ "$page_len" -lt "${LIVE_LIMIT}" ]; then
                w_short=$w_mid
            else
                w_full=$w_mid
            fi
        done

        if [ "$w_short" -eq 0 ] && [ "$w_full" -gt 0 ]; then
            echo "observations_all: even a window of ~1 second ending at $(date -u -d "@${hi}" +%Y-%m-%dT%H:%M:%SZ) is full (${LIVE_LIMIT}+ rows); more than ${LIVE_LIMIT} observations share that second, so paging by time cannot resolve it" >&2
            return 1
        fi

        # The last probe above may have been a FULL one (w_full), so re-fetch at
        # the resolved short width to guarantee $page holds the trustworthy page.
        requests=$((requests + 1))
        [ "$requests" -le 200 ] || {
            echo "observations_all: hit the hard cap of 200 requests re-fetching the resolved window; stopping rather than looping forever" >&2
            return 1
        }
        page_len="$(_obs_fetch_width "$page" "$hi" "$w_short")" || return 1
        [ "$page_len" -lt "${LIVE_LIMIT}" ] || {
            echo "observations_all: the resolved window of width ${w_short}s is still full (${LIVE_LIMIT}+ rows) on re-fetch; the store is not stable enough to page this way" >&2
            return 1
        }

        jq -s '.[0] + .[1] | unique_by(.id)' "$merged" "$page" >"${merged}.tmp" && mv "${merged}.tmp" "$merged"

        lo=$((hi - w_short))
        if [ "$lo" -le 0 ]; then
            break # this window reached all the way back to the beginning: done
        fi
        hi=$lo
    done

    cp "$merged" "$out"
    echo "# observations_all: fetched $(jq length "$out") observation(s) over ${requests} request(s)" >&3
}

# repo_rule_ids lists every rule id the repo's kusari bundles declare. Derived,
# never hardcoded: a rule added to a bundle must not silently drop out of the
# "no unknown rule is firing" assertion below. -N: given several files, yq
# prints a `---` separator between documents, which would read as an id.
repo_rule_ids() {
    yq -N -r '.rules[].id' "${BUNDLE_DIR}"/*.yaml | sort -u
}

# repo_bundle_identities lists "<id>@<version>" per repo bundle.
repo_bundle_identities() {
    yq -N -r '.id + "@" + .version' "${BUNDLE_DIR}"/*.yaml | sort -u
}

@test "live: the kusari bundles Flux reconciled are the bundles in this tree" {
    live_or_skip
    # The ConfigMap is rendered from policy/bundles/ by
    # scripts/render-policy-bundles.sh, keyed <tenant>--<file>. If the cluster's
    # copy differs from the tree, every assertion below is about a policy set
    # nobody can read in git -- so this runs FIRST.
    run kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" get cm policy-engine-bundles -o json
    [ "$status" -eq 0 ] || { echo "$output"; skip "policy-engine-bundles ConfigMap is not reconciled on ${WL_CONTEXT} yet"; }
    printf '%s' "$output" >"${BATS_TEST_TMPDIR}/cm.json"

    local f key
    for f in "${BUNDLE_DIR}"/*.yaml; do
        key="kusari--$(basename "$f")"
        jq -e --arg k "$key" '.data | has($k)' "${BATS_TEST_TMPDIR}/cm.json" >/dev/null \
            || { echo "ConfigMap has no key ${key}; run 'make policy-bundles-render' and let Flux reconcile"; return 1; }
        # -j, not -r: -r appends a newline to a value that already ends in one,
        # which reads as a trailing blank line the ConfigMap does not contain.
        jq -j --arg k "$key" '.data[$k]' "${BATS_TEST_TMPDIR}/cm.json" >"${BATS_TEST_TMPDIR}/${key}"
        diff -u "$f" "${BATS_TEST_TMPDIR}/${key}" \
            || { echo "the reconciled ${key} differs from the tree"; return 1; }
    done
}

@test "live: signal-ingest loaded both kusari bundles at boot" {
    live_or_skip
    run kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" logs deploy/signal-ingest --since=168h
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    printf '%s' "$output" >"${BATS_TEST_TMPDIR}/ingest.log"

    # signal-ingest logs JSON (slog.NewJSONHandler in main.go), so the loaded
    # line is matched on its fields: message, bundle id AND version.
    local id
    while read -r id; do
        jq -R -e --arg b "${id%@*}" --arg v "${id#*@}" \
            'fromjson? | select(.msg == "observation-policy bundle loaded" and .bundle == $b and .version == $v)' \
            "${BATS_TEST_TMPDIR}/ingest.log" >/dev/null \
            || { echo "no 'observation-policy bundle loaded' line for ${id}; the pod may predate the bundle or POLICY_BUNDLES_DIR is unset"; return 1; }
    done < <(repo_bundle_identities)

    # The loader warns rather than failing when the directory is absent, so the
    # warning is the thing to look for: it means the control is wired to nothing.
    if grep -qF 'bundle directory does not exist' "${BATS_TEST_TMPDIR}/ingest.log"; then
        echo "signal-ingest logged that its bundle directory does not exist; no finding can be produced by any collector"
        return 1
    fi
}

# observations_store writes the whole de-duplicated store to $1, paging it once
# per file run (observations_all is ~100 requests) and copying the cached result
# for later tests. The route's single page is a non-deterministic sample of the
# store, so no assertion may rely on it.
observations_store() {
    local cache="${BATS_FILE_TMPDIR}/observations-all.json"
    if [ ! -s "$cache" ]; then
        observations_all "${cache}.tmp" || return 1
        mv "${cache}.tmp" "$cache"
    fi
    cp "$cache" "$1"
}

@test "live: tenant kusari has findings, and every rule that fired is declared in this tree" {
    live_or_skip
    observations_store "${BATS_TEST_TMPDIR}/obs.json"

    jq '[.[] | select(.source == "policy_finding") | select(.labels.tenant_id == "kusari")]' \
        "${BATS_TEST_TMPDIR}/obs.json" >"${BATS_TEST_TMPDIR}/findings.json"
    local n; n="$(jq length "${BATS_TEST_TMPDIR}/findings.json")"
    [ "$n" -gt 0 ] || {
        echo "tenant kusari has no policy_finding rows in the last ${LIVE_LIMIT} observations."
        echo "Either no AWS telemetry has been ingested, or the collector is not running, or the bundles are loaded but nothing matched."
        echo "Sources present: $(jq -r '[.[].source] | unique | join(", ")' "${BATS_TEST_TMPDIR}/obs.json")"
        return 1
    }

    jq -r '[.[].labels.rule_id] | unique | .[]' "${BATS_TEST_TMPDIR}/findings.json" \
        | sort -u >"${BATS_TEST_TMPDIR}/live-rules"
    repo_rule_ids >"${BATS_TEST_TMPDIR}/repo-rules"

    # Every rule that fired must be declared here. A rule id in the cluster that
    # is not in the tree means the pod is running a bundle nobody can review,
    # which is the governance claim D6 rests on.
    local unknown
    unknown="$(comm -23 "${BATS_TEST_TMPDIR}/live-rules" "${BATS_TEST_TMPDIR}/repo-rules")"
    [ -z "$unknown" ] || {
        echo "rule ids fired in the cluster but not declared in ${BUNDLE_DIR}:"
        echo "$unknown"
        return 1
    }

    echo "# tenant kusari: ${n} findings over $(wc -l <"${BATS_TEST_TMPDIR}/live-rules") rule(s):" >&3
    sed 's/^/#   /' "${BATS_TEST_TMPDIR}/live-rules" >&3
}

@test "live: the cloud-signals bundle is detecting, not merely loaded" {
    live_or_skip
    observations_store "${BATS_TEST_TMPDIR}/obs.json"

    # A bundle that loads and never fires is indistinguishable from a bundle
    # that was never shipped, so being loaded is not the claim worth making.
    local n
    n="$(jq '[.[] | select(.source == "policy_finding")
              | select(.labels.tenant_id == "kusari")
              | select(.labels.bundle_id == "kusari-cloud-signals")] | length' \
        "${BATS_TEST_TMPDIR}/obs.json")"
    [ "$n" -gt 0 ] || {
        echo "kusari-cloud-signals has produced no findings."
        echo "If the AWS collector has only replayed the DEFAULT fixture corpus this is expected:"
        echo "the extra-signal fixtures live under collectors/awslogs/testdata/kusari/ and fixture mode"
        echo "replays them only with AWSLOGS_FIXTURE_SET=kusari. See docs/EAP/kusari-e2e.md."
        return 1
    }

    # The version that fired is the version in the tree. A finding carrying an
    # older bundle_version is a pod that has not picked the ConfigMap up.
    local want got
    want="$(yq -r '.version' "${BUNDLE_DIR}/cloud-signals.yaml")"
    got="$(jq -r '[.[] | select(.source == "policy_finding")
                   | select(.labels.bundle_id == "kusari-cloud-signals")
                   | .labels.bundle_version] | unique | join(",")' \
        "${BATS_TEST_TMPDIR}/obs.json")"
    [ "$got" = "$want" ] || {
        echo "cloud-signals findings carry bundle_version '${got}', the tree declares '${want}'"
        return 1
    }
}

@test "live: every stored finding and decision is shadow mode" {
    live_or_skip
    observations_store "${BATS_TEST_TMPDIR}/obs.json"

    # Both shipped bundles are shadow. A warn or enforce row means a promotion
    # reached the cluster without reaching the tree, which is the one thing the
    # staged-enforcement model (D5) must not allow.
    local modes
    modes="$(jq -r '[.[] | select(.source == "policy_finding" or .source == "policy_decision")
                     | select(.labels.tenant_id == "kusari")
                     | .labels.mode] | unique | join(",")' "${BATS_TEST_TMPDIR}/obs.json")"
    [ -n "$modes" ] || skip "no kusari policy rows to check the mode of"
    [ "$modes" = "shadow" ] || {
        echo "kusari policy rows carry modes '${modes}', want only 'shadow'"
        echo "the tree declares: $(yq -r '.id + "=" + .mode' "${BUNDLE_DIR}"/*.yaml | tr '\n' ' ')"
        return 1
    }
}

@test "live: a decision cites the findings it counted, and cites them by id" {
    live_or_skip
    observations_store "${BATS_TEST_TMPDIR}/obs.json"

    jq '[.[] | select(.source == "policy_decision") | select(.labels.tenant_id == "kusari")]' \
        "${BATS_TEST_TMPDIR}/obs.json" >"${BATS_TEST_TMPDIR}/decisions.json"
    [ "$(jq length "${BATS_TEST_TMPDIR}/decisions.json")" -gt 0 ] \
        || skip "no kusari decisions yet; stage 2 fires only when a declared threshold is crossed"

    # count must equal the number of finding ids cited, and each cited id must be
    # a finding that exists. A decision citing evidence that is not there is a
    # number an operator cannot audit.
    jq -r '.[] | [.id, .labels.count, (.labels.finding_ids | split(",") | length)] | @tsv' \
        "${BATS_TEST_TMPDIR}/decisions.json" >"${BATS_TEST_TMPDIR}/counts"
    local id count cited
    while IFS=$'\t' read -r id count cited; do
        [ "$count" = "$cited" ] || {
            echo "decision ${id} claims count=${count} but cites ${cited} finding id(s)"
            return 1
        }
    done <"${BATS_TEST_TMPDIR}/counts"

    jq -r '[.[] | select(.source == "policy_finding") | .id] | .[]' \
        "${BATS_TEST_TMPDIR}/obs.json" | sort -u >"${BATS_TEST_TMPDIR}/finding-ids"
    jq -r '[.[].labels.finding_ids | split(",")] | flatten | unique | .[]' \
        "${BATS_TEST_TMPDIR}/decisions.json" | sort -u >"${BATS_TEST_TMPDIR}/cited-ids"
    local missing
    missing="$(comm -23 "${BATS_TEST_TMPDIR}/cited-ids" "${BATS_TEST_TMPDIR}/finding-ids")"
    [ -z "$missing" ] || {
        echo "decisions cite finding ids that are not in the store (observations_all paged to the end, or to the 200-page cap):"
        echo "$missing"
        echo "Either the citing decision is wrong, or the finding aged out past the retention floor."
        return 1
    }
}

@test "live: the evidence-reader key cannot write" {
    live_or_skip
    # The read this suite performs must not be usable to inject an observation,
    # or the suite itself becomes a write path into the tenant's evidence.
    local h="${BATS_TEST_TMPDIR}/reader.hdr" code
    reader_hdr "$h"
    pf_start

    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H @"$h" \
        -H 'Content-Type: application/json' --data-binary '{"observations":[]}' \
        "${PF_URL}/api/v1/observations")"
    pf_stop

    [ "$code" = 403 ] || {
        echo "POST with the evidence-reader key returned ${code}, want 403"
        return 1
    }
}
