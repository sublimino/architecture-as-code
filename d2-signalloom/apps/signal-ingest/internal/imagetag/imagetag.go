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

// Inputs returns the build inputs of the signal-ingest image, as paths relative to the Docker
// build context (d2-signalloom/apps, the parent of moduleDir), sorted.
func Inputs(moduleDir string) ([]string, error) {
	absModule, err := filepath.Abs(moduleDir)
	if err != nil {
		return nil, err
	}
	context := filepath.Dir(absModule)

	cmd := exec.Command("go", "list", "-deps",
		"-f", "{{if .Module}}{{if .Module.Replace}}{{.Module.Replace.Path}}{{else}}{{.Module.Path}}{{end}}{{end}}\t{{.Dir}}\t{{join .GoFiles \",\"}}\t{{join .EmbedFiles \",\"}}", ".")
	cmd.Dir = absModule
	// The Dockerfile builds `CGO_ENABLED=0 go build .` on linux with no tags; list for that target.
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOFLAGS=")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	set := map[string]struct{}{"signal-ingest/Dockerfile": {}}
	modules := map[string]struct{}{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "\t")
		if len(fields) != 4 || fields[0] == "" {
			continue // standard library
		}
		dir := fields[1]
		rel, err := filepath.Rel(context, dir)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue // module cache: pinned by go.sum
		}
		modules[strings.SplitN(filepath.ToSlash(rel), "/", 2)[0]] = struct{}{}
		for _, list := range fields[2:] {
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

// Digest hashes each input's path and content under contextDir. The path is part of the record:
// two files swapping contents is a different build.
func Digest(contextDir string, inputs []string) (string, error) {
	h := sha256.New()
	for _, p := range inputs {
		f, err := os.Open(filepath.Join(contextDir, p))
		if err != nil {
			return "", fmt.Errorf("image input %s: %w", p, err)
		}
		fh := sha256.New()
		_, err = io.Copy(fh, f)
		f.Close()
		if err != nil {
			return "", fmt.Errorf("image input %s: %w", p, err)
		}
		fmt.Fprintf(h, "%s\x00%x\n", p, fh.Sum(nil))
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Tag is the immutable image tag for the source in moduleDir: Prefix plus 16 hex of Digest.
func Tag(moduleDir string) (string, error) {
	in, err := Inputs(moduleDir)
	if err != nil {
		return "", err
	}
	absModule, err := filepath.Abs(moduleDir)
	if err != nil {
		return "", err
	}
	d, err := Digest(filepath.Dir(absModule), in)
	if err != nil {
		return "", err
	}
	return Prefix + d[:16], nil
}
