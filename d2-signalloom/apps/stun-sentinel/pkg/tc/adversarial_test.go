// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"errors"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/ringbuf"
	"github.com/cilium/ebpf/rlimit"
	ebpfPkg "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
)

func loadMonitorCollection(t *testing.T) (*ebpf.Collection, *ebpf.Program) {
	t.Helper()
	_ = rlimit.RemoveMemlock()
	spec, err := loadMonitorCollectionSpec()
	if err != nil {
		t.Fatalf("loadMonitorCollectionSpec: %v", err)
	}

	opts := ebpf.CollectionOptions{
		Programs: ebpf.ProgramOptions{
			LogLevel: ebpf.LogLevelStats,
		},
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, opts)
	if err != nil {
		var ve *ebpf.VerifierError
		if errors.As(err, &ve) {
			t.Fatalf("BPF verifier rejected tc_monitor:\n%+v", ve)
		}
		if errors.Is(err, os.ErrPermission) || strings.Contains(err.Error(), "operation not permitted") {
			t.Skipf("skipping live kernel packet test (unprivileged): %v", err)
			return nil, nil
		}
		t.Fatalf("NewCollectionWithOptions: %v", err)
	}

	prog := coll.Programs["stun_tc_monitor"]
	if prog == nil {
		coll.Close()
		t.Fatal("program stun_tc_monitor not found in collection")
	}

	return coll, prog
}

// readNextRecordWithTimeout reads the next record from the ringbuffer with a deadline to prevent hanging.
func readNextRecordWithTimeout(t *testing.T, rd *ringbuf.Reader) *ringbuf.Record {
	t.Helper()
	rd.SetDeadline(time.Now().Add(500 * time.Millisecond))
	rec, err := rd.Read()
	if err != nil {
		t.Fatalf("ringbuf.Read timed out or failed: %v", err)
		return nil
	}
	return &rec
}

// readParseStatusStats reads all 16 entries of the per-CPU parse_status_stats map.
func readParseStatusStats(t *testing.T, m *ebpf.Map) [16]uint64 {
	t.Helper()
	var totals [16]uint64
	for k := uint32(0); k < 16; k++ {
		var values []uint64
		if err := m.Lookup(k, &values); err == nil {
			var sum uint64
			for _, v := range values {
				sum += v
			}
			totals[k] = sum
		}
	}
	return totals
}

// TestAdversarialDNSOverDeclaredAncount tests DNS responses declaring more answers than carried.
func TestAdversarialDNSOverDeclaredAncount(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["dns_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	// Case 1: Declared ancount = 10, but only 1 answer carried
	t.Run("Ancount10_Carried1", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		answers := []AdversarialDNSAnswerSpec{
			{Type: 1, TTL: 300, IP: net.IPv4(93, 184, 216, 34)},
		}
		frame := BuildOverDeclaredAncountDNSResponse(0x1001, "overdeclared-1.example.com", 10, answers)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.Ancount != 10 {
			t.Errorf("event.Ancount = %d, want declared 10", event.Ancount)
		}
		if event.AnswersParsed != 1 {
			t.Errorf("event.AnswersParsed = %d, want parsed 1", event.AnswersParsed)
		}
		if event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want DNS_PARSE_TRUNCATED (%d)", event.ParseStatus, ebpfPkg.DNS_PARSE_TRUNCATED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		deltaTruncated := statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED] - statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED]
		if deltaTruncated != 1 {
			t.Errorf("deltaTruncated = %d, want 1", deltaTruncated)
		}
	})

	// Case 2: Declared ancount = 100, carried 0 answers (truncated immediately at answer section)
	t.Run("Ancount100_Carried0", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		frame := BuildOverDeclaredAncountDNSResponse(0x1002, "overdeclared-0.example.com", 100, nil)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.Ancount != 100 {
			t.Errorf("event.Ancount = %d, want declared 100", event.Ancount)
		}
		if event.AnswersParsed != 0 {
			t.Errorf("event.AnswersParsed = %d, want parsed 0", event.AnswersParsed)
		}
		if event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want DNS_PARSE_TRUNCATED (%d)", event.ParseStatus, ebpfPkg.DNS_PARSE_TRUNCATED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		deltaTruncated := statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED] - statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED]
		if deltaTruncated != 1 {
			t.Errorf("deltaTruncated = %d, want 1", deltaTruncated)
		}
	})
}

// TestAdversarialDNSNameCompressionFuzzing tests pointer compression evasion vectors.
func TestAdversarialDNSNameCompressionFuzzing(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["dns_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	// Vector 1: Forward pointer (target offset 0x40 beyond short packet)
	t.Run("ForwardPointer", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)
		frame := BuildForwardPointerDNSQuery(0x2001, 0x0040)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.DNS_PARSE_COMPRESSED && event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want COMPRESSED (%d) or TRUNCATED (%d)",
				event.ParseStatus, ebpfPkg.DNS_PARSE_COMPRESSED, ebpfPkg.DNS_PARSE_TRUNCATED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		delta := (statsAfter[ebpfPkg.DNS_PARSE_COMPRESSED] + statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED]) -
			(statsBefore[ebpfPkg.DNS_PARSE_COMPRESSED] + statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED])
		if delta != 1 {
			t.Errorf("delta counted parse status = %d, want 1", delta)
		}
	})

	// Vector 2: Self-referential / cyclic pointer (offset 12 points to offset 12)
	t.Run("SelfReferentialPointer", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)
		frame := BuildSelfReferentialPointerDNSQuery(0x2002)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.DNS_PARSE_COMPRESSED && event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want COMPRESSED (%d) or TRUNCATED (%d)",
				event.ParseStatus, ebpfPkg.DNS_PARSE_COMPRESSED, ebpfPkg.DNS_PARSE_TRUNCATED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		delta := (statsAfter[ebpfPkg.DNS_PARSE_COMPRESSED] + statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED]) -
			(statsBefore[ebpfPkg.DNS_PARSE_COMPRESSED] + statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED])
		if delta != 1 {
			t.Errorf("delta counted status = %d, want 1", delta)
		}
	})

	// Vector 3: Deep chained pointer (chain of 5 pointers)
	t.Run("DeepPointerChain", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)
		frame := BuildDeepPointerChainDNSQuery(0x2003, 5)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.DNS_PARSE_COMPRESSED && event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want COMPRESSED or TRUNCATED", event.ParseStatus)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		delta := (statsAfter[ebpfPkg.DNS_PARSE_COMPRESSED] + statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED]) -
			(statsBefore[ebpfPkg.DNS_PARSE_COMPRESSED] + statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED])
		if delta != 1 {
			t.Errorf("delta counted status = %d, want 1", delta)
		}
	})
}

// TestAdversarialMTUFragmentedDatagrams tests behavior under packet fragmentation.
func TestAdversarialMTUFragmentedDatagrams(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["dns_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	// Vector 1: Truncated UDP DNS frame (only 4 bytes of DNS header present)
	t.Run("TruncatedDNSHeader", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		shortDNS := []byte{0x30, 0x01, 0x01, 0x00} // only 4 bytes, dnshdr is 12 bytes
		frame := BuildEthIPv4UDPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, shortDNS)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want DNS_PARSE_TRUNCATED (%d)", event.ParseStatus, ebpfPkg.DNS_PARSE_TRUNCATED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		deltaTruncated := statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED] - statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED]
		if deltaTruncated != 1 {
			t.Errorf("deltaTruncated = %d, want 1", deltaTruncated)
		}
	})

	// Vector 2: DNS Query truncated midway through domain name
	t.Run("TruncatedQName", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		dnsPayload := BuildDNSQueryPayload(0x3002, "fragmented-mid-name.example.com", 1)
		// Truncate halfway through QNAME
		if len(dnsPayload) > 20 {
			dnsPayload = dnsPayload[:20]
		}
		frame := BuildEthIPv4UDPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, dnsPayload)

		ret, _, err := prog.Test(frame)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.DNS_PARSE_TRUNCATED {
			t.Errorf("event.ParseStatus = %d, want DNS_PARSE_TRUNCATED", event.ParseStatus)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		deltaTruncated := statsAfter[ebpfPkg.DNS_PARSE_TRUNCATED] - statsBefore[ebpfPkg.DNS_PARSE_TRUNCATED]
		if deltaTruncated != 1 {
			t.Errorf("deltaTruncated = %d, want 1", deltaTruncated)
		}
	})
}

// TestAdversarialSegmentedClientHello tests TCP segment boundary handling.
func TestAdversarialSegmentedClientHello(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["tls_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	// Vector 1: ClientHello split across 2 TCP segments (segment 1 has first 20 bytes)
	t.Run("SplitAt20Bytes", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		seg1, _ := BuildSegmentedTLSClientHello("segmented.example.com", false, 20)

		ret, _, err := prog.Test(seg1)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeTLSSNIEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.TLS_CH_SEGMENTED {
			t.Errorf("event.ParseStatus = %d, want TLS_CH_SEGMENTED (%d)", event.ParseStatus, ebpfPkg.TLS_CH_SEGMENTED)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		// TLS_CH_SEGMENTED is mapped at index 8 + 1 = 9
		deltaSegmented := statsAfter[8+ebpfPkg.TLS_CH_SEGMENTED] - statsBefore[8+ebpfPkg.TLS_CH_SEGMENTED]
		if deltaSegmented != 1 {
			t.Errorf("deltaSegmented = %d, want 1", deltaSegmented)
		}
	})

	// Vector 2: ClientHello split mid-extension header
	t.Run("SplitMidExtension", func(t *testing.T) {
		statsBefore := readParseStatusStats(t, statsMap)

		// Full ClientHello is approx 80 bytes; split at 45 (mid extensions)
		seg1, _ := BuildSegmentedTLSClientHello("extended.example.com", false, 45)

		ret, _, err := prog.Test(seg1)
		if err != nil {
			t.Fatalf("prog.Test: %v", err)
		}
		if ret != 0 {
			t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
		}

		rec := readNextRecordWithTimeout(t, rd)
		event, err := ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeTLSSNIEvent: %v", err)
		}

		if event.ParseStatus != ebpfPkg.TLS_CH_SEGMENTED && event.ParseStatus != ebpfPkg.TLS_CH_NO_SNI {
			t.Errorf("event.ParseStatus = %d, want TLS_CH_SEGMENTED or TLS_CH_NO_SNI", event.ParseStatus)
		}

		statsAfter := readParseStatusStats(t, statsMap)
		delta := (statsAfter[8+ebpfPkg.TLS_CH_SEGMENTED] + statsAfter[8+ebpfPkg.TLS_CH_NO_SNI]) -
			(statsBefore[8+ebpfPkg.TLS_CH_SEGMENTED] + statsBefore[8+ebpfPkg.TLS_CH_NO_SNI])
		if delta != 1 {
			t.Errorf("delta status = %d, want 1", delta)
		}
	})
}

// TestAdversarialECHClientHello tests Encrypted Client Hello outer SNI handling.
func TestAdversarialECHClientHello(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["tls_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	statsBefore := readParseStatusStats(t, statsMap)

	// ECH outer ClientHello carrying extension 0xfe0d and outer SNI "cloudflare-ech.com"
	rawECH := BuildTLSClientHelloRaw("cloudflare-ech.com", true)
	frame := BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(104, 16, 132, 229), 43210, 443, rawECH)

	ret, _, err := prog.Test(frame)
	if err != nil {
		t.Fatalf("prog.Test: %v", err)
	}
	if ret != 0 {
		t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
	}

	rec := readNextRecordWithTimeout(t, rd)
	event, err := ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
	if err != nil {
		t.Fatalf("DecodeTLSSNIEvent: %v", err)
	}

	if event.ParseStatus != ebpfPkg.TLS_CH_ENCRYPTED {
		t.Errorf("event.ParseStatus = %d, want TLS_CH_ENCRYPTED (%d)", event.ParseStatus, ebpfPkg.TLS_CH_ENCRYPTED)
	}

	statsAfter := readParseStatusStats(t, statsMap)
	// TLS_CH_ENCRYPTED is mapped at index 8 + 3 = 11
	deltaECH := statsAfter[8+ebpfPkg.TLS_CH_ENCRYPTED] - statsBefore[8+ebpfPkg.TLS_CH_ENCRYPTED]
	if deltaECH != 1 {
		t.Errorf("deltaECH = %d, want 1", deltaECH)
	}
}

// TestAdversarialMalformedTLS tests malformed ClientHello field lengths.
func TestAdversarialMalformedTLS(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringMap := coll.Maps["tls_events"]
	rd, err := ringbuf.NewReader(ringMap)
	if err != nil {
		t.Fatalf("ringbuf.NewReader: %v", err)
	}
	defer rd.Close()

	variants := []struct {
		name    string
		variant string
	}{
		{"SessionIDOverflow", "session_id_overflow"},
		{"CipherSuitesOverflow", "cipher_suites_overflow"},
		{"CompMethodsOverflow", "comp_methods_overflow"},
		{"SNILenMismatch", "sni_len_mismatch"},
	}

	for _, tc := range variants {
		t.Run(tc.name, func(t *testing.T) {
			statsBefore := readParseStatusStats(t, statsMap)

			frame := BuildMalformedTLSClientHello(tc.variant)
			ret, _, err := prog.Test(frame)
			if err != nil {
				t.Fatalf("prog.Test: %v", err)
			}
			if ret != 0 {
				t.Errorf("ret = %d, want TC_ACT_OK (0)", ret)
			}

			rec := readNextRecordWithTimeout(t, rd)
			event, err := ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
			if err != nil {
				t.Fatalf("DecodeTLSSNIEvent: %v", err)
			}

			if event.ParseStatus != ebpfPkg.TLS_CH_MALFORMED && event.ParseStatus != ebpfPkg.TLS_CH_SEGMENTED {
				t.Errorf("event.ParseStatus = %d, want MALFORMED (%d) or SEGMENTED",
					event.ParseStatus, ebpfPkg.TLS_CH_MALFORMED)
			}

			statsAfter := readParseStatusStats(t, statsMap)
			delta := (statsAfter[8+ebpfPkg.TLS_CH_MALFORMED] + statsAfter[8+ebpfPkg.TLS_CH_SEGMENTED]) -
				(statsBefore[8+ebpfPkg.TLS_CH_MALFORMED] + statsBefore[8+ebpfPkg.TLS_CH_SEGMENTED])
			if delta != 1 {
				t.Errorf("delta counted parse status = %d, want 1", delta)
			}
		})
	}
}

// TestAdversarialAccounting asserts 100% accounting across a mixed attack batch.
func TestAdversarialAccounting(t *testing.T) {
	coll, prog := loadMonitorCollection(t)
	if coll == nil {
		return
	}
	defer coll.Close()

	statsMap := coll.Maps["parse_status_stats"]
	ringDNS := coll.Maps["dns_events"]
	ringTLS := coll.Maps["tls_events"]

	rdDNS, err := ringbuf.NewReader(ringDNS)
	if err != nil {
		t.Fatalf("ringbuf.NewReader(dns): %v", err)
	}
	defer rdDNS.Close()

	rdTLS, err := ringbuf.NewReader(ringTLS)
	if err != nil {
		t.Fatalf("ringbuf.NewReader(tls): %v", err)
	}
	defer rdTLS.Close()

	statsBefore := readParseStatusStats(t, statsMap)

	dnsFrames := [][]byte{
		BuildOverDeclaredAncountDNSResponse(0x4001, "acc-over-1.com", 10, []AdversarialDNSAnswerSpec{{Type: 1, TTL: 60, IP: net.IPv4(1, 2, 3, 4)}}),
		BuildForwardPointerDNSQuery(0x4002, 0x40),
		BuildSelfReferentialPointerDNSQuery(0x4003),
		BuildDeepPointerChainDNSQuery(0x4004, 4),
		BuildEthIPv4UDPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, []byte{0x40, 0x05, 0x01, 0x00}),
	}

	tlsFrames := [][]byte{
		BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, BuildTLSClientHelloRaw("valid.example.com", false)),
		BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, BuildTLSClientHelloRaw("ech.example.com", true)),
		BuildMalformedTLSClientHello("session_id_overflow"),
		BuildMalformedTLSClientHello("cipher_suites_overflow"),
	}

	for _, df := range dnsFrames {
		ret, _, err := prog.Test(df)
		if err != nil || ret != 0 {
			t.Fatalf("prog.Test(DNS): err=%v, ret=%d", err, ret)
		}
	}

	for _, tf := range tlsFrames {
		ret, _, err := prog.Test(tf)
		if err != nil || ret != 0 {
			t.Fatalf("prog.Test(TLS): err=%v, ret=%d", err, ret)
		}
	}

	statsAfter := readParseStatusStats(t, statsMap)

	// Verify all 5 DNS events were emitted to ringbuffer
	for i := 0; i < len(dnsFrames); i++ {
		rec := readNextRecordWithTimeout(t, rdDNS)
		_, err = ebpfPkg.DecodeDNSEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeDNSEvent %d: %v", i, err)
		}
	}

	// Verify all 4 TLS events were emitted to ringbuffer
	for i := 0; i < len(tlsFrames); i++ {
		rec := readNextRecordWithTimeout(t, rdTLS)
		_, err = ebpfPkg.DecodeTLSSNIEvent(rec.RawSample)
		if err != nil {
			t.Fatalf("DecodeTLSSNIEvent %d: %v", i, err)
		}
	}

	var totalDNSStatsDelta uint64
	for s := 0; s < 8; s++ {
		totalDNSStatsDelta += (statsAfter[s] - statsBefore[s])
	}
	if totalDNSStatsDelta != uint64(len(dnsFrames)) {
		t.Errorf("total DNS stats delta = %d, want %d", totalDNSStatsDelta, len(dnsFrames))
	}

	var totalTLSStatsDelta uint64
	for s := 8; s < 16; s++ {
		totalTLSStatsDelta += (statsAfter[s] - statsBefore[s])
	}
	if totalTLSStatsDelta != uint64(len(tlsFrames)) {
		t.Errorf("total TLS stats delta = %d, want %d", totalTLSStatsDelta, len(tlsFrames))
	}
}
