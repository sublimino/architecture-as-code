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

func TestHTTPUtilGates(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		defer drainAndCloseBody(r)
		if !requireReadMethod(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("/poll", func(w http.ResponseWriter, r *http.Request) {
		defer drainAndCloseBody(r)
		if !requirePostMethod(w, r) {
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	handler := headBodySuppressingMiddleware(mux)

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

	t.Run("HEAD /poll returns 405 with 0 body bytes and Allow POST, OPTIONS", func(t *testing.T) {
		tb := &trackingBody{Reader: strings.NewReader("payload")}
		req := httptest.NewRequest(http.MethodHead, "/poll", tb)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusMethodNotAllowed || rec.Header().Get("Allow") != "POST, OPTIONS" || rec.Body.Len() != 0 {
			t.Fatalf("code=%d Allow=%q len=%d", rec.Code, rec.Header().Get("Allow"), rec.Body.Len())
		}
		if !tb.closed || tb.readBytes != len("payload") {
			t.Fatalf("closed=%v readBytes=%d", tb.closed, tb.readBytes)
		}
	})
}
