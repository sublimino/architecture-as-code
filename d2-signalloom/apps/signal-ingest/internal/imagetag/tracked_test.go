package imagetag

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
)

// The tag names the committed source, exactly as scripts/lib/source-id.sh
// does for the sentinel (2026-10-03): go list reads the files on disk, so an
// untracked or ignored .go file in a package directory was hashed into the tag
// while the guard (no --ignored) let an ignored one through, and the digest
// ignored file modes entirely. Now the inputs are filtered to git's index,
// the executable bit (the only mode git records) is part of the record, and
// untracked/ignored inputs are the guard's to refuse.

func gitFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("config", "user.email", "t@example.invalid")
	run("config", "user.name", "t")
	run("config", "core.excludesFile", os.DevNull) // this machine's global excludes must not decide
	run("config", "commit.gpgsign", "false")
	write(t, dir, ".gitignore", "zz_ignored.go\n")
	write(t, dir, "m/a.go", "package m\n")
	write(t, dir, "m/b.go", "package m // b\n")
	run("add", "-A")
	run("commit", "-q", "-m", "init")
	return dir
}

func write(t *testing.T, dir, name, body string) {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func trackedDigest(t *testing.T, dir string, inputs []string) string {
	t.Helper()
	tracked, err := TrackedInputs(dir, inputs)
	if err != nil {
		t.Fatalf("TrackedInputs: %v", err)
	}
	d, err := Digest(dir, tracked)
	if err != nil {
		t.Fatalf("Digest: %v", err)
	}
	return d
}

func TestTrackedInputsDropUntrackedAndIgnoredFiles(t *testing.T) {
	dir := gitFixture(t)
	write(t, dir, "m/zz_ignored.go", "package m\n")
	write(t, dir, "m/zz_untracked.go", "package m\n")
	got, err := TrackedInputs(dir, []string{"m/a.go", "m/b.go", "m/zz_ignored.go", "m/zz_untracked.go"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []string{"m/a.go", "m/b.go"}) {
		t.Fatalf("TrackedInputs = %v, want [m/a.go m/b.go]", got)
	}
}

func TestTheTagIgnoresUntrackedAndIgnoredInputsAndMovesOnTrackedEdits(t *testing.T) {
	dir := gitFixture(t)
	all := []string{"m/a.go", "m/b.go", "m/zz_ignored.go", "m/zz_untracked.go"}
	base := trackedDigest(t, dir, all[:2])
	write(t, dir, "m/zz_ignored.go", "package m\n")
	write(t, dir, "m/zz_untracked.go", "package m\n")
	if got := trackedDigest(t, dir, all); got != base {
		t.Fatal("an untracked or ignored input moved the tag")
	}
	write(t, dir, "m/a.go", "package m\n\nvar edited = 1\n")
	if got := trackedDigest(t, dir, all); got == base {
		t.Fatal("an uncommitted edit to a tracked input did not move the tag")
	}
}

// Git records the executable bit and nothing else; the rest is the writer's umask.
func TestOnlyTheExecutableBitOfAModeIsPartOfTheTag(t *testing.T) {
	dir := gitFixture(t)
	in := []string{"m/a.go", "m/b.go"}
	p := filepath.Join(dir, "m/a.go")
	if err := os.Chmod(p, 0o664); err != nil {
		t.Fatal(err)
	}
	base := trackedDigest(t, dir, in)
	for _, mode := range []os.FileMode{0o600, 0o644} {
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}
		if got := trackedDigest(t, dir, in); got != base {
			t.Fatalf("mode %o moved the tag: umask noise must not", mode)
		}
	}
	if err := os.Chmod(p, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := trackedDigest(t, dir, in); got == base {
		t.Fatal("the executable bit, which git records, did not move the tag")
	}
}

func TestTrackedInputsFailOutsideARepository(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "m/a.go", "package m\n")
	if _, err := TrackedInputs(dir, []string{"m/a.go"}); err == nil {
		t.Fatal("TrackedInputs succeeded outside a git repository")
	}
}

func TestTrackedInputsFailWhenNothingIsTracked(t *testing.T) {
	dir := gitFixture(t)
	write(t, dir, "m/zz_untracked.go", "package m\n")
	if _, err := TrackedInputs(dir, []string{"m/zz_untracked.go"}); err == nil {
		t.Fatal("an empty tracked set would hash to a tag that names nothing")
	}
}
