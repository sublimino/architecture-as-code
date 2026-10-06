// Command kusari-synth prints a synthetic Kusari CloudTrail-shaped stream as the
// bare JSON array POST /api/v1/observations accepts, so a live cluster can be seeded
// with recent, deterministic activity for the dashboard review loop and the
// Kusari e2e walkthrough.
//
//	go run ./cmd/kusari-synth -profile all -minutes 30 -rate 4 -recent | \
//	  curl -s -X POST -H @hdr -H 'Content-Type: application/json' --data-binary @- \
//	  http://127.0.0.1:28094/api/v1/observations
//
// -recent moves the corpus base time so the newest event lands at the moment
// the command runs; without it the corpus sits at synth.BaseTime (2026-10-04)
// and the dashboard's 90m windows will not show it.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/collectors/awslogs/synth"
)

func main() {
	seed := flag.Int64("seed", 1, "deterministic seed")
	minutes := flag.Int("minutes", 30, "span of the stream in minutes")
	rate := flag.Int("rate", 4, "baseline events per minute")
	profile := flag.String("profile", string(synth.ProfileAll), "profile: baseline, iam-burst, reject-burst, cross-account, all")
	tenant := flag.String("tenant", "kusari", "tenant_id label")
	region := flag.String("region", "eu-west-2", "aws_region label")
	recent := flag.Bool("recent", false, "shift the base time so the stream ends now")
	flag.Parse()

	if *recent {
		synth.BaseTime = time.Now().UTC().Add(-time.Duration(*minutes) * time.Minute)
	}
	s, err := synth.Generate(*seed, *minutes, *rate, synth.Profile(*profile))
	if err != nil {
		fmt.Fprintln(os.Stderr, "kusari-synth:", err)
		os.Exit(2)
	}
	obs, err := s.Observations(*tenant, *region)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kusari-synth:", err)
		os.Exit(2)
	}
	// The route unmarshals a bare []model.Observation, not an envelope.
	body := obs
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(body); err != nil {
		fmt.Fprintln(os.Stderr, "kusari-synth:", err)
		os.Exit(2)
	}
}
