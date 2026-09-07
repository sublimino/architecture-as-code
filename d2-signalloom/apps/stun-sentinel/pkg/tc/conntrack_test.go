// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"encoding/binary"
	"errors"
	"net"
	"syscall"
	"testing"
)

// The netlink tests assert BYTES, not behaviour of a mock. A conntrack delete
// that is one padding byte wrong is accepted by the socket and then silently
// ignored by the kernel: the call succeeds, nothing is deleted, and every
// higher-level test that asks "did the flush return without error" passes.
// Byte-level assertions are the only place that class of defect is visible
// without a kernel.

func TestNLMsgAlign(t *testing.T) {
	cases := []struct{ in, want int }{
		{0, 0}, {1, 4}, {2, 4}, {3, 4}, {4, 4}, {5, 8}, {8, 8}, {9, 12}, {20, 20}, {21, 24},
	}
	for _, c := range cases {
		if got := nlMsgAlign(c.in); got != c.want {
			t.Errorf("nlMsgAlign(%d) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestEncodeAttrHeaderAndPadding(t *testing.T) {
	// A 1-byte payload: nla_len counts header+payload UNPADDED (5), but the
	// buffer is padded to 8. Conflating the two is the classic netlink bug.
	got := encodeAttr(attr{typ: ctaProtoNum, data: []byte{6}})
	if len(got) != 8 {
		t.Fatalf("buffer length = %d, want 8 (padded)", len(got))
	}
	if l := binary.LittleEndian.Uint16(got[0:2]); l != 5 {
		t.Errorf("nla_len = %d, want 5 (header 4 + payload 1, unpadded)", l)
	}
	if typ := binary.LittleEndian.Uint16(got[2:4]); typ != ctaProtoNum {
		t.Errorf("nla_type = %d, want %d", typ, ctaProtoNum)
	}
	if got[4] != 6 {
		t.Errorf("payload = %d, want 6", got[4])
	}
	for i := 5; i < 8; i++ {
		if got[i] != 0 {
			t.Errorf("padding byte %d = %d, want 0", i, got[i])
		}
	}
}

func TestEncodeAttrIPv4IsExactlyEightBytes(t *testing.T) {
	got := encodeAttr(attr{typ: ctaIPv4Src, data: net.IPv4(10, 244, 0, 7).To4()})
	if len(got) != 8 {
		t.Fatalf("length = %d, want 8", len(got))
	}
	if l := binary.LittleEndian.Uint16(got[0:2]); l != 8 {
		t.Errorf("nla_len = %d, want 8", l)
	}
	if !bytesEqual(got[4:8], []byte{10, 244, 0, 7}) {
		t.Errorf("payload = %v, want [10 244 0 7] in network order", got[4:8])
	}
}

func TestEncodeNestedSetsNestedFlag(t *testing.T) {
	child := encodeAttr(attr{typ: ctaIPv4Src, data: []byte{1, 2, 3, 4}})
	got := encodeNested(ctaTupleIP, child)
	typ := binary.LittleEndian.Uint16(got[2:4])
	if typ&nlaFNested == 0 {
		t.Errorf("nested flag not set: type = 0x%04x", typ)
	}
	if typ&^nlaFNested != ctaTupleIP {
		t.Errorf("nested type = %d, want %d", typ&^nlaFNested, ctaTupleIP)
	}
}

func TestBuildDeleteMessageWireFormat(t *testing.T) {
	orig := ConntrackTuple{
		SrcIP:    net.IPv4(10, 244, 0, 7),
		DstIP:    net.IPv4(10, 244, 0, 1),
		SrcPort:  54321,
		DstPort:  8080,
		Protocol: syscall.IPPROTO_TCP,
	}
	msg, err := BuildDeleteMessage(42, orig)
	if err != nil {
		t.Fatalf("BuildDeleteMessage: %v", err)
	}

	// ISC-89: the length field must match the actual buffer length. A
	// mismatch here is exactly what makes the kernel return EINVAL, or
	// worse, read past the message.
	declared := binary.LittleEndian.Uint32(msg[0:4])
	if int(declared) != len(msg) {
		t.Errorf("nlmsg_len = %d but buffer is %d bytes", declared, len(msg))
	}

	// ISC-80/81: type is (subsys << 8) | msg.
	msgType := binary.LittleEndian.Uint16(msg[4:6])
	wantType := uint16((nfnlSubsysCTNetlink << 8) | ipctnlMsgCTDelete)
	if msgType != wantType {
		t.Errorf("nlmsg_type = 0x%04x, want 0x%04x (NFNL_SUBSYS_CTNETLINK|IPCTNL_MSG_CT_DELETE)", msgType, wantType)
	}

	flags := binary.LittleEndian.Uint16(msg[6:8])
	if flags&syscall.NLM_F_REQUEST == 0 {
		t.Error("NLM_F_REQUEST not set")
	}
	if flags&syscall.NLM_F_ACK == 0 {
		t.Error("NLM_F_ACK not set: deletes would not be acknowledged and errors would be invisible")
	}
	if seq := binary.LittleEndian.Uint32(msg[8:12]); seq != 42 {
		t.Errorf("seq = %d, want 42", seq)
	}

	// ISC-82: nfgenmsg family must be AF_INET.
	body := msg[syscall.NLMSG_HDRLEN:]
	if body[0] != syscall.AF_INET {
		t.Errorf("nfgen_family = %d, want AF_INET (%d)", body[0], syscall.AF_INET)
	}
	if body[1] != nfnetlinkV0 {
		t.Errorf("nfnetlink version = %d, want %d", body[1], nfnetlinkV0)
	}

	// ISC-84/85/86: BOTH tuple directions must be present. A one-sided
	// delete leaves the reply-direction lookup able to resurrect the flow.
	attrs := parseAttrs(body[nfgenmsgLen:])
	origPayload, hasOrig := attrs[ctaTupleOrig]
	if !hasOrig {
		t.Fatal("CTA_TUPLE_ORIG missing")
	}
	replyPayload, hasReply := attrs[ctaTupleReply]
	if !hasReply {
		t.Fatal("CTA_TUPLE_REPLY missing: a one-directional delete is not a delete")
	}

	gotOrig, ok := parseTuple(origPayload)
	if !ok {
		t.Fatal("could not parse CTA_TUPLE_ORIG back")
	}
	if !gotOrig.SrcIP.Equal(orig.SrcIP) || !gotOrig.DstIP.Equal(orig.DstIP) {
		t.Errorf("orig tuple round-trip = %s, want %s", gotOrig, orig)
	}
	if gotOrig.SrcPort != 54321 || gotOrig.DstPort != 8080 {
		t.Errorf("orig ports = %d/%d, want 54321/8080", gotOrig.SrcPort, gotOrig.DstPort)
	}
	if gotOrig.Protocol != syscall.IPPROTO_TCP {
		t.Errorf("orig proto = %d, want TCP", gotOrig.Protocol)
	}

	// The reply tuple must be the ORIGINAL WITH ENDPOINTS SWAPPED. This is
	// the assertion that catches a copy-paste of the orig tuple into the
	// reply slot, which would look correct in a hex dump and delete nothing.
	gotReply, ok := parseTuple(replyPayload)
	if !ok {
		t.Fatal("could not parse CTA_TUPLE_REPLY back")
	}
	if !gotReply.SrcIP.Equal(orig.DstIP) || !gotReply.DstIP.Equal(orig.SrcIP) {
		t.Errorf("reply tuple = %s, want endpoints swapped from %s", gotReply, orig)
	}
	if gotReply.SrcPort != orig.DstPort || gotReply.DstPort != orig.SrcPort {
		t.Errorf("reply ports = %d/%d, want %d/%d (swapped)", gotReply.SrcPort, gotReply.DstPort, orig.DstPort, orig.SrcPort)
	}
}

func TestBuildDeleteMessageRejectsIPv6(t *testing.T) {
	_, err := BuildDeleteMessage(1, ConntrackTuple{
		SrcIP: net.ParseIP("fd00::1"),
		DstIP: net.ParseIP("fd00::2"),
	})
	if err == nil {
		t.Fatal("expected an error for IPv6 tuples, got nil")
	}
}

func TestBuildDumpMessageSetsDumpFlag(t *testing.T) {
	msg := BuildDumpMessage(7)
	if int(binary.LittleEndian.Uint32(msg[0:4])) != len(msg) {
		t.Error("nlmsg_len does not match buffer length")
	}
	msgType := binary.LittleEndian.Uint16(msg[4:6])
	if msgType != uint16((nfnlSubsysCTNetlink<<8)|ipctnlMsgCTGet) {
		t.Errorf("nlmsg_type = 0x%04x, want CT_GET", msgType)
	}
	flags := binary.LittleEndian.Uint16(msg[6:8])
	if flags&syscall.NLM_F_DUMP == 0 {
		t.Error("NLM_F_DUMP not set: the kernel would return one entry, not the table")
	}
}

// --- fake netlink connection ------------------------------------------------

type fakeConn struct {
	sent     [][]byte
	responses [][]byte
	recvIdx  int
	closed   bool
	sendErr  error
}

func (f *fakeConn) Send(b []byte) error {
	if f.sendErr != nil {
		return f.sendErr
	}
	f.sent = append(f.sent, append([]byte{}, b...))
	return nil
}

func (f *fakeConn) Receive() ([]byte, error) {
	if f.recvIdx >= len(f.responses) {
		return nil, errors.New("fakeConn: no more responses")
	}
	r := f.responses[f.recvIdx]
	f.recvIdx++
	return r, nil
}

func (f *fakeConn) Close() error { f.closed = true; return nil }

// buildCTEntry synthesises a conntrack dump entry as the kernel would emit it.
func buildCTEntry(t ConntrackTuple) []byte {
	origAttr, err := encodeTuple(ctaTupleOrig, t)
	if err != nil {
		panic(err)
	}
	nfgen := make([]byte, nfgenmsgLen)
	nfgen[0] = syscall.AF_INET
	body := append(append([]byte{}, nfgen...), origAttr...)
	total := syscall.NLMSG_HDRLEN + len(body)
	msg := make([]byte, nlMsgAlign(total))
	binary.LittleEndian.PutUint32(msg[0:4], uint32(total))
	binary.LittleEndian.PutUint16(msg[4:6], (nfnlSubsysCTNetlink<<8)|ipctnlMsgCTNew)
	copy(msg[syscall.NLMSG_HDRLEN:], body)
	return msg
}

func buildDoneMsg() []byte {
	msg := make([]byte, syscall.NLMSG_HDRLEN)
	binary.LittleEndian.PutUint32(msg[0:4], uint32(syscall.NLMSG_HDRLEN))
	binary.LittleEndian.PutUint16(msg[4:6], syscall.NLMSG_DONE)
	return msg
}

func buildAckMsg(errno int32) []byte {
	msg := make([]byte, syscall.NLMSG_HDRLEN+4)
	binary.LittleEndian.PutUint32(msg[0:4], uint32(len(msg)))
	binary.LittleEndian.PutUint16(msg[4:6], syscall.NLMSG_ERROR)
	binary.LittleEndian.PutUint32(msg[syscall.NLMSG_HDRLEN:], uint32(errno))
	return msg
}

func TestFlushDeletesOnlyMatchingTuples(t *testing.T) {
	target := net.IPv4(10, 244, 0, 7)
	mine := ConntrackTuple{SrcIP: target, DstIP: net.IPv4(93, 184, 216, 34), SrcPort: 40000, DstPort: 443, Protocol: syscall.IPPROTO_TCP}
	inbound := ConntrackTuple{SrcIP: net.IPv4(10, 244, 0, 1), DstIP: target, SrcPort: 5000, DstPort: 8080, Protocol: syscall.IPPROTO_TCP}
	// A completely unrelated flow between two other pods. If this is ever
	// deleted, the flush has become a table-wide flush and ISC-91/95 fail.
	other := ConntrackTuple{SrcIP: net.IPv4(10, 244, 0, 9), DstIP: net.IPv4(10, 244, 0, 11), SrcPort: 1234, DstPort: 5678, Protocol: syscall.IPPROTO_TCP}

	dump := append(append(append([]byte{}, buildCTEntry(mine)...), buildCTEntry(inbound)...), buildCTEntry(other)...)
	dump = append(dump, buildDoneMsg()...)

	f := &fakeConn{responses: [][]byte{dump, buildAckMsg(0), buildAckMsg(0)}}

	deleted, err := flushIPOn(f, target)
	if err != nil {
		t.Fatalf("flushIPOn: %v", err)
	}
	if deleted != 2 {
		t.Errorf("deleted = %d, want 2 (outbound + inbound), not the unrelated flow", deleted)
	}

	// sent[0] is the dump request; the rest are deletes.
	if len(f.sent) != 3 {
		t.Fatalf("sent %d messages, want 3 (1 dump + 2 deletes)", len(f.sent))
	}
	for i, msg := range f.sent[1:] {
		body := msg[syscall.NLMSG_HDRLEN:]
		attrs := parseAttrs(body[nfgenmsgLen:])
		tup, ok := parseTuple(attrs[ctaTupleOrig])
		if !ok {
			t.Fatalf("delete %d has an unparseable orig tuple", i)
		}
		if !tupleMatchesIP(tup, target) {
			t.Errorf("delete %d targets %s, which does not involve %s — this is a table-wide flush", i, tup, target)
		}
		if tup.SrcIP.Equal(other.SrcIP) && tup.DstIP.Equal(other.DstIP) {
			t.Errorf("delete %d destroyed an UNRELATED flow: %s", i, tup)
		}
	}
}

func TestFlushReportsNoEntriesAsSentinel(t *testing.T) {
	target := net.IPv4(10, 244, 0, 7)
	other := ConntrackTuple{SrcIP: net.IPv4(10, 0, 0, 1), DstIP: net.IPv4(10, 0, 0, 2), Protocol: syscall.IPPROTO_TCP}
	dump := append(buildCTEntry(other), buildDoneMsg()...)
	f := &fakeConn{responses: [][]byte{dump}}

	_, err := flushIPOn(f, target)
	if !errors.Is(err, ErrNoConntrackEntries) {
		t.Fatalf("err = %v, want ErrNoConntrackEntries", err)
	}
	if len(f.sent) != 1 {
		t.Errorf("sent %d messages, want 1 (dump only, no deletes)", len(f.sent))
	}
}

func TestFlushTreatsENOENTAckAsSuccess(t *testing.T) {
	// The entry expired between the dump and the delete. That is the state
	// we wanted; reporting it as a failure would make a successful flush
	// look broken.
	target := net.IPv4(10, 244, 0, 7)
	mine := ConntrackTuple{SrcIP: target, DstIP: net.IPv4(1, 1, 1, 1), Protocol: syscall.IPPROTO_TCP}
	dump := append(buildCTEntry(mine), buildDoneMsg()...)
	f := &fakeConn{responses: [][]byte{dump, buildAckMsg(-int32(syscall.ENOENT))}}

	deleted, err := flushIPOn(f, target)
	if err != nil {
		t.Fatalf("flushIPOn: %v", err)
	}
	if deleted != 1 {
		t.Errorf("deleted = %d, want 1 (ENOENT counts as already-gone)", deleted)
	}
}

func TestCountIPCountsBothDirections(t *testing.T) {
	target := net.IPv4(10, 244, 0, 7)
	out := ConntrackTuple{SrcIP: target, DstIP: net.IPv4(8, 8, 8, 8), Protocol: syscall.IPPROTO_UDP}
	in := ConntrackTuple{SrcIP: net.IPv4(8, 8, 4, 4), DstIP: target, Protocol: syscall.IPPROTO_UDP}
	other := ConntrackTuple{SrcIP: net.IPv4(10, 0, 0, 1), DstIP: net.IPv4(10, 0, 0, 2), Protocol: syscall.IPPROTO_TCP}
	dump := append(append(append([]byte{}, buildCTEntry(out)...), buildCTEntry(in)...), buildCTEntry(other)...)
	dump = append(dump, buildDoneMsg()...)

	n, err := countIPOn(&fakeConn{responses: [][]byte{dump}}, target)
	if err != nil {
		t.Fatalf("countIPOn: %v", err)
	}
	if n != 2 {
		t.Errorf("count = %d, want 2", n)
	}
}

func TestParseDumpResponseRejectsMalformedLength(t *testing.T) {
	buf := make([]byte, 32)
	binary.LittleEndian.PutUint32(buf[0:4], 9999) // longer than the buffer
	if _, _, err := parseDumpResponse(buf); err == nil {
		t.Fatal("expected an error on a message claiming to be longer than the buffer")
	}
}

func TestFlushIPRejectsNilAndIPv6(t *testing.T) {
	if _, err := FlushIP(nil); err == nil {
		t.Error("FlushIP(nil) should error")
	}
	if _, err := FlushIP(net.ParseIP("fd00::1")); err == nil {
		t.Error("FlushIP(IPv6) should error")
	}
}

func TestTupleMatchesIPBothEndpoints(t *testing.T) {
	target := net.IPv4(10, 244, 0, 7)
	if !tupleMatchesIP(ConntrackTuple{SrcIP: target, DstIP: net.IPv4(1, 1, 1, 1)}, target) {
		t.Error("failed to match target as source (egress flow)")
	}
	if !tupleMatchesIP(ConntrackTuple{SrcIP: net.IPv4(1, 1, 1, 1), DstIP: target}, target) {
		t.Error("failed to match target as destination (ingress flow)")
	}
	if tupleMatchesIP(ConntrackTuple{SrcIP: net.IPv4(1, 1, 1, 1), DstIP: net.IPv4(2, 2, 2, 2)}, target) {
		t.Error("matched a flow that does not involve the target at all")
	}
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
