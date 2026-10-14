// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// TestLiveAgentOpenatScoping proves that:
// 1. One openat("/etc/passwd") from a target process yields exactly one captured event with cgroup_id.
// 2. The sentinel's own opens of /etc/passwd are filtered out in kernel space (sentinel_self_tgid).
// 3. Opens of non-sensitive paths are prefiltered before ring buffer reservation.
func TestLiveAgentOpenatScoping(t *testing.T) {
	requireLiveBPF(t)

	var uname unix.Utsname
	if err := unix.Uname(&uname); err == nil {
		release := string(uname.Release[:])
		if idx := len(release); idx > 0 {
			for i, b := range uname.Release {
				if b == 0 {
					release = string(uname.Release[:i])
					break
				}
			}
		}
		t.Logf("kernel release: %s", release)
	}

	l, err := NewLoader(LoaderOptions{IgnoreTGID: uint32(os.Getpid())})
	if err != nil {
		t.Fatalf("NewLoader: %v", err)
	}
	defer l.Close()

	nonce := strconv.FormatInt(time.Now().UnixNano(), 36)
	noisePath := "/tmp/sentinel-live-noise-" + nonce
	targetPath := "/etc/passwd"

	prefilteredBefore, err := l.Prefiltered()
	if err != nil {
		t.Fatalf("Prefiltered: %v", err)
	}
	dropsBefore, err := l.Drops()
	if err != nil {
		t.Fatalf("Drops: %v", err)
	}

	selfPath := "/root/.ssh/sentinel-live-self-" + nonce

	// 1. Self open of sensitive path must be dropped in kernel space (sentinel_self_tgid)
	if f, err := os.Open(selfPath); err == nil {
		f.Close()
	}
	if f, err := os.Open(targetPath); err == nil {
		f.Close()
	}

	// 2. Spawn child to open noise path and then target path
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperProcess$")
	cmd.Env = append(os.Environ(),
		"SENTINEL_PROBE_HELPER=1",
		"SENTINEL_HELPER_NOISE_PATH="+noisePath,
		"SENTINEL_HELPER_PATH="+targetPath,
	)
	if err := cmd.Run(); err != nil {
		t.Fatalf("helper run failed: %v", err)
	}

	wantComm := filepath.Base(os.Args[0])
	if len(wantComm) > commLen-1 {
		wantComm = wantComm[:commLen-1]
	}

	var capturedEvents []*SyscallEvent
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ev, err := l.ReadEvent(time.Now().Add(500 * time.Millisecond))
		if errors.Is(err, os.ErrDeadlineExceeded) {
			break
		}
		if err != nil {
			t.Fatalf("ReadEvent: %v", err)
		}

		if ev.TGID == uint32(os.Getpid()) || ev.Filename == selfPath {
			t.Fatalf("kernel self-filter leaked sentinel's own open: %+v", ev)
		}
		if ev.Filename == noisePath {
			t.Fatalf("noise path %q was not prefiltered: %+v", noisePath, ev)
		}
		if ev.Filename == targetPath && ev.Comm == wantComm {
			capturedEvents = append(capturedEvents, ev)
		}
	}

	// Must capture exactly 1 openat of targetPath from the child process (none from self)
	if len(capturedEvents) != 1 {
		t.Fatalf("captured %d openat events for %s from child, want exactly 1 (self opens must be filtered)", len(capturedEvents), targetPath)
	}

	ev := capturedEvents[0]
	if ev.Comm != wantComm {
		t.Errorf("ev.Comm = %q, want %q", ev.Comm, wantComm)
	}
	if ev.CgroupID == 0 {
		t.Errorf("ev.CgroupID is 0, want non-zero kernel cgroup v2 inode")
	}
	if ev.Type != EventOpenat && ev.Type != EventOpenat2 {
		t.Errorf("ev.Type = %v, want EventOpenat or EventOpenat2", ev.Type)
	}

	dropsAfter, _ := l.Drops()
	prefilteredAfter, _ := l.Prefiltered()

	eventJSON, _ := json.Marshal(ev)
	t.Logf("captured event JSON: %s", string(eventJSON))
	t.Logf("drops: before=%d, after=%d; prefiltered: before=%d, after=%d", dropsBefore, dropsAfter, prefilteredBefore, prefilteredAfter)
}
