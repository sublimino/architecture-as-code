package main

import (
	"context"
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
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
		u, p, ok := r.BasicAuth()
		if !ok || u != username || p != password {
			w.Header().Set("WWW-Authenticate", `Basic realm="cardvault"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		next(w, r)
	}
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleReadyz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func handleListCards(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, cards)
}

func handleGetCard(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/cards/")
	if id == "" {
		handleListCards(w, r)
		return
	}
	for _, c := range cards {
		if c.ID == id {
			writeJSON(w, http.StatusOK, c)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "card not found"})
}

func newMux(username, password string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/readyz", handleReadyz)
	mux.HandleFunc("/api/v1/cards", requireAuth(username, password, handleListCards))
	mux.HandleFunc("/api/v1/cards/", requireAuth(username, password, handleGetCard))
	return mux
}

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	username := os.Getenv("CARDVAULT_USERNAME")
	password := os.Getenv("CARDVAULT_PASSWORD")
	if username == "" || password == "" {
		log.Fatal("CARDVAULT_USERNAME and CARDVAULT_PASSWORD must be set")
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
