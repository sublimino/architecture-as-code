package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/fleet-manager/pkg/attestation"
	"k8s.io/apimachinery/pkg/util/validation"
)

const (
	AgentStunnedEventName         = "agent.stunned"
	AgentResumeRequestedEventName = "agent.resume_requested"

	maxRemoteStunAckBytes = 4 << 10
)

// RemoteStunState is the lifecycle of a stun on a workload in a remote cluster.
type RemoteStunState string

const (
	RemoteStunRequested   RemoteStunState = "stun_requested"
	RemoteStunned         RemoteStunState = "stunned"
	RemoteResumeRequested RemoteStunState = "resume_requested"
	RemoteResumed         RemoteStunState = "resumed"
)

var (
	ErrRemoteStunNotFound    = errors.New("remote stun record not found")
	ErrRemoteStunBadAckState = errors.New("remote stun acknowledgement state must be stunned or resumed")
	ErrRemoteStunAckConflict = errors.New("remote stun acknowledgement conflicts with current state")
	ErrRemoteStunBadAck      = errors.New("invalid remote stun acknowledgement")
)

// RemoteStunRecord is the wire shape the warden polls and the hub stores.
type RemoteStunRecord struct {
	ID          string          `json:"id"`
	ClusterID   string          `json:"cluster_id"`
	Namespace   string          `json:"namespace"`
	Name        string          `json:"name"`
	Reason      string          `json:"reason"`
	RequestedBy string          `json:"requested_by"`
	RequestedAt string          `json:"requested_at"`
	State       RemoteStunState `json:"state"`
	// AckedNode and AckedAt record the warden's acknowledgement. Absent until acked.
	AckedNode string `json:"acked_node,omitempty"`
	AckedAt   string `json:"acked_at,omitempty"`
}

// RemoteStunStore owns the hub's remote-containment intent records. The mutex
// covers every access to both indexes so an acknowledgement can never observe
// an id whose workload-key entry is only partly replaced.
type RemoteStunStore struct {
	mu      sync.Mutex
	now     func() time.Time
	newID   func() string
	records map[workloadKey]RemoteStunRecord
	byID    map[string]workloadKey
}

// NewRemoteStunStore constructs an empty remote-containment store.
func NewRemoteStunStore(now func() time.Time, newID func() string) *RemoteStunStore {
	if now == nil {
		now = time.Now
	}
	if newID == nil {
		newID = newRemoteStunID
	}
	return &RemoteStunStore{
		now:     now,
		newID:   newID,
		records: make(map[workloadKey]RemoteStunRecord),
		byID:    make(map[string]workloadKey),
	}
}

func newRemoteStunID() string {
	var random [8]byte
	// Remote stun ids cross a cluster trust boundary. math/rand would let a
	// remote cluster predict another record's id and acknowledge containment
	// on that cluster's behalf, so failure of the operating-system CSPRNG is
	// fatal rather than grounds for a predictable fallback.
	if _, err := rand.Read(random[:]); err != nil {
		panic(fmt.Sprintf("generate remote stun id: %v", err))
	}
	return "rstun-" + hex.EncodeToString(random[:])
}

// Request records an intent to contain a remote workload.
func (s *RemoteStunStore) Request(clusterID, namespace, name, reason, requestedBy string) RemoteStunRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := workloadKey{ClusterID: clusterID, Namespace: namespace, Name: name}
	existing, found := s.records[key]
	if found {
		switch existing.State {
		case RemoteStunRequested:
			return existing
		case RemoteStunned:
			// Re-asserting a stun on a workload the warden has already frozen
			// must not reopen a request the warden would action a second time.
			return existing
		case RemoteResumeRequested:
			// Containment beats release when stun and resume race. Retaining
			// the id lets a stale resume acknowledgement be rejected against
			// the new state instead of becoming an unknown-record response.
			existing.State = RemoteStunRequested
			existing.Reason = reason
			existing.RequestedBy = requestedBy
			existing.RequestedAt = s.now().UTC().Format(time.RFC3339)
			existing.AckedNode = ""
			existing.AckedAt = ""
			s.records[key] = existing
			return existing
		case RemoteResumed:
			delete(s.byID, existing.ID)
		}
	}

	record := RemoteStunRecord{
		ID:          s.newID(),
		ClusterID:   clusterID,
		Namespace:   namespace,
		Name:        name,
		Reason:      reason,
		RequestedBy: requestedBy,
		RequestedAt: s.now().UTC().Format(time.RFC3339),
		State:       RemoteStunRequested,
	}
	s.records[key] = record
	s.byID[record.ID] = key
	return record
}

// RequestResume records an intent to release a previously requested stun.
func (s *RemoteStunStore) RequestResume(clusterID, namespace, name, requestedBy string) (RemoteStunRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := workloadKey{ClusterID: clusterID, Namespace: namespace, Name: name}
	record, found := s.records[key]
	if !found {
		return RemoteStunRecord{}, ErrRemoteStunNotFound
	}

	switch record.State {
	case RemoteStunRequested, RemoteStunned:
		record.State = RemoteResumeRequested
		record.RequestedBy = requestedBy
		record.AckedNode = ""
		record.AckedAt = ""
		s.records[key] = record
		return record, nil
	case RemoteResumeRequested, RemoteResumed:
		return record, nil
	default:
		return RemoteStunRecord{}, fmt.Errorf("unknown remote stun state %q", record.State)
	}
}

// Ack applies a warden acknowledgement when it matches the outstanding intent.
func (s *RemoteStunStore) Ack(id string, state RemoteStunState, node, at string) (RemoteStunRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, found := s.byID[id]
	if !found {
		return RemoteStunRecord{}, ErrRemoteStunNotFound
	}
	record := s.records[key]

	if state != RemoteStunned && state != RemoteResumed {
		return RemoteStunRecord{}, ErrRemoteStunBadAckState
	}

	validTransition := state == RemoteStunned && record.State == RemoteStunRequested ||
		state == RemoteResumed && record.State == RemoteResumeRequested
	if !validTransition {
		// A mismatched acknowledgement is a warden acting on a stale poll.
		// Silently accepting it would make the hub claim a containment state
		// nobody currently asked for.
		return RemoteStunRecord{}, fmt.Errorf(
			"%w: current state %q, attempted state %q",
			ErrRemoteStunAckConflict,
			record.State,
			state,
		)
	}

	if node == "" {
		return RemoteStunRecord{}, fmt.Errorf("%w: node is required", ErrRemoteStunBadAck)
	}
	if problems := validation.IsDNS1123Subdomain(node); len(problems) != 0 {
		return RemoteStunRecord{}, fmt.Errorf("%w: node: %s", ErrRemoteStunBadAck, strings.Join(problems, "; "))
	}
	if at == "" {
		return RemoteStunRecord{}, fmt.Errorf("%w: at is required", ErrRemoteStunBadAck)
	}
	if _, err := time.Parse(time.RFC3339, at); err != nil {
		return RemoteStunRecord{}, fmt.Errorf("%w: at must be an RFC3339 timestamp", ErrRemoteStunBadAck)
	}

	record.State = state
	record.AckedNode = node
	record.AckedAt = at
	s.records[key] = record
	return record, nil
}

// Pending returns the outstanding containment and release intents for one
// cluster in a deterministic order suitable for repeated warden polls.
func (s *RemoteStunStore) Pending(clusterID string) []RemoteStunRecord {
	return s.list(clusterID, false)
}

// All returns every record of the cluster, acked ones included: the view an
// observer (dashboard, operator, the lab) reads to follow a stun to its end.
func (s *RemoteStunStore) All(clusterID string) []RemoteStunRecord {
	return s.list(clusterID, true)
}

func (s *RemoteStunStore) list(clusterID string, all bool) []RemoteStunRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	records := make([]RemoteStunRecord, 0)
	for _, record := range s.records {
		if record.ClusterID != clusterID {
			continue
		}
		if all || record.State == RemoteStunRequested || record.State == RemoteResumeRequested {
			records = append(records, record)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].Namespace != records[j].Namespace {
			return records[i].Namespace < records[j].Namespace
		}
		return records[i].Name < records[j].Name
	})
	return records
}

// ByID returns one record without exposing the store's mutable indexes.
func (s *RemoteStunStore) ByID(id string) (RemoteStunRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, found := s.byID[id]
	if !found {
		return RemoteStunRecord{}, false
	}
	record, found := s.records[key]
	return record, found
}

// HeldByName returns the one record for a pod name whose hold still stands:
// stun_requested, stunned, or resume_requested (the warden has not released
// it yet, and a replayed resume must still reach the ledger). Two clusters
// holding the same pod name is ambiguous and reports nothing, like the
// registry's own name lookup.
func (s *RemoteStunStore) HeldByName(name string) (RemoteStunRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out RemoteStunRecord
	n := 0
	for _, record := range s.records {
		if record.Name != name {
			continue
		}
		if record.State == RemoteStunRequested || record.State == RemoteStunned || record.State == RemoteResumeRequested {
			out = record
			n++
		}
	}
	return out, n == 1
}

// Current returns the record for a workload without changing it. The resume
// path uses it to answer "nothing to resume" before any token is consumed.
func (s *RemoteStunStore) Current(clusterID, namespace, name string) (RemoteStunRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	record, found := s.records[workloadKey{ClusterID: clusterID, Namespace: namespace, Name: name}]
	return record, found
}

// Len returns the number of workload-keyed records.
func (s *RemoteStunStore) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()

	return len(s.records)
}

// remoteTarget is a registry workload a stun or resume request resolved onto.
type remoteTarget struct {
	Workload RegisteredWorkload
	By       string
}

// Resolution branch names, reported in the 404 "tried" list.
const (
	remoteResolvedByPodName = "registry-pod-name"
	remoteResolvedByKey     = "registry-cluster-namespace-name"
	remoteResolvedByOwner   = "registry-owner-name"
)

// resolveRemoteTarget resolves the caller's name against the remote registry.
// Local resolution is deliberately performed by the caller before this method:
// a registry report must never shadow a local DAG agent.
func (s *server) resolveRemoteTarget(requested string) (remoteTarget, []string, bool) {
	tried := make([]string, 0, 3)
	if s.workloads == nil {
		tried = append(tried, "registry (not configured)")
		return remoteTarget{}, tried, false
	}

	podMatches := s.workloads.ByPodName(requested)
	switch len(podMatches) {
	case 0:
		tried = append(tried, "registry pod name:"+requested+" (no matches)")
	case 1:
		tried = append(tried, "registry pod name:"+requested+" (one match)")
		return remoteTarget{Workload: podMatches[0], By: remoteResolvedByPodName}, tried, true
	default:
		// Picking one duplicate pod name arbitrarily would stun a workload in
		// a cluster the operator did not name. The explicit three-part key is
		// the only safe way to disambiguate this request.
		tried = append(tried, fmt.Sprintf(
			"registry pod name:%s (%d matches across clusters %s; use cluster/namespace/name)",
			requested,
			len(podMatches),
			strings.Join(remoteMatchClusters(podMatches), ","),
		))
		return remoteTarget{}, tried, false
	}

	parts := strings.Split(requested, "/")
	if len(parts) == 3 && parts[0] != "" && parts[1] != "" && parts[2] != "" {
		workload, found := s.workloads.ByKey(parts[0], parts[1], parts[2])
		if found {
			tried = append(tried, "registry key:"+requested+" (one match)")
			return remoteTarget{Workload: workload, By: remoteResolvedByKey}, tried, true
		}
		tried = append(tried, "registry key:"+requested+" (no match)")
	} else {
		tried = append(tried, "registry key:"+requested+" (not cluster/namespace/name)")
	}

	ownerMatches := s.workloads.ByOwnerName(requested)
	switch len(ownerMatches) {
	case 0:
		tried = append(tried, "registry owner name:"+requested+" (no matches)")
	case 1:
		tried = append(tried, "registry owner name:"+requested+" (one match)")
		return remoteTarget{Workload: ownerMatches[0], By: remoteResolvedByOwner}, tried, true
	default:
		// Owner names commonly span replicas and can also span clusters.
		// Choosing a member would turn an ambiguous operator request into an
		// arbitrary containment action in a cluster the operator did not name.
		tried = append(tried, fmt.Sprintf(
			"registry owner name:%s (%d matches across clusters %s; use cluster/namespace/name)",
			requested,
			len(ownerMatches),
			strings.Join(remoteMatchClusters(ownerMatches), ","),
		))
	}
	return remoteTarget{}, tried, false
}

func remoteMatchClusters(workloads []RegisteredWorkload) []string {
	set := make(map[string]struct{})
	for _, workload := range workloads {
		set[workload.ClusterID] = struct{}{}
	}
	clusters := make([]string, 0, len(set))
	for cluster := range set {
		clusters = append(clusters, cluster)
	}
	sort.Strings(clusters)
	return clusters
}

// RemoteStunAuditLogEntry is the stable structured record for remote stun and
// resume requests. Remote is always true: readers use it to distinguish a
// hub-local containment from an intent the hub recorded but did not itself
// enforce. Conflating those cases would overstate what actually happened.
type RemoteStunAuditLogEntry struct {
	Timestamp   string          `json:"timestamp"`
	Event       string          `json:"event"`
	AgentID     string          `json:"agent_id"`
	ClusterID   string          `json:"cluster_id"`
	Namespace   string          `json:"namespace"`
	Name        string          `json:"name"`
	StunID      string          `json:"stun_id"`
	Reason      string          `json:"reason"`
	RequestedBy string          `json:"requested_by"`
	State       RemoteStunState `json:"state"`
	ResolvedBy  string          `json:"resolved_by"`
	Remote      bool            `json:"remote"`
	// TokenID and OperatorIDs attribute a resume to the operators who signed
	// its token. Absent on a stun, which carries no token.
	TokenID     string   `json:"token_id,omitempty"`
	OperatorIDs []string `json:"operator_ids,omitempty"`
}

func emitRemoteStunAudit(event, requested string, target remoteTarget, record RemoteStunRecord) {
	emitRemoteAudit(event, requested, target, record, "", nil)
}

// emitRemoteResumeAudit records a governed remote resume, naming the token and
// the operators whose signatures verified. It is emitted only after the token
// passed, so an audit line here always means an approved release.
func emitRemoteResumeAudit(requested string, target remoteTarget, record RemoteStunRecord, tokenID string, operatorIDs []string) {
	emitRemoteAudit(AgentResumeRequestedEventName, requested, target, record, tokenID, operatorIDs)
}

func emitRemoteAudit(event, requested string, target remoteTarget, record RemoteStunRecord, tokenID string, operatorIDs []string) {
	entry := RemoteStunAuditLogEntry{
		TokenID:     tokenID,
		OperatorIDs: operatorIDs,
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
		Event:       event,
		AgentID:     requested,
		ClusterID:   record.ClusterID,
		Namespace:   record.Namespace,
		Name:        record.Name,
		StunID:      record.ID,
		Reason:      record.Reason,
		RequestedBy: record.RequestedBy,
		State:       record.State,
		ResolvedBy:  target.By,
		Remote:      true,
	}
	data, err := json.Marshal(entry)
	if err != nil {
		slog.Error("failed to marshal remote stun audit log", "event", event, "error", err)
		return
	}
	slog.Info(event, "record", string(data))
}

func callerName(w http.ResponseWriter) string {
	requestedBy := w.Header().Get(callerHeader)
	if requestedBy == "" {
		// Focused tests and direct handler integrations can bypass require,
		// which is normally responsible for installing the authenticated name.
		// Preserve an explicit provenance value instead of recording an empty
		// identity that could be mistaken for a serialization omission.
		return "unknown"
	}
	return requestedBy
}

// handleRemoteStunFallback handles the registry branch after local resolution
// has failed. It returns false only when remote support is not configured.
func (s *server) handleRemoteStunFallback(w http.ResponseWriter, r *http.Request, requested string, local agentResolution) bool {
	if s.workloads == nil || s.remoteStuns == nil {
		return false
	}

	target, tried, found := s.resolveRemoteTarget(requested)
	if !found {
		local.Tried = append(local.Tried, tried...)
		writeUnknownAgent(w, local)
		return true
	}

	reason, err := decodeStunRequest(r, requested, target.Workload.Name)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return true
	}

	// The cascade is hub-local by design. Containment of a remote workload is
	// the remote warden's job, so this branch must remain free of Kubernetes,
	// Flux, OpenBao, SPIRE, orchestrator and all other local-plane calls.
	record := s.remoteStuns.Request(
		target.Workload.ClusterID,
		target.Workload.Namespace,
		target.Workload.Name,
		reason,
		callerName(w),
	)
	emitRemoteStunAudit(AgentStunnedEventName, requested, target, record)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(record)
	return true
}

// errRemoteResumeTokenRequired is the refusal for a remote resume that carries
// no token at all. It is distinct from a malformed token on purpose: the
// caller did not present governance, rather than presenting it badly.
var errRemoteResumeTokenRequired = errors.New("a dual-signed resume token is required to resume a remote workload")

// remoteResumePlane is the attested plane name for a resume the hub records
// and the remote warden enforces.
const remoteResumePlane = "remote-warden"

// handleRemoteResumeFallback handles a registry resume only after local agent
// resolution has failed, so no local agent's release can be diverted through
// the remote intent store.
//
// The remote branch is held to the same governance as the local one. The
// caller key's `resume` scope says who may ask; it says nothing about who
// approved. Approval is the dual-signed resume token, verified against the
// registry pod name the token must name, then consumed exactly once in the
// replay ledger, then attested. Only after all three does the hub write
// resume_requested for the warden to act on. Nothing is mutated on any
// failing path, so a refused request leaves the stun record as it was.
func (s *server) handleRemoteResumeFallback(w http.ResponseWriter, req ResumeRequest, local agentResolution) bool {
	if s.workloads == nil || s.remoteStuns == nil {
		return false
	}
	requested := req.AgentID

	target, tried, found := s.resolveRemoteTarget(requested)
	if !found {
		// A stunned pod can leave the registry while its hold stands: the
		// warden reports only pods it still sees, and a frozen pod that the
		// controller replaced is gone from the next report within a minute.
		// The stun record is the authority for what is held, so a resume
		// resolves against it when the registry no longer answers.
		if record, ok := s.remoteStuns.HeldByName(requested); ok {
			tried = append(tried, "stun record:"+record.ID+" (registry entry gone; resolved by the hold)")
			target = remoteTarget{Workload: RegisteredWorkload{
				ClusterID: record.ClusterID, Namespace: record.Namespace, Name: record.Name, Node: record.AckedNode,
			}, By: "stun-record"}
			found = true
		}
	}
	if !found {
		local.Tried = append(local.Tried, tried...)
		writeUnknownAgent(w, local)
		return true
	}

	if req.Token.TokenID == "" && len(req.Token.Signatures) == 0 && req.Token.Signature == "" {
		writeError(w, http.StatusForbidden, errRemoteResumeTokenRequired.Error())
		return true
	}

	now := time.Now().UTC()
	policy := s.resumePolicy
	if policy.RequiredSignatures == 0 {
		policy = DefaultResumeTokenPolicy(policy.Audience, policy.TrustRootID)
	}
	// The token binds to the registry pod name and namespace, not to whatever
	// alias the caller used to find it. A token minted for one replica must
	// not release another that shares its owner name.
	boundTarget := TargetRef{
		AgentID:   target.Workload.Name,
		Namespace: target.Workload.Namespace,
		PodName:   target.Workload.Name,
		NodeName:  target.Workload.Node,
	}
	if err := VerifyResumeToken(req.Token, boundTarget, s.keyRegistry, policy, now); err != nil {
		writeError(w, remoteResumeStatus(err), fmt.Sprintf("resume token verification failed: %v", err))
		return true
	}
	operatorIDs := make([]string, 0, len(req.Token.Signatures))
	for _, sig := range req.Token.Signatures {
		operatorIDs = append(operatorIDs, sig.OperatorID)
	}

	// Existence is checked before the ledger consumes the token: a token spent
	// on a 404 would be a token spent on nothing.
	current, found := s.remoteStuns.Current(
		target.Workload.ClusterID,
		target.Workload.Namespace,
		target.Workload.Name,
	)
	if !found {
		local.Tried = append(local.Tried, tried...)
		local.Tried = append(local.Tried, "remote stun record (not found; nothing to resume)")
		writeUnknownAgent(w, local)
		return true
	}

	idempotencyKey := req.IdempotencyKey
	if idempotencyKey == "" {
		idempotencyKey = fmt.Sprintf("resume-%s-%s", requested, req.Token.TokenID)
	}
	if s.replayLedger != nil {
		isRetry, _, err := s.replayLedger.CheckAndRecord(req.Token.TokenID, idempotencyKey, operatorIDs, now)
		if err != nil {
			writeError(w, remoteResumeStatus(err), err.Error())
			return true
		}
		if isRetry {
			// The same request again: answer with what the first one did and
			// write nothing. A second resume_requested would re-open a record
			// the warden may already have acknowledged.
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusAccepted)
			_ = json.NewEncoder(w).Encode(current)
			return true
		}
	}

	if s.attestationEngine != nil {
		if err := s.attestRemoteResume(req, target, current, idempotencyKey, operatorIDs, now); err != nil {
			slog.Error("witness attestation signing failed for remote resume",
				"agent", requested, "cluster_id", target.Workload.ClusterID, "error", err)
			writeError(w, http.StatusInternalServerError, fmt.Sprintf("attestation failed: %v", err))
			return true
		}
	}

	record, err := s.remoteStuns.RequestResume(
		target.Workload.ClusterID,
		target.Workload.Namespace,
		target.Workload.Name,
		callerName(w),
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return true
	}

	emitRemoteResumeAudit(requested, target, record, req.Token.TokenID, operatorIDs)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(record)
	return true
}

// remoteResumeStatus maps a governance failure onto the status handleResume
// uses for the same failure. Every other verification failure of a presented
// token is a refusal, not a server fault: the token was read and found
// wanting.
func remoteResumeStatus(err error) int {
	switch {
	case errors.Is(err, ErrResumeTokenReplayed):
		return http.StatusConflict
	case errors.Is(err, ErrResumeTokenTargetMismatch),
		errors.Is(err, ErrResumeTokenMalformed),
		errors.Is(err, ErrResumeTokenSchemaVersion),
		errors.Is(err, ErrResumeTokenUnsupportedAlgorithm),
		errors.Is(err, ErrResumeTokenProjectionMismatch),
		errors.Is(err, ErrResumeTokenShortNonce):
		return http.StatusBadRequest
	default:
		return http.StatusForbidden
	}
}

// attestRemoteResume writes the forensic ledger record for a remote resume.
// The hub is not the enforcer here, and the record says so: the single plane
// is the remote warden, its outcome is the intent the hub recorded, and the
// details carry the cluster coordinates with remote set to true.
func (s *server) attestRemoteResume(req ResumeRequest, target remoteTarget, current RemoteStunRecord, idempotencyKey string, operatorIDs []string, now time.Time) error {
	attReq := attestation.ResumeAttestationRequest{
		EventID:        fmt.Sprintf("resume-%s-%d", req.AgentID, now.UnixNano()),
		EventType:      attestation.EventContainmentResumed,
		IdempotencyKey: idempotencyKey,
		Authorization: attestation.AuthorizationEvidence{
			DecisionID:            req.Token.GovernanceApprovalRef,
			TriggerReason:         "attributable_governance_resume",
			TriggerDescription:    "Dual-operator attributable governance token presented and verified for a remote workload",
			TriggeredBy:           strings.Join(operatorIDs, ","),
			DelegationEdgeRevoked: false,
		},
		Target: attestation.TargetIdentity{
			AgentID:   target.Workload.Name,
			Namespace: target.Workload.Namespace,
			PodName:   target.Workload.Name,
			PodUID:    target.Workload.UID,
			NodeName:  target.Workload.Node,
			TenantID:  target.Workload.Tenant,
		},
		Execution: attestation.ExecutionEvidence{
			OverallOutcome: string(RemoteResumeRequested),
			TotalLatencyMs: 0,
			Planes: []attestation.PlaneExecutionEvidence{{
				Plane:   remoteResumePlane,
				Outcome: string(RemoteResumeRequested),
				Details: map[string]any{
					"cluster_id": target.Workload.ClusterID,
					"namespace":  target.Workload.Namespace,
					"name":       target.Workload.Name,
					"stun_id":    current.ID,
					"remote":     true,
				},
			}},
		},
		GovernanceResume: attestation.GovernanceResumeEvidence{
			TokenID:               req.Token.TokenID,
			OperatorIDs:           operatorIDs,
			GovernanceApprovalRef: req.Token.GovernanceApprovalRef,
			CredentialsRotated:    false,
			ProcessesResumed:      0,
			UnfreezeLatencyMs:     0,
		},
		Timestamp: now,
	}
	record, _, err := s.attestationEngine.AttestResume(context.Background(), attReq)
	if err != nil {
		return err
	}
	slog.Info("governance resume decision executed",
		"event", ResumeDecisionEventName,
		"agent_id", req.AgentID,
		"namespace", target.Workload.Namespace,
		"cluster_id", target.Workload.ClusterID,
		"remote", true,
		"token_id", req.Token.TokenID,
		"operator_ids", operatorIDs,
		"governance_approval_ref", req.Token.GovernanceApprovalRef,
		"idempotency_key", idempotencyKey,
		"attested_record_digest", record.Attestation.StatementDigest)
	return nil
}

// RemoteStunStateResponse wraps pending records and preserves an empty JSON
// array instead of changing the response schema to null.
type RemoteStunStateResponse struct {
	Records []RemoteStunRecord `json:"records"`
	Count   int                `json:"count"`
}

// RemoteStunAckRequest is the acknowledgement body sent by a remote warden.
type RemoteStunAckRequest struct {
	ID    string          `json:"id"`
	State RemoteStunState `json:"state"`
	Node  string          `json:"node"`
	At    string          `json:"at"`
}

// handleRemoteStunState returns only one cluster's outstanding intentions.
// cluster_id is mandatory because defaulting to all clusters would hand one
// remote cluster another cluster's containment and release instructions.
func (s *server) handleRemoteStunState(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.remoteStuns == nil {
		writeError(w, http.StatusServiceUnavailable, "remote stun store is not configured")
		return
	}

	clusterID := r.URL.Query().Get("cluster_id")
	if clusterID == "" {
		writeError(w, http.StatusBadRequest, "cluster_id is required")
		return
	}
	if problems := validation.IsDNS1123Label(clusterID); len(problems) != 0 {
		writeError(w, http.StatusBadRequest, "cluster_id: "+strings.Join(problems, "; "))
		return
	}

	// include=all is the observer's view; the warden reads the default, the
	// records it still has to act on.
	var records []RemoteStunRecord
	if r.URL.Query().Get("include") == "all" {
		records = s.remoteStuns.All(clusterID)
	} else {
		records = s.remoteStuns.Pending(clusterID)
	}
	if records == nil {
		records = make([]RemoteStunRecord, 0)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(RemoteStunStateResponse{
		Records: records,
		Count:   len(records),
	})
}

// handleRemoteStunAck validates and records one warden acknowledgement.
func (s *server) handleRemoteStunAck(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.remoteStuns == nil {
		writeError(w, http.StatusServiceUnavailable, "remote stun store is not configured")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxRemoteStunAckBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	var request RemoteStunAckRequest
	if err := decoder.Decode(&request); err != nil {
		writeRemoteStunAckDecodeError(w, err)
		return
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err != nil {
			writeRemoteStunAckDecodeError(w, err)
			return
		}
		writeError(w, http.StatusBadRequest, "request body must contain one JSON object")
		return
	}

	record, err := s.remoteStuns.Ack(request.ID, request.State, request.Node, request.At)
	switch {
	case errors.Is(err, ErrRemoteStunNotFound):
		writeError(w, http.StatusNotFound, err.Error())
		return
	case errors.Is(err, ErrRemoteStunBadAckState), errors.Is(err, ErrRemoteStunBadAck):
		writeError(w, http.StatusBadRequest, err.Error())
		return
	case errors.Is(err, ErrRemoteStunAckConflict):
		writeError(w, http.StatusConflict, err.Error())
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	slog.Info(
		"remote stun acknowledged",
		"stun_id", record.ID,
		"cluster_id", record.ClusterID,
		"namespace", record.Namespace,
		"name", record.Name,
		"state", record.State,
		"node", record.AckedNode,
		"at", record.AckedAt,
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(record)
}

func writeRemoteStunAckDecodeError(w http.ResponseWriter, err error) {
	var maxBytesError *http.MaxBytesError
	if errors.As(err, &maxBytesError) {
		writeError(w, http.StatusRequestEntityTooLarge, "remote stun acknowledgement exceeds 4096 bytes")
		return
	}
	writeError(w, http.StatusBadRequest, "invalid remote stun acknowledgement: "+err.Error())
}
