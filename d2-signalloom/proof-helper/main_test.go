package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fixtureJWT(subject string) string {
	payload, _ := json.Marshal(map[string]any{"sub": subject, "exp": time.Now().Add(time.Minute).Unix()})
	return "header." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func signedA2ARequest(privateKey ed25519.PrivateKey, jwt, nonce, instance string) *http.Request {
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	timestamp := time.Now().Unix()
	request := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	request.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	request.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	request.Header.Set("X-Agent-Trust-Nonce", nonce)
	request.Header.Set("X-Agent-Trust-Instance", instance)
	request.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))
	return request
}

func TestExchangeJWTStoresOpenBaoToken(t *testing.T) {
	var request struct {
		Role string `json:"role"`
		JWT  string `json:"jwt"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/auth/jwt/login" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		_, _ = w.Write([]byte(`{"auth":{"client_token":"bao-token"}}`))
	}))
	defer server.Close()

	dir := t.TempDir()
	jwtPath := filepath.Join(dir, "jwt")
	if err := os.WriteFile(jwtPath, []byte("header.payload.signature"), 0o600); err != nil {
		t.Fatal(err)
	}
	tokenPath := filepath.Join(dir, "home", ".bao-token")
	if err := exchangeJWT(server.Client(), server.URL, "signalloom-fe-signalloom", jwtPath, tokenPath); err != nil {
		t.Fatal(err)
	}
	if request.Role != "signalloom-fe-signalloom" || request.JWT != "header.payload.signature" {
		t.Fatalf("unexpected login request: %+v", request)
	}
	token, err := os.ReadFile(tokenPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(token) != "bao-token" {
		t.Fatalf("unexpected OpenBao token: %q", token)
	}
}

func TestExchangeJWTRejectsUnsuccessfulLogin(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "signature validation failed", http.StatusBadRequest)
	}))
	defer server.Close()

	jwtPath := filepath.Join(t.TempDir(), "jwt")
	if err := os.WriteFile(jwtPath, []byte("jwt"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := exchangeJWT(server.Client(), server.URL, "role", jwtPath, filepath.Join(t.TempDir(), ".bao-token")); err == nil {
		t.Fatal("unsuccessful OpenBao login unexpectedly succeeded")
	}
}

func TestOpenBaoClientHasBoundedTimeout(t *testing.T) {
	if openBaoClient.Timeout != 30*time.Second {
		t.Fatalf("unexpected OpenBao timeout: %s", openBaoClient.Timeout)
	}
}

func TestA2AReceiverRequiresOpenBaoValidatedExactSPIFFEIdentity(t *testing.T) {
	const planner = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner"
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/jwt/login" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"auth":{"client_token":"ephemeral"}}`))
	}))
	defer bao.Close()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	receiver := newA2AHandlerWithInstance(bao.Client(), bao.URL, "agent-trust-planner", planner, publicKey, "instance-one")

	request := signedA2ARequest(privateKey, fixtureJWT(planner), "first", "instance-one")
	response := httptest.NewRecorder()
	receiver.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"decision":"allow"`) {
		t.Fatalf("unexpected allow response: %d %s", response.Code, response.Body.String())
	}
	replayed := request.Clone(request.Context())
	replayed.Body = io.NopCloser(strings.NewReader(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`))
	replayResult := httptest.NewRecorder()
	receiver.ServeHTTP(replayResult, replayed)
	if replayResult.Code != http.StatusForbidden {
		t.Fatalf("expected replay denial, got %d", replayResult.Code)
	}
	restarted := newA2AHandlerWithInstance(bao.Client(), bao.URL, "agent-trust-planner", planner, publicKey, "instance-two")
	restartReplay := httptest.NewRecorder()
	replayed.Body = io.NopCloser(strings.NewReader(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`))
	restarted.ServeHTTP(restartReplay, replayed)
	if restartReplay.Code != http.StatusForbidden {
		t.Fatalf("expected pre-restart request denial, got %d", restartReplay.Code)
	}
	liveReceiver := httptest.NewServer(receiver)
	defer liveReceiver.Close()
	if err := callA2A(liveReceiver.Client(), liveReceiver.URL+"/a2a", request.Header.Get("X-SPIFFE-JWT-SVID"), privateKey); err != nil {
		t.Fatalf("signed network request failed: %v", err)
	}

	index := 0
	for name, token := range map[string]string{"missing": "", "wrong-subject": fixtureJWT("spiffe://signalloom.demo/other")} {
		t.Run(name, func(t *testing.T) {
			index++
			denied := signedA2ARequest(privateKey, token, fmt.Sprintf("denied-%d", index), "instance-one")
			result := httptest.NewRecorder()
			receiver.ServeHTTP(result, denied)
			if result.Code != http.StatusForbidden {
				t.Fatalf("expected denial, got %d", result.Code)
			}
		})
	}
}

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

func TestExpectDeniedTreatsIdentityDenialAsSuccess(t *testing.T) {
	var stdout strings.Builder
	denied := func(string, ...string) ([]byte, error) {
		return []byte("rpc error: code = PermissionDenied desc = no identity issued"), errors.New("exit status 1")
	}
	if code := run([]string{"expect-denied"}, &stdout, os.Stderr, denied); code != 0 {
		t.Fatalf("expected denial mode to succeed, got %d", code)
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
