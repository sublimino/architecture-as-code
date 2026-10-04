// Package imagetag derives signal-ingest's immutable image tag from the files its image is built
// from, so the deployed manifest can pin an image that is provably this source and nothing else.
//
// Why a source digest and not the git SHA: the manifest that pins the tag lives in the same tree,
// so a commit SHA can never be written into the commit it names. Why not the whole build context:
// `COPY signal-ingest/` copies base/ and deploy/, which hold the pin itself (circular), and every
// _test.go, which would move the tag on changes that cannot change the binary. So the input set is
// exactly what `go build` compiles for the Dockerfile's target — the non-test Go files and
// //go:embed files of every package in the two local modules, plus both go.mod/go.sum and the
// Dockerfile — as reported by `go list`, not by a hand-written list that would drift.
package imagetag

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Prefix marks a tag as a source digest, so it cannot be mistaken for a semver or `latest`.
const Prefix = "src-"

// BuildTags are the tags the Dockerfile's `go build` passes, and therefore the tags this package
// must list with. They decide which files the binary is compiled from: under `frostdb`,
// store/frostdb.go, store/factory_frostdb.go and store/label_allowlist.go are compiled and
// store/factory.go is not. Listing without them would leave the durable store unpinned -- an edit
// to the FrostDB store would not move the tag, so a stale image would pass the staleness gate.
const BuildTags = "frostdb"

// DockerfilePath is the Dockerfile's own path within the build context. It is an input to the
// digest because the build command (tags, flags) is part of what produces the binary.
const DockerfilePath = "apps/signal-ingest/Dockerfile"

// ContextDir returns the Docker build context for a signal-ingest module directory: d2-signalloom,
// two levels above the module, matching DEMO_IMAGES in scripts/signalfusion-images.sh.
//
// Two levels, not one: signal-ingest/go.mod has `replace ... /pkg/obscel => ../../pkg/obscel`,
// which is outside d2-signalloom/apps, and docker refuses a COPY from outside the context. The
// side effect that matters here is that pkg/obscel now resolves *inside* the context, so its files
// are hashed into the tag instead of being skipped as module cache. A local replace target has no
// go.sum entry, so nothing else was pinning it.
func ContextDir(moduleDir string) (string, error) {
	absModule, err := filepath.Abs(moduleDir)
	if err != nil {
		return "", err
	}
	return filepath.Dir(filepath.Dir(absModule)), nil
}

// Inputs returns the build inputs of the signal-ingest image, as paths relative to the Docker
// build context (d2-signalloom; see ContextDir), sorted.
func Inputs(moduleDir string) ([]string, error) {
	absModule, err := filepath.Abs(moduleDir)
	if err != nil {
		return nil, err
	}
	context, err := ContextDir(moduleDir)
	if err != nil {
		return nil, err
	}

	// .Module.Dir (or .Module.Replace.Dir for a replaced module) locates each module root, so
	// go.mod/go.sum are found by asking go rather than by assuming the first path segment is the
	// module -- which stopped being true when the context moved above apps/.
	cmd := exec.Command("go", "list", "-deps", "-tags", BuildTags,
		"-f", "{{if .Module}}{{if .Module.Replace}}{{.Module.Replace.Path}}{{else}}{{.Module.Path}}{{end}}{{end}}\t{{.Dir}}\t{{join .GoFiles \",\"}}\t{{join .EmbedFiles \",\"}}\t{{if .Module}}{{if .Module.Replace}}{{.Module.Replace.Dir}}{{else}}{{.Module.Dir}}{{end}}{{end}}", ".")
	cmd.Dir = absModule
	// The Dockerfile builds `CGO_ENABLED=0 go build -tags frostdb .` on linux; list for that target.
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOFLAGS=")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	// within reports a path's slash-form location inside the build context, and whether it is
	// there at all. Outside means the module cache, which go.sum pins.
	within := func(dir string) (string, bool) {
		rel, err := filepath.Rel(context, dir)
		if err != nil {
			return "", false
		}
		rel = filepath.ToSlash(rel)
		return rel, rel != ".." && !strings.HasPrefix(rel, "../")
	}

	set := map[string]struct{}{DockerfilePath: {}}
	modules := map[string]struct{}{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "\t")
		if len(fields) != 5 || fields[0] == "" {
			continue // standard library
		}
		rel, ok := within(fields[1])
		if !ok {
			continue // module cache: pinned by go.sum
		}
		if modRel, ok := within(fields[4]); ok {
			modules[modRel] = struct{}{}
		}
		for _, list := range fields[2:4] {
			for _, f := range strings.Split(list, ",") {
				if f != "" {
					set[filepath.ToSlash(filepath.Join(rel, f))] = struct{}{}
				}
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	for m := range modules {
		for _, f := range []string{"go.mod", "go.sum"} {
			if _, err := os.Stat(filepath.Join(context, m, f)); err == nil {
				set[m+"/"+f] = struct{}{}
			}
		}
	}

	in := make([]string, 0, len(set))
	for p := range set {
		in = append(in, p)
	}
	sort.Strings(in)
	return in, nil
}

// TrackedInputs returns the inputs git tracks under contextDir, in their given order. go list
// reads the files on disk, so an untracked or ignored .go file in a package directory is
// compiled and was hashed; the tag must name the committed source (as scripts/lib/source-id.sh
// does for the sentinel), and such files are for the image-tag guard
// (scripts/signal-ingest-image-tag.sh, source_id_dirty_inputs) to refuse. It fails outside a git
// repository and when nothing is tracked: a digest of the empty set names nothing.
func TrackedInputs(contextDir string, inputs []string) ([]string, error) {
	cmd := exec.Command("git", append([]string{"-C", contextDir, "ls-files", "-z", "--cached", "--"}, inputs...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	tracked := map[string]struct{}{}
	for _, p := range strings.Split(string(out), "\x00") {
		if p != "" {
			tracked[p] = struct{}{}
		}
	}
	var kept []string
	for _, p := range inputs {
		if _, ok := tracked[p]; ok {
			kept = append(kept, p)
		}
	}
	if len(kept) == 0 {
		return nil, fmt.Errorf("none of the %d image inputs is tracked by git under %s", len(inputs), contextDir)
	}
	return kept, nil
}

// Digest hashes each input's path, executable bit and content under contextDir. The path is part
// of the record: two files swapping contents is a different build. Of the mode, only the
// executable bit is recorded -- it is all git tracks; the rest is the umask of whoever wrote the
// file, and hashing it split one commit's sentinel tag across checkouts (2026-10-03).
func Digest(contextDir string, inputs []string) (string, error) {
	h := sha256.New()
	for _, p := range inputs {
		f, err := os.Open(filepath.Join(contextDir, p))
		if err != nil {
			return "", fmt.Errorf("image input %s: %w", p, err)
		}
		fi, err := f.Stat()
		if err != nil {
			f.Close()
			return "", fmt.Errorf("image input %s: %w", p, err)
		}
		execBit := "-"
		if fi.Mode()&0o111 != 0 {
			execBit = "x"
		}
		fh := sha256.New()
		_, err = io.Copy(fh, f)
		f.Close()
		if err != nil {
			return "", fmt.Errorf("image input %s: %w", p, err)
		}
		fmt.Fprintf(h, "%s\x00%s\x00%x\n", p, execBit, fh.Sum(nil))
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Tag is the immutable image tag for the committed source in moduleDir: Prefix plus 16 hex of
// Digest over the tracked inputs.
func Tag(moduleDir string) (string, error) {
	in, err := Inputs(moduleDir)
	if err != nil {
		return "", err
	}
	context, err := ContextDir(moduleDir)
	if err != nil {
		return "", err
	}
	tracked, err := TrackedInputs(context, in)
	if err != nil {
		return "", err
	}
	d, err := Digest(context, tracked)
	if err != nil {
		return "", err
	}
	return Prefix + d[:16], nil
}
