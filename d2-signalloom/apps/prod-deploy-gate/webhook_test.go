package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestSendApprovalCard_Success(t *testing.T) {
	var receivedCard ApprovalCard
	var callCount int32

	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		if ct := r.Header.Get("Content-Type"); ct != "application/json" {
			t.Errorf("expected application/json Content-Type, got %q", ct)
		}

		if err := json.NewDecoder(r.Body).Decode(&receivedCard); err != nil {
			t.Errorf("failed to decode request body: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		atomic.AddInt32(&callCount, 1)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "delivered"})
	})))
	defer server.Close()

	card := ApprovalCard{
		RequestID:   "req-12345",
		Description: "Production deploy for core-ledger",
		Requester:   "alice@example.com",
		ApproveURL:  "https://gate.example.com/gate/approve?req=req-12345",
		Token:       "signed-token-xyz",
		ExpiresAt:   time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := SendApprovalCard(ctx, server.URL, card); err != nil {
		t.Fatalf("SendApprovalCard failed: %v", err)
	}

	if atomic.LoadInt32(&callCount) != 1 {
		t.Errorf("expected 1 call, got %d", callCount)
	}
	if receivedCard.RequestID != card.RequestID {
		t.Errorf("expected RequestID %q, got %q", card.RequestID, receivedCard.RequestID)
	}
	if receivedCard.Description != card.Description {
		t.Errorf("expected Description %q, got %q", card.Description, receivedCard.Description)
	}
	if receivedCard.Requester != card.Requester {
		t.Errorf("expected Requester %q, got %q", card.Requester, receivedCard.Requester)
	}
}

func TestSendApprovalCard_EmptyAndInvalidURL(t *testing.T) {
	card := ApprovalCard{
		RequestID:   "req-123",
		Description: "test",
		Requester:   "alice@example.com",
	}
	ctx := context.Background()

	// Empty and whitespace URLs fail fast
	for _, badURL := range []string{"", "   ", "\t\n"} {
		err := SendApprovalCard(ctx, badURL, card)
		if err == nil {
			t.Errorf("expected error for empty URL %q, got nil", badURL)
		}
		if !strings.Contains(err.Error(), "empty webhook URL") {
			t.Errorf("expected 'empty webhook URL' error for %q, got: %v", badURL, err)
		}
	}

	// Invalid URL scheme / protocol
	err := SendApprovalCard(ctx, "://invalid-url-format", card)
	if err == nil {
		t.Fatal("expected error for invalid URL format, got nil")
	}
}

func TestSendApprovalCard_ContextCancelled(t *testing.T) {
	card := ApprovalCard{
		RequestID:   "req-ctx",
		Description: "test cancellation",
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	err := SendApprovalCard(ctx, "http://127.0.0.1:54321/webhook", card)
	if err == nil {
		t.Fatal("expected error on cancelled context, got nil")
	}
	if !strings.Contains(err.Error(), "context canceled") {
		t.Errorf("expected context canceled error, got: %v", err)
	}
}

func TestSendApprovalCard_HTTPErrorResponses(t *testing.T) {
	tests := []struct {
		statusCode int
	}{
		{statusCode: http.StatusBadRequest},
		{statusCode: http.StatusUnauthorized},
		{statusCode: http.StatusForbidden},
		{statusCode: http.StatusNotFound},
		{statusCode: http.StatusInternalServerError},
		{statusCode: http.StatusBadGateway},
		{statusCode: http.StatusServiceUnavailable},
	}

	for _, tt := range tests {
		server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodPost {
				w.Header().Set("Allow", "POST")
				w.WriteHeader(http.StatusMethodNotAllowed)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(tt.statusCode)
			_ = json.NewEncoder(w).Encode(map[string]int{"error_code": tt.statusCode})
		})))

		card := ApprovalCard{RequestID: "err-req", Description: "error test"}
		err := SendApprovalCard(context.Background(), server.URL, card)
		server.Close()

		if err == nil {
			t.Fatalf("expected error for status %d, got nil", tt.statusCode)
		}
		expectedSubstr := strings.TrimSpace(strings.ReplaceAll(http.StatusText(tt.statusCode), " ", ""))
		_ = expectedSubstr
		if !strings.Contains(err.Error(), "webhook returned status") {
			t.Errorf("expected 'webhook returned status' in error, got: %v", err)
		}
	}
}

func TestSendApprovalCard_MethodGatesAndHEADBodySuppression(t *testing.T) {
	server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "method not allowed"})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})))
	defer server.Close()

	// 1. Disallowed HTTP methods return 405 Method Not Allowed with Allow: POST
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req, err := http.NewRequestWithContext(context.Background(), method, server.URL, nil)
		if err != nil {
			t.Fatalf("create %s request: %v", method, err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s request failed: %v", method, err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s status = %d, want 405", method, resp.StatusCode)
		}
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Errorf("%s Allow header = %q, want 'POST'", method, allow)
		}
	}

	// 2. HEAD request returns 405 Method Not Allowed with Allow: POST and 0-byte body
	headReq, err := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL, nil)
	if err != nil {
		t.Fatalf("create HEAD request: %v", err)
	}
	headResp, err := http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD request failed: %v", err)
	}
	defer headResp.Body.Close()

	if headResp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("HEAD status = %d, want 405", headResp.StatusCode)
	}
	if allow := headResp.Header.Get("Allow"); allow != "POST" {
		t.Errorf("HEAD Allow header = %q, want 'POST'", allow)
	}
	headBody, err := io.ReadAll(headResp.Body)
	if err != nil {
		t.Fatalf("read HEAD body: %v", err)
	}
	if len(headBody) != 0 {
		t.Errorf("HEAD body length = %d, want 0 (RFC 9110 Section 6.4.1 violation)", len(headBody))
	}
}

func TestSendApprovalCard_HEADBodySuppressionAcrossStatuses(t *testing.T) {
	statusCodes := []int{
		http.StatusOK,
		http.StatusCreated,
		http.StatusNoContent,
		http.StatusBadRequest,
		http.StatusUnauthorized,
		http.StatusForbidden,
		http.StatusNotFound,
		http.StatusMethodNotAllowed,
		http.StatusRequestEntityTooLarge,
		http.StatusTooManyRequests,
		http.StatusInternalServerError,
		http.StatusServiceUnavailable,
	}

	for _, status := range statusCodes {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(status)
				_ = json.NewEncoder(w).Encode(map[string]any{"status": status, "message": "sample body"})
			})))
			defer server.Close()

			req, err := http.NewRequestWithContext(context.Background(), http.MethodHead, server.URL, nil)
			if err != nil {
				t.Fatalf("create HEAD request: %v", err)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("HEAD request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != status {
				t.Errorf("status = %d, want %d", resp.StatusCode, status)
			}
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatalf("read body: %v", err)
			}
			if len(body) != 0 {
				t.Errorf("status %d HEAD body length = %d, want 0", status, len(body))
			}
		})
	}
}
