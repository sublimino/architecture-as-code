// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tc

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
)

// AdversarialDNSAnswerSpec defines an answer record for adversarial fixture generation.
type AdversarialDNSAnswerSpec struct {
	Type  uint16
	TTL   uint32
	IP    net.IP
	CNAME string
}

// EncodeDNSNameRFC1035 encodes a domain name into RFC 1035 label format.
func EncodeDNSNameRFC1035(domain string) []byte {
	if domain == "" {
		return []byte{0}
	}
	var out []byte
	parts := bytes.Split([]byte(domain), []byte("."))
	for _, p := range parts {
		if len(p) == 0 {
			continue
		}
		out = append(out, byte(len(p)))
		out = append(out, p...)
	}
	out = append(out, 0)
	return out
}

// BuildDNSQueryPayload constructs a standard RFC 1035 DNS query payload.
func BuildDNSQueryPayload(id uint16, qname string, qtype uint16) []byte {
	buf := new(bytes.Buffer)
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0100)) // Standard Query
	_ = binary.Write(buf, binary.BigEndian, uint16(1))      // qdcount = 1
	_ = binary.Write(buf, binary.BigEndian, uint16(0))      // ancount = 0
	_ = binary.Write(buf, binary.BigEndian, uint16(0))      // nscount = 0
	_ = binary.Write(buf, binary.BigEndian, uint16(0))      // arcount = 0

	buf.Write(EncodeDNSNameRFC1035(qname))
	_ = binary.Write(buf, binary.BigEndian, qtype)
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // CLASS IN

	return buf.Bytes()
}

// BuildEthIPv4UDPFrame constructs an Ethernet + IPv4 + UDP frame.
func BuildEthIPv4UDPFrame(srcIP, dstIP net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	buf := new(bytes.Buffer)

	// Ethernet Header (14 bytes)
	dstMAC := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
	srcMAC := []byte{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}
	buf.Write(dstMAC)
	buf.Write(srcMAC)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0800)) // EtherType IPv4

	// IPv4 Header (20 bytes)
	v4Src := srcIP.To4()
	if v4Src == nil {
		v4Src = net.IPv4(10, 244, 0, 5).To4()
	}
	v4Dst := dstIP.To4()
	if v4Dst == nil {
		v4Dst = net.IPv4(10, 96, 0, 10).To4()
	}
	ipLen := uint16(20 + 8 + len(payload))
	ipHeader := []byte{
		0x45, 0x00,
		byte(ipLen >> 8), byte(ipLen & 0xff),
		0x12, 0x34,
		0x40, 0x00, // Don't fragment
		64,         // TTL
		17,         // IPPROTO_UDP
		0x00, 0x00, // Checksum (ignored in BPF direct test)
	}
	buf.Write(ipHeader)
	buf.Write(v4Src)
	buf.Write(v4Dst)

	// UDP Header (8 bytes)
	udpLen := uint16(8 + len(payload))
	_ = binary.Write(buf, binary.BigEndian, srcPort)
	_ = binary.Write(buf, binary.BigEndian, dstPort)
	_ = binary.Write(buf, binary.BigEndian, udpLen)
	_ = binary.Write(buf, binary.BigEndian, uint16(0)) // UDP Checksum

	buf.Write(payload)
	return buf.Bytes()
}

// BuildEthIPv4TCPFrame constructs an Ethernet + IPv4 + TCP frame.
func BuildEthIPv4TCPFrame(srcIP, dstIP net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	buf := new(bytes.Buffer)

	// Ethernet Header (14 bytes)
	dstMAC := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
	srcMAC := []byte{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}
	buf.Write(dstMAC)
	buf.Write(srcMAC)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0800)) // EtherType IPv4

	// IPv4 Header (20 bytes)
	v4Src := srcIP.To4()
	if v4Src == nil {
		v4Src = net.IPv4(10, 244, 0, 5).To4()
	}
	v4Dst := dstIP.To4()
	if v4Dst == nil {
		v4Dst = net.IPv4(1, 1, 1, 1).To4()
	}
	ipLen := uint16(20 + 20 + len(payload))
	ipHeader := []byte{
		0x45, 0x00,
		byte(ipLen >> 8), byte(ipLen & 0xff),
		0x56, 0x78,
		0x40, 0x00,
		64,
		6,          // IPPROTO_TCP
		0x00, 0x00,
	}
	buf.Write(ipHeader)
	buf.Write(v4Src)
	buf.Write(v4Dst)

	// TCP Header (20 bytes, doff = 5)
	_ = binary.Write(buf, binary.BigEndian, srcPort)
	_ = binary.Write(buf, binary.BigEndian, dstPort)
	_ = binary.Write(buf, binary.BigEndian, uint32(1000000))
	_ = binary.Write(buf, binary.BigEndian, uint32(2000000))
	tcpHeader := []byte{
		0x50, 0x18, // doff=5 (20 bytes), flags=PSH|ACK
		0x72, 0x10, // window
		0x00, 0x00, // checksum
		0x00, 0x00, // urgent ptr
	}
	buf.Write(tcpHeader)
	buf.Write(payload)
	return buf.Bytes()
}

// BuildOverDeclaredAncountDNSResponse constructs a DNS response where ancount declares
// more records than the packet actually contains.
func BuildOverDeclaredAncountDNSResponse(id uint16, qname string, declaredAncount uint16, actualAnswers []AdversarialDNSAnswerSpec) []byte {
	buf := new(bytes.Buffer)
	flags := uint16(0x8180) // QR=1, RD=1, RA=1, RCODE=0
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, flags)
	_ = binary.Write(buf, binary.BigEndian, uint16(1))               // qdcount = 1
	_ = binary.Write(buf, binary.BigEndian, declaredAncount)          // ancount = declared (adversarial!)
	_ = binary.Write(buf, binary.BigEndian, uint16(0))               // nscount = 0
	_ = binary.Write(buf, binary.BigEndian, uint16(0))               // arcount = 0

	buf.Write(EncodeDNSNameRFC1035(qname))
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QTYPE A
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QCLASS IN

	// Write only actualAnswers (fewer than declaredAncount)
	for _, ans := range actualAnswers {
		_ = binary.Write(buf, binary.BigEndian, uint16(0xC00C)) // Compression pointer to offset 12 (qname)
		_ = binary.Write(buf, binary.BigEndian, ans.Type)
		_ = binary.Write(buf, binary.BigEndian, uint16(1)) // CLASS IN
		_ = binary.Write(buf, binary.BigEndian, ans.TTL)

		switch ans.Type {
		case 1: // Type A
			v4 := ans.IP.To4()
			if v4 == nil {
				v4 = net.IPv4(93, 184, 216, 34).To4()
			}
			_ = binary.Write(buf, binary.BigEndian, uint16(4))
			buf.Write(v4)
		case 28: // Type AAAA
			v6 := ans.IP.To16()
			if v6 == nil {
				v6 = net.ParseIP("2606:4700:4700::1111").To16()
			}
			_ = binary.Write(buf, binary.BigEndian, uint16(16))
			buf.Write(v6)
		case 5: // Type CNAME
			enc := EncodeDNSNameRFC1035(ans.CNAME)
			_ = binary.Write(buf, binary.BigEndian, uint16(len(enc)))
			buf.Write(enc)
		}
	}

	return BuildEthIPv4UDPFrame(net.IPv4(10, 96, 0, 10), net.IPv4(10, 244, 0, 5), 53, 54321, buf.Bytes())
}

// BuildForwardPointerDNSQuery constructs a DNS query with a forward-pointing compression pointer.
func BuildForwardPointerDNSQuery(id uint16, targetOffset uint16) []byte {
	buf := new(bytes.Buffer)
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0100)) // Query
	_ = binary.Write(buf, binary.BigEndian, uint16(1))      // qdcount=1
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))

	// Compression pointer at offset 12 pointing to targetOffset
	ptr := uint16(0xC000) | (targetOffset & 0x3FFF)
	_ = binary.Write(buf, binary.BigEndian, ptr)
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QTYPE A
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QCLASS IN

	return BuildEthIPv4UDPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, buf.Bytes())
}

// BuildSelfReferentialPointerDNSQuery constructs a DNS query pointing to itself (offset 12).
func BuildSelfReferentialPointerDNSQuery(id uint16) []byte {
	return BuildForwardPointerDNSQuery(id, 12) // offset 12 points to offset 12
}

// BuildDeepPointerChainDNSQuery constructs a DNS query with chained pointers.
func BuildDeepPointerChainDNSQuery(id uint16, depth int) []byte {
	buf := new(bytes.Buffer)
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0100)) // Query
	_ = binary.Write(buf, binary.BigEndian, uint16(1))      // qdcount=1
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))

	// Write a chain of pointers: offset 12 -> 14 -> 16 -> ...
	for i := 0; i < depth; i++ {
		nextOffset := uint16(12 + 2*(i+1))
		ptr := uint16(0xC000) | (nextOffset & 0x3FFF)
		_ = binary.Write(buf, binary.BigEndian, ptr)
	}
	// Terminate with root domain
	buf.WriteByte(0x00)
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QTYPE A
	_ = binary.Write(buf, binary.BigEndian, uint16(1)) // QCLASS IN

	return BuildEthIPv4UDPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(10, 96, 0, 10), 54321, 53, buf.Bytes())
}

// BuildFragmentedIPv4UDP constructs an IP fragment frame.
func BuildFragmentedIPv4UDP(srcIP, dstIP net.IP, fragID uint16, fragOffset8 uint16, moreFrags bool, payload []byte) []byte {
	buf := new(bytes.Buffer)

	// Ethernet Header
	dstMAC := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
	srcMAC := []byte{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}
	buf.Write(dstMAC)
	buf.Write(srcMAC)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0800))

	flagsAndOffset := fragOffset8 & 0x1FFF
	if moreFrags {
		flagsAndOffset |= 0x2000 // MF bit
	}

	ipLen := uint16(20 + len(payload))
	ipHeader := []byte{
		0x45, 0x00,
		byte(ipLen >> 8), byte(ipLen & 0xff),
		byte(fragID >> 8), byte(fragID & 0xff),
		byte(flagsAndOffset >> 8), byte(flagsAndOffset & 0xff),
		64,
		17, // IPPROTO_UDP
		0x00, 0x00,
	}
	buf.Write(ipHeader)
	buf.Write(srcIP.To4())
	buf.Write(dstIP.To4())
	buf.Write(payload)

	return buf.Bytes()
}

// BuildTLSClientHelloRaw constructs a TLS 1.2 / 1.3 ClientHello byte payload.
func BuildTLSClientHelloRaw(sni string, isECH bool) []byte {
	hsBuf := new(bytes.Buffer)

	// ClientVersion (TLS 1.2 legacy: 0x0303)
	hsBuf.Write([]byte{0x03, 0x03})
	// Random (32 bytes)
	hsBuf.Write(make([]byte, 32))
	// Legacy Session ID (0 length)
	hsBuf.WriteByte(0x00)

	// Cipher Suites (4 bytes = 2 suites: TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384)
	_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
	hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})

	// Legacy Compression Methods (1 byte length = 0x00 null)
	hsBuf.Write([]byte{0x01, 0x00})

	extBuf := new(bytes.Buffer)

	// ECH outer extension (0xfe0d)
	if isECH {
		_ = binary.Write(extBuf, binary.BigEndian, uint16(0xfe0d))
		echData := []byte{0x00, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
		_ = binary.Write(extBuf, binary.BigEndian, uint16(len(echData)))
		extBuf.Write(echData)
	}

	// Server Name Indication (0x0000)
	if sni != "" {
		_ = binary.Write(extBuf, binary.BigEndian, uint16(0x0000))
		sniBytes := []byte(sni)
		snListLen := uint16(len(sniBytes) + 3)
		extLen := uint16(snListLen + 2)

		_ = binary.Write(extBuf, binary.BigEndian, extLen)
		_ = binary.Write(extBuf, binary.BigEndian, snListLen)
		extBuf.WriteByte(0x00) // NameType: host_name (0)
		_ = binary.Write(extBuf, binary.BigEndian, uint16(len(sniBytes)))
		extBuf.Write(sniBytes)
	}

	if extBuf.Len() > 0 {
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(extBuf.Len()))
		hsBuf.Write(extBuf.Bytes())
	}

	// Handshake record (Type 0x01 = ClientHello)
	recPayload := new(bytes.Buffer)
	recPayload.WriteByte(0x01)
	hsLen := hsBuf.Len()
	recPayload.WriteByte(byte((hsLen >> 16) & 0xff))
	recPayload.WriteByte(byte((hsLen >> 8) & 0xff))
	recPayload.WriteByte(byte(hsLen & 0xff))
	recPayload.Write(hsBuf.Bytes())

	// TLS Record Layer (Content Type 0x16 = Handshake, Version 0x0301)
	recBuf := new(bytes.Buffer)
	recBuf.WriteByte(0x16)
	recBuf.Write([]byte{0x03, 0x01})
	_ = binary.Write(recBuf, binary.BigEndian, uint16(recPayload.Len()))
	recBuf.Write(recPayload.Bytes())

	return recBuf.Bytes()
}

// BuildSegmentedTLSClientHello splits a ClientHello into two TCP segment frames.
func BuildSegmentedTLSClientHello(sni string, isECH bool, splitAt int) ([]byte, []byte) {
	full := BuildTLSClientHelloRaw(sni, isECH)
	if splitAt > len(full) {
		splitAt = len(full) / 2
	}
	seg1 := full[:splitAt]
	seg2 := full[splitAt:]

	frame1 := BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, seg1)
	frame2 := BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, seg2)

	return frame1, frame2
}

// BuildMalformedTLSClientHello constructs TLS ClientHello with malformed header fields.
func BuildMalformedTLSClientHello(variant string) []byte {
	hsBuf := new(bytes.Buffer)
	hsBuf.Write([]byte{0x03, 0x03})
	hsBuf.Write(make([]byte, 32))

	switch variant {
	case "session_id_overflow":
		// Session ID length > 32 (e.g. 64)
		hsBuf.WriteByte(64)
		hsBuf.Write(make([]byte, 64))
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
		hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})
		hsBuf.Write([]byte{0x01, 0x00})
	case "cipher_suites_overflow":
		hsBuf.WriteByte(0x00)
		// Cipher suites length > 256 (e.g. 512)
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(512))
		hsBuf.Write(make([]byte, 512))
		hsBuf.Write([]byte{0x01, 0x00})
	case "comp_methods_overflow":
		hsBuf.WriteByte(0x00)
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
		hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})
		// Compression methods length > 16 (e.g. 32)
		hsBuf.WriteByte(32)
		hsBuf.Write(make([]byte, 32))
	case "sni_len_mismatch":
		hsBuf.WriteByte(0x00)
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
		hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})
		hsBuf.Write([]byte{0x01, 0x00})

		extBuf := new(bytes.Buffer)
		_ = binary.Write(extBuf, binary.BigEndian, uint16(0x0000)) // SNI
		_ = binary.Write(extBuf, binary.BigEndian, uint16(5))      // ext_len = 5
		_ = binary.Write(extBuf, binary.BigEndian, uint16(20))     // sn_list_len = 20 (mismatch > ext_len!)
		extBuf.WriteByte(0x00)
		_ = binary.Write(extBuf, binary.BigEndian, uint16(15))
		extBuf.Write([]byte("overflow.example"))

		_ = binary.Write(hsBuf, binary.BigEndian, uint16(extBuf.Len()))
		hsBuf.Write(extBuf.Bytes())
	default:
		hsBuf.WriteByte(0x00)
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
		hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})
		hsBuf.Write([]byte{0x01, 0x00})
	}

	recPayload := new(bytes.Buffer)
	recPayload.WriteByte(0x01)
	hsLen := hsBuf.Len()
	recPayload.WriteByte(byte((hsLen >> 16) & 0xff))
	recPayload.WriteByte(byte((hsLen >> 8) & 0xff))
	recPayload.WriteByte(byte(hsLen & 0xff))
	recPayload.Write(hsBuf.Bytes())

	recBuf := new(bytes.Buffer)
	recBuf.WriteByte(0x16)
	recBuf.Write([]byte{0x03, 0x01})
	_ = binary.Write(recBuf, binary.BigEndian, uint16(recPayload.Len()))
	recBuf.Write(recPayload.Bytes())

	return BuildEthIPv4TCPFrame(net.IPv4(10, 244, 0, 5), net.IPv4(1, 1, 1, 1), 43210, 443, recBuf.Bytes())
}

// BuildFloodBatch generates a slice of count unique synthetic packets for ringbuffer saturation.
func BuildFloodBatch(count int, isDNS bool) [][]byte {
	batch := make([][]byte, count)
	for i := 0; i < count; i++ {
		if isDNS {
			id := uint16(i & 0xFFFF)
			name := fmt.Sprintf("flood-%d.example.com", i)
			answers := []AdversarialDNSAnswerSpec{
				{Type: 1, TTL: 60, IP: net.IPv4(byte(10+(i>>16)&0xFF), byte((i>>8)&0xFF), byte(i&0xFF), 1)},
			}
			buf := new(bytes.Buffer)
			flags := uint16(0x8180)
			_ = binary.Write(buf, binary.BigEndian, id)
			_ = binary.Write(buf, binary.BigEndian, flags)
			_ = binary.Write(buf, binary.BigEndian, uint16(1))
			_ = binary.Write(buf, binary.BigEndian, uint16(len(answers)))
			_ = binary.Write(buf, binary.BigEndian, uint16(0))
			_ = binary.Write(buf, binary.BigEndian, uint16(0))

			buf.Write(EncodeDNSNameRFC1035(name))
			_ = binary.Write(buf, binary.BigEndian, uint16(1))
			_ = binary.Write(buf, binary.BigEndian, uint16(1))

			for _, ans := range answers {
				_ = binary.Write(buf, binary.BigEndian, uint16(0xC00C))
				_ = binary.Write(buf, binary.BigEndian, ans.Type)
				_ = binary.Write(buf, binary.BigEndian, uint16(1))
				_ = binary.Write(buf, binary.BigEndian, ans.TTL)
				_ = binary.Write(buf, binary.BigEndian, uint16(4))
				buf.Write(ans.IP.To4())
			}

			srcIP := net.IPv4(10, 96, 0, 10)
			dstIP := net.IPv4(10, 244, byte((i>>8)&0xFF), byte(i&0xFF))
			batch[i] = BuildEthIPv4UDPFrame(srcIP, dstIP, 53, uint16(10000+(i%50000)), buf.Bytes())
		} else {
			sni := fmt.Sprintf("tls-flood-%d.example.com", i)
			tlsPayload := BuildTLSClientHelloRaw(sni, false)
			srcIP := net.IPv4(10, 244, byte((i>>8)&0xFF), byte(i&0xFF))
			dstIP := net.IPv4(byte(1+(i>>16)&0xFF), byte((i>>8)&0xFF), byte(i&0xFF), 1)
			batch[i] = BuildEthIPv4TCPFrame(srcIP, dstIP, uint16(10000+(i%50000)), 443, tlsPayload)
		}
	}
	return batch
}
