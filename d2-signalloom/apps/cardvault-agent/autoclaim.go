package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// claimRequest is the payload POSTed to Signal Loom's claim API.
type claimRequest struct {
	SpiffeID  string `json:"spiffe_id"`
	AgentType string `json:"agent_type"`
	BaoToken  string `json:"bao_token"`
	ClaimedAt string `json:"claimed_at"`
}

// autoClaim registers this agent with Signal Loom's claim API after successful
// OpenBao authentication. It sends the SPIFFE ID, agent type, and the OpenBao
// token as proof of identity.
func (a *agent) autoClaim(spiffeID, baoToken string) error {
	payload, err := json.Marshal(claimRequest{
		SpiffeID:  spiffeID,
		AgentType: "cardvault",
		BaoToken:  baoToken,
		ClaimedAt: time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("encode claim request: %w", err)
	}

	url := strings.TrimRight(a.claimURL, "/") + "/api/v1/agents/claim"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create claim request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return fmt.Errorf("claim API request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("read claim response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("claim API returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	return nil
}
