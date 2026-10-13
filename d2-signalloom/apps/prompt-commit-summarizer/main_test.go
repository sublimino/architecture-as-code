package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealth(t *testing.T) {
	mux := newRouter("http://mock-llm", "test-model")

	for _, endpoint := range []string{"/health", "/healthz", "/readyz"} {
		// GET
		req := httptest.NewRequest("GET", endpoint, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("expected status 200 for %s, got %d", endpoint, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("expected Content-Type text/plain; charset=utf-8 for %s, got %s", endpoint, ct)
		}
		if !strings.Contains(rec.Body.String(), "ok") {
			t.Fatalf("expected body to contain ok, got %s", rec.Body.String())
		}

		// HEAD
		req = httptest.NewRequest("HEAD", endpoint, nil)
		rec = httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("expected status 200 for HEAD %s, got %d", endpoint, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Fatalf("expected Content-Type text/plain; charset=utf-8 for HEAD %s, got %s", endpoint, ct)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("expected empty body for HEAD %s, got %d bytes", endpoint, rec.Body.Len())
		}

		// POST rejected
		req = httptest.NewRequest("POST", endpoint, nil)
		rec = httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("expected status 405 for POST %s, got %d", endpoint, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD" {
			t.Fatalf("expected Allow GET, HEAD for POST %s, got %s", endpoint, allow)
		}
	}
}

func TestSummarizeHandlerMethodGatesAndHead(t *testing.T) {
	mux := newRouter("http://mock-llm", "test-model")

	for _, method := range []string{"GET", "HEAD", "PUT", "DELETE"} {
		req := httptest.NewRequest(method, "/", nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("expected 405 for %s /, got %d", method, rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST" {
			t.Fatalf("expected Allow: POST for %s /, got %q", method, allow)
		}
		if method == "HEAD" && rec.Body.Len() != 0 {
			t.Fatalf("expected empty body for HEAD /, got %d bytes: %q", rec.Body.Len(), rec.Body.String())
		}
	}
}


func TestSummarizeHandlerPathIsolation(t *testing.T) {
	handler := makeSummarizeHandler("http://mock-llm", "test-model")

	for _, path := range []string{"/api/summarize", "/unknown", "/test"} {
		req := httptest.NewRequest("POST", path, bytes.NewReader([]byte(`{"diff":"test"}`)))
		rec := httptest.NewRecorder()
		handler(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("expected status 404 for path %s, got %d", path, rec.Code)
		}
	}
}

func TestCloudEventTypeFiltering(t *testing.T) {
	handler := makeSummarizeHandler("http://mock-llm", "test-model")

	// Event with unhandled Ce-Type should be ignored (204 No Content)
	req := httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"diff":"test"}`)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Ce-Type", "some.other.event.type")
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected status 204 for ignored Ce-Type, got %d", rec.Code)
	}

	// Event with padded unhandled Ce-Type should also be ignored
	reqPadded := httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"diff":"test"}`)))
	reqPadded.Header.Set("Content-Type", "application/json")
	reqPadded.Header.Set("Ce-Type", "  some.other.event.type \n")
	recPadded := httptest.NewRecorder()

	handler(recPadded, reqPadded)

	if recPadded.Code != http.StatusNoContent {
		t.Fatalf("expected status 204 for padded ignored Ce-Type, got %d", recPadded.Code)
	}
}

func TestMethodNotAllowed(t *testing.T) {
	handler := makeSummarizeHandler("http://mock-llm", "test-model")

	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status 405 Method Not Allowed, got %d", rec.Code)
	}
	if allow := rec.Header().Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow POST for GET /, got %s", allow)
	}
}

func TestInvalidJSON(t *testing.T) {
	handler := makeSummarizeHandler("http://mock-llm", "test-model")

	req := httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{not valid json`)))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400 Bad Request, got %d", rec.Code)
	}
}

func TestEmptyDiff(t *testing.T) {
	handler := makeSummarizeHandler("http://mock-llm", "test-model")

	for _, d := range []string{"", "   ", "\n\t  "} {
		payload, _ := json.Marshal(diffPayload{Diff: d})
		req := httptest.NewRequest("POST", "/", bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()

		handler(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Fatalf("expected status 400 for empty/whitespace diff, got %d", rec.Code)
		}
	}
}

func TestSummarizeHandlerSuccess(t *testing.T) {
	mockLLM := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var req llmRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if req.Model != "gemini-test" {
			http.Error(w, "unexpected model", http.StatusBadRequest)
			return
		}

		resp := llmResponse{
			Choices: []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			}{
				{
					Message: struct {
						Content string `json:"content"`
					}{
						Content: "feat(auth): add spiffe identity validation",
					},
				},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	})))
	defer mockLLM.Close()

	handler := makeSummarizeHandler(mockLLM.URL, "gemini-test")

	payload, _ := json.Marshal(diffPayload{Diff: "+ func ValidateSPIFFE() bool { return true }"})
	req := httptest.NewRequest("POST", "/", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Ce-Type", "dev.knative.source.github.push")
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var res summaryResponse
	if err := json.NewDecoder(rec.Body).Decode(&res); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if res.CommitMessage != "feat(auth): add spiffe identity validation" {
		t.Fatalf("unexpected commit message: %s", res.CommitMessage)
	}
	if res.Confidence < 0.9 {
		t.Fatalf("expected high confidence >= 0.9, got %f", res.Confidence)
	}
}

func TestSummarizeHandlerLargeDiffTruncated(t *testing.T) {
	receivedDiff := ""
	mockLLM := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var req llmRequest
		_ = json.Unmarshal(body, &req)
		if len(req.Messages) > 1 {
			receivedDiff = req.Messages[1].Content
		}

		resp := llmResponse{
			Choices: []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			}{
				{Message: struct {
					Content string `json:"content"`
				}{Content: "refactor: large diff refactoring"}},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	})))
	defer mockLLM.Close()

	handler := makeSummarizeHandler(mockLLM.URL, "gemini-test")

	// Generate diff exceeding 8000 bytes
	hugeDiff := strings.Repeat("+ line of code with changes\n", 400)
	payload, _ := json.Marshal(diffPayload{Diff: hugeDiff})
	req := httptest.NewRequest("POST", "/", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	if !strings.Contains(receivedDiff, "... (truncated)") {
		t.Fatalf("expected truncated marker in received diff, got %s", receivedDiff[len(receivedDiff)-100:])
	}
}

func TestSummarizeHandlerLLMFailure(t *testing.T) {
	mockLLM := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		http.Error(w, "upstream rate limit exceeded", http.StatusTooManyRequests)
	})))
	defer mockLLM.Close()

	handler := makeSummarizeHandler(mockLLM.URL, "gemini-test")

	payload, _ := json.Marshal(diffPayload{Diff: "+ some changes"})
	req := httptest.NewRequest("POST", "/", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("expected status 502 Bad Gateway on upstream error, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestHeadErrorBodySuppression(t *testing.T) {
	router := newRouter("http://mock-llm", "test-model")

	// 1. Unknown route HEAD -> 404 with 0 body bytes
	reqUnknown := httptest.NewRequest(http.MethodHead, "/unknown-route", nil)
	recUnknown := httptest.NewRecorder()
	router.ServeHTTP(recUnknown, reqUnknown)
	if recUnknown.Code != http.StatusNotFound {
		t.Fatalf("expected status 404 for HEAD /unknown-route, got %d", recUnknown.Code)
	}
	if recUnknown.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on HEAD /unknown-route, got %d bytes: %q", recUnknown.Body.Len(), recUnknown.Body.String())
	}

	// 2. Root HEAD -> 405 with 0 body bytes and Allow: POST
	reqRoot := httptest.NewRequest(http.MethodHead, "/", nil)
	recRoot := httptest.NewRecorder()
	router.ServeHTTP(recRoot, reqRoot)
	if recRoot.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status 405 for HEAD /, got %d", recRoot.Code)
	}
	if recRoot.Header().Get("Allow") != "POST" {
		t.Fatalf("expected Allow: POST for HEAD /, got %q", recRoot.Header().Get("Allow"))
	}
	if recRoot.Body.Len() != 0 {
		t.Fatalf("expected 0 body bytes on HEAD /, got %d bytes: %q", recRoot.Body.Len(), recRoot.Body.String())
	}

	// 3. Health probes HEAD -> 200 with 0 body bytes
	for _, ep := range []string{"/health", "/healthz", "/readyz"} {
		req := httptest.NewRequest(http.MethodHead, ep, nil)
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("expected status 200 for HEAD %s, got %d", ep, rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("expected 0 body bytes for HEAD %s, got %d bytes: %q", ep, rec.Body.Len(), rec.Body.String())
		}
	}
}

func TestPromptSummarizerMockServerMethodGatingAndHEAD(t *testing.T) {
	mockLLM := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"feat: test"}}]}`))
	})))
	defer mockLLM.Close()

	client := mockLLM.Client()

	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, err := http.NewRequest(method, mockLLM.URL, nil)
		if err != nil {
			t.Fatalf("NewRequest(%s): %v", method, err)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Do(%s): %v", method, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s status = %d, want 405", method, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Errorf("%s Allow = %q, want POST", method, allow)
		}
	}

	headReq, err := http.NewRequest(http.MethodHead, mockLLM.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest(HEAD): %v", err)
	}
	headResp, err := client.Do(headReq)
	if err != nil {
		t.Fatalf("Do(HEAD): %v", err)
	}
	body, _ := io.ReadAll(headResp.Body)
	headResp.Body.Close()
	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow = %q, want POST", allow)
	}
	if len(body) != 0 {
		t.Errorf("HEAD body length = %d, want 0", len(body))
	}
}

