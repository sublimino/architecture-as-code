package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	evidenceverify "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/store/verify"
)

type keyPaths []string

func (paths *keyPaths) String() string { return fmt.Sprint([]string(*paths)) }
func (paths *keyPaths) Set(value string) error {
	if value == "" {
		return errors.New("public key path cannot be empty")
	}
	*paths = append(*paths, value)
	return nil
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("segment-verify", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var cfg evidenceverify.Config
	var keys keyPaths
	var auditOnly bool
	flags.StringVar(&cfg.EvidenceDir, "evidence-dir", "", "segment evidence directory")
	flags.StringVar(&cfg.SegmentRoot, "segment-root", "", "persisted segment root")
	flags.StringVar(&cfg.HighWaterPath, "highwater", "", "externally protected highwater file")
	flags.Var(&keys, "public-key", "trusted public key PEM (Ed25519, ECDSA, RSA; repeatable)")
	flags.BoolVar(&auditOnly, "audit-only", false, "report partial or empty corpus without accepting it")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("segment-verify accepts flags only")
	}
	cfg.PublicKeyPaths = keys
	result, err := evidenceverify.VerifyCorpus(ctx, cfg)
	if err != nil {
		return err
	}
	if !auditOnly && result.IntegrityScope != evidenceverify.IntegrityScopeComplete {
		return fmt.Errorf("partial integrity scope is not accepted; use -audit-only to report it")
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(result)
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintln(os.Stderr, "segment-verify:", err)
		os.Exit(1)
	}
}
