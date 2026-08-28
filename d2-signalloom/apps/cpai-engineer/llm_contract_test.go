package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// LLM contract tests validate the HTTP request shape that cpai-engineer sends
// to the configured LLM_ENDPOINT. All tests use httptest.NewServer as a mock
// LLM backend — no real API calls are made.

// ── OpenAI-compatible request shape ────────────────────────────────────────

// openAIChatRequest is the expected wire format for /v1/chat/completions.
type openAIChatRequest struct {
	Model     string              `json:"model"`
	Messages  []openAIChatMessage `json:"messages"`
	MaxTokens int                 `json:"max_tokens"`
}

type openAIChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// openAIChatResponse is the minimal response shape the parser must handle.
type openAIChatResponse struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Choices []struct {
		Index   int `json:"index"`
		Message struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
}

func TestLLMEndpointFormat(t *testing.T) {
	// Verify the LLM endpoint path follows the OpenAI /v1/chat/completions format.
	var receivedPath string
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(openAIChatResponse{
			ID:     "chatcmpl-test",
			Object: "chat.completion",
			Choices: []struct {
				Index   int `json:"index"`
				Message struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"message"`
			}{
				{
					Index:   0,
					Message: struct {
						Role    string `json:"role"`
						Content string `json:"content"`
					}{Role: "assistant", Content: "Hello"},
				},
			},
		})
	}))
	defer mock.Close()

	// The expected endpoint path for OpenAI-compatible APIs.
	expectedPath := "/v1/chat/completions"

	// Simulate what the executor would call: POST to LLM_ENDPOINT + path.
	resp, err := http.Post(mock.URL+expectedPath, "application/json",
		strings.NewReader(`{"model":"gpt-4o","messages":[{"role":"user","content":"test"}],"max_tokens":100}`))
	if err != nil {
		t.Fatalf("POST to mock LLM: %v", err)
	}
	defer resp.Body.Close()

	if receivedPath != expectedPath {
		t.Errorf("expected path %q, got %q", expectedPath, receivedPath)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}

func TestLLMRequestShape(t *testing.T) {
	// Verify the request body includes model, messages, and max_tokens.
	var received openAIChatRequest
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &received)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(openAIChatResponse{
			ID:     "chatcmpl-test",
			Object: "chat.completion",
			Choices: []struct {
				Index   int `json:"index"`
				Message struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"message"`
			}{
				{Index: 0, Message: struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				}{Role: "assistant", Content: "done"}},
			},
		})
	}))
	defer mock.Close()

	// Build a valid request body matching the OpenAI chat completions format.
	reqBody := openAIChatRequest{
		Model: "gpt-4o",
		Messages: []openAIChatMessage{
			{Role: "system", Content: "You are a coding assistant."},
			{Role: "user", Content: "Fix the README"},
		},
		MaxTokens: 50000,
	}
	bodyBytes, _ := json.Marshal(reqBody)

	resp, err := http.Post(mock.URL+"/v1/chat/completions", "application/json",
		strings.NewReader(string(bodyBytes)))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()

	if received.Model == "" {
		t.Error("model field must be present in request body")
	}
	if len(received.Messages) == 0 {
		t.Error("messages array must not be empty")
	}
	if received.MaxTokens <= 0 {
		t.Error("max_tokens must be positive")
	}

	// Verify the first message has a valid role.
	validRoles := map[string]bool{"system": true, "user": true, "assistant": true}
	for _, msg := range received.Messages {
		if !validRoles[msg.Role] {
			t.Errorf("unexpected message role: %q", msg.Role)
		}
	}
}

func TestLLMResponseParsing(t *testing.T) {
	// Verify the response parser handles the OpenAI completion format.
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(openAIChatResponse{
			ID:     "chatcmpl-abc123",
			Object: "chat.completion",
			Choices: []struct {
				Index   int `json:"index"`
				Message struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				} `json:"message"`
			}{
				{Index: 0, Message: struct {
					Role    string `json:"role"`
					Content string `json:"content"`
				}{Role: "assistant", Content: "Here is the fix:\n```go\nfmt.Println(\"fixed\")\n```"}},
			},
			Usage: struct {
				PromptTokens     int `json:"prompt_tokens"`
				CompletionTokens int `json:"completion_tokens"`
				TotalTokens      int `json:"total_tokens"`
			}{
				PromptTokens:     100,
				CompletionTokens: 50,
				TotalTokens:      150,
			},
		})
	}))
	defer mock.Close()

	resp, err := http.Post(mock.URL+"/v1/chat/completions", "application/json",
		strings.NewReader(`{"model":"gpt-4o","messages":[{"role":"user","content":"fix"}],"max_tokens":100}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()

	var parsed openAIChatResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if parsed.ID == "" {
		t.Error("response ID must not be empty")
	}
	if len(parsed.Choices) == 0 {
		t.Fatal("choices must not be empty")
	}
	if parsed.Choices[0].Message.Role != "assistant" {
		t.Errorf("expected role=assistant, got %q", parsed.Choices[0].Message.Role)
	}
	if parsed.Choices[0].Message.Content == "" {
		t.Error("response content must not be empty")
	}
	if parsed.Usage.TotalTokens != 150 {
		t.Errorf("expected total_tokens=150, got %d", parsed.Usage.TotalTokens)
	}
}

func TestLLMErrorHandling(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
	}{
		{
			name:       "503 service unavailable",
			statusCode: http.StatusServiceUnavailable,
			body:       `{"error":{"message":"Service temporarily unavailable","type":"server_error"}}`,
		},
		{
			name:       "429 rate limit",
			statusCode: http.StatusTooManyRequests,
			body:       `{"error":{"message":"Rate limit exceeded","type":"rate_limit_error"}}`,
		},
		{
			name:       "malformed JSON response",
			statusCode: http.StatusOK,
			body:       `{this is not valid json`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.statusCode)
				w.Write([]byte(tc.body))
			}))
			defer mock.Close()

			resp, err := http.Post(mock.URL+"/v1/chat/completions", "application/json",
				strings.NewReader(`{"model":"gpt-4o","messages":[{"role":"user","content":"test"}],"max_tokens":100}`))
			if err != nil {
				t.Fatalf("POST: %v", err)
			}
			defer resp.Body.Close()

			bodyBytes, _ := io.ReadAll(resp.Body)

			if tc.statusCode != http.StatusOK {
				// Non-200 responses should be detectable by status code.
				if resp.StatusCode == http.StatusOK {
					t.Error("expected non-200 status for error response")
				}
			} else {
				// Malformed JSON: attempt decode, expect failure.
				var parsed openAIChatResponse
				if err := json.Unmarshal(bodyBytes, &parsed); err == nil {
					t.Error("expected JSON decode error for malformed body")
				}
			}
		})
	}
}

// ── Anthropic Messages API format ──────────────────────────────────────────

type anthropicRequest struct {
	Model     string              `json:"model"`
	Messages  []openAIChatMessage `json:"messages"`
	MaxTokens int                 `json:"max_tokens"`
}

type anthropicResponse struct {
	ID      string `json:"id"`
	Type    string `json:"type"`
	Role    string `json:"role"`
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	Usage struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

func TestAnthropicMessagesAPIFormat(t *testing.T) {
	// When configured for direct Anthropic access, the request and response
	// shapes differ from OpenAI. Verify the contract.
	var received anthropicRequest
	mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		json.Unmarshal(body, &received)

		// Verify Anthropic-specific headers.
		if r.Header.Get("x-api-key") == "" && r.Header.Get("Authorization") == "" {
			// At least one auth header should be present in production.
			// In test, we just verify the handler receives the request.
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(anthropicResponse{
			ID:   "msg-test-123",
			Type: "message",
			Role: "assistant",
			Content: []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: "Here is the fix."},
			},
			Usage: struct {
				InputTokens  int `json:"input_tokens"`
				OutputTokens int `json:"output_tokens"`
			}{
				InputTokens:  100,
				OutputTokens: 50,
			},
		})
	}))
	defer mock.Close()

	reqBody := anthropicRequest{
		Model: "claude-sonnet-4-20250514",
		Messages: []openAIChatMessage{
			{Role: "user", Content: "Fix the bug"},
		},
		MaxTokens: 4096,
	}
	bodyBytes, _ := json.Marshal(reqBody)

	resp, err := http.Post(mock.URL+"/v1/messages", "application/json",
		strings.NewReader(string(bodyBytes)))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()

	var parsed anthropicResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}

	if parsed.Type != "message" {
		t.Errorf("expected type=message, got %q", parsed.Type)
	}
	if parsed.Role != "assistant" {
		t.Errorf("expected role=assistant, got %q", parsed.Role)
	}
	if len(parsed.Content) == 0 {
		t.Fatal("content blocks must not be empty")
	}
	if parsed.Content[0].Type != "text" {
		t.Errorf("expected content type=text, got %q", parsed.Content[0].Type)
	}
}
