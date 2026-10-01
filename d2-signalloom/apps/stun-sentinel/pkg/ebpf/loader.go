// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
	"golang.org/x/sys/unix"
)

// RingBufferSize is the byte capacity of the `events` ring buffer. It must
// match SENTINEL_RINGBUF_SIZE in bpf/sentinel_probe.c.
const RingBufferSize = 1 << 24

// DefaultPollInterval bounds how long Events blocks in epoll before checking
// for cancellation. It is a wake-up bound, not a spin: the reader sleeps in
// the kernel until a record arrives or the deadline passes.
const DefaultPollInterval = 100 * time.Millisecond

// tracepoints is the attach table: tracefs group/name -> program selector.
var tracepoints = []struct {
	group, name string
	prog        func(*probeObjects) *ebpf.Program
}{
	{"syscalls", "sys_enter_openat", func(o *probeObjects) *ebpf.Program { return o.TraceEnterOpenat }},
	{"syscalls", "sys_enter_openat2", func(o *probeObjects) *ebpf.Program { return o.TraceEnterOpenat2 }},
	{"syscalls", "sys_enter_execve", func(o *probeObjects) *ebpf.Program { return o.TraceEnterExecve }},
	{"syscalls", "sys_enter_connect", func(o *probeObjects) *ebpf.Program { return o.TraceEnterConnect }},
}

// LoaderOptions configures NewLoader.
type LoaderOptions struct {
	// IgnoreTGID is a process whose syscalls are dropped in kernel space
	// before a ring slot is reserved. Set it to os.Getpid() in production to
	// stop the self-tracing feedback loop. It is interpreted in the CALLER's
	// PID namespace (the loader pins that namespace by /proc/self/ns/pid), so
	// it works with and without hostPID. Zero disables the filter.
	IgnoreTGID uint32

	// CaptureVerifierLog records the verifier's statistics line for every
	// program (see VerifierLogs). Costs a larger log buffer at load only.
	CaptureVerifierLog bool

	// PollInterval overrides DefaultPollInterval for Events.
	PollInterval time.Duration
}

// Loader owns the kernel objects for the syscall probe: four programs, their
// tracepoint links, the ring buffer and its reader. Close releases all of it.
type Loader struct {
	objs         probeObjects
	links        []link.Link
	reader       *ringbuf.Reader
	pollInterval time.Duration
	verifierLogs map[string]string

	closeOnce sync.Once
	closeErr  error
}

// NewLoader removes the memlock rlimit, loads the embedded probe into the
// kernel, attaches all tracepoints and opens the ring-buffer reader. On any
// failure everything already created is released before returning.
//
// A verifier rejection is returned as an error wrapping *ebpf.VerifierError;
// format it with %+v to get the full verifier log.
func NewLoader(opts LoaderOptions) (l *Loader, err error) {
	// Needed on kernels < 5.11, which charge BPF memory to RLIMIT_MEMLOCK. A
	// no-op on newer kernels (memcg accounting).
	if err := rlimit.RemoveMemlock(); err != nil {
		return nil, fmt.Errorf("remove memlock rlimit: %w", err)
	}

	spec, err := loadProbe()
	if err != nil {
		return nil, err
	}
	if opts.IgnoreTGID != 0 {
		dev, ino, err := selfPIDNamespace()
		if err != nil {
			return nil, err
		}
		if err := spec.RewriteConstants(map[string]interface{}{
			"sentinel_self_tgid": opts.IgnoreTGID,
			"sentinel_pidns_dev": dev,
			"sentinel_pidns_ino": ino,
		}); err != nil {
			return nil, fmt.Errorf("set self-tgid filter: %w", err)
		}
	}

	collOpts := &ebpf.CollectionOptions{}
	if opts.CaptureVerifierLog {
		collOpts.Programs.LogLevel = ebpf.LogLevelStats
	}

	l = &Loader{pollInterval: opts.PollInterval}
	if l.pollInterval <= 0 {
		l.pollInterval = DefaultPollInterval
	}
	if err := spec.LoadAndAssign(&l.objs, collOpts); err != nil {
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			return nil, fmt.Errorf("BPF verifier rejected sentinel probe: %+v", ve)
		}
		return nil, fmt.Errorf("load sentinel probe: %w", err)
	}
	// Cleanup must hold its OWN pointer. l is a named return, so every
	// `return nil, err` below assigns nil to it before this defer runs -- and
	// a nil l here meant a SIGSEGV that took the whole sentinel down rather
	// than the documented graceful release. See the two TestLoaderClose tests.
	created := l
	defer func() {
		if err != nil {
			_ = created.Close()
			l = nil
		}
	}()

	if opts.CaptureVerifierLog {
		l.verifierLogs = make(map[string]string, len(tracepoints))
		for _, tp := range tracepoints {
			l.verifierLogs[tp.name] = tp.prog(&l.objs).VerifierLog
		}
	}

	for _, tp := range tracepoints {
		lk, err := link.Tracepoint(tp.group, tp.name, tp.prog(&l.objs), nil)
		if err != nil {
			return nil, fmt.Errorf("attach tracepoint %s/%s: %w", tp.group, tp.name, err)
		}
		l.links = append(l.links, lk)
	}

	l.reader, err = ringbuf.NewReader(l.objs.Events)
	if err != nil {
		return nil, fmt.Errorf("open ring buffer reader: %w", err)
	}
	return l, nil
}

// selfPIDNamespace identifies the caller's PID namespace in the form
// bpf_get_ns_current_pid_tgid expects. stat(2) reports st_dev in the
// userspace encoding; the helper compares against the kernel's dev_t
// (major<<20 | minor), so it is re-encoded here rather than passed through.
func selfPIDNamespace() (dev, ino uint64, err error) {
	var st unix.Stat_t
	if err := unix.Stat("/proc/self/ns/pid", &st); err != nil {
		return 0, 0, fmt.Errorf("stat /proc/self/ns/pid: %w", err)
	}
	return uint64(unix.Major(st.Dev))<<20 | uint64(unix.Minor(st.Dev)), st.Ino, nil
}

// VerifierLogs returns the verifier output per tracepoint, keyed by
// tracepoint name. Nil unless LoaderOptions.CaptureVerifierLog was set.
func (l *Loader) VerifierLogs() map[string]string { return l.verifierLogs }

// Reader returns the underlying ring-buffer reader.
func (l *Loader) Reader() *ringbuf.Reader { return l.reader }

// EventsMap exposes the ring buffer map for inspection (type, capacity).
func (l *Loader) EventsMap() *ebpf.Map { return l.objs.Events }

// Programs returns the loaded programs keyed by tracepoint name.
func (l *Loader) Programs() map[string]*ebpf.Program {
	out := make(map[string]*ebpf.Program, len(tracepoints))
	for _, tp := range tracepoints {
		out[tp.name] = tp.prog(&l.objs)
	}
	return out
}

// Drops returns how many records the kernel discarded because the ring buffer
// was full, summed over CPUs.
func (l *Loader) Drops() (uint64, error) {
	var perCPU []uint64
	if err := l.objs.Drops.Lookup(uint32(0), &perCPU); err != nil {
		return 0, fmt.Errorf("read drop counter: %w", err)
	}
	var total uint64
	for _, n := range perCPU {
		total += n
	}
	return total, nil
}

// ReadEvent blocks until one record is available, the deadline passes
// (os.ErrDeadlineExceeded), or the loader is closed (ringbuf.ErrClosed). A
// zero deadline blocks indefinitely.
func (l *Loader) ReadEvent(deadline time.Time) (*SyscallEvent, error) {
	l.reader.SetDeadline(deadline)
	rec, err := l.reader.Read()
	if err != nil {
		return nil, err
	}
	return DecodeSyscallEvent(rec.RawSample)
}

// Events streams decoded records until ctx is cancelled or the loader is
// closed, then closes both channels. Undecodable records and reader failures
// are reported on the error channel rather than silently skipped; it is
// buffered and lossy so a slow error consumer never stalls events. Do not mix
// Events with ReadEvent on the same Loader: they share one reader.
func (l *Loader) Events(ctx context.Context) (<-chan SyscallEvent, <-chan error) {
	out := make(chan SyscallEvent, 1024)
	errs := make(chan error, 16)
	go func() {
		defer close(out)
		defer close(errs)
		var rec ringbuf.Record
		for {
			if ctx.Err() != nil {
				return
			}
			l.reader.SetDeadline(time.Now().Add(l.pollInterval))
			if err := l.reader.ReadInto(&rec); err != nil {
				if errors.Is(err, os.ErrDeadlineExceeded) {
					continue
				}
				if !errors.Is(err, ringbuf.ErrClosed) {
					sendErr(errs, err)
				}
				return
			}
			ev, err := DecodeSyscallEvent(rec.RawSample)
			if err != nil {
				sendErr(errs, err)
				continue
			}
			select {
			case out <- *ev:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, errs
}

func sendErr(errs chan<- error, err error) {
	select {
	case errs <- err:
	default:
	}
}

// Close detaches every tracepoint, closes the reader and unloads the programs
// and maps. Safe to call more than once and from multiple goroutines; a
// concurrent ReadEvent/Events returns ringbuf.ErrClosed.
func (l *Loader) Close() error {
	// A nil receiver is a real call site: NewLoader's cleanup path can reach
	// Close before the Loader is fully built.
	if l == nil {
		return nil
	}
	l.closeOnce.Do(func() {
		var errs []error
		// Detach first so no program fires into a map that is going away.
		for _, lk := range l.links {
			if err := lk.Close(); err != nil {
				errs = append(errs, fmt.Errorf("detach tracepoint: %w", err))
			}
		}
		l.links = nil
		if l.reader != nil {
			if err := l.reader.Close(); err != nil {
				errs = append(errs, fmt.Errorf("close ring buffer reader: %w", err))
			}
		}
		if err := l.objs.Close(); err != nil {
			errs = append(errs, fmt.Errorf("unload probe objects: %w", err))
		}
		l.closeErr = errors.Join(errs...)
	})
	return l.closeErr
}
