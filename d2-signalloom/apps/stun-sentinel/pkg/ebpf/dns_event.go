// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"encoding/binary"
	"fmt"
	"net"
)

// Wire layout of struct dns_event_t and struct tls_sni_event_t.
// Matches bpf/dns_event.h and verified by TestDnsEventLayoutMatchesBTF / TestTLSSNIEventLayoutMatchesBTF.
const (
	DNSEventSize    = 376
	TLSSNIEventSize = 168

	DNSMaxAnswers = 4
	DNSMaxNameLen = 128

	// dns_event_t field offsets
	offDNSTsNs          = 0
	offDNSIfindex       = 8
	offDNSQtype         = 12
	offDNSQdcount       = 14
	offDNSAncount       = 16
	offDNSAnswersParsed = 18
	offDNSRcode         = 19
	offDNSIsResponse    = 20
	offDNSParseStatus   = 21
	offDNSIsIPv6        = 22
	offDNSResolverAddr  = 23
	offDNSAnswers       = 39
	offDNSAnswerTTLs    = 104
	offDNSQname         = 120
	offDNSCname         = 248

	// tls_sni_event_t field offsets
	offTLSTsNs        = 0
	offTLSIfindex     = 8
	offTLSDport       = 12
	offTLSIsIPv6      = 14
	offTLSParseStatus = 15
	offTLSDaddr       = 16
	offTLSSniLen      = 32
	offTLSSni         = 34

	resolverAddrLen = 16
	answerAddrLen   = 16
	dnsNameLen      = 128
	tlsDaddrLen     = 16
	tlsSniLen       = 128
)

// DNS parse outcome constants matching bpf/dns_event.h
const (
	DNS_PARSE_OK            uint8 = 0
	DNS_PARSE_TRUNCATED     uint8 = 1 // hit data_end mid-record
	DNS_PARSE_NAME_TOO_LONG uint8 = 2 // qname exceeded DNS_MAX_NAME_LEN
	DNS_PARSE_COMPRESSED    uint8 = 3 // pointer compression beyond our depth
	DNS_PARSE_UNSUPPORTED   uint8 = 4 // opcode/class we do not decode
)

// TLS ClientHello parse outcome constants matching bpf/dns_event.h
const (
	TLS_CH_OK        uint8 = 0
	TLS_CH_SEGMENTED uint8 = 1 // ClientHello spans TCP segments
	TLS_CH_NO_SNI    uint8 = 2 // no SNI extension present
	TLS_CH_ENCRYPTED uint8 = 3 // ECH: outer SNI only, inner unreadable
	TLS_CH_MALFORMED uint8 = 4
)

// Named Prometheus-style metric identifiers for parse outcomes and ringbuffer drops.
const (
	MetricDNSParseOK          = "stun_dns_parse_ok_total"            // DNS_PARSE_OK
	MetricDNSParseTruncated   = "stun_dns_parse_truncated_total"     // DNS_PARSE_TRUNCATED
	MetricDNSParseNameTooLong = "stun_dns_parse_name_too_long_total" // DNS_PARSE_NAME_TOO_LONG
	MetricDNSParseCompressed  = "stun_dns_parse_compressed_total"    // DNS_PARSE_COMPRESSED
	MetricDNSParseUnsupported = "stun_dns_parse_unsupported_total"   // DNS_PARSE_UNSUPPORTED

	MetricTLSCHOK        = "stun_tls_ch_ok_total"        // TLS_CH_OK
	MetricTLSCHSegmented = "stun_tls_ch_segmented_total" // TLS_CH_SEGMENTED
	MetricTLSCHNoSNI     = "stun_tls_ch_no_sni_total"    // TLS_CH_NO_SNI
	MetricTLSCHEncrypted = "stun_tls_ch_encrypted_total" // TLS_CH_ENCRYPTED
	MetricTLSCHMalformed = "stun_tls_ch_malformed_total" // TLS_CH_MALFORMED

	MetricDNSEventsDropped = "stun_dns_events_dropped_total"
	MetricTLSEventsDropped = "stun_tls_events_dropped_total"
)

// Named counter identifiers for internal stats tracking.
const (
	CounterDNSParseOK          = "dns_parse_ok"            // DNS_PARSE_OK
	CounterDNSParseTruncated   = "dns_parse_truncated"     // DNS_PARSE_TRUNCATED
	CounterDNSParseNameTooLong = "dns_parse_name_too_long" // DNS_PARSE_NAME_TOO_LONG
	CounterDNSParseCompressed  = "dns_parse_compressed"    // DNS_PARSE_COMPRESSED
	CounterDNSParseUnsupported = "dns_parse_unsupported"   // DNS_PARSE_UNSUPPORTED

	CounterTLSCHOK        = "tls_ch_ok"        // TLS_CH_OK
	CounterTLSCHSegmented = "tls_ch_segmented" // TLS_CH_SEGMENTED
	CounterTLSCHNoSNI     = "tls_ch_no_sni"    // TLS_CH_NO_SNI
	CounterTLSCHEncrypted = "tls_ch_encrypted" // TLS_CH_ENCRYPTED
	CounterTLSCHMalformed = "tls_ch_malformed" // TLS_CH_MALFORMED

	CounterDNSEventsDropped = "dns_events_dropped"
	CounterTLSEventsDropped = "tls_events_dropped"
)

// DNSParseStatusName returns a human-readable name for a DNS parse_status code.
func DNSParseStatusName(status uint8) string {
	switch status {
	case DNS_PARSE_OK:
		return "DNS_PARSE_OK"
	case DNS_PARSE_TRUNCATED:
		return "DNS_PARSE_TRUNCATED"
	case DNS_PARSE_NAME_TOO_LONG:
		return "DNS_PARSE_NAME_TOO_LONG"
	case DNS_PARSE_COMPRESSED:
		return "DNS_PARSE_COMPRESSED"
	case DNS_PARSE_UNSUPPORTED:
		return "DNS_PARSE_UNSUPPORTED"
	default:
		return fmt.Sprintf("DNS_PARSE_UNKNOWN(%d)", status)
	}
}

// TLSCHStatusName returns a human-readable name for a TLS ClientHello parse_status code.
func TLSCHStatusName(status uint8) string {
	switch status {
	case TLS_CH_OK:
		return "TLS_CH_OK"
	case TLS_CH_SEGMENTED:
		return "TLS_CH_SEGMENTED"
	case TLS_CH_NO_SNI:
		return "TLS_CH_NO_SNI"
	case TLS_CH_ENCRYPTED:
		return "TLS_CH_ENCRYPTED"
	case TLS_CH_MALFORMED:
		return "TLS_CH_MALFORMED"
	default:
		return fmt.Sprintf("TLS_CH_UNKNOWN(%d)", status)
	}
}

// DNSEvent is the decoded userspace representation of a DNS ringbuffer event.
// Uses pre-sized fixed arrays to guarantee zero heap allocations on decode.
type DNSEvent struct {
	TimestampNs   uint64                  `json:"timestamp_ns"`
	Ifindex       uint32                  `json:"ifindex"`
	Qtype         uint16                  `json:"qtype"`
	Qdcount       uint16                  `json:"qdcount"`
	Ancount       uint16                  `json:"ancount"`
	AnswersParsed uint8                   `json:"answers_parsed"`
	Rcode         uint8                   `json:"rcode"`
	IsResponse    uint8                   `json:"is_response"`
	ParseStatus   uint8                   `json:"parse_status"`
	IsIPv6        uint8                   `json:"is_ipv6"`
	ResolverAddr  [16]byte                `json:"resolver_addr"`
	Answers       [DNSMaxAnswers][16]byte `json:"answers"`
	AnswerTTLs    [DNSMaxAnswers]uint32   `json:"answer_ttls"`
	QnameBytes    [DNSMaxNameLen]byte     `json:"-"`
	CnameBytes    [DNSMaxNameLen]byte     `json:"-"`
	Qname         string                  `json:"qname,omitempty"`
	Cname         string                  `json:"cname,omitempty"`
}

// QnameString returns the NUL-terminated Qname string using cString.
func (e *DNSEvent) QnameString() string {
	if e.Qname != "" {
		return e.Qname
	}
	return cString(e.QnameBytes[:])
}

// CnameString returns the NUL-terminated Cname string using cString.
func (e *DNSEvent) CnameString() string {
	if e.Cname != "" {
		return e.Cname
	}
	return cString(e.CnameBytes[:])
}

// ResolverIP returns the resolver address formatted as net.IP using is_ipv6-branched construction.
func (e *DNSEvent) ResolverIP() net.IP {
	if e.IsIPv6 != 0 {
		ip := make(net.IP, net.IPv6len)
		copy(ip, e.ResolverAddr[:])
		return ip
	}
	return net.IPv4(e.ResolverAddr[0], e.ResolverAddr[1], e.ResolverAddr[2], e.ResolverAddr[3])
}

// AnswerIP returns the i-th decoded answer IP, or nil if i >= AnswersParsed or invalid.
func (e *DNSEvent) AnswerIP(i int) net.IP {
	if i < 0 || i >= int(e.AnswersParsed) || i >= DNSMaxAnswers {
		return nil
	}
	if e.IsIPv6 != 0 {
		ip := make(net.IP, net.IPv6len)
		copy(ip, e.Answers[i][:])
		return ip
	}
	return net.IPv4(e.Answers[i][0], e.Answers[i][1], e.Answers[i][2], e.Answers[i][3])
}

// TLSSNIEvent is the decoded userspace representation of a TLS ClientHello SNI event.
type TLSSNIEvent struct {
	TimestampNs uint64              `json:"timestamp_ns"`
	Ifindex     uint32              `json:"ifindex"`
	DestPort    uint16              `json:"dest_port"`
	IsIPv6      uint8               `json:"is_ipv6"`
	ParseStatus uint8               `json:"parse_status"`
	DestAddr    [16]byte            `json:"dest_addr"`
	SNILen      uint16              `json:"sni_len"`
	SNIBytes    [DNSMaxNameLen]byte `json:"-"`
	SNI         string              `json:"sni,omitempty"`
}

// SNIString returns the NUL-terminated SNI string using cString.
func (e *TLSSNIEvent) SNIString() string {
	if e.SNI != "" {
		return e.SNI
	}
	return cString(e.SNIBytes[:])
}

// DestIP returns the destination address formatted as net.IP using is_ipv6-branched construction.
func (e *TLSSNIEvent) DestIP() net.IP {
	if e.IsIPv6 != 0 {
		ip := make(net.IP, net.IPv6len)
		copy(ip, e.DestAddr[:])
		return ip
	}
	return net.IPv4(e.DestAddr[0], e.DestAddr[1], e.DestAddr[2], e.DestAddr[3])
}

// DecodeDNSEventInto decodes one raw ringbuffer record into a caller-supplied DNSEvent struct.
// It executes with zero heap allocations on the hot path.
func DecodeDNSEventInto(raw []byte, ev *DNSEvent) error {
	if len(raw) < DNSEventSize {
		return fmt.Errorf("dns event too short: %d bytes (want %d)", len(raw), DNSEventSize)
	}
	ne := binary.NativeEndian

	ev.TimestampNs = ne.Uint64(raw[offDNSTsNs:])
	ev.Ifindex = ne.Uint32(raw[offDNSIfindex:])
	ev.Qtype = ne.Uint16(raw[offDNSQtype:])
	ev.Qdcount = ne.Uint16(raw[offDNSQdcount:])
	ev.Ancount = ne.Uint16(raw[offDNSAncount:])
	ev.AnswersParsed = raw[offDNSAnswersParsed]
	ev.Rcode = raw[offDNSRcode]
	ev.IsResponse = raw[offDNSIsResponse]
	ev.ParseStatus = raw[offDNSParseStatus]
	ev.IsIPv6 = raw[offDNSIsIPv6]
	copy(ev.ResolverAddr[:], raw[offDNSResolverAddr:offDNSResolverAddr+resolverAddrLen])

	// Zero out answer slots
	ev.Answers = [DNSMaxAnswers][16]byte{}
	ev.AnswerTTLs = [DNSMaxAnswers]uint32{}

	// Walk exactly answers_parsed entries (never more than DNSMaxAnswers)
	n := int(ev.AnswersParsed)
	if n > DNSMaxAnswers {
		n = DNSMaxAnswers
	}
	for i := 0; i < n; i++ {
		offA := offDNSAnswers + i*answerAddrLen
		copy(ev.Answers[i][:], raw[offA:offA+answerAddrLen])
		offT := offDNSAnswerTTLs + i*4
		ev.AnswerTTLs[i] = ne.Uint32(raw[offT : offT+4])
	}

	copy(ev.QnameBytes[:], raw[offDNSQname:offDNSQname+dnsNameLen])
	copy(ev.CnameBytes[:], raw[offDNSCname:offDNSCname+dnsNameLen])
	ev.Qname = cString(raw[offDNSQname : offDNSQname+dnsNameLen])
	ev.Cname = cString(raw[offDNSCname : offDNSCname+dnsNameLen])

	return nil
}

// DecodeDNSEventZeroAlloc decodes one raw ringbuffer record into a caller-supplied DNSEvent
// without string conversions for true zero-allocation packet processing pipelines.
func DecodeDNSEventZeroAlloc(raw []byte, ev *DNSEvent) error {
	if len(raw) < DNSEventSize {
		return fmt.Errorf("dns event too short: %d bytes (want %d)", len(raw), DNSEventSize)
	}
	ne := binary.NativeEndian

	ev.TimestampNs = ne.Uint64(raw[offDNSTsNs:])
	ev.Ifindex = ne.Uint32(raw[offDNSIfindex:])
	ev.Qtype = ne.Uint16(raw[offDNSQtype:])
	ev.Qdcount = ne.Uint16(raw[offDNSQdcount:])
	ev.Ancount = ne.Uint16(raw[offDNSAncount:])
	ev.AnswersParsed = raw[offDNSAnswersParsed]
	ev.Rcode = raw[offDNSRcode]
	ev.IsResponse = raw[offDNSIsResponse]
	ev.ParseStatus = raw[offDNSParseStatus]
	ev.IsIPv6 = raw[offDNSIsIPv6]
	copy(ev.ResolverAddr[:], raw[offDNSResolverAddr:offDNSResolverAddr+resolverAddrLen])

	ev.Answers = [DNSMaxAnswers][16]byte{}
	ev.AnswerTTLs = [DNSMaxAnswers]uint32{}

	n := int(ev.AnswersParsed)
	if n > DNSMaxAnswers {
		n = DNSMaxAnswers
	}
	for i := 0; i < n; i++ {
		offA := offDNSAnswers + i*answerAddrLen
		copy(ev.Answers[i][:], raw[offA:offA+answerAddrLen])
		offT := offDNSAnswerTTLs + i*4
		ev.AnswerTTLs[i] = ne.Uint32(raw[offT : offT+4])
	}

	copy(ev.QnameBytes[:], raw[offDNSQname:offDNSQname+dnsNameLen])
	copy(ev.CnameBytes[:], raw[offDNSCname:offDNSCname+dnsNameLen])
	ev.Qname = ""
	ev.Cname = ""

	return nil
}

// DecodeDNSEvent decodes one raw ringbuffer record.
func DecodeDNSEvent(raw []byte) (*DNSEvent, error) {
	if len(raw) < DNSEventSize {
		return nil, fmt.Errorf("dns event too short: %d bytes (want %d)", len(raw), DNSEventSize)
	}
	ne := binary.NativeEndian

	ev := &DNSEvent{
		TimestampNs:   ne.Uint64(raw[offDNSTsNs:]),
		Ifindex:       ne.Uint32(raw[offDNSIfindex:]),
		Qtype:         ne.Uint16(raw[offDNSQtype:]),
		Qdcount:       ne.Uint16(raw[offDNSQdcount:]),
		Ancount:       ne.Uint16(raw[offDNSAncount:]),
		AnswersParsed: raw[offDNSAnswersParsed],
		Rcode:         raw[offDNSRcode],
		IsResponse:    raw[offDNSIsResponse],
		ParseStatus:   raw[offDNSParseStatus],
		IsIPv6:        raw[offDNSIsIPv6],
		Qname:         cString(raw[offDNSQname : offDNSQname+dnsNameLen]),
		Cname:         cString(raw[offDNSCname : offDNSCname+dnsNameLen]),
	}
	copy(ev.ResolverAddr[:], raw[offDNSResolverAddr:offDNSResolverAddr+resolverAddrLen])
	copy(ev.QnameBytes[:], raw[offDNSQname:offDNSQname+dnsNameLen])
	copy(ev.CnameBytes[:], raw[offDNSCname:offDNSCname+dnsNameLen])

	n := int(ev.AnswersParsed)
	if n > DNSMaxAnswers {
		n = DNSMaxAnswers
	}
	for i := 0; i < n; i++ {
		offA := offDNSAnswers + i*answerAddrLen
		copy(ev.Answers[i][:], raw[offA:offA+answerAddrLen])
		offT := offDNSAnswerTTLs + i*4
		ev.AnswerTTLs[i] = ne.Uint32(raw[offT : offT+4])
	}

	return ev, nil
}

// DecodeTLSSNIEventInto decodes one raw ringbuffer record into a caller-supplied TLSSNIEvent struct.
func DecodeTLSSNIEventInto(raw []byte, ev *TLSSNIEvent) error {
	if len(raw) < TLSSNIEventSize {
		return fmt.Errorf("tls sni event too short: %d bytes (want %d)", len(raw), TLSSNIEventSize)
	}
	ne := binary.NativeEndian

	ev.TimestampNs = ne.Uint64(raw[offTLSTsNs:])
	ev.Ifindex = ne.Uint32(raw[offTLSIfindex:])
	ev.DestPort = ne.Uint16(raw[offTLSDport:])
	ev.IsIPv6 = raw[offTLSIsIPv6]
	ev.ParseStatus = raw[offTLSParseStatus]
	copy(ev.DestAddr[:], raw[offTLSDaddr:offTLSDaddr+tlsDaddrLen])
	ev.SNILen = ne.Uint16(raw[offTLSSniLen:])
	copy(ev.SNIBytes[:], raw[offTLSSni:offTLSSni+tlsSniLen])
	ev.SNI = cString(raw[offTLSSni : offTLSSni+tlsSniLen])

	return nil
}

// DecodeTLSSNIEventZeroAlloc decodes one raw ringbuffer record into a caller-supplied TLSSNIEvent
// without string conversions for true zero-allocation packet processing pipelines.
func DecodeTLSSNIEventZeroAlloc(raw []byte, ev *TLSSNIEvent) error {
	if len(raw) < TLSSNIEventSize {
		return fmt.Errorf("tls sni event too short: %d bytes (want %d)", len(raw), TLSSNIEventSize)
	}
	ne := binary.NativeEndian

	ev.TimestampNs = ne.Uint64(raw[offTLSTsNs:])
	ev.Ifindex = ne.Uint32(raw[offTLSIfindex:])
	ev.DestPort = ne.Uint16(raw[offTLSDport:])
	ev.IsIPv6 = raw[offTLSIsIPv6]
	ev.ParseStatus = raw[offTLSParseStatus]
	copy(ev.DestAddr[:], raw[offTLSDaddr:offTLSDaddr+tlsDaddrLen])
	ev.SNILen = ne.Uint16(raw[offTLSSniLen:])
	copy(ev.SNIBytes[:], raw[offTLSSni:offTLSSni+tlsSniLen])
	ev.SNI = ""

	return nil
}

// DecodeTLSSNIEvent decodes one raw ringbuffer record.
func DecodeTLSSNIEvent(raw []byte) (*TLSSNIEvent, error) {
	if len(raw) < TLSSNIEventSize {
		return nil, fmt.Errorf("tls sni event too short: %d bytes (want %d)", len(raw), TLSSNIEventSize)
	}
	ne := binary.NativeEndian

	ev := &TLSSNIEvent{
		TimestampNs: ne.Uint64(raw[offTLSTsNs:]),
		Ifindex:     ne.Uint32(raw[offTLSIfindex:]),
		DestPort:    ne.Uint16(raw[offTLSDport:]),
		IsIPv6:      raw[offTLSIsIPv6],
		ParseStatus: raw[offTLSParseStatus],
		SNILen:      ne.Uint16(raw[offTLSSniLen:]),
		SNI:         cString(raw[offTLSSni : offTLSSni+tlsSniLen]),
	}
	copy(ev.DestAddr[:], raw[offTLSDaddr:offTLSDaddr+tlsDaddrLen])
	copy(ev.SNIBytes[:], raw[offTLSSni:offTLSSni+tlsSniLen])

	return ev, nil
}
