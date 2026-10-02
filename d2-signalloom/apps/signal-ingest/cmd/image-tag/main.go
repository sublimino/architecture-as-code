// Command image-tag prints signal-ingest's immutable image tag (src-<16 hex>) for the source tree
// it is run in, or with -inputs the files that tag is derived from. Run it from the module root:
//
//	go run ./cmd/image-tag
//
// The deployed manifest pins this tag; TestReconciledManifestRunsTheImageBuiltFromThisSource fails
// when the two disagree.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/internal/imagetag"
)

func main() {
	inputs := flag.Bool("inputs", false, "print the build inputs the tag is derived from, one per line")
	flag.Parse()

	if *inputs {
		in, err := imagetag.Inputs(".")
		if err != nil {
			fmt.Fprintln(os.Stderr, "image-tag:", err)
			os.Exit(1)
		}
		for _, p := range in {
			fmt.Println(p)
		}
		return
	}
	tag, err := imagetag.Tag(".")
	if err != nil {
		fmt.Fprintln(os.Stderr, "image-tag:", err)
		os.Exit(1)
	}
	fmt.Println(tag)
}
