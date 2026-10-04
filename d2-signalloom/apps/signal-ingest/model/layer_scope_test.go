package model

import (
	"go/ast"
	"go/parser"
	"go/token"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// TestLayerScopeCommentsAgreeWithInScopeLayers reads this package's own source and holds the
// `// out of scope` markers on the Layer constants to the one thing that decides scope at runtime,
// InScopeLayers().
//
// Why a source-parsing test rather than an assertion on values: the defect this catches is not a
// wrong value, it is a comment that lies. LayerCloudControlPlane has been in InScopeLayers() since
// CLOUDAUDIT extended it, while the constant still carried `// out of scope` (SLAWS v2 §8) -- so
// every reader of model/signal.go, and every reviewer deciding whether a cloud rule was reachable,
// was told the opposite of what the code does. A comment cannot be caught by a normal unit test,
// which is exactly why it drifted; the parser closes that gap. Keeping the marker on genuinely
// out-of-scope layers is the other half: an unexplained absence from InScopeLayers() is just as
// hard to review as a stale marker.
func TestLayerScopeCommentsAgreeWithInScopeLayers(t *testing.T) {
	const marker = "out of scope"

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "signal.go", nil, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse signal.go: %v", err)
	}

	inScope := InScopeLayers()
	seen := 0
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		for _, spec := range gen.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok || len(vs.Values) != 1 {
				continue
			}
			// Only the Layer constants; the const block also carries MaxLabelValueLen etc.
			ident, ok := vs.Type.(*ast.Ident)
			if !ok || ident.Name != "Layer" {
				continue
			}
			lit, ok := vs.Values[0].(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				continue
			}
			value, err := strconv.Unquote(lit.Value)
			if err != nil {
				t.Fatalf("%s: unquote %s: %v", vs.Names[0].Name, lit.Value, err)
			}
			seen++

			var comment string
			if vs.Comment != nil {
				comment = vs.Comment.Text()
			}
			marked := strings.Contains(strings.ToLower(comment), marker)
			active := slices.Contains(inScope, Layer(value))

			switch {
			case active && marked:
				t.Errorf("%s (%q) is in InScopeLayers() but its comment says %q; "+
					"the comment is stale and misreports the layer as undeployed",
					vs.Names[0].Name, value, strings.TrimSpace(comment))
			case !active && !marked:
				t.Errorf("%s (%q) is absent from InScopeLayers() but carries no %q comment; "+
					"an unexplained exclusion cannot be reviewed",
					vs.Names[0].Name, value, marker)
			}
		}
	}

	// A parser that silently matched nothing would make this test vacuously green, which is the
	// one failure mode a source-reading test is prone to.
	if seen != len(ValidLayers()) {
		t.Fatalf("parsed %d Layer constants but ValidLayers() reports %d; the parse missed declarations "+
			"and every assertion above was vacuous", seen, len(ValidLayers()))
	}
}
