// Command ed25519-keygen mints the Ed25519 keypairs the appliance needs, in
// the exact encodings openssl produced, from this repository's own source.
//
// It exists because the two keypairs the Makefile mints — the segment-signing
// witness key and the orbit approval key — were the only reason the appliance
// bundle needed openssl at all, and openssl cannot be pinned the way the five
// staged Go tools are: upstream publishes source tarballs only, no binaries.
// The requirement is far narrower than "openssl": generate an Ed25519 key,
// write its PKCS#8 private PEM and its SPKI public PEM, and derive a key ID.
// That is three calls into crypto/ed25519 and crypto/x509.
//
// Byte compatibility with openssl is structural, not coincidental. openssl
// genpkey -algorithm ed25519 emits a 46-byte PKCS#8 DER in a PRIVATE KEY PEM
// block — SEQUENCE { INTEGER 0, SEQUENCE { OID 1.3.101.112 },
// OCTET STRING [0420 || 32-byte seed] } — which is precisely what
// x509.MarshalPKCS8PrivateKey writes for an ed25519.PrivateKey. openssl pkey
// -pubout emits a 44-byte SPKI DER in a PUBLIC KEY PEM block, base64 beginning
// MCowBQYDK2VwAyEA, which is precisely x509.MarshalPKIXPublicKey. Both
// directions are proven by test/ed25519-keygen-interop.bats, which has openssl
// read a key this tool wrote and this tool read a key openssl wrote.
//
// Subcommands:
//
//	generate  mint a keypair, private PEM at 0600 and public PEM at 0644
//	key-id    print hex(sha256(SPKI DER)) for a public PEM
//
// generate REFUSES to overwrite either output. Every mint clause in the
// Makefile is guarded by `if [ ! -f ]` because re-minting a key invalidates
// everything a running cluster already trusts; the refusal makes that contract
// hold even when a caller forgets the guard.
//
// No private key material is ever printed, and no key is ever taken on argv —
// keys travel only as file paths, so nothing secret reaches shell history or
// /proc/<pid>/cmdline.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "ed25519-keygen:", err)
		os.Exit(1)
	}
}

func usage() error {
	return errors.New("usage: ed25519-keygen <generate|key-id> [flags]")
}

// run dispatches one subcommand.
func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "generate":
		return runGenerate(args[1:])
	case "key-id":
		return runKeyID(args[1:], stdout)
	case "-h", "--help", "help":
		fmt.Fprintln(stdout, usage().Error())
		return nil
	default:
		return fmt.Errorf("unknown subcommand %q: %v", args[0], usage())
	}
}

// ── generate ─────────────────────────────────────────────────────────────────

func runGenerate(args []string) error {
	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	keyPath := fs.String("key", "", "path to write the PKCS#8 private key PEM (mode 0600)")
	pubPath := fs.String("pub", "", "path to write the SPKI public key PEM (mode 0644)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *keyPath == "" || *pubPath == "" {
		return errors.New("generate requires --key and --pub")
	}
	if *keyPath == *pubPath {
		return fmt.Errorf("--key and --pub are the same path: %s", *keyPath)
	}

	// Refuse before generating, so a refusal never leaves a half-written pair.
	for _, p := range []string{*keyPath, *pubPath} {
		if _, err := os.Lstat(p); err == nil {
			return fmt.Errorf("refusing to overwrite existing file %s (keys are minted once; delete it deliberately to re-mint)", p)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("stat %s: %w", p, err)
		}
	}

	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("generate ed25519 key: %w", err)
	}

	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return fmt.Errorf("marshal PKCS#8 private key: %w", err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return fmt.Errorf("marshal SPKI public key: %w", err)
	}

	// Private half first and at 0600 from the instant it exists: writing then
	// chmod-ing would leave a window in which the seed is world-readable.
	if err := writeNew(*keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER}), 0o600); err != nil {
		return err
	}
	if err := writeNew(*pubPath, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER}), 0o644); err != nil {
		// A private key with no public half is worse than neither, because the
		// Makefile's `if [ ! -f <private> ]` guard would then skip the mint
		// forever and the missing public half would only surface downstream.
		_ = os.Remove(*keyPath)
		return err
	}
	return nil
}

// writeNew creates path with exactly mode, failing if it already exists.
// O_EXCL is what makes the refusal above race-free rather than advisory.
func writeNew(path string, content []byte, mode os.FileMode) error {
	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create directory %s: %w", dir, err)
		}
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	if _, err := f.Write(content); err != nil {
		f.Close()
		_ = os.Remove(path)
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(path)
		return fmt.Errorf("close %s: %w", path, err)
	}
	// O_CREATE applies the process umask to mode; set it explicitly so the
	// public key is 0644 even under a umask of 077.
	if err := os.Chmod(path, mode); err != nil {
		return fmt.Errorf("chmod %s: %w", path, err)
	}
	return nil
}

// ── key-id ───────────────────────────────────────────────────────────────────

// runKeyID prints hex(sha256(SPKI DER)), which is byte for byte what
//
//	openssl pkey -pubin -in <pub> -outform DER | openssl dgst -sha256
//
// produced, and what signal-ingest's store.DeriveKeyID computes for the same
// key. The three agreeing is what lets the segment-signing policy that pins a
// key ID keep its meaning across the switch away from openssl.
func runKeyID(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("key-id", flag.ContinueOnError)
	pubPath := fs.String("pub", "", "path to an SPKI public key PEM")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *pubPath == "" {
		return errors.New("key-id requires --pub")
	}

	raw, err := os.ReadFile(*pubPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", *pubPath, err)
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return fmt.Errorf("parse %s: no PEM block", *pubPath)
	}
	if block.Type != "PUBLIC KEY" {
		return fmt.Errorf("parse %s: PEM block is %q, not \"PUBLIC KEY\"", *pubPath, block.Type)
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse SPKI in %s: %w", *pubPath, err)
	}
	pub, ok := parsed.(ed25519.PublicKey)
	if !ok {
		return fmt.Errorf("%s holds a %T, not an Ed25519 public key", *pubPath, parsed)
	}

	// Re-marshal rather than hashing block.Bytes: that is what makes the
	// digest a property of the KEY and not of the file's encoding, so a
	// re-encoded but equivalent PEM yields the same ID.
	der, err := x509.MarshalPKIXPublicKey(pub)
	if err != nil {
		return fmt.Errorf("marshal SPKI public key: %w", err)
	}
	digest := sha256.Sum256(der)
	fmt.Fprintln(stdout, hex.EncodeToString(digest[:]))
	return nil
}
