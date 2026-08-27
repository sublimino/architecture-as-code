// prod-deploy-gate: approval card dispatch to webhook URL.
//
// Sends a structured approval request card to Slack/Zulip via webhook.
// The card contains the request details, an approve URL, and a reject URL.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// ApprovalCard is the payload sent to the webhook endpoint.
type ApprovalCard struct {
	RequestID   string `json:"request_id"`
	Description string `json:"description"`
	Requester   string `json:"requester"`
	ApproveURL  string `json:"approve_url"`
	Token       string `json:"token"`
	ExpiresAt   string `json:"expires_at"`
}

// SendApprovalCard dispatches an approval card to the configured webhook URL.
func SendApprovalCard(ctx context.Context, webhookURL string, card ApprovalCard) error {
	body, err := json.Marshal(card)
	if err != nil {
		return fmt.Errorf("marshal approval card: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhookURL, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create webhook request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("send webhook: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
	}

	slog.Info("approval card sent", "request_id", card.RequestID, "webhook", webhookURL)
	return nil
}
