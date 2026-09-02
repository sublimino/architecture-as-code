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

func main() {
	port := flag.Int("port", 8094, "HTTP port for factory appraiser")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /api/v1/factory/appraise", func(w http.ResponseWriter, _ *http.Request) {
		now := time.Now().UTC()
		res, esc := appraiser.Appraise(nil, nil, now, 30*time.Minute)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"appraisal":  res,
			"escalation": esc,
		})
	})
	mux.HandleFunc("POST /api/v1/factory/validate-promotion", func(w http.ResponseWriter, r *http.Request) {
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
