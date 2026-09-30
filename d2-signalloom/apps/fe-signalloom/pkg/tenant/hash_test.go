package tenant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func env(m map[string]string) Getenv { return func(k string) string { return m[k] } }

func TestCanonicalVector(t *testing.T) {
	got, err := DeriveTenantHash(CanonicalTenant, PilotSalt)
	if err != nil || got != CanonicalHash {
		t.Fatalf("DeriveTenantHash(kusari) = %q, %v; want %q", got, err, CanonicalHash)
	}
	if got == "d9d69501" {
		t.Fatal("canonical hash equals the unsalted digest")
	}
}

func TestMatchesSaltedConcatenation(t *testing.T) {
	for _, tn := range []string{"kusari", "acme", "tenant-01", "  KuSaRi "} {
		c, _ := NormalizeTenant(tn)
		sum := sha256.Sum256([]byte(PilotSalt + ":" + c))
		want := hex.EncodeToString(sum[:])[:8]
		got, err := DeriveTenantHash(tn, PilotSalt)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v; want %q", tn, got, err, want)
		}
	}
}

func TestRejectedInputs(t *testing.T) {
	cases := map[string]error{
		"kurasi": ErrRetiredTenant, " KURASI ": ErrRetiredTenant,
		"": ErrEmptyTenant, "  ": ErrEmptyTenant,
		"-x": ErrInvalidTenant, "a.b": ErrInvalidTenant,
	}
	for in, want := range cases {
		if _, err := DeriveTenantHash(in, PilotSalt); !errors.Is(err, want) {
			t.Errorf("%q: err = %v; want %v", in, err, want)
		}
	}
	if _, err := DeriveTenantHash("kusari", ""); !errors.Is(err, ErrSaltUnavailable) {
		t.Errorf("empty salt: err = %v", err)
	}
}

func TestResolveSaltPrefersOpenBao(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/secret/data/signalloom/eap" || r.Header.Get("X-Vault-Token") != "tok" {
			http.Error(w, "denied", http.StatusForbidden)
			return
		}
		_, _ = w.Write([]byte(`{"data":{"data":{"salt":"` + PilotSalt + `"}}}`))
	}))
	defer srv.Close()

	salt, err := ResolveSalt(context.Background(), srv.Client(),
		env(map[string]string{"BAO_ADDR": srv.URL, "BAO_TOKEN": "tok", "SIGNAL_LOOM_EAP_SALT": "env"}))
	if err != nil || salt != PilotSalt {
		t.Fatalf("salt = %q, %v; want OpenBao salt", salt, err)
	}

	salt, err = ResolveSalt(context.Background(), srv.Client(),
		env(map[string]string{"BAO_ADDR": srv.URL, "BAO_TOKEN": "bad", "SIGNAL_LOOM_EAP_SALT": "env"}))
	if err != nil || salt != "env" {
		t.Fatalf("invalid token: salt = %q, %v; want env fallback", salt, err)
	}
}

func TestResolveSaltFailsClosed(t *testing.T) {
	_, err := ResolveSalt(context.Background(), nil,
		env(map[string]string{"BAO_ADDR": "http://127.0.0.1:9", "BAO_TOKEN": "x"}))
	if !errors.Is(err, ErrSaltUnavailable) {
		t.Fatalf("err = %v; want ErrSaltUnavailable", err)
	}
}
