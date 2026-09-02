package main

import (
	"errors"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"
)

type recordingReconciler struct {
	pods []*corev1.Pod
	err  error
}

func (r *recordingReconciler) reconcile(pod *corev1.Pod) error {
	r.pods = append(r.pods, pod.DeepCopy())
	return r.err
}

func testPod(state string) *corev1.Pod {
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "agents", Name: "arthur"}}
	if state != "" {
		pod.Labels = map[string]string{labelStunned: state}
	}
	return pod
}

func newTestController(reconciler podReconciler) (*controller, workqueue.TypedRateLimitingInterface[string]) {
	queue := workqueue.NewTypedRateLimitingQueue(workqueue.NewTypedItemExponentialFailureRateLimiter[string](0, 0))
	return &controller{
		indexer:    cache.NewIndexer(cache.MetaNamespaceKeyFunc, cache.Indexers{}),
		queue:      queue,
		reconciler: reconciler,
	}, queue
}

func TestCallbacksOnlyEnqueueKeys(t *testing.T) {
	reconciler := &recordingReconciler{}
	controller, queue := newTestController(reconciler)
	defer queue.ShutDown()

	pod := testPod(stunnedValue)
	controller.onAdd(pod)
	controller.onUpdate(pod, pod.DeepCopy())
	controller.onDelete(cache.DeletedFinalStateUnknown{Key: "agents/arthur", Obj: pod})

	if len(reconciler.pods) != 0 {
		t.Fatalf("callbacks reconciled %d pods; want no host work", len(reconciler.pods))
	}
	if queue.Len() != 1 {
		t.Fatalf("queued %d keys; want one deduplicated key", queue.Len())
	}
}

func TestWorkerUsesLatestCachedStateAndResyncReconciles(t *testing.T) {
	reconciler := &recordingReconciler{}
	controller, queue := newTestController(reconciler)
	defer queue.ShutDown()

	oldPod := testPod("")
	if err := controller.indexer.Add(oldPod); err != nil {
		t.Fatal(err)
	}
	latest := testPod(stunnedValue)
	if err := controller.indexer.Update(latest); err != nil {
		t.Fatal(err)
	}

	controller.onUpdate(oldPod, latest)
	if !controller.processNextWorkItem() {
		t.Fatal("worker stopped unexpectedly")
	}
	controller.onUpdate(latest, latest.DeepCopy()) // informer resync: unchanged labels.
	if !controller.processNextWorkItem() {
		t.Fatal("worker stopped unexpectedly")
	}

	if len(reconciler.pods) != 2 {
		t.Fatalf("reconciled %d pods; want two", len(reconciler.pods))
	}
	for _, pod := range reconciler.pods {
		if pod.Labels[labelStunned] != stunnedValue {
			t.Fatalf("reconciled stale pod state: %#v", pod.Labels)
		}
	}
}

func TestWorkerRateLimitsFailuresAndForgetsSuccess(t *testing.T) {
	reconciler := &recordingReconciler{err: errors.New("transient")}
	controller, queue := newTestController(reconciler)
	defer queue.ShutDown()
	pod := testPod(stunnedValue)
	if err := controller.indexer.Add(pod); err != nil {
		t.Fatal(err)
	}
	controller.enqueue(pod)
	controller.processNextWorkItem()

	key := "agents/arthur"
	if queue.NumRequeues(key) != 1 {
		t.Fatalf("requeues = %d, want 1", queue.NumRequeues(key))
	}

	reconciler.err = nil
	if !controller.processNextWorkItem() {
		t.Fatal("worker stopped unexpectedly")
	}
	if queue.NumRequeues(key) != 0 {
		t.Fatalf("requeues after success = %d, want 0", queue.NumRequeues(key))
	}
}

func TestMissingCachedObjectIsSuccessfulNoop(t *testing.T) {
	reconciler := &recordingReconciler{}
	controller, queue := newTestController(reconciler)
	defer queue.ShutDown()
	controller.enqueue(testPod(stunnedValue))
	controller.processNextWorkItem()
	if len(reconciler.pods) != 0 {
		t.Fatalf("reconciled deleted pod")
	}
}

func TestControllerShutdownUnblocksIdleWorker(t *testing.T) {
	controller, _ := newTestController(&recordingReconciler{})
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		controller.run(stop)
		close(done)
	}()

	close(stop)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("idle worker remained blocked after shutdown")
	}
}
