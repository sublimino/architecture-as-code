// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"go/parser"
	"go/token"
	"os"
	"strings"
	"testing"
)

// TestAntiParentPackageDoesNotImportEbpf keeps the import-cycle invariant that
// used to live in the (now-removed) Tetragon stream tests: the parent
// `collectors` package must NOT import `collectors/ebpf`, because this package
// imports `collectors` for the shared Mode type. The endpoint collector is
// therefore registered from main.go, not from the parent factory.
func TestAntiParentPackageDoesNotImportEbpf(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, "..", func(fi os.FileInfo) bool {
		return strings.HasSuffix(fi.Name(), ".go")
	}, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse parent package: %v", err)
	}

	const self = "collectors/ebpf"
	for pkgName, pkg := range pkgs {
		for fileName, file := range pkg.Files {
			for _, imp := range file.Imports {
				if strings.Contains(imp.Path.Value, self) {
					t.Errorf("%s/%s imports %s — this creates an import cycle, because "+
						"collectors/ebpf imports collectors for the Mode type. Register the "+
						"endpoint collector from main.go instead.", pkgName, fileName, self)
				}
			}
		}
	}
}

// TestEndpointObservationSourceIsSentinelEBPF pins the re-sourced endpoint
// stream to the Sentinel eBPF naming convention. The endpoint_host projection no
// longer carries the retired runtime brand: it is sourced from the stun-sentinel's
// own eBPF syscall trace, the sibling of netebpf's "sentinel.ebpf.socket_trace",
// and the endpoint-runtime bundle source-gates on exactly this value.
func TestEndpointObservationSourceIsSentinelEBPF(t *testing.T) {
	const want = "sentinel.ebpf.syscall_trace"
	if EndpointObservationSource != want {
		t.Errorf("EndpointObservationSource = %q, want %q", EndpointObservationSource, want)
	}
	if !strings.HasPrefix(EndpointObservationSource, "sentinel.ebpf.") {
		t.Errorf("EndpointObservationSource = %q, want the sentinel.ebpf.* convention netebpf uses", EndpointObservationSource)
	}
}
