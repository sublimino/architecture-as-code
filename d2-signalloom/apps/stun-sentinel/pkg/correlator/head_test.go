// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// headResponseWriter suppresses response bodies for HTTP HEAD requests (RFC 9110 Section 6.4.1).
type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(p), nil
}

// headBodySuppressingMiddleware wraps an http.Handler and suppresses the response body
// when the request method is HEAD, in compliance with RFC 9110 Section 6.4.1.
func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			if _, ok := w.(*headResponseWriter); !ok {
				w = &headResponseWriter{ResponseWriter: w}
			}
		}
		next.ServeHTTP(w, r)
	})
}

func TestSignalIngestMockMethodGatesAndHEADBodySuppression(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method not allowed"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"status":"created"}`))
	})

	srv := httptest.NewServer(headBodySuppressingMiddleware(handler))
	defer srv.Close()

	// 1. Valid POST receives 201 Created and non-empty body
	postReq, err := http.NewRequest(http.MethodPost, srv.URL, nil)
	if err != nil {
		t.Fatalf("failed to create POST request: %v", err)
	}
	postResp, err := http.DefaultClient.Do(postReq)
	if err != nil {
		t.Fatalf("POST request failed: %v", err)
	}
	postBody, err := io.ReadAll(postResp.Body)
	_ = postResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading POST body: %v", err)
	}
	if postResp.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201 Created on POST, got %d", postResp.StatusCode)
	}
	if len(postBody) == 0 {
		t.Fatal("expected non-empty body on successful POST")
	}

	// 2. HEAD to POST-only route receives 405 Method Not Allowed, Allow: POST, and exactly 0 body bytes
	headReq, err := http.NewRequest(http.MethodHead, srv.URL, nil)
	if err != nil {
		t.Fatalf("failed to create HEAD request: %v", err)
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
		t.Fatalf("expected 405 Method Not Allowed on HEAD, got %d", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST on 405, got %q", allow)
	}
	if len(headBody) != 0 {
		t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD 405, got %d bytes: %q", len(headBody), string(headBody))
	}

	// 3. GET to POST-only route receives 405 Method Not Allowed, Allow: POST, with non-empty error body
	getReq, err := http.NewRequest(http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("failed to create GET request: %v", err)
	}
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("GET request failed: %v", err)
	}
	getBody, err := io.ReadAll(getResp.Body)
	_ = getResp.Body.Close()
	if err != nil {
		t.Fatalf("failed reading GET body: %v", err)
	}
	if getResp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405 Method Not Allowed on GET, got %d", getResp.StatusCode)
	}
	if allow := getResp.Header.Get("Allow"); allow != "POST" {
		t.Fatalf("expected Allow: POST on 405, got %q", allow)
	}
	if len(getBody) == 0 {
		t.Fatal("expected non-empty error body on GET 405")
	}

	// 4. Other verbs (PUT, DELETE) also receive 405 with Allow: POST
	for _, verb := range []string{http.MethodPut, http.MethodDelete} {
		req, err := http.NewRequest(verb, srv.URL, nil)
		if err != nil {
			t.Fatalf("failed to create %s request: %v", verb, err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s request failed: %v", verb, err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("expected 405 on %s, got %d", verb, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Fatalf("expected Allow: POST on %s, got %q", verb, allow)
		}
	}
}

func TestSignalIngestMockErrorStatusHEADBodySuppression(t *testing.T) {
	for _, status := range []int{
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
		http.StatusNotFound,
		http.StatusRequestEntityTooLarge,
		http.StatusTooManyRequests,
		http.StatusInternalServerError,
		http.StatusServiceUnavailable,
	} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if status == http.StatusTooManyRequests {
					w.Header().Set("Retry-After", "1")
				}
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"error":"simulated failure"}`))
			})

			srv := httptest.NewServer(headBodySuppressingMiddleware(handler))
			defer srv.Close()

			headReq, err := http.NewRequest(http.MethodHead, srv.URL, nil)
			if err != nil {
				t.Fatalf("failed creating HEAD request: %v", err)
			}
			headResp, err := http.DefaultClient.Do(headReq)
			if err != nil {
				t.Fatalf("HEAD request failed: %v", err)
			}
			body, err := io.ReadAll(headResp.Body)
			_ = headResp.Body.Close()
			if err != nil {
				t.Fatalf("failed reading HEAD body: %v", err)
			}

			if headResp.StatusCode != status {
				t.Fatalf("expected status %d, got %d", status, headResp.StatusCode)
			}
			if len(body) != 0 {
				t.Fatalf("RFC 9110 violation: expected 0 body bytes on HEAD %d, got %d: %q", status, len(body), string(body))
			}
			if ct := headResp.Header.Get("Content-Type"); ct != "application/json" {
				t.Fatalf("expected Content-Type application/json, got %q", ct)
			}
		})
	}
}
