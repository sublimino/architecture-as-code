// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Persisted remote holds. A local correlator hold dies with the process
// because the stun record (labels, owner annotation) outlives it and the
// reconciler re-freezes from that. On a remote cluster fleet-manager writes
// no Kubernetes object, so the only record of an authorised remote stun on
// the node is the warden's own: one JSON file per pod UID under
// SPOOL_DIR/remote-stuns/, written when the hold is taken and removed when it
// is released. At start every file is restored before the controller runs,
// so the first resync finds a hold and not drift.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const remoteStunSubdir = "remote-stuns"

type remoteStunRecord struct {
	ID        string `json:"id"`
	UID       string `json:"uid"`
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Reason    string `json:"reason"`
	At        string `json:"at"`
}

type remoteStunStore struct{ dir string }

func newRemoteStunStore(spoolDir string) *remoteStunStore {
	return &remoteStunStore{dir: filepath.Join(spoolDir, remoteStunSubdir)}
}

func (s *remoteStunStore) path(uid string) string {
	return filepath.Join(s.dir, strings.ReplaceAll(uid, string(os.PathSeparator), "_")+".json")
}

// save writes the record atomically (temp file, rename).
func (s *remoteStunStore) save(rec remoteStunRecord) error {
	if rec.UID == "" {
		return errors.New("remote stun record without a pod uid")
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return err
	}
	body, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.dir, ".stun-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), s.path(rec.UID))
}

func (s *remoteStunStore) delete(uid string) error {
	err := os.Remove(s.path(uid))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// load returns every persisted record. A file that does not parse is
// reported and skipped, never allowed to block the rest.
func (s *remoteStunStore) load() ([]remoteStunRecord, error) {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var recs []remoteStunRecord
	var errs []error
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			errs = append(errs, err)
			continue
		}
		var rec remoteStunRecord
		if err := json.Unmarshal(body, &rec); err != nil || rec.UID == "" || rec.ID == "" {
			errs = append(errs, fmt.Errorf("%s: %v", e.Name(), err))
			continue
		}
		recs = append(recs, rec)
	}
	return recs, errors.Join(errs...)
}
