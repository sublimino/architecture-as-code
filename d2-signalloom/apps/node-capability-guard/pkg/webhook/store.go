// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package webhook

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

var (
	// ErrStoreUnavailable is returned when the contained-identity store cannot be reached,
	// is unreadable, or has corrupted data. The webhook fails closed on this error.
	ErrStoreUnavailable = errors.New("contained identity store unavailable")

	// ErrTargetNotFound is returned when an identity is queried but not present.
	ErrTargetNotFound = errors.New("contained identity not found")
)

// ContainedEntry represents a single contained agent record.
type ContainedEntry struct {
	AgentID       string            `json:"agent_id"`
	Namespace     string            `json:"namespace"`
	SPIFFEID      string            `json:"spiffe_id,omitempty"`
	ContainedAt   string            `json:"contained_at"`
	Reason        string            `json:"reason,omitempty"`
	IdempotencyKey string           `json:"idempotency_key,omitempty"`
	Metadata      map[string]string `json:"metadata,omitempty"`
}

// ContainedIdentityStore defines the contract for querying and updating contained agent identities.
type ContainedIdentityStore interface {
	// IsContained checks if any candidate identifier (agentID, agentName, SPIFFE ID, ServiceAccount) is contained.
	// Returns (isContained bool, matchedIdentity string, err error).
	// On error, the admission controller fails closed (denies admission).
	IsContained(ctx context.Context, namespace string, candidates []string) (bool, string, error)

	// AddContained adds an agent identity to the store.
	AddContained(ctx context.Context, entry ContainedEntry) error

	// RemoveContained removes an agent identity from the store.
	RemoveContained(ctx context.Context, namespace, agentID string) error

	// ListContained returns all active contained entries.
	ListContained(ctx context.Context) ([]ContainedEntry, error)

	// Health reports whether the store is operational.
	Health(ctx context.Context) error
}

// MemoryIdentityStore is a thread-safe, in-memory implementation of ContainedIdentityStore.
type MemoryIdentityStore struct {
	mu      sync.RWMutex
	entries map[string]ContainedEntry // keys: agentID, agentName, spiffeID, namespace/agentID
}

var _ ContainedIdentityStore = (*MemoryIdentityStore)(nil)

// NewMemoryIdentityStore creates a new MemoryIdentityStore.
func NewMemoryIdentityStore() *MemoryIdentityStore {
	return &MemoryIdentityStore{
		entries: make(map[string]ContainedEntry),
	}
}

func normalizeKey(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// IsContained checks if any candidate matches a contained entry.
func (s *MemoryIdentityStore) IsContained(_ context.Context, namespace string, candidates []string) (bool, string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, cand := range candidates {
		if cand == "" {
			continue
		}
		norm := normalizeKey(cand)
		if entry, ok := s.entries[norm]; ok {
			return true, entry.AgentID, nil
		}
		// Also check namespace-scoped key: namespace/candidate
		if namespace != "" {
			nsKey := normalizeKey(fmt.Sprintf("%s/%s", namespace, cand))
			if entry, ok := s.entries[nsKey]; ok {
				return true, entry.AgentID, nil
			}
		}
	}
	return false, "", nil
}

// AddContained inserts or updates a contained record.
func (s *MemoryIdentityStore) AddContained(_ context.Context, entry ContainedEntry) error {
	if entry.AgentID == "" {
		return errors.New("agent_id is required")
	}
	if entry.ContainedAt == "" {
		entry.ContainedAt = time.Now().UTC().Format(time.RFC3339)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Index by full agent ID (e.g. "agent-cardvault")
	s.entries[normalizeKey(entry.AgentID)] = entry

	// Index by stripped name (e.g. "cardvault")
	stripped := strings.TrimPrefix(entry.AgentID, "agent-")
	if stripped != entry.AgentID && stripped != "" {
		s.entries[normalizeKey(stripped)] = entry
	}

	// Index by namespace/agentID
	if entry.Namespace != "" {
		s.entries[normalizeKey(fmt.Sprintf("%s/%s", entry.Namespace, entry.AgentID))] = entry
		if stripped != entry.AgentID && stripped != "" {
			s.entries[normalizeKey(fmt.Sprintf("%s/%s", entry.Namespace, stripped))] = entry
		}
	}

	// Index by SPIFFE ID if present
	if entry.SPIFFEID != "" {
		s.entries[normalizeKey(entry.SPIFFEID)] = entry
	}

	return nil
}

// RemoveContained deletes a contained record.
func (s *MemoryIdentityStore) RemoveContained(_ context.Context, namespace, agentID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	norm := normalizeKey(agentID)
	entry, ok := s.entries[norm]
	delete(s.entries, norm)

	stripped := strings.TrimPrefix(agentID, "agent-")
	delete(s.entries, normalizeKey(stripped))

	if namespace != "" {
		delete(s.entries, normalizeKey(fmt.Sprintf("%s/%s", namespace, agentID)))
		delete(s.entries, normalizeKey(fmt.Sprintf("%s/%s", namespace, stripped)))
	}

	if ok && entry.SPIFFEID != "" {
		delete(s.entries, normalizeKey(entry.SPIFFEID))
	}

	return nil
}

// ListContained returns all unique contained records.
func (s *MemoryIdentityStore) ListContained(_ context.Context) ([]ContainedEntry, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	seen := make(map[string]bool)
	list := make([]ContainedEntry, 0, len(s.entries))
	for _, entry := range s.entries {
		key := fmt.Sprintf("%s/%s", entry.Namespace, entry.AgentID)
		if !seen[key] {
			seen[key] = true
			list = append(list, entry)
		}
	}
	return list, nil
}

// Health always returns nil for in-memory store.
func (s *MemoryIdentityStore) Health(_ context.Context) error {
	return nil
}

// FileIdentityStore loads contained agent definitions from a JSON file (e.g. mounted ConfigMap).
type FileIdentityStore struct {
	path       string
	mu         sync.RWMutex
	lastMod    time.Time
	memStore   *MemoryIdentityStore
	failClosed bool
}

var _ ContainedIdentityStore = (*FileIdentityStore)(nil)

// NewFileIdentityStore creates a FileIdentityStore watching the specified JSON file.
func NewFileIdentityStore(path string) (*FileIdentityStore, error) {
	fs := &FileIdentityStore{
		path:       path,
		memStore:   NewMemoryIdentityStore(),
		failClosed: true,
	}
	if err := fs.reload(); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("initial load of %s: %w: %w", path, ErrStoreUnavailable, err)
	}
	return fs, nil
}

func (f *FileIdentityStore) reload() error {
	info, err := os.Stat(f.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat store file %s: %w", f.path, err)
	}

	f.mu.Lock()
	defer f.mu.Unlock()

	if !info.ModTime().After(f.lastMod) {
		return nil
	}

	data, err := os.ReadFile(f.path)
	if err != nil {
		return fmt.Errorf("read store file %s: %w", f.path, err)
	}

	if len(strings.TrimSpace(string(data))) == 0 {
		f.memStore = NewMemoryIdentityStore()
		f.lastMod = info.ModTime()
		return nil
	}

	var entries []ContainedEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		// Also try parsing map format {"contained_agents": [...]}
		var envelope struct {
			ContainedAgents []ContainedEntry `json:"contained_agents"`
		}
		if errEnv := json.Unmarshal(data, &envelope); errEnv == nil && len(envelope.ContainedAgents) > 0 {
			entries = envelope.ContainedAgents
		} else {
			return fmt.Errorf("unmarshal store file %s: %w", f.path, err)
		}
	}

	newMem := NewMemoryIdentityStore()
	ctx := context.Background()
	for _, e := range entries {
		_ = newMem.AddContained(ctx, e)
	}

	f.memStore = newMem
	f.lastMod = info.ModTime()
	return nil
}

// IsContained reloads if modified and queries the memory cache.
func (f *FileIdentityStore) IsContained(ctx context.Context, namespace string, candidates []string) (bool, string, error) {
	if err := f.reload(); err != nil {
		return false, "", fmt.Errorf("store reload error: %w: %w", ErrStoreUnavailable, err)
	}

	f.mu.RLock()
	mem := f.memStore
	f.mu.RUnlock()

	return mem.IsContained(ctx, namespace, candidates)
}

// AddContained writes to memory and syncs to disk.
func (f *FileIdentityStore) AddContained(ctx context.Context, entry ContainedEntry) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	if err := f.memStore.AddContained(ctx, entry); err != nil {
		return err
	}
	return f.saveUnlocked(ctx)
}

// RemoveContained removes from memory and syncs to disk.
func (f *FileIdentityStore) RemoveContained(ctx context.Context, namespace, agentID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	if err := f.memStore.RemoveContained(ctx, namespace, agentID); err != nil {
		return err
	}
	return f.saveUnlocked(ctx)
}

func (f *FileIdentityStore) saveUnlocked(ctx context.Context) error {
	entries, err := f.memStore.ListContained(ctx)
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal store: %w", err)
	}
	if err := os.WriteFile(f.path, data, 0600); err != nil {
		return fmt.Errorf("write store %s: %w: %w", f.path, ErrStoreUnavailable, err)
	}
	if info, err := os.Stat(f.path); err == nil {
		f.lastMod = info.ModTime()
	}
	return nil
}

// ListContained returns all contained entries.
func (f *FileIdentityStore) ListContained(ctx context.Context) ([]ContainedEntry, error) {
	if err := f.reload(); err != nil {
		return nil, fmt.Errorf("store reload error: %w: %w", ErrStoreUnavailable, err)
	}
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.memStore.ListContained(ctx)
}

// Health verifies the file is accessible.
func (f *FileIdentityStore) Health(_ context.Context) error {
	if _, err := os.Stat(f.path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("health check on %s: %w: %w", f.path, ErrStoreUnavailable, err)
	}
	return nil
}

// FailingIdentityStore always returns ErrStoreUnavailable to test fail-closed behavior.
type FailingIdentityStore struct {
	Err error
}

var _ ContainedIdentityStore = (*FailingIdentityStore)(nil)

// NewFailingIdentityStore creates a store that unconditionally fails.
func NewFailingIdentityStore(err error) *FailingIdentityStore {
	if err == nil {
		err = ErrStoreUnavailable
	}
	return &FailingIdentityStore{Err: err}
}

func (f *FailingIdentityStore) IsContained(_ context.Context, _ string, _ []string) (bool, string, error) {
	return false, "", f.Err
}

func (f *FailingIdentityStore) AddContained(_ context.Context, _ ContainedEntry) error {
	return f.Err
}

func (f *FailingIdentityStore) RemoveContained(_ context.Context, _, _ string) error {
	return f.Err
}

func (f *FailingIdentityStore) ListContained(_ context.Context) ([]ContainedEntry, error) {
	return nil, f.Err
}

func (f *FailingIdentityStore) Health(_ context.Context) error {
	return f.Err
}
