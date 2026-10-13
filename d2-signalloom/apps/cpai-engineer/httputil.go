package main

import (
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

func bodyDrainingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer drainAndCloseBody(r)
		next.ServeHTTP(w, r)
	})
}

func optionsHandler(allow string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		drainAndCloseBody(r)
		w.Header().Set("Allow", allow)
		w.WriteHeader(http.StatusNoContent)
	}
}

func registerReadRoute(mux *http.ServeMux, path string, handler http.HandlerFunc) {
	mux.HandleFunc("OPTIONS "+path, optionsHandler("GET, HEAD, OPTIONS"))
	mux.HandleFunc("GET "+path, handler)
	mux.HandleFunc("HEAD "+path, handler)
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
