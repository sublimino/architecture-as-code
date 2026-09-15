package pseudonym_test

import (
	"testing"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pseudonym"
)

func TestPseudonymVector(t *testing.T) {
	ring, err := pseudonym.NewKeyRing([]byte("01234567890123456789012345678901"), 1)
	if err != nil {
		t.Fatalf("failed to create keyring: %v", err)
	}
	p, err := ring.Pseudonym("tenant-alpha", "test-session-123")
	if err != nil {
		t.Fatalf("pseudonym failed: %v", err)
	}
	expected := "7b3835c06f46f2ddca90bc84566f21bed867aca811958afb080968a302bbd97e"
	if p != expected {
		t.Fatalf("mismatch: got %s, want %s", p, expected)
	}
}
