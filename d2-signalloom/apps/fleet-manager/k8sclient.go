package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
)

// k8sFleetClient is the first real FleetClient: it talks to the Kubernetes API
// through client-go and reads/writes the agent pod-state label contract.
//
// Credential operations are typed stubs that fail closed until SLER-P2-1
// (OpenBao lease revocation) and SLER-P2-2 (SPIRE entry eviction) land. They
// return ErrEnforcementUnavailable rather than nil on purpose: nil is the value
// a working revocation returns, so a stub that returns it re-creates exactly the
// silent-success defect this card exists to remove.
type k8sFleetClient struct {
	clientset        kubernetes.Interface
	spireClient      SpireClient
	defaultNamespace string
	degraded         *degradedRegistry
	// now is injectable so a test can prove the containment timestamp is
	// preserved across a retry rather than restamped — an assertion that a real
	// clock makes flaky-or-vacuous depending on how fast the test runs.
	now func() time.Time
}

// Compile-time proof the real client satisfies the orchestrator's contract.
var _ FleetClient = (*k8sFleetClient)(nil)

// newK8sFleetClient takes a kubernetes.Interface rather than a *rest.Config so
// the whole client is testable against client-go's fake clientset with no
// cluster present. The construction boundary is injectable by design.
func newK8sFleetClient(clientset kubernetes.Interface, defaultNamespace string) *k8sFleetClient {
	if defaultNamespace == "" {
		defaultNamespace = DefaultAgentNamespace
	}
	return &k8sFleetClient{
		clientset:        clientset,
		defaultNamespace: defaultNamespace,
		degraded:         newDegradedRegistry(),
		now:              time.Now,
	}
}

// newK8sFleetClientWithSpire constructs a k8sFleetClient with an explicit SpireClient.
func newK8sFleetClientWithSpire(clientset kubernetes.Interface, defaultNamespace string, spireClient SpireClient) *k8sFleetClient {
	c := newK8sFleetClient(clientset, defaultNamespace)
	c.spireClient = spireClient
	return c
}

// SetSpireClient configures or replaces the active SpireClient.
func (c *k8sFleetClient) SetSpireClient(sc SpireClient) {
	c.spireClient = sc
}

// SpireClient returns the active SpireClient, if configured.
func (c *k8sFleetClient) SpireClient() SpireClient {
	return c.spireClient
}

func (c *k8sFleetClient) namespaceOrDefault(namespace string) string {
	if namespace == "" {
		return c.defaultNamespace
	}
	return namespace
}

// agentNameFromID maps a fleet-config agent id onto the value carried in the
// signalloom.ai/agent-name label. The manifests name the Pod after the agent id
// ("agent-monitor") and label it with the id minus that prefix ("monitor"), so
// both forms have to be resolvable.
func agentNameFromID(agentID string) string {
	return strings.TrimPrefix(agentID, "agent-")
}

// resolvePod finds the Pod backing an agent id. It tries the direct name first
// (the fleet-agents manifests name pods after the agent id), then falls back to
// the agent-name label selector for any agent whose pod name diverges — the
// agent-swarm manifests are generated separately and are not guaranteed to
// agree with fleet-config on the pod name.
//
// More than one match is treated as unavailable, not as "pick the first". Acting
// on the wrong pod is a worse failure than declining to act, and an ambiguous
// target means the client genuinely does not know which workload to contain.
func (c *k8sFleetClient) resolvePod(ctx context.Context, namespace, agentID string) (*corev1.Pod, error) {
	namespace = c.namespaceOrDefault(namespace)
	target := TargetRef{AgentID: agentID, Namespace: namespace}

	pod, err := c.clientset.CoreV1().Pods(namespace).Get(ctx, agentID, metav1.GetOptions{})
	if err == nil {
		if pod == nil {
			// A nil object with a nil error is pathological, but a nil deref
			// downstream would surface as a panic rather than as unavailability.
			return nil, fmt.Errorf("get pod %s/%s: %w: API returned no object and no error",
				namespace, agentID, ErrEnforcementUnavailable)
		}
		return pod, nil
	}
	if !apierrors.IsNotFound(err) {
		// Connection failure, timeout, 5xx, Forbidden — the plane did not answer.
		return nil, classifyAPIError("get pod", target, err)
	}

	selector := fmt.Sprintf("%s=%s", AgentNameLabel, agentNameFromID(agentID))
	list, listErr := c.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if listErr != nil {
		return nil, classifyAPIError("list pods", target, listErr)
	}
	switch len(list.Items) {
	case 0:
		// Propagate the original NotFound: the plane answered, the pod is absent.
		return nil, classifyAPIError("resolve pod", target, err)
	case 1:
		return &list.Items[0], nil
	default:
		return nil, fmt.Errorf(
			"resolve pod %s/%s: %w: selector %q matched %d pods, target is ambiguous",
			namespace, agentID, ErrEnforcementUnavailable, selector, len(list.Items))
	}
}

// requireSentinelWatched refuses to act on a pod the stun sentinel does not
// watch.
//
// The sentinel's informer is filtered to signalloom.ai/agent=true
// (signalloom-stun-sentinel/main.go:303). Neither resolution path above enforces
// that: the direct Get is by name, and the selector fallback matches on
// agent-name. Patching a pod that lacks the discovery label writes all three
// containment labels and returns nil — a full success — for a workload that was
// never in the informer's cache and will therefore NEVER be frozen. The
// dashboard shows it contained, the registry stays clean, /health reports zero
// degraded targets, and the agent keeps running at full privilege.
//
// That is the original no-op defect reached sideways: every layer reporting a
// containment that did not happen. Labelling a pod is not containing it; the
// label is only a request the sentinel has to be able to see.
func requireSentinelWatched(pod *corev1.Pod, namespace, agentID string) error {
	if pod.Labels[AgentLabel] == "true" {
		return nil
	}
	return fmt.Errorf(
		"resolve pod %s/%s: %w: pod %q lacks %s=true, so the stun sentinel does not watch it and "+
			"labelling it would report a containment that can never be enforced",
		namespace, agentID, ErrEnforcementUnavailable, pod.Name, AgentLabel)
}

// record marks or clears the fail-closed registry for a target. A nil error and
// an ErrTargetNotFound both clear it: in each case the plane answered, so the
// client is not blind even though the second answer is negative.
// record files the outcome of ONE API call. seq is the ticket taken before that
// call, so a slow verdict cannot overwrite a fresher one.
func (c *k8sFleetClient) record(seq uint64, plane EnforcementPlane, namespace, agentID, operation string, err error) {
	namespace = c.namespaceOrDefault(namespace)
	target := TargetRef{AgentID: agentID, Namespace: namespace}
	if errors.Is(err, ErrEnforcementUnavailable) {
		c.degraded.mark(seq, plane, target, operation, err)
		return
	}
	// Either success or a definite negative answer such as ErrTargetNotFound.
	// Both prove THIS plane is reachable, so its stale blindness is cleared —
	// and no other plane's is, because this call proved nothing about them.
	c.degraded.clear(seq, plane, namespace, agentID)
}

// GetPodState reads the agent's signalloom.ai/state label.
//
// On failure it returns StateUnknown, never StateRunning. StateRunning is a
// legal reading from a healthy plane; returning it on failure is what made the
// old no-op client's blindness invisible.
func (c *k8sFleetClient) GetPodState(ctx context.Context, namespace, agentID string) (string, error) {
	seq := c.degraded.nextSeq()
	pod, err := c.resolvePod(ctx, namespace, agentID)
	c.record(seq, PlaneFreeze, namespace, agentID, "get_pod_state", err)
	if err != nil {
		return StateUnknown, err
	}

	state := pod.Labels[PodStateLabel]
	if state == "" {
		// The pod exists and carries no state label. A definite answer, so no
		// error — but not an invented state either.
		return StateUnknown, nil
	}
	return state, nil
}

// SetPodState writes the whole containment state in one strategic-merge patch.
//
// "The whole containment state" is three labels and three annotations, not one
// label. The sentinel's isPodStunned is an OR of THREE terms
// (signalloom-stun-sentinel/main.go:31-43): state==stunned, stunned=="true", or
// containment-mode=="frozen". Writing only the state label is enough to FREEZE a
// pod — but it is not enough to THAW one. Restore the state label alone and a
// stale containment-mode=frozen keeps the OR true, so the workload stays frozen
// while the dashboard reports it healthy. That is a split brain in the direction
// that lies reassuringly, which is the worst direction.
//
// The three provenance fields are cleared to "" rather than removed. A remove op
// is strictly worse here: Flux's .spec.ignore preserves a path only if the
// desired object declares it, so deleting the key drops it from the manifest's
// ignore surface and the next reconcile wipes it for good
// (measured and documented at apps/fe-signalloom/base/agents-cardvault.yaml:32-41).
//
// The patch is idempotent: re-applying the same state is a no-op for the API
// server and returns nil, which is what makes containment safe to retry.
func (c *k8sFleetClient) SetPodState(ctx context.Context, namespace, agentID, state string) error {
	seq := c.degraded.nextSeq()
	pod, err := c.resolvePod(ctx, namespace, agentID)
	if err != nil {
		c.record(seq, PlaneFreeze, namespace, agentID, "set_pod_state", err)
		return err
	}

	if err := requireSentinelWatched(pod, c.namespaceOrDefault(namespace), agentID); err != nil {
		c.record(seq, PlaneFreeze, namespace, agentID, "set_pod_state", err)
		return err
	}

	stunning := state == StateStunned
	containmentMode := ContainmentModeNone
	stunnedAt := ""
	stunReason := ""
	if stunning {
		containmentMode = ContainmentModeFrozen
		stunReason = StunReason

		// Preserve an existing containment timestamp rather than restamping it.
		//
		// A wall-clock value here makes the patch NON-idempotent, which quietly
		// contradicts the contract above: re-applying the same state produces a
		// different patch body, a new resourceVersion, a fresh watch event, and —
		// worst — overwrites "when was this contained" with "when did someone last
		// retry". That timestamp is what an incident timeline and P3's attested
		// record are built on, so a retry silently destroys the forensic value the
		// containment existed to capture. Retries are expected: the card requires
		// containment to be idempotent, and two overlapping cascades can cover the
		// same target.
		stunnedAt = pod.Annotations[StunnedAtAnnotation]
		if stunnedAt == "" {
			stunnedAt = c.now().UTC().Format(time.RFC3339)
		}
	}

	patch := map[string]any{
		"metadata": map[string]any{
			"labels": map[string]string{
				PodStateLabel:        PodStateLabelValue(state),
				StunnedLabel:         strconv.FormatBool(stunning),
				ContainmentModeLabel: containmentMode,
			},
			"annotations": map[string]string{
				StunnedAtAnnotation:    stunnedAt,
				StunReasonAnnotationAI: stunReason,
				StunReasonAnnotationIO: stunReason,
			},
		},
	}
	body, marshalErr := json.Marshal(patch)
	if marshalErr != nil {
		// Unreachable with the literal map above, but a silent skip here would
		// mean "patched" was reported for a patch never sent.
		wrapped := fmt.Errorf("set_pod_state %s/%s: %w: marshal patch: %v",
			c.namespaceOrDefault(namespace), agentID, ErrEnforcementUnavailable, marshalErr)
		c.record(seq, PlaneFreeze, namespace, agentID, "set_pod_state", wrapped)
		return wrapped
	}

	_, patchErr := c.clientset.CoreV1().Pods(c.namespaceOrDefault(namespace)).Patch(
		ctx, pod.Name, types.StrategicMergePatchType, body,
		metav1.PatchOptions{FieldManager: PodPatchFieldManager})
	classified := classifyAPIError("set_pod_state", TargetRef{AgentID: agentID, Namespace: c.namespaceOrDefault(namespace)}, patchErr)
	c.record(seq, PlaneFreeze, namespace, agentID, "set_pod_state", classified)
	return classified
}

// RevokeCredentials revokes the agent's credentials across OpenBao and SPIRE planes.
//
// SPIRE entry eviction is implemented for SLER-P2-2: it evicts the target agent's
// registration entry via gRPC, propagating any errors into the degraded registry and
// returning typed errors rather than discarding errors.
func (c *k8sFleetClient) RevokeCredentials(ctx context.Context, agentID string) error {
	seq := c.degraded.nextSeq()
	namespace := c.defaultNamespace
	spiffeID := fmt.Sprintf("spiffe://signalloom.demo/ns/%s/sa/%s", namespace, agentID)

	if c.spireClient != nil {
		req := SpireEvictionRequest{
			SchemaVersion:  CurrentSchemaVersion,
			IdempotencyKey: fmt.Sprintf("contain-%s-%d", agentID, c.now().UnixNano()),
			AgentID:        agentID,
			SPIFFEID:       spiffeID,
			Reason:         StunReason,
			Timestamp:      c.now().UTC().Format(time.RFC3339),
		}

		resp, err := c.spireClient.EvictAgent(ctx, req)
		if err != nil {
			c.record(seq, PlaneSpire, namespace, agentID, "revoke_credentials", err)
			return err
		}
		if resp != nil && resp.Outcome == OutcomeUnavailable {
			evictErr := fmt.Errorf("spire eviction failed: %s", resp.Error)
			c.record(seq, PlaneSpire, namespace, agentID, "revoke_credentials", evictErr)
			return evictErr
		}

		c.record(seq, PlaneSpire, namespace, agentID, "revoke_credentials", nil)
		return nil
	}

	err := fmt.Errorf("revoke_credentials %s/%s: %w: OpenBao lease revocation not implemented (SLER-P2-1)",
		c.defaultNamespace, agentID, ErrEnforcementUnavailable)
	c.record(seq, PlaneBao, c.defaultNamespace, agentID, "revoke_credentials", err)
	return err
}

// EvictSpireEntry directly executes SPIRE server registration entry eviction for a target agent.
func (c *k8sFleetClient) EvictSpireEntry(ctx context.Context, namespace, agentID string) (*SpireEvictionResponse, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)
	spiffeID := fmt.Sprintf("spiffe://signalloom.demo/ns/%s/sa/%s", namespace, agentID)

	if c.spireClient == nil {
		err := fmt.Errorf("evict_spire_entry %s/%s: %w: SPIRE client unconfigured (SLER-P2-2)",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneSpire, namespace, agentID, "evict_spire_entry", err)
		return &SpireEvictionResponse{
			SchemaVersion: CurrentSchemaVersion,
			AgentID:       agentID,
			Plane:         PlaneSpire,
			Outcome:       OutcomeUnavailable,
			Error:         err.Error(),
			Timestamp:     c.now().UTC().Format(time.RFC3339),
		}, err
	}

	req := SpireEvictionRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: fmt.Sprintf("evict-%s-%d", agentID, c.now().UnixNano()),
		AgentID:        agentID,
		SPIFFEID:       spiffeID,
		Reason:         StunReason,
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, err := c.spireClient.EvictAgent(ctx, req)
	if err != nil {
		c.record(seq, PlaneSpire, namespace, agentID, "evict_spire_entry", err)
		return resp, err
	}
	if resp != nil && resp.Outcome == OutcomeUnavailable {
		evictErr := fmt.Errorf("spire eviction failed: %s", resp.Error)
		c.record(seq, PlaneSpire, namespace, agentID, "evict_spire_entry", evictErr)
		return resp, evictErr
	}

	c.record(seq, PlaneSpire, namespace, agentID, "evict_spire_entry", nil)
	return resp, nil
}

// RestoreCredentials is a typed stub owned by SLER-P2-2.
//
// Note for the orchestrator: CascadeOrchestrator.Recover logs and continues past
// a RestoreCredentials failure (cascade.go:156) and still writes the running
// label. That is correct and must stay correct — if un-stunning became hard-
// dependent on the credential plane, break-glass would die with it.
func (c *k8sFleetClient) RestoreCredentials(_ context.Context, agentID string) error {
	err := fmt.Errorf("restore_credentials %s/%s: %w: SPIRE re-entry and OpenBao re-issue not implemented (SLER-P2-2)",
		c.defaultNamespace, agentID, ErrEnforcementUnavailable)
	c.record(c.degraded.nextSeq(), PlaneBao, c.defaultNamespace, agentID, "restore_credentials", err)
	return err
}

// Health probes API-server connectivity using only verbs the fleet-manager Role
// already grants (list on pods). Discovery would need no RBAC at all, but it
// also would not exercise the namespace and selector the client actually uses,
// so a Role change could break enforcement while Health stayed green.
func (c *k8sFleetClient) Health(ctx context.Context) error {
	_, err := c.clientset.CoreV1().Pods(c.defaultNamespace).List(ctx, metav1.ListOptions{
		LabelSelector: AgentLabel + "=true",
		Limit:         1,
	})
	if err != nil {
		return fmt.Errorf("health probe on %s: %w: %v", c.defaultNamespace, ErrEnforcementUnavailable, err)
	}
	if c.spireClient != nil {
		if spireErr := c.spireClient.Health(ctx); spireErr != nil {
			return fmt.Errorf("spire health probe: %w", spireErr)
		}
	}
	return nil
}

// DegradedTargets returns the fail-closed registry snapshot: every target the
// client is currently blind to, with a P1-2 PlaneResult carrying
// OutcomeUnavailable.
func (c *k8sFleetClient) DegradedTargets() map[string]DegradedTarget {
	return c.degraded.snapshot()
}

// IsDegraded reports whether a specific target is in fail-closed isolation.
func (c *k8sFleetClient) IsDegraded(namespace, agentID string) bool {
	return c.degraded.isDegraded(c.namespaceOrDefault(namespace), agentID)
}
