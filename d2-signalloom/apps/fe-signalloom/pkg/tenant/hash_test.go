package tenant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
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
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["method not allowed"]}`))
			}
			return
		}
		if r.URL.Path != "/v1/secret/data/signalloom/eap" || r.Header.Get("X-Vault-Token") != "tok" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			if r.Method != http.MethodHead {
				_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
			}
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			_, _ = w.Write([]byte(`{"data":{"data":{"salt":"` + PilotSalt + `"}}}`))
		}
	}))
	defer srv.Close()

	// Verify HEAD request body suppression and status parity
	headReq, err := http.NewRequestWithContext(context.Background(), http.MethodHead, srv.URL+"/v1/secret/data/signalloom/eap", nil)
	if err != nil {
		t.Fatalf("failed to create HEAD request: %v", err)
	}
	headReq.Header.Set("X-Vault-Token", "tok")
	headResp, err := srv.Client().Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()
	if headResp.StatusCode != http.StatusOK {
		t.Errorf("HEAD status = %d; want %d", headResp.StatusCode, http.StatusOK)
	}
	headBytes, _ := io.ReadAll(headResp.Body)
	if len(headBytes) != 0 {
		t.Errorf("HEAD response had body length %d; want 0", len(headBytes))
	}

	// Verify HEAD with bad token returns 403 with 0 body bytes
	headBadReq, err := http.NewRequestWithContext(context.Background(), http.MethodHead, srv.URL+"/v1/secret/data/signalloom/eap", nil)
	if err != nil {
		t.Fatalf("failed to create bad HEAD request: %v", err)
	}
	headBadReq.Header.Set("X-Vault-Token", "bad")
	headBadResp, err := srv.Client().Do(headBadReq)
	if err != nil {
		t.Fatalf("bad HEAD request failed: %v", err)
	}
	defer headBadResp.Body.Close()
	if headBadResp.StatusCode != http.StatusForbidden {
		t.Errorf("bad HEAD status = %d; want %d", headBadResp.StatusCode, http.StatusForbidden)
	}
	badHeadBytes, _ := io.ReadAll(headBadResp.Body)
	if len(badHeadBytes) != 0 {
		t.Errorf("bad HEAD response had body length %d; want 0", len(badHeadBytes))
	}

	// Verify POST method rejection
	postReq, err := http.NewRequestWithContext(context.Background(), http.MethodPost, srv.URL+"/v1/secret/data/signalloom/eap", nil)
	if err != nil {
		t.Fatalf("failed to create POST request: %v", err)
	}
	postResp, err := srv.Client().Do(postReq)
	if err != nil {
		t.Fatalf("POST request failed: %v", err)
	}
	defer postResp.Body.Close()
	if postResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST status = %d; want 405", postResp.StatusCode)
	}
	if allow := postResp.Header.Get("Allow"); allow != "GET, HEAD" {
		t.Errorf("POST Allow header = %q; want %q", allow, "GET, HEAD")
	}

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

// TestSharedVectors runs the cross-language table that the Python and
// TypeScript implementations also run (test/fixtures/tenant/hash-vectors.json).
func TestSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../../../test/fixtures/tenant/hash-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var table struct {
		Salt    string `json:"salt"`
		Vectors []struct {
			Name   string  `json:"name"`
			Input  string  `json:"input"`
			Repeat int     `json:"repeat"`
			Salt   *string `json:"salt"`
			Want   string  `json:"want"`
			Error  string  `json:"error"`
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &table); err != nil {
		t.Fatal(err)
	}
	wantErr := map[string]error{
		"empty": ErrEmptyTenant, "invalid": ErrInvalidTenant,
		"retired": ErrRetiredTenant, "salt": ErrSaltUnavailable,
	}
	for _, v := range table.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			in := v.Input
			if v.Repeat > 0 {
				in = strings.Repeat(in, v.Repeat)
			}
			salt := table.Salt
			if v.Salt != nil {
				salt = *v.Salt
			}
			got, err := DeriveTenantHash(in, salt)
			if v.Error != "" {
				if !errors.Is(err, wantErr[v.Error]) {
					t.Fatalf("%q: got (%q, %v); want error %s", in, got, err, v.Error)
				}
				return
			}
			if err != nil || got != v.Want {
				t.Fatalf("%q: got (%q, %v); want %s", in, got, err, v.Want)
			}
		})
	}
}
