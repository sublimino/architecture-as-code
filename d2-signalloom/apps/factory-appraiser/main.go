package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/factory-appraiser/appraiser"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/factory-appraiser/validator"
)

// defaultStaleTTL is the appraisal TTL applied when the caller does not pin one.
const defaultStaleTTL = 30 * time.Minute

// appraiseRequest is the appraisal data plane. This service holds no candidate
// store, so — exactly as POST /api/v1/factory/validate-promotion does — the
// caller supplies the facts being appraised. A verdict is only ever a function
// of this body plus the clock.
type appraiseRequest struct {
	Candidates      []validator.Candidate       `json:"candidates"`
	Intents         map[string]validator.Intent `json:"intents"`
	StaleTTLMinutes *int                        `json:"stale_ttl_minutes"`
}

// appraiseHandler serves POST /api/v1/factory/appraise.
//
// It refuses rather than answering with no inputs: an appraisal of zero
// candidates would report status "healthy" with escalation null, which is
// indistinguishable from a real all-clear. `escalation` is consumed by oncall
// paging, so a permanent null is a silent suppression, not a cosmetic default.
func appraiseHandler(clock func() time.Time) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		r.Body = http.MaxBytesReader(w, r.Body, 4<<20)

		var req appraiseRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error":  "malformed_request",
				"reason": err.Error(),
			})
			return
		}

		if len(req.Candidates) == 0 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnprocessableEntity)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error": "insufficient_input",
				"reason": "no candidates supplied: this service holds no candidate store, " +
					"so an appraisal cannot be derived. No candidates is not an all-clear.",
			})
			return
		}

		staleTTL := defaultStaleTTL
		if req.StaleTTLMinutes != nil {
			if *req.StaleTTLMinutes <= 0 {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				if r.Method == http.MethodHead {
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]string{
					"error":  "malformed_request",
					"reason": "stale_ttl_minutes must be a positive number of minutes",
				})
				return
			}
			staleTTL = time.Duration(*req.StaleTTLMinutes) * time.Minute
		}

		res, esc := appraiser.Appraise(req.Candidates, req.Intents, clock(), staleTTL)
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"appraisal":        res,
			"escalation":       esc,
			"stale_ttl":        staleTTL.String(),
			"candidates_input": len(req.Candidates),
		})
	}
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

func newMux(clock func() time.Time) http.Handler {
	mux := http.NewServeMux()
	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	}
	mux.HandleFunc("GET /healthz", healthHandler)
	mux.HandleFunc("HEAD /healthz", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	mux.HandleFunc("HEAD /readyz", healthHandler)
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("HEAD /health", healthHandler)
	mux.HandleFunc("POST /api/v1/factory/appraise", appraiseHandler(clock))
	mux.HandleFunc("POST /api/v1/factory/validate-promotion", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
		var req struct {
			Candidate validator.Candidate  `json:"candidate"`
			Evidence  validator.QAEvidence `json:"evidence"`
			Promotion validator.Promotion  `json:"promotion"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		if err := validator.ValidateSeparationOfDuties(req.Candidate, req.Evidence); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		if err := validator.ValidatePromotionContract(req.Promotion, req.Evidence); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			if r.Method == http.MethodHead {
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "approved", "message": "Promotion contract satisfied"})
	})
	return headBodySuppressingMiddleware(mux)
}

func main() {
	port := flag.Int("port", 8094, "HTTP port for factory appraiser")
	flag.Parse()

	mux := newMux(func() time.Time { return time.Now().UTC() })

	slog.Info("factory-appraiser listening", "port", *port)
	srv := &http.Server{
		Addr:              fmt.Sprintf(":%d", *port),
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	_ = srv.ListenAndServe()
}
