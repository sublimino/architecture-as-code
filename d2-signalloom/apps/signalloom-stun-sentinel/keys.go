// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Hub keys. The warden needs two: the signal-ingest bearer and the
// fleet-manager caller key. Each comes from an environment variable (the
// Secret projected by the DaemonSet) or, failing that, a file named by a
// second variable (a Secret mounted as a volume, so a key created after the
// pod started still arrives without a restart):
//
//	SIGNAL_INGEST_TOKEN      / SIGNAL_INGEST_TOKEN_FILE
//	FLEET_MANAGER_STUN_KEY   / FLEET_MANAGER_STUN_KEY_FILE
//
// A key absent at start used to mean running keyless: every observation
// logged and dropped, every stun unrecorded, silently, until someone
// restarted the pod (secondary-cluster.md's WARNING). Now the warden waits:
// a keySource polls with backoff, logs key_missing once per minute, and
// becomes ready when the key appears. Enforcement never waits on it. While
// the ingest key is missing, observations spool (correlator
// WithBearerTokenSource); while the fleet key is missing, a stun delivery
// retries and the report and poll do not start. The key value is never
// placed in an event.

import (
	"context"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	keyWaitMinBackoff = time.Second
	keyWaitMaxBackoff = 30 * time.Second
	keyWarnEvery      = time.Minute
)

type keySource struct {
	name    string // the event's key name, e.g. "signal_ingest_token"
	envVar  string
	fileVar string

	getenv   func(string) string
	readFile func(string) ([]byte, error)
	sleep    func(context.Context, time.Duration) bool // false: ctx ended
	now      func() time.Time

	mu    sync.Mutex
	value string
	ready chan struct{}
	once  sync.Once
}

func newKeySource(name, envVar, fileVar string) *keySource {
	return &keySource{
		name:     name,
		envVar:   envVar,
		fileVar:  fileVar,
		getenv:   os.Getenv,
		readFile: os.ReadFile,
		sleep: func(ctx context.Context, d time.Duration) bool {
			select {
			case <-ctx.Done():
				return false
			case <-time.After(d):
				return true
			}
		},
		now:   time.Now,
		ready: make(chan struct{}),
	}
}

// get returns the key, or "" until it has been found.
func (k *keySource) get() string {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.value
}

// load reads the key once: the variable first, then the file. source names
// where it came from, for the event; a missing file is simply "not yet".
func (k *keySource) load() (value, source string, err error) {
	if v := strings.TrimSpace(k.getenv(k.envVar)); v != "" {
		return v, "env:" + k.envVar, nil
	}
	path := strings.TrimSpace(k.getenv(k.fileVar))
	if path == "" {
		return "", "", nil
	}
	body, err := k.readFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", "", nil
		}
		return "", "", err
	}
	return strings.TrimSpace(string(body)), "file:" + path, nil
}

func (k *keySource) set(value, source string) {
	k.mu.Lock()
	k.value = value
	k.mu.Unlock()
	k.once.Do(func() { close(k.ready) })
	logEvent(stunEvent{Timestamp: now(), Event: "key_loaded", Decision: "ready",
		Details: map[string]interface{}{"key": k.name, "source": source}})
}

// await blocks until the key is found or ctx ends, reporting which. The
// first miss and every minute after is logged at WARN; polls back off from
// one second to thirty.
func (k *keySource) await(ctx context.Context) bool {
	backoff := keyWaitMinBackoff
	var lastWarn time.Time
	attempts := 0
	for {
		value, source, err := k.load()
		if value != "" {
			k.set(value, source)
			return true
		}
		attempts++
		if t := k.now(); lastWarn.IsZero() || t.Sub(lastWarn) >= keyWarnEvery {
			lastWarn = t
			ev := stunEvent{Timestamp: now(), Event: "key_missing", Decision: "waiting",
				Details: map[string]interface{}{"key": k.name, "env": k.envVar, "file_env": k.fileVar, "attempts": attempts, "level": "WARN"}}
			if path := strings.TrimSpace(k.getenv(k.fileVar)); path != "" {
				ev.Details["file"] = path
			}
			if err != nil {
				ev.Error = err.Error()
			}
			logEvent(ev)
		}
		if !k.sleep(ctx, backoff) {
			return false
		}
		if backoff *= 2; backoff > keyWaitMaxBackoff {
			backoff = keyWaitMaxBackoff
		}
	}
}
