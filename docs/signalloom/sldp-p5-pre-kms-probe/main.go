// SLDP-P5-PRE KMS signer prototype.
// Answers: does Witness (go-witness v0.8.4, the library behind the pinned witness 0.9.1 CLI)
// accept a KMS-backed signer, and can that signer produce what Signal Loom's segment
// attestor + verifier already require?
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/in-toto/go-witness/cryptoutil"
	"github.com/in-toto/go-witness/dsse"
	kms "github.com/in-toto/go-witness/signer/kms"
	awskms "github.com/in-toto/go-witness/signer/kms/aws"
	gcpkms "github.com/in-toto/go-witness/signer/kms/gcp"
)

func main() {
	ctx := context.Background()

	fmt.Println("## A. Does go-witness expose a KMS signer provider at all?")
	ksp := kms.New(kms.WithRef("gcpkms://projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1"))
	algs := (*gcpkms.SignerVerifier)(nil).SupportedAlgorithms()
	fmt.Printf("A1 gcpkms provider registered = %v\n", ksp != nil)
	fmt.Printf("A2 gcpkms algorithms  = %v\n", algs)
	fmt.Printf("A3 gcpkms contains ed25519 = %v\n", containsEd(algs))

	kspAWS := kms.New(kms.WithRef("awskms://key/abcd-1234"))
	algsAWS := (*awskms.SignerVerifier)(nil).SupportedAlgorithms()
	fmt.Printf("A4 awskms provider registered = %v\n", kspAWS != nil)
	fmt.Printf("A5 awskms algorithms  = %v\n", algsAWS)
	fmt.Printf("A6 awskms contains ed25519 = %v\n", containsEd(algsAWS))

	fmt.Println("\n## B. Is the KMS signer code path reachable without cloud credentials?")
	s, err := ksp.Signer(ctx)
	fmt.Printf("B1 gcpkms Signer(ctx) signer=%v\n", s)
	fmt.Printf("B2 gcpkms Signer(ctx) err=%v\n", err)
	sAWS, errS := kspAWS.Signer(ctx)
	fmt.Printf("B3 awskms Signer(ctx) signer=%v\n", sAWS)
	fmt.Printf("B4 awskms Signer(ctx) err=%v\n", errS)

	fmt.Println("\n## C. Unknown-scheme behaviour (fail-closed check)")
	bad := kms.New(kms.WithRef("azurekeyvault://vault/key"))
	_, errBad := bad.Signer(ctx)
	fmt.Printf("C1 azurekeyvault Signer(ctx) err=%v\n", errBad)

	fmt.Println("\n## D. Envelope compatibility: go-witness ed25519 signer vs Signal Loom's hand-rolled DSSE")
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	statement := map[string]any{
		"_type":         "https://in-toto.io/Statement/v1",
		"predicateType": "https://controlplane.io/attestations/signalloom-segment/v1",
		"subject":       []any{map[string]any{"name": "seg-0001", "digest": map[string]any{"sha256": strings.Repeat("a", 64)}}},
		"predicate":     map[string]any{"schema_version": "signalloom.segment/v1", "sequence": 1},
	}
	payload, _ := json.Marshal(statement)

	// Signal Loom's own construction (copied verbatim from store/segment_attestor.go).
	spki, _ := x509.MarshalPKIXPublicKey(pub)
	d := sha256.Sum256(spki)
	loomKeyID := hex.EncodeToString(d[:])
	pae := []byte(fmt.Sprintf("DSSEv1 %d %s %d %s", len("application/vnd.in-toto+json"), "application/vnd.in-toto+json", len(payload), payload))
	loomSig := base64.StdEncoding.EncodeToString(ed25519.Sign(priv, pae))
	fmt.Printf("D1 signalloom keyid  = %s\n", loomKeyID)
	fmt.Printf("D2 signalloom keyid len = %d (verify.go validDigest requires 64 hex)\n", len(loomKeyID))

	// go-witness construction over the identical payload.
	gwSigner := cryptoutil.NewED25519Signer(priv)
	env, err := dsse.Sign("application/vnd.in-toto+json", strings.NewReader(string(payload)), dsse.SignWithSigners(gwSigner))
	if err != nil {
		fmt.Printf("D3 go-witness dsse.Sign err=%v\n", err)
		return
	}
	gwKeyID := env.Signatures[0].KeyID
	gwSig := base64.StdEncoding.EncodeToString(env.Signatures[0].Signature)
	fmt.Printf("D4 go-witness keyid  = %s\n", gwKeyID)
	fmt.Printf("D5 go-witness keyid len = %d\n", len(gwKeyID))
	fmt.Printf("D6 KEYIDS MATCH        = %v\n", gwKeyID == loomKeyID)
	fmt.Printf("D7 SIGNATURES MATCH    = %v (ed25519 is deterministic, so equality proves identical PAE)\n", gwSig == loomSig)
	fmt.Printf("D8 go-witness payloadType = %q\n", env.PayloadType)

	// Would the repo's verifier accept the go-witness envelope?
	keyring := map[string]ed25519.PublicKey{loomKeyID: pub}
	k, known := keyring[gwKeyID]
	verified := known && ed25519.Verify(k, pae, mustB64(gwSig))
	fmt.Printf("D9 repo verify.go would accept go-witness envelope = %v (keyid known=%v)\n", verified, known)
}

func containsEd(a []string) bool {
	for _, x := range a {
		if strings.Contains(strings.ToLower(x), "ed25519") || strings.Contains(strings.ToLower(x), "eddsa") {
			return true
		}
	}
	return false
}

func mustB64(s string) []byte { b, _ := base64.StdEncoding.DecodeString(s); return b }
