package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// invoke drives the command exactly as the Makefile does: argv in, exit code
// and stdout out. main() turns a non-nil error into exit 1 and prints it to
// stderr, so this models the process boundary without an internal back door.
func invoke(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out bytes.Buffer
	err := run(args, &out)
	if err != nil {
		return 1, out.String(), "ed25519-keygen: " + err.Error()
	}
	return 0, out.String(), ""
}

func TestGenerateWritesPKCS8PrivateAndSPKIPublic(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "witness.pem")
	pub := filepath.Join(dir, "witness-pub.pem")

	code, _, errOut := invoke(t, "generate", "--key", key, "--pub", pub)
	if code != 0 {
		t.Fatalf("generate exited %d: %s", code, errOut)
	}

	keyPEM, err := os.ReadFile(key)
	if err != nil {
		t.Fatal(err)
	}
	// openssl genpkey -algorithm ed25519 emits exactly this PEM type.
	if !bytes.HasPrefix(keyPEM, []byte("-----BEGIN PRIVATE KEY-----\n")) {
		t.Fatalf("private PEM header is not the PKCS#8 header openssl emits: %q", first(keyPEM, 40))
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil || keyBlock.Type != "PRIVATE KEY" {
		t.Fatalf("private PEM does not decode to a PRIVATE KEY block")
	}
	// openssl's PKCS#8 Ed25519 DER is 48 bytes total: a two-byte SEQUENCE
	// header over 46 bytes of content — SEQUENCE { INTEGER 0,
	// SEQUENCE { OID 1.3.101.112 }, OCTET STRING [0420 || 32-byte seed] }.
	// 46 is the figure `openssl asn1parse` prints as the SEQUENCE length (l=46)
	// and is NOT the DER length; measured against OpenSSL 3.6.2, `openssl pkey
	// -outform DER | wc -c` is 48 and the PEM file is 119 bytes.
	if len(keyBlock.Bytes) != 48 {
		t.Fatalf("PKCS#8 DER is %d bytes, openssl emits 48 (46 bytes of SEQUENCE content)", len(keyBlock.Bytes))
	}
	if len(keyPEM) != 119 {
		t.Fatalf("private PEM file is %d bytes, openssl genpkey emits 119", len(keyPEM))
	}
	parsed, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
	if err != nil {
		t.Fatalf("PKCS#8 DER does not parse: %v", err)
	}
	priv, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		t.Fatalf("private key is %T, not ed25519.PrivateKey", parsed)
	}

	pubPEM, err := os.ReadFile(pub)
	if err != nil {
		t.Fatal(err)
	}
	// openssl pkey -pubout emits an SPKI PEM whose base64 begins MCowBQYDK2Vw.
	if !bytes.HasPrefix(pubPEM, []byte("-----BEGIN PUBLIC KEY-----\n")) {
		t.Fatalf("public PEM header is not the SPKI header openssl emits: %q", first(pubPEM, 40))
	}
	if !strings.Contains(string(pubPEM), "MCowBQYDK2VwAyEA") {
		t.Fatalf("public PEM base64 does not carry the Ed25519 SPKI prefix MCowBQYDK2VwAyEA: %s", pubPEM)
	}
	if len(pubPEM) != 113 {
		t.Fatalf("public PEM file is %d bytes, openssl pkey -pubout emits 113", len(pubPEM))
	}
	pubBlock, _ := pem.Decode(pubPEM)
	if pubBlock == nil || pubBlock.Type != "PUBLIC KEY" {
		t.Fatalf("public PEM does not decode to a PUBLIC KEY block")
	}
	parsedPub, err := x509.ParsePKIXPublicKey(pubBlock.Bytes)
	if err != nil {
		t.Fatalf("SPKI DER does not parse: %v", err)
	}
	gotPub, ok := parsedPub.(ed25519.PublicKey)
	if !ok {
		t.Fatalf("public key is %T, not ed25519.PublicKey", parsedPub)
	}
	if !gotPub.Equal(priv.Public()) {
		t.Fatal("public PEM is not the public half of the private PEM")
	}

	// The keys must be real crypto, not fixtures.
	msg := []byte("segment attestation payload")
	if !ed25519.Verify(gotPub, msg, ed25519.Sign(priv, msg)) {
		t.Fatal("signature made with the private PEM does not verify under the public PEM")
	}
}

func TestGenerateSetsPrivate0600AndPublic0644(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "k.pem")
	pub := filepath.Join(dir, "k-pub.pem")
	if code, _, errOut := invoke(t, "generate", "--key", key, "--pub", pub); code != 0 {
		t.Fatalf("generate exited %d: %s", code, errOut)
	}
	for path, want := range map[string]os.FileMode{key: 0o600, pub: 0o644} {
		st, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if got := st.Mode().Perm(); got != want {
			t.Fatalf("%s mode is %04o, want %04o", filepath.Base(path), got, want)
		}
	}
}

// Idempotence is the house contract: every Makefile mint clause is
// `if [ ! -f ]`, and silently re-minting invalidates keys a live cluster
// already trusts. The helper refuses rather than overwrites.
func TestGenerateRefusesToOverwriteEitherExistingFile(t *testing.T) {
	cases := []struct{ name, plant string }{
		{"private already present", "key"},
		{"public already present", "pub"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			key := filepath.Join(dir, "k.pem")
			pub := filepath.Join(dir, "k-pub.pem")
			planted := key
			if tc.plant == "pub" {
				planted = pub
			}
			const sentinel = "DO NOT CLOBBER\n"
			if err := os.WriteFile(planted, []byte(sentinel), 0o600); err != nil {
				t.Fatal(err)
			}
			code, _, errOut := invoke(t, "generate", "--key", key, "--pub", pub)
			if code == 0 {
				t.Fatal("generate succeeded over an existing file; it must refuse")
			}
			if !strings.Contains(errOut, planted) {
				t.Fatalf("refusal does not name the offending path %s: %s", planted, errOut)
			}
			got, err := os.ReadFile(planted)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != sentinel {
				t.Fatalf("existing file was modified: %q", got)
			}
		})
	}
}

// key-id must reproduce, byte for byte, what the Makefile previously computed
// with `openssl pkey -pubin -outform DER | openssl dgst -sha256`, which is
// also exactly what signal-ingest's store.DeriveKeyID computes.
func TestKeyIDIsHexSHA256OfTheSPKIDER(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "k.pem")
	pub := filepath.Join(dir, "k-pub.pem")
	if code, _, errOut := invoke(t, "generate", "--key", key, "--pub", pub); code != 0 {
		t.Fatalf("generate exited %d: %s", code, errOut)
	}

	pubPEM, err := os.ReadFile(pub)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(pubPEM)
	digest := sha256.Sum256(block.Bytes)
	want := hex.EncodeToString(digest[:])

	code, out, errOut := invoke(t, "key-id", "--pub", pub)
	if code != 0 {
		t.Fatalf("key-id exited %d: %s", code, errOut)
	}
	if got := strings.TrimSpace(out); got != want {
		t.Fatalf("key-id printed %q, want %q", got, want)
	}
	if strings.TrimSpace(out) != out[:len(out)-1] || !strings.HasSuffix(out, "\n") {
		t.Fatalf("key-id must print exactly one line with a trailing newline, got %q", out)
	}
}

func TestKeyIDRejectsANonEd25519PublicKey(t *testing.T) {
	dir := t.TempDir()
	pub := filepath.Join(dir, "not-a-key.pem")
	if err := os.WriteFile(pub, []byte("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := invoke(t, "key-id", "--pub", pub)
	if code == 0 {
		t.Fatalf("key-id accepted a malformed SPKI and printed %q", out)
	}
	if errOut == "" {
		t.Fatal("key-id failed silently with no message on stderr")
	}
}

// A PEM whose armour says something other than PUBLIC KEY is not a public key
// file, even when the DER inside happens to parse. openssl pkey -pubin refuses
// it, so key-id must too — otherwise a certificate or a mislabelled blob could
// silently yield a key ID the segment-signing policy then pins.
func TestKeyIDRejectsAMislabelledPEMBlockCarryingValidSPKI(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "k.pem")
	pub := filepath.Join(dir, "k-pub.pem")
	if code, _, errOut := invoke(t, "generate", "--key", key, "--pub", pub); code != 0 {
		t.Fatalf("generate exited %d: %s", code, errOut)
	}
	good, err := os.ReadFile(pub)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(good)

	// Positive control: the same DER under the correct armour must be accepted,
	// so a rejection below cannot be explained by the DER simply being bad.
	okPath := filepath.Join(dir, "relabelled-ok.pem")
	if err := os.WriteFile(okPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: block.Bytes}), 0o644); err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := invoke(t, "key-id", "--pub", okPath); code != 0 {
		t.Fatalf("positive control failed: key-id rejected valid SPKI under PUBLIC KEY armour: %s", errOut)
	}

	badPath := filepath.Join(dir, "mislabelled.pem")
	if err := os.WriteFile(badPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: block.Bytes}), 0o644); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := invoke(t, "key-id", "--pub", badPath)
	if code == 0 {
		t.Fatalf("key-id accepted a CERTIFICATE-armoured SPKI and printed %q", out)
	}
	if !strings.Contains(errOut, "CERTIFICATE") {
		t.Fatalf("refusal does not name the offending PEM type: %s", errOut)
	}
}

func TestUnknownSubcommandAndMissingFlagsAreErrors(t *testing.T) {
	if code, _, _ := invoke(t, "mint-me-a-pony"); code == 0 {
		t.Fatal("unknown subcommand exited 0")
	}
	if code, _, _ := invoke(t); code == 0 {
		t.Fatal("no subcommand exited 0")
	}
	dir := t.TempDir()
	if code, _, _ := invoke(t, "generate", "--key", filepath.Join(dir, "k.pem")); code == 0 {
		t.Fatal("generate without --pub exited 0")
	}
	if code, _, _ := invoke(t, "key-id"); code == 0 {
		t.Fatal("key-id without --pub exited 0")
	}
}

func first(b []byte, n int) []byte {
	if len(b) < n {
		return b
	}
	return b[:n]
}
