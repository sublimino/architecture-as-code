package main

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestImportBoundary_NoFrostDBOutsideStore ensures that no package outside
// store/ imports github.com/polarsignals/frostdb. This is a structural
// constraint: FrostDB is an implementation detail of the store layer.
func TestImportBoundary_NoFrostDBOutsideStore(t *testing.T) {
	const forbidden = "github.com/polarsignals/frostdb"

	root, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}

	fset := token.NewFileSet()
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip store/ directory — FrostDB is allowed there.
		rel, _ := filepath.Rel(root, path)
		if info.IsDir() && (rel == "store" || strings.HasPrefix(rel, "store/") || strings.HasPrefix(rel, "store\\")) {
			return filepath.SkipDir
		}

		// Skip vendor, testdata, hidden dirs.
		if info.IsDir() && (strings.HasPrefix(info.Name(), ".") || info.Name() == "vendor" || info.Name() == "testdata") {
			return filepath.SkipDir
		}

		if !strings.HasSuffix(path, ".go") {
			return nil
		}

		f, parseErr := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if parseErr != nil {
			return nil // skip unparseable files
		}

		for _, imp := range f.Imports {
			importPath := strings.Trim(imp.Path.Value, `"`)
			if strings.HasPrefix(importPath, forbidden) {
				t.Errorf("BOUNDARY VIOLATION: %s imports %s (FrostDB only allowed in store/)", rel, importPath)
			}
		}

		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// verifySymmetricRegistration checks that baoaudit and spirea are either both registered or neither,
// and rejects asymmetric/half-wired registrations.
func verifySymmetricRegistration(source string) error {
	hasBao := strings.Contains(source, "baoaudit")
	hasSpire := strings.Contains(source, "spirea")

	if hasBao && !hasSpire {
		return fmt.Errorf("asymmetric registration violation: baoaudit is present in main.go but spirea is missing")
	}
	if !hasBao && hasSpire {
		return fmt.Errorf("asymmetric registration violation: spirea is present in main.go but baoaudit is missing")
	}
	if !hasBao && !hasSpire {
		return fmt.Errorf("unregistered identity collectors: neither baoaudit nor spirea found in main.go")
	}
	return nil
}


// TestSymmetricRegistration_BaoauditAndSpirea enforces the symmetric registration guard:
// baoaudit and spirea must be registered together in main.go so the identity pair cannot land half-wired.
func TestSymmetricRegistration_BaoauditAndSpirea(t *testing.T) {
	mainBytes, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("failed to read main.go: %v", err)
	}
	mainSrc := string(mainBytes)

	hasBao := strings.Contains(mainSrc, "baoaudit")
	hasSpire := strings.Contains(mainSrc, "spirea")

	if !hasBao || !hasSpire {
		t.Fatalf("both-wired invariant violated in main.go: baoaudit=%v, spirea=%v (both required)", hasBao, hasSpire)
	}

	// Guard verification against asymmetric synthetic inputs
	validate := func(src string) (bool, string) {
		b := strings.Contains(src, "baoaudit")
		s := strings.Contains(src, "spirea")
		if b != s {
			return false, "asymmetric registration"
		}
		if !b {
			return false, "unregistered"
		}
		return true, ""
	}

	ok, _ := validate(mainSrc)
	if !ok {
		t.Errorf("main.go failed symmetric registration validation")
	}

	if ok, _ := validate("collectorRegistry.Register(baoaudit)"); ok {
		t.Errorf("guard failed to reject lone baoaudit registration")
	}
	if ok, _ := validate("collectorRegistry.Register(spirea)"); ok {
		t.Errorf("guard failed to reject lone spirea registration")
	}
	if ok, _ := validate("no collectors here"); ok {
		t.Errorf("guard failed to reject unregistered source")
	}
}

