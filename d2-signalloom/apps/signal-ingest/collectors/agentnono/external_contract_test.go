package agentnono

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile("fixtures/contracts/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func testBinding() TrustedHostBinding {
	seed := make([]byte, ed25519.SeedSize)
	for index := range seed {
		seed[index] = byte(index)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	return TrustedHostBinding{AgentID: "agentmaxxing-linux-001", HostID: "amx-host-001", KeyID: "host-key:001", PublicKey: privateKey.Public().(ed25519.PublicKey)}
}

func TestRealEd25519FixtureAndBinding(t *testing.T) {
	upload, ack, err := VerifyHostUploadAcknowledgement(fixture(t, "valid-upload.v1.json"), testBinding(), "accepted")
	if err != nil {
		t.Fatal(err)
	}
	if upload.ReplayKey != upload.AssertionEnvelope.PayloadSHA256 {
		t.Fatal("replay key and signed digest diverged")
	}
	if ack.HostSignatureState != "host-signature-verified" || ack.OriginalChainState != "original-chain-not-verified" {
		t.Fatalf("upload acknowledgement overclaims evidence: %#v", ack)
	}
	canonical, err := CanonicalSigningBytes(*upload)
	if err != nil {
		t.Fatal(err)
	}
	expected := fixture(t, "valid-upload.v1.canonical.json")
	expected = []byte(strings.TrimSuffix(string(expected), "\n"))
	if string(canonical) != string(expected) {
		t.Fatal("canonical signing bytes drifted")
	}
	if _, err := VerifyHostUpload(fixture(t, "tampered-upload.v1.json"), testBinding()); err == nil {
		t.Fatal("schema-valid signed payload mutation accepted")
	}
	if _, _, err := VerifyHostUploadAcknowledgement(fixture(t, "tampered-upload.v1.json"), testBinding(), "accepted"); err == nil {
		t.Fatal("tampered upload received host-signature-verified acknowledgement")
	}
	if _, err := VerifyHostUpload(fixture(t, "valid-artifact-upload.v1.json"), testBinding()); err != nil {
		t.Fatalf("bounded artifact vector rejected: %v", err)
	}
	if _, err := VerifyHostUpload(fixture(t, "malformed-oversize-artifact.v1.json"), testBinding()); err == nil {
		t.Fatal("oversize artifact accepted")
	}
	if _, err := VerifyHostUpload(fixture(t, "malformed-signature-alias.v1.json"), testBinding()); err == nil {
		t.Fatal("non-canonical signature alias accepted")
	}
}

func TestTrustedRegistrationBindingMatrix(t *testing.T) {
	valid := fixture(t, "valid-upload.v1.json")
	for name, mutate := range map[string]func(*TrustedHostBinding){
		"agent":      func(value *TrustedHostBinding) { value.AgentID = "other-agent" },
		"host":       func(value *TrustedHostBinding) { value.HostID = "other-host" },
		"key id":     func(value *TrustedHostBinding) { value.KeyID = "host-key:002" },
		"public key": func(value *TrustedHostBinding) { value.PublicKey = make(ed25519.PublicKey, ed25519.PublicKeySize) },
	} {
		t.Run(name, func(t *testing.T) {
			binding := testBinding()
			mutate(&binding)
			if _, err := VerifyHostUpload(valid, binding); err == nil {
				t.Fatal("untrusted registration binding accepted")
			}
		})
	}
}

func TestUploadMutationMatrix(t *testing.T) {
	base := fixture(t, "valid-upload.v1.json")
	mutations := map[string]func(map[string]any){
		"tenant injection": func(value map[string]any) { value["tenant_id"] = "attacker" },
		"upload too long":  func(value map[string]any) { value["upload_id"] = strings.Repeat("a", 129) },
		"reversed range":   func(value map[string]any) { value["sequence_start"], value["sequence_end"] = 2.0, 1.0 },
		"count mismatch":   func(value map[string]any) { value["sequence_end"] = 1.0 },
		"receipt authority injection": func(value map[string]any) {
			value["original_chain_reference"].(map[string]any)["authority"] = IntegrityAuthority
		},
		"receipt state injection": func(value map[string]any) {
			value["original_chain_reference"].(map[string]any)["state"] = "integrity-verified"
		},
		"receipt count zero": func(value map[string]any) { value["original_chain_reference"].(map[string]any)["event_count"] = 0.0 },
		"invalid timestamp": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["observed_at"] = "yesterday"
		},
		"binding mismatch": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["host_id"] = "other-host"
		},
		"sequence gap": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["sequence"] = 1.0
		},
		"bad source": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["source"] = "unknown"
		},
		"server source": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["source"] = "signal-ingest"
		},
		"verified inbound integrity": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["integrity_state"] = "integrity-verified"
		},
		"unknown attribute": func(value map[string]any) {
			value["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)["attributes"].(map[string]any)["path"] = "/secret"
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			var value map[string]any
			if err := json.Unmarshal(base, &value); err != nil {
				t.Fatal(err)
			}
			mutate(value)
			data, _ := json.Marshal(value)
			if _, err := VerifyHostUpload(data, testBinding()); err == nil {
				t.Fatal("mutation accepted")
			}
		})
	}
}

func TestTimestampWireGrammar(t *testing.T) {
	base := fixture(t, "valid-upload.v1.json")
	for _, value := range []string{
		"2026-09-13t10:00:00Z",
		"2026-09-13T10:00:00z",
		"2026-09-13 10:00:00Z",
		"2026-09-13T10:00:00.1234567890Z",
	} {
		data := bytes.Replace(base, []byte("2026-09-13T10:00:00Z"), []byte(value), 1)
		if _, err := DecodeExternalUpload(data); err == nil {
			t.Fatalf("invalid timestamp %q accepted", value)
		}
	}
	valid := bytes.Replace(base, []byte("2026-09-13T10:00:00Z"), []byte("2026-09-13T11:00:00+01:00"), 1)
	if _, err := DecodeExternalUpload(valid); err != nil {
		t.Fatalf("valid numeric timezone offset rejected: %v", err)
	}
}

func TestRequiredKeysAndDuplicateKeysAreRejectedRecursively(t *testing.T) {
	base := fixture(t, "valid-upload.v1.json")
	mutations := map[string][]byte{
		"missing zero root scalar": bytes.Replace(base, []byte(`"sequence_start":0,`), nil, 1),
		"missing envelope scalar":  bytes.Replace(base, []byte(`,"algorithm":"Ed25519"`), nil, 1),
		"missing evidence scalar":  bytes.Replace(base, []byte(`"sequence":0,`), nil, 1),
		"missing attribute scalar": bytes.Replace(base, []byte(`,"decision":"allowed"`), nil, 1),
		"missing reference scalar": bytes.Replace(base, []byte(`"event_count":1,`), nil, 1),
		"null root scalar":         bytes.Replace(base, []byte(`"sequence_start":0`), []byte(`"sequence_start":null`), 1),
		"null evidence scalar":     bytes.Replace(base, []byte(`"sequence":0`), []byte(`"sequence":null`), 1),
		"duplicate root key":       bytes.Replace(base, []byte(`"upload_id":`), []byte(`"upload_id":"duplicate-upload-0001","upload_id":`), 1),
		"duplicate nested key":     bytes.Replace(base, []byte(`"decision":`), []byte(`"decision":"denied","decision":`), 1),
		"escaped duplicate key":    bytes.Replace(base, []byte(`"upload_id":`), []byte(`"\u0075pload_id":"duplicate-upload-0001","upload_id":`), 1),
		"unknown envelope key":     bytes.Replace(base, []byte(`"format":`), []byte(`"private_path":"/secret","format":`), 1),
		"aliased envelope key":     bytes.Replace(base, []byte(`"algorithm":`), []byte(`"ALGORITHM":`), 1),
		"unknown evidence key":     bytes.Replace(base, []byte(`"observed_at":`), []byte(`"private_path":"/secret","observed_at":`), 1),
		"aliased evidence key":     bytes.Replace(base, []byte(`"observed_at":`), []byte(`"OBSERVED_AT":`), 1),
		"unknown attribute key":    bytes.Replace(base, []byte(`"destination_id":`), []byte(`"private_path":"/secret","destination_id":`), 1),
		"aliased attribute key":    bytes.Replace(base, []byte(`"decision":`), []byte(`"DECISION":`), 1),
		"unknown reference key":    bytes.Replace(base, []byte(`"event_count":`), []byte(`"private_path":"/secret","event_count":`), 1),
		"aliased reference key":    bytes.Replace(base, []byte(`"event_count":`), []byte(`"EVENT_COUNT":`), 1),
	}
	for name, data := range mutations {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeExternalUpload(data); err == nil {
				t.Fatal("ambiguous or incomplete JSON accepted")
			}
		})
	}
}

func TestSignedCaseAliasedRootKeysAreRejected(t *testing.T) {
	base := bytes.TrimSuffix(fixture(t, "valid-upload.v1.json"), []byte("\n"))
	data := append(append([]byte{}, base[:len(base)-1]...), []byte(`,"UPLOAD_ID":"secret-private-path","Upload_id":"upload-0000000001"}`)...)
	if _, err := VerifyHostUpload(data, testBinding()); err == nil {
		t.Fatal("signed upload with case-aliased root keys accepted")
	}
}

func TestClosedAttributeObjectsRejectUnknownKeys(t *testing.T) {
	for _, name := range []string{"process", "artifact", "network", "collection-limit"} {
		t.Run(name, func(t *testing.T) {
			var payload map[string]any
			fixtureName := "valid-upload.v1.json"
			if name == "artifact" {
				fixtureName = "valid-artifact-upload.v1.json"
			}
			if err := json.Unmarshal(fixture(t, fixtureName), &payload); err != nil {
				t.Fatal(err)
			}
			evidence := payload["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)
			if name == "process" {
				evidence["evidence_type"] = "process"
				evidence["attributes"] = map[string]any{"health_state": "running", "cpu_time_ms": 0.0, "resident_memory_bytes": 0.0, "exit_code": nil, "restart_count": 0.0}
			} else if name == "collection-limit" {
				evidence["evidence_type"] = "collection-limit"
				evidence["observation_state"] = "unobserved"
				evidence["attributes"] = map[string]any{"reason_code": "oversize", "max_file_size_bytes": 16777216.0, "max_files_per_window": 120.0, "max_bytes_per_window": 67108864.0, "window_seconds": 60.0}
			}
			evidence["attributes"].(map[string]any)["private_path"] = "/secret"
			data, _ := json.Marshal(payload)
			if _, err := DecodeExternalUpload(data); err == nil {
				t.Fatal("closed attribute object accepted unknown key")
			}
		})
	}
}

func TestCanonicalInputLexicalContract(t *testing.T) {
	base := fixture(t, "valid-upload.v1.json")
	for name, data := range map[string][]byte{
		"fractional integer": bytes.Replace(base, []byte(`"sequence":0`), []byte(`"sequence":0.0`), 1),
		"exponent integer":   bytes.Replace(base, []byte(`"sequence":0`), []byte(`"sequence":0e0`), 1),
		"negative zero":      bytes.Replace(base, []byte(`"sequence":0`), []byte(`"sequence":-0`), 1),
		"unsafe integer":     bytes.Replace(base, []byte(`"sequence":0`), []byte(`"sequence":9007199254740992`), 1),
		"non ASCII value":    bytes.Replace(base, []byte(`"host-sensor-v1"`), []byte(`"host-sensör-v1"`), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeExternalUpload(data); err == nil {
				t.Fatal("non-canonical lexical form accepted")
			}
		})
	}

	var reordered map[string]any
	if err := json.Unmarshal(base, &reordered); err != nil {
		t.Fatal(err)
	}
	reorderedBytes, err := json.Marshal(reordered)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyHostUpload(reorderedBytes, testBinding()); err != nil {
		t.Fatalf("key reordering changed canonical signature: %v", err)
	}
	escapedKey := bytes.Replace(base, []byte(`"upload_id"`), []byte(`"\u0075pload_id"`), 1)
	if _, err := VerifyHostUpload(escapedKey, testBinding()); err != nil {
		t.Fatalf("equivalent escaped ASCII key changed canonical signature: %v", err)
	}
}

func TestProcessExitCodeIsRequiredAndNullable(t *testing.T) {
	var payload map[string]any
	if err := json.Unmarshal(fixture(t, "valid-upload.v1.json"), &payload); err != nil {
		t.Fatal(err)
	}
	evidence := payload["assertion_envelope"].(map[string]any)["assertions"].([]any)[0].(map[string]any)
	evidence["evidence_type"] = "process"
	evidence["attributes"] = map[string]any{"health_state": "running", "cpu_time_ms": float64(0), "resident_memory_bytes": float64(0), "exit_code": nil, "restart_count": float64(0)}
	valid, _ := json.Marshal(payload)
	if _, err := DecodeExternalUpload(valid); err != nil {
		t.Fatalf("required null exit_code rejected: %v", err)
	}
	delete(evidence["attributes"].(map[string]any), "exit_code")
	missing, _ := json.Marshal(payload)
	if _, err := DecodeExternalUpload(missing); err == nil {
		t.Fatal("missing process exit_code accepted")
	}
}

func TestArtifactMtimeUsesBoundedUint64DecimalString(t *testing.T) {
	base := fixture(t, "valid-artifact-upload.v1.json")
	for _, value := range []string{"18446744073709551616", "01", "1.0"} {
		data := bytes.Replace(base, []byte(`"mtime_ns":"1"`), []byte(`"mtime_ns":"`+value+`"`), 1)
		if _, err := DecodeExternalUpload(data); err == nil {
			t.Fatalf("invalid mtime_ns %q accepted", value)
		}
	}
	maximum := bytes.Replace(base, []byte(`"mtime_ns":"1"`), []byte(`"mtime_ns":"18446744073709551615"`), 1)
	if _, err := DecodeExternalUpload(maximum); err != nil {
		t.Fatalf("uint64 maximum mtime_ns rejected: %v", err)
	}
}

func TestServerIntegrityResultIsGoOwned(t *testing.T) {
	verifier := NewAuditVerifier(VerifierConfig{RequireSignature: false})
	event := &NonoAuditEvent{Timestamp: time.Date(2026, 9, 13, 10, 0, 0, 0, time.UTC), AuditSessionID: "session-003", AgentID: "agentmaxxing-linux-001", SPIFFEID: "spiffe://signalloom.demo/agent/001", EventType: "exec", Digest: strings.Repeat("0", 64)}
	result, err := VerifyOriginalChain(verifier, LocalChainInput{ExpectedSessionID: event.AuditSessionID, Finalized: true, Events: []*NonoAuditEvent{event}}, event.Timestamp)
	if err != nil {
		t.Fatal(err)
	}
	if result.Authority != IntegrityAuthority || result.State != "tampered" || result.Reason != "event-tampered" || result.EventCount != 1 || result.FinalDigest == nil {
		t.Fatalf("unexpected server integrity result: %#v", result)
	}
	for name, input := range map[string]LocalChainInput{
		"empty":         {ExpectedSessionID: event.AuditSessionID, Finalized: true},
		"not finalized": {ExpectedSessionID: event.AuditSessionID, Events: []*NonoAuditEvent{event}},
		"over cap":      {ExpectedSessionID: event.AuditSessionID, Finalized: true, Events: make([]*NonoAuditEvent, 100001)},
	} {
		t.Run(name, func(t *testing.T) {
			got, err := VerifyOriginalChain(verifier, input, event.Timestamp)
			if err != nil {
				t.Fatal(err)
			}
			if got.State != "unavailable" || got.FinalDigest != nil || got.EventCount != 0 {
				t.Fatalf("expected unavailable, got %#v", got)
			}
		})
	}
	got, err := VerifyOriginalChain(nil, LocalChainInput{ExpectedSessionID: event.AuditSessionID, Finalized: true, Events: []*NonoAuditEvent{event}}, event.Timestamp)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != "unavailable" || got.FinalDigest != nil || got.EventCount != 0 {
		t.Fatalf("nil verifier must be unavailable: %#v", got)
	}
	if _, err := VerifyOriginalChain(verifier, LocalChainInput{ExpectedSessionID: "bad/session", Finalized: true, Events: []*NonoAuditEvent{event}}, event.Timestamp); err == nil {
		t.Fatal("invalid expected session identifier did not return an error")
	}
}

func TestLocalFinalizedChainCanBeIndependentlyVerified(t *testing.T) {
	kp, err := GenerateTestKeypair("spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced")
	if err != nil {
		t.Fatal(err)
	}
	verifier := NewAuditVerifier(VerifierConfig{TrustDomain: DefaultTrustDomain, TrustBundlePEM: []byte(kp.CACertPEM)})
	events, err := GenerateSignedSession(kp, "session-verified-001", 3, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	result, err := VerifyOriginalChain(verifier, LocalChainInput{ExpectedSessionID: "session-verified-001", Finalized: true, Events: events}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if result.State != "integrity-verified" || result.Reason != "verified" || result.EventCount != 3 || result.FinalDigest == nil {
		t.Fatalf("trusted finalized chain was not independently verified: %#v", result)
	}
}

func TestLocalChainRejectsMissingLaterPredecessorDigest(t *testing.T) {
	kp, err := GenerateTestKeypair("spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced")
	if err != nil {
		t.Fatal(err)
	}
	events, err := GenerateSignedSession(kp, "session-missing-prev-001", 2, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	events[1].PrevDigest = ""
	payload := events[1].CanonicalPayload()
	digest := sha256.Sum256(payload)
	events[1].Digest = hex.EncodeToString(digest[:])
	events[1].Signature, err = kp.SignPayload(payload)
	if err != nil {
		t.Fatal(err)
	}
	events[1].SignatureGitOID = ComputeGitOID(payload)
	verifier := NewAuditVerifier(VerifierConfig{TrustDomain: DefaultTrustDomain, TrustBundlePEM: []byte(kp.CACertPEM)})
	result, err := VerifyOriginalChain(verifier, LocalChainInput{ExpectedSessionID: "session-missing-prev-001", Finalized: true, Events: events}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if result.State != "tampered" || result.Reason != "chain-continuity-failed" {
		t.Fatalf("missing predecessor was not rejected as continuity failure: %#v", result)
	}
}
