package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
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

type stunEvent struct {
	Timestamp string `json:"timestamp"`
	Event     string `json:"event"`
	Pod       string `json:"pod"`
	Namespace string `json:"namespace"`
	UID       string `json:"uid"`
	Latency   string `json:"latency_ms,omitempty"`
	Error     string `json:"error,omitempty"`
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
	freezer *cgroupFreezer
	tc      *tcDropFilter
}

func (r *stunReconciler) reconcile(pod *corev1.Pod) error {
	start := time.Now()
	event := stunEvent{Timestamp: now(), Pod: pod.Name, Namespace: pod.Namespace, UID: string(pod.UID)}
	cgroupPath, err := r.freezer.resolvePodCgroup(string(pod.UID))
	if err != nil {
		return fmt.Errorf("resolve cgroup: %w", err)
	}

	if pod.Labels[labelStunned] == stunnedValue {
		event.Event = "stun"
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
		event.Latency = fmt.Sprintf("%.1f", float64(time.Since(start).Microseconds())/1000)
		logEvent(event)
		return nil
	}

	event.Event = "unstun"
	if err := r.freezer.unfreeze(cgroupPath); err != nil {
		return fmt.Errorf("unfreeze: %w", err)
	}
	veth, err := r.tc.findHostVeth(cgroupPath)
	if err != nil {
		return fmt.Errorf("find veth after unfreezing pod: %w", err)
	}
	if err := r.tc.detachDrop(veth); err != nil {
		return fmt.Errorf("detach drop filter: %w", err)
	}
	logEvent(event)
	return nil
}

func main() {
	cgroupRoot := envOrDefault("CGROUP_ROOT", defaultCgroupRoot)
	namespace := envOrDefault("WATCH_NAMESPACE", watchNamespace)
	config, err := rest.InClusterConfig()
	if err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: fmt.Sprintf("in-cluster config: %v", err)})
		os.Exit(1)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: fmt.Sprintf("create clientset: %v", err)})
		os.Exit(1)
	}

	factory := informers.NewSharedInformerFactoryWithOptions(clientset, 30*time.Second,
		informers.WithNamespace(namespace),
		informers.WithTweakListOptions(func(options *metav1.ListOptions) { options.LabelSelector = "signalloom.ai/agent=true" }),
	)
	informer := factory.Core().V1().Pods().Informer()
	controller := newController(informer, &stunReconciler{freezer: &cgroupFreezer{cgroupRoot: cgroupRoot}, tc: newTCDropFilter()})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	go func() { <-signals; logEvent(stunEvent{Timestamp: now(), Event: "shutdown"}); cancel() }()

	logEvent(stunEvent{Timestamp: now(), Event: "started", Namespace: namespace})
	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), informer.HasSynced) {
		logEvent(stunEvent{Timestamp: now(), Event: "startup_failed", Error: "pod informer cache did not sync"})
		return
	}
	controller.run(ctx.Done())
}

func logEvent(event stunEvent) { _ = json.NewEncoder(os.Stdout).Encode(event) }
func now() string              { return time.Now().UTC().Format(time.RFC3339Nano) }
func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
