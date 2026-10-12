#!/usr/bin/env bats
#
# test/demo-mission-honesty.bats — the operator-facing demo may print only what it measured.
#
# ═══ Why this file exists ═══════════════════════════════════════════════════
#
# `scripts/demo-crkc-mission.sh` is the script someone runs in front of an
# audience. It is therefore the highest-blast-radius surface in the repository:
# every other fabrication in this estate is read by an engineer who can check
# it, and this one is read aloud to a room that cannot.
#
# Four verified fabrications were removed from it, and this suite is the guard
# that stops each from returning:
#
#   1. A hardcoded closing banner. Five figures — "100% Green", a killswitch
#      p95, a FAIR latency, a 100.0% packet drop rate, a 100.0% label retention
#      rate — printed as plain string literals with no shell expansion anywhere
#      in them. The script CONTRADICTED ITSELF: it measured a value into
#      ${CALC_MS}, printed it, and then printed an unrelated constant for the
#      same metric four lines later.
#
#   2. A real computation invoked, discarded, and replaced by a typed figure.
#      `tools/riskctl/riskctl baseline > /dev/null 2>&1 || true` followed by an
#      echo of "ALE £13,346.97, VaR95 £308,558.93". Three compounding defects:
#      output to /dev/null, failure swallowed by `|| true`, and the binary is
#      not committed — so that invocation had never once succeeded. The two
#      figures are each real riskctl outputs, but from DIFFERENT agents
#      (ALE from agent-remediation@2.1.0, VaR95 from agent-olly-sentinel@2.1.0);
#      no single invocation can produce the pair. The real VaR95 for the agent
#      named is £0 and the real verdict is `denied`.
#
#   3. Timing the wrong thing. `sum(x**0.5 for x in range(20000))` under a
#      comment calling it an OpenFAIR stochastic draw. The clock was honest;
#      the thing on the clock was not the product.
#
#   4. An existence check presented as evidence verification. `[ -f ... ]`
#      under a phase heading reading "Verification of Demo Artifacts &
#      Evidence". A file being on disk is not a measurement of anything.
#
# ═══ The invariant, stated once ═════════════════════════════════════════════
#
# A figure is real iff it is a function of this run's inputs. One that cannot be
# derived here must be REFUSED — printed as UNAVAILABLE with a reason — never
# replaced by a better-chosen constant or a sensible default.
#
# Test 2 is the general form and the one that matters: every metric-shaped token
# in the script's OUTPUT must be absent from its SOURCE. A measured value
# reaches stdout through a variable and so cannot appear as a source literal; a
# fabricated one is a source literal by construction. The test needs no
# allow-list because the script prints no thresholds — a declared threshold is
# a requirement, not a measurement, and belongs in the benchmarks contract.

setup() {
    repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
    demo="$repo_root/scripts/demo-crkc-mission.sh"
    repro="$repo_root/scripts/verify-demo-reproducibility.sh"
    bench="$repo_root/docs/signalloom/benchmarks/mission-benchmarks.json"
}

# A metric-shaped token is a currency amount, a millisecond figure, or a
# percentage. Deliberately NOT "any number" — a digest, a pack version, an
# iteration count and a timestamp are identifiers, not measurements.
METRIC_RE='£[0-9][0-9,]*(\.[0-9]+)?|[0-9]+(\.[0-9]+)?(ms|%)'

@test "demo script source carries no metric-shaped literal" {
    [ -f "$demo" ]
    run grep -oE "$METRIC_RE" "$demo"
    [ "$status" -ne 0 ] || {
        printf 'metric-shaped literals in the demo source:\n%s\n' "$output" >&2
        printf 'Every figure the demo prints must come from this run. Remove the literal\n' >&2
        printf 'or move it to the benchmarks contract as a declared threshold.\n' >&2
        return 1
    }
}

@test "demo script output contains no figure that is also a literal in its source" {
    [ -x "$demo" ]
    run "$demo"
    [ "$status" -eq 0 ]
    local tok leaked=""
    while read -r tok; do
        [ -n "$tok" ] || continue
        if grep -qF -- "$tok" "$demo"; then
            leaked="${leaked}${tok}"$'\n'
        fi
    done < <(printf '%s\n' "$output" | grep -oE "$METRIC_RE" || true)
    if [ -n "$leaked" ]; then
        printf 'the demo printed figures that are literals in its own source:\n%s\n' "$leaked" >&2
        printf 'A measured value reaches stdout through a variable and cannot be a source\n' >&2
        printf 'literal. A value that is both is theatre.\n' >&2
        return 1
    fi
}

@test "demo script prints no unmeasured success banner" {
    run grep -nE '100% Green|Completed Successfully|100\.0%|p95:' "$demo"
    [ "$status" -ne 0 ] || {
        printf 'unmeasured banner text survives:\n%s\n' "$output" >&2
        return 1
    }
}

@test "demo script never swallows a failed computation" {
    run grep -nE '\|\|[[:space:]]*true|> ?/dev/null 2>&1' "$demo"
    [ "$status" -ne 0 ] || {
        printf 'a computation whose failure cannot be seen:\n%s\n' "$output" >&2
        printf 'If the figure matters, a failure to produce it must be a failure.\n' >&2
        return 1
    }
}

@test "demo script does not present artefact presence as verification" {
    # The defect: `[ -f ... ]` under a heading reading "Verification of Demo
    # Artifacts & Evidence". Presence may be reported; it may not be called
    # verification, and it may not be called evidence.
    run grep -niE '^echo.*(Verification|Evidence).*(Artifact|Artefact)' "$demo"
    [ "$status" -ne 0 ] || {
        printf 'a presence check announced as verification:\n%s\n' "$output" >&2
        return 1
    }
    run "$demo"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qi 'presence' || {
        printf 'the artefact phase must name itself a presence check\n' >&2
        return 1
    }
}

@test "demo script does not delegate to the simulated freeze benchmark" {
    # test/bench-redteam-stress.sh derives its figure from a modulo of a python
    # loop duration and hardcodes its p95. It is a known fabrication owned
    # elsewhere (P6-1). Whatever it is worth, it must not reach an audience
    # through this script, which presents its output as a benchmark.
    run grep -n 'bench-redteam-stress' "$demo"
    [ "$status" -ne 0 ] || {
        printf 'the demo delegates to a simulated benchmark:\n%s\n' "$output" >&2
        return 1
    }
}

@test "demo script refuses the three metrics with no producer" {
    run "$demo"
    [ "$status" -eq 0 ]
    local m
    for m in "Killswitch" "packet drop" "label retention"; do
        printf '%s\n' "$output" | grep -qi -- "$m" || {
            printf 'the demo no longer mentions %s at all; it must REFUSE it, not drop it\n' "$m" >&2
            return 1
        }
    done
    [ "$(printf '%s\n' "$output" | grep -c 'UNAVAILABLE')" -ge 3 ] || {
        printf 'fewer than three UNAVAILABLE refusals in the output\n' >&2
        return 1
    }
    printf '%s\n' "$output" | grep -q 'reason:' || {
        printf 'a refusal with no reason is not honest degradation\n' >&2
        return 1
    }
}

@test "demo script reports the real riskctl exposure including a zero and a denial" {
    run "$demo"
    [ "$status" -eq 0 ]
    # The honest output for the agent the demo names is ALE £13,346.97,
    # VaR95 £0.00 (tail-dominated) and tier `denied`. Theatre replaced the zero
    # with another agent's VaR95 and hid the denial. Both must be visible.
    printf '%s\n' "$output" | grep -qi 'VaR95' || {
        printf 'no VaR95 reported\n' >&2; return 1; }
    printf '%s\n' "$output" | grep -qiE 'tier|verdict' || {
        printf 'the riskctl tier verdict is not shown; a denial must not be hidden\n' >&2
        return 1
    }
    printf '%s\n' "$output" | grep -q 'riskctl risk' || {
        printf 'the exact reproducing command must be printed with the figures\n' >&2
        return 1
    }
}

@test "demo script fails loudly when the risk engine is unavailable" {
    RISKCTL_BIN=/nonexistent/riskctl run "$demo"
    [ "$status" -ne 0 ] || {
        printf 'the demo exited 0 with no risk engine; a missing producer must be fatal\n' >&2
        return 1
    }
}

@test "benchmarks json carries no percentile ladder" {
    [ -f "$bench" ]
    run grep -nE '"p(50|90|95|99)_ms"' "$bench"
    [ "$status" -ne 0 ] || {
        printf 'authored percentile ladders survive:\n%s\n' "$output" >&2
        printf 'A distribution cannot be authored. Four quantiles of a run that never\n' >&2
        printf 'happened are the clearest possible tell.\n' >&2
        return 1
    }
}

@test "benchmarks json carries no authored unit rate or PASS verdict" {
    run grep -nE '"(drop_rate|retention_rate|parity_rate|dropped_pps|latency_to_drop_ns|labels_retained)"|"status": *"PASS"|"verdict"' "$bench"
    [ "$status" -ne 0 ] || {
        printf 'authored measurements and verdicts survive:\n%s\n' "$output" >&2
        return 1
    }
}

@test "every benchmarks json entry declares its evidence state and a reason or provenance" {
    run python3 - "$bench" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
bad = []
entries = doc.get("benchmarks", {})
if not entries:
    bad.append("no benchmark entries at all")
for name, e in entries.items():
    state = e.get("evidence_state")
    if state not in ("measured", "unavailable"):
        bad.append(f"{name}: evidence_state={state!r} (want 'measured' or 'unavailable')")
        continue
    if state == "unavailable":
        if not e.get("reason"):
            bad.append(f"{name}: unavailable with no reason")
        for k, v in e.items():
            if k.endswith(("_ms", "_pps", "_rate", "_ns")) and isinstance(v, (int, float)) \
               and not k.startswith(("sla_", "internal_target")):
                bad.append(f"{name}: unavailable but still carries a figure {k}={v}")
    else:
        if not e.get("provenance"):
            bad.append(f"{name}: measured with no provenance command")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{len(entries)} benchmark entries, all declared")
PY
    [ "$status" -eq 0 ] || {
        printf '%s\n' "$output" >&2
        return 1
    }
}

@test "reproducibility script asserts no authored literal against an authored threshold" {
    [ -f "$repro" ]
    run grep -nE "p95_ms|demonstration_status|step\['status'\]|== 'SUCCESS'" "$repro"
    [ "$status" -ne 0 ] || {
        printf 'tautological assertions survive:\n%s\n' "$output" >&2
        printf 'Asserting that a literal you typed satisfies a threshold you typed cannot fail.\n' >&2
        return 1
    }
}

@test "reproducibility script compares derived figures between the two cycles" {
    run grep -nE 'diff|cmp |CYCLE1|cycle1' "$repro"
    [ "$status" -eq 0 ] || {
        printf 'the reproducibility harness runs the demo twice and compares nothing\n' >&2
        return 1
    }
}
