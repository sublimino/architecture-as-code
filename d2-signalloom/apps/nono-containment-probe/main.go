package main

import (
	"encoding/json"
	"fmt"
	"os"
)

const (
	defaultWorkspaceReadPath  = "/workspace/test.txt"
	defaultWorkspaceWritePath = "/workspace/probe-result.txt"
)

func main() {
	readPath := envOr("PROBE_READ_PATH", defaultWorkspaceReadPath)
	writePath := envOr("PROBE_WRITE_PATH", defaultWorkspaceWritePath)

	fmt.Fprintln(os.Stderr, "nono-containment-probe: starting containment validation")

	results := runAllProbes(readPath, writePath)
	enc := json.NewEncoder(os.Stdout)

	exitCode := 0
	for _, r := range results {
		if err := enc.Encode(r); err != nil {
			fmt.Fprintf(os.Stderr, "encode result: %v\n", err)
			exitCode = 1
		}
	}

	// Summarise.
	blocked := 0
	allowed := 0
	for _, r := range results {
		if r.Result == "blocked" {
			blocked++
		} else {
			allowed++
		}
	}
	fmt.Fprintf(os.Stderr, "nono-containment-probe: %d blocked, %d allowed (of %d probes)\n",
		blocked, allowed, len(results))

	os.Exit(exitCode)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
