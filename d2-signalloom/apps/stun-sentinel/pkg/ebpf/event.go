// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"strconv"
)

// EventType identifies which syscall produced a SyscallEvent. Values mirror
// SENTINEL_EVT_* in bpf/sentinel_probe.c and are part of the frozen contract
// consumed by the SLDC-P1-2 normaliser.
type EventType uint8

const (
	EventOpenat  EventType = 1
	EventExecve  EventType = 2
	EventConnect EventType = 3
	EventOpenat2 EventType = 4
)

// String returns the syscall name, matching the `syscall` field the P1-2
// normaliser emits.
func (t EventType) String() string {
	switch t {
	case EventOpenat:
		return "openat"
	case EventExecve:
		return "execve"
	case EventConnect:
		return "connect"
	case EventOpenat2:
		return "openat2"
	default:
		return "unknown(" + strconv.Itoa(int(t)) + ")"
	}
}

// Wire layout of struct syscall_event_t. The C side _Static_asserts the same
// numbers and TestSyscallEventLayoutMatchesBTF checks both against the BTF the
// compiler actually emitted, so the three cannot drift silently.
const (
	SyscallEventSize = 328

	offTsNs     = 0
	offCgroupID = 8
	offPid      = 16
	offTgid     = 20
	offUID      = 24
	offType     = 28
	offFamily   = 30
	offDport    = 32
	offDaddr    = 40
	offComm     = 56
	offFilename = 72

	commLen     = 16
	filenameLen = 256
	daddrLen    = 16
)

// SyscallEvent is the decoded, userspace form of one ring-buffer record.
//
// PID is the thread id and TGID the process id, in the kernel's naming; the
// value `ps` shows is TGID. Filename is the raw user-supplied argument (not
// canonicalised). DestAddr/DestPort/Family are set only for EventConnect.
type SyscallEvent struct {
	TimestampNs uint64    `json:"timestamp_ns"`
	CgroupID    uint64    `json:"cgroup_id"`
	PID         uint32    `json:"pid"`
	TGID        uint32    `json:"tgid"`
	UID         uint32    `json:"uid"`
	Type        EventType `json:"type"`
	Comm        string    `json:"comm"`
	Filename    string    `json:"filename,omitempty"`
	Family      uint16    `json:"family,omitempty"`
	DestPort    uint16    `json:"dest_port,omitempty"`
	DestAddr    net.IP    `json:"dest_addr,omitempty"`
}

// RemoteEndpoint formats a connect event's destination as host:port
// ("[v6]:port" for IPv6). Empty for non-connect events.
func (e *SyscallEvent) RemoteEndpoint() string {
	if e.Type != EventConnect || e.DestAddr == nil {
		return ""
	}
	return net.JoinHostPort(e.DestAddr.String(), strconv.Itoa(int(e.DestPort)))
}

// DecodeSyscallEvent decodes one raw ring-buffer record. The kernel writes in
// host byte order, so NativeEndian is correct on both bpfel and bpfeb hosts;
// only daddr is in network order, and it is copied as bytes.
func DecodeSyscallEvent(raw []byte) (*SyscallEvent, error) {
	if len(raw) < SyscallEventSize {
		return nil, fmt.Errorf("syscall event too short: %d bytes (want %d)", len(raw), SyscallEventSize)
	}
	ne := binary.NativeEndian
	ev := &SyscallEvent{
		TimestampNs: ne.Uint64(raw[offTsNs:]),
		CgroupID:    ne.Uint64(raw[offCgroupID:]),
		PID:         ne.Uint32(raw[offPid:]),
		TGID:        ne.Uint32(raw[offTgid:]),
		UID:         ne.Uint32(raw[offUID:]),
		Type:        EventType(raw[offType]),
		Comm:        cString(raw[offComm : offComm+commLen]),
		Filename:    cString(raw[offFilename : offFilename+filenameLen]),
	}
	if ev.Type == EventConnect {
		ev.Family = ne.Uint16(raw[offFamily:])
		ev.DestPort = ne.Uint16(raw[offDport:])
		switch ev.Family {
		case AF_INET:
			ev.DestAddr = net.IPv4(raw[offDaddr], raw[offDaddr+1], raw[offDaddr+2], raw[offDaddr+3])
		case AF_INET6:
			ip := make(net.IP, net.IPv6len)
			copy(ip, raw[offDaddr:offDaddr+daddrLen])
			ev.DestAddr = ip
		default:
			return nil, fmt.Errorf("connect event with unsupported family %d", ev.Family)
		}
	}
	return ev, nil
}

// cString returns b up to (not including) the first NUL. Ring-buffer memory
// is not zeroed, so bytes after the terminator are stale and must be ignored.
func cString(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}
