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
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error":  "malformed_request",
				"reason": err.Error(),
			})
			return
		}

		if len(req.Candidates) == 0 {
			w.WriteHeader(http.StatusUnprocessableEntity)
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
				w.WriteHeader(http.StatusBadRequest)
				_ = json.NewEncoder(w).Encode(map[string]string{
					"error":  "malformed_request",
					"reason": "stale_ttl_minutes must be a positive number of minutes",
				})
				return
			}
			staleTTL = time.Duration(*req.StaleTTLMinutes) * time.Minute
		}

		res, esc := appraiser.Appraise(req.Candidates, req.Intents, clock(), staleTTL)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"appraisal":        res,
			"escalation":       esc,
			"stale_ttl":        staleTTL.String(),
			"candidates_input": len(req.Candidates),
		})
	}
}

func main() {
	port := flag.Int("port", 8094, "HTTP port for factory appraiser")
	flag.Parse()

	mux := http.NewServeMux()
	healthHandler := func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	}
	mux.HandleFunc("GET /healthz", healthHandler)
	mux.HandleFunc("GET /readyz", healthHandler)
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("POST /api/v1/factory/appraise", appraiseHandler(func() time.Time { return time.Now().UTC() }))
	mux.HandleFunc("POST /api/v1/factory/validate-promotion", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 4<<20)
		var req struct {
			Candidate validator.Candidate  `json:"candidate"`
			Evidence  validator.QAEvidence `json:"evidence"`
			Promotion validator.Promotion  `json:"promotion"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		if err := validator.ValidateSeparationOfDuties(req.Candidate, req.Evidence); err != nil {
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		if err := validator.ValidatePromotionContract(req.Promotion, req.Evidence); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "approved", "message": "Promotion contract satisfied"})
	})

	slog.Info("factory-appraiser listening", "port", *port)
	_ = http.ListenAndServe(fmt.Sprintf(":%d", *port), mux)
}
