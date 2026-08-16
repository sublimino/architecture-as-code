package main

// Adversarial tests for the proof-helper.
//
// Focus: replay cache race conditions, A2A handler bypass vectors, extractJWT edge cases,
// authorization message construction.

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Replay cache adversarial tests.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestReplayCacheConcurrentAccess hammers the replay cache from multiple goroutines to
// verify the mutex protects the map correctly.
func TestReplayCacheConcurrentAccess(t *testing.T) {
	cache := newReplayCache(10000)
	now := time.Now().Unix()

	var wg sync.WaitGroup
	const goroutines = 50
	const perGoroutine = 100
	consumed := make([]int, goroutines)

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < perGoroutine; i++ {
				nonce := fmt.Sprintf("g%d-n%d", id, i)
				if cache.consume(nonce, now+60, now) {
					consumed[id]++
				}
			}
		}(g)
	}
	wg.Wait()

	total := 0
	for _, c := range consumed {
		total += c
	}
	// Each nonce should be consumed exactly once.
	if total != goroutines*perGoroutine {
		t.Errorf("consumed %d nonces, want %d; some nonces were rejected or double-consumed",
			total, goroutines*perGoroutine)
	}
}

// TestReplayCacheSameNonceTwice verifies that the same nonce cannot be consumed twice.
func TestReplayCacheSameNonceTwice(t *testing.T) {
	cache := newReplayCache(100)
	now := time.Now().Unix()

	if !cache.consume("nonce-1", now+60, now) {
		t.Fatal("first consume should succeed")
	}
	if cache.consume("nonce-1", now+60, now) {
		t.Fatal("second consume of same nonce should be rejected")
	}
}

// TestReplayCacheExpiry checks that expired nonces are cleaned up and don't consume capacity.
func TestReplayCacheExpiry(t *testing.T) {
	cache := newReplayCache(2)
	baseTime := int64(1000)

	// Fill the cache.
	if !cache.consume("a", baseTime+10, baseTime) {
		t.Fatal("first consume should succeed")
	}
	if !cache.consume("b", baseTime+10, baseTime) {
		t.Fatal("second consume should succeed")
	}

	// Cache is full (max=2). New nonce should be rejected.
	if cache.consume("c", baseTime+20, baseTime) {
		t.Fatal("cache at capacity should reject new nonces")
	}

	// Advance time past expiry of a and b.
	futureTime := baseTime + 15

	// Now "c" should be accepted because a and b expired.
	if !cache.consume("c", futureTime+10, futureTime) {
		t.Error("after expiry of old nonces, new nonces should be accepted")
	}
}

// TestReplayCacheRejectsEmptyNonce verifies that empty nonces are always rejected.
func TestReplayCacheRejectsEmptyNonce(t *testing.T) {
	cache := newReplayCache(100)
	now := time.Now().Unix()
	if cache.consume("", now+60, now) {
		t.Error("empty nonce should be rejected")
	}
}

// TestReplayCacheRejectsExpiredNonce verifies that a nonce whose expiry is in the past
// is rejected.
func TestReplayCacheRejectsExpiredNonce(t *testing.T) {
	cache := newReplayCache(100)
	now := time.Now().Unix()
	if cache.consume("nonce", now-1, now) {
		t.Error("expired nonce should be rejected")
	}
}

// TestReplayCacheRejectsExactlyExpiredNonce checks the boundary: expiry == now.
func TestReplayCacheRejectsExactlyExpiredNonce(t *testing.T) {
	cache := newReplayCache(100)
	now := time.Now().Unix()
	if cache.consume("nonce", now, now) {
		t.Error("nonce with expiry == now should be rejected (expires <= now)")
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// A2A handler adversarial tests.
// ─────────────────────────────────────────────────────────────────────────────────────────────

func adversarialFixtureJWT(subject string) string {
	payload, _ := json.Marshal(map[string]any{"sub": subject, "exp": time.Now().Add(time.Minute).Unix()})
	return "header." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func setupA2ATest(t *testing.T) (http.Handler, ed25519.PrivateKey, string) {
	t.Helper()
	const planner = "spiffe://signalloom.demo/agent/planner"
	bao := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"auth":{"client_token":"ephemeral"}}`))
	}))
	t.Cleanup(bao.Close)

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	handler := newA2AHandlerWithInstance(bao.Client(), bao.URL, "test-role", planner, publicKey, "test-instance")
	return handler, privateKey, planner
}

// TestA2ARejectsWrongHTTPMethod checks that GET requests to /a2a are rejected.
func TestA2ARejectsWrongHTTPMethod(t *testing.T) {
	handler, _, _ := setupA2ATest(t)
	req := httptest.NewRequest(http.MethodGet, "/a2a", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET /a2a: expected 405, got %d", w.Code)
	}
}

// TestA2ARejectsMissingSPIFFEHeader checks that a request without the SPIFFE JWT header
// is rejected.
func TestA2ARejectsMissingSPIFFEHeader(t *testing.T) {
	handler, _, _ := setupA2ATest(t)
	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("missing JWT header: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsWrongAction checks that an unauthorized action is rejected.
func TestA2ARejectsWrongAction(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"admin.delete","Resource":"case/runtime-proof"}`)
	timestamp := time.Now().Unix()
	nonce := "wrong-action-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("wrong action: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsInvalidResource checks that a resource not matching the regex is rejected.
func TestA2ARejectsInvalidResource(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)

	invalidResources := []string{
		"case/../etc/passwd",
		"case/" + strings.Repeat("A", 200), // too long
		"notacase/valid",
		"case/has spaces",
		"case/has.dots",
	}

	for _, resource := range invalidResources {
		t.Run(resource[:min(len(resource), 30)], func(t *testing.T) {
			body, _ := json.Marshal(map[string]string{
				"Action":   "triage.analyze",
				"Resource": resource,
			})
			timestamp := time.Now().Unix()
			nonce := fmt.Sprintf("res-nonce-%s", resource[:min(len(resource), 10)])
			instance := "test-instance"

			req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
			req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
			req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
			req.Header.Set("X-Agent-Trust-Nonce", nonce)
			req.Header.Set("X-Agent-Trust-Instance", instance)
			req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
				ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))

			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)
			if w.Code != http.StatusForbidden {
				t.Errorf("resource %q: expected 403, got %d", resource[:min(len(resource), 30)], w.Code)
			}
		})
	}
}

// TestA2ARejectsWrongInstanceNonce checks that a request with the wrong instance nonce
// is rejected (protects against requests to a restarted receiver).
func TestA2ARejectsWrongInstanceNonce(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	timestamp := time.Now().Unix()
	nonce := "wrong-instance-nonce"
	wrongInstance := "wrong-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", wrongInstance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, wrongInstance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("wrong instance nonce: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsStaleTimestamp checks that a request with a timestamp older than 30 seconds
// is rejected.
func TestA2ARejectsStaleTimestamp(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	staleTimestamp := time.Now().Unix() - 60 // 60 seconds in the past
	nonce := "stale-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(staleTimestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, staleTimestamp, nonce, instance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("stale timestamp: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsFutureTimestamp checks that a far-future timestamp is rejected.
func TestA2ARejectsFutureTimestamp(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	futureTimestamp := time.Now().Unix() + 60 // 60 seconds in the future
	nonce := "future-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(futureTimestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, futureTimestamp, nonce, instance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("future timestamp: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsTamperedSignature checks that a valid request with a tampered signature
// is rejected.
func TestA2ARejectsTamperedSignature(t *testing.T) {
	handler, _, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	timestamp := time.Now().Unix()
	nonce := "tampered-sig-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString([]byte("tampered-signature")))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("tampered signature: expected 403, got %d", w.Code)
	}
}

// TestA2ARejectsExtraFieldsInBody checks that unknown fields in the request body are rejected
// (DisallowUnknownFields is enabled).
func TestA2ARejectsExtraFieldsInBody(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof","Evil":"payload"}`)
	timestamp := time.Now().Unix()
	nonce := "extra-fields-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("extra fields in body: expected 403, got %d", w.Code)
	}
}

// TestA2AOversizedBody checks that a body > 4096 bytes is rejected.
func TestA2AOversizedBody(t *testing.T) {
	handler, privateKey, planner := setupA2ATest(t)
	jwt := adversarialFixtureJWT(planner)
	body := []byte(`{"Action":"triage.analyze","Resource":"case/` + strings.Repeat("A", 5000) + `"}`)
	timestamp := time.Now().Unix()
	nonce := "oversize-nonce"
	instance := "test-instance"

	req := httptest.NewRequest(http.MethodPost, "/a2a", strings.NewReader(string(body)))
	req.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	req.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	req.Header.Set("X-Agent-Trust-Nonce", nonce)
	req.Header.Set("X-Agent-Trust-Instance", instance)
	req.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(
		ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))

	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Errorf("oversized body: expected 403, got %d", w.Code)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// extractJWT edge cases (mirroring cardvault-agent tests for the separate implementation).
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestExtractJWTProofHelperEdgeCases checks the proof-helper's own extractJWT implementation.
func TestExtractJWTProofHelperEdgeCases(t *testing.T) {
	for name, tc := range map[string]struct {
		input   string
		wantErr bool
	}{
		"valid":      {`{"svid":"jwt-value"}`, false},
		"empty":      {`{"svid":""}`, true},
		"absent":     {`{"other":"value"}`, true},
		"multiple":   {`{"a":{"svid":"one"},"b":{"svid":"two"}}`, true},
		"non-string": {`{"svid":42}`, true},
		"malformed":  {`{not json`, true},
		"null-svid":  {`{"svid":null}`, true},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := extractJWT([]byte(tc.input))
			if (err != nil) != tc.wantErr {
				t.Errorf("extractJWT(%s): err=%v, wantErr=%v", name, err, tc.wantErr)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// jwtSubject edge cases.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestJWTSubjectEdgeCases tests the jwtSubject function with various malformed inputs.
func TestJWTSubjectEdgeCases(t *testing.T) {
	for name, tc := range map[string]struct {
		token string
		want  string
	}{
		"valid": {
			adversarialFixtureJWT("spiffe://test"),
			"spiffe://test",
		},
		"empty":            {"", ""},
		"no-dots":          {"nodots", ""},
		"one-dot":          {"one.dot", ""},
		"four-dots":        {"a.b.c.d", ""}, // too many parts
		"empty-payload":    {"header..signature", ""},
		"invalid-base64":   {"header.!!!.signature", ""},
		"no-subject":       {"header." + base64.RawURLEncoding.EncodeToString([]byte(`{"exp":123}`)) + ".sig", ""},
		"empty-subject":    {"header." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":""}`)) + ".sig", ""},
		"non-string-sub":   {"header." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":123}`)) + ".sig", ""},
		"malformed-json":   {"header." + base64.RawURLEncoding.EncodeToString([]byte(`{bad`)) + ".sig", ""},
	} {
		t.Run(name, func(t *testing.T) {
			got := jwtSubject(tc.token)
			if got != tc.want {
				t.Errorf("jwtSubject(%q) = %q, want %q", name, got, tc.want)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Challenge endpoint.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestChallengeEndpointReturnsInstanceNonce verifies the /challenge endpoint.
func TestChallengeEndpointReturnsInstanceNonce(t *testing.T) {
	handler, _, _ := setupA2ATest(t)
	req := httptest.NewRequest(http.MethodGet, "/challenge", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("/challenge: expected 200, got %d", w.Code)
	}

	var resp struct {
		InstanceNonce string `json:"instanceNonce"`
	}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp.InstanceNonce != "test-instance" {
		t.Errorf("instanceNonce = %q, want %q", resp.InstanceNonce, "test-instance")
	}
}

// TestReadyzEndpoint verifies the /readyz endpoint.
func TestReadyzEndpoint(t *testing.T) {
	handler, _, _ := setupA2ATest(t)
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("/readyz: expected 200, got %d", w.Code)
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// A2A resource regex boundary tests.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestA2AResourceRegex directly tests the regex pattern.
func TestA2AResourceRegex(t *testing.T) {
	valid := []string{
		"case/a",
		"case/runtime-proof",
		"case/A-B_C",
		"case/" + strings.Repeat("x", 123), // max length
	}
	invalid := []string{
		"",
		"case/",
		"case/ ",
		"case/" + strings.Repeat("x", 124), // too long
		"case/has.dot",
		"case/has space",
		"notcase/valid",
		"Case/valid", // capital C
	}

	for _, r := range valid {
		if !a2aResource.MatchString(r) {
			t.Errorf("resource %q should be valid", r)
		}
	}
	for _, r := range invalid {
		if a2aResource.MatchString(r) {
			t.Errorf("resource %q should be invalid", r)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────────────────────
// Probe evidence.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// TestWriteProbeEvidenceContainsExpectedFields checks the probe evidence structure.
func TestWriteProbeEvidenceContainsExpectedFields(t *testing.T) {
	path := t.TempDir() + "/evidence.json"
	original := probeEvidencePath
	probeEvidencePath = path
	t.Cleanup(func() { probeEvidencePath = original })

	writeProbeEvidence("pass", "test reason", "spiffe://test/id")

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var evidence map[string]string
	if err := json.Unmarshal(data, &evidence); err != nil {
		t.Fatal(err)
	}

	for _, key := range []string{"observed_at", "outcome", "reason", "spiffe_id"} {
		if _, ok := evidence[key]; !ok {
			t.Errorf("evidence missing key %q", key)
		}
	}
	if evidence["outcome"] != "pass" {
		t.Errorf("outcome = %q, want %q", evidence["outcome"], "pass")
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
