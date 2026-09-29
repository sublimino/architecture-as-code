package main

// Cross-plane consistency: does every enforcement plane agree with the pod?
//
// A stun writes to four independent systems — pod labels, OpenBao, SPIRE and
// the Flux reconcile pin — and each can succeed or fail on its own. The cascade
// reports what it attempted; this file reports what is TRUE NOW, by reading
// every plane back. A disagreement is a split brain: the dashboard says
// "contained" while an OpenBao token is still live, or says "active" while
// Flux is pinned and will never roll the agent forward again.
//
// The one rule that matters: an unqueried plane is never evidence. If a plane
// cannot be read, the verdict is consistent=false and HTTP 503 — never a
// "consistent" built from the planes that happened to answer.
//
// Everything lives in this file so the only edit to main.go is one call to
// registerConsistencyRoutes. The checker holds its own state; it reads the
// server struct and the k8s fleet client but adds no fields to either.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	spiretypes "github.com/spiffe/spire-api-sdk/proto/spire/api/types"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// The Flux pin. W1's cascade writes it on stun; this file only reads it.
const (
	consistencyPinAnnotation = "kustomize.toolkit.fluxcd.io/reconcile"
	consistencyPinValue      = "disabled"
	consistencyTrustDomain   = "signalloom.demo"
	consistencyRoutePrefix   = "/api/v1/fleet/consistency/"
	consistencyCheckTimeout  = 5 * time.Second
	consistencyDefaultPeriod = 60 * time.Second
)

// ConsistencyReport is the wire shape of GET /api/v1/fleet/consistency/{id}.
type ConsistencyReport struct {
	AgentID    string            `json:"agent_id"`
	CheckedAt  string            `json:"checked_at"`
	SPIFFEID   string            `json:"spiffe_id"`
	Pod        ConsistencyPod    `json:"pod"`
	Bao        ConsistencyBao    `json:"bao"`
	Spire      ConsistencySpire  `json:"spire"`
	GitOps     ConsistencyGitOps `json:"gitops"`
	Consistent bool              `json:"consistent"`
	SplitBrain []string          `json:"split_brain"`

	queried bool // every plane answered
}

type ConsistencyPod struct {
	State           string `json:"state"`
	Stunned         bool   `json:"stunned"`
	ContainmentMode string `json:"containment_mode"`
	Found           bool   `json:"found"`
	Error           string `json:"error,omitempty"`
}

type ConsistencyBao struct {
	Configured   bool   `json:"configured"`
	ActiveTokens int    `json:"active_tokens"`
	Error        string `json:"error,omitempty"`
}

type ConsistencySpire struct {
	Configured   bool   `json:"configured"`
	EntryPresent bool   `json:"entry_present"`
	Error        string `json:"error,omitempty"`
}

type ConsistencyGitOps struct {
	DeploymentPinned bool   `json:"deployment_pinned"`
	PodPinned        bool   `json:"pod_pinned"`
	DeploymentFound  bool   `json:"deployment_found"`
	Deployment       string `json:"deployment,omitempty"`
	Error            string `json:"error,omitempty"`
}

// consistencyTokenCounter is the read half of *OpenBaoClient this file needs.
type consistencyTokenCounter interface {
	TokenConfigured() bool
	ActiveTokensBySubject(ctx context.Context) (map[string]int, error)
}

// consistencyEntryLister is the read half of SpireClient this file needs.
type consistencyEntryLister interface {
	ListEntriesBySPIFFEID(ctx context.Context, spiffeID string) ([]*spiretypes.Entry, error)
}

type consistencyChecker struct {
	dag              *DAG
	defaultNamespace string
	clientset        kubernetes.Interface
	resolvePod       func(ctx context.Context, namespace, agentID string) (*corev1.Pod, error)
	bao              consistencyTokenCounter
	spire            consistencyEntryLister
	metrics          *consistencyMetrics
	logger           *slog.Logger
	now              func() time.Time
}

// newConsistencyChecker builds a checker. kc may be nil (no Kubernetes client:
// the pod plane is then unqueried). bao and spire may be nil (unconfigured).
func newConsistencyChecker(dag *DAG, kc *k8sFleetClient, bao consistencyTokenCounter, spire consistencyEntryLister) *consistencyChecker {
	c := &consistencyChecker{
		dag:              dag,
		defaultNamespace: DefaultAgentNamespace,
		bao:              bao,
		spire:            spire,
		metrics:          newConsistencyMetrics(),
		logger:           slog.Default(),
		now:              time.Now,
	}
	if kc != nil {
		c.defaultNamespace = kc.namespaceOrDefault("")
		c.clientset = kc.clientset
		c.resolvePod = kc.resolvePod
	}
	return c
}

// registerConsistencyRoutes is the single hook main.go calls. It mounts the
// endpoint and /metrics and starts the reconciler unless CONSISTENCY_INTERVAL=0.
func registerConsistencyRoutes(mux *http.ServeMux, s *server) *consistencyChecker {
	var kc *k8sFleetClient
	if s.enforcement != nil {
		kc, _ = s.enforcement.Client.(*k8sFleetClient)
	}
	// Assign through explicit nil checks: a nil *OpenBaoClient or a nil
	// SpireClient stored in these interfaces would be a TYPED nil, non-nil to
	// the checker and a nil dereference on first use (see fleetclient_select.go).
	var bao consistencyTokenCounter
	var spire consistencyEntryLister
	if kc != nil {
		if kc.baoClient != nil {
			bao = kc.baoClient
		}
		if kc.spireClient != nil {
			spire = kc.spireClient
		}
	}
	c := newConsistencyChecker(s.dag, kc, bao, spire)
	c.register(mux)
	if interval := consistencyIntervalFromEnv(); interval > 0 {
		go c.run(context.Background(), interval)
		slog.Info("consistency reconciler started", "interval", interval.String())
	} else {
		slog.Warn("consistency reconciler disabled", "env", "CONSISTENCY_INTERVAL")
	}
	return c
}

func (c *consistencyChecker) register(mux *http.ServeMux) {
	mux.HandleFunc(consistencyRoutePrefix, c.handleConsistency)
	mux.HandleFunc("/metrics", c.metrics.serveHTTP)
}

// consistencyIntervalFromEnv parses CONSISTENCY_INTERVAL as a Go duration or a
// bare number of seconds. "0" disables; empty, invalid or negative falls back to
// the default rather than silently disabling the reconciler.
func consistencyIntervalFromEnv() time.Duration {
	raw := strings.TrimSpace(os.Getenv("CONSISTENCY_INTERVAL"))
	if raw == "" {
		return consistencyDefaultPeriod
	}
	if raw == "0" {
		return 0
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		secs, convErr := strconv.Atoi(raw)
		if convErr != nil {
			slog.Warn("invalid CONSISTENCY_INTERVAL; using default", "value", raw, "default", consistencyDefaultPeriod.String())
			return consistencyDefaultPeriod
		}
		d = time.Duration(secs) * time.Second
	}
	if d < 0 {
		slog.Warn("negative CONSISTENCY_INTERVAL; using default", "value", raw)
		return consistencyDefaultPeriod
	}
	return d
}

func (c *consistencyChecker) handleConsistency(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	agentID := strings.TrimPrefix(r.URL.Path, consistencyRoutePrefix)
	if agentID == "" || strings.Contains(agentID, "/") || c.dag == nil || c.dag.GetAgent(agentID) == nil {
		http.Error(w, fmt.Sprintf("unknown agent %q", agentID), http.StatusNotFound)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), consistencyCheckTimeout)
	defer cancel()

	rep := c.checkAgent(ctx, c.dag.GetAgent(agentID), c.snapshotBao(ctx))
	c.observe(rep, false)

	status := http.StatusOK
	if !rep.queried {
		status = http.StatusServiceUnavailable
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(rep)
}

// baoSnapshot is one enumeration of live tokens, shared by every agent in a
// reconcile round so OpenBao is listed once per round, not once per agent.
type baoSnapshot struct {
	configured bool
	counts     map[string]int
	err        error
}

func (c *consistencyChecker) snapshotBao(ctx context.Context) baoSnapshot {
	if c.bao == nil || !c.bao.TokenConfigured() {
		return baoSnapshot{err: errors.New("openbao plane not configured: no client token (BAO_TOKEN / BAO_TOKEN_FILE)")}
	}
	counts, err := c.bao.ActiveTokensBySubject(ctx)
	return baoSnapshot{configured: true, counts: counts, err: err}
}

func (c *consistencyChecker) checkAgent(ctx context.Context, agent *Agent, bao baoSnapshot) ConsistencyReport {
	namespace := agent.Namespace
	if namespace == "" {
		namespace = c.defaultNamespace
	}
	rep := ConsistencyReport{
		AgentID:    agent.ID,
		CheckedAt:  c.now().UTC().Format(time.RFC3339),
		SplitBrain: []string{},
		queried:    true,
	}

	// ── Pod plane ──
	var pod *corev1.Pod
	podQueried := false
	switch {
	case c.resolvePod == nil:
		rep.Pod.State = StateUnknown
		rep.Pod.Error = "pod plane not configured: fleet client is not the kubernetes client"
	default:
		p, err := c.resolvePod(ctx, namespace, agent.ID)
		switch {
		case err == nil:
			pod, podQueried = p, true
		case errors.Is(err, ErrTargetNotFound):
			podQueried = true
			rep.Pod.State = "absent"
		default:
			rep.Pod.State = StateUnknown
			rep.Pod.Error = err.Error()
		}
	}
	rep.queried = rep.queried && podQueried

	serviceAccount := agent.ID
	if pod != nil {
		rep.Pod.Found = true
		if pod.Spec.ServiceAccountName != "" {
			serviceAccount = pod.Spec.ServiceAccountName
		}
		state := pod.Labels[PodStateLabel]
		stunnedFlag := pod.Labels[StunnedLabel]
		rep.Pod.ContainmentMode = pod.Labels[ContainmentModeLabel]
		rep.Pod.State = state
		if state == "" {
			rep.Pod.State = StateUnknown
		}
		// The sentinel ORs these three; any one freezes the pod.
		rep.Pod.Stunned = state == StateStunned || stunnedFlag == "true" || rep.Pod.ContainmentMode == ContainmentModeFrozen
		allAgree := state == StateStunned && stunnedFlag == "true" && rep.Pod.ContainmentMode == ContainmentModeFrozen
		if rep.Pod.Stunned && !allAgree {
			rep.SplitBrain = append(rep.SplitBrain, fmt.Sprintf(
				"pod containment labels disagree: state=%q stunned=%q containment-mode=%q",
				state, stunnedFlag, rep.Pod.ContainmentMode))
		}
	}
	rep.SPIFFEID = fmt.Sprintf("spiffe://%s/ns/%s/sa/%s", consistencyTrustDomain, namespace, serviceAccount)

	// ── OpenBao plane ──
	rep.Bao.Configured = bao.configured
	baoQueried := bao.configured && bao.err == nil
	if bao.err != nil {
		rep.Bao.Error = bao.err.Error()
	} else {
		rep.Bao.ActiveTokens = bao.counts[rep.SPIFFEID]
	}
	rep.queried = rep.queried && baoQueried

	// ── SPIRE plane ──
	spireQueried := false
	if c.spire == nil {
		rep.Spire.Error = "spire plane not configured: no SPIRE server client"
	} else {
		rep.Spire.Configured = true
		entries, err := c.spire.ListEntriesBySPIFFEID(ctx, rep.SPIFFEID)
		if err != nil {
			rep.Spire.Error = err.Error()
		} else {
			spireQueried = true
			rep.Spire.EntryPresent = len(entries) > 0
		}
	}
	rep.queried = rep.queried && spireQueried

	// ── GitOps plane (only meaningful when the pod exists) ──
	gitopsQueried := true
	if pod != nil {
		rep.GitOps.PodPinned = pod.Annotations[consistencyPinAnnotation] == consistencyPinValue
		if err := c.readDeploymentPin(ctx, namespace, agent.ID, pod, &rep.GitOps); err != nil {
			gitopsQueried = false
			rep.GitOps.Error = err.Error()
		}
	}
	rep.queried = rep.queried && gitopsQueried

	// ── Expectations, judged only on planes that answered ──
	switch {
	case podQueried && pod == nil:
		if baoQueried && rep.Bao.ActiveTokens > 0 {
			rep.SplitBrain = append(rep.SplitBrain, fmt.Sprintf("pod absent but %d openbao tokens active", rep.Bao.ActiveTokens))
		}
	case pod != nil && rep.Pod.Stunned:
		if baoQueried && rep.Bao.ActiveTokens > 0 {
			rep.SplitBrain = append(rep.SplitBrain, fmt.Sprintf("pod stunned but %d openbao tokens active", rep.Bao.ActiveTokens))
		}
		if spireQueried && rep.Spire.EntryPresent {
			rep.SplitBrain = append(rep.SplitBrain, "pod stunned but spire entry present")
		}
		if gitopsQueried && rep.GitOps.DeploymentFound && !rep.GitOps.DeploymentPinned {
			rep.SplitBrain = append(rep.SplitBrain, "pod stunned but deployment not pinned")
		}
		if !rep.GitOps.PodPinned {
			rep.SplitBrain = append(rep.SplitBrain, "pod stunned but pod not pinned")
		}
	case pod != nil:
		if baoQueried && rep.Bao.ActiveTokens == 0 {
			rep.SplitBrain = append(rep.SplitBrain, "pod active but 0 openbao tokens active")
		}
		if spireQueried && !rep.Spire.EntryPresent {
			rep.SplitBrain = append(rep.SplitBrain, "pod active but no spire entry")
		}
		if gitopsQueried && rep.GitOps.DeploymentPinned {
			rep.SplitBrain = append(rep.SplitBrain, "pod active but deployment pinned")
		}
		if rep.GitOps.PodPinned {
			rep.SplitBrain = append(rep.SplitBrain, "pod active but pod pinned")
		}
	}

	rep.Consistent = rep.queried && len(rep.SplitBrain) == 0
	return rep
}

// readDeploymentPin finds the agent's Deployment — by the agent ID, else by the
// pod's ReplicaSet owner with its pod-template-hash suffix stripped (no extra
// API call, no replicasets RBAC) — and reads the Flux pin. A bare pod has no
// Deployment: DeploymentFound=false, which is an answer, not an error.
func (c *consistencyChecker) readDeploymentPin(ctx context.Context, namespace, agentID string, pod *corev1.Pod, out *ConsistencyGitOps) error {
	if c.clientset == nil {
		return errors.New("gitops plane not configured: no Kubernetes clientset")
	}
	candidates := []string{agentID}
	for _, ref := range pod.OwnerReferences {
		if ref.Kind == "ReplicaSet" {
			if i := strings.LastIndex(ref.Name, "-"); i > 0 && ref.Name[:i] != agentID {
				candidates = append(candidates, ref.Name[:i])
			}
		}
	}
	for _, name := range candidates {
		dep, err := c.clientset.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("get deployment %s/%s: %w", namespace, name, err)
		}
		out.DeploymentFound = true
		out.Deployment = dep.Name
		out.DeploymentPinned = dep.Annotations[consistencyPinAnnotation] == consistencyPinValue
		return nil
	}
	return nil
}

// ── Reconciler ───────────────────────────────────────────────────────────────

func (c *consistencyChecker) run(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		c.reconcileOnce(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// reconcileOnce checks every DAG agent against one OpenBao snapshot, logs one
// structured split_brain event per finding and updates the metrics.
func (c *consistencyChecker) reconcileOnce(ctx context.Context) {
	if c.dag == nil {
		return
	}
	roundCtx, cancel := context.WithTimeout(ctx, consistencyCheckTimeout*3)
	defer cancel()
	snap := c.snapshotBao(roundCtx)
	for _, agent := range c.dag.AllAgents() {
		checkCtx, checkCancel := context.WithTimeout(roundCtx, consistencyCheckTimeout)
		rep := c.checkAgent(checkCtx, agent, snap)
		checkCancel()
		c.observe(rep, true)
	}
}

// observe updates metrics; when log is set it also emits the per-finding events.
func (c *consistencyChecker) observe(rep ConsistencyReport, log bool) {
	c.metrics.record(rep)
	if !log {
		return
	}
	for _, finding := range rep.SplitBrain {
		c.logger.Warn("split_brain",
			"event", "split_brain",
			"agent_id", rep.AgentID,
			"spiffe_id", rep.SPIFFEID,
			"finding", finding,
			"checked_at", rep.CheckedAt)
	}
	if !rep.queried {
		c.logger.Warn("consistency_unqueried",
			"event", "consistency_unqueried",
			"agent_id", rep.AgentID,
			"pod_error", rep.Pod.Error,
			"bao_error", rep.Bao.Error,
			"spire_error", rep.Spire.Error,
			"gitops_error", rep.GitOps.Error)
	}
}

// ── Metrics (Prometheus text format, no client library) ──────────────────────

type consistencyMetrics struct {
	mu         sync.Mutex
	checks     uint64
	splitBrain map[string]uint64
	unqueried  map[string]uint64
}

func newConsistencyMetrics() *consistencyMetrics {
	return &consistencyMetrics{splitBrain: map[string]uint64{}, unqueried: map[string]uint64{}}
}

func (m *consistencyMetrics) record(rep ConsistencyReport) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.checks++
	if n := len(rep.SplitBrain); n > 0 {
		m.splitBrain[rep.AgentID] += uint64(n)
	}
	if !rep.queried {
		m.unqueried[rep.AgentID]++
	}
}

func (m *consistencyMetrics) serveHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var b strings.Builder
	b.WriteString("# HELP fleet_consistency_checks_total Cross-plane consistency checks performed (endpoint and reconciler).\n")
	b.WriteString("# TYPE fleet_consistency_checks_total counter\n")
	fmt.Fprintf(&b, "fleet_consistency_checks_total %d\n", m.checks)
	writeLabelledCounter(&b, "fleet_split_brain_total", "Split-brain findings: a plane disagreeing with the pod's containment state.", m.splitBrain)
	writeLabelledCounter(&b, "fleet_consistency_unqueried_total", "Checks where at least one plane could not be queried (never counted as consistent).", m.unqueried)
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(b.String()))
}

func writeLabelledCounter(b *strings.Builder, name, help string, values map[string]uint64) {
	fmt.Fprintf(b, "# HELP %s %s\n# TYPE %s counter\n", name, help, name)
	agents := make([]string, 0, len(values))
	for agent := range values {
		agents = append(agents, agent)
	}
	sort.Strings(agents)
	for _, agent := range agents {
		fmt.Fprintf(b, "%s{agent=%s} %d\n", name, strconv.Quote(agent), values[agent])
	}
}
