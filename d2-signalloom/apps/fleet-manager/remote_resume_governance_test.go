package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
)

// ── Remote resume governance ─────────────────────────────────────────────────
//
// A remote resume used to need only the caller key's `resume` scope. That is
// a bearer credential deciding a dual-control question. These tests pin the
// remote branch to the same governance the local branch has: a dual-signed
// token bound to the registry pod name, single use in the replay ledger, an
// attested record when the engine is present, and no state change on any
// refusal.

const (
	remoteGovCluster   = "cluster-a"
	remoteGovNamespace = "tenant-a"
	remoteGovPod       = "remote-api-0"
	remoteGovOwner     = "remote-api"
)

// remoteDualSignedToken mints a token for the given target with the same
// reference operators liveDualSignedToken uses, so the registry it returns
// also knows a third, non-signing key.
func remoteDualSignedToken(t *testing.T, agentID, namespace string, signers int) (ResumeToken, *StaticOperatorKeyRegistry) {
	t.Helper()
	now := time.Now().UTC()
	alicePub, alicePriv := keyFromSeed(t, seedOperatorAlice)
	bobPub, bobPriv := keyFromSeed(t, seedOperatorBob)

	raw := ResumeToken{
		SchemaVersion:         FrozenSchemaVersion,
		TokenID:               "rt-remote-" + base64.RawURLEncoding.EncodeToString([]byte(now.Format(time.RFC3339Nano))),
		Algorithm:             ResumeTokenAlgEd25519,
		AgentID:               agentID,
		Namespace:             namespace,
		Audience:              "signalloom-fleet/local",
		GovernanceApprovalRef: "CHG-2026-10-04-0007",
		IssuedAt:              now.Add(-2 * time.Minute).Format(time.RFC3339),
		ExpiresAt:             now.Add(8 * time.Minute).Format(time.RFC3339),
		Nonce:                 base64.StdEncoding.EncodeToString([]byte("remote-resume-nonce!")),
		TrustRootID:           refTrustRoot,
		RequiredSignatures:    2,
	}
	token, err := SignResumeToken(raw, opAlice, alicePriv, now.Add(-2*time.Minute))
	if err != nil {
		t.Fatalf("alice sign: %v", err)
	}
	if signers > 1 {
		token, err = SignResumeToken(token, opBob, bobPriv, now.Add(-90*time.Second))
		if err != nil {
			t.Fatalf("bob sign: %v", err)
		}
	}
	reg := NewStaticOperatorKeyRegistry(
		OperatorKeyEntry{OperatorID: opAlice, KeyID: ComputeKeyID(alicePub), PublicKey: alicePub},
		OperatorKeyEntry{OperatorID: opBob, KeyID: ComputeKeyID(bobPub), PublicKey: bobPub},
	)
	return token, reg
}

// newRemoteGovernedServer is a hub with one stunned remote workload and the
// full governance surface installed.
func newRemoteGovernedServer(t *testing.T, reg OperatorKeyRegistry) (*server, RemoteStunRecord) {
	t.Helper()
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s := newTestServer(t)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor(remoteGovCluster, "node-a", remoteGovNamespace, remoteGovPod, remoteGovOwner, now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)
	s.keyRegistry = reg
	s.resumePolicy = dualPolicy()
	s.replayLedger = NewReplayLedger()
	stun := s.remoteStuns.Request(remoteGovCluster, remoteGovNamespace, remoteGovPod, "reason", "warden")
	return s, stun
}

func remoteResumeBody(t *testing.T, token ResumeToken, idempotencyKey string) string {
	t.Helper()
	req := ResumeRequest{
		SchemaVersion:  FrozenSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        remoteGovPod,
		Namespace:      remoteGovNamespace,
		Token:          token,
	}
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func postRemoteResume(t *testing.T, s *server, body string) (int, string) {
	t.Helper()
	response := call(t, s.routes(), http.MethodPost, "/api/v1/fleet/resume/"+remoteGovPod, body, "Bearer "+operatorRemoteKey)
	return response.Code, response.Body.String()
}

func remoteStateOf(t *testing.T, s *server) RemoteStunState {
	t.Helper()
	record, found := s.remoteStuns.Current(remoteGovCluster, remoteGovNamespace, remoteGovPod)
	if !found {
		t.Fatal("remote stun record vanished")
	}
	return record.State
}

func TestRemoteResume_WithoutToken_IsForbiddenAndChangesNothing(t *testing.T) {
	_, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, _ := newRemoteGovernedServer(t, reg)

	for _, body := range []string{`{}`, `{"agent_id":"remote-api-0"}`, `{"token":{}}`} {
		code, text := postRemoteResume(t, s, body)
		if code != http.StatusForbidden {
			t.Fatalf("body %s: status = %d, want 403: %s", body, code, text)
		}
		if !strings.Contains(text, "dual-signed resume token is required") {
			t.Fatalf("body %s: refusal does not say a token is required: %s", body, text)
		}
	}
	if got := remoteStateOf(t, s); got != RemoteStunRequested {
		t.Fatalf("state = %q after refused resumes, want %q", got, RemoteStunRequested)
	}
	if n := len(s.replayLedger.records); n != 0 {
		t.Fatalf("ledger recorded %d tokens on refused requests", n)
	}
}

func TestRemoteResume_DualSignedToken_IsAcceptedAndLedgered(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, stun := newRemoteGovernedServer(t, reg)

	var logBuf bytes.Buffer
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logBuf, nil)))
	defer slog.SetDefault(oldLogger)

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-remote-1"))
	if code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202: %s", code, text)
	}
	record := decodeRemoteStunRecord(t, text)
	if record.State != RemoteResumeRequested || record.ID != stun.ID {
		t.Fatalf("unexpected resume record: %#v", record)
	}

	rec, ok := s.replayLedger.records[token.TokenID]
	if !ok {
		t.Fatalf("ledger has no record for %s", token.TokenID)
	}
	if rec.IdempotencyKey != "idem-remote-1" || len(rec.OperatorIDs) != 2 {
		t.Fatalf("ledger record = %#v", rec)
	}

	// The audit line names the operators, not the caller key alone.
	if !strings.Contains(logBuf.String(), AgentResumeRequestedEventName) {
		t.Fatalf("no %s audit line:\n%s", AgentResumeRequestedEventName, logBuf.String())
	}
	if !strings.Contains(logBuf.String(), opAlice) || !strings.Contains(logBuf.String(), opBob) {
		t.Fatalf("audit line does not carry both operator ids:\n%s", logBuf.String())
	}
}

func TestRemoteResume_ReplayWithDifferentKey_IsConflict(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, _ := newRemoteGovernedServer(t, reg)

	if code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-first")); code != http.StatusAccepted {
		t.Fatalf("first: status = %d: %s", code, text)
	}
	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-second"))
	if code != http.StatusConflict {
		t.Fatalf("replay: status = %d, want 409: %s", code, text)
	}
}

func TestRemoteResume_SameIdempotencyKey_IsIdempotent(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, stun := newRemoteGovernedServer(t, reg)

	if code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-same")); code != http.StatusAccepted {
		t.Fatalf("first: status = %d: %s", code, text)
	}
	// The warden acts on the first request. A retry must not re-open it.
	mustAckRemoteStun(t, s.remoteStuns, stun.ID, RemoteResumed)

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-same"))
	if code != http.StatusAccepted {
		t.Fatalf("retry: status = %d, want 202: %s", code, text)
	}
	record := decodeRemoteStunRecord(t, text)
	if record.State != RemoteResumed || record.ID != stun.ID {
		t.Fatalf("retry returned %#v, want the acknowledged record unchanged", record)
	}
	if got := remoteStateOf(t, s); got != RemoteResumed {
		t.Fatalf("retry re-opened the record: state = %q", got)
	}
}

func TestRemoteResume_SingleSignature_IsForbidden(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 1)
	s, _ := newRemoteGovernedServer(t, reg)

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-single"))
	if code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", code, text)
	}
	if got := remoteStateOf(t, s); got != RemoteStunRequested {
		t.Fatalf("state = %q after a refused single-signature resume", got)
	}
	if n := len(s.replayLedger.records); n != 0 {
		t.Fatalf("ledger recorded %d tokens on a refused request", n)
	}
}

func TestRemoteResume_WrongNamespaceBinding_IsBadRequest(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, "tenant-b", 2)
	s, _ := newRemoteGovernedServer(t, reg)

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-ns"))
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", code, text)
	}
	if got := remoteStateOf(t, s); got != RemoteStunRequested {
		t.Fatalf("state = %q after a mis-bound resume", got)
	}
}

func TestRemoteResume_OwnerAliasStillBindsToPodName(t *testing.T) {
	// The caller may name the owner; the token must still name the pod.
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, stun := newRemoteGovernedServer(t, reg)
	body := remoteResumeBody(t, token, "idem-owner")
	body = strings.Replace(body, `"agent_id":"`+remoteGovPod+`"`, `"agent_id":"`+remoteGovOwner+`"`, 1)

	response := call(t, s.routes(), http.MethodPost, "/api/v1/fleet/resume/"+remoteGovOwner, body, "Bearer "+operatorRemoteKey)
	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202: %s", response.Code, response.Body.String())
	}
	if record := decodeRemoteStunRecord(t, response.Body.String()); record.ID != stun.ID {
		t.Fatalf("resumed %#v, want %s", record, stun.ID)
	}
}

func TestRemoteResume_NoStunRecord_Is404AndTokenNotConsumed(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, _ := newRemoteGovernedServer(t, reg)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: time.Now()})

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-404"))
	if code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404: %s", code, text)
	}
	if n := len(s.replayLedger.records); n != 0 {
		t.Fatalf("a 404 consumed the token")
	}
}

func TestRemoteResume_AttestedRecordNamesTheRemoteTarget(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, _ := newRemoteGovernedServer(t, reg)
	priv := ed25519.NewKeyFromSeed([]byte("remote resume attestation seed!!")[:ed25519.SeedSize])
	signer, err := attestation.NewLocalEd25519SignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	s.attestationEngine, err = attestation.NewAttestationEngine(signer, attestation.NewKeyHistoryStore(), "remote-resume-test")
	if err != nil {
		t.Fatal(err)
	}

	var logBuf bytes.Buffer
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logBuf, nil)))
	defer slog.SetDefault(oldLogger)

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-attested"))
	if code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202: %s", code, text)
	}

	found := false
	for _, line := range bytes.Split(logBuf.Bytes(), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal(line, &entry); err != nil || entry["event"] != ResumeDecisionEventName {
			continue
		}
		found = true
		if entry["remote"] != true || entry["cluster_id"] != remoteGovCluster || entry["namespace"] != remoteGovNamespace {
			t.Errorf("decision line lacks remote coordinates: %s", line)
		}
		if entry["token_id"] != token.TokenID {
			t.Errorf("decision line token_id = %v", entry["token_id"])
		}
		if digest, _ := entry["attested_record_digest"].(string); digest == "" {
			t.Errorf("decision line carries no attested digest: %s", line)
		}
	}
	if !found {
		t.Fatalf("no %s line in:\n%s", ResumeDecisionEventName, logBuf.String())
	}
}

func TestRemoteResume_LocalPathUnchangedWithGovernanceConfigured(t *testing.T) {
	baseline := newTestServer(t)
	localID := knownLocalAgentID(t, baseline)
	request := `{"agent_id":"` + localID + `"}`
	first := call(t, http.HandlerFunc(baseline.handleResume), http.MethodPost, "/api/v1/fleet/resume", request)

	_, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	governed, _ := newRemoteGovernedServer(t, reg)
	second := call(t, http.HandlerFunc(governed.handleResume), http.MethodPost, "/api/v1/fleet/resume", request)

	if second.Code != first.Code {
		t.Fatalf("local resume status changed from %d to %d under remote governance", first.Code, second.Code)
	}
	if got := remoteStateOf(t, governed); got != RemoteStunRequested {
		t.Fatalf("a local resume touched the remote record: %q", got)
	}
}

// A frozen pod leaves the registry as soon as the warden stops reporting it
// (a replaced pod, a report with no pods). The hold is still real, so a
// governed resume resolves through the stun record and is accepted.
func TestRemoteResume_RegistryEntryGone_ResolvesThroughTheHold(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, stun := newRemoteGovernedServer(t, reg)
	if _, err := s.remoteStuns.Ack(stun.ID, RemoteStunned, "node-a", "2026-10-04T10:00:05Z"); err != nil {
		t.Fatal(err)
	}
	// An empty report from the node drops the pod from the registry.
	empty := workloadReportFor(remoteGovCluster, "node-a", remoteGovNamespace, remoteGovPod, remoteGovOwner, time.Date(2026, 10, 4, 10, 1, 0, 0, time.UTC))
	empty.Pods = nil
	if _, _, err := s.workloads.Apply(empty); err != nil {
		t.Fatal(err)
	}
	if got := s.workloads.ByPodName(remoteGovPod); len(got) != 0 {
		t.Fatalf("registry still lists the pod: %+v", got)
	}

	code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-gone-1"))
	if code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202 via the hold: %s", code, text)
	}
	record := decodeRemoteStunRecord(t, text)
	if record.State != RemoteResumeRequested || record.ID != stun.ID {
		t.Fatalf("unexpected record: %#v", record)
	}
	// A name with no standing hold still 404s (TestRemoteResume_NoStunRecord_Is404AndTokenNotConsumed).
}

// With the registry entry gone and the resume already requested, a replay of
// the same token must still answer 409 from the ledger, not 404.
func TestRemoteResume_RegistryEntryGone_ReplayIsStillConflict(t *testing.T) {
	token, reg := remoteDualSignedToken(t, remoteGovPod, remoteGovNamespace, 2)
	s, _ := newRemoteGovernedServer(t, reg)
	if code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-replay-1")); code != http.StatusAccepted {
		t.Fatalf("first resume: %d %s", code, text)
	}
	empty := workloadReportFor(remoteGovCluster, "node-a", remoteGovNamespace, remoteGovPod, remoteGovOwner, time.Date(2026, 10, 4, 10, 1, 0, 0, time.UTC))
	empty.Pods = nil
	if _, _, err := s.workloads.Apply(empty); err != nil {
		t.Fatal(err)
	}
	if code, text := postRemoteResume(t, s, remoteResumeBody(t, token, "idem-replay-2")); code != http.StatusConflict {
		t.Fatalf("replay with the registry empty: %d, want 409: %s", code, text)
	}
}
