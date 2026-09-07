// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

// conntrack.go implements conntrack invalidation over a raw NETLINK_NETFILTER
// socket.
//
// WHY THIS EXISTS AT ALL. Dropping packets with TC does not terminate an
// established TCP session. The conntrack entry survives, both peers keep
// retransmitting, and the moment the drop filter is removed the flow resumes
// exactly where it left off — including any half-written exfiltration. Deleting
// the conntrack entry makes the kernel treat every subsequent segment of that
// flow as INVALID, so the flow cannot resume even if the filter is later
// detached.
//
// WHY BY EXACT TUPLE. `conntrack -F` flushes the entire table. On a busy node
// that destroys every unrelated flow AND takes a global lock long enough to
// show up as interrupt latency. This implementation dumps, filters in
// userspace, and deletes only the tuples whose source or destination is the
// target container — which is the "filter deletion by exact tuple keys"
// mitigation named on the card.
//
// WHY HAND-ROLLED. The card specifies netlink socket protocol directly, and a
// hand-rolled encoder is byte-assertable in a unit test without a kernel. The
// wire format below follows linux/netfilter/nfnetlink_conntrack.h.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
	"unsafe"
)

// ErrNoConntrackEntries reports that no entry matched the target. This is
// success, not failure: it is the terminal state the flush is trying to reach,
// and callers must not treat it as an error.
var ErrNoConntrackEntries = errors.New("conntrack: no entries matched target")

// netfilter netlink constants (linux/netfilter/nfnetlink.h and
// nfnetlink_conntrack.h). Declared locally rather than pulled from a
// dependency so the wire format under test is visible in this file.
const (
	nfnlSubsysCTNetlink = 1

	ipctnlMsgCTNew    = 0
	ipctnlMsgCTGet    = 1
	ipctnlMsgCTDelete = 2

	nfnetlinkV0 = 0

	// Top-level CTA_* attributes.
	ctaTupleOrig  = 1
	ctaTupleReply = 2

	// CTA_TUPLE_* (nested inside CTA_TUPLE_ORIG / _REPLY).
	ctaTupleIP    = 1
	ctaTupleProto = 2

	// CTA_IP_* (nested inside CTA_TUPLE_IP).
	ctaIPv4Src = 1
	ctaIPv4Dst = 2

	// CTA_PROTO_* (nested inside CTA_TUPLE_PROTO).
	ctaProtoNum     = 1
	ctaProtoSrcPort = 2
	ctaProtoDstPort = 3

	// Netlink attribute nesting flag.
	nlaFNested = 0x8000

	// sizeof(struct nfgenmsg)
	nfgenmsgLen = 4
)

// nlMsgAlign rounds a length up to the 4-byte netlink alignment. Getting this
// wrong produces a message the kernel silently ignores or rejects with EINVAL,
// so it is asserted directly in the unit tests.
func nlMsgAlign(n int) int { return (n + 3) &^ 3 }

// ConntrackTuple is one direction of a tracked flow.
type ConntrackTuple struct {
	SrcIP    net.IP
	DstIP    net.IP
	SrcPort  uint16
	DstPort  uint16
	Protocol uint8
}

// String renders the tuple the way `conntrack -L` does, for log and evidence
// output.
func (t ConntrackTuple) String() string {
	return fmt.Sprintf("%s %s:%d -> %s:%d", protoName(t.Protocol), t.SrcIP, t.SrcPort, t.DstIP, t.DstPort)
}

func protoName(p uint8) string {
	switch p {
	case syscall.IPPROTO_TCP:
		return "tcp"
	case syscall.IPPROTO_UDP:
		return "udp"
	case syscall.IPPROTO_ICMP:
		return "icmp"
	default:
		return fmt.Sprintf("proto-%d", p)
	}
}

// attr is a netlink attribute under construction.
type attr struct {
	typ  uint16
	data []byte
}

// encodeAttr serialises one netlink attribute: a 4-byte header (len, type)
// followed by the payload padded to a 4-byte boundary. nla_len counts the
// header plus the UNPADDED payload; the padding is present in the buffer but
// not in the length. That asymmetry is the single most common way a hand-built
// netlink message ends up malformed.
func encodeAttr(a attr) []byte {
	payloadLen := len(a.data)
	total := 4 + payloadLen
	buf := make([]byte, nlMsgAlign(total))
	binary.LittleEndian.PutUint16(buf[0:2], uint16(total))
	binary.LittleEndian.PutUint16(buf[2:4], a.typ)
	copy(buf[4:], a.data)
	return buf
}

// encodeNested wraps child attributes in a nested attribute.
func encodeNested(typ uint16, children ...[]byte) []byte {
	var payload []byte
	for _, c := range children {
		payload = append(payload, c...)
	}
	return encodeAttr(attr{typ: typ | nlaFNested, data: payload})
}

// encodeTuple builds a CTA_TUPLE_ORIG or CTA_TUPLE_REPLY attribute.
//
// Structure (nesting is significant; a flat encoding is accepted by the socket
// and then ignored by the kernel, which is a silent no-op flush):
//
//	CTA_TUPLE_{ORIG,REPLY}
//	  CTA_TUPLE_IP
//	    CTA_IP_V4_SRC   (4 bytes, network order)
//	    CTA_IP_V4_DST   (4 bytes, network order)
//	  CTA_TUPLE_PROTO
//	    CTA_PROTO_NUM       (1 byte)
//	    CTA_PROTO_SRC_PORT  (2 bytes, network order)
//	    CTA_PROTO_DST_PORT  (2 bytes, network order)
func encodeTuple(typ uint16, t ConntrackTuple) ([]byte, error) {
	src := t.SrcIP.To4()
	dst := t.DstIP.To4()
	if src == nil || dst == nil {
		return nil, fmt.Errorf("conntrack: tuple requires IPv4 addresses, got src=%v dst=%v", t.SrcIP, t.DstIP)
	}

	ipNested := encodeNested(ctaTupleIP,
		encodeAttr(attr{typ: ctaIPv4Src, data: []byte(src)}),
		encodeAttr(attr{typ: ctaIPv4Dst, data: []byte(dst)}),
	)

	srcPort := make([]byte, 2)
	dstPort := make([]byte, 2)
	binary.BigEndian.PutUint16(srcPort, t.SrcPort) // ports are network order on the wire
	binary.BigEndian.PutUint16(dstPort, t.DstPort)

	protoNested := encodeNested(ctaTupleProto,
		encodeAttr(attr{typ: ctaProtoNum, data: []byte{t.Protocol}}),
		encodeAttr(attr{typ: ctaProtoSrcPort, data: srcPort}),
		encodeAttr(attr{typ: ctaProtoDstPort, data: dstPort}),
	)

	return encodeNested(typ, ipNested, protoNested), nil
}

// BuildDeleteMessage serialises a complete IPCTNL_MSG_CT_DELETE netlink
// message for one flow.
//
// Both the original and the reply tuple are encoded. Deleting by the original
// tuple alone leaves NAT'd and reply-direction lookups able to resurrect the
// entry, so a one-sided delete is not a delete — this is the "atomic deletion
// of bidirectional flow tuples" the card's evidence list requires.
//
// Exported so the unit tests can assert the exact bytes without a kernel.
func BuildDeleteMessage(seq uint32, orig ConntrackTuple) ([]byte, error) {
	origAttr, err := encodeTuple(ctaTupleOrig, orig)
	if err != nil {
		return nil, err
	}
	reply := ConntrackTuple{
		SrcIP:    orig.DstIP,
		DstIP:    orig.SrcIP,
		SrcPort:  orig.DstPort,
		DstPort:  orig.SrcPort,
		Protocol: orig.Protocol,
	}
	replyAttr, err := encodeTuple(ctaTupleReply, reply)
	if err != nil {
		return nil, err
	}

	// struct nfgenmsg { u8 nfgen_family; u8 version; __be16 res_id; }
	nfgen := make([]byte, nfgenmsgLen)
	nfgen[0] = syscall.AF_INET
	nfgen[1] = nfnetlinkV0
	binary.BigEndian.PutUint16(nfgen[2:4], 0) // res_id is big-endian by definition

	body := append(append(append([]byte{}, nfgen...), origAttr...), replyAttr...)
	total := syscall.NLMSG_HDRLEN + len(body)

	msg := make([]byte, total)
	binary.LittleEndian.PutUint32(msg[0:4], uint32(total))
	binary.LittleEndian.PutUint16(msg[4:6], (nfnlSubsysCTNetlink<<8)|ipctnlMsgCTDelete)
	binary.LittleEndian.PutUint16(msg[6:8], syscall.NLM_F_REQUEST|syscall.NLM_F_ACK)
	binary.LittleEndian.PutUint32(msg[8:12], seq)
	binary.LittleEndian.PutUint32(msg[12:16], 0) // pid: kernel fills in
	copy(msg[syscall.NLMSG_HDRLEN:], body)
	return msg, nil
}

// BuildDumpMessage serialises an IPCTNL_MSG_CT_GET request with NLM_F_DUMP,
// which asks the kernel to stream every IPv4 conntrack entry.
func BuildDumpMessage(seq uint32) []byte {
	nfgen := make([]byte, nfgenmsgLen)
	nfgen[0] = syscall.AF_INET
	nfgen[1] = nfnetlinkV0
	binary.BigEndian.PutUint16(nfgen[2:4], 0)

	total := syscall.NLMSG_HDRLEN + len(nfgen)
	msg := make([]byte, total)
	binary.LittleEndian.PutUint32(msg[0:4], uint32(total))
	binary.LittleEndian.PutUint16(msg[4:6], (nfnlSubsysCTNetlink<<8)|ipctnlMsgCTGet)
	binary.LittleEndian.PutUint16(msg[6:8], syscall.NLM_F_REQUEST|syscall.NLM_F_DUMP)
	binary.LittleEndian.PutUint32(msg[8:12], seq)
	binary.LittleEndian.PutUint32(msg[12:16], 0)
	copy(msg[syscall.NLMSG_HDRLEN:], nfgen)
	return msg
}

// conn abstracts the netlink socket so tests can drive the parse and filter
// logic without CAP_NET_ADMIN.
type conn interface {
	Send([]byte) error
	Receive() ([]byte, error)
	Close() error
}

// netlinkConn is the real NETLINK_NETFILTER socket.
type netlinkConn struct {
	fd   int
	addr *syscall.SockaddrNetlink
}

func dialNetfilter() (*netlinkConn, error) {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_NETFILTER)
	if err != nil {
		if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EACCES) {
			return nil, fmt.Errorf("%w: opening NETLINK_NETFILTER socket", ErrPermission)
		}
		return nil, fmt.Errorf("open netlink socket: %w", err)
	}
	addr := &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}
	if err := syscall.Bind(fd, addr); err != nil {
		syscall.Close(fd) // never leak the fd on the error path
		return nil, fmt.Errorf("bind netlink socket: %w", err)
	}
	return &netlinkConn{fd: fd, addr: addr}, nil
}

func (c *netlinkConn) Send(b []byte) error {
	return syscall.Sendto(c.fd, b, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK})
}

func (c *netlinkConn) Receive() ([]byte, error) {
	buf := make([]byte, os.Getpagesize()*4)
	n, _, err := syscall.Recvfrom(c.fd, buf, 0)
	if err != nil {
		return nil, err
	}
	return buf[:n], nil
}

func (c *netlinkConn) Close() error { return syscall.Close(c.fd) }

// parseAttrs walks a flat run of netlink attributes.
func parseAttrs(b []byte) map[uint16][]byte {
	out := make(map[uint16][]byte)
	for len(b) >= 4 {
		alen := int(binary.LittleEndian.Uint16(b[0:2]))
		atyp := binary.LittleEndian.Uint16(b[2:4]) &^ nlaFNested
		if alen < 4 || alen > len(b) {
			break // malformed; stop rather than read out of bounds
		}
		out[atyp] = b[4:alen]
		b = b[nlMsgAlign(alen):]
	}
	return out
}

// parseTuple decodes a CTA_TUPLE_* payload into a ConntrackTuple.
func parseTuple(b []byte) (ConntrackTuple, bool) {
	var t ConntrackTuple
	top := parseAttrs(b)

	ipPayload, ok := top[ctaTupleIP]
	if !ok {
		return t, false
	}
	ipAttrs := parseAttrs(ipPayload)
	src, hasSrc := ipAttrs[ctaIPv4Src]
	dst, hasDst := ipAttrs[ctaIPv4Dst]
	if !hasSrc || !hasDst || len(src) < 4 || len(dst) < 4 {
		return t, false
	}
	t.SrcIP = net.IPv4(src[0], src[1], src[2], src[3])
	t.DstIP = net.IPv4(dst[0], dst[1], dst[2], dst[3])

	if protoPayload, ok := top[ctaTupleProto]; ok {
		pa := parseAttrs(protoPayload)
		if n, ok := pa[ctaProtoNum]; ok && len(n) >= 1 {
			t.Protocol = n[0]
		}
		if sp, ok := pa[ctaProtoSrcPort]; ok && len(sp) >= 2 {
			t.SrcPort = binary.BigEndian.Uint16(sp)
		}
		if dp, ok := pa[ctaProtoDstPort]; ok && len(dp) >= 2 {
			t.DstPort = binary.BigEndian.Uint16(dp)
		}
	}
	return t, true
}

// parseDumpResponse extracts the original tuples from a conntrack dump,
// returning them and whether the dump is complete (NLMSG_DONE seen).
func parseDumpResponse(buf []byte) (tuples []ConntrackTuple, done bool, err error) {
	for len(buf) >= syscall.NLMSG_HDRLEN {
		msgLen := int(binary.LittleEndian.Uint32(buf[0:4]))
		msgType := binary.LittleEndian.Uint16(buf[4:6])
		if msgLen < syscall.NLMSG_HDRLEN || msgLen > len(buf) {
			return tuples, false, fmt.Errorf("conntrack: malformed netlink message length %d (have %d bytes)", msgLen, len(buf))
		}

		switch msgType {
		case syscall.NLMSG_DONE:
			return tuples, true, nil
		case syscall.NLMSG_ERROR:
			if msgLen >= syscall.NLMSG_HDRLEN+4 {
				errno := int32(binary.LittleEndian.Uint32(buf[syscall.NLMSG_HDRLEN : syscall.NLMSG_HDRLEN+4]))
				if errno != 0 {
					return tuples, true, fmt.Errorf("conntrack: netlink error %d (%v)", -errno, syscall.Errno(-errno))
				}
			}
			return tuples, true, nil
		}

		// Body: struct nfgenmsg followed by attributes.
		body := buf[syscall.NLMSG_HDRLEN:msgLen]
		if len(body) > nfgenmsgLen {
			attrs := parseAttrs(body[nfgenmsgLen:])
			if origPayload, ok := attrs[ctaTupleOrig]; ok {
				if t, ok := parseTuple(origPayload); ok {
					tuples = append(tuples, t)
				}
			}
		}
		buf = buf[nlMsgAlign(msgLen):]
	}
	return tuples, false, nil
}

// tupleMatchesIP reports whether either endpoint of the flow is the target.
// Checking both is required: an egress flow carries the container in SrcIP and
// an ingress flow carries it in DstIP. Matching one direction only is the
// asymmetric-routing failure mode, one layer up from the packet path.
func tupleMatchesIP(t ConntrackTuple, target net.IP) bool {
	t4 := target.To4()
	if t4 == nil {
		return false
	}
	return t.SrcIP.To4().Equal(t4) || t.DstIP.To4().Equal(t4)
}

// FlushIP deletes every conntrack entry involving the target IP and returns the
// number deleted.
//
// Never issues a table-wide flush: entries that do not involve the target are
// left strictly untouched (asserted by ISC-91 / ISC-95).
func FlushIP(target net.IP) (int, error) {
	if target == nil || target.To4() == nil {
		return 0, fmt.Errorf("conntrack: FlushIP requires an IPv4 address, got %v", target)
	}
	c, err := dialNetfilter()
	if err != nil {
		return 0, err
	}
	defer c.Close() // fd closed on every path, including the error paths below
	return flushIPOn(c, target)
}

// flushIPOn is the testable core: dump, filter in userspace, delete by exact
// tuple.
func flushIPOn(c conn, target net.IP) (int, error) {
	if err := c.Send(BuildDumpMessage(1)); err != nil {
		return 0, fmt.Errorf("conntrack: send dump request: %w", err)
	}

	var all []ConntrackTuple
	for {
		buf, err := c.Receive()
		if err != nil {
			return 0, fmt.Errorf("conntrack: read dump response: %w", err)
		}
		tuples, done, err := parseDumpResponse(buf)
		if err != nil {
			return 0, err
		}
		all = append(all, tuples...)
		if done {
			break
		}
	}

	var matched []ConntrackTuple
	for _, t := range all {
		if tupleMatchesIP(t, target) {
			matched = append(matched, t)
		}
	}
	if len(matched) == 0 {
		return 0, ErrNoConntrackEntries
	}

	deleted := 0
	var firstErr error
	for i, t := range matched {
		msg, err := BuildDeleteMessage(uint32(i+2), t)
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if err := c.Send(msg); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("conntrack: send delete for %s: %w", t, err)
			}
			continue
		}
		// The kernel ACKs each delete. ENOENT means the entry expired
		// between the dump and the delete, which is the outcome we
		// wanted, so it counts as a success.
		if err := readDeleteAck(c); err != nil && !errors.Is(err, syscall.ENOENT) {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		deleted++
	}
	if deleted == 0 && firstErr != nil {
		return 0, firstErr
	}
	return deleted, nil
}

// readDeleteAck consumes the NLMSG_ERROR ack that follows a delete request.
func readDeleteAck(c conn) error {
	buf, err := c.Receive()
	if err != nil {
		return fmt.Errorf("conntrack: read delete ack: %w", err)
	}
	if len(buf) < syscall.NLMSG_HDRLEN+4 {
		return nil
	}
	msgType := binary.LittleEndian.Uint16(buf[4:6])
	if msgType != syscall.NLMSG_ERROR {
		return nil
	}
	errno := int32(binary.LittleEndian.Uint32(buf[syscall.NLMSG_HDRLEN : syscall.NLMSG_HDRLEN+4]))
	if errno == 0 {
		return nil // ack, not an error
	}
	return syscall.Errno(-errno)
}

// CountIP reports how many conntrack entries currently involve the target IP.
// Used by the BATS suite to assert the table reached zero, and by `status`.
func CountIP(target net.IP) (int, error) {
	c, err := dialNetfilter()
	if err != nil {
		return 0, err
	}
	defer c.Close()
	return countIPOn(c, target)
}

func countIPOn(c conn, target net.IP) (int, error) {
	if err := c.Send(BuildDumpMessage(1)); err != nil {
		return 0, fmt.Errorf("conntrack: send dump request: %w", err)
	}
	count := 0
	for {
		buf, err := c.Receive()
		if err != nil {
			return 0, fmt.Errorf("conntrack: read dump response: %w", err)
		}
		tuples, done, err := parseDumpResponse(buf)
		if err != nil {
			return 0, err
		}
		for _, t := range tuples {
			if tupleMatchesIP(t, target) {
				count++
			}
		}
		if done {
			return count, nil
		}
	}
}

// unused guards against an accidental import removal of unsafe, which is
// referenced only for the compile-time size assertion below.
var _ = unsafe.Sizeof(uint32(0))

// Compile-time assertion that IsolationState matches the C struct layout
// (8 + 8 + 4 + 4 = 24 bytes). If the C struct changes and this does not, every
// counter read silently returns garbage rather than failing loudly.
const _ = 24 - unsafe.Sizeof(IsolationState{})
