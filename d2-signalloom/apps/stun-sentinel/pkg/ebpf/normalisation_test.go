// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"encoding/binary"
	"net"
	"testing"
)

func TestDecodeSyscallEventAllFourTypes(t *testing.T) {
	cases := []struct {
		name         string
		typ          EventType
		comm         string
		filename     string
		family       uint16
		port         uint16
		addr         []byte
		wantTypeStr  string
		wantEndpoint string
	}{
		{
			name:        "openat",
			typ:         EventOpenat,
			comm:        "cat",
			filename:    "/etc/passwd",
			wantTypeStr: "openat",
		},
		{
			name:        "openat2",
			typ:         EventOpenat2,
			comm:        "openat2_test",
			filename:    "/etc/shadow",
			wantTypeStr: "openat2",
		},
		{
			name:        "execve",
			typ:         EventExecve,
			comm:        "bash",
			filename:    "/usr/bin/python3",
			wantTypeStr: "execve",
		},
		{
			name:         "connect_ipv4",
			typ:          EventConnect,
			comm:         "curl",
			family:       AF_INET,
			port:         443,
			addr:         []byte{10, 96, 0, 10},
			wantTypeStr:  "connect",
			wantEndpoint: "10.96.0.10:443",
		},
		{
			name:         "connect_ipv6",
			typ:          EventConnect,
			comm:         "curl",
			family:       AF_INET6,
			port:         8443,
			addr:         net.ParseIP("2001:db8::1").To16(),
			wantTypeStr:  "connect",
			wantEndpoint: "[2001:db8::1]:8443",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw := record(tc.typ, []byte(tc.comm), []byte(tc.filename))
			if tc.typ == EventConnect {
				binary.NativeEndian.PutUint16(raw[offFamily:], tc.family)
				binary.NativeEndian.PutUint16(raw[offDport:], tc.port)
				copy(raw[offDaddr:offDaddr+daddrLen], tc.addr)
			}

			ev, err := DecodeSyscallEvent(raw)
			if err != nil {
				t.Fatalf("DecodeSyscallEvent failed: %v", err)
			}
			if ev.Type != tc.typ {
				t.Errorf("ev.Type = %v, want %v", ev.Type, tc.typ)
			}
			if ev.Type.String() != tc.wantTypeStr {
				t.Errorf("ev.Type.String() = %q, want %q", ev.Type.String(), tc.wantTypeStr)
			}
			if tc.comm != "" && ev.Comm != tc.comm {
				t.Errorf("ev.Comm = %q, want %q", ev.Comm, tc.comm)
			}
			if tc.filename != "" && ev.Filename != tc.filename {
				t.Errorf("ev.Filename = %q, want %q", ev.Filename, tc.filename)
			}
			if tc.wantEndpoint != "" && ev.RemoteEndpoint() != tc.wantEndpoint {
				t.Errorf("ev.RemoteEndpoint() = %q, want %q", ev.RemoteEndpoint(), tc.wantEndpoint)
			}
		})
	}
}

func TestLoaderAttachedTracepointsReflectsSuccess(t *testing.T) {
	// A Loader with tracepoints attached returns their names
	var l Loader
	l.attachedTPs = []string{"sys_enter_openat", "sys_enter_openat2", "sys_enter_execve", "sys_enter_connect"}

	got := l.AttachedTracepoints()
	if len(got) != 4 {
		t.Fatalf("AttachedTracepoints() len = %d, want 4", len(got))
	}
	want := []string{"sys_enter_openat", "sys_enter_openat2", "sys_enter_execve", "sys_enter_connect"}
	for i, name := range want {
		if got[i] != name {
			t.Errorf("AttachedTracepoints()[%d] = %q, want %q", i, got[i], name)
		}
	}

	// Close empties the list
	_ = l.Close()
	if len(l.AttachedTracepoints()) != 0 {
		t.Errorf("AttachedTracepoints() after Close = %v, want empty", l.AttachedTracepoints())
	}
}
