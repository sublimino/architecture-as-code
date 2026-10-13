// prompt-commit-summarizer: stateless prompt function agent.
//
// Receives a Git diff via HTTP POST (CloudEvent format), invokes an LLM
// to generate a conventional commit message, and returns it. Single-turn,
// stateless, sub-second target latency.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// diffPayload is the expected CloudEvent body.
type diffPayload struct {
	Diff string `json:"diff"`
}

// summaryResponse is the JSON response.
type summaryResponse struct {
	CommitMessage string  `json:"commit_message"`
	Confidence    float64 `json:"confidence"`
}

// llmRequest is the OpenAI-compatible chat completion request.
type llmRequest struct {
	Model       string       `json:"model"`
	Messages    []llmMessage `json:"messages"`
	Temperature float64      `json:"temperature"`
	MaxTokens   int          `json:"max_tokens"`
}

type llmMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// llmResponse is the relevant subset of the chat completion response.
type llmResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

const systemPrompt = `You are a commit message generator. Given a git diff, produce a single conventional commit message following this format:
<type>(<scope>): <description>

Types: feat, fix, refactor, docs, test, chore, ci, perf, style, build
Rules:
- Use imperative mood ("add" not "added")
- Keep the first line under 72 characters
- Be specific about what changed
- Scope is optional but preferred
- Return ONLY the commit message, nothing else`

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	llmEndpoint := os.Getenv("LLM_ENDPOINT")
	if llmEndpoint == "" {
		llmEndpoint = "http://litellm.inf-bao.svc.cluster.local:4000/v1/chat/completions"
	}

	model := os.Getenv("LLM_MODEL")
	if model == "" {
		model = "gemini-2.5-flash"
	}

	mux := newRouter(llmEndpoint, model)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("prompt-commit-summarizer listening", "port", port, "llm_endpoint", llmEndpoint, "model", model)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	<-sigCh

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusMethodNotAllowed)
		if r.Method != http.MethodHead {
			fmt.Fprintln(w, "method not allowed")
		}
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		fmt.Fprintln(w, "ok")
	}
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

func newRouter(llmEndpoint, model string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", makeSummarizeHandler(llmEndpoint, model))
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", healthHandler)
	return headBodySuppressingMiddleware(mux)
}

func makeSummarizeHandler(llmEndpoint, model string) http.HandlerFunc {
	client := &http.Client{Timeout: 30 * time.Second}

	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusNotFound)
			if r.Method != http.MethodHead {
				fmt.Fprintln(w, "404 page not found")
			}
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusMethodNotAllowed)
			if r.Method != http.MethodHead {
				fmt.Fprintln(w, "method not allowed")
			}
			return
		}

		// Validate CloudEvent type header if present.
		ceType := strings.TrimSpace(r.Header.Get("Ce-Type"))
		if ceType != "" && ceType != "dev.knative.source.github.push" {
			slog.Warn("ignoring event", "ce-type", ceType)
			w.WriteHeader(http.StatusNoContent)
			return
		}

		var payload diffPayload
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil {
			slog.Error("failed to decode payload", "error", err)
			http.Error(w, "bad request: invalid JSON", http.StatusBadRequest)
			return
		}

		if strings.TrimSpace(payload.Diff) == "" {
			http.Error(w, "bad request: empty diff", http.StatusBadRequest)
			return
		}

		// Truncate very large diffs to avoid token limits.
		diff := payload.Diff
		const maxDiffLen = 8000
		if len(diff) > maxDiffLen {
			diff = diff[:maxDiffLen] + "\n... (truncated)"
		}

		commitMsg, confidence, err := callLLM(r.Context(), client, llmEndpoint, model, diff)
		if err != nil {
			slog.Error("LLM call failed", "error", err)
			http.Error(w, "LLM call failed", http.StatusBadGateway)
			return
		}

		resp := summaryResponse{
			CommitMessage: commitMsg,
			Confidence:    confidence,
		}

		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		_ = json.NewEncoder(w).Encode(resp)
	}
}


func callLLM(ctx context.Context, client *http.Client, endpoint, model, diff string) (string, float64, error) {
	reqBody := llmRequest{
		Model: model,
		Messages: []llmMessage{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: fmt.Sprintf("Generate a conventional commit message for this diff:\n\n```diff\n%s\n```", diff)},
		},
		Temperature: 0.3,
		MaxTokens:   100,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", 0, fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", 0, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	// Use API key if provided.
	if apiKey := os.Getenv("LLM_API_KEY"); apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", 0, fmt.Errorf("LLM request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", 0, fmt.Errorf("LLM returned %d: %s", resp.StatusCode, string(respBody))
	}

	var llmResp llmResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&llmResp); err != nil {
		return "", 0, fmt.Errorf("decode LLM response: %w", err)
	}

	if len(llmResp.Choices) == 0 {
		return "", 0, fmt.Errorf("LLM returned no choices")
	}

	msg := llmResp.Choices[0].Message.Content
	// Confidence heuristic: if the message follows conventional commit format, high confidence.
	confidence := 0.7
	if len(msg) > 0 && (msg[0] >= 'a' && msg[0] <= 'z') {
		confidence = 0.92
	}

	return msg, confidence, nil
}
