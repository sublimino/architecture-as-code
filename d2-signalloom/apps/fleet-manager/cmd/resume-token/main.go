// Command resume-token is the operator-side tool for the dual-signed resume
// token that fleet-manager's /api/v1/fleet/resume route requires, local and
// remote alike.
//
// It is the minting half of the contract in resume_token.go: it holds
// private keys, which the server never does. Four subcommands, each a step
// an operator takes:
//
//	keygen   generate an operator key pair and print its registry entry
//	mint     write an unsigned token bound to one agent in one namespace
//	sign     add one operator's signature to a token file
//	request  wrap a signed token in the ResumeRequest body the route accepts
//
// Private keys and tokens only ever travel as file paths. Nothing secret is
// taken on argv, so nothing secret lands in shell history or /proc.
//
// Usage:
//
//	resume-token keygen --operator <id> --out <dir> --name <n>
//	resume-token mint --agent <id> --namespace <ns> --audience <aud> --trust-root <id> \
//	    --approval <ref> [--lifetime 10m] [--required-signatures 2] --out <file>
//	resume-token sign --token <file> --operator <id> --key <keyfile> [--out <file>]
//	resume-token request --token <file> [--idempotency-key <k>] [--out <file>]
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/auth"
)

// resumeRequest is the wire body fleet-manager's handleResume decodes. It is
// declared here rather than imported because the server is package main.
type resumeRequest struct {
	SchemaVersion  string           `json:"schema_version"`
	IdempotencyKey string           `json:"idempotency_key"`
	AgentID        string           `json:"agent_id"`
	Namespace      string           `json:"namespace"`
	Token          auth.ResumeToken `json:"token"`
	Timestamp      string           `json:"timestamp"`
}

// mintNonceBytes is the entropy a fresh nonce carries: twice the contract's
// floor, so a token is never near the rejection threshold.
const mintNonceBytes = 2 * auth.ResumeTokenMinNonceBytes

// issuedAtBackdate is how far before now issued_at is set, so a verifier
// whose clock trails the minting host still sees the token as valid.
const issuedAtBackdate = 30 * time.Second

func main() {
	if err := run(os.Args[1:], os.Stdout, time.Now); err != nil {
		fmt.Fprintln(os.Stderr, "resume-token:", err)
		os.Exit(1)
	}
}

func usage() error {
	return errors.New("usage: resume-token <keygen|mint|sign|request> [flags]")
}

// run dispatches one subcommand. Taking the clock lets tests pin time.
func run(args []string, stdout io.Writer, now func() time.Time) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "keygen":
		return runKeygen(args[1:], stdout)
	case "mint":
		return runMint(args[1:], stdout, now)
	case "sign":
		return runSign(args[1:], stdout, now)
	case "request":
		return runRequest(args[1:], stdout, now)
	case "-h", "--help", "help":
		fmt.Fprintln(stdout, usage().Error())
		return nil
	default:
		return fmt.Errorf("unknown subcommand %q: %v", args[0], usage())
	}
}

// ── keygen ───────────────────────────────────────────────────────────────────

func runKeygen(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("keygen", flag.ContinueOnError)
	operator := fs.String("operator", "", "operator identity the key attributes to (normatively a SPIFFE ID)")
	outDir := fs.String("out", "", "directory to write <name>.key and <name>.pub into")
	name := fs.String("name", "", "file stem for the key pair")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *operator == "" || *outDir == "" || *name == "" {
		return errors.New("keygen: --operator, --out and --name are required")
	}
	if strings.ContainsAny(*name, `/\`) {
		return errors.New("keygen: --name must be a file stem, not a path")
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("keygen: generate key: %w", err)
	}
	if err := os.MkdirAll(*outDir, 0o700); err != nil {
		return fmt.Errorf("keygen: create %s: %w", *outDir, err)
	}
	keyPath := filepath.Join(*outDir, *name+".key")
	pubPath := filepath.Join(*outDir, *name+".pub")
	if err := writeExclusive(keyPath, []byte(hex.EncodeToString(priv)+"\n"), 0o600); err != nil {
		return fmt.Errorf("keygen: %w", err)
	}
	if err := writeExclusive(pubPath, []byte(hex.EncodeToString(pub)+"\n"), 0o644); err != nil {
		return fmt.Errorf("keygen: %w", err)
	}

	entry := auth.OperatorKeyJSON{
		OperatorID: *operator,
		KeyID:      auth.ComputeKeyID(pub),
		PublicKey:  hex.EncodeToString(pub),
	}
	return writeJSON(stdout, entry)
}

// writeExclusive refuses to overwrite: a key file replaced by accident is a
// key an operator can no longer sign with, and nothing would say so.
func writeExclusive(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// ── mint ─────────────────────────────────────────────────────────────────────

func runMint(args []string, stdout io.Writer, now func() time.Time) error {
	fs := flag.NewFlagSet("mint", flag.ContinueOnError)
	agent := fs.String("agent", "", "agent id the token resumes; for a remote workload this is the registry pod name")
	namespace := fs.String("namespace", "", "namespace the agent runs in")
	audience := fs.String("audience", "", "fleet audience, fleet-manager's FLEET_AUDIENCE")
	trustRoot := fs.String("trust-root", "", "operator-key trust root, fleet-manager's OPERATOR_TRUST_ROOT_ID")
	approval := fs.String("approval", "", "governance approval reference, for example a change ticket")
	lifetime := fs.Duration("lifetime", 10*time.Minute, "validity window from issued_at to expires_at")
	required := fs.Int("required-signatures", 2, "distinct operator signatures the token itself demands")
	out := fs.String("out", "", "file to write the unsigned token to")
	if err := fs.Parse(args); err != nil {
		return err
	}
	for _, f := range []struct{ name, value string }{
		{"--agent", *agent}, {"--namespace", *namespace}, {"--audience", *audience},
		{"--trust-root", *trustRoot}, {"--approval", *approval}, {"--out", *out},
	} {
		if f.value == "" {
			return fmt.Errorf("mint: %s is required", f.name)
		}
	}
	if *required < 1 {
		return errors.New("mint: --required-signatures must be at least 1")
	}
	if *lifetime <= 0 {
		return errors.New("mint: --lifetime must be positive")
	}

	nonce := make([]byte, mintNonceBytes)
	if _, err := rand.Read(nonce); err != nil {
		return fmt.Errorf("mint: nonce: %w", err)
	}
	var id [12]byte
	if _, err := rand.Read(id[:]); err != nil {
		return fmt.Errorf("mint: token id: %w", err)
	}
	issued := now().UTC().Add(-issuedAtBackdate)
	token := auth.ResumeToken{
		SchemaVersion:         auth.FrozenSchemaVersion,
		TokenID:               "rt-" + hex.EncodeToString(id[:]),
		Algorithm:             auth.ResumeTokenAlgEd25519,
		AgentID:               *agent,
		Namespace:             *namespace,
		Audience:              *audience,
		GovernanceApprovalRef: *approval,
		IssuedAt:              issued.Format(time.RFC3339),
		ExpiresAt:             issued.Add(*lifetime).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString(nonce),
		TrustRootID:           *trustRoot,
		RequiredSignatures:    *required,
	}
	if err := writeFileJSON(*out, token, 0o600); err != nil {
		return fmt.Errorf("mint: %w", err)
	}
	fmt.Fprintf(stdout, "minted %s for %s/%s, expires %s, written to %s\n",
		token.TokenID, token.Namespace, token.AgentID, token.ExpiresAt, *out)
	return nil
}

// ── sign ─────────────────────────────────────────────────────────────────────

func runSign(args []string, stdout io.Writer, now func() time.Time) error {
	fs := flag.NewFlagSet("sign", flag.ContinueOnError)
	tokenPath := fs.String("token", "", "token file to sign")
	operator := fs.String("operator", "", "signing operator's identity, as registered with the key")
	keyPath := fs.String("key", "", "private key file written by keygen")
	out := fs.String("out", "", "file to write the signed token to (default: in place)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *tokenPath == "" || *operator == "" || *keyPath == "" {
		return errors.New("sign: --token, --operator and --key are required")
	}
	if *out == "" {
		*out = *tokenPath
	}

	token, err := readToken(*tokenPath)
	if err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	priv, err := readPrivateKey(*keyPath)
	if err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	signed, err := auth.SignResumeToken(token, *operator, priv, now().UTC())
	if err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	if err := signed.ValidateStructure(); err != nil {
		return fmt.Errorf("sign: signed token does not validate: %w", err)
	}
	if err := writeFileJSON(*out, signed, 0o600); err != nil {
		return fmt.Errorf("sign: %w", err)
	}
	fmt.Fprintf(stdout, "signed %s as %s (%d of %d signatures), written to %s\n",
		signed.TokenID, *operator, len(signed.Signatures), signed.RequiredSignatures, *out)
	return nil
}

// readPrivateKey accepts the hex 64-byte private key keygen writes, or a hex
// 32-byte seed from another tool.
func readPrivateKey(path string) (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, fmt.Errorf("%s: not hex: %w", path, err)
	}
	switch len(raw) {
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	default:
		return nil, fmt.Errorf("%s: %d bytes, want %d (private key) or %d (seed)",
			path, len(raw), ed25519.PrivateKeySize, ed25519.SeedSize)
	}
}

// ── request ──────────────────────────────────────────────────────────────────

func runRequest(args []string, stdout io.Writer, now func() time.Time) error {
	fs := flag.NewFlagSet("request", flag.ContinueOnError)
	tokenPath := fs.String("token", "", "signed token file")
	idem := fs.String("idempotency-key", "", "idempotency key (default resume-<agent>-<token_id>)")
	out := fs.String("out", "", "file to write the request body to (default: stdout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *tokenPath == "" {
		return errors.New("request: --token is required")
	}
	token, err := readToken(*tokenPath)
	if err != nil {
		return fmt.Errorf("request: %w", err)
	}
	if *idem == "" {
		*idem = fmt.Sprintf("resume-%s-%s", token.AgentID, token.TokenID)
	}
	req := resumeRequest{
		SchemaVersion:  auth.FrozenSchemaVersion,
		IdempotencyKey: *idem,
		AgentID:        token.AgentID,
		Namespace:      token.Namespace,
		Token:          token,
		Timestamp:      now().UTC().Format(time.RFC3339),
	}
	if *out == "" {
		return writeJSON(stdout, req)
	}
	return writeFileJSON(*out, req, 0o600)
}

// ── shared ───────────────────────────────────────────────────────────────────

func readToken(path string) (auth.ResumeToken, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return auth.ResumeToken{}, err
	}
	var token auth.ResumeToken
	if err := json.Unmarshal(data, &token); err != nil {
		return auth.ResumeToken{}, fmt.Errorf("%s: %w", path, err)
	}
	if token.TokenID == "" {
		return auth.ResumeToken{}, fmt.Errorf("%s: not a resume token (no token_id)", path)
	}
	return token, nil
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func writeFileJSON(path string, v any, mode os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), mode)
}
