package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	bpfebpf "github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/ebpf"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/correlator"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"
)

const (
	labelStunnedAI       = "signalloom.ai/state"
	labelStunnedIO       = "signalloom.io/stunned"
	labelContainmentMode = "signalloom.io/containment-mode"
	labelStunned         = "signalloom.ai/state"
	stunnedValue         = "stunned"
	watchNamespace       = "fe-signalloom-agents"
	defaultCgroupRoot    = "/sys/fs/cgroup"
	informerResync       = 30 * time.Second
	// The sentinel's own identity. Its DaemonSet pods carry the informer's
	// selector (signalloom.ai/agent=true), so they must be excluded by name.
	sentinelServiceAccount = "stun-sentinel"
	sentinelAppName        = "stun-sentinel"
)

// isSentinelPod: a pod of this DaemonSet. The sentinel never freezes, isolates
// or annotates itself, whatever labels it carries.
func isSentinelPod(pod *corev1.Pod) bool {
	return pod.Spec.ServiceAccountName == sentinelServiceAccount ||
		pod.Labels["app.kubernetes.io/name"] == sentinelAppName
}

// ownerStunLookup answers the fourth stun term: does the pod's controller
// chain (ReplicaSet -> Deployment) carry signalloom.io/stunned=true?
type ownerStunLookup interface {
	ownerStunned(*corev1.Pod) bool
}

// isPodStunned ORs the three pod labels and, when owners is non-nil, the
// owner-chain stun record. Labels are checked first: no API call for a pod
// that is already labelled.
func isPodStunned(pod *corev1.Pod, owners ownerStunLookup) bool {
	if pod == nil {
		return false
	}
	if pod.Labels[labelStunnedAI] == stunnedValue {
		return true
	}
	if pod.Labels[labelStunnedIO] == "true" {
		return true
	}
	if pod.Labels[labelContainmentMode] == "frozen" {
		return true
	}
	if owners != nil && owners.ownerStunned(pod) {
		return true
	}
	return false
}

type podReconciler interface {
	reconcile(*corev1.Pod) error
}

type controller struct {
	indexer    cache.Indexer
	queue      workqueue.TypedRateLimitingInterface[string]
	reconciler podReconciler
}

func newController(informer cache.SharedIndexInformer, reconciler podReconciler) *controller {
	controller := &controller{
		indexer: informer.GetIndexer(),
		queue: workqueue.NewTypedRateLimitingQueueWithConfig(
			workqueue.DefaultTypedControllerRateLimiter[string](),
			workqueue.TypedRateLimitingQueueConfig[string]{Name: "stun-sentinel"},
		),
		reconciler: reconciler,
	}
	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    controller.onAdd,
		UpdateFunc: controller.onUpdate,
		DeleteFunc: controller.onDelete,
	})
	return controller
}

func (c *controller) onAdd(obj interface{})          { c.enqueue(obj) }
func (c *controller) onUpdate(_, newObj interface{}) { c.enqueue(newObj) }
func (c *controller) onDelete(obj interface{})       { c.enqueue(obj) }

func (c *controller) enqueue(obj interface{}) {
	key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
	if err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "queue_key_failed", Error: err.Error()})
		return
	}
	c.queue.Add(key)
}

func (c *controller) run(stopCh <-chan struct{}) {
	defer c.queue.ShutDown()
	go func() {
		<-stopCh
		c.queue.ShutDown()
	}()
	for c.processNextWorkItem() {
	}
}

func (c *controller) processNextWorkItem() bool {
	key, shutdown := c.queue.Get()
	if shutdown {
		return false
	}
	defer c.queue.Done(key)
	obj, exists, err := c.indexer.GetByKey(key)
	if err != nil {
		c.queue.AddRateLimited(key)
		return true
	}
	if !exists { // Pod deletion ends the cgroup and host veth lifecycle.
		if f, ok := c.reconciler.(interface{ forget(string) }); ok {
			f.forget(key)
		}
		c.queue.Forget(key)
		return true
	}
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		c.queue.Forget(key)
		return true
	}
	if err := c.reconciler.reconcile(pod); err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "reconcile_failed", Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID), Error: err.Error()})
		c.queue.AddRateLimited(key)
		return true
	}
	c.queue.Forget(key)
	return true
}

type stunReconciler struct {
	freezer        *cgroupFreezer
	tc             *tcDropFilter
	probes         *probePreserver
	kernel         *kernelPublisher // nil: kernel state is not published
	dryRun         bool
	reconcileCount *atomic.Int64
	selfSkipped    sync.Map // pod key -> struct{}: self_pod_skipped logged once
}

func (r *stunReconciler) forget(key string) {
	r.kernel.forget(key)
	r.selfSkipped.Delete(key)
}

func newStunReconciler(freezer *cgroupFreezer, tc *tcDropFilter, probes *probePreserver) *stunReconciler {
	if probes == nil {
		probes = newProbePreserver()
	}
	return &stunReconciler{
		freezer:        freezer,
		tc:             tc,
		probes:         probes,
		reconcileCount: &atomic.Int64{},
	}
}

func (r *stunReconciler) reconcile(pod *corev1.Pod) error {
	if isSentinelPod(pod) {
		if _, seen := r.selfSkipped.LoadOrStore(pod.Namespace+"/"+pod.Name, struct{}{}); !seen {
			logEvent(stunEvent{Timestamp: now(), Event: "self_pod_skipped", Pod: pod.Name, Namespace: pod.Namespace,
				UID: string(pod.UID), Decision: "never_contain_self", Details: map[string]interface{}{
					"service_account": pod.Spec.ServiceAccountName, "stunned_labels": isPodStunned(pod, nil)}})
		}
		return nil
	}
	start := time.Now()
	if r.reconcileCount != nil {
		r.reconcileCount.Add(1)
	}

	if pod == nil || pod.Name == "stun-sentinel" || (pod.Labels != nil && pod.Labels["app.kubernetes.io/name"] == "stun-sentinel") {
		return nil
	}
	if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
		return nil
	}

	// The owner lookup is needed before the cgroup is resolved: a pod whose
	// cgroup cannot be found is only an error when something says it is stunned,
	// and that includes its controller's stun record.
	var owners ownerStunLookup
	if r.kernel != nil {
		owners = r.kernel
	}

	cgroupPath, err := r.freezer.resolvePodCgroup(string(pod.UID))
	if err != nil {
		if !isPodStunned(pod, owners) {
			return nil
		}
		return fmt.Errorf("resolve cgroup: %w", err)
	}

	// Kernel truth FIRST, before any veth/tc work: it must publish even while
	// the veth step fails.
	stunned := isPodStunned(pod, owners)
	r.kernel.publish(pod, cgroupPath, stunned)

	if stunned {
		if err := r.freezer.freeze(cgroupPath); err != nil {
			return fmt.Errorf("freeze: %w", err)
		}
		veth, err := r.tc.findHostVeth(cgroupPath)
		if err != nil {
			return fmt.Errorf("find veth after freezing pod: %w", err)
		}
		if err := r.tc.attachDrop(veth); err != nil {
			return fmt.Errorf("attach drop filter after freezing pod: %w", err)
		}
		if err := r.probes.preserve(pod, cgroupPath, veth); err != nil {
			return fmt.Errorf("preserve liveness probes: %w", err)
		}

		latency := fmt.Sprintf("%.1f", float64(time.Since(start).Microseconds())/1000)
		var count int64
		if r.reconcileCount != nil {
			count = r.reconcileCount.Load()
		}
		decision := "containment_applied"
		if r.dryRun {
			decision = "containment_planned_dry_run"
		}
		event := stunEvent{
			Timestamp:       now(),
			Event:           "stun",
			Pod:             pod.Name,
			Namespace:       pod.Namespace,
			UID:             string(pod.UID),
			DryRun:          r.dryRun,
			Latency:         latency,
			CgroupPath:      cgroupPath,
			HostVeth:        veth,
			TCIngressFilter: fmt.Sprintf("pref %s ingress handle %s matchall action drop", sentinelIngressPref, sentinelIngressHandle),
			TCEgressFilter:  fmt.Sprintf("pref %s egress handle %s matchall action drop", sentinelEgressPref, sentinelEgressHandle),
			Decision:        decision,
			ProbesCount:     len(r.probes.detectProbes(pod)),
			ReconcileCount:  count,
		}
		logEvent(event)
		return nil
	}

	// Release order: thaw FIRST. The network layer must never block a
	// release: a pod frozen before its sandbox joined a netns has no
	// resolvable veth, and looking the veth up first left it frozen forever.
	if err := r.freezer.unfreeze(cgroupPath); err != nil {
		return fmt.Errorf("unfreeze: %w", err)
	}
	if err := r.probes.release(pod, cgroupPath, ""); err != nil {
		return fmt.Errorf("release liveness probes: %w", err)
	}

	var count int64
	if r.reconcileCount != nil {
		count = r.reconcileCount.Load()
	}

	veth, netErr := r.tc.findHostVeth(cgroupPath)
	if netErr != nil {
		netErr = fmt.Errorf("find veth after unfreezing pod: %w", netErr)
	} else if err := r.tc.detachDrop(veth); err != nil {
		netErr = fmt.Errorf("detach drop filter after unfreezing pod: %w", err)
	}
	if netErr != nil {
		// Thawed, but the drop filter may still be attached. Returning the
		// error requeues the detach; the thaw is already done.
		logEvent(stunEvent{
			Timestamp:      now(),
			Event:          "unstun_partial",
			Pod:            pod.Name,
			Namespace:      pod.Namespace,
			UID:            string(pod.UID),
			DryRun:         r.dryRun,
			CgroupPath:     cgroupPath,
			HostVeth:       veth,
			Decision:       "thawed_network_release_pending",
			ReconcileCount: count,
			Error:          netErr.Error(),
		})
		return netErr
	}

	decision := "containment_released"
	if r.dryRun {
		decision = "containment_release_planned_dry_run"
	}
	event := stunEvent{
		Timestamp:      now(),
		Event:          "unstun",
		Pod:            pod.Name,
		Namespace:      pod.Namespace,
		UID:            string(pod.UID),
		DryRun:         r.dryRun,
		CgroupPath:     cgroupPath,
		HostVeth:       veth,
		Decision:       decision,
		ReconcileCount: count,
	}
	logEvent(event)
	return nil
}

// newCorrelatorFreezeManager hands the eBPF correlator the same freezer engine,
// and so the same dry-run and credential policy, as the reconciler.
func newCorrelatorFreezeManager(f *cgroupFreezer) *correlator.FreezeManager {
	return correlator.NewFreezeManager(f.engine, f.freezeToken)
}

func main() {
	cfg := parseConfig(os.Args[1:])

	reconcileCount := &atomic.Int64{}
	healthSrv := newHealthServer(cfg.HealthAddr, cfg.DryRun, cfg.CgroupRoot, reconcileCount)
	// Set once the clientset exists; read concurrently by /metrics.
	var kernelRef atomic.Pointer[kernelPublisher]
	healthSrv.frozenUnlabelled = func() int { return kernelRef.Load().frozenUnlabelledCount() }

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	go func() {
		<-signals
		logEvent(stunEvent{Timestamp: now(), Event: "shutdown", DryRun: cfg.DryRun})
		cancel()
	}()

	// Start Health HTTP server in background
	go func() {
		if err := healthSrv.Start(ctx); err != nil {
			logEvent(stunEvent{Timestamp: now(), Event: "health_server_failed", Error: err.Error()})
		}
	}()

	freezer := newCgroupFreezer(cfg.CgroupRoot, cfg.DryRun, cfg.FreezeToken, cfg.ResumeToken)
	tc := newTCDropFilter()
	tc.dryRun = cfg.DryRun
	probes := newProbePreserver()
	probes.dryRun = cfg.DryRun

	reconciler := newStunReconciler(freezer, tc, probes)
	reconciler.dryRun = cfg.DryRun
	reconciler.reconcileCount = reconcileCount

	logEvent(stunEvent{
		Timestamp:  now(),
		Event:      "started",
		Namespace:  cfg.WatchNamespace,
		DryRun:     cfg.DryRun,
		CgroupPath: cfg.CgroupRoot,
		Details: map[string]interface{}{
			"health_addr":   cfg.HealthAddr,
			"cgroup_driver": healthSrv.cgroupDriver,
		},
	})

	config, err := rest.InClusterConfig()
	if err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: fmt.Sprintf("in-cluster config: %v", err), DryRun: cfg.DryRun})
		if cfg.DryRun {
			// In standalone dry-run mode without a Kubernetes cluster, keep the health server running
			<-ctx.Done()
			return
		}
		os.Exit(1)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: fmt.Sprintf("create clientset: %v", err), DryRun: cfg.DryRun})
		os.Exit(1)
	}

	reconciler.kernel = newKernelPublisher(clientsetAPI{cs: clientset}, informerResync, cfg.DryRun)
	kernelRef.Store(reconciler.kernel)

	factory := informers.NewSharedInformerFactoryWithOptions(clientset, informerResync,
		informers.WithNamespace(cfg.WatchNamespace),
		informers.WithTweakListOptions(func(options *metav1.ListOptions) { options.LabelSelector = "signalloom.ai/agent=true" }),
	)
	informer := factory.Core().V1().Pods().Informer()
	controller := newController(informer, reconciler)

	factory.Start(ctx.Done())
	// Initialize and start in-sentinel pure-Go eBPF probe loader & correlator (SLDC-P1-1, SLDC-P1-2)
	go func() {
		loader, err := bpfebpf.NewLoader(bpfebpf.LoaderOptions{
			IgnoreTGID: uint32(os.Getpid()),
		})
		if err != nil {
			logEvent(stunEvent{Timestamp: now(), Event: "ebpf_probe_skipped", Error: fmt.Sprintf("ebpf probe load: %v", err), DryRun: cfg.DryRun})
			return
		}
		defer loader.Close()

		logEvent(stunEvent{
			Timestamp: now(),
			Event:     "ebpf_probe_attached",
			Details: map[string]interface{}{
				"tracepoints": []string{"sys_enter_openat", "sys_enter_openat2", "sys_enter_execve", "sys_enter_connect"},
				"ringbuf_mb":  16,
			},
		})

		freezeMgr := newCorrelatorFreezeManager(freezer)
		probeMgr := correlator.NewSentinelProbeManager(informer, os.Getenv("SIGNAL_INGEST_URL"), freezeMgr, correlator.WithCgroupRoot(cfg.CgroupRoot))
		go reportCorrelatorStats(ctx, probeMgr.Stats, loader.Drops, 30*time.Second)
		if err := probeMgr.Start(ctx, loader.Reader()); err != nil {
			logEvent(stunEvent{Timestamp: now(), Event: "ebpf_correlator_stopped", Error: err.Error(), DryRun: cfg.DryRun})
		}
	}()

	controller.run(ctx.Done())
}

// reportCorrelatorStats logs the correlator's pipeline counters whenever they
// change. The correlator itself has no logger, and on a live node a provoked
// sensitive read once produced no observation with nothing to say which stage
// dropped it. One line per interval, only on change, keeps it quiet at rest.
//
// ringbuf_drops is the kernel's own count of events it could not reserve ring
// space for. Without it a provoked event lost in the kernel left every
// user-space counter unchanged (review M6).
func reportCorrelatorStats(ctx context.Context, stats func() correlator.Stats, drops func() (uint64, error), every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	var last correlator.Stats
	var lastDrops uint64
	first := true
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s := stats()
			d, err := drops()
			if !first && s == last && d == lastDrops && err == nil {
				continue
			}
			first, last, lastDrops = false, s, d
			details := map[string]interface{}{"stats": s, "ringbuf_drops": d}
			if err != nil {
				details["ringbuf_drops_error"] = err.Error()
			}
			logEvent(stunEvent{Timestamp: now(), Event: "ebpf_correlator_stats", Details: details})
		}
	}
}
