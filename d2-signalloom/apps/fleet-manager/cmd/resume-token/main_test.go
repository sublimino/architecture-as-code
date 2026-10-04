package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/auth"
)

const (
	testAudience  = "signalloom-fleet/local"
	testTrustRoot = "signalloom-operator-root/2026-q3"
	testAgent     = "remote-api-0"
	testNamespace = "tenant-a"
)

var testNow = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func fixedClock() time.Time { return testNow }

// runOK runs one subcommand and fails the test on error, returning stdout.
func runOK(t *testing.T, args ...string) string {
	t.Helper()
	var out bytes.Buffer
	if err := run(args, &out, fixedClock); err != nil {
		t.Fatalf("%v: %v", args, err)
	}
	return out.String()
}

// keygen writes a pair into dir and returns the registry entry it printed.
func keygen(t *testing.T, dir, operator, name string) auth.OperatorKeyJSON {
	t.Helper()
	out := runOK(t, "keygen", "--operator", operator, "--out", dir, "--name", name)
	var entry auth.OperatorKeyJSON
	if err := json.Unmarshal([]byte(out), &entry); err != nil {
		t.Fatalf("keygen output is not one JSON entry: %v\n%s", err, out)
	}
	return entry
}

// mintSigned mints and signs with the given operators, returning the token
// path and a registry holding every printed entry.
func mintSigned(t *testing.T, operators ...string) (string, *auth.StaticOperatorKeyRegistry) {
	t.Helper()
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")
	runOK(t, "mint",
		"--agent", testAgent, "--namespace", testNamespace,
		"--audience", testAudience, "--trust-root", testTrustRoot,
		"--approval", "CHG-2026-10-04-0007", "--out", tokenPath)

	var entries []auth.OperatorKeyEntry
	for i, op := range operators {
		name := "op" + string(rune('a'+i))
		printed := keygen(t, dir, op, name)
		raw, err := json.Marshal(printed)
		if err != nil {
			t.Fatal(err)
		}
		loaded, err := auth.LoadOperatorKeysFromJSON(raw)
		if err != nil {
			t.Fatalf("printed entry does not load: %v", err)
		}
		entries = append(entries, loaded...)
		runOK(t, "sign", "--token", tokenPath, "--operator", op, "--key", filepath.Join(dir, name+".key"))
	}
	return tokenPath, auth.NewStaticOperatorKeyRegistry(entries...)
}

func readTokenFile(t *testing.T, path string) auth.ResumeToken {
	t.Helper()
	token, err := readToken(path)
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func TestKeygen_RoundTripsThroughTheRegistryLoader(t *testing.T) {
	dir := t.TempDir()
	entry := keygen(t, dir, "spiffe://signalloom.io/operator/alice", "alice")

	// The printed entry is exactly the shape the server loads.
	raw, _ := json.Marshal(entry)
	loaded, err := auth.LoadOperatorKeysFromJSON(raw)
	if err != nil {
		t.Fatalf("LoadOperatorKeysFromJSON: %v", err)
	}
	if len(loaded) != 1 || loaded[0].OperatorID != entry.OperatorID || loaded[0].KeyID != entry.KeyID {
		t.Fatalf("loaded %#v from %s", loaded, raw)
	}

	// The files agree with the entry and with each other.
	privHex, err := os.ReadFile(filepath.Join(dir, "alice.key"))
	if err != nil {
		t.Fatal(err)
	}
	priv, err := hex.DecodeString(strings.TrimSpace(string(privHex)))
	if err != nil || len(priv) != ed25519.PrivateKeySize {
		t.Fatalf("alice.key is not a hex 64-byte key: %v (%d bytes)", err, len(priv))
	}
	pubHex, err := os.ReadFile(filepath.Join(dir, "alice.pub"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(pubHex)) != entry.PublicKey {
		t.Fatalf("alice.pub %q disagrees with printed public_key %q", pubHex, entry.PublicKey)
	}
	derived := ed25519.PrivateKey(priv).Public().(ed25519.PublicKey)
	if hex.EncodeToString(derived) != entry.PublicKey || auth.ComputeKeyID(derived) != entry.KeyID {
		t.Fatal("private key does not derive the printed public key and key id")
	}

	info, err := os.Stat(filepath.Join(dir, "alice.key"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("alice.key mode = %o, want 600", info.Mode().Perm())
	}

	// A second keygen with the same name must not overwrite the first.
	var out bytes.Buffer
	if err := run([]string{"keygen", "--operator", "x", "--out", dir, "--name", "alice"}, &out, fixedClock); err == nil {
		t.Fatal("keygen overwrote an existing key file")
	}
}

func TestMintAndSign_TwiceVerifiesUnderTheDefaultPolicy(t *testing.T) {
	tokenPath, reg := mintSigned(t, "spiffe://signalloom.io/operator/alice", "spiffe://signalloom.io/operator/bob")
	token := readTokenFile(t, tokenPath)

	if token.RequiredSignatures != 2 || len(token.Signatures) != 2 {
		t.Fatalf("token requires %d, carries %d", token.RequiredSignatures, len(token.Signatures))
	}
	nonce, err := base64.StdEncoding.DecodeString(token.Nonce)
	if err != nil || len(nonce) < auth.ResumeTokenMinNonceBytes {
		t.Fatalf("nonce %q: %v (%d bytes)", token.Nonce, err, len(nonce))
	}
	if !strings.HasPrefix(token.TokenID, "rt-") {
		t.Fatalf("token_id %q lacks the rt- prefix", token.TokenID)
	}
	if token.IssuedAt != testNow.Add(-30*time.Second).Format(time.RFC3339) {
		t.Fatalf("issued_at = %s, want now minus 30s", token.IssuedAt)
	}
	if token.ExpiresAt != testNow.Add(-30*time.Second).Add(10*time.Minute).Format(time.RFC3339) {
		t.Fatalf("expires_at = %s, want issued_at plus 10m", token.ExpiresAt)
	}

	policy := auth.DefaultResumeTokenPolicy(testAudience, testTrustRoot)
	policy.RequiredSignatures = 2
	target := auth.TargetRef{AgentID: testAgent, Namespace: testNamespace}
	if _, err := auth.VerifyResumeToken(token, target, reg, policy, testNow); err != nil {
		t.Fatalf("a twice-signed minted token must verify: %v", err)
	}
}

func TestSign_OnceFailsTheDualPolicy(t *testing.T) {
	tokenPath, reg := mintSigned(t, "spiffe://signalloom.io/operator/alice")
	token := readTokenFile(t, tokenPath)

	policy := auth.DefaultResumeTokenPolicy(testAudience, testTrustRoot)
	policy.RequiredSignatures = 2
	target := auth.TargetRef{AgentID: testAgent, Namespace: testNamespace}
	_, err := auth.VerifyResumeToken(token, target, reg, policy, testNow)
	if !errors.Is(err, auth.ErrResumeTokenInsufficientSignature) {
		t.Fatalf("single signature verified or failed for the wrong reason: %v", err)
	}
}

func TestRequest_BodyDecodesIntoAResumeRequest(t *testing.T) {
	tokenPath, _ := mintSigned(t, "spiffe://signalloom.io/operator/alice", "spiffe://signalloom.io/operator/bob")
	token := readTokenFile(t, tokenPath)

	cases := []struct {
		name     string
		args     []string
		wantIdem string
	}{
		{"default key", nil, "resume-" + testAgent + "-" + token.TokenID},
		{"explicit key", []string{"--idempotency-key", "idem-42"}, "idem-42"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := runOK(t, append([]string{"request", "--token", tokenPath}, tc.args...)...)
			var req resumeRequest
			if err := json.Unmarshal([]byte(out), &req); err != nil {
				t.Fatalf("request output is not a ResumeRequest: %v\n%s", err, out)
			}
			if req.SchemaVersion != auth.FrozenSchemaVersion || req.AgentID != testAgent || req.Namespace != testNamespace {
				t.Fatalf("request = %#v", req)
			}
			if req.IdempotencyKey != tc.wantIdem {
				t.Fatalf("idempotency_key = %q, want %q", req.IdempotencyKey, tc.wantIdem)
			}
			if req.Token.TokenID != token.TokenID || len(req.Token.Signatures) != 2 {
				t.Fatalf("token not carried intact: %#v", req.Token)
			}
			if req.Timestamp != testNow.Format(time.RFC3339) {
				t.Fatalf("timestamp = %q", req.Timestamp)
			}
		})
	}

	// --out writes the same body to a file.
	outPath := filepath.Join(t.TempDir(), "request.json")
	runOK(t, "request", "--token", tokenPath, "--out", outPath)
	data, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	var req resumeRequest
	if err := json.Unmarshal(data, &req); err != nil || req.Token.TokenID != token.TokenID {
		t.Fatalf("file body: %v %#v", err, req)
	}
}

func TestUsage_RejectsMissingFlagsWithoutWriting(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name string
		args []string
	}{
		{"no subcommand", nil},
		{"unknown subcommand", []string{"verify"}},
		{"keygen without name", []string{"keygen", "--operator", "x", "--out", dir}},
		{"keygen name is a path", []string{"keygen", "--operator", "x", "--out", dir, "--name", "../x"}},
		{"mint without out", []string{"mint", "--agent", "a", "--namespace", "n", "--audience", "u", "--trust-root", "r", "--approval", "p"}},
		{"mint zero signatures", []string{"mint", "--agent", "a", "--namespace", "n", "--audience", "u", "--trust-root", "r", "--approval", "p", "--out", filepath.Join(dir, "t.json"), "--required-signatures", "0"}},
		{"sign without key", []string{"sign", "--token", filepath.Join(dir, "missing.json"), "--operator", "x"}},
		{"request without token", []string{"request"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := run(tc.args, &out, fixedClock); err == nil {
				t.Fatalf("%v succeeded", tc.args)
			}
		})
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("refused commands wrote files: %v", entries)
	}
}
