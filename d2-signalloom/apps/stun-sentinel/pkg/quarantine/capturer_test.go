// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

var (
	globalHeldLockFile *os.File
	globalListener     net.Listener
	globalMemoryBuffer []byte
)

// Helper to spawn a helper process that holds open files, locks, sockets, and memory
func startHelperProcess(t *testing.T, holdLockPath string, listenPort int, memAllocBytes int, canary string) *exec.Cmd {
	t.Helper()

	args := []string{"-test.run=TestHelperProcess", "--", holdLockPath, strconv.Itoa(listenPort), strconv.Itoa(memAllocBytes), canary}
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}

	if err := cmd.Start(); err != nil {
		t.Fatalf("start helper: %v", err)
	}

	// Wait for helper to print "READY\n"
	buf := make([]byte, 128)
	n, err := stdout.Read(buf)
	t.Logf("HELPER OUTPUT: %s (err: %v)", string(buf[:n]), err)
	if err != nil || !strings.Contains(string(buf[:n]), "READY") {
		_ = cmd.Process.Kill()
		t.Fatalf("helper failed to become ready: %s (%v)", string(buf[:n]), err)
	}

	return cmd
}

// TestHelperProcess is the helper sub-process target
func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}

	// Allow parent test process to inspect memory via process_vm_readv / /proc/pid/mem
	_ = unix.Prctl(unix.PR_SET_PTRACER, uintptr(os.Getppid()), 0, 0, 0)
	_ = unix.Prctl(unix.PR_SET_PTRACER, ^uintptr(0), 0, 0, 0)

	var lockFile string
	var listenPort int = -1
	var memBytes int
	var canary string

	args := os.Args
	for i, arg := range args {
		if arg == "--" {
			if i+1 < len(args) {
				lockFile = args[i+1]
			}
			if i+2 < len(args) {
				listenPort, _ = strconv.Atoi(args[i+2])
			}
			if i+3 < len(args) {
				memBytes, _ = strconv.Atoi(args[i+3])
			}
			if i+4 < len(args) {
				canary = args[i+4]
			}
			break
		}
	}

	var lockErrStr string
	if lockFile != "" {
		fd, err := unix.Open(lockFile, unix.O_CREAT|unix.O_RDWR, 0666)
		if err != nil {
			lockErrStr = "open_err: " + err.Error()
		} else {
			_, _ = unix.Write(fd, []byte("lock test data\n"))
			if fErr := unix.Flock(fd, unix.LOCK_EX); fErr != nil {
				lockErrStr = "flock_err: " + fErr.Error()
			}
		}
	}

	if listenPort >= 0 {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", listenPort))
		if err == nil {
			globalListener = ln
		}
	}

	if memBytes > 0 {
		globalMemoryBuffer = make([]byte, memBytes)
		for j := range globalMemoryBuffer {
			globalMemoryBuffer[j] = byte(j % 256)
		}
		if canary != "" {
			copy(globalMemoryBuffer[100:], []byte(canary))
		}
	}

	// Signal parent process we are ready with any lock error
	if lockErrStr != "" {
		fmt.Printf("READY ERR: %s\n", lockErrStr)
	} else {
		fmt.Println("READY OK")
	}
	_ = os.Stdout.Sync()

	// Keep alive until killed (do not use select{} which triggers Go runtime deadlock detector)
	for {
		time.Sleep(1 * time.Second)
	}
}

func TestCaptureLiveProcessWithHeldFileLock(t *testing.T) {
	lockFile := filepath.Join(t.TempDir(), "locked_agent_resource.db")
	cmd := startHelperProcess(t, lockFile, 0, 1024, "TEST_CANARY")
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 10 * 1024 * 1024,
		MaxTimeBudget:      2 * time.Second,
		DumpAnonymousOnly:  true,
	})

	target := TargetInfo{
		PodUID:     "test-pod-uid-42",
		PodName:    "agent-executor",
		Namespace:  "fe-signalloom-agents",
		CgroupPath: "/sys/fs/cgroup/test",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	if len(manifest.Processes) != 1 {
		t.Fatalf("expected 1 process captured, got %d", len(manifest.Processes))
	}

	proc := manifest.Processes[0]
	if proc.PID != cmd.Process.Pid {
		t.Errorf("PID mismatch: got %d, want %d", proc.PID, cmd.Process.Pid)
	}

	// Verify the open file descriptor is present
	var foundFD bool
	for _, fd := range proc.FileDescriptors {
		if strings.Contains(fd.Target, "locked_agent_resource.db") {
			foundFD = true
			break
		}
	}
	if !foundFD {
		t.Errorf("open file descriptor for %s not found in capture: %+v", lockFile, proc.FileDescriptors)
	}

	// Verify file lock is recorded in the forensic snapshot
	if len(proc.HeldLocks) == 0 {
		t.Errorf("expected held locks to be detected for locked file")
	} else {
		lock := proc.HeldLocks[0]
		if lock.LockType != "FLOCK" && lock.LockType != "POSIX" {
			t.Errorf("expected FLOCK or POSIX lock type, got %s", lock.LockType)
		}
		if lock.LockMode != "WRITE" {
			t.Errorf("expected WRITE lock mode, got %s", lock.LockMode)
		}
	}
}

func TestCaptureLiveProcessWithOpenSockets(t *testing.T) {
	cmd := startHelperProcess(t, "", 0, 1024, "SOCKET_TEST")
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 10 * 1024 * 1024,
		MaxTimeBudget:      2 * time.Second,
	})

	target := TargetInfo{
		PodUID: "test-pod-uid-socket",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	if len(manifest.Processes) == 0 {
		t.Fatalf("no processes captured")
	}

	proc := manifest.Processes[0]
	if len(proc.Sockets) == 0 {
		t.Errorf("expected open sockets to be captured in forensic snapshot")
	}

	var foundListen bool
	for _, sock := range proc.Sockets {
		if sock.State == "LISTEN" {
			foundListen = true
			break
		}
	}
	if !foundListen {
		t.Errorf("expected at least one LISTEN socket in capture: %+v", proc.Sockets)
	}
}

func TestCaptureMemoryDumpContent(t *testing.T) {
	canary := "SIGNAL_LOOM_FORENSIC_CANARY_STRING_987654321"
	cmd := startHelperProcess(t, "", -1, 512*1024, canary)
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 128 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})

	target := TargetInfo{
		PodUID: "test-pod-canary",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	if manifest.Summary.MemoryBytesDumped == 0 {
		t.Fatalf("expected memory bytes to be dumped, got 0")
	}

	// Verify canary string exists in one of the dumped memory files
	var foundCanary bool
	for _, hash := range manifest.Summary.ArtifactHashes {
		_ = hash
	}

	entries, err := os.ReadDir(manifest.StoragePath)
	if err != nil {
		t.Fatalf("read snapshot dir failed: %v", err)
	}

	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "mem_") && strings.HasSuffix(entry.Name(), ".bin") {
			content, err := os.ReadFile(filepath.Join(manifest.StoragePath, entry.Name()))
			if err == nil && bytes.Contains(content, []byte(canary)) {
				foundCanary = true
				break
			}
		}
	}

	if !foundCanary {
		t.Errorf("canary string %q was not found in dumped process memory files", canary)
	}
}

func TestSnapshotSurvivesPodDeletion(t *testing.T) {
	canary := "POD_DELETION_SURVIVAL_CANARY"
	cmd := startHelperProcess(t, "", -1, 256*1024, canary)
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 128 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})

	target := TargetInfo{
		PodUID:    "ephemeral-agent-pod-999",
		PodName:   "worker-agent",
		Namespace: "agents-sandbox",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	snapDir := manifest.StoragePath

	// Simulate pod deletion by terminating process
	_ = cmd.Process.Kill()
	_ = cmd.Wait()

	// Verify forensic snapshot directory still exists and is fully readable
	if _, err := os.Stat(snapDir); err != nil {
		t.Fatalf("snapshot directory was destroyed or missing after pod exit: %v", err)
	}

	manifestFile := filepath.Join(snapDir, "manifest.json")
	if _, err := os.Stat(manifestFile); err != nil {
		t.Fatalf("manifest.json missing after pod exit: %v", err)
	}

	// Verify we can load the manifest back from disk
	loadedManifest, err := capturer.GetSnapshot(manifest.CaptureID)
	if err != nil {
		t.Fatalf("failed to reload manifest: %v", err)
	}

	if loadedManifest.Target.PodUID != target.PodUID {
		t.Errorf("loaded manifest UID mismatch: got %s, want %s", loadedManifest.Target.PodUID, target.PodUID)
	}
}

func TestCaptureTimeBudgetExceededAbortsCleanly(t *testing.T) {
	cmd := startHelperProcess(t, "", -1, 50*1024*1024, "TIME_BUDGET_TEST")
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	// Extremely tight time budget (1 nanosecond) ensures deadline fires immediately
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 100 * 1024 * 1024,
		MaxTimeBudget:      1 * time.Nanosecond,
		DumpAnonymousOnly:  true,
	})

	target := TargetInfo{
		PodUID: "test-pod-time-budget",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	if !manifest.Partial {
		t.Errorf("expected manifest.Partial to be true when time budget exceeded")
	}
	if manifest.PartialReason != "time_budget_exceeded" {
		t.Errorf("expected PartialReason 'time_budget_exceeded', got %q", manifest.PartialReason)
	}
}

func TestCaptureMemorySizeBudgetExceededAbortsCleanly(t *testing.T) {
	cmd := startHelperProcess(t, "", -1, 10*1024*1024, "SIZE_BUDGET_TEST")
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	storageDir := t.TempDir()
	// Tight memory budget (512 bytes)
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 512,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})

	target := TargetInfo{
		PodUID: "test-pod-size-budget",
	}

	manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	if !manifest.Partial {
		t.Errorf("expected manifest.Partial to be true when memory size budget exceeded")
	}
	if manifest.PartialReason != "memory_size_budget_exceeded" {
		t.Errorf("expected PartialReason 'memory_size_budget_exceeded', got %q", manifest.PartialReason)
	}
	if manifest.Summary.MemoryBytesDumped > 512 {
		t.Errorf("dumped bytes %d exceeded limit of 512", manifest.Summary.MemoryBytesDumped)
	}
}

func TestConcurrentSnapshotCaptures(t *testing.T) {
	cmd1 := startHelperProcess(t, "", -1, 64*1024, "CONCURRENT_1")
	defer func() { _ = cmd1.Process.Kill(); _ = cmd1.Wait() }()

	cmd2 := startHelperProcess(t, "", -1, 64*1024, "CONCURRENT_2")
	defer func() { _ = cmd2.Process.Kill(); _ = cmd2.Wait() }()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 128 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	manifests := make(chan *QuarantineManifest, 2)

	captureFunc := func(podUID string, pid int) {
		defer wg.Done()
		m, err := capturer.Capture(context.Background(), TargetInfo{PodUID: podUID}, []int{pid})
		if err != nil {
			errs <- err
			return
		}
		manifests <- m
	}

	wg.Add(2)
	go captureFunc("pod-concurrent-1", cmd1.Process.Pid)
	go captureFunc("pod-concurrent-2", cmd2.Process.Pid)
	wg.Wait()
	close(errs)
	close(manifests)

	for err := range errs {
		t.Fatalf("concurrent capture failed: %v", err)
	}

	var count int
	for m := range manifests {
		count++
		if m.Partial {
			t.Errorf("concurrent capture %s marked partial: %s", m.CaptureID, m.PartialReason)
		}
		if _, err := os.Stat(filepath.Join(m.StoragePath, "manifest.json")); err != nil {
			t.Errorf("manifest missing for %s", m.CaptureID)
		}
	}
	if count != 2 {
		t.Fatalf("expected 2 manifests, got %d", count)
	}
}

func TestSnapshotPermissionsAreStrict(t *testing.T) {
	cmd := startHelperProcess(t, "", 0, 32*1024, "PERM_TEST")
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 1 * 1024 * 1024,
		MaxTimeBudget:      2 * time.Second,
		DumpAnonymousOnly:  true,
	})

	manifest, err := capturer.Capture(context.Background(), TargetInfo{PodUID: "pod-perm-test"}, []int{cmd.Process.Pid})
	if err != nil {
		t.Fatalf("Capture failed: %v", err)
	}

	dirInfo, err := os.Stat(manifest.StoragePath)
	if err != nil {
		t.Fatalf("stat dir failed: %v", err)
	}
	// Directory must be 0700 (drwx------)
	if dirInfo.Mode().Perm() != 0700 {
		t.Errorf("directory permissions not 0700: %o", dirInfo.Mode().Perm())
	}

	entries, err := os.ReadDir(manifest.StoragePath)
	if err != nil {
		t.Fatalf("read snapshot dir failed: %v", err)
	}

	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		// Files must be 0600 (-rw-------)
		if info.Mode().Perm() != 0600 {
			t.Errorf("file %s permissions not 0600: %o", entry.Name(), info.Mode().Perm())
		}
	}
}

func TestCaptureLatencyBenchmark(t *testing.T) {
	sizes := []struct {
		name       string
		allocBytes int
	}{
		{name: "1MB_RSS", allocBytes: 1 * 1024 * 1024},
		{name: "10MB_RSS", allocBytes: 10 * 1024 * 1024},
		{name: "50MB_RSS", allocBytes: 50 * 1024 * 1024},
	}

	storageDir := t.TempDir()
	capturer := New(CaptureConfig{
		StorageDir:         storageDir,
		MaxMemorySizeBytes: 100 * 1024 * 1024,
		MaxTimeBudget:      5 * time.Second,
		DumpAnonymousOnly:  true,
	})

	for _, tc := range sizes {
		cmd := startHelperProcess(t, "", 0, tc.allocBytes, "BENCHMARK_DATA")
		target := TargetInfo{PodUID: "bench-" + tc.name}

		start := time.Now()
		manifest, err := capturer.Capture(context.Background(), target, []int{cmd.Process.Pid})
		elapsed := time.Since(start)

		_ = cmd.Process.Kill()
		_ = cmd.Wait()

		if err != nil {
			t.Errorf("benchmark %s failed: %v", tc.name, err)
			continue
		}

		t.Logf("BENCHMARK [%s]: Captured %d bytes in %.2fms (manifest duration: %.2fms, partial: %v)",
			tc.name, manifest.Summary.MemoryBytesDumped, float64(elapsed.Nanoseconds())/1e6, manifest.CaptureDurationMS, manifest.Partial)
	}
}
