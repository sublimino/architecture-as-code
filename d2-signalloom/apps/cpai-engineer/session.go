package main

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// SessionStore persists task history in SQLite with WAL journaling.
//
// The database lives on the PVC at /workspace/.cpai/sessions.db so task
// history survives pod restarts. WAL mode avoids writer-blocks-reader
// contention when the executor writes results while the HTTP server reads
// task status.
type SessionStore struct {
	db *sql.DB
}

// NewSessionStore opens (or creates) the SQLite database at path and applies
// the schema.
func NewSessionStore(path string) (*SessionStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}

	// WAL mode for concurrent reads during writes.
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, err
	}

	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS tasks (
			task_id     TEXT PRIMARY KEY,
			repo        TEXT NOT NULL,
			branch      TEXT NOT NULL DEFAULT '',
			instruction TEXT NOT NULL,
			status      TEXT NOT NULL DEFAULT 'pending',
			commits     TEXT NOT NULL DEFAULT '[]',
			tokens_used INTEGER NOT NULL DEFAULT 0,
			error_msg   TEXT NOT NULL DEFAULT '',
			created_at  TEXT NOT NULL,
			updated_at  TEXT NOT NULL
		)
	`); err != nil {
		db.Close()
		return nil, err
	}

	return &SessionStore{db: db}, nil
}

// Close closes the database connection.
func (s *SessionStore) Close() error {
	return s.db.Close()
}

// Insert stores a new task record.
func (s *SessionStore) Insert(task *TaskResponse, repo, branch, instruction string) error {
	commits, _ := json.Marshal(task.Commits)
	_, err := s.db.Exec(`
		INSERT INTO tasks (task_id, repo, branch, instruction, status, commits, tokens_used, error_msg, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, task.TaskID, repo, branch, instruction, task.Status,
		string(commits), task.TokensUsed, task.Error, task.CreatedAt, task.UpdatedAt)
	return err
}

// Update persists the final status of a completed or failed task.
func (s *SessionStore) Update(task *TaskResponse) error {
	commits, _ := json.Marshal(task.Commits)
	_, err := s.db.Exec(`
		UPDATE tasks SET status = ?, commits = ?, tokens_used = ?, error_msg = ?, updated_at = ?
		WHERE task_id = ?
	`, task.Status, string(commits), task.TokensUsed, task.Error, task.UpdatedAt, task.TaskID)
	return err
}

// Get retrieves a task by ID.
func (s *SessionStore) Get(id string) (*TaskResponse, error) {
	var t TaskResponse
	var commitsJSON string
	err := s.db.QueryRow(`
		SELECT task_id, status, commits, tokens_used, error_msg, created_at, updated_at
		FROM tasks WHERE task_id = ?
	`, id).Scan(&t.TaskID, &t.Status, &commitsJSON, &t.TokensUsed, &t.Error, &t.CreatedAt, &t.UpdatedAt)
	if err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(commitsJSON), &t.Commits)
	if t.Commits == nil {
		t.Commits = []string{}
	}
	return &t, nil
}

// List returns the most recent n tasks ordered by creation time descending.
func (s *SessionStore) List(n int) ([]*TaskResponse, error) {
	rows, err := s.db.Query(`
		SELECT task_id, status, commits, tokens_used, error_msg, created_at, updated_at
		FROM tasks ORDER BY created_at DESC LIMIT ?
	`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []*TaskResponse
	for rows.Next() {
		var t TaskResponse
		var commitsJSON string
		if err := rows.Scan(&t.TaskID, &t.Status, &commitsJSON, &t.TokensUsed, &t.Error, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(commitsJSON), &t.Commits)
		if t.Commits == nil {
			t.Commits = []string{}
		}
		tasks = append(tasks, &t)
	}
	if tasks == nil {
		tasks = []*TaskResponse{}
	}
	return tasks, nil
}

func nowISO() string {
	return time.Now().UTC().Format(time.RFC3339)
}
