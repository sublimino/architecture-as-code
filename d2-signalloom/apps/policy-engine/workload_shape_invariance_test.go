package main

// The controller-wrapping invariance property: wrapping any pod-shaped CIS
// fixture in any supported controller kind must not change a single verdict.
// This is the invariant the whole fixture estate silently assumed and never
// tested. Helpers live in workload_shape_scan_test.go.

import "testing"

// The property the whole fixture estate silently assumed: wrapping a
// pod-shaped fixture in any supported controller kind must not change a single
// verdict. Fixtures without a `spec` map are excluded — they are deliberately
// malformed pods and there is no pod template to wrap.
func TestScanGuard_ControllerWrappingPreservesVerdicts(t *testing.T) {
	root := conformancePolicyRoot(t)
	s := newCISScanner(t)

	var pods []conformanceFixture
	skipped := 0
	for _, p := range loadConformancePacks(t, root) {
		if p.fw.ID != cisPackID {
			continue
		}
		for _, f := range p.fixtures {
			if _, ok := f.Input.Object["spec"].(map[string]any); !ok {
				skipped++
				continue
			}
			pods = append(pods, roundTripFixtureInput(t, f))
		}
	}
	if len(pods) < 20 {
		t.Fatalf("only %d pod-shaped CIS fixtures found (%d skipped): the property would be near-vacuous", len(pods), skipped)
	}

	sawFail := false
	for _, f := range pods {
		want := s.verdicts(t, f.Input.Object)
		if tally(want)[VerdictFail] > 0 {
			sawFail = true
		}
		for _, kind := range controllerKinds {
			got := s.verdicts(t, wrapInController(kind, f.Input.Object))
			for _, d := range diffVerdicts(want, got) {
				t.Errorf("%s wrapped in %s: %s", f.Name, kind, d)
			}
		}
	}
	if !sawFail {
		t.Error("no fixture produced a fail: the invariance property is vacuous")
	}
	t.Logf("controller-wrapping invariance: %d pod-shaped CIS fixtures × %d kinds = %d wrapped scans (%d fixtures skipped: no spec map)",
		len(pods), len(controllerKinds), len(pods)*len(controllerKinds), skipped)
}
