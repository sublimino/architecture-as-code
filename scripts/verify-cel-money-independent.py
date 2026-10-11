#!/usr/bin/env python3
"""Independent cross-check of the policy engine's priced-risk figures.

WHY THIS EXISTS. The gating oracle for the money is a CLOSED FORM, committed in
Go at d2-signalloom/apps/policy-engine/compliance_money_oracle_test.go: the
beta-PERT mean and variance derived from the distribution's definition, which
pins ALE to within a stated number of standard errors of E[freq]*E[loss]. That
oracle is only as good as its algebra, and its algebra is checked here against
a wholly independent numerical estimate -- NumPy's own Beta sampler, its own
generator, its own quantile routine, no Go code and no port of fair.go.

It also gives the 95th percentile and the tail mean the only independent
treatment available to them. There is no simple closed form for a quantile of a
product of two Beta variates, so the anchor is a BOUND rather than a point
value, and the bound is DERIVED rather than chosen:

  var95. The engine's figure is the order statistic at rank
  k = ceil(0.95*10000) = 9500 of 10,000 i.i.d. draws. The probability level that
  order statistic actually attains is Beta(k, n-k+1)-distributed -- a
  distribution-free fact about sampling, true of ANY correct implementation --
  with mean 0.95 and standard deviation sqrt(p(1-p)/n). So the admissible window
  is [Q(p - z*sd), Q(p + z*sd)] where Q is this script's own independently
  estimated quantile function. Nothing in that derivation consults fair.go.

  tvar. The engine's figure is the mean of the 500 draws above that order
  statistic, so its standard error is the tail standard deviation over
  sqrt(500), estimated here from the same independent sample. The window is the
  union of that interval with the tail means taken at the two level bounds
  above, so it absorbs the threshold's own uncertainty too.

WHAT THAT BOUND CAN AND CANNOT CATCH -- stated because it is the honest limit of
this tier, and it is not a small one. At n=10,000 the level standard deviation
is 0.00218, so a 4.5-sigma window spans levels 0.940 to 0.960, which in VALUE
terms on this estate is roughly +/-4%. An off-by-one percentile index --
percentile(losses, 0.94) instead of 0.95, the exact mutation an adversarial
audit used -- moves the figures by 3 to 5%. It therefore lands INSIDE the
statistical envelope of a correct implementation and no point-estimate
comparison at the engine's sample size can separate the two. This tier catches
an order-of-magnitude error, a lost scale factor, a changed PERT lambda, a
figure read from the wrong triple, or a quantile taken at the wrong end. It
cannot catch a one-rank percentile shift, and nothing statistical can. That
mutation is caught by the DETERMINISTIC golden files plus the guard on how a
golden may be rewritten (TestWriteMoneyGolden), which is why that guard exists.

KNOWN BLIND SPOT, found by mutation: neither this tier nor the Go closed form
can see frequency and magnitude TRANSPOSED, because E[F]*E[M] and the support
product are both symmetric in their arguments. That mutation is caught by the
deterministic golden files instead (the two triples are consumed in a fixed
draw order, so var95 and tvar move). Stated so nobody reads an analytic pass as
a complete one.

NOT part of `make verify-cel`: it needs NumPy, it is statistical rather than
deterministic, and the deterministic golden files plus the Go closed form are
what gate a merge. Run it when a triple, the sampler or the risk load changes.

    make verify-cel-money-independent
"""

from __future__ import annotations

import glob
import json
import math
import os
import sys

# Tolerances. The two on the MEANS are statistical (standard errors of the
# estimator in question); the one on the algebra is a pure-arithmetic check.
MAX_CLOSED_FORM_REL = 0.01  # closed-form mean vs NumPy mean: pure algebra check
MAX_ALE_SIGMA = 5.0  # engine ALE vs closed form, in standard errors
SAMPLES = 1_000_000
ENGINE_ITERATIONS = 10_000  # mirrors fair.iterations on the Simulate path
RISK_LOAD = 0.10

# The quantile bounds are DERIVED from the engine's sample size, not chosen.
# QUANTILE_Z is how many standard deviations of the order statistic's own
# probability level the window spans; 4.5 is a two-sided p of about 7e-6, which
# over ~60 priced checks is a false-alarm rate near 4e-4 per run. The engine is
# deterministic, so a pass today is a pass forever.
QUANTILE_Z = 4.5
VAR_LEVEL = 0.95

GOLDEN_GLOB = "d2-signalloom/apps/policy-engine/testdata/money-golden/*.json"


def moments(t: dict) -> tuple[float, float]:
    """Closed-form mean and variance of a beta-PERT variate over (min, mode, max).

    X = min + span*B with B ~ Beta(a, b), a = 1 + 4*(mode-min)/span,
    b = 1 + 4*(max-mode)/span, so a+b == 6 identically and
    Var[B] = a*b/(6^2 * 7) = a*b/252.
    """
    span = t["max"] - t["min"]
    if span <= 0:
        return t["min"], 0.0
    a = 1 + 4 * (t["mode"] - t["min"]) / span
    b = 1 + 4 * (t["max"] - t["mode"]) / span
    return t["min"] + span * a / 6, span * span * a * b / 252


def is_zero(t: dict) -> bool:
    return t["min"] == 0 and t["mode"] == 0 and t["max"] == 0


def main() -> int:
    try:
        import numpy as np
    except ImportError:
        print("verify-cel-money-independent: NumPy is required for this tier", file=sys.stderr)
        return 2

    paths = sorted(glob.glob(GOLDEN_GLOB))
    if not paths:
        print(f"verify-cel-money-independent: no golden files at {GOLDEN_GLOB}", file=sys.stderr)
        print("run `make verify-cel-money-golden` first", file=sys.stderr)
        return 1

    # Fixed seed: this tier must give the same verdict twice.
    rng = np.random.default_rng(20260801)

    def draw(t: dict, n: int):
        span = t["max"] - t["min"]
        if span <= 0:
            return np.full(n, t["min"])
        a = 1 + 4 * (t["mode"] - t["min"]) / span
        b = 1 + 4 * (t["max"] - t["mode"]) / span
        return t["min"] + span * rng.beta(a, b, n)

    # The admissible probability-level window for a rank-k order statistic of
    # ENGINE_ITERATIONS i.i.d. draws. Beta(k, n-k+1) has mean ~p and standard
    # deviation sqrt(p(1-p)/n); both shape parameters are in the hundreds here,
    # so the normal approximation to its spread is sound (and the window is wide
    # enough that its error does not matter).
    level_sd = math.sqrt(VAR_LEVEL * (1 - VAR_LEVEL) / ENGINE_ITERATIONS)
    level_lo = max(VAR_LEVEL - QUANTILE_Z * level_sd, 0.0)
    level_hi = min(VAR_LEVEL + QUANTILE_Z * level_sd, 1.0)
    tail_n = ENGINE_ITERATIONS - (math.ceil(VAR_LEVEL * ENGINE_ITERATIONS) - 1)

    failures: list[str] = []
    priced = zero = 0
    worst = {"sigma": 0.0, "algebra": 0.0, "var95": 0.0, "tvar": 0.0}
    worst_where = {k: "" for k in worst}
    # The widest admissible window, reported so the LIMIT of this tier is a
    # measured number in the output rather than a claim in a comment.
    widest = {"var95": 0.0, "tvar": 0.0}
    widest_where = {k: "" for k in widest}

    for path in paths:
        with open(path, encoding="utf-8") as fh:
            golden = json.load(fh)
        pack = f"{golden['framework']}@{golden['version']}"
        if golden.get("iterations") != ENGINE_ITERATIONS:
            failures.append(
                f"{pack}: golden records {golden.get('iterations')} iterations, "
                f"this script assumes {ENGINE_ITERATIONS}"
            )
        for row in golden["checks"]:
            where = f"{pack} {row['check']}"
            freq, loss = row["freqTriple"], row["riskTriple"]

            if is_zero(freq):
                zero += 1
                if any(row[k] != 0 for k in ("ale", "var95", "tvar", "carried")):
                    failures.append(f"{where}: zero frequency must price at zero, got {row}")
                continue
            priced += 1

            mf, vf = moments(freq)
            ml, vl = moments(loss)
            closed = mf * ml
            var = max((vf + mf * mf) * (vl + ml * ml) - closed * closed, 0.0)
            se = math.sqrt(var / ENGINE_ITERATIONS)

            z = draw(freq, SAMPLES) * draw(loss, SAMPLES)
            mc_mean = float(z.mean())
            mc_p95 = float(np.quantile(z, 0.95))
            mc_tvar = float(z[z >= mc_p95].mean())

            # 1. The closed form itself, against an independent estimate.
            algebra = abs(mc_mean - closed) / closed
            if algebra > worst["algebra"]:
                worst["algebra"], worst_where["algebra"] = algebra, where
            if algebra > MAX_CLOSED_FORM_REL:
                failures.append(
                    f"{where}: closed-form mean {closed:.2f} disagrees with an independent "
                    f"{SAMPLES}-sample estimate {mc_mean:.2f} by {algebra * 100:.3f}% -- the ALGEBRA is wrong"
                )

            # 2. The engine's ALE, against the closed form.
            sigma = abs(row["ale"] - closed) / se if se > 0 else 0.0
            if sigma > worst["sigma"]:
                worst["sigma"], worst_where["sigma"] = sigma, where
            if sigma > MAX_ALE_SIGMA:
                failures.append(
                    f"{where}: ale {row['ale']:.2f} is {sigma:.2f} sigma from "
                    f"the closed-form mean {closed:.2f}"
                )

            # 3. The quantiles, against a DERIVED admissible window rather than
            #    a chosen tolerance. See the module docstring: the window is the
            #    sampling spread any correct 10,000-iteration implementation
            #    must be allowed, and nothing narrower is honest.
            q_lo = float(np.quantile(z, level_lo))
            q_hi = float(np.quantile(z, level_hi))

            tail = z[z >= mc_p95]
            tvar_se = float(tail.std(ddof=1)) / math.sqrt(tail_n) if tail.size > 1 else 0.0
            tvar_candidates = [
                mc_tvar - QUANTILE_Z * tvar_se,
                mc_tvar + QUANTILE_Z * tvar_se,
                float(z[z >= q_lo].mean()),
                float(z[z >= q_hi].mean()),
            ]
            t_lo, t_hi = min(tvar_candidates), max(tvar_candidates)

            for name, got, want, lo, hi in (
                ("var95", row["var95"], mc_p95, q_lo, q_hi),
                ("tvar", row["tvar"], mc_tvar, t_lo, t_hi),
            ):
                rel = abs(got - want) / want if want else 0.0
                if rel > worst[name]:
                    worst[name], worst_where[name] = rel, where
                width = (hi - lo) / want / 2 if want else 0.0
                if width > widest[name]:
                    widest[name], widest_where[name] = width, where
                if not (lo <= got <= hi):
                    failures.append(
                        f"{where}: {name} {got:.2f} is outside the admissible window "
                        f"[{lo:.2f}, {hi:.2f}] for a {ENGINE_ITERATIONS}-iteration estimate "
                        f"(independent point estimate {want:.2f}, {rel * 100:.2f}% away)"
                    )

            # 4. The risk load, to within the double-rounding of a reported figure.
            if abs(row["carried"] - round(row["tvar"] * (1 + RISK_LOAD), 2)) > 0.011:
                failures.append(
                    f"{where}: carried {row['carried']:.2f} is not tvar "
                    f"{row['tvar']:.2f} plus a {RISK_LOAD:.0%} load"
                )

    print(
        f"==> verify-cel-money-independent: {len(paths)} packs, "
        f"{priced} priced checks, {zero} zero-frequency"
    )
    print(f"    closed form vs independent NumPy mean : max {worst['algebra'] * 100:.4f}%  ({worst_where['algebra']})")
    print(f"    engine ale   vs closed form           : max {worst['sigma']:.2f} sigma ({worst_where['sigma']})")
    print(f"    engine var95 vs independent NumPy p95 : max {worst['var95'] * 100:.3f}%  ({worst_where['var95']})")
    print(f"    engine tvar  vs independent NumPy tail: max {worst['tvar'] * 100:.3f}%  ({worst_where['tvar']})")
    print(
        f"    admissible window (levels {level_lo:.4f}..{level_hi:.4f}, "
        f"{QUANTILE_Z:.1f} sd of the rank-{math.ceil(VAR_LEVEL * ENGINE_ITERATIONS)} order statistic):"
    )
    print(f"      var95: up to +/-{widest['var95'] * 100:.2f}% ({widest_where['var95']})")
    print(f"      tvar : up to +/-{widest['tvar'] * 100:.2f}% ({widest_where['tvar']})")
    print(
        "    LIMIT: that window is the sampling noise of the engine's own "
        f"{ENGINE_ITERATIONS}-iteration quantile. A one-rank percentile shift "
        "(0.95 -> 0.94) moves these figures by a similar amount and therefore "
        "CANNOT be detected here; the deterministic goldens and the update-mode "
        "guard are what catch it."
    )
    if failures:
        print(f"==> verify-cel-money-independent: {len(failures)} divergence(s)", file=sys.stderr)
        for f in failures:
            print(f"    {f}", file=sys.stderr)
        return 1
    print("==> verify-cel-money-independent: the priced figures agree with an independent derivation")
    return 0


if __name__ == "__main__":
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    sys.exit(main())
