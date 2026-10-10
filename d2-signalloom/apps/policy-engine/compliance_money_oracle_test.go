package main

// An INDEPENDENT analytic oracle for the monetary figures a scan reports.
//
// WHY AN ANALYTIC ORACLE AND NOT A SECOND SIMULATION. A line-by-line port of
// fair.go — same PCG generator, same Marsaglia-Tsang rejection sampler, same
// draw order — agrees with fair.go by construction and therefore anchors
// nothing: it is the same claim written twice. What anchors a Monte Carlo
// estimate is the closed form of the quantity it estimates, derived from the
// distribution's definition rather than from its implementation.
//
// WHAT IS DERIVED HERE. fair.samplePERT draws
//
//	X = min + span * B,  B ~ Beta(alpha, beta),
//	alpha = 1 + 4*(mode-min)/span,  beta = 1 + 4*(max-mode)/span,  span = max-min
//
// so alpha+beta is identically 6 for every triple, and the standard Beta
// moments give, in closed form,
//
//	E[X]   = min + span*alpha/6      ( = (min + 4*mode + max)/6, the PERT mean )
//	Var[X] = span^2 * alpha*beta/252  ( 252 = 6^2 * (6+1) )
//
// fair.Simulate's single-scenario path multiplies one frequency draw by one
// magnitude draw per iteration, from the same generator but as independent
// draws, so for the annual loss L = F*M
//
//	E[L]   = E[F]*E[M]
//	Var[L] = (Var[F]+E[F]^2)*(Var[M]+E[M]^2) - (E[F]*E[M])^2
//
// and ALE, being the sample mean of `iterations` such draws, has standard error
// sqrt(Var[L]/iterations). That turns "is the ALE right?" into a statistical
// question with a stated answer instead of a tolerance pulled from the air.
//
// WHAT IT CANNOT ANCHOR. There is no comparably simple closed form for the 95th
// percentile or the tail mean of a product of two Beta variates, so VaR95 and
// TVaR are NOT analytically pinned. They are held by: the golden file (any
// change is a reviewable diff), the support bounds below (a closed-form
// falsifiable constraint), and the ordering properties. That limitation is
// stated rather than papered over.

import (
	"math"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine/fair"
)

// simulateIterations mirrors the unexported fair.iterations used by
// fair.Simulate. It is only used to size the analytic standard error, so a
// drift here loosens or tightens the oracle's tolerance rather than changing
// any figure; TestConformance_MoneyAnalyticAnchor logs the observed spread in
// sigma, which would make a large drift obvious.
const simulateIterations = 10_000

// pertMoments returns the closed-form mean and variance of a beta-PERT variate
// over the triple. A zero-or-negative span is the sampler's degenerate branch:
// it returns min exactly, with no variance.
func pertMoments(t fair.RiskTriple) (mean, variance float64) {
	span := t.Max - t.Min
	if span <= 0 {
		return t.Min, 0
	}
	alpha := 1 + 4*(t.Mode-t.Min)/span
	beta := 1 + 4*(t.Max-t.Mode)/span
	// alpha+beta == 6 identically; 252 == 6^2 * 7.
	return t.Min + span*alpha/6, span * span * alpha * beta / 252
}

// zeroFrequency mirrors fair.Simulate's short-circuit: an all-zero frequency
// triple means no loss event ever happens, so every figure is zero.
func zeroFrequency(freq fair.RiskTriple) bool {
	return freq.Min == 0 && freq.Mode == 0 && freq.Max == 0
}

// analyticALE is E[F*M], the exact expected annual loss for a check's triples.
func analyticALE(loss, freq fair.RiskTriple) float64 {
	if zeroFrequency(freq) {
		return 0
	}
	mf, _ := pertMoments(freq)
	ml, _ := pertMoments(loss)
	return mf * ml
}

// analyticALEStdErr is the standard error of the engine's ALE estimate: the
// standard deviation of one annual-loss draw divided by sqrt(iterations).
func analyticALEStdErr(loss, freq fair.RiskTriple) float64 {
	if zeroFrequency(freq) {
		return 0
	}
	mf, vf := pertMoments(freq)
	ml, vl := pertMoments(loss)
	variance := (vf+mf*mf)*(vl+ml*ml) - (mf*ml)*(mf*ml)
	if variance < 0 { // float noise on a degenerate triple
		variance = 0
	}
	return math.Sqrt(variance / float64(simulateIterations))
}

// analyticSupport is the closed-form support of the annual loss: a beta-PERT
// variate is bounded by its own min and max, so the product is bounded by the
// products of the bounds. Every figure the engine reports — mean, percentile or
// tail mean — must lie inside it. Crude, but it is exact and it is falsifiable:
// a lost scale factor or a figure read from the wrong triple leaves it
// immediately.
//
// KNOWN BLIND SPOT, found by mutation. This oracle cannot see frequency and
// magnitude TRANSPOSED, and neither can analyticALE: E[F]*E[M] and
// freq.Min*loss.Min are both symmetric in their arguments, so swapping the two
// triples is analytically invisible. Transposition IS caught — by the golden
// files, because the two triples are consumed in a fixed draw order so var95
// and tvar move, and by the carried-equals-tvar-plus-10% pin. Stated here so
// nobody mistakes the analytic tier for a complete one.
func analyticSupport(loss, freq fair.RiskTriple) (lo, hi float64) {
	if zeroFrequency(freq) {
		return 0, 0
	}
	return freq.Min * loss.Min, freq.Max * loss.Max
}
