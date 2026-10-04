package obscel

import (
	"os"
	"path/filepath"
	"testing"
)

// A kubelet ConfigMap volume is laid out as:
//   <dir>/<key>              -> symlink to ..data/<key>
//   <dir>/..data             -> symlink to ..2026_10_04_08_00_00.123456789
//   <dir>/..2026_10_04_.../<key>  the real file
// LoadBundleDir must load each bundle exactly once from that layout (SLAWS D6).
func TestLoadBundleDirLoadsAConfigMapMountExactlyOnce(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "..2026_10_04_08_00_00.123456789")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join("..", "..", "..", "policy", "bundles", "kusari", "iam-change.yaml")
	body, err := os.ReadFile(src)
	if err != nil {
		t.Skipf("kusari bundle not present at %s: %v", src, err)
	}
	if err := os.WriteFile(filepath.Join(real, "kusari--iam-change.yaml"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(dir, "..data")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join("..data", "kusari--iam-change.yaml"), filepath.Join(dir, "kusari--iam-change.yaml")); err != nil {
		t.Fatal(err)
	}

	bundles, err := LoadBundleDir(dir)
	if err != nil {
		t.Fatalf("LoadBundleDir over a ConfigMap-shaped mount: %v", err)
	}
	if len(bundles) != 1 {
		ids := make([]string, 0, len(bundles))
		for _, b := range bundles {
			ids = append(ids, b.ID+"@"+b.Version)
		}
		t.Fatalf("want exactly 1 bundle from the mount, got %d: %v", len(bundles), ids)
	}
}
