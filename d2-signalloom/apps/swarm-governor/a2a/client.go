// Package a2a provides a JSON-RPC 2.0 client for the A2A protocol.
//
// Discovers agent capabilities via their agent cards at /.well-known/agent-card.json
// and dispatches tasks via the tasks/send method.
package a2a

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client communicates with A2A agents.
type Client struct {
	httpClient *http.Client
}

// NewClient creates an A2A client with sensible defaults.
func NewClient() *Client {
	return &Client{
		httpClient: &http.Client{Timeout: 30 * time.Second},
	}
}

// DiscoverCard fetches an agent's card from its well-known endpoint.
func (c *Client) DiscoverCard(ctx context.Context, baseURL string) (*AgentCard, error) {
	cardURL := baseURL + "/.well-known/agent-card.json"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, cardURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create card request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch agent card from %s: %w", cardURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("agent card at %s returned status %d", cardURL, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read agent card body: %w", err)
	}

	var card AgentCard
	if err := json.Unmarshal(body, &card); err != nil {
		return nil, fmt.Errorf("decode agent card: %w", err)
	}

	if card.URL == "" {
		card.URL = baseURL
	}

	return &card, nil
}

// SendTask dispatches a task to an agent via JSON-RPC 2.0 tasks/send.
func (c *Client) SendTask(ctx context.Context, agentURL string, task Task) (*TaskResult, error) {
	rpcReq := JSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "tasks/send",
		ID:      task.ID,
		Params:  task,
	}

	body, err := json.Marshal(rpcReq)
	if err != nil {
		return nil, fmt.Errorf("marshal task request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, agentURL, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create task request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("send task to %s: %w", agentURL, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read task response: %w", err)
	}

	var rpcResp JSONRPCResponse
	if err := json.Unmarshal(respBody, &rpcResp); err != nil {
		return nil, fmt.Errorf("decode task response: %w", err)
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("agent error (code %d): %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	// Re-marshal the result into TaskResult.
	resultBytes, err := json.Marshal(rpcResp.Result)
	if err != nil {
		return nil, fmt.Errorf("re-marshal task result: %w", err)
	}

	var result TaskResult
	if err := json.Unmarshal(resultBytes, &result); err != nil {
		return nil, fmt.Errorf("decode task result: %w", err)
	}

	return &result, nil
}

// GetTask queries the status of a task via JSON-RPC 2.0 tasks/get.
func (c *Client) GetTask(ctx context.Context, agentURL string, taskID string) (*TaskResult, error) {
	rpcReq := JSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "tasks/get",
		ID:      taskID,
		Params:  map[string]string{"task_id": taskID},
	}

	body, err := json.Marshal(rpcReq)
	if err != nil {
		return nil, fmt.Errorf("marshal get request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, agentURL, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create get request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("get task from %s: %w", agentURL, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read get response: %w", err)
	}

	var rpcResp JSONRPCResponse
	if err := json.Unmarshal(respBody, &rpcResp); err != nil {
		return nil, fmt.Errorf("decode get response: %w", err)
	}

	if rpcResp.Error != nil {
		return nil, fmt.Errorf("agent error (code %d): %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}

	resultBytes, err := json.Marshal(rpcResp.Result)
	if err != nil {
		return nil, fmt.Errorf("re-marshal get result: %w", err)
	}

	var result TaskResult
	if err := json.Unmarshal(resultBytes, &result); err != nil {
		return nil, fmt.Errorf("decode get result: %w", err)
	}

	return &result, nil
}
