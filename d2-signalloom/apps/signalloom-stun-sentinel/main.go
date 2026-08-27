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
)

const (
	labelStunned    = "signalloom.ai/state"
	stunnedValue    = "stunned"
	watchNamespace  = "fe-signalloom-agents"
	defaultCgroupRoot = "/sys/fs/cgroup"
)

// stunEvent is the structured log output for stun/unstun operations.
type stunEvent struct {
	Timestamp string `json:"timestamp"`
	Event     string `json:"event"`
	Pod       string `json:"pod"`
	Namespace string `json:"namespace"`
	UID       string `json:"uid"`
	Latency   string `json:"latency_ms,omitempty"`
	Error     string `json:"error,omitempty"`
}

func main() {
	cgroupRoot := envOrDefault("CGROUP_ROOT", defaultCgroupRoot)
	ns := envOrDefault("WATCH_NAMESPACE", watchNamespace)

	config, err := rest.InClusterConfig()
	if err != nil {
		logEvent(stunEvent{
			Timestamp: now(),
			Event:     "startup_failed",
			Error:     fmt.Sprintf("in-cluster config: %v", err),
		})
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		logEvent(stunEvent{
			Timestamp: now(),
			Event:     "startup_failed",
			Error:     fmt.Sprintf("create clientset: %v", err),
		})
		os.Exit(1)
	}

	freezer := &cgroupFreezer{cgroupRoot: cgroupRoot}
	tc := &tcDropFilter{}

	// Track stunned pods to detect un-stun (label removal).
	stunnedPods := make(map[string]bool)

	factory := informers.NewSharedInformerFactoryWithOptions(
		clientset,
		30*time.Second,
		informers.WithNamespace(ns),
		informers.WithTweakListOptions(func(opts *metav1.ListOptions) {
			opts.LabelSelector = "signalloom.ai/agent=true"
		}),
	)

	podInformer := factory.Core().V1().Pods().Informer()
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		UpdateFunc: func(oldObj, newObj interface{}) {
			oldPod := oldObj.(*corev1.Pod)
			newPod := newObj.(*corev1.Pod)
			handlePodUpdate(oldPod, newPod, freezer, tc, stunnedPods)
		},
		AddFunc: func(obj interface{}) {
			pod := obj.(*corev1.Pod)
			if pod.Labels[labelStunned] == stunnedValue {
				handleStun(pod, freezer, tc, stunnedPods)
			}
		},
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Graceful shutdown.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		logEvent(stunEvent{Timestamp: now(), Event: "shutdown"})
		cancel()
	}()

	logEvent(stunEvent{
		Timestamp: now(),
		Event:     "started",
		Namespace: ns,
	})

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())

	<-ctx.Done()
}

func handlePodUpdate(oldPod, newPod *corev1.Pod, freezer *cgroupFreezer, tc *tcDropFilter, stunnedPods map[string]bool) {
	oldStunned := oldPod.Labels[labelStunned] == stunnedValue
	newStunned := newPod.Labels[labelStunned] == stunnedValue

	if !oldStunned && newStunned {
		handleStun(newPod, freezer, tc, stunnedPods)
	} else if oldStunned && !newStunned {
		handleUnstun(newPod, freezer, tc, stunnedPods)
	}
}

func handleStun(pod *corev1.Pod, freezer *cgroupFreezer, tc *tcDropFilter, stunnedPods map[string]bool) {
	start := time.Now()
	podKey := string(pod.UID)

	evt := stunEvent{
		Timestamp: now(),
		Event:     "stun",
		Pod:       pod.Name,
		Namespace: pod.Namespace,
		UID:       podKey,
	}

	// Step 1: Freeze the pod's cgroup.
	cgroupPath, err := freezer.resolvePodCgroup(podKey)
	if err != nil {
		evt.Error = fmt.Sprintf("resolve cgroup: %v", err)
		logEvent(evt)
		return
	}

	if err := freezer.freeze(cgroupPath); err != nil {
		evt.Error = fmt.Sprintf("freeze: %v", err)
		logEvent(evt)
		return
	}

	// Step 2: Attach TC drop filter on the host veth.
	veth, err := tc.findHostVeth(pod.Name, pod.Namespace)
	if err != nil {
		evt.Error = fmt.Sprintf("find veth: %v (cgroup frozen, network not dropped)", err)
		logEvent(evt)
		stunnedPods[podKey] = true
		return
	}

	if err := tc.attachDrop(veth); err != nil {
		evt.Error = fmt.Sprintf("tc attach: %v (cgroup frozen, network not dropped)", err)
		logEvent(evt)
		stunnedPods[podKey] = true
		return
	}

	elapsed := time.Since(start)
	evt.Latency = fmt.Sprintf("%.1f", float64(elapsed.Microseconds())/1000.0)
	stunnedPods[podKey] = true
	logEvent(evt)
}

func handleUnstun(pod *corev1.Pod, freezer *cgroupFreezer, tc *tcDropFilter, stunnedPods map[string]bool) {
	podKey := string(pod.UID)

	evt := stunEvent{
		Timestamp: now(),
		Event:     "unstun",
		Pod:       pod.Name,
		Namespace: pod.Namespace,
		UID:       podKey,
	}

	// Step 1: Unfreeze the pod's cgroup.
	cgroupPath, err := freezer.resolvePodCgroup(podKey)
	if err != nil {
		evt.Error = fmt.Sprintf("resolve cgroup: %v", err)
		logEvent(evt)
		delete(stunnedPods, podKey)
		return
	}

	if err := freezer.unfreeze(cgroupPath); err != nil {
		evt.Error = fmt.Sprintf("unfreeze: %v", err)
		logEvent(evt)
		delete(stunnedPods, podKey)
		return
	}

	// Step 2: Remove TC drop filter.
	veth, err := tc.findHostVeth(pod.Name, pod.Namespace)
	if err != nil {
		evt.Error = fmt.Sprintf("find veth for detach: %v", err)
		logEvent(evt)
		delete(stunnedPods, podKey)
		return
	}

	if err := tc.detachDrop(veth); err != nil {
		evt.Error = fmt.Sprintf("tc detach: %v", err)
	}

	delete(stunnedPods, podKey)
	logEvent(evt)
}

func logEvent(evt stunEvent) {
	json.NewEncoder(os.Stdout).Encode(evt)
}

func now() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
