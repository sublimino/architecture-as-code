//go:build !frostdb

package store

import (
	"strings"
	"testing"
)

// A binary built without the frostdb tag must refuse SIGNAL_STORE=frostdb rather than
// quietly booting the in-memory store: that silent downgrade is the v1 defect SLAWS fixed.
func TestNewStoreFromEnvRefusesFrostDBWithoutTheBuildTag(t *testing.T) {
	st, err := NewStoreFromEnv("frostdb", "/data/signals")
	if err == nil || st != nil {
		t.Fatalf("want a refusal, got store=%v err=%v", st, err)
	}
	if !strings.Contains(err.Error(), "-tags frostdb") {
		t.Fatalf("error must name the build tag so the operator can fix the image: %v", err)
	}
	if _, err := NewStoreFromEnv("", ""); err != nil {
		t.Fatalf("the default (memory) store must still construct: %v", err)
	}
}
