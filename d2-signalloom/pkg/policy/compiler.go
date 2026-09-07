package policy

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"gopkg.in/yaml.v3"
)

// Artifact is one generated file held in memory. Compile never writes; Write
// does. Keeping emission and I/O separate is what lets the tests assert on
// byte-for-byte determinism without a temp directory.
type Artifact struct {
	// RelPath is the artefact's path relative to the output directory.
	RelPath string `json:"path"`
	// Content is the exact bytes to write.
	Content []byte `json:"-"`
	// Digest is the SHA-256 of Content, hex encoded with a "sha256:" prefix.
	Digest string `json:"digest"`
	// Target names the tier the artefact belongs to.
	Target Target `json:"target"`
}

// CompileResult is everything one compilation produced.
type CompileResult struct {
	Set              *InvariantSet      `json:"-"`
	Normalised       *Normalised        `json:"-"`
	Bundles          []VAPBundle        `json:"-"`
	Profile          *NonoProfile       `json:"-"`
	Artifacts        []Artifact         `json:"artifacts"`
	Diagnostics      []Diagnostic       `json:"diagnostics"`
	SP4              *SP4Report         `json:"sp4"`
	Equivalence      *EquivalenceReport `json:"equivalence"`
	InvariantsDigest string             `json:"invariantsDigest"`
}

// Options tunes a compilation run.
type Options struct {
	// Targets selects which tiers to emit. Empty means both.
	Targets []Target
	// SkipOptimize disables the redundancy pass. Used by the test that proves
	// optimisation is verdict-preserving, which needs both rule sets.
	SkipOptimize bool
}

// CanonicalDigest is the content-address of an invariant set's *semantics*.
//
// It is computed over the normalised rule set, not the source YAML, so a comment
// change or a key reorder does not read as drift while a rule change always
// does. That distinction is the whole value of the verify verb: an operator who
// gets a false drift alert learns to ignore drift alerts.
func CanonicalDigest(n *Normalised) string {
	type canonical struct {
		APIVersion string              `json:"apiVersion"`
		Kind       string              `json:"kind"`
		Name       string              `json:"name"`
		Version    string              `json:"version"`
		Defaults   Defaults            `json:"defaults"`
		FS         []NormalFSRule      `json:"fs"`
		Process    []NormalProcessRule `json:"process"`
		Network    []NormalNetworkRule `json:"network"`
	}
	c := canonical{
		APIVersion: n.Set.APIVersion,
		Kind:       n.Set.Kind,
		Name:       n.Set.Metadata.Name,
		Version:    n.Set.Metadata.Version,
		Defaults:   n.Defaults,
		FS:         n.FS,
		Process:    n.Process,
		Network:    n.Network,
	}
	// The normalised slices are already sorted deterministically by Normalise,
	// and encoding/json sorts map keys, so this serialisation is stable.
	b, err := json.Marshal(c)
	if err != nil {
		// canonical contains only marshalable types; a failure here is a
		// programming error, not an input error.
		panic(fmt.Sprintf("canonical digest: %v", err))
	}
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func digestBytes(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func wantTarget(opts Options, t Target) bool {
	if len(opts.Targets) == 0 {
		return true
	}
	return hasTarget(opts.Targets, t)
}

// Compile turns a manifest into artefacts, diagnostics, an SP-4 report and an
// equivalence report. It does not touch the filesystem.
func Compile(set *InvariantSet, opts Options) (*CompileResult, error) {
	n, err := set.Normalise()
	if err != nil {
		return nil, err
	}

	res := &CompileResult{Set: set, Normalised: n, Diagnostics: []Diagnostic{}}

	opt := Optimize(n.FS)
	res.Diagnostics = opt.Diagnostics
	if !opts.SkipOptimize {
		n.FS = opt.Rules
	}

	res.InvariantsDigest = CanonicalDigest(n)

	if wantTarget(opts, TargetVAP) {
		bundles, err := GenerateVAP(n, res.InvariantsDigest)
		if err != nil {
			return nil, err
		}
		res.Bundles = bundles
		for _, b := range bundles {
			content, err := renderBundle(b)
			if err != nil {
				return nil, err
			}
			res.Artifacts = append(res.Artifacts, Artifact{
				RelPath: filepath.Join("vap", string(b.Domain)+".yaml"),
				Content: content,
				Digest:  digestBytes(content),
				Target:  TargetVAP,
			})
		}

		sp4, err := ValidateExpressions(AllExpressions(bundles), n.Defaults)
		if err != nil {
			return nil, err
		}
		res.SP4 = sp4
	}

	if wantTarget(opts, TargetLandlock) {
		profile, err := GenerateLandlock(n, res.InvariantsDigest)
		if err != nil {
			return nil, err
		}
		res.Profile = profile
		content, err := profile.Render()
		if err != nil {
			return nil, err
		}
		res.Artifacts = append(res.Artifacts, Artifact{
			RelPath: filepath.Join("nono", profile.Meta.Name+".json"),
			Content: content,
			Digest:  digestBytes(content),
			Target:  TargetLandlock,
		})
	}

	if res.Bundles != nil && res.Profile != nil {
		eq, err := CheckEquivalence(n, res.Bundles, res.Profile)
		if err != nil {
			return nil, err
		}
		res.Equivalence = eq
	}

	sort.Slice(res.Artifacts, func(i, j int) bool { return res.Artifacts[i].RelPath < res.Artifacts[j].RelPath })
	return res, nil
}

// renderBundle emits a policy and its binding as a two-document YAML stream.
func renderBundle(b VAPBundle) ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteString("# Generated by policy-compiler. DO NOT EDIT.\n")
	buf.WriteString("# Source: config/security-invariants.yaml\n")
	buf.WriteString("# Regenerate: scripts/compile-policies.sh\n")

	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(b.Policy); err != nil {
		return nil, err
	}
	if err := enc.Encode(b.Binding); err != nil {
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// LockEntry records one artefact's expected digest.
type LockEntry struct {
	Path   string `json:"path"`
	Digest string `json:"digest"`
	Target Target `json:"target"`
}

// Lockfile is the drift-detection record.
//
// ValidatingAdmissionPolicy carries its digest in metadata.annotations, so
// cluster-side drift is readable with kubectl alone. The nono profile schema is
// additionalProperties:false with no annotation surface, so host-tier artefacts
// are covered here instead. The asymmetry is deliberate — the alternative was
// smuggling a digest into meta.description, where an operator edit would silently
// destroy it.
type Lockfile struct {
	InvariantsDigest string      `json:"invariantsDigest"`
	Manifest         string      `json:"manifest"`
	Entries          []LockEntry `json:"entries"`
}

// LockfileName is the fixed filename inside the output directory.
const LockfileName = "policies.lock.json"

// BuildLockfile derives the lockfile from a compile result.
func BuildLockfile(res *CompileResult, manifestName string) *Lockfile {
	lf := &Lockfile{InvariantsDigest: res.InvariantsDigest, Manifest: manifestName}
	for _, a := range res.Artifacts {
		lf.Entries = append(lf.Entries, LockEntry{Path: a.RelPath, Digest: a.Digest, Target: a.Target})
	}
	sort.Slice(lf.Entries, func(i, j int) bool { return lf.Entries[i].Path < lf.Entries[j].Path })
	return lf
}

// Render serialises the lockfile deterministically.
func (l *Lockfile) Render() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(l); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// WriteArtifacts writes every artefact plus the lockfile under dir.
func WriteArtifacts(res *CompileResult, dir, manifestName string) error {
	for _, a := range res.Artifacts {
		full := filepath.Join(dir, a.RelPath)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(full, a.Content, 0o644); err != nil {
			return err
		}
	}
	lf, err := BuildLockfile(res, manifestName).Render()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, LockfileName), lf, 0o644)
}

// DriftKind classifies one drift finding.
type DriftKind string

// Drift kinds.
const (
	DriftMissing   DriftKind = "missing"
	DriftModified  DriftKind = "modified"
	DriftUntracked DriftKind = "untracked"
	DriftStaleLock DriftKind = "stale-lockfile"
)

// DriftFinding is one difference between source and deployed artefacts.
type DriftFinding struct {
	Kind     DriftKind `json:"kind"`
	Path     string    `json:"path"`
	Expected string    `json:"expected,omitempty"`
	Actual   string    `json:"actual,omitempty"`
	Detail   string    `json:"detail"`
}

// DriftReport is the machine-readable verify verdict.
type DriftReport struct {
	InSync           bool           `json:"inSync"`
	InvariantsDigest string         `json:"invariantsDigest"`
	Checked          int            `json:"checked"`
	Findings         []DriftFinding `json:"findings"`
}

// CheckDrift recompiles from source and compares against what is on disk.
//
// It compares recomputed digests against the FILES, not against the lockfile
// alone. A drift check that only reads the lockfile is satisfied by an attacker
// who edits both, and is satisfied by an operator who edits neither but whose
// generated YAML was hand-patched.
func CheckDrift(res *CompileResult, dir string) (*DriftReport, error) {
	rep := &DriftReport{InvariantsDigest: res.InvariantsDigest, InSync: true, Findings: []DriftFinding{}}

	for _, a := range res.Artifacts {
		rep.Checked++
		full := filepath.Join(dir, a.RelPath)
		onDisk, err := os.ReadFile(full)
		if err != nil {
			rep.Findings = append(rep.Findings, DriftFinding{
				Kind: DriftMissing, Path: a.RelPath, Expected: a.Digest,
				Detail: fmt.Sprintf("artefact absent from %s: %v", dir, err),
			})
			continue
		}
		if got := digestBytes(onDisk); got != a.Digest {
			rep.Findings = append(rep.Findings, DriftFinding{
				Kind: DriftModified, Path: a.RelPath, Expected: a.Digest, Actual: got,
				Detail: "on-disk artefact does not match the manifest it claims to be compiled from",
			})
		}
	}

	lockPath := filepath.Join(dir, LockfileName)
	if raw, err := os.ReadFile(lockPath); err == nil {
		var lf Lockfile
		if err := json.Unmarshal(raw, &lf); err != nil {
			rep.Findings = append(rep.Findings, DriftFinding{
				Kind: DriftStaleLock, Path: LockfileName,
				Detail: fmt.Sprintf("lockfile is not valid JSON: %v", err),
			})
		} else {
			if lf.InvariantsDigest != res.InvariantsDigest {
				rep.Findings = append(rep.Findings, DriftFinding{
					Kind: DriftStaleLock, Path: LockfileName,
					Expected: res.InvariantsDigest, Actual: lf.InvariantsDigest,
					Detail: "lockfile records a different invariants digest than the manifest compiles to",
				})
			}
			known := map[string]bool{}
			for _, a := range res.Artifacts {
				known[a.RelPath] = true
			}
			for _, e := range lf.Entries {
				if !known[e.Path] {
					rep.Findings = append(rep.Findings, DriftFinding{
						Kind: DriftUntracked, Path: e.Path,
						Detail: "lockfile lists an artefact the current manifest no longer produces",
					})
				}
			}
		}
	} else {
		rep.Findings = append(rep.Findings, DriftFinding{
			Kind: DriftMissing, Path: LockfileName,
			Detail: fmt.Sprintf("lockfile absent: %v", err),
		})
	}

	sort.Slice(rep.Findings, func(i, j int) bool {
		if rep.Findings[i].Path != rep.Findings[j].Path {
			return rep.Findings[i].Path < rep.Findings[j].Path
		}
		return rep.Findings[i].Kind < rep.Findings[j].Kind
	})
	rep.InSync = len(rep.Findings) == 0
	return rep, nil
}

// LoadManifest reads and parses a manifest from disk.
func LoadManifest(path string) (*InvariantSet, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest: %w", err)
	}
	return Parse(raw)
}
