package obscel

import (
	"context"
	"errors"
	"fmt"
	"sort"
)

// evaluator is the in-process stage-1 implementation of Evaluator.
type evaluator struct {
	compiler *Compiler
}

// NewEvaluator returns the shared in-process stage-1 evaluator (ISC-40). One
// instance is intended to be long-lived and shared: the program cache is what
// keeps per-observation cost at evaluation rather than compilation.
func NewEvaluator() (Evaluator, error) {
	c, err := NewCompiler()
	if err != nil {
		return nil, err
	}
	return &evaluator{compiler: c}, nil
}

// SortedRules returns a bundle's rules in canonical (sorted rule ID) order.
// Rule order is part of the determinism contract: evaluating in slice or map
// order makes two replays of the same backlog disagree on finding order.
func SortedRules(b *Bundle) []Rule {
	if b == nil {
		return nil
	}
	rules := append([]Rule(nil), b.Rules...)
	sort.Slice(rules, func(i, j int) bool { return rules[i].ID < rules[j].ID })
	return rules
}

// EvaluateObservation evaluates every rule in the bundle against one
// observation and returns the findings for the rules that matched.
//
// Fault isolation is the point of the signature. A rule whose expression fails
// to compile or evaluate is an evaluator fault: it contributes NO finding, the
// fault is joined into the returned error, and every other rule still runs. A
// single malformed rule therefore cannot suppress detections from its
// neighbours, and the caller still learns that the bundle is partially broken.
//
// A rule that evaluates cleanly to false is not an error.
func (e *evaluator) EvaluateObservation(obs Observation, b *Bundle) ([]Finding, error) {
	if b == nil {
		return nil, fmt.Errorf("obscel: nil bundle")
	}

	activation := Activation(obs, b.Vars)
	var findings []Finding
	var faults []error

	for _, rule := range SortedRules(b) {
		prg, err := e.compiler.Compile(rule.Expression)
		if err != nil {
			faults = append(faults, fmt.Errorf("rule %q: %w", rule.ID, err))
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), EvalTimeout)
		out, _, err := prg.ContextEval(ctx, activation)
		cancel()
		if err != nil {
			faults = append(faults, fmt.Errorf("rule %q: evaluation error: %w", rule.ID, err))
			continue
		}

		matched, ok := out.Value().(bool)
		if !ok {
			faults = append(faults, fmt.Errorf("rule %q: expression evaluated to non-boolean type %T", rule.ID, out.Value()))
			continue
		}
		if !matched {
			continue
		}

		findings = append(findings, NewFinding(obs, b, rule))
	}

	return findings, errors.Join(faults...)
}

// NewFinding builds a Finding from a matched rule. Every derived field comes
// from the determinism contract in doc.go: the ID is sha256 over
// tenant | rule | bundle version | source observation, and the timestamp is the
// observation's own, never time.Now().
func NewFinding(obs Observation, b *Bundle, rule Rule) Finding {
	return Finding{
		ID:            FindingID(obs.TenantID, rule.ID, b.Version, obs.ID),
		Timestamp:     obs.Timestamp,
		TenantID:      obs.TenantID,
		Actor:         obs.Actor,
		RuleID:        rule.ID,
		BundleID:      b.ID,
		BundleVersion: b.Version,
		Severity:      rule.Severity,
		SourceObsID:   obs.ID,
		Labels:        copyLabels(obs.Labels),
	}
}

// copyLabels returns a defensive copy so a finding cannot be mutated through
// the observation it came from (or vice versa) after it has been emitted.
// Serialisation order is imposed by SortedLabelKeys/CanonicalFinding, not by
// the map, because Go map iteration order is deliberately random.
func copyLabels(in map[string]string) map[string]string {
	if in == nil {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
