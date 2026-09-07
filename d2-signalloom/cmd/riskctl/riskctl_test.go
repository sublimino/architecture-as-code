package main

import (
	"os/exec"
	"strings"
	"testing"
)

func TestRiskctlCLI(t *testing.T) {
	cmd := exec.Command("go", "run", "-C", "../../../tools/riskctl", ".", "--help")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("riskctl --help failed: %v, output: %s", err, string(out))
	}
	output := string(out)
	if !strings.Contains(output, "riskctl") {
		t.Errorf("unexpected --help output: %s", output)
	}
}
