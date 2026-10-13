package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type trackingBody struct {
	io.Reader
	readBytes int
	closed    bool
}

func (b *trackingBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	b.readBytes += n
	return n, err
}

func (b *trackingBody) Close() error {
	b.closed = true
	return nil
}

func TestHTTPUtilReadMethodGate(t *testing.T) {
	handler := headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer drainAndCloseBody(r)
		if !requireReadMethod(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}))

	t.Run("OPTIONS returns 204 with Allow including OPTIONS and drains body", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodOptions, "/test", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Fatalf("Allow = %q, want GET, HEAD, OPTIONS", allow)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("body len = %d, want 0", rec.Body.Len())
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("body closed=%v readBytes=%d, want true/7", tb.closed, tb.readBytes)
		}
	})

	t.Run("405 on disallowed method includes OPTIONS in Allow and drains body", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodPost, "/test", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
			t.Fatalf("Allow = %q, want GET, HEAD, OPTIONS", allow)
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("body closed=%v readBytes=%d, want true/7", tb.closed, tb.readBytes)
		}
	})

	t.Run("HEAD returns 200 with 0 body bytes", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodHead, "/test", nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200", rec.Code)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("HEAD body len = %d, want 0", rec.Body.Len())
		}
	})
}

func TestHTTPUtilPostMethodGate(t *testing.T) {
	handler := headBodySuppressingMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer drainAndCloseBody(r)
		if !requirePostMethod(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}))

	t.Run("OPTIONS returns 204 with Allow POST, OPTIONS and drains body", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodOptions, "/mutate", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204", rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Fatalf("Allow = %q, want POST, OPTIONS", allow)
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("body closed=%v readBytes=%d, want true/7", tb.closed, tb.readBytes)
		}
	})

	t.Run("HEAD on POST endpoint returns 405 with 0 body bytes and Allow POST, OPTIONS", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodHead, "/mutate", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", rec.Code)
		}
		if allow := rec.Header().Get("Allow"); allow != "POST, OPTIONS" {
			t.Fatalf("Allow = %q, want POST, OPTIONS", allow)
		}
		if rec.Body.Len() != 0 {
			t.Fatalf("HEAD 405 body len = %d, want 0", rec.Body.Len())
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("body closed=%v readBytes=%d, want true/7", tb.closed, tb.readBytes)
		}
	})
}
