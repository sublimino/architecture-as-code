package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// ── Why this file exists ─────────────────────────────────────────────────────
//
// Until SLER-P1-1 the only FleetClient was noopFleetClient, whose GetPodState
// returned StateRunning and whose three mutating methods returned nil. Those are
// not "do nothing" values. They are the exact values a real client returns on
// SUCCESS, so the cascade orchestrator recorded Success:true and the HTTP layer
// answered 200 for a containment that never happened. A failed enforcement was
// indistinguishable from a successful one at every layer above the client.
//
// The fix is not "return an error" — it is to stop projecting a three-valued
// space onto a boolean. A plane request has three outcomes, never two:
//
//	known-contained      the plane answered "done"                  -> nil
//	known-not-contained  the plane answered "absent" / "refused"    -> ErrTargetNotFound
//	unknown              the plane did not answer at all            -> ErrEnforcementUnavailable
//
// The third is the one the old code could not express. The absence of an answer
// carries ZERO information about the target, so any state value synthesised in
// that case is fabricated. Callers get StateUnknown and a typed error, never a
// plausible lie.

// ErrEnforcementUnavailable is returned when the enforcement plane could not be
// reached or could not answer: connection failure, timeout, server error, or an
// RBAC denial (being forbidden to act is a failure to enforce, not a verdict
// about the target). Callers distinguish it with errors.Is.
//
// It is deliberately NOT returned when the plane answers clearly — see
// ErrTargetNotFound. Collapsing the two is how "target is gone" and "we are
// blind" become the same event in an incident timeline.
var ErrEnforcementUnavailable = errors.New("enforcement unavailable")

// ErrTargetNotFound is returned when the plane answered and the target does not
// exist. This is a definite answer, not unavailability: the plane is healthy and
// the enforcement surface is reachable.
var ErrTargetNotFound = errors.New("enforcement target not found")

// ErrEnforcementDenied is returned when a policy decisively refused the action —
// an RBAC 403, or a ValidatingAdmissionPolicy rejection.
//
// It WRAPS ErrEnforcementUnavailable, so errors.Is(err, ErrEnforcementUnavailable)
// still holds and every fail-closed caller keeps working unchanged. The extra
// type exists because the two differ in one way that matters operationally: an
// unreachable plane is transient and worth retrying, a policy denial is
// authoritative and permanent. Collapsing them sends a backoff loop retrying a
// decision that will never change.
//
// This is the type a fleet-manager un-stun receives wherever
// d2-agent-trust/policies/agent-identity-state-protection.yaml is deployed —
// that policy permits mutating signalloom.ai/state away from "stunned" only for
// swarm-governor and cluster admins, and this ServiceAccount is not among them.
var ErrEnforcementDenied = fmt.Errorf("enforcement denied by policy: %w", ErrEnforcementUnavailable)

// StateUnknown is declared in cascade.go:28 beside the other state constants.
// This client consumes that declaration rather than redeclaring it, ensuring
// package main exports a single StateUnknown symbol across orchestrator and client.

// Pod label contract shared with the agent manifests and the stun sentinel.
//
// The card that introduced this file pointed at node-capability-guard's
// ValidatePod for the state label. ValidatePod reads no state label:
// pkg/webhook/handler.go:84-86 checks agent IDENTITY labels and :99-109 checks
// the node.signalloom.ai/{cgroup-v2,landlock} nodeSelector. The actual shared
// contract is the one twelve agent manifests carry and that
// infra/agent-swarm/ebpf-sentinel-rbac.yaml:5 documents as the PATCH target for
// "=stunned". These constants exist so P2/P3 consume one symbol rather than
// re-deriving the strings.
const (
	// PodStateLabel carries the agent's lifecycle state (idle | active | stunned).
	PodStateLabel = "signalloom.ai/state"
	// StunnedLabel is the boolean companion the sentinel's informer branches on.
	StunnedLabel = "signalloom.io/stunned"
	// AgentLabel marks a pod as a fleet agent; the sentinel's informer selects on it.
	AgentLabel = "signalloom.ai/agent"
	// AgentNameLabel carries the agent id with its "agent-" prefix stripped.
	AgentNameLabel = "signalloom.ai/agent-name"
	// ContainmentModeLabel is the THIRD term the sentinel ORs into its stunned
	// test (signalloom-stun-sentinel/main.go:41). Leaving it at "frozen" while
	// setting the state label back to active leaves the pod frozen while the
	// dashboard reports it healthy — a split brain that lies reassuringly.
	ContainmentModeLabel = "signalloom.io/containment-mode"
)

// Containment-mode label values. Only these two are ever written in this
// repository; the proposal docs also list "isolated" and "quarantined", which
// nothing writes and nothing reads.
const (
	ContainmentModeFrozen = "frozen"
	ContainmentModeNone   = "none"
)

// Stun provenance annotations. All three are written together — the duplicate
// ai/io stun-reason pair is pre-existing and both are read by different
// consumers, so writing only one leaves a stale value behind.
const (
	StunnedAtAnnotation    = "signalloom.ai/stunned-at"
	StunReasonAnnotationAI = "signalloom.ai/stun-reason"
	StunReasonAnnotationIO = "signalloom.io/stun-reason"
)

// PodStateLabelValue maps a cascade orchestrator state constant onto a value the
// label vocabulary actually admits.
//
// This mapping exists because of a latent defect that only becomes reachable the
// moment a REAL client ships. cascade.go:12 defines StateRunning = "running",
// and Recover writes it (cascade.go:161). "running" appears in zero manifests,
// zero scripts, and is not a member of AgentStateValue — this module's own
// contract test enumerates the client-known values as absent, deploying, active,
// non-compliant, grace-period, stunned (contract_test.go:153-156). Every other
// un-stun path in the repo writes "active".
//
// So under noopFleetClient the value never left the process and nothing broke.
// Writing it to a live pod would make the dashboard's derivePhase switch fall to
// its default arm and report the agent as "deployed" — a believable wrong answer
// of exactly the kind topology.go:13-17 was written to prevent.
//
// The mapping is applied on WRITE only. Reads return the label verbatim, because
// the value on the pod is what the dashboard and the sentinel consume, and
// translating it back would reintroduce a vocabulary this repo does not use.
// Fixing the constant itself belongs to SLER-P1-5, which owns cascade.go's
// orchestration; this boundary keeps the corruption from ever reaching a pod in
// the meantime.
func PodStateLabelValue(state string) string {
	if state == StateRunning {
		return "active"
	}
	return state
}

// StunReason is written into the provenance annotations on containment. It is a
// constant rather than a parameter because SLER-P1-1 does not change the
// FleetClient method signatures beyond adding Health; a caller-supplied reason
// arrives with the ContainmentReason type in a later phase.
const StunReason = "fleet-manager cascade containment"

// PodPatchFieldManager matches every other writer of these fields in the repo
// (the three demo scripts and the integration proxy), a convention
// test/flux-drift-ignore.bats asserts on. Flux's .spec.ignore rules were
// validated against writes carrying this manager; patching under a different one
// would make this client the first deviant writer with no test covering it.
const PodPatchFieldManager = "flux-client-side-apply"

// DefaultAgentNamespace is used when a fleet-config entry omits its namespace.
// The agents run in fe-signalloom-agents; fleet-manager itself runs in
// fe-signalloom, which is why the Role granting pod access is namespaced to the
// former (d2-osramp-fleet/tenants/local/signalloom.yaml).
const DefaultAgentNamespace = "fe-signalloom-agents"

// DegradedTarget is the fail-closed record written when a plane could not be
// reached for a specific target. It pairs the P1-2 wire types so a caller can
// serialise it into a ContainmentDecision without a second translation.
type DegradedTarget struct {
	Target TargetRef   `json:"target"`
	Result PlaneResult `json:"result"`
}

// degradedRegistry is the fail-closed isolation state. A target enters it the
// moment an operation against it returns ErrEnforcementUnavailable, and leaves
// it only when the plane answers again — including when it answers "not found",
// because that answer proves the plane is reachable.
//
// It is in-memory and per-process by design: this is the liveness view of "which
// targets are we currently blind to", not a durable containment ledger. The
// attested forensic record is P3's surface.
type degradedRegistry struct {
	mu      sync.RWMutex
	entries map[string]registryEntry
	seq     atomic.Uint64
}

// registryEntry carries the sequence number of the API call that produced it, so
// a late-arriving verdict cannot overwrite a fresher one.
//
// The lock alone is not enough. mark and clear are each individually locked, but
// the DECISION to mark or clear is made outside the lock — at API-call-return
// time — and applied afterwards. HTTP handlers are concurrent and share one
// client, so a stun and a recover can be in flight against the same target at
// once. Without ordering: A's patch fails at T0, B's resolve succeeds at T1>T0,
// and whichever record() the scheduler runs second wins. Half the time that
// leaves spurious blindness; the other half it leaves the target reported
// healthy while A genuinely could not enforce. Correctness by scheduler luck.
//
// The ticket is taken BEFORE the API call (see nextSeq) and compared under the
// lock, so a verdict about an older call is dropped.
type registryEntry struct {
	target DegradedTarget
	seq    uint64
}

func newDegradedRegistry() *degradedRegistry {
	return &degradedRegistry{entries: make(map[string]registryEntry)}
}

// nextSeq issues a monotonic ticket. Callers take one immediately before the API
// call whose outcome they are about to record.
func (r *degradedRegistry) nextSeq() uint64 {
	return r.seq.Add(1)
}

// degradedKey is keyed by PLANE as well as target, and that is load-bearing.
//
// Keyed by target alone, this registry lies by construction. RevokeCredentials
// always fails (it is a typed P2-1 stub), so every target would be permanently
// degraded — and then the next successful SetPodState, which only ever proves
// something about the FREEZE plane, would clear a record whose subject is the
// BAO plane and which is still true. One plane's partial success would vouch for
// its siblings, and DegradedTargets() would report "available" for a credential
// plane known to be broken. Per-plane keying is what makes clear() honest: it
// can only ever retract a claim about the plane that just answered.
func degradedKey(plane EnforcementPlane, namespace, agentID string) string {
	return string(plane) + "|" + namespace + "/" + agentID
}

// mark records the target as degraded on the named plane. It is a no-op for any
// error that is not ErrEnforcementUnavailable: a NotFound is a real answer and
// must not be reported as blindness.
func (r *degradedRegistry) mark(seq uint64, plane EnforcementPlane, target TargetRef, operation string, cause error) {
	if cause == nil || !errors.Is(cause, ErrEnforcementUnavailable) {
		return
	}
	key := degradedKey(plane, target.Namespace, target.AgentID)
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing, ok := r.entries[key]; ok && existing.seq > seq {
		return // a fresher verdict already landed
	}
	r.entries[key] = registryEntry{
		seq: seq,
		target: DegradedTarget{
			Target: target,
			Result: PlaneResult{
				Plane:     plane,
				Outcome:   OutcomeUnavailable,
				Error:     cause.Error(),
				Timestamp: time.Now().UTC().Format(time.RFC3339),
				Details: map[string]any{
					"operation": operation,
					"reason":    "plane did not answer; target state is unknown",
				},
			},
		},
	}
}

// clear retracts the blindness claim for ONE plane, and only that plane, because
// that is the only plane the answering call proved anything about.
//
// It refuses to retract a claim made by a LATER call than its own: a slow
// success returning after a fresh failure must not erase the failure. Safe on an
// absent key.
func (r *degradedRegistry) clear(seq uint64, plane EnforcementPlane, namespace, agentID string) {
	key := degradedKey(plane, namespace, agentID)
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing, ok := r.entries[key]; ok && existing.seq > seq {
		return
	}
	delete(r.entries, key)
}

// isDegraded reports whether the target is degraded on ANY plane. Fail-closed:
// a target we cannot reach on one plane is a target we cannot fully contain,
// even if another plane answered.
func (r *degradedRegistry) isDegraded(namespace, agentID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, plane := range AllEnforcementPlanes() {
		if _, ok := r.entries[degradedKey(plane, namespace, agentID)]; ok {
			return true
		}
	}
	return false
}

// isDegradedOnPlane answers the narrower question, for callers deciding whether
// a specific plane is worth retrying.
func (r *degradedRegistry) isDegradedOnPlane(plane EnforcementPlane, namespace, agentID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.entries[degradedKey(plane, namespace, agentID)]
	return ok
}

func (r *degradedRegistry) len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.entries)
}

// snapshot returns a DEEP copy so callers cannot mutate the registry through it.
//
// A shallow copy is not enough and the difference is not theoretical:
// PlaneResult.Details is a map[string]any, so `out[k] = v` copies the struct but
// shares the map header. A caller holding the snapshot could write through it
// into a live entry with no lock held, while a concurrent /health handler ranges
// over the same map — an unsynchronised concurrent map access, which Go turns
// into a runtime throw rather than a benign race.
func (r *degradedRegistry) snapshot() map[string]DegradedTarget {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]DegradedTarget, len(r.entries))
	for k, v := range r.entries {
		if v.target.Result.Details != nil {
			details := make(map[string]any, len(v.target.Result.Details))
			for dk, dv := range v.target.Result.Details {
				details[dk] = dv
			}
			v.target.Result.Details = details
		}
		out[k] = v.target
	}
	return out
}

// classifyAPIError maps a Kubernetes API error onto the three-valued outcome
// space. Everything that is not an unambiguous "the object does not exist"
// becomes ErrEnforcementUnavailable — including Forbidden, because a client that
// is denied the verb cannot enforce and must say so rather than reporting a
// verdict it never obtained.
func classifyAPIError(operation string, target TargetRef, err error) error {
	if err == nil {
		return nil
	}
	if apierrors.IsNotFound(err) {
		return fmt.Errorf("%s %s/%s: %w", operation, target.Namespace, target.AgentID, ErrTargetNotFound)
	}

	// Caller-side cancellation is NOT plane unavailability, and collapsing it is
	// the same category error this file exists to prevent, in reverse. An
	// operator who clicks stun and navigates away cancels r.Context(); the
	// in-flight request returns context.Canceled. The plane was healthy — WE
	// hung up, and the patch may well have been applied server-side. Reporting
	// that as blindness would mark a target degraded on no evidence at all.
	if errors.Is(err, context.Canceled) {
		return fmt.Errorf("%s %s/%s: caller cancelled the request: %w",
			operation, target.Namespace, target.AgentID, err)
	}

	// Two %w verbs, not "%w: %v". Flattening the cause with %v destroys
	// errors.Is/As for everything underneath — context.DeadlineExceeded,
	// apierrors.IsTooManyRequests, IsConflict, IsTimeout — leaving callers unable
	// to tell a rate-limit from a dead API server. go.mod is go 1.24, so
	// multiple %w is available and the single-verb form was a choice.
	if apierrors.IsForbidden(err) {
		// Still satisfies errors.Is(.., ErrEnforcementUnavailable) via the wrap —
		// a client denied the verb cannot enforce — but is separable for callers
		// that need to stop retrying a permanent decision.
		return fmt.Errorf("%s %s/%s: %w: %w", operation, target.Namespace, target.AgentID, ErrEnforcementDenied, err)
	}
	return fmt.Errorf("%s %s/%s: %w: %w", operation, target.Namespace, target.AgentID, ErrEnforcementUnavailable, err)
}

// unavailableFleetClient is installed when the real client could not be built —
// no in-cluster config and no usable KUBECONFIG.
//
// It is NOT a no-op. Every method returns ErrEnforcementUnavailable and records
// the target as degraded. This is deliberately the fallback rather than
// os.Exit(1): a crash-looping fleet-manager during an API-server outage means
// break-glass has to traverse the very plane that just failed, which is the
// failure mode the mission's containment constitution exists to prevent. The
// process stays up, serves topology, reports its own blindness through /health,
// and refuses to claim any enforcement it did not perform.
type unavailableFleetClient struct {
	cause            error
	defaultNamespace string
	degraded         *degradedRegistry
}

var _ FleetClient = (*unavailableFleetClient)(nil)

func newUnavailableFleetClient(cause error, defaultNamespace string) *unavailableFleetClient {
	if defaultNamespace == "" {
		defaultNamespace = DefaultAgentNamespace
	}
	return &unavailableFleetClient{
		cause:            cause,
		defaultNamespace: defaultNamespace,
		degraded:         newDegradedRegistry(),
	}
}

func (u *unavailableFleetClient) fail(plane EnforcementPlane, namespace, agentID, operation string) error {
	if namespace == "" {
		namespace = u.defaultNamespace
	}
	target := TargetRef{AgentID: agentID, Namespace: namespace}
	err := fmt.Errorf("%s: no enforcement plane client: %w: %v", operation, ErrEnforcementUnavailable, u.cause)
	u.degraded.mark(u.degraded.nextSeq(), plane, target, operation, err)
	return err
}

func (u *unavailableFleetClient) GetPodState(_ context.Context, namespace, agentID string) (string, error) {
	return StateUnknown, u.fail(PlaneFreeze, namespace, agentID, "get_pod_state")
}

func (u *unavailableFleetClient) SetPodState(_ context.Context, namespace, agentID, _ string) error {
	return u.fail(PlaneFreeze, namespace, agentID, "set_pod_state")
}

func (u *unavailableFleetClient) RevokeCredentials(_ context.Context, agentID string) error {
	return u.fail(PlaneBao, "", agentID, "revoke_credentials")
}

func (u *unavailableFleetClient) RestoreCredentials(_ context.Context, agentID string) error {
	return u.fail(PlaneBao, "", agentID, "restore_credentials")
}

func (u *unavailableFleetClient) Health(_ context.Context) error {
	return fmt.Errorf("no enforcement plane client: %w: %v", ErrEnforcementUnavailable, u.cause)
}

// DegradedTargets exposes the fail-closed registry for /health and for callers
// assembling a ContainmentDecision.
func (u *unavailableFleetClient) DegradedTargets() map[string]DegradedTarget {
	return u.degraded.snapshot()
}
