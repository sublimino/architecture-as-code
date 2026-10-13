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

// requireReadMethod enforces GET, HEAD, or OPTIONS on a read-only JSON endpoint.
func requireReadMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodOptions {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return false
	}
	return true
}

// requireReadMethodPlain enforces GET, HEAD, or OPTIONS on a read-only plain-text endpoint.
func requireReadMethodPlain(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodOptions {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r.Method != http.MethodHead {
			fmt.Fprintln(w, "method not allowed")
		}
		return false
	}
	return true
}

// requirePostMethod enforces POST or OPTIONS on a mutating JSON endpoint.
func requirePostMethod(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodOptions {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if r.Method != http.MethodPost {
		drainAndCloseBody(r)
		w.Header().Set("Allow", "POST, OPTIONS")
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return false
		}
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return false
	}
	return true
}

type headResponseWriter struct {
	http.ResponseWriter
	wroteHeader bool
}

func (w *headResponseWriter) WriteHeader(status int) {
	w.wroteHeader = true
	w.ResponseWriter.WriteHeader(status)
}

func (w *headResponseWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	// Per RFC 9110 Section 6.4.1, responses to HEAD requests MUST NOT contain
	// a message body, regardless of status code.
	return len(b), nil
}

func (w *headResponseWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func headBodySuppressingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			next.ServeHTTP(&headResponseWriter{ResponseWriter: w}, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
