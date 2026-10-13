package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

type remoteStunTestClock struct {
	current time.Time
}

func (c *remoteStunTestClock) Now() time.Time {
	return c.current
}

func (c *remoteStunTestClock) Advance(d time.Duration) {
	c.current = c.current.Add(d)
}

func newRemoteStunTestStore(clock *remoteStunTestClock) *RemoteStunStore {
	next := 0
	return NewRemoteStunStore(clock.Now, func() string {
		next++
		return fmt.Sprintf("rstun-%016x", next)
	})
}

func mustAckRemoteStun(t *testing.T, store *RemoteStunStore, id string, state RemoteStunState) RemoteStunRecord {
	t.Helper()
	record, err := store.Ack(id, state, "node-a.example", "2026-10-04T10:01:00Z")
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func remoteRecordInState(t *testing.T, state RemoteStunState) (*RemoteStunStore, RemoteStunRecord) {
	t.Helper()
	clock := &remoteStunTestClock{current: time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)}
	store := newRemoteStunTestStore(clock)
	record := store.Request("cluster-a", "tenant-a", "api-0", "contain", "operator")
	switch state {
	case RemoteStunRequested:
	case RemoteStunned:
		record = mustAckRemoteStun(t, store, record.ID, RemoteStunned)
	case RemoteResumeRequested:
		var err error
		record, err = store.RequestResume("cluster-a", "tenant-a", "api-0", "operator")
		if err != nil {
			t.Fatal(err)
		}
	case RemoteResumed:
		var err error
		record, err = store.RequestResume("cluster-a", "tenant-a", "api-0", "operator")
		if err != nil {
			t.Fatal(err)
		}
		record = mustAckRemoteStun(t, store, record.ID, RemoteResumed)
	default:
		t.Fatalf("unsupported test state %q", state)
	}
	return store, record
}

func TestRemoteStunRequestStateTable(t *testing.T) {
	t.Run("no record creates a request", func(t *testing.T) {
		clock := &remoteStunTestClock{current: time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)}
		store := newRemoteStunTestStore(clock)
		record := store.Request("cluster-a", "tenant-a", "api-0", "reason-a", "alice")
		if record.State != RemoteStunRequested || record.ID != "rstun-0000000000000001" {
			t.Fatalf("unexpected record: %#v", record)
		}
		if record.AckedNode != "" || record.AckedAt != "" {
			t.Fatalf("new request retained acknowledgement: %#v", record)
		}
	})

	t.Run("stun requested is idempotent", func(t *testing.T) {
		store, original := remoteRecordInState(t, RemoteStunRequested)
		got := store.Request("cluster-a", "tenant-a", "api-0", "changed", "bob")
		if !reflect.DeepEqual(got, original) {
			t.Fatalf("idempotent request changed record:\n got %#v\nwant %#v", got, original)
		}
	})

	t.Run("stunned is idempotent", func(t *testing.T) {
		store, original := remoteRecordInState(t, RemoteStunned)
		got := store.Request("cluster-a", "tenant-a", "api-0", "changed", "bob")
		if !reflect.DeepEqual(got, original) {
			t.Fatalf("re-stun changed contained record:\n got %#v\nwant %#v", got, original)
		}
	})

	t.Run("stun wins over resume request", func(t *testing.T) {
		store, original := remoteRecordInState(t, RemoteResumeRequested)
		store.mu.Lock()
		key := store.byID[original.ID]
		withAck := store.records[key]
		withAck.AckedNode = "stale-node"
		withAck.AckedAt = "2026-10-04T10:02:00Z"
		store.records[key] = withAck
		store.mu.Unlock()

		got := store.Request("cluster-a", "tenant-a", "api-0", "new containment", "bob")
		if got.State != RemoteStunRequested {
			t.Fatalf("state = %q, want %q", got.State, RemoteStunRequested)
		}
		if got.ID != original.ID {
			t.Fatalf("id = %q, want retained %q", got.ID, original.ID)
		}
		if got.Reason != "new containment" || got.RequestedBy != "bob" {
			t.Fatalf("request fields not refreshed: %#v", got)
		}
		if got.AckedNode != "" || got.AckedAt != "" {
			t.Fatalf("acknowledgement was not cleared: %#v", got)
		}
	})

	t.Run("resumed creates a replacement", func(t *testing.T) {
		store, original := remoteRecordInState(t, RemoteResumed)
		got := store.Request("cluster-a", "tenant-a", "api-0", "again", "bob")
		if got.State != RemoteStunRequested {
			t.Fatalf("state = %q, want %q", got.State, RemoteStunRequested)
		}
		if got.ID == original.ID {
			t.Fatalf("replacement retained old id %q", got.ID)
		}
		if _, found := store.ByID(original.ID); found {
			t.Fatalf("old id %q remained indexed", original.ID)
		}
		if got.AckedNode != "" || got.AckedAt != "" {
			t.Fatalf("replacement retained acknowledgement: %#v", got)
		}
	})
}

func TestRemoteStunResumeStateTable(t *testing.T) {
	t.Run("no record", func(t *testing.T) {
		clock := &remoteStunTestClock{current: time.Now()}
		store := newRemoteStunTestStore(clock)
		_, err := store.RequestResume("cluster-a", "tenant-a", "api-0", "alice")
		if !errors.Is(err, ErrRemoteStunNotFound) {
			t.Fatalf("error = %v, want ErrRemoteStunNotFound", err)
		}
	})

	tests := []struct {
		name       string
		from       RemoteStunState
		want       RemoteStunState
		idempotent bool
	}{
		{name: "stun requested", from: RemoteStunRequested, want: RemoteResumeRequested},
		{name: "stunned", from: RemoteStunned, want: RemoteResumeRequested},
		{name: "resume requested", from: RemoteResumeRequested, want: RemoteResumeRequested, idempotent: true},
		{name: "resumed", from: RemoteResumed, want: RemoteResumed, idempotent: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store, original := remoteRecordInState(t, test.from)
			got, err := store.RequestResume("cluster-a", "tenant-a", "api-0", "bob")
			if err != nil {
				t.Fatal(err)
			}
			if got.State != test.want {
				t.Fatalf("state = %q, want %q", got.State, test.want)
			}
			if got.ID != original.ID {
				t.Fatalf("id = %q, want retained %q", got.ID, original.ID)
			}
			if test.idempotent && !reflect.DeepEqual(got, original) {
				t.Fatalf("idempotent resume changed record:\n got %#v\nwant %#v", got, original)
			}
			if !test.idempotent {
				if got.RequestedBy != "bob" {
					t.Fatalf("requested_by = %q, want bob", got.RequestedBy)
				}
				if got.AckedNode != "" || got.AckedAt != "" {
					t.Fatalf("resume did not clear acknowledgement: %#v", got)
				}
			}
		})
	}
}

func TestRemoteStunAckTransitionTable(t *testing.T) {
	tests := []struct {
		name         string
		from         RemoteStunState
		attempt      RemoteStunState
		want         RemoteStunState
		wantConflict bool
	}{
		{name: "stun requested to stunned", from: RemoteStunRequested, attempt: RemoteStunned, want: RemoteStunned},
		{name: "stun requested cannot resume", from: RemoteStunRequested, attempt: RemoteResumed, wantConflict: true},
		{name: "stunned cannot stun again", from: RemoteStunned, attempt: RemoteStunned, wantConflict: true},
		{name: "stunned cannot resume without request", from: RemoteStunned, attempt: RemoteResumed, wantConflict: true},
		{name: "resume requested cannot stun", from: RemoteResumeRequested, attempt: RemoteStunned, wantConflict: true},
		{name: "resume requested to resumed", from: RemoteResumeRequested, attempt: RemoteResumed, want: RemoteResumed},
		{name: "resumed cannot stun", from: RemoteResumed, attempt: RemoteStunned, wantConflict: true},
		{name: "resumed cannot resume again", from: RemoteResumed, attempt: RemoteResumed, wantConflict: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			store, original := remoteRecordInState(t, test.from)
			got, err := store.Ack(original.ID, test.attempt, "node-a.example", "2026-10-04T10:05:00Z")
			if test.wantConflict {
				if !errors.Is(err, ErrRemoteStunAckConflict) {
					t.Fatalf("error = %v, want conflict", err)
				}
				if !strings.Contains(err.Error(), string(test.from)) || !strings.Contains(err.Error(), string(test.attempt)) {
					t.Fatalf("conflict does not name both states: %v", err)
				}
				unchanged, found := store.ByID(original.ID)
				if !found || !reflect.DeepEqual(unchanged, original) {
					t.Fatalf("rejected transition changed record: %#v", unchanged)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.State != test.want {
				t.Fatalf("state = %q, want %q", got.State, test.want)
			}
			if got.ID != original.ID {
				t.Fatalf("ack changed id from %q to %q", original.ID, got.ID)
			}
			if got.AckedNode != "node-a.example" || got.AckedAt != "2026-10-04T10:05:00Z" {
				t.Fatalf("ack fields = %#v", got)
			}
		})
	}
}

func TestRemoteStunAckValidation(t *testing.T) {
	clock := &remoteStunTestClock{current: time.Now()}
	store := newRemoteStunTestStore(clock)
	record := store.Request("cluster-a", "tenant-a", "api-0", "reason", "alice")

	tests := []struct {
		name  string
		id    string
		state RemoteStunState
		node  string
		at    string
		want  error
	}{
		{name: "unknown id", id: "rstun-missing", state: RemoteStunned, node: "node-a", at: "2026-10-04T10:00:00Z", want: ErrRemoteStunNotFound},
		{name: "bad state", id: record.ID, state: RemoteStunRequested, node: "node-a", at: "2026-10-04T10:00:00Z", want: ErrRemoteStunBadAckState},
		{name: "bad node", id: record.ID, state: RemoteStunned, node: "NODE A", at: "2026-10-04T10:00:00Z", want: ErrRemoteStunBadAck},
		{name: "bad timestamp", id: record.ID, state: RemoteStunned, node: "node-a", at: "yesterday", want: ErrRemoteStunBadAck},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := store.Ack(test.id, test.state, test.node, test.at)
			if !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
		})
	}
}

func newRemoteWorkloadRegistry(t *testing.T, now time.Time, reports ...WorkloadReport) *WorkloadRegistry {
	t.Helper()
	registry := NewWorkloadRegistry(DefaultFleetReportInterval, func() time.Time { return now })
	for _, report := range reports {
		if _, _, err := registry.Apply(report); err != nil {
			t.Fatal(err)
		}
	}
	return registry
}

func workloadReportFor(cluster, node, namespace, pod, owner string, now time.Time) WorkloadReport {
	return WorkloadReport{
		ClusterID:             cluster,
		Node:                  node,
		ReportedAt:            now.UTC().Format(time.RFC3339),
		ReportIntervalSeconds: 60,
		Pods: []ReportedPod{{
			Namespace: namespace,
			Name:      pod,
			UID:       cluster + "-" + pod,
			Owner: ReportedPodOwner{
				Kind: "Deployment",
				Name: owner,
			},
			Tenant: namespace,
		}},
	}
}

func TestResolveRemoteTargetForms(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	registry := newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "api-7d6-abc", "api", now),
	)
	s := &server{workloads: registry}

	tests := []struct {
		name      string
		requested string
		wantBy    string
	}{
		{name: "pod name", requested: "api-7d6-abc", wantBy: remoteResolvedByPodName},
		{name: "key", requested: "cluster-a/tenant-a/api-7d6-abc", wantBy: remoteResolvedByKey},
		{name: "owner", requested: "api", wantBy: remoteResolvedByOwner},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			target, tried, found := s.resolveRemoteTarget(test.requested)
			if !found {
				t.Fatalf("not found; tried %v", tried)
			}
			if target.By != test.wantBy {
				t.Fatalf("resolved by %q, want %q", target.By, test.wantBy)
			}
			if target.Workload.ClusterID != "cluster-a" {
				t.Fatalf("wrong workload: %#v", target.Workload)
			}
		})
	}

	_, tried, found := s.resolveRemoteTarget("missing")
	if found {
		t.Fatal("missing target resolved")
	}
	if len(tried) != 3 {
		t.Fatalf("tried = %v, want all three branches", tried)
	}
}

func TestResolveRemoteTargetRejectsAmbiguity(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)

	t.Run("pod name", func(t *testing.T) {
		registry := newRemoteWorkloadRegistry(t, now,
			workloadReportFor("cluster-a", "node-a", "tenant-a", "worker-0", "worker-a", now),
			workloadReportFor("cluster-b", "node-b", "tenant-b", "worker-0", "worker-b", now),
		)
		s := &server{workloads: registry}
		_, tried, found := s.resolveRemoteTarget("worker-0")
		if found {
			t.Fatal("ambiguous pod resolved")
		}
		text := strings.Join(tried, " ")
		if !strings.Contains(text, "2 matches") || !strings.Contains(text, "cluster-a") || !strings.Contains(text, "cluster-b") {
			t.Fatalf("ambiguity detail = %q", text)
		}
	})

	t.Run("owner name", func(t *testing.T) {
		report := workloadReportFor("cluster-a", "node-a", "tenant-a", "worker-a", "worker", now)
		report.Pods = append(report.Pods, ReportedPod{
			Namespace: "tenant-a",
			Name:      "worker-b",
			UID:       "worker-b",
			Owner:     ReportedPodOwner{Kind: "Deployment", Name: "worker"},
			Tenant:    "tenant-a",
		})
		registry := newRemoteWorkloadRegistry(t, now, report)
		s := &server{workloads: registry}
		_, tried, found := s.resolveRemoteTarget("worker")
		if found {
			t.Fatal("ambiguous owner resolved")
		}
		if text := strings.Join(tried, " "); !strings.Contains(text, "2 matches") || !strings.Contains(text, "cluster-a") {
			t.Fatalf("ambiguity detail = %q", text)
		}
	})
}

// remoteCallerKeys mirrors the production split rather than minting one
// all-powerful key.
//
// This matters for more than tidiness. A remote stun is REQUESTED from the hub
// side by a caller holding `stun` (the operator or the dashboard) and is
// POLLED AND ACKED by the remote warden, which holds `report` and nothing
// else. A fixture that granted the warden `stun` would let these tests pass
// while describing a system in which a remote cluster's own key can order
// containment on the hub — and would record "warden" in requested_by for a
// stun no warden can issue, so the audit assertions would be checking a value
// production never produces.
func remoteCallerKeys(t *testing.T) *callerKeys {
	t.Helper()
	keys, err := loadCallerKeys([]string{
		"FLEET_MANAGER_KEY_OPERATOR=" + operatorRemoteKey,
		"FLEET_MANAGER_KEY_OPERATOR_SCOPES=stun,resume",
		"FLEET_MANAGER_KEY_WARDEN=" + wardenWorkloadKey,
		"FLEET_MANAGER_KEY_WARDEN_SCOPES=report",
	})
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

// operatorRemoteKey is the hub-side caller that may order a stun or a resume.
const operatorRemoteKey = "operator-remote-key-0123456789abcdef01234"

func decodeRemoteStunRecord(t *testing.T, body string) RemoteStunRecord {
	t.Helper()
	var record RemoteStunRecord
	if err := json.Unmarshal([]byte(body), &record); err != nil {
		t.Fatal(err)
	}
	return record
}

func mockCallCount(client *mockFleetClient) int {
	client.mu.Lock()
	defer client.mu.Unlock()
	return len(client.calls)
}

// knownLocalAgentID reads a real id out of the test DAG rather than guessing
// from a list of plausible names. A guessed id that happens not to be in the
// fixture turns the precedence tests below into tests of nothing: local
// resolution would fail for the uninteresting reason that the agent does not
// exist, and the registry branch they exist to constrain would be exercised
// by accident rather than by design.
//
// The lowest id by sort order is chosen so the selection is stable across
// runs; AllAgents' own ordering is not part of its contract.
func knownLocalAgentID(t *testing.T, s *server) string {
	t.Helper()
	if s.dag == nil {
		t.Fatal("test server has no DAG")
	}
	ids := make([]string, 0)
	for _, a := range s.dag.AllAgents() {
		ids = append(ids, a.ID)
	}
	if len(ids) == 0 {
		t.Fatal("test DAG holds no agents")
	}
	sort.Strings(ids)
	return ids[0]
}

func TestStunLocalResolutionPrecedesRegistry(t *testing.T) {
	s := newTestServer(t)
	localID := knownLocalAgentID(t, s)
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", localID, "remote-copy", now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)

	client, ok := s.orchestrator.client.(*mockFleetClient)
	if !ok {
		t.Fatalf("orchestrator client is %T, want *mockFleetClient", s.orchestrator.client)
	}

	response := call(
		t,
		s.routes(),
		http.MethodPost,
		"/api/v1/fleet/stun/"+localID,
		`{"reason":"local precedence"}`,
		"Bearer "+operatorRemoteKey,
	)
	if response.Code == http.StatusAccepted {
		t.Fatalf("local target took remote 202 branch: %s", response.Body.String())
	}
	if s.remoteStuns.Len() != 0 {
		t.Fatalf("remote store length = %d, want zero", s.remoteStuns.Len())
	}
	if mockCallCount(client) == 0 {
		t.Fatal("local cascade made no fleet-client calls")
	}
}

func TestRemoteStunTakesNoLocalActionAndReturnsRecord(t *testing.T) {
	s := newTestServer(t)
	localID := knownLocalAgentID(t, s)
	before := *s.dag.GetAgent(localID)

	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "remote-api-0", "remote-api", now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)

	client, ok := s.orchestrator.client.(*mockFleetClient)
	if !ok {
		t.Fatalf("orchestrator client is %T, want *mockFleetClient", s.orchestrator.client)
	}

	response := call(
		t,
		s.routes(),
		http.MethodPost,
		"/api/v1/fleet/stun/remote-api-0",
		`{"reason":"suspected compromise"}`,
		"Bearer "+operatorRemoteKey,
	)
	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}

	record := decodeRemoteStunRecord(t, response.Body.String())
	if record.State != RemoteStunRequested ||
		record.ClusterID != "cluster-a" ||
		record.Namespace != "tenant-a" ||
		record.Name != "remote-api-0" ||
		record.Reason != "suspected compromise" ||
		record.RequestedBy != "operator" {
		t.Fatalf("unexpected response: %#v", record)
	}
	if mockCallCount(client) != 0 {
		t.Fatalf("remote stun made local calls: %v", client.calls)
	}
	after := *s.dag.GetAgent(localID)
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("remote stun changed local DAG agent:\n before %#v\n after %#v", before, after)
	}
}

func TestRemoteStunReasonValidation(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s := newTestServer(t)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "remote-api-0", "remote-api", now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)

	for _, body := range []string{`{}`, `{"reason":"   "}`} {
		response := call(
			t,
			s.routes(),
			http.MethodPost,
			"/api/v1/fleet/stun/remote-api-0",
			body,
			"Bearer "+operatorRemoteKey,
		)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("body %s: status = %d, response = %s", body, response.Code, response.Body.String())
		}
	}
	if s.remoteStuns.Len() != 0 {
		t.Fatalf("invalid reasons created %d records", s.remoteStuns.Len())
	}
}

func TestRemoteStunNotFoundIncludesResolutionAttempts(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s := newTestServer(t)
	s.workloads = newRemoteWorkloadRegistry(t, now)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)

	response := call(
		t,
		s.routes(),
		http.MethodPost,
		"/api/v1/fleet/stun/missing",
		`{"reason":"test"}`,
		"Bearer "+operatorRemoteKey,
	)
	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}

	var body struct {
		Error string   `json:"error"`
		Tried []string `json:"tried"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Tried) < 3 || !strings.Contains(strings.Join(body.Tried, " "), "registry pod name") {
		t.Fatalf("tried = %v", body.Tried)
	}
}

func TestRemoteResume(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	// The remote branch is held to the same governance as the local one, so
	// the request carries a dual-signed token bound to the registry pod name.
	token, reg := remoteDualSignedToken(t, "remote-api-0", "tenant-a", 2)
	s := newTestServer(t)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "remote-api-0", "remote-api", now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)
	s.keyRegistry = reg
	s.resumePolicy = dualPolicy()
	s.replayLedger = NewReplayLedger()
	stun := s.remoteStuns.Request("cluster-a", "tenant-a", "remote-api-0", "reason", "warden")

	response := call(
		t,
		s.routes(),
		http.MethodPost,
		"/api/v1/fleet/resume/remote-api-0",
		remoteResumeBody(t, token, "idem-remote-resume"),
		"Bearer "+operatorRemoteKey,
	)
	if response.Code != http.StatusAccepted {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	record := decodeRemoteStunRecord(t, response.Body.String())
	if record.State != RemoteResumeRequested || record.ID != stun.ID {
		t.Fatalf("unexpected resume record: %#v", record)
	}

	unknown := newTestServer(t)
	unknown.workloads = s.workloads
	unknown.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	unknown.callerKeys = remoteCallerKeys(t)
	unknown.keyRegistry = reg
	unknown.resumePolicy = dualPolicy()
	unknown.replayLedger = NewReplayLedger()
	response = call(
		t,
		unknown.routes(),
		http.MethodPost,
		"/api/v1/fleet/resume/remote-api-0",
		remoteResumeBody(t, token, "idem-remote-unknown"),
		"Bearer "+operatorRemoteKey,
	)
	if response.Code != http.StatusNotFound {
		t.Fatalf("unknown resume status = %d, body = %s", response.Code, response.Body.String())
	}
}

func TestRegistryDoesNotChangeLocalResumeStatus(t *testing.T) {
	baseline := newTestServer(t)
	localID := knownLocalAgentID(t, baseline)
	request := `{"agent_id":"` + localID + `"}`

	first := call(t, http.HandlerFunc(baseline.handleResume), http.MethodPost, "/api/v1/fleet/resume", request)

	withRegistry := newTestServer(t)
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	withRegistry.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "unrelated-0", "unrelated", now),
	)
	withRegistry.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	second := call(t, http.HandlerFunc(withRegistry.handleResume), http.MethodPost, "/api/v1/fleet/resume", request)

	if second.Code != first.Code {
		t.Fatalf("local resume status changed from %d to %d when registry was configured", first.Code, second.Code)
	}
	if withRegistry.remoteStuns.Len() != 0 {
		t.Fatalf("local resume created %d remote records", withRegistry.remoteStuns.Len())
	}
}

func TestRemoteStunStateScopeAndMethods(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	store := newRemoteStunTestStore(&remoteStunTestClock{current: now})
	record := store.Request("cluster-a", "tenant-a", "api-0", "reason", "warden")
	s := &server{
		remoteStuns: store,
		callerKeys:  testWorkloadCallerKeys(t),
	}
	handler := s.routes()

	tests := []struct {
		name   string
		method string
		path   string
		body   string
		auth   string
		want   int
	}{
		{name: "state no key", method: http.MethodGet, path: "/api/v1/fleet/stun-state?cluster_id=cluster-a", want: http.StatusUnauthorized},
		{name: "state read key (observation: the dashboard and operator watch stun state)", method: http.MethodGet, path: "/api/v1/fleet/stun-state?cluster_id=cluster-a", auth: "Bearer " + dashboardWorkloadKey, want: http.StatusOK},
		{name: "state report key", method: http.MethodGet, path: "/api/v1/fleet/stun-state?cluster_id=cluster-a", auth: "Bearer " + wardenWorkloadKey, want: http.StatusOK},
		{name: "state wrong method", method: http.MethodPost, path: "/api/v1/fleet/stun-state?cluster_id=cluster-a", auth: "Bearer " + wardenWorkloadKey, want: http.StatusMethodNotAllowed},
		{name: "ack no key", method: http.MethodPost, path: "/api/v1/fleet/stun-state/ack", body: `{}`, want: http.StatusUnauthorized},
		{name: "ack read key", method: http.MethodPost, path: "/api/v1/fleet/stun-state/ack", body: `{}`, auth: "Bearer " + dashboardWorkloadKey, want: http.StatusForbidden},
		{
			name:   "ack report key",
			method: http.MethodPost,
			path:   "/api/v1/fleet/stun-state/ack",
			body:   fmt.Sprintf(`{"id":%q,"state":"stunned","node":"node-a","at":"2026-10-04T10:01:00Z"}`, record.ID),
			auth:   "Bearer " + wardenWorkloadKey,
			want:   http.StatusOK,
		},
		{name: "ack wrong method", method: http.MethodGet, path: "/api/v1/fleet/stun-state/ack", auth: "Bearer " + wardenWorkloadKey, want: http.StatusMethodNotAllowed},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			headers := []string{}
			if test.auth != "" {
				headers = append(headers, test.auth)
			}
			response := call(t, handler, test.method, test.path, test.body, headers...)
			if response.Code != test.want {
				t.Fatalf("status = %d, want %d; body = %s", response.Code, test.want, response.Body.String())
			}
		})
	}
}

func TestRemoteStunStateHandlerValidation(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)

	t.Run("nil store", func(t *testing.T) {
		s := &server{}
		state := call(t, http.HandlerFunc(s.handleRemoteStunState), http.MethodGet, "/api/v1/fleet/stun-state?cluster_id=cluster-a", "")
		if state.Code != http.StatusServiceUnavailable {
			t.Fatalf("state status = %d", state.Code)
		}
		ack := call(t, http.HandlerFunc(s.handleRemoteStunAck), http.MethodPost, "/api/v1/fleet/stun-state/ack", `{}`)
		if ack.Code != http.StatusServiceUnavailable {
			t.Fatalf("ack status = %d", ack.Code)
		}
	})

	store := newRemoteStunTestStore(&remoteStunTestClock{current: now})
	record := store.Request("cluster-a", "tenant-a", "api-0", "reason", "warden")
	s := &server{remoteStuns: store}

	for _, path := range []string{
		"/api/v1/fleet/stun-state",
		"/api/v1/fleet/stun-state?cluster_id=INVALID_CLUSTER",
	} {
		response := call(t, http.HandlerFunc(s.handleRemoteStunState), http.MethodGet, path, "")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("%s: status = %d, body = %s", path, response.Code, response.Body.String())
		}
	}

	ackTests := []struct {
		name string
		body string
		want int
	}{
		{name: "unknown", body: `{"id":"missing","state":"stunned","node":"node-a","at":"2026-10-04T10:01:00Z"}`, want: http.StatusNotFound},
		{name: "bad state", body: fmt.Sprintf(`{"id":%q,"state":"stun_requested","node":"node-a","at":"2026-10-04T10:01:00Z"}`, record.ID), want: http.StatusBadRequest},
		{name: "bad node", body: fmt.Sprintf(`{"id":%q,"state":"stunned","node":"NODE A","at":"2026-10-04T10:01:00Z"}`, record.ID), want: http.StatusBadRequest},
		{name: "bad at", body: fmt.Sprintf(`{"id":%q,"state":"stunned","node":"node-a","at":"invalid"}`, record.ID), want: http.StatusBadRequest},
		{name: "unknown field", body: fmt.Sprintf(`{"id":%q,"state":"stunned","node":"node-a","at":"2026-10-04T10:01:00Z","extra":true}`, record.ID), want: http.StatusBadRequest},
		{name: "oversized", body: `{"id":"` + strings.Repeat("x", maxRemoteStunAckBytes) + `"}`, want: http.StatusRequestEntityTooLarge},
	}
	for _, test := range ackTests {
		t.Run(test.name, func(t *testing.T) {
			response := call(t, http.HandlerFunc(s.handleRemoteStunAck), http.MethodPost, "/api/v1/fleet/stun-state/ack", test.body)
			if response.Code != test.want {
				t.Fatalf("status = %d, want %d; body = %s", response.Code, test.want, response.Body.String())
			}
		})
	}

	t.Run("HEAD and method gates", func(t *testing.T) {
		// HEAD on state returns 200 with empty body
		headResp := call(t, http.HandlerFunc(s.handleRemoteStunState), http.MethodHead, "/api/v1/fleet/stun-state?cluster_id=cluster-a", "")
		if headResp.Code != http.StatusOK {
			t.Fatalf("HEAD state status = %d, want 200", headResp.Code)
		}
		if headResp.Body.Len() != 0 {
			t.Fatalf("HEAD state body length = %d, want 0", headResp.Body.Len())
		}
		if ct := headResp.Header().Get("Content-Type"); ct != "application/json" {
			t.Fatalf("HEAD state Content-Type = %q, want application/json", ct)
		}

		// Non-GET/HEAD on state returns 405 with Allow: GET, HEAD, OPTIONS
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
			bad := call(t, http.HandlerFunc(s.handleRemoteStunState), method, "/api/v1/fleet/stun-state?cluster_id=cluster-a", "")
			if bad.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s state status = %d, want 405", method, bad.Code)
			}
			if allow := bad.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
				t.Fatalf("%s state Allow = %q, want GET, HEAD, OPTIONS", method, allow)
			}
		}

		// Non-POST on ack returns 405 with Allow: POST, OPTIONS
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodPut, http.MethodDelete} {
			bad := call(t, http.HandlerFunc(s.handleRemoteStunAck), method, "/api/v1/fleet/stun-state/ack", "")
			if bad.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s ack status = %d, want 405", method, bad.Code)
			}
			if allow := bad.Header().Get("Allow"); allow != "POST, OPTIONS" {
				t.Fatalf("%s ack Allow = %q, want POST, OPTIONS", method, allow)
			}
		}
	})

	stunned := mustAckRemoteStun(t, store, record.ID, RemoteStunned)
	conflictBody := fmt.Sprintf(
		`{"id":%q,"state":"stunned","node":"node-a","at":"2026-10-04T10:02:00Z"}`,
		stunned.ID,
	)
	conflict := call(t, http.HandlerFunc(s.handleRemoteStunAck), http.MethodPost, "/api/v1/fleet/stun-state/ack", conflictBody)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict status = %d, body = %s", conflict.Code, conflict.Body.String())
	}
	if body := conflict.Body.String(); !strings.Contains(body, "stunned") {
		t.Fatalf("conflict did not name states: %s", body)
	}
}

func TestRemoteStunPendingFiltersSortsAndNeverReturnsNil(t *testing.T) {
	clock := &remoteStunTestClock{current: time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)}
	store := newRemoteStunTestStore(clock)

	zeta := store.Request("cluster-a", "zeta", "b", "reason", "alice")
	alphaB := store.Request("cluster-a", "alpha", "b", "reason", "alice")
	alphaA := store.Request("cluster-a", "alpha", "a", "reason", "alice")
	other := store.Request("cluster-b", "alpha", "a", "reason", "alice")

	mustAckRemoteStun(t, store, alphaB.ID, RemoteStunned)
	if _, err := store.RequestResume("cluster-a", "alpha", "b", "alice"); err != nil {
		t.Fatal(err)
	}
	mustAckRemoteStun(t, store, other.ID, RemoteStunned)
	_ = zeta
	_ = alphaA

	pending := store.Pending("cluster-a")
	if pending == nil {
		t.Fatal("Pending returned nil")
	}
	if len(pending) != 3 {
		t.Fatalf("pending = %#v", pending)
	}
	got := []string{
		pending[0].Namespace + "/" + pending[0].Name,
		pending[1].Namespace + "/" + pending[1].Name,
		pending[2].Namespace + "/" + pending[2].Name,
	}
	want := []string{"alpha/a", "alpha/b", "zeta/b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("order = %v, want %v", got, want)
	}
	if pending[0].State != RemoteStunRequested ||
		pending[1].State != RemoteResumeRequested ||
		pending[2].State != RemoteStunRequested {
		t.Fatalf("unexpected pending states: %#v", pending)
	}

	empty := store.Pending("cluster-missing")
	if empty == nil || len(empty) != 0 {
		t.Fatalf("empty pending = %#v, want non-nil empty slice", empty)
	}
}

// TestRemoteRoutesRejectWrongMethodThroughMux pins the four remote paths at the
// mux, not just at their handlers.
//
// The gateway in front of fleet-manager forwards every verb rather than
// filtering by method, so fleet-manager is the only thing standing between a
// stray PUT or DELETE and a handler that was written expecting one verb. Go's
// ServeMux patterns here are method-agnostic by design (the alternative,
// method-qualified patterns, would answer a wrong verb with the mux's own 405
// and never reach the handler's error envelope), which means the handler's own
// check is load-bearing. Asserting it through s.routes() rather than by calling
// the handler directly is what makes this a test of the deployed path.
func TestRemoteRoutesRejectWrongMethodThroughMux(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	s := newTestServer(t)
	s.workloads = newRemoteWorkloadRegistry(t, now,
		workloadReportFor("cluster-a", "node-a", "tenant-a", "remote-api-0", "remote-api", now),
	)
	s.remoteStuns = newRemoteStunTestStore(&remoteStunTestClock{current: now})
	s.callerKeys = remoteCallerKeys(t)
	handler := s.routes()

	// Each path is paired with a verb it does NOT serve.
	cases := []struct {
		path   string
		method string
	}{
		{path: "/api/v1/fleet/workloads/report", method: http.MethodGet},
		{path: "/api/v1/fleet/workloads/report", method: http.MethodDelete},
		{path: "/api/v1/fleet/workloads", method: http.MethodPost},
		{path: "/api/v1/fleet/workloads", method: http.MethodPut},
		{path: "/api/v1/fleet/stun-state", method: http.MethodPost},
		{path: "/api/v1/fleet/stun-state", method: http.MethodDelete},
		{path: "/api/v1/fleet/stun-state/ack", method: http.MethodGet},
		{path: "/api/v1/fleet/stun-state/ack", method: http.MethodPut},
	}

	for _, test := range cases {
		t.Run(test.method+" "+test.path, func(t *testing.T) {
			response := call(t, handler, test.method, test.path, "", "Bearer "+wardenWorkloadKey)
			if response.Code != http.StatusMethodNotAllowed {
				t.Fatalf("status = %d, want 405; body=%s", response.Code, response.Body.String())
			}
			// The envelope matters as much as the code: callers parse
			// {"error":...} and a bare status with an empty body is
			// indistinguishable from a proxy having answered instead.
			if !strings.Contains(response.Body.String(), "method not allowed") {
				t.Fatalf("body %q does not carry the error envelope", response.Body.String())
			}
		})
	}
}

// An acked record leaves the warden's pending view but stays in the observer's
// include=all view, so a stun can be followed to its end.
func TestRemoteStunStateIncludeAllKeepsAckedRecords(t *testing.T) {
	store := newRemoteStunTestStore(&remoteStunTestClock{current: time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)})
	rec := store.Request("cluster-a", "ns", "pod-1", "lab", "operator")
	if _, err := store.Ack(rec.ID, RemoteStunned, "node-a", "2026-10-04T19:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if got := store.Pending("cluster-a"); len(got) != 0 {
		t.Fatalf("pending after ack = %d, want 0", len(got))
	}
	all := store.All("cluster-a")
	if len(all) != 1 || all[0].ID != rec.ID || all[0].State != RemoteStunned {
		t.Fatalf("all after ack = %+v", all)
	}
	if got := store.All("cluster-b"); len(got) != 0 {
		t.Fatalf("another cluster's view leaked: %+v", got)
	}
}
