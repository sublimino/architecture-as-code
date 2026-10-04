package obscel

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// semverPattern is strict MAJOR.MINOR.PATCH with optional prerelease and build
// metadata. Two-component versions are rejected: Finding.ID hashes the bundle
// version, so "1.0" and "1.0.0" would be two different detection identities for
// what an author meant as one bundle.
var semverPattern = regexp.MustCompile(`^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$`)

// BundleFileExtensions are the file suffixes LoadBundleDir considers.
var BundleFileExtensions = []string{".yaml", ".yml"}

// ValidateBundle checks the bundle header and structure without compiling CEL.
// Conform does the compilation; this reports the defects that make a document
// not a bundle at all.
func ValidateBundle(b *Bundle) []RuleError {
	if b == nil {
		return []RuleError{{Kind: "bundle", Field: "", Message: "bundle is nil"}}
	}

	var errs []RuleError
	add := func(field, msg string) {
		errs = append(errs, RuleError{Kind: "bundle", Field: field, Message: msg})
	}

	if strings.TrimSpace(b.ID) == "" {
		add("id", "bundle id is required")
	}
	if strings.TrimSpace(b.TenantID) == "" {
		add("tenant_id", "tenant_id is required: a bundle with no tenant cannot be scoped and must never load")
	}
	if !semverPattern.MatchString(b.Version) {
		add("version", fmt.Sprintf("version %q is not a MAJOR.MINOR.PATCH semantic version", b.Version))
	}
	switch b.Mode {
	case ModeShadow, ModeWarn, ModeEnforce:
	default:
		add("mode", fmt.Sprintf("mode %q must be one of %s, %s, %s", b.Mode, ModeShadow, ModeWarn, ModeEnforce))
	}
	if len(b.Rules) == 0 {
		add("rules", "at least one rule is required")
	}
	for name, values := range b.Vars {
		if strings.TrimSpace(name) == "" {
			add("vars", "vars key must not be empty")
			continue
		}
		if len(values) == 0 {
			add("vars", fmt.Sprintf("vars.%s is empty: an empty allowlist silently changes every rule that reads it", name))
		}
	}
	for _, r := range SortedRules(b) {
		if strings.TrimSpace(r.Severity) == "" {
			errs = append(errs, RuleError{RuleID: r.ID, Kind: "rule", Field: "severity", Message: "severity is required"})
		}
	}

	return errs
}

// LoadBundleFile reads one bundle document from disk, validates its structure
// and conforms every rule and window reference (ISC-45, D6).
//
// It is deliberately fail-closed: a bundle that does not parse, does not
// validate, or does not compile is an error rather than a partially-loaded
// bundle. A half-loaded policy set is indistinguishable at runtime from a
// policy set that chose not to detect anything.
func LoadBundleFile(path string) (*Bundle, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("obscel: reading bundle %s: %w", path, err)
	}

	var b Bundle
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	dec.KnownFields(true)
	if err := dec.Decode(&b); err != nil {
		return nil, fmt.Errorf("obscel: parsing bundle %s: %w", path, err)
	}

	if errs := ValidateBundle(&b); len(errs) > 0 {
		return nil, fmt.Errorf("obscel: invalid bundle %s: %w", path, JoinRuleErrors(errs))
	}
	if errs := Conform(&b); len(errs) > 0 {
		return nil, fmt.Errorf("obscel: non-conformant bundle %s: %w", path, JoinRuleErrors(errs))
	}

	return &b, nil
}

// LoadBundleDir loads every bundle under dir, recursively, in sorted path order
// so two processes booting from the same tree get the same set in the same
// order (the determinism contract covers boot as well as replay).
//
// A missing dir, or a dir with no bundle files, returns an empty slice and no
// error: policy-engine must boot in an estate that has not shipped a bundle
// yet. A dir that exists but cannot be read, or any bundle that fails to load,
// IS an error — that is a broken deployment, not an empty one.
func LoadBundleDir(dir string) ([]*Bundle, error) {
	if dir == "" {
		return nil, nil
	}

	info, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("obscel: stat bundle dir %s: %w", dir, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("obscel: bundle path %s is not a directory", dir)
	}

	var paths []string
	walkErr := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			// A kubelet ConfigMap mount lays files out as <key> -> ..data/<key> with ..data a
			// symlink to a timestamped ..YYYY_MM_DD_* directory. Walking into the dot
			// directories would load every bundle twice; skip them (nested below the root).
			if p != dir && strings.HasPrefix(d.Name(), "..") {
				return filepath.SkipDir
			}
			return nil
		}
		if !isBundleFile(p) {
			return nil
		}
		paths = append(paths, p)
		return nil
	})
	if walkErr != nil {
		return nil, fmt.Errorf("obscel: walking bundle dir %s: %w", dir, walkErr)
	}
	sort.Strings(paths)

	bundles := make([]*Bundle, 0, len(paths))
	seen := make(map[string]string, len(paths))
	for _, p := range paths {
		b, err := LoadBundleFile(p)
		if err != nil {
			return nil, err
		}
		identity := b.TenantID + "/" + b.ID + "@" + b.Version
		if prev, dup := seen[identity]; dup {
			return nil, fmt.Errorf("obscel: bundle %s duplicates %s (both are %s)", p, prev, identity)
		}
		seen[identity] = p
		bundles = append(bundles, b)
	}

	return bundles, nil
}

func isBundleFile(p string) bool {
	ext := strings.ToLower(filepath.Ext(p))
	for _, want := range BundleFileExtensions {
		if ext == want {
			return true
		}
	}
	return false
}
