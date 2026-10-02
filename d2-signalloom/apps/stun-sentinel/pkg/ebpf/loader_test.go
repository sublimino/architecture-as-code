// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"

	"github.com/cilium/ebpf/link"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/btf"
	"github.com/cilium/ebpf/ringbuf"
)

// Two tiers live in this file.
//
// Tier 1 (always runs, no privileges): the committed ELF, its BTF, the wire
// layout and the decoder. These catch C/Go drift and decoder bugs anywhere.
//
// Tier 2 (live kernel): load through the real verifier, attach, generate real
// syscalls, read them back. Needs root (CAP_BPF + CAP_PERFMON + tracefs).
// Without it these SKIP with a stated reason -- unless
// SENTINEL_REQUIRE_LIVE_BPF=1, which turns the skip into a failure so a
// privileged CI lane cannot go green by silently skipping.
// Run them with: bpf/build.sh test

func requireLiveBPF(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		return
	}
	reason := "live BPF test needs root (CAP_BPF+CAP_PERFMON+tracefs); run bpf/build.sh test"
	if os.Getenv("SENTINEL_REQUIRE_LIVE_BPF") == "1" {
		t.Fatal("SENTINEL_REQUIRE_LIVE_BPF=1 but " + reason)
	}
	t.Skip(reason)
}

// --- tier 1: artifact and layout ------------------------------------------

func TestCollectionSpecTracepointSections(t *testing.T) {
	spec, err := loadProbe()
	if err != nil {
		t.Fatalf("loadProbe: %v", err)
	}
	want := map[string]string{
		"trace_enter_openat":  "tracepoint/syscalls/sys_enter_openat",
		"trace_enter_openat2": "tracepoint/syscalls/sys_enter_openat2",
		"trace_enter_execve":  "tracepoint/syscalls/sys_enter_execve",
		"trace_enter_connect": "tracepoint/syscalls/sys_enter_connect",
	}
	for name, section := range want {
		p, ok := spec.Programs[name]
		if !ok {
			t.Errorf("missing program %q", name)
			continue
		}
		if p.SectionName != section {
			t.Errorf("%s: section %q, want %q", name, p.SectionName, section)
		}
		if p.Type != ebpf.TracePoint {
			t.Errorf("%s: type %v, want TracePoint", name, p.Type)
		}
		if p.License != "Dual BSD/GPL" {
			t.Errorf("%s: license %q, want %q", name, p.License, "Dual BSD/GPL")
		}
	}
	if len(tracepoints) != len(want) {
		t.Errorf("attach table has %d entries, spec has %d programs", len(tracepoints), len(want))
	}
}

func TestSyscallEventLayoutMatchesBTF(t *testing.T) {
	// Three statements of the layout exist: the C struct (as the compiler
	// laid it out, recorded in BTF), bpf2go's Go mirror, and the offset
	// constants the decoder uses. All three must agree.
	spec, err := loadProbe()
	if err != nil {
		t.Fatalf("loadProbe: %v", err)
	}
	var st *btf.Struct
	if err := spec.Types.TypeByName("syscall_event_t", &st); err != nil {
		t.Fatalf("syscall_event_t not in BTF: %v", err)
	}
	if st.Size != SyscallEventSize {
		t.Fatalf("BTF size %d, decoder assumes %d", st.Size, SyscallEventSize)
	}
	if got := unsafe.Sizeof(probeSyscallEventT{}); got != SyscallEventSize {
		t.Fatalf("Go mirror size %d, want %d (implicit padding crept in)", got, SyscallEventSize)
	}
	if got := binary.Size(probeSyscallEventT{}); got != SyscallEventSize {
		t.Fatalf("binary.Size %d, want %d", got, SyscallEventSize)
	}
	want := map[string]uint32{
		"ts_ns": offTsNs, "cgroup_id": offCgroupID, "pid": offPid, "tgid": offTgid,
		"uid": offUID, "type": offType, "family": offFamily, "dport": offDport,
		"daddr": offDaddr, "comm": offComm, "filename": offFilename,
	}
	seen := 0
	for _, m := range st.Members {
		off, ok := want[m.Name]
		if !ok {
			continue
		}
		seen++
		if got := uint32(m.Offset.Bytes()); got != off {
			t.Errorf("field %s: BTF offset %d, decoder uses %d", m.Name, got, off)
		}
	}
	if seen != len(want) {
		t.Errorf("found %d of %d expected fields in BTF", seen, len(want))
	}
	var sum uint32
	for _, m := range st.Members {
		sz, err := btf.Sizeof(m.Type)
		if err != nil {
			t.Fatalf("sizeof %s: %v", m.Name, err)
		}
		sum += uint32(sz)
	}
	if sum != SyscallEventSize {
		t.Errorf("members sum to %d bytes but struct is %d: compiler inserted implicit padding", sum, SyscallEventSize)
	}
}

func TestRingBufMapProperties(t *testing.T) {
	spec, err := loadProbe()
	if err != nil {
		t.Fatalf("loadProbe: %v", err)
	}
	ms, ok := spec.Maps["events"]
	if !ok {
		t.Fatal("no map named events")
	}
	if ms.Type != ebpf.RingBuf {
		t.Fatalf("events spec type %v, want RingBuf", ms.Type)
	}
	if ms.MaxEntries != 16777216 || RingBufferSize != 16777216 {
		t.Fatalf("events spec max_entries %d (const %d), want 16777216", ms.MaxEntries, RingBufferSize)
	}

	requireLiveBPF(t)
	l, err := NewLoader(LoaderOptions{})
	if err != nil {
		t.Fatalf("NewLoader: %v", err)
	}
	defer l.Close()
	info, err := l.EventsMap().Info()
	if err != nil {
		t.Fatalf("events map info: %v", err)
	}
	if info.Type != ebpf.RingBuf || info.MaxEntries != 16777216 {
		t.Fatalf("kernel reports events map type=%v max_entries=%d, want RingBuf/16777216", info.Type, info.MaxEntries)
	}
	t.Logf("kernel map: name=%s type=%v max_entries=%d", info.Name, info.Type, info.MaxEntries)
}

// --- tier 1: decoder ------------------------------------------------------

// encode serialises through bpf2go's generated mirror, so the fixture bytes
// come from the compiler's layout rather than from the decoder's own offsets.
func encode(t *testing.T, ev probeSyscallEventT) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.NativeEndian, ev); err != nil {
		t.Fatalf("encode: %v", err)
	}
	return buf.Bytes()
}

func cBytes[T int8 | uint8](dst []T, s string) {
	for i := 0; i < len(s) && i < len(dst); i++ {
		dst[i] = T(s[i])
	}
}

func TestDecodeSyscallEventOpenat(t *testing.T) {
	var raw probeSyscallEventT
	raw.TsNs, raw.CgroupId, raw.Pid, raw.Tgid, raw.Uid = 123456789, 4242, 7001, 7000, 1000
	raw.Type = uint8(EventOpenat)
	cBytes(raw.Comm[:], "cat")
	// Stale bytes after the NUL: ring memory is not zeroed.
	cBytes(raw.Filename[:], "/etc/passwd\x00STALE-PREVIOUS-RECORD")

	ev, err := DecodeSyscallEvent(encode(t, raw))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if ev.TimestampNs != 123456789 || ev.CgroupID != 4242 || ev.PID != 7001 || ev.TGID != 7000 || ev.UID != 1000 {
		t.Fatalf("header mis-decoded: %+v", ev)
	}
	if ev.Type != EventOpenat || ev.Type.String() != "openat" {
		t.Fatalf("type %v", ev.Type)
	}
	if ev.Comm != "cat" || ev.Filename != "/etc/passwd" {
		t.Fatalf("comm=%q filename=%q", ev.Comm, ev.Filename)
	}
	if ev.RemoteEndpoint() != "" || ev.DestAddr != nil {
		t.Fatalf("openat event carries an endpoint: %q", ev.RemoteEndpoint())
	}
}

func TestDecodeSyscallEventConnect(t *testing.T) {
	cases := []struct {
		name   string
		family uint16
		addr   []byte
		port   uint16
		want   string
	}{
		{"ipv4", AF_INET, []byte{140, 82, 121, 4}, 443, "140.82.121.4:443"},
		{"ipv6", AF_INET6, net.ParseIP("2001:db8::1").To16(), 8443, "[2001:db8::1]:8443"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var raw probeSyscallEventT
			raw.Type = uint8(EventConnect)
			raw.Family, raw.Dport = tc.family, tc.port
			copy(raw.Daddr[:], tc.addr)
			ev, err := DecodeSyscallEvent(encode(t, raw))
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if got := ev.RemoteEndpoint(); got != tc.want {
				t.Fatalf("endpoint %q, want %q", got, tc.want)
			}
		})
	}
}

func TestDecodeSyscallEventRejectsMalformed(t *testing.T) {
	if _, err := DecodeSyscallEvent(make([]byte, SyscallEventSize-1)); err == nil {
		t.Fatal("short record decoded without error")
	}
	var raw probeSyscallEventT
	raw.Type, raw.Family = uint8(EventConnect), 1 // AF_UNIX: kernel filters it, so seeing it means drift
	if _, err := DecodeSyscallEvent(encode(t, raw)); err == nil {
		t.Fatal("connect with AF_UNIX decoded without error")
	}
}

// --- tier 2: live kernel --------------------------------------------------

func TestSentinelProbeLoad(t *testing.T) {
	requireLiveBPF(t)
	l, err := NewLoader(LoaderOptions{CaptureVerifierLog: true})
	if err != nil {
		t.Fatalf("NewLoader: %v", err) // a VerifierError carries the full log via %+v
	}
	var ids []ebpf.ProgramID
	for name, prog := range l.Programs() {
		log := l.VerifierLogs()[name]
		if !strings.Contains(log, "processed") {
			t.Errorf("%s: verifier log lacks a stats line: %q", name, log)
		}
		t.Logf("verifier[%s]: %s", name, strings.TrimSpace(log))
		info, err := prog.Info()
		if err != nil {
			t.Fatalf("%s info: %v", name, err)
		}
		id, ok := info.ID()
		if !ok {
			t.Fatalf("%s: kernel did not report a program ID", name)
		}
		ids = append(ids, id)
	}
	if len(ids) != len(tracepoints) {
		t.Fatalf("loaded %d programs, want %d", len(ids), len(tracepoints))
	}

	if err := l.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	// Unload proof: once links and FDs are gone the kernel frees the
	// programs (RCU-deferred, hence the poll), and their IDs stop resolving.
	deadline := time.Now().Add(5 * time.Second)
	for _, id := range ids {
		for {
			p, err := ebpf.NewProgramFromID(id)
			if err != nil {
				break
			}
			p.Close()
			if time.Now().After(deadline) {
				t.Fatalf("program id %d still loaded after Close", id)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
}

// TestHelperProcess is not a test: it is the traced workload, re-executed from
// the test binary so its tgid differs from the (self-filtered) test process.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("SENTINEL_PROBE_HELPER") != "1" {
		return
	}
	f, err := os.Open(os.Getenv("SENTINEL_HELPER_PATH")) // ENOENT is fine: openat still ran
	if err == nil {
		f.Close()
	}
	for _, key := range []string{"SENTINEL_HELPER_DIAL4", "SENTINEL_HELPER_DIAL6"} {
		if addr := os.Getenv(key); addr != "" {
			if c, err := net.DialTimeout("tcp", addr, 2*time.Second); err == nil {
				c.Close()
			}
		}
	}
	os.Exit(0)
}

func TestSentinelProbeSyscallCapture(t *testing.T) {
	requireLiveBPF(t)

	l, err := NewLoader(LoaderOptions{IgnoreTGID: uint32(os.Getpid())})
	if err != nil {
		t.Fatalf("NewLoader: %v", err)
	}
	defer l.Close()

	ln4, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen tcp4: %v", err)
	}
	defer ln4.Close()
	port4 := uint16(ln4.Addr().(*net.TCPAddr).Port)
	var port6 uint16
	dial6 := ""
	if ln6, err := net.Listen("tcp6", "[::1]:0"); err == nil {
		defer ln6.Close()
		port6 = uint16(ln6.Addr().(*net.TCPAddr).Port)
		dial6 = ln6.Addr().String()
	} else {
		t.Logf("no IPv6 loopback (%v); IPv6 connect assertion skipped", err)
	}

	nonce := strconv.FormatInt(time.Now().UnixNano(), 36)
	childPath := "/tmp/sentinel-probe-child-" + nonce
	selfPath := "/tmp/sentinel-probe-self-" + nonce

	// The test process's own openat must be filtered in kernel space.
	if f, err := os.Open(selfPath); err == nil {
		f.Close()
	}

	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperProcess$")
	cmd.Env = append(os.Environ(),
		"SENTINEL_PROBE_HELPER=1",
		"SENTINEL_HELPER_PATH="+childPath,
		"SENTINEL_HELPER_DIAL4="+ln4.Addr().String(),
		"SENTINEL_HELPER_DIAL6="+dial6,
	)
	if err := cmd.Run(); err != nil {
		t.Fatalf("helper: %v", err)
	}
	wantComm := filepath.Base(os.Args[0])
	if len(wantComm) > commLen-1 {
		wantComm = wantComm[:commLen-1]
	}

	// Records carry INIT-namespace tgids; cmd.Process.Pid is in this
	// container's namespace, so the two are not comparable. The child is
	// identified by what only it did (nonce path, listener port, exec path),
	// and all of its records must then agree on one tgid.
	var childTGID uint32
	bind := func(ev *SyscallEvent) {
		if childTGID == 0 {
			childTGID = ev.TGID
		} else if ev.TGID != childTGID {
			t.Fatalf("child records disagree on tgid: %d vs %d (%+v)", childTGID, ev.TGID, ev)
		}
	}

	var gotOpen, gotExec, gotConn4, gotConn6 bool
	if dial6 == "" {
		gotConn6 = true
	}
	deadline := time.Now().Add(10 * time.Second)
	for !(gotOpen && gotExec && gotConn4 && gotConn6) {
		ev, err := l.ReadEvent(deadline)
		if errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("timed out: openat=%v execve=%v connect4=%v connect6=%v", gotOpen, gotExec, gotConn4, gotConn6)
		}
		if err != nil {
			t.Fatalf("ReadEvent: %v", err)
		}
		if ev.Filename == selfPath {
			t.Fatalf("kernel self-filter leaked the test process's own openat: %+v", ev)
		}
		switch ev.Type {
		case EventOpenat, EventOpenat2:
			if ev.Filename != childPath {
				continue
			}
			if ev.Comm != wantComm || ev.UID != uint32(os.Getuid()) || ev.CgroupID == 0 || ev.TGID == 0 {
				t.Fatalf("openat record wrong: comm=%q (want %q) uid=%d cgroup=%d tgid=%d",
					ev.Comm, wantComm, ev.UID, ev.CgroupID, ev.TGID)
			}
			bind(ev)
			gotOpen = true
		case EventExecve:
			if ev.Filename == cmd.Path {
				bind(ev)
				gotExec = true
			}
		case EventConnect:
			if ev.Comm != wantComm {
				continue
			}
			switch {
			case ev.Family == AF_INET && ev.DestPort == port4 && ev.DestAddr.Equal(net.IPv4(127, 0, 0, 1)):
				bind(ev)
				gotConn4 = true
			case ev.Family == AF_INET6 && ev.DestPort == port6 && ev.DestAddr.Equal(net.IPv6loopback):
				bind(ev)
				gotConn6 = true
			}
		}
	}

	drops, err := l.Drops()
	if err != nil {
		t.Fatalf("Drops: %v", err)
	}
	t.Logf("captured openat/execve/connect for child tgid %d (init ns); ring drops=%d", childTGID, drops)
}

func TestLoaderLifecycleReleasesResources(t *testing.T) {
	requireLiveBPF(t)

	countFDs := func() int {
		ents, err := os.ReadDir("/proc/self/fd")
		if err != nil {
			t.Fatalf("read /proc/self/fd: %v", err)
		}
		return len(ents)
	}

	// Warm-up cycle: the first load lazily opens process-lifetime handles
	// (tracefs, BTF of vmlinux) that are not leaks.
	warm, err := NewLoader(LoaderOptions{})
	if err != nil {
		t.Fatalf("NewLoader: %v", err)
	}
	warm.Close()
	before := countFDs()

	for i := 0; i < 25; i++ {
		l, err := NewLoader(LoaderOptions{PollInterval: 20 * time.Millisecond})
		if err != nil {
			t.Fatalf("cycle %d NewLoader: %v", i, err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		events, errs := l.Events(ctx)
		// Consume some real traffic so the reader has actually run.
		select {
		case <-events:
		case <-time.After(2 * time.Second):
		}
		cancel()
		if err := drainClosed(events, 2*time.Second); err != nil {
			t.Fatalf("cycle %d: %v", i, err)
		}
		for e := range errs {
			t.Fatalf("cycle %d: stream error: %v", i, e)
		}
		if err := l.Close(); err != nil {
			t.Fatalf("cycle %d Close: %v", i, err)
		}
		if err := l.Close(); err != nil {
			t.Fatalf("cycle %d second Close not idempotent: %v", i, err)
		}
		if _, err := l.ReadEvent(time.Now().Add(time.Second)); !errors.Is(err, ringbuf.ErrClosed) {
			t.Fatalf("cycle %d: ReadEvent after Close = %v, want ringbuf.ErrClosed", i, err)
		}
	}

	if after := countFDs(); after != before {
		t.Fatalf("fd leak: %d open before 25 cycles, %d after", before, after)
	}
}

func drainClosed(ch <-chan SyscallEvent, within time.Duration) error {
	timeout := time.After(within)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return nil
			}
		case <-timeout:
			return fmt.Errorf("event channel not closed %v after cancel", within)
		}
	}
}

// NewLoader's contract is "on any failure everything already created is
// released before returning". It was not: the function uses NAMED returns, so
// `return nil, err` after a successful LoadAndAssign assigns nil to l, and the
// deferred cleanup then called l.Close() on that nil. Any tracepoint-attach or
// ring-buffer failure therefore panicked with SIGSEGV and took the whole
// sentinel down instead of degrading to the cgroup reconciler. Observed on a
// live node 2026-10-01 under a non-privileged securityContext:
//
//	panic: runtime error: invalid memory address or nil pointer dereference
//	  ebpf.(*Loader).Close(...) loader.go:256
//	  ebpf.NewLoader.func1()    loader.go:120
//
// These two tests pin both halves of the fix: Close tolerates a nil receiver,
// and a partially-initialised Loader really does release what it holds.
func TestLoaderCloseOnNilReceiverIsNotAPanic(t *testing.T) {
	var l *Loader
	if err := l.Close(); err != nil {
		t.Fatalf("Close on a nil *Loader: want nil error, got %v", err)
	}
}

func TestLoaderCloseReleasesPartiallyInitialisedLoader(t *testing.T) {
	// The shape NewLoader holds when a tracepoint attach fails: programs and
	// maps loaded, one link attached, no ring-buffer reader yet.
	first := &countingLink{}
	second := &countingLink{}
	l := &Loader{links: []link.Link{first, second}}

	if err := l.Close(); err != nil {
		t.Fatalf("Close on a partially-initialised Loader: %v", err)
	}
	if first.closed != 1 || second.closed != 1 {
		t.Fatalf("every attached link must be detached exactly once, got first=%d second=%d",
			first.closed, second.closed)
	}
	if l.links != nil {
		t.Fatal("links must be released, not retained")
	}
	// Idempotent: the deferred cleanup and an explicit Close both run.
	if err := l.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if first.closed != 1 {
		t.Fatalf("Close must be once-only, link closed %d times", first.closed)
	}
}

type countingLink struct {
	link.Link
	closed int
}

func (c *countingLink) Close() error { c.closed++; return nil }

// Independent review M2 (2026-10-02): reverting NewLoader's cleanup to use the
// named return stayed green, because only the nil-receiver half of the fix was
// tested and NewLoader needs BPF privileges to reach its failure path. The
// post-load steps now run in attachAndOpen with injectable attach/open, so the
// release of already-attached links is tested without the kernel.

func TestAttachFailureReleasesTheLinksAlreadyAttached(t *testing.T) {
	first := &countingLink{}
	calls := 0
	attach := func(_, _ string, _ *ebpf.Program) (link.Link, error) {
		calls++
		if calls == 1 {
			return first, nil
		}
		return nil, errors.New("neither debugfs nor tracefs are mounted")
	}
	l := &Loader{}
	err := l.attachAndOpen(attach, func() (*ringbuf.Reader, error) {
		t.Fatal("the reader must not be opened after an attach failure")
		return nil, nil
	})
	if err == nil {
		t.Fatal("an attach failure must be returned")
	}
	if first.closed != 1 {
		t.Fatalf("the link attached before the failure was closed %d times, want 1 (leaked)", first.closed)
	}
}

func TestReaderFailureReleasesEveryAttachedLink(t *testing.T) {
	var attached []*countingLink
	attach := func(_, _ string, _ *ebpf.Program) (link.Link, error) {
		lk := &countingLink{}
		attached = append(attached, lk)
		return lk, nil
	}
	l := &Loader{}
	if err := l.attachAndOpen(attach, func() (*ringbuf.Reader, error) {
		return nil, errors.New("ring buffer map unavailable")
	}); err == nil {
		t.Fatal("a reader failure must be returned")
	}
	if len(attached) != len(tracepoints) {
		t.Fatalf("attached %d links, want %d", len(attached), len(tracepoints))
	}
	for i, lk := range attached {
		if lk.closed != 1 {
			t.Fatalf("link %d closed %d times, want 1 (leaked)", i, lk.closed)
		}
	}
}
