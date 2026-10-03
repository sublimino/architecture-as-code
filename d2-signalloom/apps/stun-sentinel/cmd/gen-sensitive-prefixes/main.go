// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// gen-sensitive-prefixes writes bpf/sensitive_prefixes.h, the kernel copy of
// correlator.DefaultSensitivePrefixes. Run from the stun-sentinel module root:
//
//	go run ./cmd/gen-sensitive-prefixes
//
// then rebuild the probe with `bpf/build.sh sentinel`.
package main

import (
	"fmt"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
)

func main() {
	out, err := correlator.RenderSensitivePrefixesHeader(correlator.DefaultSensitivePrefixes)
	if err != nil {
		fmt.Fprintln(os.Stderr, "gen-sensitive-prefixes:", err)
		os.Exit(1)
	}
	if err := os.WriteFile(correlator.SensitivePrefixesHeaderPath, []byte(out), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "gen-sensitive-prefixes:", err)
		os.Exit(1)
	}
}
