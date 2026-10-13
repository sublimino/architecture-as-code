package main

import (
	"fmt"
	"io"
	"net/http"
)

const maxDrainBytes = 1 << 20

// drainAndCloseBody safely drains up to maxDrainBytes and closes r.Body.
func drainAndCloseBody(r *http.Request) {
	if r == nil || r.Body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, maxDrainBytes))
	_ = r.Body.Close()
}

// methodNotAllowed sets RFC 9110 Allow headers and status 405, suppressing response bodies on HEAD requests.
func methodNotAllowed(w http.ResponseWriter, r *http.Request, allow string) {
	drainAndCloseBody(r)
	w.Header().Set("Allow", allow)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusMethodNotAllowed)
	if r == nil || r.Method != http.MethodHead {
		fmt.Fprintln(w, "method not allowed")
	}
}

// requireReadMethod enforces GET, HEAD, or OPTIONS on a read-only endpoint.
func requireReadMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodOptions {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		methodNotAllowed(w, r, "GET, HEAD, OPTIONS")
		return false
	}
	return true
}

// requirePostMethod enforces POST or OPTIONS on a mutating endpoint.
func requirePostMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodOptions {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w, r, "POST, OPTIONS")
		return false
	}
	return true
}

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
	return len(p), nil
}

// headBodySuppressingMiddleware wraps an http.Handler and suppresses the response body
// when the request method is HEAD, in compliance with RFC 9110 Section 6.4.1.
func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
