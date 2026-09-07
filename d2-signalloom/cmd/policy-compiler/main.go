package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/policy"
)

func usage() {
	fmt.Fprintf(os.Stderr, `policy-compiler: Declarative CEL-to-Landlock Policy Compiler (CRKC Rule SP-4)

Usage:
  policy-compiler <subcommand> [flags]

Subcommands:
  compile    Compile security invariants YAML into Kubernetes VAP manifests and nono Landlock profiles
  validate   Validate policy invariants schema, AST, SP-4 compliance, and cross-tier equivalence
  verify     Verify deployed artifacts against source invariants for continuous drift detection

Flags for compile:
  -i, --invariants   Path to security invariants YAML manifest (default: config/security-invariants.yaml)
  -o, --out          Output directory for generated artifacts (default: dist/policies)
  -t, --target       Target tier: vap, landlock, or all (default: all)
  --skip-optimize    Disable redundant rule optimization

Flags for validate:
  -i, --invariants   Path to security invariants YAML manifest (default: config/security-invariants.yaml)
  --json             Output detailed diagnostics as JSON

Flags for verify:
  -i, --invariants   Path to security invariants YAML manifest (default: config/security-invariants.yaml)
  -d, --dir          Directory containing deployed artifacts and policies.lock.json (default: dist/policies)
  --json             Output drift report as JSON
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	subcmd := os.Args[1]
	args := os.Args[2:]

	switch subcmd {
	case "compile":
		runCompile(args)
	case "validate":
		runValidate(args)
	case "verify":
		runVerify(args)
	case "-h", "--help", "help":
		usage()
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "error: unknown subcommand %q\n", subcmd)
		usage()
		os.Exit(2)
	}
}

func runCompile(args []string) {
	fs := flag.NewFlagSet("compile", flag.ExitOnError)
	var invPath string
	var outDir string
	var targetStr string
	var skipOpt bool

	fs.StringVar(&invPath, "invariants", "config/security-invariants.yaml", "path to invariants manifest")
	fs.StringVar(&invPath, "i", "config/security-invariants.yaml", "shorthand for -invariants")
	fs.StringVar(&outDir, "out", "dist/policies", "output directory")
	fs.StringVar(&outDir, "o", "dist/policies", "shorthand for -out")
	fs.StringVar(&targetStr, "target", "all", "target tier (vap, landlock, all)")
	fs.StringVar(&targetStr, "t", "all", "shorthand for -target")
	fs.BoolVar(&skipOpt, "skip-optimize", false, "skip rule optimization")
	_ = fs.Parse(args)

	manifest, err := policy.LoadManifest(invPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading manifest: %v\n", err)
		os.Exit(1)
	}

	opts := policy.Options{SkipOptimize: skipOpt}
	switch strings.ToLower(targetStr) {
	case "all", "":
		opts.Targets = []policy.Target{policy.TargetVAP, policy.TargetLandlock}
	case "vap":
		opts.Targets = []policy.Target{policy.TargetVAP}
	case "landlock":
		opts.Targets = []policy.Target{policy.TargetLandlock}
	default:
		fmt.Fprintf(os.Stderr, "error: invalid target %q (must be vap, landlock, or all)\n", targetStr)
		os.Exit(2)
	}

	res, err := policy.Compile(manifest, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error compiling policies: %v\n", err)
		os.Exit(1)
	}

	manifestName := filepath.Base(invPath)
	if err := policy.WriteArtifacts(res, outDir, manifestName); err != nil {
		fmt.Fprintf(os.Stderr, "error writing artifacts to %s: %v\n", outDir, err)
		os.Exit(1)
	}

	fmt.Printf("✓ Compiled %d artifact(s) to %s (invariants digest: %s)\n", len(res.Artifacts), outDir, res.InvariantsDigest)
	for _, a := range res.Artifacts {
		fmt.Printf("  • %-28s [%s] (%s)\n", a.RelPath, a.Target, a.Digest[:18])
	}
	if res.SP4 != nil {
		fmt.Printf("✓ Rule SP-4 (Non-Turing Complete CEL): Compliant (%d expressions checked)\n", res.SP4.Checked)
	}
	if res.Equivalence != nil {
		if res.Equivalence.Equivalent {
			fmt.Printf("✓ Cross-tier equivalence: PASS (%d checks passed)\n", len(res.Equivalence.Probes))
		} else {
			divCount := 0
			for _, d := range res.Equivalence.Domains {
				divCount += len(d.Divergences)
			}
			fmt.Printf("✗ Cross-tier equivalence: FAIL (%d divergences)\n", divCount)
			os.Exit(1)
		}
	}
}

func runValidate(args []string) {
	fs := flag.NewFlagSet("validate", flag.ExitOnError)
	var invPath string
	var jsonOutput bool

	fs.StringVar(&invPath, "invariants", "config/security-invariants.yaml", "path to invariants manifest")
	fs.StringVar(&invPath, "i", "config/security-invariants.yaml", "shorthand for -invariants")
	fs.BoolVar(&jsonOutput, "json", false, "output JSON")
	_ = fs.Parse(args)

	manifest, err := policy.LoadManifest(invPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading manifest: %v\n", err)
		os.Exit(1)
	}

	opts := policy.Options{Targets: []policy.Target{policy.TargetVAP, policy.TargetLandlock}}
	res, err := policy.Compile(manifest, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error during validation compile: %v\n", err)
		os.Exit(1)
	}

	type validationOutput struct {
		InvariantsDigest string                    `json:"invariantsDigest"`
		Valid            bool                      `json:"valid"`
		SP4              *policy.SP4Report         `json:"sp4"`
		Equivalence      *policy.EquivalenceReport `json:"equivalence"`
		Diagnostics      []policy.Diagnostic       `json:"diagnostics,omitempty"`
	}

	valid := (res.SP4 == nil || res.SP4.Compliant) && (res.Equivalence == nil || res.Equivalence.Equivalent)
	out := validationOutput{
		InvariantsDigest: res.InvariantsDigest,
		Valid:            valid,
		SP4:              res.SP4,
		Equivalence:      res.Equivalence,
		Diagnostics:      res.Diagnostics,
	}

	if jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(out)
	} else {
		fmt.Printf("Validation Report for %s\n", invPath)
		fmt.Printf("Invariants Digest: %s\n", res.InvariantsDigest)
		if res.SP4 != nil {
			status := "PASS"
			if !res.SP4.Compliant {
				status = "FAIL"
			}
			fmt.Printf("• Rule SP-4 CEL Non-Turing Completeness: %s (%d expressions checked)\n", status, res.SP4.Checked)
		}
		if res.Equivalence != nil {
			status := "PASS"
			if !res.Equivalence.Equivalent {
				status = "FAIL"
			}
			fmt.Printf("• Cross-Tier Semantic Equivalence: %s\n", status)
		}
		if valid {
			fmt.Println("✓ Manifest is valid and conformant across all tiers")
		} else {
			fmt.Fprintln(os.Stderr, "✗ Manifest validation failed")
			os.Exit(1)
		}
	}
}

func runVerify(args []string) {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	var invPath string
	var dir string
	var jsonOutput bool

	fs.StringVar(&invPath, "invariants", "config/security-invariants.yaml", "path to invariants manifest")
	fs.StringVar(&invPath, "i", "config/security-invariants.yaml", "shorthand for -invariants")
	fs.StringVar(&dir, "dir", "dist/policies", "deployed artifacts directory")
	fs.StringVar(&dir, "d", "dist/policies", "shorthand for -dir")
	fs.BoolVar(&jsonOutput, "json", false, "output JSON")
	_ = fs.Parse(args)

	manifest, err := policy.LoadManifest(invPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading manifest: %v\n", err)
		os.Exit(1)
	}

	opts := policy.Options{Targets: []policy.Target{policy.TargetVAP, policy.TargetLandlock}}
	res, err := policy.Compile(manifest, opts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error compiling policies: %v\n", err)
		os.Exit(1)
	}

	report, err := policy.CheckDrift(res, dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error checking drift: %v\n", err)
		os.Exit(1)
	}

	if jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
	} else {
		if report.InSync {
			fmt.Printf("✓ In-sync: all %d deployed artifact(s) match invariants digest %s\n", report.Checked, report.InvariantsDigest)
		} else {
			fmt.Fprintf(os.Stderr, "✗ Drift detected in %s: %d finding(s)\n", dir, len(report.Findings))
			for _, f := range report.Findings {
				fmt.Fprintf(os.Stderr, "  • [%s] %s: %s\n", f.Kind, f.Path, f.Detail)
			}
			os.Exit(1)
		}
	}
}
