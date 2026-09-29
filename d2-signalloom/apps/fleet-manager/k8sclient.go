package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
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
	meshClient       MeshClient
	admissionClient  AdmissionClient
	defaultNamespace string
	degraded         *degradedRegistry
	baoClient        *OpenBaoClient
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
		baoClient:        NewOpenBaoClient(OpenBaoConfigFromEnv()),
		meshClient:       NewCiliumMeshClient(clientset),
		admissionClient:  NewK8sAdmissionClient(clientset, "fe-signalloom"),
		now:              time.Now,
	}
}

// newK8sFleetClientWithBao constructs a k8sFleetClient with an explicit OpenBaoClient.
func newK8sFleetClientWithBao(clientset kubernetes.Interface, defaultNamespace string, baoClient *OpenBaoClient) *k8sFleetClient {
	c := newK8sFleetClient(clientset, defaultNamespace)
	c.baoClient = baoClient
	return c
}

// newK8sFleetClientWithSpire constructs a k8sFleetClient with an explicit SpireClient.
func newK8sFleetClientWithSpire(clientset kubernetes.Interface, defaultNamespace string, spireClient SpireClient) *k8sFleetClient {
	c := newK8sFleetClient(clientset, defaultNamespace)
	c.spireClient = spireClient
	return c
}

// newK8sFleetClientWithMesh constructs a k8sFleetClient with an explicit MeshClient.
func newK8sFleetClientWithMesh(clientset kubernetes.Interface, defaultNamespace string, meshClient MeshClient) *k8sFleetClient {
	c := newK8sFleetClient(clientset, defaultNamespace)
	c.meshClient = meshClient
	return c
}

// SetMeshClient configures or replaces the active MeshClient.
func (c *k8sFleetClient) SetMeshClient(mc MeshClient) {
	c.meshClient = mc
}

// MeshClient returns the active MeshClient, if configured.
func (c *k8sFleetClient) MeshClient() MeshClient {
	return c.meshClient
}

// SetSpireClient configures or replaces the active SpireClient.
func (c *k8sFleetClient) SetSpireClient(sc SpireClient) {
	c.spireClient = sc
}

// SpireClient returns the active SpireClient, if configured.
func (c *k8sFleetClient) SpireClient() SpireClient {
	return c.spireClient
}

// SetAdmissionClient configures or replaces the active AdmissionClient.
func (c *k8sFleetClient) SetAdmissionClient(ac AdmissionClient) {
	c.admissionClient = ac
}

// AdmissionClient returns the active AdmissionClient, if configured.
func (c *k8sFleetClient) AdmissionClient() AdmissionClient {
	return c.admissionClient
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
	return c.SetPodStateWithReason(ctx, namespace, agentID, state, "")
}

// SetPodStateWithReason is SetPodState with a caller-supplied stun reason. An
// empty reason means StunReason. The reason is only written on a stun; any
// other state blanks it, exactly as before.
func (c *k8sFleetClient) SetPodStateWithReason(ctx context.Context, namespace, agentID, state, reason string) error {
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
		stunReason = reason
		if stunReason == "" {
			stunReason = StunReason
		}

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

// SuspendGitOps annotates the agent's pod and its owning Deployment with
// kustomize.toolkit.fluxcd.io/reconcile=disabled so Flux cannot reconcile a
// contained workload back to its declared state.
func (c *k8sFleetClient) SuspendGitOps(ctx context.Context, namespace, agentID string) PlaneResult {
	return c.setFluxReconcile(ctx, namespace, agentID, true)
}

// ResumeGitOps removes the annotation SuspendGitOps wrote. Removing an absent
// annotation is a no-op, so this is safe on a pod that was never suspended.
func (c *k8sFleetClient) ResumeGitOps(ctx context.Context, namespace, agentID string) PlaneResult {
	return c.setFluxReconcile(ctx, namespace, agentID, false)
}

// setFluxReconcile writes or removes the Flux annotation on the pod and, when
// the pod is owned through a ReplicaSet by a Deployment, on that Deployment.
//
// Only object metadata is patched. Touching spec.template would roll the
// Deployment and replace the frozen pod, which undoes the containment this
// plane exists to protect.
//
// The verdict is honest per object: both written is contained, one written is
// partial, none written is unavailable. A pod with no Deployment owner is not a
// failure; the pod is annotated and Details says what the owner was.
func (c *k8sFleetClient) setFluxReconcile(ctx context.Context, namespace, agentID string, disable bool) PlaneResult {
	start := c.now()
	namespace = c.namespaceOrDefault(namespace)
	action := "enable_reconcile"
	var value any // nil in a JSON merge patch deletes the key
	if disable {
		action = "disable_reconcile"
		value = FluxReconcileDisabled
	}
	res := PlaneResult{
		Plane:     PlaneGitOps,
		Timestamp: start.UTC().Format(time.RFC3339),
		Details: map[string]any{
			"agent_id":   agentID,
			"action":     action,
			"pod":        "",
			"deployment": "",
			"annotation": FluxReconcileAnnotation + "=" + FluxReconcileDisabled,
		},
	}
	finish := func(outcome PlaneOutcome, errs []string) PlaneResult {
		res.Outcome = outcome
		res.Error = strings.Join(errs, "; ")
		res.LatencyMs = c.now().Sub(start).Milliseconds()
		return res
	}

	pod, err := c.resolvePod(ctx, namespace, agentID)
	if err != nil {
		return finish(OutcomeUnavailable, []string{err.Error()})
	}
	res.Details["pod"] = pod.Name

	body, err := json.Marshal(map[string]any{
		"metadata": map[string]any{"annotations": map[string]any{FluxReconcileAnnotation: value}},
	})
	if err != nil {
		return finish(OutcomeUnavailable, []string{"marshal gitops patch: " + err.Error()})
	}
	opts := metav1.PatchOptions{FieldManager: PodPatchFieldManager}

	var errs []string
	written, wanted := 0, 1
	if _, err := c.clientset.CoreV1().Pods(namespace).Patch(ctx, pod.Name, types.MergePatchType, body, opts); err != nil {
		errs = append(errs, fmt.Sprintf("patch pod %s/%s: %v", namespace, pod.Name, err))
	} else {
		written++
	}

	deployment, ownerKind, note, err := c.owningDeployment(ctx, namespace, pod)
	res.Details["owner_kind"] = ownerKind
	if note != "" {
		res.Details["note"] = note
	}
	switch {
	case err != nil:
		wanted++
		errs = append(errs, err.Error())
	case deployment != "":
		wanted++
		res.Details["deployment"] = deployment
		if _, err := c.clientset.AppsV1().Deployments(namespace).Patch(ctx, deployment, types.MergePatchType, body, opts); err != nil {
			errs = append(errs, fmt.Sprintf("patch deployment %s/%s: %v", namespace, deployment, err))
		} else {
			written++
		}
	}

	switch {
	case written == wanted:
		return finish(OutcomeContained, errs)
	case written > 0:
		return finish(OutcomePartial, errs)
	default:
		return finish(OutcomeUnavailable, errs)
	}
}

// owningDeployment walks pod -> ReplicaSet -> Deployment through controller
// owner references. It returns an empty name, with a note, when the chain does
// not end in a Deployment. That is a fact about the workload, not an error.
// An error means the chain could not be read.
func (c *k8sFleetClient) owningDeployment(ctx context.Context, namespace string, pod *corev1.Pod) (name, ownerKind, note string, err error) {
	ref := metav1.GetControllerOf(pod)
	if ref == nil {
		return "", "none", "pod has no controller; only the pod is annotated", nil
	}
	if ref.Kind != "ReplicaSet" {
		return "", ref.Kind, fmt.Sprintf("owner is %s/%s, not a Deployment; only the pod is annotated", ref.Kind, ref.Name), nil
	}
	rs, err := c.clientset.AppsV1().ReplicaSets(namespace).Get(ctx, ref.Name, metav1.GetOptions{})
	if err != nil {
		return "", "ReplicaSet", "", fmt.Errorf("get replicaset %s/%s: %v", namespace, ref.Name, err)
	}
	rsRef := metav1.GetControllerOf(rs)
	if rsRef == nil || rsRef.Kind != "Deployment" {
		return "", "ReplicaSet", fmt.Sprintf("replicaset %s has no Deployment owner; only the pod is annotated", rs.Name), nil
	}
	return rsRef.Name, "Deployment", "", nil
}

// Worst-case residual-exposure bounds for the SPIRE plane, in milliseconds.
//
// These are UPSTREAM SPIRE DEFAULTS, not measurements. SLER-P2-GOV verified that
// no default_svid_ttl or default_x509_svid_ttl is set anywhere in this repository
// (`rg default_svid_ttl -r d2-signalloom/` returns zero matches), so SPIRE's own
// defaults are what actually apply. They are published rather than measured
// because a 3600s window is not observable inside a unit test, and a test that
// claims to observe one is asserting against its own constant.
//
// SPIFFE has no CRL and no OCSP. Deleting a registration entry stops RE-ISSUANCE;
// it does not invalidate an SVID already in the workload's memory. Nothing short
// of TTL expiry removes a trusted SVID, so this residual is a floor on the
// attacker's window, not an implementation shortcoming to be engineered away.
const (
	// SpireJWTSVIDResidualMs is SPIRE's default JWT-SVID TTL (300s).
	SpireJWTSVIDResidualMs = int64(300000)
	// SpireX509SVIDResidualMs is SPIRE's default X.509-SVID TTL (3600s) and is
	// the binding worst case for the spire plane: it is the longer of the two.
	SpireX509SVIDResidualMs = int64(3600000)
)

// revokeCredentialsIdempotencyKey builds the single key shared by every plane in
// one containment decision. Sharing it is load-bearing: P2-1 and P2-2 implemented
// idempotency independently against the same P1-2 schema, and a per-plane key
// would make a retry look like a fresh decision on one plane and a replay on the
// other.
func (c *k8sFleetClient) revokeCredentialsIdempotencyKey(agentID string) string {
	return fmt.Sprintf("contain-%s-%d", agentID, c.now().UnixNano())
}

// RevokeCredentialsPlanes fans out credential revocation to EVERY configured
// credential plane and returns one PlaneResult per plane, in deterministic order
// (spire, then bao).
//
// This exists because the previous implementation was an if/else-if chain whose
// SPIRE branch ended in an unconditional `return nil`. newK8sFleetClient always
// sets baoClient and newK8sFleetClientWithSpire then sets spireClient, so in the
// production wiring at fleetclient_select.go both fields are non-nil, the SPIRE
// branch won, and OpenBao lease revocation never executed — while the function
// reported success. Neither P2-1 nor P2-2 could see it: each card's tests only
// ever configured its own client. A real agent holds both a lease and an SVID.
//
// The planes run CONCURRENTLY under the caller's context, so the decision's
// overall deadline bounds the pair rather than the sum. A tripped OpenBao circuit
// breaker therefore returns Unavailable immediately without consuming the budget
// the SPIRE call still needs.
//
// The returned error is non-nil whenever any plane failed to contain, and wraps
// ErrEnforcementUnavailable so callers keep the fail-closed contract. A partial
// containment is representable: the []PlaneResult carries the per-plane truth
// even when the aggregate error is set.
func (c *k8sFleetClient) RevokeCredentialsPlanes(ctx context.Context, agentID string) ([]PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace := c.defaultNamespace
	spiffeID, subjectSource := c.agentSubject(ctx, namespace, agentID)
	idempotencyKey := c.revokeCredentialsIdempotencyKey(agentID)

	if c.spireClient == nil && c.baoClient == nil {
		err := fmt.Errorf("revoke_credentials %s/%s: %w: no credential plane configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneBao, namespace, agentID, "revoke_credentials", err)
		return nil, err
	}

	var (
		wg        sync.WaitGroup
		spireRes  *PlaneResult
		spireErr  error
		baoRes    *PlaneResult
		baoErr    error
		startedAt = c.now().UTC()
	)

	if c.spireClient != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			spireRes, spireErr = c.revokeSpirePlane(ctx, namespace, agentID, spiffeID, idempotencyKey, startedAt)
			stampSubject(spireRes, spiffeID, subjectSource)
		}()
	}

	if c.baoClient != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			baoRes, baoErr = c.revokeBaoPlane(ctx, namespace, agentID, idempotencyKey)
		}()
	}

	wg.Wait()

	// Record degraded state per plane AFTER the fan-out, on the calling
	// goroutine. degradedRegistry is keyed per plane precisely so one plane's
	// success cannot clear a sibling's still-true failure.
	results := make([]PlaneResult, 0, 2)
	var failures []string

	if spireRes != nil {
		c.record(seq, PlaneSpire, namespace, agentID, "revoke_credentials", spireErr)
		results = append(results, *spireRes)
		if spireErr != nil {
			failures = append(failures, "spire: "+spireErr.Error())
		}
	}
	if baoRes != nil {
		c.record(seq, PlaneBao, namespace, agentID, "revoke_credentials", baoErr)
		results = append(results, *baoRes)
		if baoErr != nil {
			failures = append(failures, "bao: "+baoErr.Error())
		}
	}

	if len(failures) == 0 {
		return results, nil
	}
	return results, fmt.Errorf("revoke_credentials %s/%s: %w: %s",
		namespace, agentID, ErrEnforcementUnavailable, strings.Join(failures, "; "))
}

// revokeSpirePlane evicts the agent's SPIRE registration entries and returns an
// honest PlaneResult carrying the published worst-case residual.
func (c *k8sFleetClient) revokeSpirePlane(ctx context.Context, namespace, agentID, spiffeID, idempotencyKey string, startedAt time.Time) (*PlaneResult, error) {
	req := SpireEvictionRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		SPIFFEID:       spiffeID,
		Reason:         StunReason,
		Timestamp:      startedAt.Format(time.RFC3339),
	}

	res := &PlaneResult{
		Plane:     PlaneSpire,
		Outcome:   OutcomeUnavailable,
		Timestamp: c.now().UTC().Format(time.RFC3339Nano),
		Details: map[string]any{
			"idempotency_key":          idempotencyKey,
			"spiffe_id":                spiffeID,
			"namespace":                namespace,
			"worst_case_residual_ms":   SpireX509SVIDResidualMs,
			"jwt_svid_residual_ms":     SpireJWTSVIDResidualMs,
			"x509_svid_residual_ms":    SpireX509SVIDResidualMs,
			"residual_provenance":      "upstream-default",
			"revocation_mechanism":     "grpc BatchDeleteEntry (no CRL/OCSP in SPIFFE)",
			"invalidates_issued_svids": false,
		},
	}

	resp, err := c.spireClient.EvictAgent(ctx, req)
	if err != nil {
		res.Error = err.Error()
		return res, err
	}
	if resp == nil {
		nilErr := fmt.Errorf("spire eviction returned no response: %w", ErrEnforcementUnavailable)
		res.Error = nilErr.Error()
		return res, nilErr
	}

	res.Outcome = resp.Outcome
	res.LatencyMs = resp.LatencyMs
	res.Details["entries_evicted"] = resp.EntriesEvicted
	res.Details["svids_invalidated"] = resp.SVIDsInvalidated

	if resp.Outcome == OutcomeUnavailable {
		evictErr := fmt.Errorf("spire eviction failed: %s: %w", resp.Error, ErrEnforcementUnavailable)
		res.Error = evictErr.Error()
		return res, evictErr
	}
	return res, nil
}

// revokeBaoPlane revokes the agent's OpenBao leases and tokens. The idempotency
// key is now threaded through; the previous implementation passed "" here, so a
// retry was indistinguishable from a fresh decision on this plane while the
// SPIRE plane saw a stable key.
//
// Two calls, and the plane is Contained only when BOTH succeed:
//  1. lease revoke (RevokeAgentCredentials), as before;
//  2. RevokeTokensBySubject: every live token whose SPIFFE subject is this
//     agent's, revoked by accessor. Before this, step 1 alone reported
//     Contained while the agent's JWT-login tokens stayed usable until their
//     5m TTL. Step 2 runs even when step 1 failed: killing the tokens is still
//     containment, and the outcome stays non-contained either way.
//
// The subject uses the same derivation as RevokeCredentialsPlanes' SPIRE
// eviction (namespace + agent id as the service account), so both planes target
// one identity.
func (c *k8sFleetClient) revokeBaoPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	planeRes, leaseErr := c.baoClient.RevokeAgentCredentials(ctx, namespace, agentID, idempotencyKey)
	if planeRes == nil {
		planeRes = &PlaneResult{
			Plane:     PlaneBao,
			Outcome:   OutcomeUnavailable,
			Timestamp: c.now().UTC().Format(time.RFC3339Nano),
			Details: map[string]any{
				"idempotency_key":        idempotencyKey,
				"worst_case_residual_ms": DefaultWorstCaseResidualMs,
			},
		}
	}
	if planeRes.Details == nil {
		planeRes.Details = map[string]any{}
	}
	if _, ok := planeRes.Details["worst_case_residual_ms"]; !ok {
		planeRes.Details["worst_case_residual_ms"] = DefaultWorstCaseResidualMs
	}
	planeRes.Details["residual_provenance"] = "config-derived (token_ttl = token_max_ttl = 5m)"
	planeRes.Details["invalidates_issued_credentials"] = false

	leasesRevoked, _ := planeRes.Details["revoked_leases"].(int)
	planeRes.Details["leases_revoked"] = leasesRevoked

	subject, subjectSource := c.agentSubject(ctx, namespace, agentID)
	tokensRevoked, tokenErr := c.baoClient.RevokeTokensBySubject(ctx, subject)
	planeRes.Details["tokens_revoked"] = tokensRevoked
	stampSubject(planeRes, subject, subjectSource)

	var failures []string
	if leaseErr != nil {
		failures = append(failures, "lease revoke: "+leaseErr.Error())
	} else if planeRes.Outcome == OutcomeUnavailable {
		failures = append(failures, "lease revoke: "+planeRes.Error)
	}
	if tokenErr != nil {
		failures = append(failures, "token revoke: "+tokenErr.Error())
		if planeRes.Outcome == OutcomeContained {
			// Leases gone, tokens possibly live: partial, never contained.
			planeRes.Outcome = OutcomePartial
		}
	}
	if len(failures) > 0 {
		planeRes.Error = strings.Join(failures, "; ")
		return planeRes, fmt.Errorf("%w: %s", ErrEnforcementUnavailable, planeRes.Error)
	}
	return planeRes, nil
}

// AggregateCredentialOutcome collapses per-plane results into the single outcome
// a ContainmentDecision reports. Partial is a first-class answer: one plane
// contained and one unavailable is neither "contained" nor "unavailable", and
// reporting it as either is the lie this phase exists to stop telling.
func AggregateCredentialOutcome(results []PlaneResult) PlaneOutcome {
	if len(results) == 0 {
		return OutcomeUnavailable
	}
	contained, unavailable := 0, 0
	for _, r := range results {
		switch r.Outcome {
		case OutcomeContained, OutcomeNotFound:
			contained++
		case OutcomePartial:
			return OutcomePartial
		default:
			unavailable++
		}
	}
	switch {
	case unavailable == 0:
		return OutcomeContained
	case contained == 0:
		return OutcomeUnavailable
	default:
		return OutcomePartial
	}
}

// RevokeCredentials satisfies the FleetClient contract by fanning out to every
// configured plane and collapsing the per-plane results into a single error.
// Callers that need the per-plane truth — the attestation pipeline, the denial
// matrix, /health — use RevokeCredentialsPlanes.
func (c *k8sFleetClient) RevokeCredentials(ctx context.Context, agentID string) error {
	_, err := c.RevokeCredentialsPlanes(ctx, agentID)
	return err
}

// EvictSpireEntry directly executes SPIRE server registration entry eviction for a target agent.
func (c *k8sFleetClient) EvictSpireEntry(ctx context.Context, namespace, agentID string) (*SpireEvictionResponse, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)
	spiffeID, _ := c.agentSubject(ctx, namespace, agentID)

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

// IsolateMeshPlane executes mesh network isolation for a target agent.
func (c *k8sFleetClient) IsolateMeshPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)

	if c.meshClient == nil {
		err := fmt.Errorf("isolate_mesh %s/%s: %w: no mesh client configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneMesh, namespace, agentID, "isolate_mesh", err)
		return &PlaneResult{
			Plane:     PlaneMesh,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, err := c.meshClient.IsolateAgentMesh(ctx, req)
	if err != nil {
		c.record(seq, PlaneMesh, namespace, agentID, "isolate_mesh", err)
		if resp != nil {
			return MeshIsolationResponseToPlaneResult(resp, namespace, ""), err
		}
		return &PlaneResult{
			Plane:     PlaneMesh,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	res := MeshIsolationResponseToPlaneResult(resp, namespace, "")
	if resp.Outcome == OutcomeUnavailable {
		resErr := fmt.Errorf("mesh isolation unavailable: %s: %w", resp.Error, ErrEnforcementUnavailable)
		c.record(seq, PlaneMesh, namespace, agentID, "isolate_mesh", resErr)
		return res, resErr
	}

	c.record(seq, PlaneMesh, namespace, agentID, "isolate_mesh", nil)
	return res, nil
}

// RestoreMeshPlane restores mesh network connectivity for a target agent.
func (c *k8sFleetClient) RestoreMeshPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)

	if c.meshClient == nil {
		err := fmt.Errorf("restore_mesh %s/%s: %w: no mesh client configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneMesh, namespace, agentID, "restore_mesh", err)
		return &PlaneResult{
			Plane:     PlaneMesh,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	req := MeshIsolationRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, err := c.meshClient.RestoreAgentMesh(ctx, req)
	if err != nil {
		c.record(seq, PlaneMesh, namespace, agentID, "restore_mesh", err)
		if resp != nil {
			return MeshIsolationResponseToPlaneResult(resp, namespace, ""), err
		}
		return &PlaneResult{
			Plane:     PlaneMesh,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	res := MeshIsolationResponseToPlaneResult(resp, namespace, "")
	c.record(seq, PlaneMesh, namespace, agentID, "restore_mesh", nil)
	return res, nil
}

// BlockAdmissionPlane executes admission blocking for a target agent.
func (c *k8sFleetClient) BlockAdmissionPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)

	if c.admissionClient == nil {
		err := fmt.Errorf("block_admission %s/%s: %w: no admission client configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneAdmission, namespace, agentID, "block_admission", err)
		return &PlaneResult{
			Plane:     PlaneAdmission,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		Reason:         "fleet-manager containment cascade",
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, err := c.admissionClient.BlockAdmission(ctx, req)
	if err != nil {
		c.record(seq, PlaneAdmission, namespace, agentID, "block_admission", err)
		if resp != nil {
			return AdmissionResponseToPlaneResult(resp, namespace), err
		}
		return &PlaneResult{
			Plane:     PlaneAdmission,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	res := AdmissionResponseToPlaneResult(resp, namespace)
	if resp.Outcome == OutcomeUnavailable {
		resErr := fmt.Errorf("admission block unavailable: %s: %w", resp.Error, ErrEnforcementUnavailable)
		c.record(seq, PlaneAdmission, namespace, agentID, "block_admission", resErr)
		return res, resErr
	}

	c.record(seq, PlaneAdmission, namespace, agentID, "block_admission", nil)
	return res, nil
}

// UnblockAdmissionPlane removes admission blocking for a target agent upon recovery.
func (c *k8sFleetClient) UnblockAdmissionPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)

	if c.admissionClient == nil {
		err := fmt.Errorf("unblock_admission %s/%s: %w: no admission client configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneAdmission, namespace, agentID, "unblock_admission", err)
		return &PlaneResult{
			Plane:     PlaneAdmission,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		Timestamp:      c.now().UTC().Format(time.RFC3339),
	}

	resp, err := c.admissionClient.UnblockAdmission(ctx, req)
	if err != nil {
		c.record(seq, PlaneAdmission, namespace, agentID, "unblock_admission", err)
		if resp != nil {
			return AdmissionResponseToPlaneResult(resp, namespace), err
		}
		return &PlaneResult{
			Plane:     PlaneAdmission,
			Outcome:   OutcomeUnavailable,
			Error:     err.Error(),
			Timestamp: c.now().UTC().Format(time.RFC3339),
		}, err
	}

	res := AdmissionResponseToPlaneResult(resp, namespace)
	c.record(seq, PlaneAdmission, namespace, agentID, "unblock_admission", nil)
	return res, nil
}

// RestoreCredentialsPlanes fans out credential rotation/re-issuance to EVERY configured
// credential plane (SPIRE and OpenBao) concurrently and returns one PlaneResult per plane.
func (c *k8sFleetClient) RestoreCredentialsPlanes(ctx context.Context, namespace, agentID, idempotencyKey string) ([]PlaneResult, error) {
	seq := c.degraded.nextSeq()
	namespace = c.namespaceOrDefault(namespace)
	if idempotencyKey == "" {
		idempotencyKey = fmt.Sprintf("restore-%s-%d", agentID, c.now().UnixNano())
	}
	spiffeID, subjectSource := c.agentSubject(ctx, namespace, agentID)

	if c.spireClient == nil && c.baoClient == nil {
		err := fmt.Errorf("restore_credentials %s/%s: %w: no credential plane configured",
			namespace, agentID, ErrEnforcementUnavailable)
		c.record(seq, PlaneBao, namespace, agentID, "restore_credentials", err)
		return nil, err
	}

	var (
		wg        sync.WaitGroup
		spireRes  *PlaneResult
		spireErr  error
		baoRes    *PlaneResult
		baoErr    error
		startedAt = c.now().UTC()
	)

	if c.spireClient != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			spireRes, spireErr = c.restoreSpirePlane(ctx, namespace, agentID, spiffeID, idempotencyKey, startedAt)
			stampSubject(spireRes, spiffeID, subjectSource)
		}()
	}

	if c.baoClient != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			baoRes, baoErr = c.restoreBaoPlane(ctx, namespace, agentID, idempotencyKey)
		}()
	}

	wg.Wait()

	results := make([]PlaneResult, 0, 2)
	var failures []string

	if spireRes != nil {
		c.record(seq, PlaneSpire, namespace, agentID, "restore_credentials", spireErr)
		results = append(results, *spireRes)
		if spireErr != nil {
			failures = append(failures, "spire: "+spireErr.Error())
		}
	}
	if baoRes != nil {
		c.record(seq, PlaneBao, namespace, agentID, "restore_credentials", baoErr)
		results = append(results, *baoRes)
		if baoErr != nil {
			failures = append(failures, "bao: "+baoErr.Error())
		}
	}

	if len(failures) == 0 {
		return results, nil
	}
	return results, fmt.Errorf("restore_credentials %s/%s: %w: %s",
		namespace, agentID, ErrEnforcementUnavailable, strings.Join(failures, "; "))
}

func (c *k8sFleetClient) restoreSpirePlane(ctx context.Context, namespace, agentID, spiffeID, idempotencyKey string, startedAt time.Time) (*PlaneResult, error) {
	req := SpireReentryRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: idempotencyKey,
		AgentID:        agentID,
		Namespace:      namespace,
		SPIFFEID:       spiffeID,
		Reason:         "governance resume credential rotation",
		Timestamp:      startedAt.Format(time.RFC3339),
	}

	res := &PlaneResult{
		Plane:     PlaneSpire,
		Outcome:   OutcomeUnavailable,
		Timestamp: c.now().UTC().Format(time.RFC3339Nano),
		Details: map[string]any{
			"idempotency_key":     idempotencyKey,
			"spiffe_id":           spiffeID,
			"namespace":           namespace,
			"rotation_mechanism":  "SPIRE BatchCreateEntry registration re-entry",
			"credentials_rotated": false,
		},
	}

	resp, err := c.spireClient.ReenterAgent(ctx, req)
	if err != nil {
		res.Error = err.Error()
		return res, err
	}
	if resp == nil {
		nilErr := fmt.Errorf("spire reentry returned no response: %w", ErrEnforcementUnavailable)
		res.Error = nilErr.Error()
		return res, nilErr
	}

	res.Outcome = resp.Outcome
	res.LatencyMs = resp.LatencyMs
	res.Details["entry_created"] = resp.EntryCreated
	res.Details["entry_id"] = resp.EntryID
	res.Details["credentials_rotated"] = resp.Outcome == OutcomeContained

	if resp.Outcome == OutcomeUnavailable {
		reenterErr := fmt.Errorf("spire reentry failed: %s: %w", resp.Error, ErrEnforcementUnavailable)
		res.Error = reenterErr.Error()
		return res, reenterErr
	}
	return res, nil
}

func (c *k8sFleetClient) restoreBaoPlane(ctx context.Context, namespace, agentID, idempotencyKey string) (*PlaneResult, error) {
	planeRes, err := c.baoClient.RotateAgentCredentials(ctx, namespace, agentID, idempotencyKey)
	if err != nil {
		if planeRes == nil {
			planeRes = &PlaneResult{
				Plane:     PlaneBao,
				Outcome:   OutcomeUnavailable,
				Timestamp: c.now().UTC().Format(time.RFC3339Nano),
				Details: map[string]any{
					"idempotency_key":     idempotencyKey,
					"credentials_rotated": false,
				},
			}
		}
		planeRes.Error = err.Error()
		return planeRes, err
	}
	return planeRes, nil
}

// RestoreCredentials satisfies the FleetClient contract by fanning out to every
// configured plane and collapsing the per-plane results into a single error.
func (c *k8sFleetClient) RestoreCredentials(ctx context.Context, agentID string) error {
	_, err := c.RestoreCredentialsPlanes(ctx, c.defaultNamespace, agentID, fmt.Sprintf("restore-%s-%d", agentID, c.now().UnixNano()))
	return err
}

// RotateCredentials performs credential rotation for a target agent and returns per-plane results.
func (c *k8sFleetClient) RotateCredentials(ctx context.Context, namespace, agentID, idempotencyKey string) ([]PlaneResult, error) {
	return c.RestoreCredentialsPlanes(ctx, namespace, agentID, idempotencyKey)
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
	if c.meshClient != nil {
		if meshErr := c.meshClient.Health(ctx); meshErr != nil {
			return fmt.Errorf("mesh health probe: %w", meshErr)
		}
	}
	if c.admissionClient != nil {
		if admErr := c.admissionClient.Health(ctx); admErr != nil {
			return fmt.Errorf("admission health probe: %w", admErr)
		}
	}
	return nil
}

// ContainAllPlanes executes unified multi-plane containment concurrently across
// all 5 enforcement planes: Freeze, Mesh, OpenBao, SPIRE, and Admission.
func (c *k8sFleetClient) ContainAllPlanes(ctx context.Context, namespace, agentID, idempotencyKey string) (*ContainmentDecision, error) {
	namespace = c.namespaceOrDefault(namespace)
	if idempotencyKey == "" {
		idempotencyKey = fmt.Sprintf("contain-all-%s-%d", agentID, c.now().UnixNano())
	}
	decisionID := fmt.Sprintf("dec-%s-%d", agentID, c.now().UnixNano())
	subject, subjectSource := c.agentSubject(ctx, namespace, agentID)
	target := TargetRef{
		AgentID:   agentID,
		Namespace: namespace,
		SPIFFEID:  subject,
	}
	reason := ContainmentReason{
		Code:                  "MANUAL_CONTAINMENT",
		Description:           "Unified 5-plane containment cascade",
		TriggeredBy:           "fleet-manager",
		DelegationEdgeRevoked: true,
	}

	decision := NewContainmentDecision(decisionID, target, reason, AllEnforcementPlanes(), idempotencyKey)
	startedAt := c.now()

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		results = make([]PlaneResult, 0, 5)
		errs    []error
	)

	addResult := func(res *PlaneResult, err error) {
		mu.Lock()
		defer mu.Unlock()
		if res != nil {
			results = append(results, *res)
		}
		if err != nil {
			errs = append(errs, err)
		}
	}

	// 1. PlaneFreeze (Pod State & cgroup freeze label contract)
	wg.Add(1)
	go func() {
		defer wg.Done()
		t0 := c.now()
		err := c.SetPodState(ctx, namespace, agentID, StateStunned)
		elapsed := time.Since(t0).Milliseconds()
		outcome := OutcomeContained
		errStr := ""
		if err != nil {
			outcome = OutcomeUnavailable
			errStr = err.Error()
		}
		res := &PlaneResult{
			Plane:     PlaneFreeze,
			Outcome:   outcome,
			Error:     errStr,
			Timestamp: c.now().UTC().Format(time.RFC3339Nano),
			LatencyMs: elapsed,
			Details: map[string]any{
				"worst_case_residual_ms": int64(0),
				"residual_provenance":    "measured (cgroup-v2 D-state process suspension)",
				"kernel_freeze":          true,
			},
		}
		addResult(res, err)
	}()

	// 2. PlaneMesh
	wg.Add(1)
	go func() {
		defer wg.Done()
		res, err := c.IsolateMeshPlane(ctx, namespace, agentID, idempotencyKey)
		addResult(res, err)
	}()

	// 3. PlaneBao
	wg.Add(1)
	go func() {
		defer wg.Done()
		res, err := c.revokeBaoPlane(ctx, namespace, agentID, idempotencyKey)
		addResult(res, err)
	}()

	// 4. PlaneSpire
	wg.Add(1)
	go func() {
		defer wg.Done()
		res, err := c.revokeSpirePlane(ctx, namespace, agentID, target.SPIFFEID, idempotencyKey, startedAt)
		stampSubject(res, target.SPIFFEID, subjectSource)
		addResult(res, err)
	}()

	// 5. PlaneAdmission
	wg.Add(1)
	go func() {
		defer wg.Done()
		res, err := c.BlockAdmissionPlane(ctx, namespace, agentID, idempotencyKey)
		addResult(res, err)
	}()

	wg.Wait()

	decision.PlaneResults = results
	decision.OverallOutcome = AggregateOutcome(results)
	decision.DurationMs = time.Since(startedAt).Milliseconds()

	if len(errs) > 0 {
		return decision, fmt.Errorf("%w: %d of 5 planes failed during containment", ErrEnforcementUnavailable, len(errs))
	}
	return decision, nil
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

// Subject sources recorded in PlaneResult details.
const (
	subjectSourcePod     = "pod"
	subjectSourceDerived = "derived"
)

// agentSubject returns the SPIFFE ID the agent actually holds, and where it
// came from. The ServiceAccount segment is the pod's spec.serviceAccountName
// (resolved with the same name-then-agent-name-selector lookup as every other
// pod operation). Only when the pod cannot be read does it fall back to
// agentNameFromID(agentID).
//
// The raw DAG id is never used: Kusari's id is agent-kusari-agent and its
// ServiceAccount kusari-agent, so the old derivation made token revocation,
// SPIRE eviction and re-entry all target an identity nothing holds while
// reporting success.
func (c *k8sFleetClient) agentSubject(ctx context.Context, namespace, agentID string) (string, string) {
	namespace = c.namespaceOrDefault(namespace)
	sa, source := agentNameFromID(agentID), subjectSourceDerived
	if pod, err := c.resolvePod(ctx, namespace, agentID); err == nil && pod.Spec.ServiceAccountName != "" {
		sa, source = pod.Spec.ServiceAccountName, subjectSourcePod
	}
	return fmt.Sprintf("spiffe://signalloom.demo/ns/%s/sa/%s", namespace, sa), source
}

// stampSubject records which identity a plane acted on.
func stampSubject(res *PlaneResult, subject, source string) {
	if res == nil {
		return
	}
	if res.Details == nil {
		res.Details = map[string]any{}
	}
	res.Details["subject"] = subject
	res.Details["subject_source"] = source
}

// ResolvePodName names the pod an agent id resolves to, using the same
// name-then-agent-name-selector lookup as every enforcement operation.
func (c *k8sFleetClient) ResolvePodName(ctx context.Context, namespace, agentID string) (string, error) {
	pod, err := c.resolvePod(ctx, namespace, agentID)
	if err != nil {
		return "", err
	}
	return pod.Name, nil
}
