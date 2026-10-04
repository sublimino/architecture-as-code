package main

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"k8s.io/apimachinery/pkg/util/validation"
)

// DefaultFleetReportInterval is both the warden's documented default cadence
// and the hub's fallback when an older report omits its interval. Keeping the
// fallback in the registry prevents an omitted wire field from disabling
// eviction.
const DefaultFleetReportInterval = 60 * time.Second

const (
	// MaxReportedPods bounds both validation work and the amount of registry
	// state one compromised or defective warden can replace in one request.
	MaxReportedPods = 2000

	// MaxReportedPodLabels prevents Kubernetes metadata from becoming an
	// unbounded amplification path through the fleet-manager JSON API.
	MaxReportedPodLabels = 32
)

// tenantNamePattern is the remote contract's tenant rule, not a Kubernetes
// object-name rule. It deliberately permits the contract's exact shape,
// including a trailing hyphen, so fleet-manager does not silently impose a
// different tenancy vocabulary on remote clusters.
var tenantNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

type WorkloadReport struct {
	ClusterID             string        `json:"cluster_id"`
	Node                  string        `json:"node"`
	ReportedAt            string        `json:"reported_at"`
	ReportIntervalSeconds int           `json:"report_interval_seconds,omitempty"`
	Pods                  []ReportedPod `json:"pods"`
}

type ReportedPod struct {
	Namespace string            `json:"namespace"`
	Name      string            `json:"name"`
	UID       string            `json:"uid"`
	Owner     ReportedPodOwner  `json:"owner"`
	Tenant    string            `json:"tenant"`
	Labels    map[string]string `json:"labels,omitempty"`
	Frozen    bool              `json:"frozen"`
}

type ReportedPodOwner struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

type RegisteredWorkload struct {
	ClusterID             string            `json:"cluster_id"`
	Node                  string            `json:"node"`
	Namespace             string            `json:"namespace"`
	Name                  string            `json:"name"`
	UID                   string            `json:"uid,omitempty"`
	Owner                 ReportedPodOwner  `json:"owner"`
	Tenant                string            `json:"tenant"`
	Labels                map[string]string `json:"labels,omitempty"`
	Frozen                bool              `json:"frozen"`
	ReportedAt            string            `json:"reported_at"`
	ReportIntervalSeconds int               `json:"report_interval_seconds"`
}

type workloadKey struct {
	ClusterID string
	Namespace string
	Name      string
}

type workloadEntry struct {
	workload   RegisteredWorkload
	receivedAt time.Time
	interval   time.Duration
}

// WorkloadRegistry holds the latest complete node reports. One ordinary Mutex,
// rather than a read/write split, protects every access because every apparent
// read may first perform lazy eviction and therefore mutate the map.
type WorkloadRegistry struct {
	mu              sync.Mutex
	now             func() time.Time
	defaultInterval time.Duration
	entries         map[workloadKey]workloadEntry
}

// NewWorkloadRegistry constructs a deterministic registry. Tests and callers
// that need controlled eviction can inject a clock; production callers can
// pass nil and receive the server's wall clock.
func NewWorkloadRegistry(defaultInterval time.Duration, now func() time.Time) *WorkloadRegistry {
	if defaultInterval <= 0 {
		defaultInterval = DefaultFleetReportInterval
	}
	if now == nil {
		now = time.Now
	}
	return &WorkloadRegistry{
		now:             now,
		defaultInterval: defaultInterval,
		entries:         make(map[workloadKey]workloadEntry),
	}
}

// Apply validates a complete report before taking any state-changing action.
// A partially applied report would describe a cluster state that never
// existed, so one bad pod rejects the whole request and leaves the previous
// node snapshot intact.
func (r *WorkloadRegistry) Apply(report WorkloadReport) (accepted int, evicted int, err error) {
	if err := report.Validate(); err != nil {
		return 0, 0, err
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	receivedAt := r.now()
	entryInterval := r.defaultInterval
	if report.ReportIntervalSeconds > 0 {
		entryInterval = time.Duration(report.ReportIntervalSeconds) * time.Second
	}

	// A report is an authoritative snapshot for one cluster/node pair, not an
	// additive event stream. Removing the previous snapshot first makes an
	// empty report clear the node immediately and makes disappeared pods leave
	// on the next report rather than surviving for three more intervals.
	for key, entry := range r.entries {
		if key.ClusterID == report.ClusterID && entry.workload.Node == report.Node {
			delete(r.entries, key)
		}
	}

	for _, pod := range report.Pods {
		key := workloadKey{
			ClusterID: report.ClusterID,
			Namespace: pod.Namespace,
			Name:      pod.Name,
		}
		r.entries[key] = workloadEntry{
			workload: RegisteredWorkload{
				ClusterID:             report.ClusterID,
				Node:                  report.Node,
				Namespace:             pod.Namespace,
				Name:                  pod.Name,
				UID:                   pod.UID,
				Owner:                 pod.Owner,
				Tenant:                pod.Tenant,
				Labels:                copyWorkloadLabels(pod.Labels),
				Frozen:                pod.Frozen,
				ReportedAt:            report.ReportedAt,
				ReportIntervalSeconds: int(entryInterval / time.Second),
			},
			receivedAt: receivedAt,
			interval:   entryInterval,
		}
	}

	// Replacement removals are not eviction: evicted reports only entries
	// removed by the staleness rule, allowing metrics and callers to distinguish
	// an authoritative node update from a missed-report timeout.
	evicted = r.evictLocked(receivedAt)
	return len(report.Pods), evicted, nil
}

// List returns the selected live entries in a stable order. The result is
// allocated even when empty so JSON encoders produce [] rather than null.
func (r *WorkloadRegistry) List(clusterID string) []RegisteredWorkload {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.evictLocked(r.now())
	workloads := make([]RegisteredWorkload, 0, len(r.entries))
	for _, entry := range r.entries {
		if clusterID == "" || entry.workload.ClusterID == clusterID {
			workloads = append(workloads, copyRegisteredWorkload(entry.workload))
		}
	}
	sortRegisteredWorkloads(workloads)
	return workloads
}

// ByKey resolves the registry's canonical cluster/namespace/name identity.
func (r *WorkloadRegistry) ByKey(clusterID, namespace, name string) (RegisteredWorkload, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.evictLocked(r.now())
	entry, ok := r.entries[workloadKey{
		ClusterID: clusterID,
		Namespace: namespace,
		Name:      name,
	}]
	if !ok {
		return RegisteredWorkload{}, false
	}
	return copyRegisteredWorkload(entry.workload), true
}

// ByPodName returns every live exact pod-name match. Names need not be unique
// across namespaces or clusters, so callers receive every candidate and a
// stable order suitable for deterministic ambiguity handling.
func (r *WorkloadRegistry) ByPodName(name string) []RegisteredWorkload {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.evictLocked(r.now())
	workloads := make([]RegisteredWorkload, 0)
	for _, entry := range r.entries {
		if entry.workload.Name == name {
			workloads = append(workloads, copyRegisteredWorkload(entry.workload))
		}
	}
	sortRegisteredWorkloads(workloads)
	return workloads
}

// ByOwnerName returns every live exact controller-name match. A controller can
// own several pods and names can repeat across namespaces or clusters, so the
// method intentionally returns all deterministic candidates.
func (r *WorkloadRegistry) ByOwnerName(name string) []RegisteredWorkload {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.evictLocked(r.now())
	workloads := make([]RegisteredWorkload, 0)
	for _, entry := range r.entries {
		if entry.workload.Owner.Name == name {
			workloads = append(workloads, copyRegisteredWorkload(entry.workload))
		}
	}
	sortRegisteredWorkloads(workloads)
	return workloads
}

// Len returns the number of live entries, not the number last written. Lazy
// eviction therefore runs before the count just as it does before every other
// registry read.
func (r *WorkloadRegistry) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.evictLocked(r.now())
	return len(r.entries)
}

// evictLocked applies the per-entry missed-report window. receivedAt is the
// hub's own receipt time rather than the client-supplied reported_at: a remote
// clock an hour in the future must not be able to pin entries in the hub
// forever. reported_at remains validated and echoed so operators can observe
// and diagnose that clock skew without trusting it for lifecycle decisions.
//
// The caller holds r.mu. Equality is retained deliberately: the contract says
// an entry becomes stale only after more than three complete intervals.
func (r *WorkloadRegistry) evictLocked(now time.Time) int {
	evicted := 0
	for key, entry := range r.entries {
		if now.Sub(entry.receivedAt) > 3*entry.interval {
			delete(r.entries, key)
			evicted++
		}
	}
	return evicted
}

// copyWorkloadLabels copies at both registry boundaries. A report owner must
// not be able to mutate its input map after Apply and rewrite stored state,
// and a reader mutating a returned map must not be able to rewrite the
// registry.
func copyWorkloadLabels(labels map[string]string) map[string]string {
	if labels == nil {
		return nil
	}
	copied := make(map[string]string, len(labels))
	for key, value := range labels {
		copied[key] = value
	}
	return copied
}

func copyRegisteredWorkload(workload RegisteredWorkload) RegisteredWorkload {
	copied := workload
	copied.Labels = copyWorkloadLabels(workload.Labels)
	return copied
}

func sortRegisteredWorkloads(workloads []RegisteredWorkload) {
	sort.Slice(workloads, func(i, j int) bool {
		if workloads[i].ClusterID != workloads[j].ClusterID {
			return workloads[i].ClusterID < workloads[j].ClusterID
		}
		if workloads[i].Namespace != workloads[j].Namespace {
			return workloads[i].Namespace < workloads[j].Namespace
		}
		return workloads[i].Name < workloads[j].Name
	})
}

// Validate checks the complete wire report without consulting registry state.
// Each error names the JSON field, and pod errors include their array index,
// so a warden author can identify the rejected value from the HTTP 400 body
// without reproducing fleet-manager's internal state.
func (r WorkloadReport) Validate() error {
	if r.ClusterID == "" {
		return fmt.Errorf("cluster_id is required")
	}
	if problems := validation.IsDNS1123Label(r.ClusterID); len(problems) > 0 {
		return fmt.Errorf("cluster_id %q must be a DNS1123 label: %s", r.ClusterID, strings.Join(problems, "; "))
	}

	if r.Node == "" {
		return fmt.Errorf("node is required")
	}
	if problems := validation.IsDNS1123Subdomain(r.Node); len(problems) > 0 {
		return fmt.Errorf("node %q must be a DNS1123 subdomain: %s", r.Node, strings.Join(problems, "; "))
	}

	if r.ReportedAt == "" {
		return fmt.Errorf("reported_at is required")
	}
	if _, err := time.Parse(time.RFC3339, r.ReportedAt); err != nil {
		return fmt.Errorf("reported_at %q must be RFC3339: %v", r.ReportedAt, err)
	}

	if r.ReportIntervalSeconds != 0 && (r.ReportIntervalSeconds < 1 || r.ReportIntervalSeconds > 3600) {
		return fmt.Errorf("report_interval_seconds must be between 1 and 3600 when present; got %d", r.ReportIntervalSeconds)
	}

	if len(r.Pods) > MaxReportedPods {
		return fmt.Errorf("pods contains %d entries; at most %d are allowed", len(r.Pods), MaxReportedPods)
	}

	seenPods := make(map[workloadKey]int, len(r.Pods))
	for index, pod := range r.Pods {
		if err := validateReportedPod(index, pod); err != nil {
			return err
		}

		identity := workloadKey{
			Namespace: pod.Namespace,
			Name:      pod.Name,
		}
		if previousIndex, duplicate := seenPods[identity]; duplicate {
			return fmt.Errorf(
				"pods[%d] duplicates pods[%d]: namespace/name %q is present more than once",
				index,
				previousIndex,
				pod.Namespace+"/"+pod.Name,
			)
		}
		seenPods[identity] = index
	}

	// Zero pods is intentionally valid. It is the authoritative statement that
	// this node currently hosts no reportable workload and causes Apply to
	// clear the node's previous snapshot.
	return nil
}

func validateReportedPod(index int, pod ReportedPod) error {
	fieldPrefix := fmt.Sprintf("pods[%d]", index)

	if pod.Namespace == "" {
		return fmt.Errorf("%s.namespace is required", fieldPrefix)
	}
	if problems := validation.IsDNS1123Label(pod.Namespace); len(problems) > 0 {
		return fmt.Errorf("%s.namespace %q must be a DNS1123 label: %s", fieldPrefix, pod.Namespace, strings.Join(problems, "; "))
	}

	if pod.Name == "" {
		return fmt.Errorf("%s.name is required", fieldPrefix)
	}
	if problems := validation.IsDNS1123Subdomain(pod.Name); len(problems) > 0 {
		return fmt.Errorf("%s.name %q must be a DNS1123 subdomain: %s", fieldPrefix, pod.Name, strings.Join(problems, "; "))
	}

	if pod.Tenant == "" {
		return fmt.Errorf("%s.tenant is required", fieldPrefix)
	}
	if !tenantNamePattern.MatchString(pod.Tenant) {
		return fmt.Errorf("%s.tenant %q must match %s", fieldPrefix, pod.Tenant, tenantNamePattern.String())
	}

	if utf8.RuneCountInString(pod.UID) > 64 {
		return fmt.Errorf("%s.uid must be at most 64 characters; got %d", fieldPrefix, utf8.RuneCountInString(pod.UID))
	}
	for _, character := range pod.UID {
		if character < 0x20 || character > 0x7e {
			return fmt.Errorf("%s.uid contains non-printable-ASCII character %U", fieldPrefix, character)
		}
	}

	if pod.Owner.Kind == "" {
		return fmt.Errorf("%s.owner.kind is required", fieldPrefix)
	}
	if utf8.RuneCountInString(pod.Owner.Kind) > 63 {
		return fmt.Errorf("%s.owner.kind must be at most 63 characters; got %d", fieldPrefix, utf8.RuneCountInString(pod.Owner.Kind))
	}
	// Validate the controller kind's transport shape rather than maintaining an
	// allow-list. Kubernetes can gain new controller kinds, and remote clusters
	// can install CRDs, without requiring a fleet-manager release merely to
	// report their workloads.
	for _, character := range pod.Owner.Kind {
		if (character < 'A' || character > 'Z') && (character < 'a' || character > 'z') {
			return fmt.Errorf("%s.owner.kind %q must contain ASCII letters only", fieldPrefix, pod.Owner.Kind)
		}
	}

	if pod.Owner.Name == "" {
		return fmt.Errorf("%s.owner.name is required", fieldPrefix)
	}
	if problems := validation.IsDNS1123Subdomain(pod.Owner.Name); len(problems) > 0 {
		return fmt.Errorf("%s.owner.name %q must be a DNS1123 subdomain: %s", fieldPrefix, pod.Owner.Name, strings.Join(problems, "; "))
	}

	if len(pod.Labels) > MaxReportedPodLabels {
		return fmt.Errorf("%s.labels contains %d entries; at most %d are allowed", fieldPrefix, len(pod.Labels), MaxReportedPodLabels)
	}

	// Map iteration order is deliberately removed before validation so a report
	// with several bad labels produces the same first error on every run.
	labelKeys := make([]string, 0, len(pod.Labels))
	for key := range pod.Labels {
		labelKeys = append(labelKeys, key)
	}
	sort.Strings(labelKeys)
	for _, key := range labelKeys {
		if problems := validation.IsQualifiedName(key); len(problems) > 0 {
			return fmt.Errorf("%s.labels key %q is not a valid qualified name: %s", fieldPrefix, key, strings.Join(problems, "; "))
		}
		value := pod.Labels[key]
		if problems := validation.IsValidLabelValue(value); len(problems) > 0 {
			return fmt.Errorf("%s.labels[%q] value %q is not a valid label value: %s", fieldPrefix, key, value, strings.Join(problems, "; "))
		}
	}

	return nil
}
