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
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
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
	trimmed := strings.TrimSpace(webhookURL)
	if trimmed == "" {
		return fmt.Errorf("empty webhook URL")
	}

	parsed, err := url.Parse(trimmed)
	if err != nil {
		return fmt.Errorf("invalid webhook URL: %w", err)
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("invalid webhook URL scheme: %s (must be http or https)", parsed.Scheme)
	}
	if parsed.Host == "" {
		return fmt.Errorf("webhook URL missing host")
	}

	body, err := json.Marshal(card)
	if err != nil {
		return fmt.Errorf("marshal approval card: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, trimmed, bytes.NewReader(body))
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
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
	}

	slog.Info("approval card sent", "request_id", card.RequestID, "webhook", trimmed)
	return nil
}

