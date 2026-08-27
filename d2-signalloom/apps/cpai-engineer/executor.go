package main

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Executor runs coding tasks asynchronously inside a nono sandbox.
//
// The flow is:
//  1. Clone (or fetch) the repo into the workspace
//  2. Checkout the requested branch
//  3. Run OpenCode headlessly inside nono with the instruction
//  4. Collect any commits produced
//  5. Persist results to the session store
type Executor struct {
	workspaceDir string
	nono         *NonoWrapper
	store        *SessionStore
}

// CmdRunner abstracts command execution for testability.
type CmdRunner interface {
	Run(ctx context.Context, dir, name string, args ...string) (stdout, stderr string, err error)
}

// RealCmdRunner executes commands on the host.
type RealCmdRunner struct{}

// Run executes a command and captures stdout/stderr.
func (r *RealCmdRunner) Run(ctx context.Context, dir, name string, args ...string) (string, string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	return outBuf.String(), errBuf.String(), err
}

// NewExecutor creates an Executor with the given workspace, nono wrapper, and
// session store.
func NewExecutor(workspaceDir string, nono *NonoWrapper, store *SessionStore) *Executor {
	return &Executor{
		workspaceDir: workspaceDir,
		nono:         nono,
		store:        store,
	}
}

// Submit creates a task record and starts async execution.
func (e *Executor) Submit(req TaskRequest) *TaskResponse {
	now := nowISO()
	task := &TaskResponse{
		TaskID:    uuid.New().String(),
		Status:    "pending",
		Commits:   []string{},
		CreatedAt: now,
		UpdatedAt: now,
	}

	if err := e.store.Insert(task, req.Repo, req.Branch, req.Instruction); err != nil {
		slog.Error("failed to persist task", "task_id", task.TaskID, "error", err)
	}

	go e.execute(task, req)
	return task
}

// execute runs the full clone-execute-collect pipeline.
func (e *Executor) execute(task *TaskResponse, req TaskRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	task.Status = "running"
	task.UpdatedAt = nowISO()
	e.store.Update(task)

	slog.Info("task started",
		"task_id", task.TaskID,
		"repo", req.Repo,
		"branch", req.Branch,
	)

	repoDir := filepath.Join(e.workspaceDir, "repos", sanitisePath(req.Repo))

	// Clone or fetch.
	if err := e.ensureRepo(ctx, repoDir, req.Repo, req.Branch); err != nil {
		e.fail(task, fmt.Sprintf("repo setup failed: %v", err))
		return
	}

	// Record HEAD before the run so we can diff commits afterward.
	headBefore, err := e.gitHead(ctx, repoDir)
	if err != nil {
		e.fail(task, fmt.Sprintf("failed to read HEAD: %v", err))
		return
	}

	// Run OpenCode inside nono sandbox.
	if err := e.runOpenCode(ctx, repoDir, req.Instruction, req.TokenBudget); err != nil {
		e.fail(task, fmt.Sprintf("opencode execution failed: %v", err))
		return
	}

	// Collect commits produced by the agent.
	commits, err := e.collectCommits(ctx, repoDir, headBefore)
	if err != nil {
		slog.Warn("failed to collect commits", "task_id", task.TaskID, "error", err)
	}

	task.Status = "completed"
	task.Commits = commits
	task.TokensUsed = req.TokenBudget // Approximation; real usage from OpenCode metrics.
	task.UpdatedAt = nowISO()
	e.store.Update(task)

	slog.Info("task completed",
		"task_id", task.TaskID,
		"commits", len(commits),
	)
}

// ensureRepo clones the repo if absent, otherwise fetches and checks out the
// branch.
func (e *Executor) ensureRepo(ctx context.Context, dir, repo, branch string) error {
	if _, err := os.Stat(filepath.Join(dir, ".git")); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
			return fmt.Errorf("mkdir: %w", err)
		}
		cmd := exec.CommandContext(ctx, "git", "clone", "--depth=1", repo, dir)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("git clone: %w", err)
		}
	} else {
		cmd := exec.CommandContext(ctx, "git", "-C", dir, "fetch", "--all", "--prune")
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("git fetch: %w", err)
		}
	}

	if branch != "" {
		cmd := exec.CommandContext(ctx, "git", "-C", dir, "checkout", branch)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("git checkout %s: %w", branch, err)
		}
	}

	return nil
}

// runOpenCode executes OpenCode headlessly inside the nono sandbox.
func (e *Executor) runOpenCode(ctx context.Context, dir, instruction string, tokenBudget int) error {
	// OpenCode's headless mode: opencode -y --message "instruction"
	cmd := e.nono.WrapWithDir(dir, "opencode", "-y",
		"--message", instruction,
	)
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("OPENCODE_TOKEN_BUDGET=%d", tokenBudget),
	)

	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	slog.Info("running opencode in sandbox",
		"dir", dir,
		"command", e.nono.CommandString("opencode", "-y", "--message", instruction),
	)

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("opencode: %w\nstderr: %s", err, errBuf.String())
	}

	return nil
}

// gitHead returns the current HEAD commit hash.
func (e *Executor) gitHead(ctx context.Context, dir string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// collectCommits returns the list of commit hashes between oldHead and HEAD.
func (e *Executor) collectCommits(ctx context.Context, dir, oldHead string) ([]string, error) {
	cmd := exec.CommandContext(ctx, "git", "-C", dir, "log",
		"--format=%H", fmt.Sprintf("%s..HEAD", oldHead))
	out, err := cmd.Output()
	if err != nil {
		return []string{}, err
	}

	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return []string{}, nil
	}
	return strings.Split(raw, "\n"), nil
}

// fail marks a task as failed and persists it.
func (e *Executor) fail(task *TaskResponse, errMsg string) {
	task.Status = "failed"
	task.Error = errMsg
	task.UpdatedAt = nowISO()
	e.store.Update(task)
	slog.Error("task failed", "task_id", task.TaskID, "error", errMsg)
}

// sanitisePath converts a repo URL to a safe directory name.
func sanitisePath(repo string) string {
	// Strip protocol prefix and .git suffix.
	name := repo
	for _, prefix := range []string{"https://", "http://", "git@", "ssh://"} {
		name = strings.TrimPrefix(name, prefix)
	}
	name = strings.TrimSuffix(name, ".git")
	// Replace path separators and colons.
	name = strings.ReplaceAll(name, "/", "_")
	name = strings.ReplaceAll(name, ":", "_")
	return name
}
