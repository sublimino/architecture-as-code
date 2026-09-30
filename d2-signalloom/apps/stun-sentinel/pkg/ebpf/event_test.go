// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
	"unicode/utf8"
)

// record builds a raw ring-buffer record by offset, independent of the
// bpf2go-generated struct, so a layout drift in either shows up here.
func record(typ EventType, comm, filename []byte) []byte {
	b := make([]byte, SyscallEventSize)
	binary.NativeEndian.PutUint32(b[offPid:], 4242)
	binary.NativeEndian.PutUint32(b[offTgid:], 4241)
	b[offType] = byte(typ)
	copy(b[offComm:offComm+commLen], comm)
	copy(b[offFilename:offFilename+filenameLen], filename)
	return b
}

func TestDecodeSyscallEventRejectsEveryShortLength(t *testing.T) {
	full := record(EventOpenat, []byte("cat"), []byte("/etc/passwd"))
	for n := 0; n < SyscallEventSize; n++ {
		if ev, err := DecodeSyscallEvent(full[:n]); err == nil || ev != nil {
			t.Fatalf("len %d: decoded (%v, %v), want error", n, ev, err)
		}
	}
	if _, err := DecodeSyscallEvent(nil); err == nil || !strings.Contains(err.Error(), "too short: 0 bytes") {
		t.Fatalf("nil record: err = %v", err)
	}
}

func TestDecodeSyscallEventRejectsUnknownType(t *testing.T) {
	// The probe emits only SENTINEL_EVT_{OPENAT,EXECVE,CONNECT,OPENAT2}; any
	// other type byte means the record is not a syscall_event_t (layout drift,
	// byte-swapped producer, or corruption) and must not reach policy.
	for _, typ := range []EventType{0, 5, 0x80, 0xff} {
		_, err := DecodeSyscallEvent(record(typ, []byte("x"), []byte("/etc/passwd")))
		if err == nil || !strings.Contains(err.Error(), "unknown event type") {
			t.Errorf("type %d: err = %v, want unknown event type", typ, err)
		}
	}
}

func TestDecodeSyscallEventUnterminatedFieldsStayInBounds(t *testing.T) {
	comm := bytes.Repeat([]byte{'C'}, commLen)          // no NUL
	name := bytes.Repeat([]byte{'/'}, filenameLen)      // no NUL
	raw := append(record(EventOpenat, comm, name), 'X') // trailing byte past the struct
	ev, err := DecodeSyscallEvent(raw)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Comm != string(comm) {
		t.Errorf("comm = %q (%d bytes), want exactly the 16-byte field", ev.Comm, len(ev.Comm))
	}
	if ev.Filename != string(name) {
		t.Errorf("filename length %d, want exactly %d (no read into trailing bytes)", len(ev.Filename), filenameLen)
	}
}

func TestDecodeSyscallEventIgnoresStaleBytesAfterNUL(t *testing.T) {
	ev, err := DecodeSyscallEvent(record(EventOpenat, []byte("sh\x00stale"), []byte("/tmp/a\x00/etc/shadow")))
	if err != nil {
		t.Fatal(err)
	}
	if ev.Comm != "sh" || ev.Filename != "/tmp/a" {
		t.Fatalf("comm=%q filename=%q, want sh and /tmp/a", ev.Comm, ev.Filename)
	}
}

func TestDecodeSyscallEventKeepsNonUTF8BytesVerbatim(t *testing.T) {
	name := []byte("/etc/\xff\xfepasswd")
	ev, err := DecodeSyscallEvent(record(EventOpenat, nil, name))
	if err != nil {
		t.Fatal(err)
	}
	if ev.Filename != string(name) {
		t.Fatalf("filename = %q, want the raw bytes %q", ev.Filename, name)
	}
}

func TestDecodeSyscallEventNonConnectIgnoresSockaddr(t *testing.T) {
	raw := record(EventOpenat, nil, []byte("/x"))
	binary.NativeEndian.PutUint16(raw[offFamily:], 1) // AF_UNIX garbage in a non-connect slot
	ev, err := DecodeSyscallEvent(raw)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Family != 0 || ev.DestAddr != nil || ev.RemoteEndpoint() != "" {
		t.Fatalf("non-connect event carried sockaddr: %+v", ev)
	}
}

// FuzzDecodeSyscallEvent: arbitrary bytes must never panic, and a successful
// decode must respect the field bounds and the known-type contract.
func FuzzDecodeSyscallEvent(f *testing.F) {
	f.Add(record(EventOpenat, []byte("cat"), []byte("/etc/passwd")))
	f.Add(record(EventExecve, bytes.Repeat([]byte{'A'}, 16), bytes.Repeat([]byte{0xff}, 256)))
	c := record(EventConnect, []byte("curl"), nil)
	binary.NativeEndian.PutUint16(c[offFamily:], AF_INET6)
	f.Add(c)
	f.Add([]byte{})
	f.Fuzz(func(t *testing.T, raw []byte) {
		ev, err := DecodeSyscallEvent(raw)
		if err != nil {
			if ev != nil {
				t.Fatal("error with non-nil event")
			}
			return
		}
		if len(raw) < SyscallEventSize {
			t.Fatalf("decoded a %d-byte record", len(raw))
		}
		if len(ev.Comm) > commLen || len(ev.Filename) > filenameLen {
			t.Fatalf("field overrun: comm %d filename %d", len(ev.Comm), len(ev.Filename))
		}
		if strings.IndexByte(ev.Comm, 0) >= 0 || strings.IndexByte(ev.Filename, 0) >= 0 {
			t.Fatal("NUL survived into a decoded string")
		}
		switch ev.Type {
		case EventOpenat, EventExecve, EventOpenat2:
			if ev.DestAddr != nil {
				t.Fatal("non-connect event has a destination")
			}
		case EventConnect:
			if ev.Family != AF_INET && ev.Family != AF_INET6 {
				t.Fatalf("connect decoded with family %d", ev.Family)
			}
		default:
			t.Fatalf("decoded unknown type %d", ev.Type)
		}
		_ = utf8.ValidString(ev.Filename) // non-UTF-8 is legal; only bounds matter
	})
}
