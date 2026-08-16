package main

import (
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
