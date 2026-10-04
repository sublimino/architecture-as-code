// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Workload report (remote-contract.md "Workload report"). A remote warden is
// the only thing on its cluster that knows which pods exist, so it tells
// fleet-manager, at start and every FLEET_REPORT_INTERVAL:
//
//	POST {FLEET_MANAGER_URL}/api/v1/fleet/workloads/report
//	Authorization: Bearer {fleet caller key}        (scope report)
//	{"cluster_id", "node", "reported_at", "pods": [{namespace, name, uid,
//	  owner {kind, name}, tenant, labels, frozen}]}
//
// fleet-manager keys its registry by cluster_id/namespace/name and drops an
// entry not reported for three intervals, so a missed report is retried at
// the next tick, never blocked on. The report is observation only: it never
// gates a freeze and runs on its own goroutine.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const fleetReportTimeout = 10 * time.Second

type workloadOwner struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

type workloadPod struct {
	Namespace string            `json:"namespace"`
	Name      string            `json:"name"`
	UID       string            `json:"uid"`
	Owner     *workloadOwner    `json:"owner,omitempty"`
	Tenant    string            `json:"tenant"`
	Labels    map[string]string `json:"labels"`
	Frozen    bool              `json:"frozen"`
}

type workloadReport struct {
	ClusterID  string        `json:"cluster_id"`
	Node       string        `json:"node"`
	ReportedAt string        `json:"reported_at"`
	Pods       []workloadPod `json:"pods"`
}

// fleetReporter builds and posts the report.
type fleetReporter struct {
	baseURL   string
	key       func() string // the caller key; "" means not yet available
	client    *http.Client
	clusterID string
	node      string
	interval  time.Duration

	listPods  func() []*corev1.Pod     // the informer's view
	tenantFor func(*corev1.Pod) string // the operator's tenant map
	frozen    func(*corev1.Pod) bool   // hold or kernel state
	now       func() time.Time

	failures  atomic.Int64
	delivered atomic.Int64
}

func newFleetReporter(baseURL string, key func() string, client *http.Client, clusterID, node string, interval time.Duration) *fleetReporter {
	if client == nil {
		client = &http.Client{Timeout: fleetReportTimeout}
	}
	if interval <= 0 {
		interval = DefaultFleetReportInterval
	}
	return &fleetReporter{
		baseURL:   strings.TrimRight(baseURL, "/"),
		key:       key,
		client:    client,
		clusterID: clusterID,
		node:      node,
		interval:  interval,
		listPods:  func() []*corev1.Pod { return nil },
		tenantFor: func(*corev1.Pod) string { return "" },
		frozen:    func(*corev1.Pod) bool { return false },
		now:       time.Now,
	}
}

// ownerOf names the pod's controller. A ReplicaSet whose name is
// "<deployment>-<pod-template-hash>" is reported as its Deployment, because
// that is the name an operator stuns by; the hash is the pod's own label so no
// API call is needed. Anything else is reported as the controller itself.
func ownerOf(pod *corev1.Pod) *workloadOwner {
	ref := metav1.GetControllerOf(pod)
	if ref == nil {
		return nil
	}
	if ref.Kind == "ReplicaSet" {
		if hash := pod.Labels["pod-template-hash"]; hash != "" && strings.HasSuffix(ref.Name, "-"+hash) {
			return &workloadOwner{Kind: "Deployment", Name: strings.TrimSuffix(ref.Name, "-"+hash)}
		}
	}
	return &workloadOwner{Kind: ref.Kind, Name: ref.Name}
}

// build renders the report for this node: every watched pod scheduled here
// that is not the warden itself and has not finished.
func (r *fleetReporter) build() workloadReport {
	rep := workloadReport{ClusterID: r.clusterID, Node: r.node, ReportedAt: r.now().UTC().Format(time.RFC3339), Pods: []workloadPod{}}
	for _, pod := range r.listPods() {
		if pod == nil || isSentinelPod(pod) {
			continue
		}
		if r.node != "" && pod.Spec.NodeName != r.node {
			continue
		}
		if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
			continue
		}
		labels := make(map[string]string, len(pod.Labels))
		for k, v := range pod.Labels {
			labels[k] = v
		}
		rep.Pods = append(rep.Pods, workloadPod{
			Namespace: pod.Namespace,
			Name:      pod.Name,
			UID:       string(pod.UID),
			Owner:     ownerOf(pod),
			Tenant:    r.tenantFor(pod),
			Labels:    labels,
			Frozen:    r.frozen(pod),
		})
	}
	sort.Slice(rep.Pods, func(i, j int) bool {
		if rep.Pods[i].Namespace != rep.Pods[j].Namespace {
			return rep.Pods[i].Namespace < rep.Pods[j].Namespace
		}
		return rep.Pods[i].Name < rep.Pods[j].Name
	})
	return rep
}

// report posts one report. Every failure is logged and counted; the caller
// retries at the next interval.
func (r *fleetReporter) report(ctx context.Context) error {
	key := r.key()
	if r.baseURL == "" || key == "" || r.clusterID == "" {
		return r.fail("unconfigured", 0, "FLEET_MANAGER_URL, the fleet caller key and SIGNAL_CLUSTER_ID are all required")
	}
	rep := r.build()
	body, err := json.Marshal(rep)
	if err != nil {
		return r.fail("encode", 0, err.Error())
	}
	ctx, cancel := context.WithTimeout(ctx, fleetReportTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.baseURL+"/api/v1/fleet/workloads/report", bytes.NewReader(body))
	if err != nil {
		return r.fail("request", 0, err.Error())
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := r.client.Do(req)
	if err != nil {
		return r.fail("transport", 0, err.Error())
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		kind := "refused"
		if resp.StatusCode >= 500 {
			kind = "server"
		}
		return r.fail(kind, resp.StatusCode, fmt.Sprintf("fleet-manager answered %d", resp.StatusCode))
	}
	r.delivered.Add(1)
	logEvent(stunEvent{Timestamp: now(), Event: "fleet_report_delivered", Decision: "registry_updated",
		Details: map[string]interface{}{"cluster_id": r.clusterID, "node": r.node, "pods": len(rep.Pods), "status": resp.StatusCode}})
	return nil
}

func (r *fleetReporter) fail(kind string, status int, detail string) error {
	total := r.failures.Add(1)
	details := map[string]interface{}{"kind": kind, "cluster_id": r.clusterID, "node": r.node, "fleet_report_failures_total": total}
	if status != 0 {
		details["status"] = status
	}
	logEvent(stunEvent{Timestamp: now(), Event: "fleet_report_failed", Decision: "retry_next_interval", Error: detail, Details: details})
	return fmt.Errorf("fleet report %s: %s", kind, detail)
}

// run reports at start and then every interval until ctx ends.
func (r *fleetReporter) run(ctx context.Context) {
	_ = r.report(ctx)
	t := time.NewTicker(r.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = r.report(ctx)
		}
	}
}
