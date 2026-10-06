// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type keyHarness struct {
	k      *keySource
	env    map[string]string
	files  map[string][]byte
	sleeps []time.Duration
	clock  time.Time
	log    *bytes.Buffer
}

func newKeyHarness(t *testing.T) *keyHarness {
	t.Helper()
	h := &keyHarness{env: map[string]string{}, files: map[string][]byte{}, clock: time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC), log: &bytes.Buffer{}}
	h.k = newKeySource("fleet_caller_key", "FLEET_MANAGER_STUN_KEY", "FLEET_MANAGER_STUN_KEY_FILE")
	h.k.getenv = func(n string) string { return h.env[n] }
	h.k.readFile = func(p string) ([]byte, error) {
		if b, ok := h.files[p]; ok {
			return b, nil
		}
		return nil, os.ErrNotExist
	}
	h.k.sleep = func(_ context.Context, d time.Duration) bool {
		h.sleeps = append(h.sleeps, d)
		h.clock = h.clock.Add(d)
		return true
	}
	h.k.now = func() time.Time { return h.clock }
	SetAuditOutput(h.log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })
	return h
}

func TestKeyFromTheEnvironmentIsReadyAtOnce(t *testing.T) {
	h := newKeyHarness(t)
	h.env["FLEET_MANAGER_STUN_KEY"] = " " + testStunKey + "\n"
	if !h.k.await(context.Background()) || h.k.get() != testStunKey || len(h.sleeps) != 0 {
		t.Fatalf("ready=%v key=%q sleeps=%v", h.k.get() == testStunKey, h.k.get(), h.sleeps)
	}
	select {
	case <-h.k.ready:
	default:
		t.Fatal("ready channel must be closed")
	}
	out := h.log.String()
	if !strings.Contains(out, `"event":"key_loaded"`) || !strings.Contains(out, `"source":"env:FLEET_MANAGER_STUN_KEY"`) {
		t.Fatalf("log:\n%s", out)
	}
	if strings.Contains(out, testStunKey) {
		t.Fatal("the key value must never be logged")
	}
}

func TestKeyFileAbsentAtStartIsWaitedForWithBackoffAndWarnedOncePerMinute(t *testing.T) {
	h := newKeyHarness(t)
	path := filepath.Join(t.TempDir(), "token")
	h.env["FLEET_MANAGER_STUN_KEY_FILE"] = path
	// 1+2+4+8+16+30+30 = 91s before the file appears: two warnings.
	h.k.sleep = func(ctx context.Context, d time.Duration) bool {
		h.sleeps = append(h.sleeps, d)
		h.clock = h.clock.Add(d)
		if len(h.sleeps) == 7 {
			h.files[path] = []byte(testStunKey + "\n")
		}
		return true
	}
	if !h.k.await(context.Background()) || h.k.get() != testStunKey {
		t.Fatalf("key = %q", h.k.get())
	}
	want := []time.Duration{1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	if len(h.sleeps) != len(want) {
		t.Fatalf("sleeps = %v", h.sleeps)
	}
	for i := range want {
		if h.sleeps[i] != want[i] {
			t.Fatalf("sleeps = %v, want %v", h.sleeps, want)
		}
	}
	out := h.log.String()
	if n := strings.Count(out, `"event":"key_missing"`); n != 2 {
		t.Fatalf("want one WARN at start and one after a minute, got %d:\n%s", n, out)
	}
	if !strings.Contains(out, `"level":"WARN"`) || !strings.Contains(out, `"file":"`+path+`"`) {
		t.Fatalf("log:\n%s", out)
	}
	if !strings.Contains(out, `"source":"file:`+path+`"`) || strings.Contains(out, testStunKey) {
		t.Fatalf("log:\n%s", out)
	}
}

func TestKeyWaitStopsWhenTheContextEnds(t *testing.T) {
	h := newKeyHarness(t)
	h.k.sleep = func(context.Context, time.Duration) bool { return false }
	if h.k.await(context.Background()) || h.k.get() != "" {
		t.Fatal("a cancelled wait is not ready")
	}
	if !strings.Contains(h.log.String(), `"event":"key_missing"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
}

func TestKeyFileReadErrorOtherThanAbsenceIsReported(t *testing.T) {
	h := newKeyHarness(t)
	h.env["FLEET_MANAGER_STUN_KEY_FILE"] = "/etc/key"
	h.k.readFile = func(string) ([]byte, error) { return nil, errors.New("permission denied") }
	h.k.sleep = func(context.Context, time.Duration) bool { return false }
	h.k.await(context.Background())
	if !strings.Contains(h.log.String(), `"error":"permission denied"`) {
		t.Fatalf("log:\n%s", h.log.String())
	}
}

func TestKeyEmptyFileIsNotAKey(t *testing.T) {
	h := newKeyHarness(t)
	h.env["FLEET_MANAGER_STUN_KEY_FILE"] = "/k"
	h.files["/k"] = []byte(" \n")
	h.k.sleep = func(context.Context, time.Duration) bool { return false }
	if h.k.await(context.Background()) {
		t.Fatal("blank file must not be ready")
	}
}
