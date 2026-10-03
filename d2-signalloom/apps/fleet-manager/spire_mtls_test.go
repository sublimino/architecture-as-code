package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffegrpc/grpccredentials"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	entryv1 "github.com/spiffe/spire-api-sdk/proto/spire/api/server/entry/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// SPIRE's server API on :8081 speaks only mTLS. fleet-manager dialled it in
// plaintext, and every credential restore failed live (2026-10-03) with
// "error reading server preface: EOF", leaving recovered agents revoked.

var (
	testTD           = spiffeid.RequireTrustDomainFromString("signalloom.demo")
	testServerID     = spiffeid.RequireFromString("spiffe://signalloom.demo/spire/server")
	testFleetManager = spiffeid.RequireFromString("spiffe://signalloom.demo/ns/fe-signalloom/sa/fleet-manager")
)

type testCA struct {
	cert *x509.Certificate
	key  crypto.Signer
}

func newTestCA(t *testing.T) *testCA {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test SPIRE CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		URIs:                  []*url.URL{testTD.ID().URL()},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return &testCA{cert: cert, key: key}
}

type staticSVID struct{ svid *x509svid.SVID }

func (s staticSVID) GetX509SVID() (*x509svid.SVID, error) { return s.svid, nil }

func (ca *testCA) svid(t *testing.T, id spiffeid.ID) staticSVID {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		URIs:         []*url.URL{id.URL()},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, key.Public(), ca.key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return staticSVID{&x509svid.SVID{ID: id, Certificates: []*x509.Certificate{cert}, PrivateKey: key}}
}

func (ca *testCA) bundle() *x509bundle.Bundle {
	return x509bundle.FromX509Authorities(testTD, []*x509.Certificate{ca.cert})
}

// startMTLSSpire serves the mock Entry API over mTLS as `serverID`, admitting
// only fleet-manager's SVID (SPIRE's admin_ids, for this test).
func startMTLSSpire(t *testing.T, ca *testCA, serverID spiffeid.ID) (string, *mockEntryServer) {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	creds := grpccredentials.MTLSServerCredentials(ca.svid(t, serverID), ca.bundle(), tlsconfig.AuthorizeID(testFleetManager))
	s := grpc.NewServer(grpc.Creds(creds))
	srv := newMockEntryServer()
	entryv1.RegisterEntryServer(s, srv)
	go func() { _ = s.Serve(lis) }()
	t.Cleanup(s.Stop)
	return lis.Addr().String(), srv
}

func TestSpireClientReachesTheServerAPIOverMTLSWithItsOwnSVID(t *testing.T) {
	ca := newTestCA(t)
	addr, _ := startMTLSSpire(t, ca, testServerID)
	client, err := newSpireClientWithTransport(addr, spireMTLS(ca.svid(t, testFleetManager), ca.bundle(), testServerID))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := client.ListEntriesBySPIFFEID(ctx, "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent"); err != nil {
		t.Fatalf("mTLS call to the SPIRE server API failed: %v", err)
	}
}

func TestSpireClientRefusesAServerThatIsNotTheSPIREServer(t *testing.T) {
	ca := newTestCA(t)
	addr, _ := startMTLSSpire(t, ca, spiffeid.RequireFromString("spiffe://signalloom.demo/ns/fe-signalloom/sa/impostor"))
	client, err := newSpireClientWithTransport(addr, spireMTLS(ca.svid(t, testFleetManager), ca.bundle(), testServerID))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = client.ListEntriesBySPIFFEID(ctx, "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent")
	if err == nil || !strings.Contains(err.Error(), "unexpected ID") {
		t.Fatalf("err = %v; want the impostor's SPIFFE ID refused", err)
	}
}

// The live failure, pinned: plaintext against the TLS-only server API.
func TestPlaintextAgainstTheTLSServerAPIIsTheLivePrefaceEOF(t *testing.T) {
	ca := newTestCA(t)
	addr, _ := startMTLSSpire(t, ca, testServerID)
	client, err := newSpireClientWithTransport(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err = client.ListEntriesBySPIFFEID(ctx, "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent")
	if err == nil || !strings.Contains(err.Error(), "preface") {
		t.Fatalf("err = %v; want the plaintext failure the live estate showed", err)
	}
}

func TestATCPSpireAddressWithoutAWorkloadAPISocketIsAConfigErrorNotPlaintext(t *testing.T) {
	t.Setenv("SPIFFE_ENDPOINT_SOCKET", "")
	_, err := spireTransportFor("spire-server.inf-bao.svc.cluster.local:8081")
	if err == nil || !strings.Contains(err.Error(), "SPIFFE_ENDPOINT_SOCKET") {
		t.Fatalf("err = %v; want a refusal naming SPIFFE_ENDPOINT_SOCKET instead of a plaintext dial", err)
	}
}

func TestTheServerIDDefaultsToSignalloomDemoAndIsOverridable(t *testing.T) {
	t.Setenv("SPIRE_SERVER_SPIFFE_ID", "")
	if id, err := spireServerID(); err != nil || id != testServerID {
		t.Fatalf("default server ID = %v, %v; want %v", id, err, testServerID)
	}
	t.Setenv("SPIRE_SERVER_SPIFFE_ID", "spiffe://osramp.local/spire/server")
	if id, err := spireServerID(); err != nil || id.String() != "spiffe://osramp.local/spire/server" {
		t.Fatalf("override = %v, %v", id, err)
	}
	t.Setenv("SPIRE_SERVER_SPIFFE_ID", "not-a-spiffe-id")
	if _, err := spireServerID(); err == nil {
		t.Fatal("a malformed SPIRE_SERVER_SPIFFE_ID was accepted")
	}
}
