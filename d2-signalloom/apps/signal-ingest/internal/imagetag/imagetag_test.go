package imagetag

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The module under test is the real signal-ingest module: Inputs answers "which files does the
// Dockerfile's `go build` read", and the only honest fixture for that is the build itself.
const moduleDir = "../.."

func TestInputsAreExactlyWhatTheBinaryIsBuiltFrom(t *testing.T) {
	in, err := Inputs(moduleDir)
	if err != nil {
		t.Fatalf("Inputs: %v", err)
	}
	// Paths are relative to the build context, which is d2-signalloom (ContextDir), so every
	// module sits under apps/ -- except pkg/obscel, which is why the context is above apps/.
	for _, want := range []string{
		"apps/signal-ingest/Dockerfile",
		"apps/signal-ingest/go.mod",
		"apps/signal-ingest/go.sum",
		"apps/signal-ingest/main.go",
		"apps/signal-ingest/store/memory.go",
		"apps/signal-ingest/identity/migrations/001_identity_graph.sql", // //go:embed
		"apps/policy-engine/go.mod",
		"apps/policy-engine/fair/fair.go", // replace => ../policy-engine
		// The Dockerfile builds -tags frostdb, so the durable store IS the binary and must be
		// pinned. These were asserted absent while the image was built without tags; listing
		// with the build's own tags is what keeps the tag honest about the FrostDB store.
		"apps/signal-ingest/store/frostdb.go",
		"apps/signal-ingest/store/factory_frostdb.go",
		"apps/signal-ingest/store/label_allowlist.go",
	} {
		if !slices.Contains(in, want) {
			t.Errorf("Inputs omits %s, which the image build reads", want)
		}
	}
	for _, p := range in {
		switch {
		case strings.HasSuffix(p, "_test.go"):
			t.Errorf("Inputs includes test file %s; tests do not change the binary", p)
		case strings.HasPrefix(p, "apps/signal-ingest/base/"), strings.HasPrefix(p, "apps/signal-ingest/deploy/"):
			t.Errorf("Inputs includes manifest %s; the manifest pins the tag, so hashing it is circular", p)
		case p == "apps/signal-ingest/store/factory.go":
			t.Errorf("Inputs includes %s, which only a build WITHOUT -tags frostdb compiles", p)
		}
	}
	if !slices.IsSorted(in) {
		t.Error("Inputs is not sorted; the digest would depend on go list's order")
	}
}

func TestDigestMovesWithContentAndNothingElse(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a/x.go", "package a\n")
	write("a/y.go", "package a // y\n")
	files := []string{"a/x.go", "a/y.go"}

	base, err := Digest(dir, files)
	if err != nil {
		t.Fatal(err)
	}
	if again, _ := Digest(dir, files); again != base {
		t.Fatalf("Digest is not deterministic: %s then %s", base, again)
	}

	write("a/x.go", "package a\n\nvar changed = 1\n")
	if moved, _ := Digest(dir, files); moved == base {
		t.Error("editing a compiled file did not move the digest")
	}
	write("a/x.go", "package a\n")

	write("a/x_test.go", "package a\n")
	if same, _ := Digest(dir, files); same != base {
		t.Error("a file outside the input set moved the digest")
	}

	// Moving a file keeps every content hash but is a different build: the path is part of the
	// record.
	write("b/x.go", "package a\n")
	if moved, _ := Digest(dir, []string{"b/x.go", "a/y.go"}); moved == base {
		t.Error("moving a file to another path did not move the digest")
	}

	if _, err := Digest(dir, []string{"a/missing.go"}); err == nil {
		t.Error("a missing input digested without error; the tag would describe a tree that cannot build")
	}
}

func TestTagIsTheImmutableSourceForm(t *testing.T) {
	tag, err := Tag(moduleDir)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tag, Prefix) || len(tag) != len(Prefix)+16 || strings.Trim(tag[len(Prefix):], "0123456789abcdef") != "" {
		t.Fatalf("Tag = %q, want %s followed by 16 lowercase hex", tag, Prefix)
	}
}
