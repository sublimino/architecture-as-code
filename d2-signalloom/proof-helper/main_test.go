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
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		if r.URL.Path != "/v1/auth/jwt/login" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth":{"client_token":"bao-token"}}`))
	})))
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
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		http.Error(w, "signature validation failed", http.StatusBadRequest)
	})))
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
	bao := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		if r.URL.Path != "/v1/auth/jwt/login" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth":{"client_token":"ephemeral"}}`))
	})))
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

// A denial proof must distinguish "SPIRE refused this identity" from "the
// fetch broke". Both are non-nil errors, and treating the second as the first
// is the shape this repo's own AGENTS.md names: `nc` cannot tell a firewall
// from a typo, and a gate that always passes is a wait that can never succeed
// wearing a different hat.
//
// The stakes are asymmetric. If a broken socket, a missing binary, an
// unreachable agent or a crash-looping SPIRE all read as "denied as expected",
// then bao-spire-negative-proof reports a security boundary holding at exactly
// the moments it is least able to observe one — and scripts/bao-spire-proof.sh
// greps for that marker as its only positive evidence of denial.
//
// Each input below is a real failure seen on a lane, not an invented string.
func TestExpectDeniedRejectsFailuresThatAreNotDenials(t *testing.T) {
	for _, notADenial := range []string{
		"rpc error: code = Unavailable desc = connection error: desc = \"transport: Error while dialing: dial unix /run/spire/sockets/agent.sock: connect: no such file or directory\"",
		"exec: \"/usr/local/bin/signalloom-spire-proof\": executable file not found in $PATH",
		"rpc error: code = DeadlineExceeded desc = context deadline exceeded",
		"x509svid: could not verify leaf certificate: x509: certificate signed by unknown authority",
		"",
	} {
		var stdout strings.Builder
		broken := func(string, ...string) ([]byte, error) {
			return []byte(notADenial), errors.New("exit status 1")
		}
		// runWithPause with a no-op pause, not run(): a non-denial exhausts all
		// 30 attempts, so the real one-second backoff makes this 30s per input
		// and ~145s for the table. The retry COUNT is what the behaviour needs,
		// not the wall time.
		code := runWithPause([]string{"expect-denied"}, &stdout, io.Discard, broken, func(time.Duration) {})
		if code == 0 {
			t.Fatalf("a non-denial failure was accepted as proof of denial: %q", notADenial)
		}
		if strings.Contains(stdout.String(), "denied as expected") {
			t.Fatalf("a non-denial failure emitted the denial marker: %q", notADenial)
		}
	}
}

func TestProbeSVIDWritesOnlyTokenFreeSubjectEvidence(t *testing.T) {
	const subject = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner"
	evidencePath := filepath.Join(t.TempDir(), "termination-log")
	originalPath := probeEvidencePath
	probeEvidencePath = evidencePath
	t.Cleanup(func() { probeEvidencePath = originalPath })
	runner := func(name string, _ ...string) ([]byte, error) {
		if name != spireAgent {
			t.Fatalf("unexpected executable: %s", name)
		}
		return []byte(`{"svids":[{"svid":"` + fixtureJWT(subject) + `"}]}`), nil
	}
	if code := run([]string{"probe-svid"}, io.Discard, io.Discard, runner); code != 0 {
		t.Fatalf("probe-svid returned %d", code)
	}
	evidence, err := os.ReadFile(evidencePath)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(evidence, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["outcome"] != "pass" || payload["spiffe_id"] != subject {
		t.Fatalf("unexpected evidence: %s", evidence)
	}
	rendered := strings.ToLower(string(evidence))
	if strings.Contains(rendered, "header.") || strings.Contains(rendered, "client_token") {
		t.Fatalf("probe leaked credential material: %s", evidence)
	}
}

func TestProbeOpenBaoWritesMetadataWithoutClientToken(t *testing.T) {
	const subject = "spiffe://signalloom.demo/platform/signalloom/tenant/acme/project/payments/agent/planner"
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth":{"client_token":"must-not-leak","renewable":false,"lease_duration":300,"token_type":"batch"}}`))
	})))
	defer server.Close()
	evidencePath := filepath.Join(t.TempDir(), "termination-log")
	originalPath, originalClient := probeEvidencePath, openBaoClient
	probeEvidencePath, openBaoClient = evidencePath, server.Client()
	t.Cleanup(func() { probeEvidencePath, openBaoClient = originalPath, originalClient })
	runner := func(string, ...string) ([]byte, error) {
		return []byte(`{"svids":[{"svid":"` + fixtureJWT(subject) + `"}]}`), nil
	}
	if code := run([]string{"probe-openbao", "-address", server.URL, "-role", "agent-trust-planner"}, io.Discard, io.Discard, runner); code != 0 {
		t.Fatalf("probe-openbao returned %d", code)
	}
	evidence, err := os.ReadFile(evidencePath)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(evidence, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["renewable"] != false || payload["lease_duration"] != float64(300) || payload["token_type"] != "batch" {
		t.Fatalf("unexpected OpenBao evidence: %s", evidence)
	}
	if strings.Contains(string(evidence), "must-not-leak") || strings.Contains(string(evidence), "client_token") {
		t.Fatalf("OpenBao probe leaked token: %s", evidence)
	}
}

func TestA2AHandlerHealthAndChallengeMethods(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	handler := newA2AHandlerWithInstance(http.DefaultClient, "http://127.0.0.1:8200", "role", "sub", pub, "test-nonce")

	for _, path := range []string{"/health", "/healthz", "/readyz"} {
		// GET
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s returned %d, want 200", path, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("GET %s Content-Type = %q, want application/json", path, ct)
		}

		// HEAD
		req = httptest.NewRequest(http.MethodHead, path, nil)
		rec = httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("HEAD %s returned %d, want 200", path, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("HEAD %s Content-Type = %q, want application/json", path, ct)
		}

		// Disallowed methods (POST, PUT, DELETE, PATCH) rejected with Allow: GET, HEAD and non-empty body
		for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			req = httptest.NewRequest(m, path, nil)
			rec = httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Errorf("%s %s returned %d, want 405", m, path, rec.Code)
			}
			if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
				t.Errorf("%s %s Allow = %q, want GET, HEAD", m, path, allow)
			}
			if rec.Body.Len() == 0 {
				t.Errorf("%s %s expected non-empty error body", m, path)
			}
		}
	}

	// /a2a disallowed methods (GET, PUT, DELETE, PATCH) rejected with Allow: POST
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		reqA2A := httptest.NewRequest(m, "/a2a", nil)
		recA2A := httptest.NewRecorder()
		handler.ServeHTTP(recA2A, reqA2A)
		if recA2A.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /a2a returned %d, want 405", m, recA2A.Code)
		}
		if allow := recA2A.Header().Get("Allow"); allow != "POST" {
			t.Errorf("%s /a2a Allow = %q, want POST", m, allow)
		}
		if recA2A.Body.Len() == 0 {
			t.Errorf("%s /a2a expected non-empty error body", m)
		}
	}

	// Challenge GET
	req := httptest.NewRequest(http.MethodGet, "/challenge", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("GET /challenge returned %d, want 200", rec.Code)
	}
	var challenge struct {
		InstanceNonce string `json:"instanceNonce"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &challenge); err != nil || challenge.InstanceNonce != "test-nonce" {
		t.Errorf("GET /challenge invalid response: %v, %+v", err, challenge)
	}

	// Challenge HEAD
	req = httptest.NewRequest(http.MethodHead, "/challenge", nil)
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("HEAD /challenge returned %d, want 200", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD /challenge body length = %d, want 0", rec.Body.Len())
	}

	// Challenge disallowed methods (POST, PUT, DELETE, PATCH) rejected with Allow: GET, HEAD
	for _, m := range []string{http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req = httptest.NewRequest(m, "/challenge", nil)
		rec = httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /challenge returned %d, want 405", m, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Errorf("%s /challenge Allow = %q, want GET, HEAD", m, allow)
		}
		if rec.Body.Len() == 0 {
			t.Errorf("%s /challenge expected non-empty error body", m)
		}
	}

	// /a2a HEAD rejected with Allow: POST and empty body
	reqA2AHead := httptest.NewRequest(http.MethodHead, "/a2a", nil)
	recA2AHead := httptest.NewRecorder()
	handler.ServeHTTP(recA2AHead, reqA2AHead)
	if recA2AHead.Code != http.StatusMethodNotAllowed {
		t.Errorf("HEAD /a2a returned %d, want 405", recA2AHead.Code)
	}
	if allow := recA2AHead.Header().Get("Allow"); allow != "POST" {
		t.Errorf("HEAD /a2a Allow = %q, want POST", allow)
	}
	if recA2AHead.Body.Len() != 0 {
		t.Errorf("HEAD /a2a body length = %d, want 0", recA2AHead.Body.Len())
	}
}

func TestProofHelperHeadUnmatchedRoutes(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	handler := newA2AHandlerWithInstance(http.DefaultClient, "http://127.0.0.1:8200", "role", "spiffe://example.org/ns/default/sa/caller", publicKey, "test-nonce")

	for _, path := range []string{"/unknown", "/api/v1/invalid", "/health/subpath"} {
		req := httptest.NewRequest(http.MethodHead, path, nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Errorf("HEAD %s returned %d, want 404", path, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Errorf("HEAD %s body length = %d, want 0", path, rec.Body.Len())
		}
	}
}

func TestOpenBaoMockMethodGatesAndHEADBodySuppression(t *testing.T) {
	baoHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		if r.URL.Path != "/v1/auth/jwt/login" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not found"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"auth":{"client_token":"valid-token"}}`))
	})

	srv := httptest.NewServer(headBodySuppressingMiddleware(baoHandler))
	defer srv.Close()

	// 1. HEAD request on POST route returns 405 Method Not Allowed with Allow: POST and 0 body bytes
	headReq, err := http.NewRequest(http.MethodHead, srv.URL+"/v1/auth/jwt/login", nil)
	if err != nil {
		t.Fatalf("failed creating HEAD request: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	headBody, err := io.ReadAll(headResp.Body)
	_ = headResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading HEAD body: %v", err)
	}
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 on HEAD, got %d", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if len(headBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD 405, got %d: %q", len(headBody), string(headBody))
	}

	// 2. Disallowed methods (GET, PUT, DELETE, PATCH) on POST route return 405 with Allow: POST and non-empty error body
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, err := http.NewRequest(m, srv.URL+"/v1/auth/jwt/login", nil)
		if err != nil {
			t.Fatalf("failed creating %s request: %v", m, err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s request failed: %v", m, err)
		}
		body, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			t.Fatalf("failed reading %s body: %v", m, err)
		}
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("expected 405 on %s, got %d", m, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Fatalf("expected Allow: POST on %s 405, got %q", m, allow)
		}
		if len(body) == 0 {
			t.Fatalf("expected non-empty error body on %s 405", m)
		}
	}

	// 3. HEAD on simulated 500 error route returns 0 body bytes
	errSrv := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"internal openbao panic"}`))
	})))
	defer errSrv.Close()

	errHeadReq, _ := http.NewRequest(http.MethodHead, errSrv.URL+"/v1/auth/jwt/login", nil)
	errHeadResp, err := http.DefaultClient.Do(errHeadReq)
	if err != nil {
		t.Fatalf("HEAD err request failed: %v", err)
	}
	errBody, _ := io.ReadAll(errHeadResp.Body)
	_ = errHeadResp.Body.Close()
	if errHeadResp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("expected 500 on HEAD, got %d", errHeadResp.StatusCode)
	}
	if len(errBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD 500, got %d: %q", len(errBody), string(errBody))
	}
}

func TestMethodNotAllowedDirect(t *testing.T) {
	// GET request -> 405 with Allow header and body
	recGet := httptest.NewRecorder()
	reqGet := httptest.NewRequest(http.MethodGet, "/test", nil)
	methodNotAllowed(recGet, reqGet, "POST")
	if recGet.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", recGet.Code)
	}
	if allow := recGet.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST, got %q", allow)
	}
	if ct := recGet.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Fatalf("expected text/plain Content-Type, got %q", ct)
	}
	if recGet.Body.String() != "method not allowed\n" {
		t.Fatalf("expected 'method not allowed\\n', got %q", recGet.Body.String())
	}

	// HEAD request -> 405 with Allow header and 0 body bytes (RFC 9110 Section 6.4.1)
	recHead := httptest.NewRecorder()
	reqHead := httptest.NewRequest(http.MethodHead, "/test", nil)
	methodNotAllowed(recHead, reqHead, "POST")
	if recHead.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 on HEAD, got %d", recHead.Code)
	}
	if allow := recHead.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST on HEAD, got %q", allow)
	}
	if recHead.Body.Len() != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD 405, got %d: %q", recHead.Body.Len(), recHead.Body.String())
	}

	// Nil request -> 405 without panic
	recNil := httptest.NewRecorder()
	methodNotAllowed(recNil, nil, "GET, HEAD")
	if recNil.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 on nil req, got %d", recNil.Code)
	}
	if allow := recNil.Header().Get("Allow"); allow != "GET, HEAD" {
		t.Fatalf("expected Allow: GET, HEAD, got %q", allow)
	}
	if recNil.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on nil req, got %d", recNil.Body.Len())
	}
}


