// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package quarantine

import (
	"strings"
	"testing"
)

const sampleMaps = `
556df5a0c000-556df5a0e000 r--p 00000000 fd:00 10143421                   /usr/bin/head
556df5a0e000-556df5a15000 r-xp 00002000 fd:00 10143421                   /usr/bin/head
556df5a15000-556df5a18000 r--p 00009000 fd:00 10143421                   /usr/bin/head
556df5a18000-556df5a19000 r--p 0000b000 fd:00 10143421                   /usr/bin/head
556df5a19000-556df5a1a000 rw-p 0000c000 fd:00 10143421                   /usr/bin/head
556e2d307000-556e2d328000 rw-p 00000000 00:00 0                          [heap]
7f8faa000000-7f8faa2ec000 r--p 00000000 fd:00 10093855                   /usr/lib/locale/locale-archive
7f8faa49a000-7f8faa49d000 rw-p 00000000 00:00 0 
7f8faa49d000-7f8faa4c5000 r--p 00000000 fd:00 10126780                   /usr/lib/x86_64-linux-gnu/libc.so.6
7f8faa4c5000-7f8faa628000 r-xp 00028000 fd:00 10126780                   /usr/lib/x86_64-linux-gnu/libc.so.6
7f8faa682000-7f8faa684000 rw-p 001e4000 fd:00 10126780                   /usr/lib/x86_64-linux-gnu/libc.so.6
7f8faa684000-7f8faa691000 rw-p 00000000 00:00 0 
7ffd77351000-7ffd77372000 rw-p 00000000 00:00 0                          [stack]
7ffd773d4000-7ffd773d8000 r--p 00000000 00:00 0                          [vvar]
7ffd773d8000-7ffd773da000 r-xp 00000000 00:00 0                          [vdso]
`

func TestParseMapsFromReader(t *testing.T) {
	regions, err := ParseMapsFromReader(strings.NewReader(sampleMaps))
	if err != nil {
		t.Fatalf("ParseMapsFromReader failed: %v", err)
	}

	if len(regions) != 15 {
		t.Fatalf("expected 15 regions, got %d", len(regions))
	}

	// Check heap region
	heap := regions[5]
	if heap.StartAddr != "0x556e2d307000" || heap.EndAddr != "0x556e2d328000" {
		t.Errorf("heap addr mismatch: %s-%s", heap.StartAddr, heap.EndAddr)
	}
	if !heap.IsAnonymous {
		t.Errorf("expected heap to be anonymous")
	}
	if !heap.IsWritable {
		t.Errorf("expected heap to be writable")
	}
	if heap.Pathname != "[heap]" {
		t.Errorf("expected pathname [heap], got %q", heap.Pathname)
	}

	// Check stack region
	stack := regions[12]
	if stack.Pathname != "[stack]" || !stack.IsAnonymous || !stack.IsWritable {
		t.Errorf("stack properties mismatch: %+v", stack)
	}

	// Check clean code page (executable, non-writable, file-backed)
	code := regions[1]
	if code.IsWritable || code.IsAnonymous || code.Pathname != "/usr/bin/head" {
		t.Errorf("code region properties mismatch: %+v", code)
	}
}

const sampleLocks = `
1: POSIX  ADVISORY  WRITE 18985 fd:00:97704115 0 EOF
2: POSIX  ADVISORY  WRITE 18985 fd:00:89825525 0 EOF
3: POSIX  ADVISORY  WRITE 415478 fd:00:96885062 1073741824 1073742335
4: FLOCK  ADVISORY  WRITE 18985 fd:00:100064515 0 EOF
5: POSIX  ADVISORY  READ 416503 fd:00:96890415 1073741826 1073742335
`

func TestParseLocksFromReader(t *testing.T) {
	records, err := ParseLocksFromReader(strings.NewReader(sampleLocks), 18985)
	if err != nil {
		t.Fatalf("ParseLocksFromReader failed: %v", err)
	}

	if len(records) != 3 {
		t.Fatalf("expected 3 locks for PID 18985, got %d", len(records))
	}

	l1 := records[0]
	if l1.LockType != "POSIX" || l1.LockMode != "WRITE" || l1.Inode != 97704115 || l1.Start != 0 || l1.End != -1 {
		t.Errorf("lock 1 mismatch: %+v", l1)
	}

	l3 := records[2]
	if l3.LockType != "FLOCK" || l3.LockMode != "WRITE" || l3.Inode != 100064515 {
		t.Errorf("lock 3 mismatch: %+v", l3)
	}
}

const sampleNetTCP = `
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 134327 2 0000000087390c03 100 0 0 10 0
   1: 0100007F:E261 0100007F:1F90 01 00000000:00000000 00:00000000 00000000     0        0 495572 2 0000000097761362 100 0 0 10 0
   2: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 999999 2 0000000097761362 100 0 0 10 0
`

func TestParseSocketsFromReader(t *testing.T) {
	targetInodes := map[uint64]int{
		134327: 3, // fd 3
		495572: 4, // fd 4
	}

	socks, err := ParseSocketsFromReader(strings.NewReader(sampleNetTCP), "tcp", targetInodes)
	if err != nil {
		t.Fatalf("ParseSocketsFromReader failed: %v", err)
	}

	if len(socks) != 2 {
		t.Fatalf("expected 2 sockets, got %d", len(socks))
	}

	s0 := socks[0]
	if s0.FD != 3 || s0.Protocol != "tcp" || s0.LocalAddr != "127.0.0.1:8080" || s0.State != "LISTEN" || s0.Inode != 134327 {
		t.Errorf("socket 0 mismatch: %+v", s0)
	}

	s1 := socks[1]
	if s1.FD != 4 || s1.Protocol != "tcp" || s1.LocalAddr != "127.0.0.1:57953" || s1.RemoteAddr != "127.0.0.1:8080" || s1.State != "ESTABLISHED" || s1.Inode != 495572 {
		t.Errorf("socket 1 mismatch: %+v", s1)
	}
}

const sampleStatus = `
Name:	agent-runtime
Umask:	0022
State:	T (stopped)
Tgid:	12345
Ngid:	0
Pid:	12345
PPid:	1
VmSize:	   524288 kB
VmLck:	        0 kB
VmPin:	        0 kB
VmHWM:	    65536 kB
VmRSS:	    32768 kB
RssAnon:	    16384 kB
RssFile:	    16384 kB
RssShmem:	        0 kB
VmData:	    16384 kB
VmStk:	      136 kB
VmExe:	     2048 kB
VmLib:	     8192 kB
VmPTE:	      128 kB
VmSwap:	     4096 kB
`

func TestParseStatusFromReader(t *testing.T) {
	stats, comm, state, ppid, err := ParseStatusFromReader(strings.NewReader(sampleStatus))
	if err != nil {
		t.Fatalf("ParseStatusFromReader failed: %v", err)
	}

	if comm != "agent-runtime" {
		t.Errorf("comm mismatch: got %q, want 'agent-runtime'", comm)
	}
	if state != "T" {
		t.Errorf("state mismatch: got %q, want 'T'", state)
	}
	if ppid != 1 {
		t.Errorf("ppid mismatch: got %d, want 1", ppid)
	}
	if stats.VMSizeBytes != 524288*1024 {
		t.Errorf("VmSize mismatch: got %d", stats.VMSizeBytes)
	}
	if stats.RSSBytes != 32768*1024 {
		t.Errorf("RSSBytes mismatch: got %d", stats.RSSBytes)
	}
	if stats.VMSwapBytes != 4096*1024 {
		t.Errorf("VMSwapBytes mismatch: got %d", stats.VMSwapBytes)
	}
	if stats.VMDataBytes != 16384*1024 {
		t.Errorf("VMDataBytes mismatch: got %d", stats.VMDataBytes)
	}
	if stats.VMStackBytes != 136*1024 {
		t.Errorf("VMStackBytes mismatch: got %d", stats.VMStackBytes)
	}
}
