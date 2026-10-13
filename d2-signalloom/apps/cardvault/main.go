package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type Card struct {
	ID         string `json:"id"`
	Cardholder string `json:"cardholder"`
	PANMasked  string `json:"pan_masked"`
	Expiry     string `json:"expiry"`
	Issuer     string `json:"issuer"`
	Type       string `json:"type"`
}

var cards = []Card{
	{
		ID:         "card-001",
		Cardholder: "Alice Nakamoto",
		PANMasked:  "****-****-****-4532",
		Expiry:     "12/27",
		Issuer:     "Chase",
		Type:       "visa",
	},
	{
		ID:         "card-002",
		Cardholder: "Bob Finney",
		PANMasked:  "****-****-****-8819",
		Expiry:     "03/28",
		Issuer:     "Barclays",
		Type:       "mastercard",
	},
	{
		ID:         "card-003",
		Cardholder: "Carol Diffie",
		PANMasked:  "****-****-****-1057",
		Expiry:     "09/26",
		Issuer:     "Amex",
		Type:       "amex",
	},
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if r != nil && r.Method == http.MethodHead {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}

type loggingResponseWriter struct {
	http.ResponseWriter
	status int
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	lrw.status = code
	lrw.ResponseWriter.WriteHeader(code)
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lrw := &loggingResponseWriter{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(lrw, r)
		log.Printf("method=%s path=%s status=%d duration=%s",
			r.Method, r.URL.Path, lrw.status, time.Since(start))
	})
}

func requireAuth(username, password string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			next(w, r)
			return
		}
		if username == "" || password == "" {
			writeJSON(w, r, http.StatusInternalServerError, map[string]string{"error": "authentication credentials unconfigured"})
			return
		}
		u, p, ok := r.BasicAuth()
		uMatch := subtle.ConstantTimeCompare([]byte(u), []byte(username))
		pMatch := subtle.ConstantTimeCompare([]byte(p), []byte(password))
		if !ok || (uMatch&pMatch) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="cardvault"`)
			writeJSON(w, r, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]string{"status": "ready"})
}

func handleListCards(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, r, http.StatusOK, cards)
}

func handleGetCard(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD, OPTIONS")
		writeJSON(w, r, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/cards/")
	if id == "" {
		handleListCards(w, r)
		return
	}
	if strings.Contains(id, "/") || strings.Contains(id, "..") {
		writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "card not found"})
		return
	}
	for _, c := range cards {
		if c.ID == id {
			writeJSON(w, r, http.StatusOK, c)
			return
		}
	}
	writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "card not found"})
}


// headResponseWriter suppresses response bodies for HTTP HEAD requests (RFC 9110 Section 6.4.1).
type headResponseWriter struct {
	http.ResponseWriter
}

func (w *headResponseWriter) Write(p []byte) (int, error) {
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

// pathTraversalGuardMiddleware rejects path traversal attempts with 404 Not Found.
func pathTraversalGuardMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.RequestURI, "..") || strings.Contains(r.URL.Path, "..") {
			writeJSON(w, r, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func newMux(username, password string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealthz)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/v1/cards", requireAuth(username, password, handleListCards))
	mux.HandleFunc("/api/v1/cards/", requireAuth(username, password, handleGetCard))
	return pathTraversalGuardMiddleware(headBodySuppressingMiddleware(mux))
}


// resolveCredentials retrieves the cardvault username and password from
// environment variables or fallback credential files.
func resolveCredentials(uEnv, pEnv, uFile, pFile string) (string, string) {
	username := strings.TrimSpace(uEnv)
	if username == "" && uFile != "" {
		if data, err := os.ReadFile(uFile); err == nil {
			username = strings.TrimSpace(string(data))
		}
	}
	password := strings.TrimSpace(pEnv)
	if password == "" && pFile != "" {
		if data, err := os.ReadFile(pFile); err == nil {
			password = strings.TrimSpace(string(data))
		}
	}
	return username, password
}

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	username, password := resolveCredentials(
		os.Getenv("CARDVAULT_USERNAME"),
		os.Getenv("CARDVAULT_PASSWORD"),
		os.Getenv("CARDVAULT_USERNAME_FILE"),
		os.Getenv("CARDVAULT_PASSWORD_FILE"),
	)
	if username == "" || password == "" {
		log.Fatal("CARDVAULT_USERNAME and CARDVAULT_PASSWORD must be set (or via CARDVAULT_USERNAME_FILE / CARDVAULT_PASSWORD_FILE)")
	}

	mux := newMux(username, password)
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go func() {
		log.Printf("cardvault listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("shutdown: %v", err)
	}
	log.Println("stopped")
}
