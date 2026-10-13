// triage-ci-worker: deterministic CI failure triage agent.
//
// Receives CloudEvents for failed CI check runs, parses build logs via
// regex, deduplicates known flaky tests, and posts triage labels + a
// summary comment back to the originating PR/issue via the GitHub CLI.
//
// No LLM — purely deterministic structured analysis.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var validRepoRegex = regexp.MustCompile(`^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`)
var validLabelRegex = regexp.MustCompile(`^[a-zA-Z0-9_][a-zA-Z0-9_.: -]*$`)

func isValidRepo(repo string) bool {
	if strings.HasPrefix(repo, "-") {
		return false
	}
	parts := strings.Split(repo, "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	if strings.HasPrefix(parts[0], "-") || strings.HasPrefix(parts[1], "-") {
		return false
	}
	return validRepoRegex.MatchString(repo)
}

func sanitizeLabels(labels []string) []string {
	var clean []string
	for _, l := range labels {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "-") {
			continue
		}
		if validLabelRegex.MatchString(l) {
			clean = append(clean, l)
		}
	}
	return clean
}

// checkRunPayload is the relevant subset of a GitHub check_run event.
type checkRunPayload struct {
	Action   string `json:"action"`
	CheckRun struct {
		Name       string `json:"name"`
		Status     string `json:"status"`
		Conclusion string `json:"conclusion"`
		Output     struct {
			Title   string `json:"title"`
			Summary string `json:"summary"`
			Text    string `json:"text"`
		} `json:"output"`
		PullRequests []struct {
			Number int `json:"number"`
		} `json:"pull_requests"`
	} `json:"check_run"`
}

// triageResponse is the JSON response returned to the caller.
type triageResponse struct {
	RealFailures  int      `json:"real_failures"`
	FlakyFailures int      `json:"flaky_failures"`
	Labels        []string `json:"labels"`
	CommentPosted bool     `json:"comment_posted"`
}

// knownFlakyTests is a static list; in production this would come from a
// ConfigMap or database.
var knownFlakyTests = []string{
	"TestFlaky",
	"TestIntermittent",
	"TestRaceCondition",
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := newMux()

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("triage-ci-worker listening", "port", port)
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

// methodNotAllowed sets RFC 9110 Allow headers and status 405, suppressing response bodies on HEAD requests.
func methodNotAllowed(w http.ResponseWriter, r *http.Request, allow string) {
	w.Header().Set("Allow", allow)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusMethodNotAllowed)
	if r == nil || r.Method != http.MethodHead {
		fmt.Fprintln(w, "method not allowed")
	}
}

func newMux() http.Handler {
	mux := http.NewServeMux()
	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.Header().Set("Allow", "GET, HEAD, OPTIONS")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			methodNotAllowed(w, r, "GET, HEAD")
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			fmt.Fprintln(w, "ok")
		}
	}
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/healthz", healthHandler)
	mux.HandleFunc("/readyz", healthHandler)
	mux.HandleFunc("/", handleCheckRun)
	return headBodySuppressingMiddleware(mux)
}

func handleCheckRun(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method == http.MethodOptions {
		w.Header().Set("Allow", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		methodNotAllowed(w, r, "POST")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)

	// Validate CloudEvent headers.
	ceType := r.Header.Get("Ce-Type")
	if ceType != "" && ceType != "dev.knative.source.github.check_run" {
		slog.Warn("ignoring event", "ce-type", ceType)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	var payload checkRunPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		slog.Error("failed to decode payload", "error", err)
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// Only triage completed, failed check runs.
	if payload.CheckRun.Conclusion != "failure" {
		slog.Info("skipping non-failure", "conclusion", payload.CheckRun.Conclusion)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	logText := payload.CheckRun.Output.Text
	if logText == "" {
		logText = payload.CheckRun.Output.Summary
	}

	failures := ParseFailures(logText)
	real, flaky := DeduplicateFlaky(failures, knownFlakyTests)
	labels := SuggestLabels(real, flaky)
	comment := FormatTriageComment(real, flaky)

	slog.Info("triage complete",
		"total_failures", len(failures),
		"real", len(real),
		"flaky", len(flaky),
		"labels", labels,
	)

	// Post to GitHub if we have a PR and a token.
	commentPosted := false
	if len(payload.CheckRun.PullRequests) > 0 {
		prNum := payload.CheckRun.PullRequests[0].Number
		repo := os.Getenv("GITHUB_REPO")
		if repo != "" && comment != "" && prNum > 0 {
			commentPosted = postGitHubComment(repo, prNum, comment, labels)
		}
	}

	resp := triageResponse{
		RealFailures:  len(real),
		FlakyFailures: len(flaky),
		Labels:        labels,
		CommentPosted: commentPosted,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func postGitHubComment(repo string, prNum int, comment string, labels []string) bool {
	if prNum <= 0 {
		slog.Error("invalid pr number for github comment", "prNum", prNum)
		return false
	}
	if !isValidRepo(repo) {
		slog.Error("invalid repo for github comment", "repo", repo)
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Post comment via stdin to eliminate Linux MAX_ARG_STRLEN (128 KiB) exec failures.
	cmd := exec.CommandContext(ctx, "gh", "pr", "comment", fmt.Sprintf("%d", prNum),
		"--repo", repo,
		"--body-file", "-",
	)
	cmd.Stdin = strings.NewReader(comment)
	cmd.Env = os.Environ()
	if out, err := cmd.CombinedOutput(); err != nil {
		slog.Error("gh pr comment failed", "error", err, "output", string(out))
		return false
	}

	// Add labels.
	cleanLabels := sanitizeLabels(labels)
	if len(cleanLabels) > 0 {
		args := []string{"pr", "edit", fmt.Sprintf("%d", prNum), "--repo", repo}
		args = append(args, "--add-label", strings.Join(cleanLabels, ","))
		cmd = exec.CommandContext(ctx, "gh", args...)
		cmd.Env = os.Environ()
		if out, err := cmd.CombinedOutput(); err != nil {
			slog.Error("gh pr edit failed", "error", err, "output", string(out))
		}
	}

	return true
}
