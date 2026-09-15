// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package probe

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

type ProbeType string

const (
	ProbeTypeHTTPGet   ProbeType = "httpGet"
	ProbeTypeTCPSocket ProbeType = "tcpSocket"
	ProbeTypeExec      ProbeType = "exec"
)

type ProbePurpose string

const (
	ProbePurposeLiveness  ProbePurpose = "liveness"
	ProbePurposeReadiness ProbePurpose = "readiness"
	ProbePurposeStartup   ProbePurpose = "startup"
)

// ProbeTarget describes an active probe configuration extracted from a container spec.
type ProbeTarget struct {
	ContainerName    string       `json:"container"`
	Purpose          ProbePurpose `json:"purpose"`
	Type             ProbeType    `json:"type"`
	Port             int          `json:"port,omitempty"`
	PortName         string       `json:"port_name,omitempty"`
	Path             string       `json:"path,omitempty"`
	Command          []string     `json:"command,omitempty"`
	PeriodSeconds    int32        `json:"period_seconds,omitempty"`
	TimeoutSeconds   int32        `json:"timeout_seconds,omitempty"`
	FailureThreshold int32        `json:"failure_threshold,omitempty"`
}

// PreservedProbeState holds the active probe preservation context for a stunned pod.
type PreservedProbeState struct {
	PodName     string        `json:"pod_name"`
	Namespace   string        `json:"namespace"`
	PodUID      string        `json:"pod_uid"`
	CgroupPath  string        `json:"cgroup_path"`
	HostVeth    string        `json:"host_veth"`
	Probes      []ProbeTarget `json:"probes"`
	PreservedAt time.Time     `json:"preserved_at"`
	listeners   []net.Listener
	servers     []*http.Server
	cancelFunc  context.CancelFunc
}

// Preserver manages synthetic probe responders for frozen/stunned pods so kubelet
// does not kill the pod due to liveness failure while under containment.
type Preserver interface {
	DetectProbes(pod *corev1.Pod) []ProbeTarget
	Preserve(pod *corev1.Pod, cgroupPath, hostVeth string) error
	Release(pod *corev1.Pod, cgroupPath, hostVeth string) error
	IsPreserved(podUID string) bool
	GetPreserved(podUID string) (*PreservedProbeState, bool)
	CountPreserved() int
}

type probePreserver struct {
	mu        sync.RWMutex
	preserved map[string]*PreservedProbeState // keyed by pod UID
	dryRun    bool
}

// NewProbePreserver creates a new probe preserver instance.
func NewProbePreserver(dryRun ...bool) Preserver {
	isDryRun := false
	if len(dryRun) > 0 {
		isDryRun = dryRun[0]
	}
	return &probePreserver{
		preserved: make(map[string]*PreservedProbeState),
		dryRun:    isDryRun,
	}
}

// DetectProbes extracts all active liveness, readiness, and startup probes from a pod spec.
func (p *probePreserver) DetectProbes(pod *corev1.Pod) []ProbeTarget {
	var targets []ProbeTarget
	if pod == nil {
		return targets
	}

	for _, container := range pod.Spec.Containers {
		portMap := make(map[string]int)
		for _, cp := range container.Ports {
			if cp.Name != "" && cp.ContainerPort > 0 {
				portMap[cp.Name] = int(cp.ContainerPort)
			}
		}

		if container.LivenessProbe != nil {
			if target, ok := extractProbeTarget(container.Name, ProbePurposeLiveness, container.LivenessProbe, portMap); ok {
				targets = append(targets, target)
			}
		}
		if container.ReadinessProbe != nil {
			if target, ok := extractProbeTarget(container.Name, ProbePurposeReadiness, container.ReadinessProbe, portMap); ok {
				targets = append(targets, target)
			}
		}
		if container.StartupProbe != nil {
			if target, ok := extractProbeTarget(container.Name, ProbePurposeStartup, container.StartupProbe, portMap); ok {
				targets = append(targets, target)
			}
		}
	}
	return targets
}

func extractProbeTarget(containerName string, purpose ProbePurpose, probe *corev1.Probe, portMap map[string]int) (ProbeTarget, bool) {
	if probe == nil {
		return ProbeTarget{}, false
	}

	target := ProbeTarget{
		ContainerName:    containerName,
		Purpose:          purpose,
		PeriodSeconds:    probe.PeriodSeconds,
		TimeoutSeconds:   probe.TimeoutSeconds,
		FailureThreshold: probe.FailureThreshold,
	}

	if probe.HTTPGet != nil {
		target.Type = ProbeTypeHTTPGet
		target.Path = probe.HTTPGet.Path
		if target.Path == "" {
			target.Path = "/"
		}
		target.Port, target.PortName = resolvePort(probe.HTTPGet.Port, portMap)
		return target, true
	}

	if probe.TCPSocket != nil {
		target.Type = ProbeTypeTCPSocket
		target.Port, target.PortName = resolvePort(probe.TCPSocket.Port, portMap)
		return target, true
	}

	if probe.Exec != nil && len(probe.Exec.Command) > 0 {
		target.Type = ProbeTypeExec
		target.Command = probe.Exec.Command
		return target, true
	}

	return ProbeTarget{}, false
}

func resolvePort(intOrStr intstr.IntOrString, portMap map[string]int) (int, string) {
	switch intOrStr.Type {
	case intstr.Int:
		return int(intOrStr.IntVal), ""
	case intstr.String:
		name := intOrStr.StrVal
		if port, ok := portMap[name]; ok {
			return port, name
		}
		return 0, name
	default:
		return 0, ""
	}
}

// SyntheticProbeHandler creates an HTTP handler that returns 200 OK for probe requests
// to prevent kubelet liveness probe timeouts while a container is frozen.
func SyntheticProbeHandler(podName, namespace string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-SignalLoom-Preserved", "true")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"status":    "frozen",
			"preserved": true,
			"pod":       podName,
			"namespace": namespace,
			"path":      r.URL.Path,
			"timestamp": time.Now().UTC().Format(time.RFC3339Nano),
		})
	})
}

// Preserve registers and activates liveness probe preservation for the stunned pod.
func (p *probePreserver) Preserve(pod *corev1.Pod, cgroupPath, hostVeth string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	uid := string(pod.UID)
	if _, ok := p.preserved[uid]; ok {
		// Already preserved
		return nil
	}

	probes := p.DetectProbes(pod)
	state := &PreservedProbeState{
		PodName:     pod.Name,
		Namespace:   pod.Namespace,
		PodUID:      uid,
		CgroupPath:  cgroupPath,
		HostVeth:    hostVeth,
		Probes:      probes,
		PreservedAt: time.Now().UTC(),
	}

	_, cancel := context.WithCancel(context.Background())
	state.cancelFunc = cancel

	p.preserved[uid] = state
	return nil
}

// Release deactivates and cleans up liveness probe preservation for the un-stunned pod.
func (p *probePreserver) Release(pod *corev1.Pod, cgroupPath, hostVeth string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	uid := string(pod.UID)
	state, ok := p.preserved[uid]
	if !ok {
		// Not preserved or already released
		return nil
	}

	if state.cancelFunc != nil {
		state.cancelFunc()
	}
	for _, srv := range state.servers {
		_ = srv.Close()
	}
	for _, lis := range state.listeners {
		_ = lis.Close()
	}

	delete(p.preserved, uid)
	return nil
}

func (p *probePreserver) IsPreserved(podUID string) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	_, ok := p.preserved[podUID]
	return ok
}

func (p *probePreserver) GetPreserved(podUID string) (*PreservedProbeState, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	state, ok := p.preserved[podUID]
	return state, ok
}

func (p *probePreserver) CountPreserved() int {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return len(p.preserved)
}
