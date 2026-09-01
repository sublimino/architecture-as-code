package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"
)

const (
	labelStunned      = "signalloom.ai/state"
	stunnedValue      = "stunned"
	watchNamespace    = "fe-signalloom-agents"
	defaultCgroupRoot = "/sys/fs/cgroup"
)

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
	dryRun         bool
	reconcileCount *atomic.Int64
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
	start := time.Now()
	if r.reconcileCount != nil {
		r.reconcileCount.Add(1)
	}

	cgroupPath, err := r.freezer.resolvePodCgroup(string(pod.UID))
	if err != nil {
		return fmt.Errorf("resolve cgroup: %w", err)
	}

	if pod.Labels[labelStunned] == stunnedValue {
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

	veth, err := r.tc.findHostVeth(cgroupPath)
	if err != nil {
		return fmt.Errorf("find veth before unfreezing pod: %w", err)
	}
	if err := r.probes.release(pod, cgroupPath, veth); err != nil {
		return fmt.Errorf("release liveness probes: %w", err)
	}
	if err := r.tc.detachDrop(veth); err != nil {
		return fmt.Errorf("detach drop filter: %w", err)
	}
	if err := r.freezer.unfreeze(cgroupPath); err != nil {
		return fmt.Errorf("unfreeze: %w", err)
	}

	var count int64
	if r.reconcileCount != nil {
		count = r.reconcileCount.Load()
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

func main() {
	cfg := parseConfig(os.Args[1:])

	reconcileCount := &atomic.Int64{}
	healthSrv := newHealthServer(cfg.HealthAddr, cfg.DryRun, cfg.CgroupRoot, reconcileCount)

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

	freezer := &cgroupFreezer{cgroupRoot: cfg.CgroupRoot, dryRun: cfg.DryRun}
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

	factory := informers.NewSharedInformerFactoryWithOptions(clientset, 30*time.Second,
		informers.WithNamespace(cfg.WatchNamespace),
		informers.WithTweakListOptions(func(options *metav1.ListOptions) { options.LabelSelector = "signalloom.ai/agent=true" }),
	)
	informer := factory.Core().V1().Pods().Informer()
	controller := newController(informer, reconciler)

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), informer.HasSynced) {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: "pod informer cache did not sync", DryRun: cfg.DryRun})
		return
	}
	controller.run(ctx.Done())
}
