package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Docker is not available in this environment, so these tests do what a build would prove:
// read the Dockerfile and the build script, and check they agree with each other and with the
// tree. A COPY whose source lies outside the declared build context fails at `docker build` with
// "forbidden path outside the build context" -- which nobody sees until a release build runs.
//
// The specific trap: pkg/obscel is a separate module reached by `replace ../../pkg/obscel` in
// go.mod (SLAWS v2 §4.1). The build context used to be d2-signalloom/apps, from which
// ../../pkg/obscel is unreachable, so the first commit that imports obscel would break the image
// build and nothing here would have caught it.

const (
	dockerfilePath   = "Dockerfile"
	imagesScriptPath = "../../../scripts/signalfusion-images.sh"

	// Relative to the repository root. The Dockerfile's COPY sources are relative to this.
	wantBuildContext = "d2-signalloom"
)

func readFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(raw)
}

// TestImageIsBuiltWithTheFrostDBTag: the deployed manifest sets SIGNAL_STORE=frostdb, but
// store/factory.go (the !frostdb build) ignores that value and returns a MemoryStore. Without the
// tag in the image build the two agree only by accident and the pod silently stores nothing
// durably, which is the whole of SLAWS P1-1.
func TestImageIsBuiltWithTheFrostDBTag(t *testing.T) {
	df := readFile(t, dockerfilePath)

	var buildLine string
	for _, line := range strings.Split(df, "\n") {
		if strings.Contains(line, "go build") {
			buildLine = line
		}
	}
	if buildLine == "" {
		t.Fatal("the Dockerfile runs no `go build`")
	}
	if !strings.Contains(buildLine, "-tags frostdb") {
		t.Errorf("image build line is %q;\nit must pass -tags frostdb or store.NewStoreFromEnv ignores SIGNAL_STORE=frostdb and returns an in-memory store", strings.TrimSpace(buildLine))
	}
}

// copySources returns the source argument of every COPY in the Dockerfile.
func copySources(t *testing.T, dockerfile string) []string {
	t.Helper()
	var out []string
	for _, line := range strings.Split(dockerfile, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		// COPY <src> <dst>; skip COPY --from=build, which copies from a stage, not the context.
		if len(fields) < 3 || !strings.EqualFold(fields[0], "COPY") || strings.HasPrefix(fields[1], "--") {
			continue
		}
		out = append(out, fields[1])
	}
	if len(out) == 0 {
		t.Fatal("parsed no COPY lines from the Dockerfile; every assertion below would be vacuous")
	}
	return out
}

// TestDockerfileCopiesEveryLocalModule: all three modules the build compiles are copied in --
// signal-ingest, policy-engine (replace ../policy-engine) and pkg/obscel (replace
// ../../pkg/obscel). A missing COPY is a build that cannot resolve a replace directive.
func TestDockerfileCopiesEveryLocalModule(t *testing.T) {
	sources := copySources(t, readFile(t, dockerfilePath))
	for _, want := range []string{"apps/signal-ingest/", "apps/policy-engine/", "pkg/obscel/"} {
		var found bool
		for _, got := range sources {
			if strings.TrimSuffix(got, "/") == strings.TrimSuffix(want, "/") {
				found = true
			}
		}
		if !found {
			t.Errorf("the Dockerfile does not COPY %s; got %v.\nIt is a local module reached by a replace directive in go.mod, so the build cannot resolve it", want, sources)
		}
	}
}

var demoImageRow = regexp.MustCompile(`(?m)^\s*"signal-ingest:local\|([^|"]*)\|([^|"]*)"`)

// TestBuildScriptAndDockerfileAgreeOnTheContext is the assertion docker would make for us. Every
// COPY source is resolved against the context the build script actually passes; a path that does
// not exist there is the "forbidden path outside the build context" failure, caught here instead
// of in a release build.
func TestBuildScriptAndDockerfileAgreeOnTheContext(t *testing.T) {
	script := readFile(t, imagesScriptPath)
	m := demoImageRow.FindStringSubmatch(script)
	if m == nil {
		t.Fatalf("no signal-ingest:local row parsed from %s; DEMO_IMAGES may have been restructured", imagesScriptPath)
	}
	context, dockerfile := m[1], m[2]

	if context != wantBuildContext {
		t.Errorf("build context is %q, want %q; pkg/obscel sits outside d2-signalloom/apps and cannot be COPYed from there", context, wantBuildContext)
	}
	if want := wantBuildContext + "/apps/signal-ingest/Dockerfile"; dockerfile != want {
		t.Errorf("dockerfile path is %q, want %q", dockerfile, want)
	}

	// repoRoot is three levels above this module (apps/signal-ingest -> apps -> d2-signalloom).
	repoRoot := filepath.Join("..", "..", "..")
	contextDir := filepath.Join(repoRoot, context)
	if _, err := os.Stat(contextDir); err != nil {
		t.Fatalf("declared build context %s does not exist: %v", context, err)
	}
	for _, src := range copySources(t, readFile(t, dockerfilePath)) {
		if _, err := os.Stat(filepath.Join(contextDir, src)); err != nil {
			t.Errorf("COPY %s resolves to %s, which does not exist; docker would fail with a path outside the build context", src, filepath.Join(context, src))
		}
	}
}
