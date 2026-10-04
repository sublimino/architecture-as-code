// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Stun-state poll (remote-contract.md "Stun state and resume"). fleet-manager
// takes no Kubernetes action on a remote cluster; it writes a stun record and
// waits for the node's warden to act. Every FLEET_POLL_INTERVAL:
//
//	GET  {FLEET_MANAGER_URL}/api/v1/fleet/stun-state?cluster_id=   (scope report)
//	-> records in state stun_requested or resume_requested
//
// For a record naming a pod on this node: stun_requested freezes it through
// the hold (stunhold.go freezeRemote) and acks "stunned"; resume_requested
// marks the hold for release, enqueues the pod so the reconciler thaws it
// through the usual release path (probes, tc, kernel), and acks "resumed"
// once the hold is gone:
//
//	POST {FLEET_MANAGER_URL}/api/v1/fleet/stun-state/ack
//	{id, state: "stunned"|"resumed", node, at}
//
// A record for a pod not on this node is another warden's. An ack that fails
// is retried at the next poll: the record comes back and the freeze is
// idempotent. The local label path is untouched.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
)

const (
	fleetPollTimeout = 10 * time.Second
	// fleetResumeWait bounds how long one poll waits for the reconciler to
	// release a hold before leaving the ack to the next poll.
	fleetResumeWait = 5 * time.Second

	stunStateRequested = "stun_requested"
	stunStateResume    = "resume_requested"
	ackStunned         = "stunned"
	ackResumed         = "resumed"
)

// fleetStunRecord is one record from GET /api/v1/fleet/stun-state.
type fleetStunRecord struct {
	ID          string `json:"id"`
	ClusterID   string `json:"cluster_id"`
	Namespace   string `json:"namespace"`
	Name        string `json:"name"`
	Reason      string `json:"reason"`
	RequestedBy string `json:"requested_by"`
	RequestedAt string `json:"requested_at"`
	State       string `json:"state"`
}

type fleetAck struct {
	ID    string `json:"id"`
	State string `json:"state"`
	Node  string `json:"node"`
	At    string `json:"at"`
}

type fleetPoller struct {
	baseURL   string
	key       func() string
	client    *http.Client
	clusterID string
	node      string
	interval  time.Duration

	findPod    func(namespace, name string) *corev1.Pod // the informer's view
	holds      *stunHolds
	now        func() time.Time
	resumeWait time.Duration
	sleep      func(time.Duration)

	failures atomic.Int64
	acked    atomic.Int64
}

func newFleetPoller(baseURL string, key func() string, client *http.Client, clusterID, node string, interval time.Duration, holds *stunHolds) *fleetPoller {
	if client == nil {
		client = &http.Client{Timeout: fleetPollTimeout}
	}
	if interval <= 0 {
		interval = DefaultFleetPollInterval
	}
	return &fleetPoller{
		baseURL:    strings.TrimRight(baseURL, "/"),
		key:        key,
		client:     client,
		clusterID:  clusterID,
		node:       node,
		interval:   interval,
		findPod:    func(string, string) *corev1.Pod { return nil },
		holds:      holds,
		now:        time.Now,
		resumeWait: fleetResumeWait,
		sleep:      time.Sleep,
	}
}

func (p *fleetPoller) run(ctx context.Context) {
	p.poll(ctx)
	t := time.NewTicker(p.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.poll(ctx)
		}
	}
}

// poll fetches the cluster's open records and handles each.
func (p *fleetPoller) poll(ctx context.Context) {
	key := p.key()
	if p.baseURL == "" || key == "" || p.clusterID == "" {
		p.fail("", "unconfigured", "FLEET_MANAGER_URL, the fleet caller key and SIGNAL_CLUSTER_ID are all required")
		return
	}
	recs, err := p.fetch(ctx, key)
	if err != nil {
		p.fail("", "poll", err.Error())
		return
	}
	for _, rec := range recs {
		if ctx.Err() != nil {
			return
		}
		p.handle(ctx, key, rec)
	}
}

func (p *fleetPoller) fetch(ctx context.Context, key string) ([]fleetStunRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, fleetPollTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		p.baseURL+"/api/v1/fleet/stun-state?cluster_id="+url.QueryEscape(p.clusterID), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fleet-manager answered %d", resp.StatusCode)
	}
	// Either a bare array or {"records": [...]}: the contract shows the
	// records, not the envelope.
	var recs []fleetStunRecord
	if err := json.Unmarshal(body, &recs); err != nil {
		var env struct {
			Records []fleetStunRecord `json:"records"`
		}
		if err2 := json.Unmarshal(body, &env); err2 != nil {
			return nil, fmt.Errorf("decode stun-state: %w", err)
		}
		recs = env.Records
	}
	return recs, nil
}

// handle acts on one record for a pod on this node.
func (p *fleetPoller) handle(ctx context.Context, key string, rec fleetStunRecord) {
	if rec.ClusterID != "" && rec.ClusterID != p.clusterID {
		return
	}
	pod := p.findPod(rec.Namespace, rec.Name)
	if pod == nil || (p.node != "" && pod.Spec.NodeName != p.node) {
		return // another node's pod, or not (yet) watched here
	}
	if isSentinelPod(pod) {
		p.fail(rec.ID, "refused", "record names the warden itself; never contained")
		return
	}
	switch rec.State {
	case stunStateRequested:
		if p.holds.remoteHoldID(pod.UID) == rec.ID {
			// Frozen already (an earlier ack was lost, or a restart restored
			// the hold): just ack.
			p.ack(ctx, key, rec, ackStunned, pod)
			return
		}
		if _, err := p.holds.freezeRemote(pod, rec.ID, rec.Reason); err != nil {
			p.fail(rec.ID, "freeze", err.Error())
			return
		}
		p.ack(ctx, key, rec, ackStunned, pod)
	case stunStateResume:
		if p.holds.resumeRemote(pod.UID) {
			if p.holds.notify != nil {
				p.holds.notify(pod.Namespace + "/" + pod.Name)
			}
			deadline := p.now().Add(p.resumeWait)
			for p.holds.isHeld(pod.UID) && p.now().Before(deadline) && ctx.Err() == nil {
				p.sleep(50 * time.Millisecond)
			}
			if p.holds.isHeld(pod.UID) {
				logEvent(stunEvent{Timestamp: now(), Event: "remote_resume_pending", Pod: pod.Name, Namespace: pod.Namespace,
					UID: string(pod.UID), Decision: "ack_next_poll", Details: map[string]interface{}{"stun_id": rec.ID}})
				return
			}
		}
		p.ack(ctx, key, rec, ackResumed, pod)
	default:
		p.fail(rec.ID, "unknown_state", fmt.Sprintf("record state %q", rec.State))
	}
}

func (p *fleetPoller) ack(ctx context.Context, key string, rec fleetStunRecord, state string, pod *corev1.Pod) {
	body, _ := json.Marshal(fleetAck{ID: rec.ID, State: state, Node: p.node, At: p.now().UTC().Format(time.RFC3339)})
	ctx, cancel := context.WithTimeout(ctx, fleetPollTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+"/api/v1/fleet/stun-state/ack", bytes.NewReader(body))
	if err != nil {
		p.fail(rec.ID, "ack", err.Error())
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := p.client.Do(req)
	if err != nil {
		p.fail(rec.ID, "ack_transport", err.Error())
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		p.fail(rec.ID, "ack_refused", fmt.Sprintf("fleet-manager answered %d", resp.StatusCode))
		return
	}
	p.acked.Add(1)
	logEvent(stunEvent{Timestamp: now(), Event: "remote_stun_acked", Pod: pod.Name, Namespace: pod.Namespace,
		UID: string(pod.UID), Decision: state, Details: map[string]interface{}{"stun_id": rec.ID, "status": resp.StatusCode}})
}

func (p *fleetPoller) fail(id, kind, detail string) {
	total := p.failures.Add(1)
	details := map[string]interface{}{"kind": kind, "cluster_id": p.clusterID, "node": p.node, "fleet_poll_failures_total": total}
	if id != "" {
		details["stun_id"] = id
	}
	logEvent(stunEvent{Timestamp: now(), Event: "fleet_poll_failed", Decision: "retry_next_poll", Error: detail, Details: details})
}
