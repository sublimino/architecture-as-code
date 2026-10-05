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
    export LIVE_PORT="${KUSARI_LIVE_PORT:-28094}"
    export LIVE_LIMIT="${KUSARI_LIVE_LIMIT:-5000}"
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

# observations fetches the observation list through a port-forward and writes it
# to $1. 3>&- keeps the port-forward off bats' fd 3, which otherwise makes bats
# wait for it.
observations() {
    local out="$1" pf code
    local h="${BATS_TEST_TMPDIR}/reader.hdr"
    reader_hdr "$h" || return 1

    kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" port-forward svc/signal-ingest "${LIVE_PORT}:8082" \
        >/dev/null 2>&1 3>&- &
    pf=$!
    local ready=
    for _ in $(seq 1 40); do
        if curl -sf -o /dev/null "http://127.0.0.1:${LIVE_PORT}/readyz"; then ready=1; break; fi
        sleep 0.25
    done
    if [ -z "$ready" ]; then
        kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
        echo "signal-ingest did not become ready through the port-forward" >&2
        return 1
    fi

    code="$(curl -s -o "$out" -w '%{http_code}' -H @"$h" \
        "http://127.0.0.1:${LIVE_PORT}/api/v1/observations?limit=${LIVE_LIMIT}")"
    kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null

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

# repo_rule_ids lists every rule id the repo's kusari bundles declare. Derived,
# never hardcoded: a rule added to a bundle must not silently drop out of the
# "no unknown rule is firing" assertion below.
repo_rule_ids() {
    yq -r '.rules[].id' "${BUNDLE_DIR}"/*.yaml | sort -u
}

# repo_bundle_identities lists "<id>@<version>" per repo bundle.
repo_bundle_identities() {
    yq -r '.id + "@" + .version' "${BUNDLE_DIR}"/*.yaml | sort -u
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
        jq -r --arg k "$key" '.data[$k]' "${BATS_TEST_TMPDIR}/cm.json" >"${BATS_TEST_TMPDIR}/${key}"
        diff -u "$f" "${BATS_TEST_TMPDIR}/${key}" \
            || { echo "the reconciled ${key} differs from the tree"; return 1; }
    done
}

@test "live: signal-ingest loaded both kusari bundles at boot" {
    live_or_skip
    run kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" logs deploy/signal-ingest --since=168h
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    printf '%s' "$output" >"${BATS_TEST_TMPDIR}/ingest.log"

    local id
    while read -r id; do
        grep -qF "bundle=${id%@*}" "${BATS_TEST_TMPDIR}/ingest.log" \
            || { echo "no 'observation-policy bundle loaded' line for ${id}; the pod may predate the bundle or POLICY_BUNDLES_DIR is unset"; return 1; }
    done < <(repo_bundle_identities)

    # The loader warns rather than failing when the directory is absent, so the
    # warning is the thing to look for: it means the control is wired to nothing.
    if grep -qF 'bundle directory does not exist' "${BATS_TEST_TMPDIR}/ingest.log"; then
        echo "signal-ingest logged that its bundle directory does not exist; no finding can be produced by any collector"
        return 1
    fi
}

@test "live: tenant kusari has findings, and every rule that fired is declared in this tree" {
    live_or_skip
    observations "${BATS_TEST_TMPDIR}/obs.json"

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
    observations "${BATS_TEST_TMPDIR}/obs.json"

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
        echo "the extra-signal fixtures live under collectors/awslogs/testdata/kusari/ and are not in"
        echo "awslogs.FixtureFiles(), so fixture mode does not replay them. See docs/EAP/kusari-e2e.md."
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
    observations "${BATS_TEST_TMPDIR}/obs.json"

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
    observations "${BATS_TEST_TMPDIR}/obs.json"

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
        echo "decisions cite finding ids that are not in the store (within the last ${LIVE_LIMIT} rows):"
        echo "$missing"
        echo "If the store has rolled past them this is expected -- raise KUSARI_LIVE_LIMIT and re-run."
        return 1
    }
}

@test "live: the evidence-reader key cannot write" {
    live_or_skip
    # The read this suite performs must not be usable to inject an observation,
    # or the suite itself becomes a write path into the tenant's evidence.
    local h="${BATS_TEST_TMPDIR}/reader.hdr" pf code
    reader_hdr "$h"

    kubectl --context "${WL_CONTEXT}" -n "${INGEST_NS}" port-forward svc/signal-ingest "${LIVE_PORT}:8082" \
        >/dev/null 2>&1 3>&- &
    pf=$!
    for _ in $(seq 1 40); do curl -sf -o /dev/null "http://127.0.0.1:${LIVE_PORT}/readyz" && break; sleep 0.25; done
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H @"$h" \
        -H 'Content-Type: application/json' --data-binary '{"observations":[]}' \
        "http://127.0.0.1:${LIVE_PORT}/api/v1/observations")"
    kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null

    [ "$code" = 403 ] || {
        echo "POST with the evidence-reader key returned ${code}, want 403"
        return 1
    }
}
