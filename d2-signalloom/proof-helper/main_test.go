package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWriteStoresSingleJWT(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwt")
	runner := func(name string, args ...string) ([]byte, error) {
		if name != spireAgent {
			t.Fatalf("unexpected executable: %s", name)
		}
		return []byte(`{"svids":[{"svid":"header.payload.signature"}]}`), nil
	}
	if code := run([]string{"write", "--output", path}, os.Stdout, os.Stderr, runner); code != 0 {
		t.Fatalf("run returned %d", code)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "header.payload.signature" {
		t.Fatalf("unexpected JWT: %q", got)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("unexpected mode: %o", got)
	}
}

func TestWriteRejectsMalformedOrAmbiguousResponses(t *testing.T) {
	for name, response := range map[string]string{
		"malformed": `{`,
		"absent":    `{"svids":[]}`,
		"multiple":  `{"svids":[{"svid":"one"},{"svid":"two"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			runner := func(string, ...string) ([]byte, error) { return []byte(response), nil }
			if code := run([]string{"write", "--output", filepath.Join(t.TempDir(), "jwt")}, os.Stdout, os.Stderr, runner); code == 0 {
				t.Fatal("invalid response unexpectedly succeeded")
			}
		})
	}
}

func TestWriteRetriesUntilSPIREIsReady(t *testing.T) {
	path := filepath.Join(t.TempDir(), "jwt")
	calls := 0
	runner := func(string, ...string) ([]byte, error) {
		calls++
		if calls < 3 {
			return []byte("agent unavailable"), errors.New("exit status 1")
		}
		return []byte(`{"svid":"jwt"}`), nil
	}
	if code := runWithPause([]string{"write", "--output", path}, os.Stdout, os.Stderr, runner, func(time.Duration) {}); code != 0 {
		t.Fatalf("run returned %d", code)
	}
	if calls != 3 {
		t.Fatalf("expected three attempts, got %d", calls)
	}
}

func TestExpectDeniedRequiresIdentityDenial(t *testing.T) {
	var stdout strings.Builder
	denied := func(string, ...string) ([]byte, error) {
		return []byte("rpc error: code = PermissionDenied desc = no identity issued"), errors.New("exit status 1")
	}
	if code := run([]string{"expect-denied"}, &stdout, os.Stderr, denied); code == 0 {
		t.Fatal("expected denial mode to fail the init container")
	}
	if !strings.Contains(stdout.String(), "denied as expected") {
		t.Fatalf("missing denial marker: %q", stdout.String())
	}

	success := func(string, ...string) ([]byte, error) { return []byte(`{"svid":"jwt"}`), nil }
	stdout.Reset()
	if code := run([]string{"expect-denied"}, &stdout, os.Stderr, success); code == 0 {
		t.Fatal("unexpected identity issuance succeeded")
	}
	if strings.Contains(stdout.String(), "denied as expected") {
		t.Fatal("successful issuance emitted denial marker")
	}
}
