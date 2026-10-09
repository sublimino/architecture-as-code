// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

import (
	"encoding/binary"
	"net"
	"testing"
	"unsafe"

	"github.com/cilium/ebpf/btf"
)

func TestDnsEventLayoutMatchesBTF(t *testing.T) {
	// Three statements of the layout exist: the C struct (as the compiler
	// laid it out, recorded in BTF), bpf2go's Go mirror, and the offset
	// constants the decoder uses. All three must agree.
	spec, err := loadMonitor()
	if err != nil {
		t.Fatalf("loadMonitor: %v", err)
	}
	var st *btf.Struct
	if err := spec.Types.TypeByName("dns_event_t", &st); err != nil {
		t.Fatalf("dns_event_t not in BTF: %v", err)
	}
	if st.Size != DNSEventSize {
		t.Fatalf("BTF size %d, decoder assumes %d", st.Size, DNSEventSize)
	}
	if got := unsafe.Sizeof(monitorDnsEventT{}); got != DNSEventSize {
		t.Fatalf("Go mirror size %d, want %d", got, DNSEventSize)
	}
	if got := binary.Size(monitorDnsEventT{}); got != DNSEventSize {
		t.Fatalf("binary.Size %d, want %d", got, DNSEventSize)
	}

	want := map[string]uint32{
		"ts_ns":          offDNSTsNs,
		"ifindex":        offDNSIfindex,
		"qtype":          offDNSQtype,
		"qdcount":        offDNSQdcount,
		"ancount":        offDNSAncount,
		"answers_parsed": offDNSAnswersParsed,
		"rcode":          offDNSRcode,
		"is_response":    offDNSIsResponse,
		"parse_status":   offDNSParseStatus,
		"is_ipv6":        offDNSIsIPv6,
		"resolver_addr":  offDNSResolverAddr,
		"answers":        offDNSAnswers,
		"answer_ttls":    offDNSAnswerTTLs,
		"qname":          offDNSQname,
		"cname":          offDNSCname,
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
	// dns_event_t has 375 bytes of declared members + 1 byte alignment padding before answer_ttls (__u32 alignment)
	if sum != 375 && sum != DNSEventSize {
		t.Errorf("members sum to %d bytes (expected 375 member bytes in %d byte struct)", sum, DNSEventSize)
	}
}

func TestTLSSNIEventLayoutMatchesBTF(t *testing.T) {
	spec, err := loadMonitor()
	if err != nil {
		t.Fatalf("loadMonitor: %v", err)
	}
	var st *btf.Struct
	if err := spec.Types.TypeByName("tls_sni_event_t", &st); err != nil {
		t.Fatalf("tls_sni_event_t not in BTF: %v", err)
	}
	if st.Size != TLSSNIEventSize {
		t.Fatalf("BTF size %d, decoder assumes %d", st.Size, TLSSNIEventSize)
	}
	if got := unsafe.Sizeof(monitorTlsSniEventT{}); got != TLSSNIEventSize {
		t.Fatalf("Go mirror size %d, want %d", got, TLSSNIEventSize)
	}
	if got := binary.Size(monitorTlsSniEventT{}); got != TLSSNIEventSize {
		t.Fatalf("binary.Size %d, want %d", got, TLSSNIEventSize)
	}

	want := map[string]uint32{
		"ts_ns":        offTLSTsNs,
		"ifindex":      offTLSIfindex,
		"dport":        offTLSDport,
		"is_ipv6":      offTLSIsIPv6,
		"parse_status": offTLSParseStatus,
		"daddr":        offTLSDaddr,
		"sni_len":      offTLSSniLen,
		"sni":          offTLSSni,
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
	// tls_sni_event_t has 162 bytes of declared members + 6 bytes tail padding to 8-byte boundary
	if sum != 162 && sum != TLSSNIEventSize {
		t.Errorf("members sum to %d bytes (expected 162 member bytes in %d byte struct)", sum, TLSSNIEventSize)
	}
}

func makeSampleDNSEventRaw() []byte {
	buf := make([]byte, DNSEventSize)
	ne := binary.NativeEndian

	ne.PutUint64(buf[offDNSTsNs:], 123456789)
	ne.PutUint32(buf[offDNSIfindex:], 42)
	ne.PutUint16(buf[offDNSQtype:], 1) // A record
	ne.PutUint16(buf[offDNSQdcount:], 1)
	ne.PutUint16(buf[offDNSAncount:], 2)
	buf[offDNSAnswersParsed] = 2
	buf[offDNSRcode] = 0 // NOERROR
	buf[offDNSIsResponse] = 1
	buf[offDNSParseStatus] = DNS_PARSE_OK
	buf[offDNSIsIPv6] = 0

	// resolver 10.96.0.10
	copy(buf[offDNSResolverAddr:], []byte{10, 96, 0, 10})

	// answer 0: 93.184.216.34, TTL 300
	copy(buf[offDNSAnswers+0*16:], []byte{93, 184, 216, 34})
	ne.PutUint32(buf[offDNSAnswerTTLs+0*4:], 300)

	// answer 1: 93.184.216.35, TTL 300
	copy(buf[offDNSAnswers+1*16:], []byte{93, 184, 216, 35})
	ne.PutUint32(buf[offDNSAnswerTTLs+1*4:], 300)

	// qname "example.com"
	copy(buf[offDNSQname:], "example.com\x00")
	// cname ""
	buf[offDNSCname] = 0

	return buf
}

func makeSampleTLSSNIEventRaw() []byte {
	buf := make([]byte, TLSSNIEventSize)
	ne := binary.NativeEndian

	ne.PutUint64(buf[offTLSTsNs:], 987654321)
	ne.PutUint32(buf[offTLSIfindex:], 42)
	ne.PutUint16(buf[offTLSDport:], 443)
	buf[offTLSIsIPv6] = 0
	buf[offTLSParseStatus] = TLS_CH_OK

	// daddr: 93.184.216.34
	copy(buf[offTLSDaddr:], []byte{93, 184, 216, 34})
	ne.PutUint16(buf[offTLSSniLen:], 11)
	copy(buf[offTLSSni:], "example.com\x00")

	return buf
}

func TestDecodeDNSEvent(t *testing.T) {
	raw := makeSampleDNSEventRaw()
	ev, err := DecodeDNSEvent(raw)
	if err != nil {
		t.Fatalf("DecodeDNSEvent: %v", err)
	}

	if ev.TimestampNs != 123456789 {
		t.Errorf("TimestampNs = %d, want 123456789", ev.TimestampNs)
	}
	if ev.Ifindex != 42 {
		t.Errorf("Ifindex = %d, want 42", ev.Ifindex)
	}
	if ev.Qtype != 1 {
		t.Errorf("Qtype = %d, want 1", ev.Qtype)
	}
	if ev.AnswersParsed != 2 {
		t.Errorf("AnswersParsed = %d, want 2", ev.AnswersParsed)
	}
	if ev.QnameString() != "example.com" {
		t.Errorf("QnameString() = %q, want %q", ev.QnameString(), "example.com")
	}
	if ev.CnameString() != "" {
		t.Errorf("CnameString() = %q, want empty", ev.CnameString())
	}

	resIP := ev.ResolverIP()
	if !resIP.Equal(net.IPv4(10, 96, 0, 10)) {
		t.Errorf("ResolverIP = %v, want 10.96.0.10", resIP)
	}

	ans0 := ev.AnswerIP(0)
	if !ans0.Equal(net.IPv4(93, 184, 216, 34)) {
		t.Errorf("AnswerIP(0) = %v, want 93.184.216.34", ans0)
	}
	if ev.AnswerTTLs[0] != 300 {
		t.Errorf("AnswerTTLs[0] = %d, want 300", ev.AnswerTTLs[0])
	}

	ans1 := ev.AnswerIP(1)
	if !ans1.Equal(net.IPv4(93, 184, 216, 35)) {
		t.Errorf("AnswerIP(1) = %v, want 93.184.216.35", ans1)
	}

	// Slot 2 should not be decoded
	ans2 := ev.AnswerIP(2)
	if ans2 != nil {
		t.Errorf("AnswerIP(2) = %v, want nil (only 2 answers parsed)", ans2)
	}
}

func TestDecodeTLSSNIEvent(t *testing.T) {
	raw := makeSampleTLSSNIEventRaw()
	ev, err := DecodeTLSSNIEvent(raw)
	if err != nil {
		t.Fatalf("DecodeTLSSNIEvent: %v", err)
	}

	if ev.TimestampNs != 987654321 {
		t.Errorf("TimestampNs = %d, want 987654321", ev.TimestampNs)
	}
	if ev.Ifindex != 42 {
		t.Errorf("Ifindex = %d, want 42", ev.Ifindex)
	}
	if ev.DestPort != 443 {
		t.Errorf("DestPort = %d, want 443", ev.DestPort)
	}
	if ev.ParseStatus != TLS_CH_OK {
		t.Errorf("ParseStatus = %d, want %d", ev.ParseStatus, TLS_CH_OK)
	}
	if ev.SNIString() != "example.com" {
		t.Errorf("SNIString() = %q, want %q", ev.SNIString(), "example.com")
	}

	dstIP := ev.DestIP()
	if !dstIP.Equal(net.IPv4(93, 184, 216, 34)) {
		t.Errorf("DestIP = %v, want 93.184.216.34", dstIP)
	}
}

func TestDecodeTooShort(t *testing.T) {
	if _, err := DecodeDNSEvent(make([]byte, DNSEventSize-1)); err == nil {
		t.Error("DecodeDNSEvent on short buffer succeeded, want error")
	}
	if _, err := DecodeTLSSNIEvent(make([]byte, TLSSNIEventSize-1)); err == nil {
		t.Error("DecodeTLSSNIEvent on short buffer succeeded, want error")
	}
}

func TestDecodeZeroAllocs(t *testing.T) {
	dnsRaw := makeSampleDNSEventRaw()
	tlsRaw := makeSampleTLSSNIEventRaw()

	var dnsEv DNSEvent
	dnsAllocs := testing.AllocsPerRun(1000, func() {
		_ = DecodeDNSEventZeroAlloc(dnsRaw, &dnsEv)
	})
	if dnsAllocs != 0 {
		t.Errorf("DecodeDNSEventZeroAlloc allocs = %v, want 0", dnsAllocs)
	}

	var tlsEv TLSSNIEvent
	tlsAllocs := testing.AllocsPerRun(1000, func() {
		_ = DecodeTLSSNIEventZeroAlloc(tlsRaw, &tlsEv)
	})
	if tlsAllocs != 0 {
		t.Errorf("DecodeTLSSNIEventZeroAlloc allocs = %v, want 0", tlsAllocs)
	}
}

func BenchmarkDecodeDNSEvent(b *testing.B) {
	raw := makeSampleDNSEventRaw()
	var ev DNSEvent
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := DecodeDNSEventZeroAlloc(raw, &ev); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkDecodeTLSSNIEvent(b *testing.B) {
	raw := makeSampleTLSSNIEventRaw()
	var ev TLSSNIEvent
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := DecodeTLSSNIEventZeroAlloc(raw, &ev); err != nil {
			b.Fatal(err)
		}
	}
}
