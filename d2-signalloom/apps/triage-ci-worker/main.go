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
	"strings"
	"syscall"
	"time"
)

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

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
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
	return mux
}

func handleCheckRun(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
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
		if repo != "" && comment != "" {
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
	if len(labels) > 0 {
		args := []string{"pr", "edit", fmt.Sprintf("%d", prNum), "--repo", repo}
		args = append(args, "--add-label", strings.Join(labels, ","))
		cmd = exec.CommandContext(ctx, "gh", args...)
		cmd.Env = os.Environ()
		if out, err := cmd.CombinedOutput(); err != nil {
			slog.Error("gh pr edit failed", "error", err, "output", string(out))
		}
	}

	return true
}
