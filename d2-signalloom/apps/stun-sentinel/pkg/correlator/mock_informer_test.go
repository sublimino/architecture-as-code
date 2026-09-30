// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/cache"
)

// MockPodStore implements cache.Store and cache.Indexer in-memory for testing.
type MockPodStore struct {
	mu   sync.RWMutex
	pods map[string]*corev1.Pod
}

func NewMockPodStore() *MockPodStore {
	return &MockPodStore{
		pods: make(map[string]*corev1.Pod),
	}
}

func (s *MockPodStore) Add(obj interface{}) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if pod, ok := obj.(*corev1.Pod); ok {
		key := pod.Namespace + "/" + pod.Name
		s.pods[key] = pod
	}
	return nil
}

func (s *MockPodStore) Update(obj interface{}) error {
	return s.Add(obj)
}

func (s *MockPodStore) Delete(obj interface{}) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if pod, ok := obj.(*corev1.Pod); ok {
		key := pod.Namespace + "/" + pod.Name
		delete(s.pods, key)
	}
	return nil
}

func (s *MockPodStore) List() []interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()
	res := make([]interface{}, 0, len(s.pods))
	for _, p := range s.pods {
		res = append(res, p)
	}
	return res
}

func (s *MockPodStore) ListKeys() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	keys := make([]string, 0, len(s.pods))
	for k := range s.pods {
		keys = append(keys, k)
	}
	return keys
}

func (s *MockPodStore) Get(obj interface{}) (item interface{}, exists bool, err error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if pod, ok := obj.(*corev1.Pod); ok {
		key := pod.Namespace + "/" + pod.Name
		p, found := s.pods[key]
		return p, found, nil
	}
	return nil, false, nil
}

func (s *MockPodStore) GetByKey(key string) (item interface{}, exists bool, err error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, found := s.pods[key]
	return p, found, nil
}

func (s *MockPodStore) Replace(list []interface{}, resourceVersion string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pods = make(map[string]*corev1.Pod)
	for _, obj := range list {
		if pod, ok := obj.(*corev1.Pod); ok {
			key := pod.Namespace + "/" + pod.Name
			s.pods[key] = pod
		}
	}
	return nil
}

func (s *MockPodStore) Resync() error { return nil }

func (s *MockPodStore) Index(indexName string, obj interface{}) ([]interface{}, error) {
	return s.List(), nil
}

func (s *MockPodStore) IndexKeys(indexName, indexedValue string) ([]string, error) {
	return s.ListKeys(), nil
}

func (s *MockPodStore) ListIndexFuncValues(indexName string) []string {
	return nil
}

func (s *MockPodStore) ByIndex(indexName, indexedValue string) ([]interface{}, error) {
	return s.List(), nil
}

func (s *MockPodStore) GetIndexers() cache.Indexers {
	return cache.Indexers{}
}

func (s *MockPodStore) AddIndexers(newIndexers cache.Indexers) error {
	return nil
}

// MockSharedIndexInformer implements cache.SharedIndexInformer for hermetic testing.
type MockSharedIndexInformer struct {
	store    *MockPodStore
	handlers []cache.ResourceEventHandler
	synced   bool
	mu       sync.Mutex
}

func NewMockSharedIndexInformer() *MockSharedIndexInformer {
	return &MockSharedIndexInformer{
		store:  NewMockPodStore(),
		synced: true,
	}
}

func (m *MockSharedIndexInformer) AddEventHandler(handler cache.ResourceEventHandler) (cache.ResourceEventHandlerRegistration, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.handlers = append(m.handlers, handler)
	return nil, nil
}

func (m *MockSharedIndexInformer) AddEventHandlerWithResyncPeriod(handler cache.ResourceEventHandler, resyncPeriod time.Duration) (cache.ResourceEventHandlerRegistration, error) {
	return m.AddEventHandler(handler)
}

func (m *MockSharedIndexInformer) RemoveEventHandler(handle cache.ResourceEventHandlerRegistration) error {
	return nil
}

func (m *MockSharedIndexInformer) GetStore() cache.Store {
	return m.store
}

func (m *MockSharedIndexInformer) GetIndexer() cache.Indexer {
	return m.store
}

func (m *MockSharedIndexInformer) GetController() cache.Controller {
	return nil
}

func (m *MockSharedIndexInformer) Run(stopCh <-chan struct{}) {
	m.mu.Lock()
	m.synced = true
	m.mu.Unlock()
	<-stopCh
}

func (m *MockSharedIndexInformer) HasSynced() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.synced
}

func (m *MockSharedIndexInformer) LastSyncResourceVersion() string {
	return "1"
}

func (m *MockSharedIndexInformer) SetWatchErrorHandler(handler cache.WatchErrorHandler) error {
	return nil
}

func (m *MockSharedIndexInformer) SetTransform(handler cache.TransformFunc) error {
	return nil
}

func (m *MockSharedIndexInformer) AddIndexers(indexers cache.Indexers) error {
	return nil
}

func (m *MockSharedIndexInformer) IsStopped() bool {
	return false
}

// InjectPod adds a pod to the store and notifies registered event handlers.
func (m *MockSharedIndexInformer) InjectPod(pod *corev1.Pod) {
	_ = m.store.Add(pod)
	m.mu.Lock()
	handlers := append([]cache.ResourceEventHandler(nil), m.handlers...)
	m.mu.Unlock()

	for _, h := range handlers {
		h.OnAdd(pod, true)
	}
}

// CreateTestPod creates a standard synthetic Pod object for test fixtures.
func CreateTestPod(namespace, name, uid, agentName, tenant string) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: namespace,
			Name:      name,
			UID:       types.UID(uid),
			Labels: map[string]string{
				"signalloom.ai/agent":      "true",
				"signalloom.ai/agent-name": agentName,
				"tenant":                   tenant,
			},
		},
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning,
			ContainerStatuses: []corev1.ContainerStatus{
				{
					Name:        "agent-container",
					ContainerID: "containerd://e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
					Ready:       true,
				},
			},
		},
	}
}

var _ runtime.Object = (*corev1.Pod)(nil)
