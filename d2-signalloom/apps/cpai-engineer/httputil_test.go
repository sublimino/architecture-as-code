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

func TestHTTPUtilRoutes(t *testing.T) {
	mux := http.NewServeMux()
	registerReadRoute(mux, "/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy"}`))
	})
	handler := headBodySuppressingMiddleware(bodyDrainingMiddleware(mux))

	t.Run("OPTIONS /healthz returns 204 and drains body", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodOptions, "/healthz", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusNoContent || rec.Header().Get("Allow") != "GET, HEAD, OPTIONS" {
			t.Fatalf("code=%d Allow=%q", rec.Code, rec.Header().Get("Allow"))
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("closed=%v readBytes=%d", tb.closed, tb.readBytes)
		}
	})

	t.Run("POST /healthz returns 405 and drains body", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodPost, "/healthz", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusMethodNotAllowed || !strings.Contains(rec.Header().Get("Allow"), "OPTIONS") {
			t.Fatalf("code=%d Allow=%q", rec.Code, rec.Header().Get("Allow"))
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("closed=%v readBytes=%d", tb.closed, tb.readBytes)
		}
	})
}
