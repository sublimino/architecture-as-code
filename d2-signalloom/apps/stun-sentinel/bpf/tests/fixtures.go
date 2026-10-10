// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package tests

import (
	"bytes"
	"encoding/binary"
	"net"
)

// Ethernet / IP / L4 constants
const (
	EtherTypeIPv4 = 0x0800
	EtherTypeIPv6 = 0x86DD
	ProtoUDP      = 17
	ProtoTCP      = 6
)

// DNS Constants matching dns_event.h
const (
	DNSParseOK          = 0
	DNSParseTruncated   = 1
	DNSParseNameTooLong = 2
	DNSParseCompressed  = 3
	DNSParseUnsupported = 4

	TypeA     = 1
	TypeNS    = 2
	TypeCNAME = 5
	TypeSOA   = 6
	TypeAAAA  = 28
)

// TLS Constants matching dns_event.h
const (
	TLSCHOK        = 0
	TLSCHSegmented = 1
	TLSCHNoSNI     = 2
	TLSCHEncrypted = 3
	TLSCHMalformed = 4
)

// BuildEthIPv4UDP builds a raw Ethernet + IPv4 + UDP frame.
func BuildEthIPv4UDP(srcMAC, dstMAC net.HardwareAddr, srcIP, dstIP net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	buf := new(bytes.Buffer)

	// Ethernet Header (14 bytes)
	if len(dstMAC) == 0 {
		dstMAC = net.HardwareAddr{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
	}
	if len(srcMAC) == 0 {
		srcMAC = net.HardwareAddr{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}
	}
	buf.Write(dstMAC[:6])
	buf.Write(srcMAC[:6])
	_ = binary.Write(buf, binary.BigEndian, uint16(EtherTypeIPv4))

	// IPv4 Header (20 bytes)
	ipLen := uint16(20 + 8 + len(payload))
	v4Src := srcIP.To4()
	if v4Src == nil {
		v4Src = net.IPv4(10, 244, 0, 5).To4()
	}
	v4Dst := dstIP.To4()
	if v4Dst == nil {
		v4Dst = net.IPv4(10, 96, 0, 10).To4()
	}

	ipHeader := []byte{
		0x45, 0x00,
		byte(ipLen >> 8), byte(ipLen & 0xff),
		0x12, 0x34,
		0x40, 0x00,
		64,
		ProtoUDP,
		0x00, 0x00,
	}
	buf.Write(ipHeader)
	buf.Write(v4Src)
	buf.Write(v4Dst)

	// UDP Header (8 bytes)
	udpLen := uint16(8 + len(payload))
	_ = binary.Write(buf, binary.BigEndian, srcPort)
	_ = binary.Write(buf, binary.BigEndian, dstPort)
	_ = binary.Write(buf, binary.BigEndian, udpLen)
	_ = binary.Write(buf, binary.BigEndian, uint16(0))

	buf.Write(payload)
	return buf.Bytes()
}

// BuildEthIPv4TCP builds a raw Ethernet + IPv4 + TCP frame.
func BuildEthIPv4TCP(srcMAC, dstMAC net.HardwareAddr, srcIP, dstIP net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	buf := new(bytes.Buffer)

	// Ethernet Header
	if len(dstMAC) == 0 {
		dstMAC = net.HardwareAddr{0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
	}
	if len(srcMAC) == 0 {
		srcMAC = net.HardwareAddr{0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb}
	}
	buf.Write(dstMAC[:6])
	buf.Write(srcMAC[:6])
	_ = binary.Write(buf, binary.BigEndian, uint16(EtherTypeIPv4))

	// IPv4 Header (20 bytes)
	ipLen := uint16(20 + 20 + len(payload))
	v4Src := srcIP.To4()
	if v4Src == nil {
		v4Src = net.IPv4(10, 244, 0, 5).To4()
	}
	v4Dst := dstIP.To4()
	if v4Dst == nil {
		v4Dst = net.IPv4(1, 1, 1, 1).To4()
	}

	ipHeader := []byte{
		0x45, 0x00,
		byte(ipLen >> 8), byte(ipLen & 0xff),
		0x56, 0x78,
		0x40, 0x00,
		64,
		ProtoTCP,
		0x00, 0x00,
	}
	buf.Write(ipHeader)
	buf.Write(v4Src)
	buf.Write(v4Dst)

	// TCP Header (20 bytes, doff=5)
	_ = binary.Write(buf, binary.BigEndian, srcPort)
	_ = binary.Write(buf, binary.BigEndian, dstPort)
	_ = binary.Write(buf, binary.BigEndian, uint32(1000))
	_ = binary.Write(buf, binary.BigEndian, uint32(2000))
	tcpHeader := []byte{
		0x50, 0x18,
		0x72, 0x10,
		0x00, 0x00,
		0x00, 0x00,
	}
	buf.Write(tcpHeader)
	buf.Write(payload)

	return buf.Bytes()
}

// EncodeDNSName encodes a domain name into RFC 1035 label format.
func EncodeDNSName(domain string) []byte {
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

// BuildDNSQueryPayload creates a standard RFC 1035 DNS query payload.
func BuildDNSQueryPayload(id uint16, qname string, qtype uint16) []byte {
	buf := new(bytes.Buffer)
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, uint16(0x0100))
	_ = binary.Write(buf, binary.BigEndian, uint16(1))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))

	buf.Write(EncodeDNSName(qname))
	_ = binary.Write(buf, binary.BigEndian, qtype)
	_ = binary.Write(buf, binary.BigEndian, uint16(1))

	return buf.Bytes()
}

// DNSAnswerSpec defines an answer record for fixture generation.
type DNSAnswerSpec struct {
	Type  uint16
	TTL   uint32
	IP    net.IP
	CNAME string
}

// BuildDNSResponsePayload creates a standard RFC 1035 DNS response payload.
func BuildDNSResponsePayload(id uint16, rcode uint8, qname string, qtype uint16, answers []DNSAnswerSpec) []byte {
	buf := new(bytes.Buffer)
	flags := uint16(0x8180) | uint16(rcode&0x0F)
	_ = binary.Write(buf, binary.BigEndian, id)
	_ = binary.Write(buf, binary.BigEndian, flags)
	_ = binary.Write(buf, binary.BigEndian, uint16(1))
	_ = binary.Write(buf, binary.BigEndian, uint16(len(answers)))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))
	_ = binary.Write(buf, binary.BigEndian, uint16(0))

	buf.Write(EncodeDNSName(qname))
	_ = binary.Write(buf, binary.BigEndian, qtype)
	_ = binary.Write(buf, binary.BigEndian, uint16(1))

	for _, ans := range answers {
		_ = binary.Write(buf, binary.BigEndian, uint16(0xC00C))
		_ = binary.Write(buf, binary.BigEndian, ans.Type)
		_ = binary.Write(buf, binary.BigEndian, uint16(1))
		_ = binary.Write(buf, binary.BigEndian, ans.TTL)

		switch ans.Type {
		case TypeA:
			v4 := ans.IP.To4()
			if v4 == nil {
				v4 = net.IPv4(1, 2, 3, 4).To4()
			}
			_ = binary.Write(buf, binary.BigEndian, uint16(4))
			buf.Write(v4)
		case TypeAAAA:
			v6 := ans.IP.To16()
			if v6 == nil {
				v6 = net.ParseIP("2606:4700:4700::1111").To16()
			}
			_ = binary.Write(buf, binary.BigEndian, uint16(16))
			buf.Write(v6)
		case TypeCNAME:
			if ans.CNAME == qname || ans.CNAME == "" {
				_ = binary.Write(buf, binary.BigEndian, uint16(2))
				_ = binary.Write(buf, binary.BigEndian, uint16(0xC00C))
			} else {
				enc := EncodeDNSName(ans.CNAME)
				_ = binary.Write(buf, binary.BigEndian, uint16(len(enc)))
				buf.Write(enc)
			}
		}
	}

	return buf.Bytes()
}

// BuildTLSClientHelloPayload constructs a TLS 1.2 / 1.3 ClientHello payload.
func BuildTLSClientHelloPayload(sni string, isECH bool) []byte {
	hsBuf := new(bytes.Buffer)

	hsBuf.Write([]byte{0x03, 0x03})
	hsBuf.Write(make([]byte, 32))
	hsBuf.WriteByte(0x00)

	_ = binary.Write(hsBuf, binary.BigEndian, uint16(4))
	hsBuf.Write([]byte{0x13, 0x01, 0x13, 0x02})
	hsBuf.Write([]byte{0x01, 0x00})

	extBuf := new(bytes.Buffer)

	if isECH {
		_ = binary.Write(extBuf, binary.BigEndian, uint16(0xfe0d))
		echData := []byte{0x00, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
		_ = binary.Write(extBuf, binary.BigEndian, uint16(len(echData)))
		extBuf.Write(echData)
	}

	if sni != "" {
		_ = binary.Write(extBuf, binary.BigEndian, uint16(0x0000))
		sniBytes := []byte(sni)
		snListLen := uint16(len(sniBytes) + 3)
		extLen := uint16(snListLen + 2)

		_ = binary.Write(extBuf, binary.BigEndian, extLen)
		_ = binary.Write(extBuf, binary.BigEndian, snListLen)
		extBuf.WriteByte(0x00)
		_ = binary.Write(extBuf, binary.BigEndian, uint16(len(sniBytes)))
		extBuf.Write(sniBytes)
	}

	if extBuf.Len() > 0 {
		_ = binary.Write(hsBuf, binary.BigEndian, uint16(extBuf.Len()))
		hsBuf.Write(extBuf.Bytes())
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

	return recBuf.Bytes()
}
