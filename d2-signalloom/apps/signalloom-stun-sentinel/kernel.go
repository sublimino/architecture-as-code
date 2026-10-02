package main

// Kernel truth: the sentinel is the only component with the node's cgroup
// filesystem mounted, so it publishes what the kernel says rather than what
// the labels say. Every reconcile reads <pod cgroup>/cgroup.events BEFORE any
// veth/tc work, patches signalloom.io/kernel-frozen on change, and warns when
// a pod is frozen with no stun record anywhere (labels or owner chain).

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
)

const (
	annotationKernelFrozen     = "signalloom.io/kernel-frozen"
	annotationKernelObservedAt = "signalloom.io/kernel-observed-at"
	// annotationOwnerStunned on a ReplicaSet or Deployment is the durable stun
	// record: a replacement pod on another node is frozen before any label
	// reaches it.
	annotationOwnerStunned = "signalloom.io/stunned"
	cgroupEventsFile       = "cgroup.events"
	kernelAPITimeout       = 5 * time.Second
)

// kubeAPI is the API surface beyond the informer: one pod patch and two
// owner gets. Matches the sentinel Role (pods patch; replicasets,deployments get).
type kubeAPI interface {
	PatchPodAnnotations(ctx context.Context, namespace, name string, annotations map[string]string) error
	GetReplicaSet(ctx context.Context, namespace, name string) (*appsv1.ReplicaSet, error)
	GetDeployment(ctx context.Context, namespace, name string) (*appsv1.Deployment, error)
}

type clientsetAPI struct{ cs kubernetes.Interface }

func (c clientsetAPI) PatchPodAnnotations(ctx context.Context, namespace, name string, annotations map[string]string) error {
	body, err := json.Marshal(map[string]any{"metadata": map[string]any{"annotations": annotations}})
	if err != nil {
		return err
	}
	_, err = c.cs.CoreV1().Pods(namespace).Patch(ctx, name, types.MergePatchType, body, metav1.PatchOptions{})
	return err
}

func (c clientsetAPI) GetReplicaSet(ctx context.Context, namespace, name string) (*appsv1.ReplicaSet, error) {
	return c.cs.AppsV1().ReplicaSets(namespace).Get(ctx, name, metav1.GetOptions{})
}

func (c clientsetAPI) GetDeployment(ctx context.Context, namespace, name string) (*appsv1.Deployment, error) {
	return c.cs.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
}

// readKernelFrozen parses the `frozen` line of cgroup.events field-exactly
// ("unfrozen 1" must not read as frozen). A missing key is an error, never 0.
func readKernelFrozen(cgroupPath string) (bool, error) {
	body, err := os.ReadFile(filepath.Join(cgroupPath, cgroupEventsFile))
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "frozen" {
			switch fields[1] {
			case "1":
				return true, nil
			case "0":
				return false, nil
			}
		}
	}
	return false, fmt.Errorf("%s: no frozen 0|1 line", cgroupEventsFile)
}

type ownerEntry struct {
	stunned bool
	expires time.Time
}

// kernelPublisher holds the per-pod state for publishing and warning. Keys are
// "namespace/name" except the owner cache, which is per pod UID.
type kernelPublisher struct {
	api    kubeAPI // nil: no API server (standalone); publish nothing
	resync time.Duration
	dryRun bool
	now    func() time.Time

	mu               sync.Mutex
	owners           map[types.UID]ownerEntry
	lastWarned       map[string]time.Time
	frozenUnlabelled map[string]bool
	plannedDryRun    map[string]string
}

func newKernelPublisher(api kubeAPI, resync time.Duration, dryRun bool) *kernelPublisher {
	return &kernelPublisher{
		api:              api,
		resync:           resync,
		dryRun:           dryRun,
		now:              time.Now,
		owners:           map[types.UID]ownerEntry{},
		lastWarned:       map[string]time.Time{},
		frozenUnlabelled: map[string]bool{},
		plannedDryRun:    map[string]string{},
	}
}

// ownerStunned reports whether the pod's owner record carries
// signalloom.io/stunned=true: the controlling Deployment if there is one,
// else the ReplicaSet. Cached per pod UID for
// one resync period. A lookup error is logged and cached as "no record": the
// three label terms still apply, and a missing RBAC grant must not wedge
// every reconcile.
func (k *kernelPublisher) ownerStunned(pod *corev1.Pod) bool {
	if k == nil || k.api == nil {
		return false
	}
	owner := metav1.GetControllerOf(pod)
	if owner == nil || owner.Kind != "ReplicaSet" {
		return false
	}
	now := k.now()
	k.mu.Lock()
	if e, ok := k.owners[pod.UID]; ok && now.Before(e.expires) {
		k.mu.Unlock()
		return e.stunned
	}
	k.mu.Unlock()

	stunned, err := k.lookupOwnerChain(pod.Namespace, owner.Name)
	if err != nil {
		logEvent(stunEvent{Timestamp: now.UTC().Format(time.RFC3339Nano), Event: "owner_lookup_failed",
			Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID), Error: err.Error()})
	}

	k.mu.Lock()
	defer k.mu.Unlock()
	for uid, e := range k.owners { // prune: the map stays namespace-sized
		if !now.Before(e.expires) {
			delete(k.owners, uid)
		}
	}
	k.owners[pod.UID] = ownerEntry{stunned: stunned, expires: now.Add(k.resync)}
	return stunned
}

func (k *kernelPublisher) lookupOwnerChain(namespace, replicaSet string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), kernelAPITimeout)
	defer cancel()
	rs, err := k.api.GetReplicaSet(ctx, namespace, replicaSet)
	if apierrors.IsNotFound(err) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("get replicaset %s/%s: %w", namespace, replicaSet, err)
	}
	rsStunned := rs.Annotations[annotationOwnerStunned] == "true"
	// The Deployment is the record whenever it controls the RS. `kubectl
	// annotate deploy` copies the annotation onto the RS and removing it from
	// the Deployment leaves the RS copy behind, so reading the RS here would
	// make an owner stun irrevocable. The RS speaks only when there is no
	// Deployment controller, or that Deployment no longer exists.
	dep := metav1.GetControllerOf(rs)
	if dep == nil || dep.Kind != "Deployment" {
		return rsStunned, nil
	}
	d, err := k.api.GetDeployment(ctx, namespace, dep.Name)
	if apierrors.IsNotFound(err) {
		return rsStunned, nil
	}
	if err != nil {
		return false, fmt.Errorf("get deployment %s/%s: %w", namespace, dep.Name, err)
	}
	return d.Annotations[annotationOwnerStunned] == "true", nil
}

// allowOnce is the per-pod, per-kind rate limit: true at most once per resync.
func (k *kernelPublisher) allowOnce(kind, key string, now time.Time) bool {
	id := kind + "|" + key
	k.mu.Lock()
	defer k.mu.Unlock()
	if last, ok := k.lastWarned[id]; ok && now.Sub(last) < k.resync {
		return false
	}
	k.lastWarned[id] = now
	return true
}

// publish reads the kernel's freeze state and publishes it. It never returns
// an error: publishing is observation, and must not block containment.
func (k *kernelPublisher) publish(pod *corev1.Pod, cgroupPath string, stunned bool) {
	if k == nil {
		return
	}
	key := pod.Namespace + "/" + pod.Name
	now := k.now()
	stamp := now.UTC().Format(time.RFC3339)

	frozen, err := readKernelFrozen(cgroupPath)
	if err != nil {
		k.setUnlabelled(key, false) // unknown is not evidence either way
		if k.allowOnce("unreadable", key, now) {
			logEvent(stunEvent{Timestamp: now.UTC().Format(time.RFC3339Nano), Event: "kernel_state_unreadable",
				Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID), CgroupPath: cgroupPath, Error: err.Error()})
		}
		return
	}

	value := fmt.Sprintf("%t", frozen)
	previous, had := pod.Annotations[annotationKernelFrozen]
	if !had {
		previous = "unset"
	}
	if previous != value && k.api != nil {
		k.patch(pod, key, value, previous, stamp, cgroupPath, now)
	}

	unlabelled := frozen && !stunned
	k.setUnlabelled(key, unlabelled)
	if unlabelled && k.allowOnce("frozen_unlabelled", key, now) {
		logEvent(stunEvent{Timestamp: now.UTC().Format(time.RFC3339Nano), Event: "frozen_unlabelled",
			Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID), CgroupPath: cgroupPath,
			Decision: "report_only",
			Details:  map[string]interface{}{"frozen": true, "stunned": false, "source": cgroupEventsFile}})
	}
}

func (k *kernelPublisher) patch(pod *corev1.Pod, key, value, previous, stamp, cgroupPath string, now time.Time) {
	ev := stunEvent{Timestamp: now.UTC().Format(time.RFC3339Nano), Event: "kernel_state",
		Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID), CgroupPath: cgroupPath, DryRun: k.dryRun,
		Decision: "annotation_patched",
		Details:  map[string]interface{}{"frozen": value == "true", "previous": previous, "observed_at": stamp}}
	if k.dryRun {
		k.mu.Lock()
		seen := k.plannedDryRun[key] == value
		k.plannedDryRun[key] = value
		k.mu.Unlock()
		if !seen {
			ev.Decision = "annotation_patch_planned_dry_run"
			logEvent(ev)
		}
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelAPITimeout)
	defer cancel()
	err := k.api.PatchPodAnnotations(ctx, pod.Namespace, pod.Name, map[string]string{
		annotationKernelFrozen:     value,
		annotationKernelObservedAt: stamp,
	})
	if err != nil {
		ev.Event, ev.Decision, ev.Error = "kernel_state_publish_failed", "", err.Error()
	}
	logEvent(ev)
}

func (k *kernelPublisher) setUnlabelled(key string, v bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if v {
		k.frozenUnlabelled[key] = true
	} else {
		delete(k.frozenUnlabelled, key)
	}
}

// forget drops per-pod state when the pod leaves the informer cache.
func (k *kernelPublisher) forget(key string) {
	if k == nil {
		return
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.frozenUnlabelled, key)
	delete(k.plannedDryRun, key)
	for _, kind := range []string{"unreadable", "frozen_unlabelled"} {
		delete(k.lastWarned, kind+"|"+key)
	}
}

// frozenUnlabelledCount backs the sentinel_frozen_unlabelled_pods gauge.
func (k *kernelPublisher) frozenUnlabelledCount() int {
	if k == nil {
		return 0
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	return len(k.frozenUnlabelled)
}
