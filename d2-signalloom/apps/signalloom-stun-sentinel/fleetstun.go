// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Fleet stun client (Step 5). A correlator freeze is only half a stun: the
// kernel is frozen, but nothing records it, pins Flux off, or revokes the
// agent's credentials. fleet-manager's stun cascade does all three and is the
// one writer of kustomize.toolkit.fluxcd.io/reconcile=disabled, so the
// sentinel hands it every new correlator freeze:
//
//	POST {FLEET_MANAGER_URL}/api/v1/fleet/stun/{pod}
//	Authorization: Bearer {FLEET_MANAGER_STUN_KEY}   (Secret, via env)
//	{"reason":"stun-sentinel detection: <syscall> <target>"}
//
// It runs off the ring-buffer goroutine, once per hold, and retries transient
// failures (network, 5xx) while the hold stands. A refusal (401/403/404/400) is
// a configuration fault that retrying cannot fix. Every failure is logged and
// counted, and the kernel freeze is held throughout by stunholds: the stun
// record is what this call adds, not what keeps the pod frozen.

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
	"unicode"

	corev1 "k8s.io/api/core/v1"
)

const (
	fleetStunTimeout     = 10 * time.Second
	fleetStunMaxAttempts = 6
	fleetStunMaxReason   = 256 // fleet-manager's MaxStunReasonRunes
)

type fleetStunner struct {
	baseURL string
	key     string
	client  *http.Client
	backoff func(attempt int) time.Duration
	// stillHeld reports whether the hold that asked for this stun still
	// stands; a resumed or re-created pod stops the retries.
	stillHeld func(*corev1.Pod) bool

	failures  atomic.Int64
	delivered atomic.Int64
}

func newFleetStunner(baseURL, key string) *fleetStunner {
	return &fleetStunner{
		baseURL: strings.TrimRight(baseURL, "/"),
		key:     key,
		client:  &http.Client{Timeout: fleetStunTimeout},
		backoff: func(attempt int) time.Duration { return time.Duration(1<<attempt) * time.Second },
	}
}

// stunReasonFor renders the wire reason. fleet-manager REJECTS a non-printable
// or over-long reason rather than sanitising it, and the target path is chosen
// by the workload, so it is made printable and bounded here.
func stunReasonFor(syscall, target string) string {
	var b strings.Builder
	n := 0
	for _, r := range strings.TrimSpace("stun-sentinel detection: " + syscall + " " + target) {
		if n == fleetStunMaxReason {
			break
		}
		if !unicode.IsPrint(r) {
			r = '?'
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

// stun delivers one stun for pod, retrying transient failures. It blocks; the
// caller runs it on its own goroutine.
func (f *fleetStunner) stun(pod *corev1.Pod, reason string) {
	if f == nil {
		return
	}
	if f.baseURL == "" || f.key == "" {
		f.fail(pod, 0, "unconfigured", "FLEET_MANAGER_URL and FLEET_MANAGER_STUN_KEY are both required; the freeze is held but not recorded")
		return
	}
	body, _ := json.Marshal(map[string]string{"reason": reason})
	for attempt := 0; attempt < fleetStunMaxAttempts; attempt++ {
		if attempt > 0 {
			time.Sleep(f.backoff(attempt))
			if f.stillHeld != nil && !f.stillHeld(pod) {
				return
			}
		}
		status, err := f.post(pod, body)
		switch {
		case err != nil:
			f.fail(pod, attempt, "transport", err.Error())
			continue
		case status == http.StatusOK || status == http.StatusMultiStatus:
			f.delivered.Add(1)
			logEvent(stunEvent{Timestamp: now(), Event: "fleet_stun_delivered", Pod: pod.Name, Namespace: pod.Namespace,
				UID: string(pod.UID), Decision: map[bool]string{true: "contained", false: "partial"}[status == http.StatusOK],
				Details: map[string]interface{}{"status": status, "reason": reason, "attempt": attempt + 1}})
			return
		case status >= 500:
			f.fail(pod, attempt, "server", fmt.Sprintf("fleet-manager answered %d", status))
			continue
		default:
			f.fail(pod, attempt, "refused", fmt.Sprintf("fleet-manager answered %d; not retried", status))
			return
		}
	}
	f.fail(pod, fleetStunMaxAttempts-1, "exhausted", fmt.Sprintf("gave up after %d attempts", fleetStunMaxAttempts))
}

func (f *fleetStunner) post(pod *corev1.Pod, body []byte) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), fleetStunTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		f.baseURL+"/api/v1/fleet/stun/"+url.PathEscape(pod.Name), bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+f.key)
	resp, err := f.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, nil
}

func (f *fleetStunner) fail(pod *corev1.Pod, attempt int, kind, detail string) {
	total := f.failures.Add(1)
	logEvent(stunEvent{Timestamp: now(), Event: "fleet_stun_failed", Pod: pod.Name, Namespace: pod.Namespace,
		UID: string(pod.UID), Decision: "freeze_held_unrecorded", Error: detail,
		Details: map[string]interface{}{"kind": kind, "attempt": attempt + 1, "fleet_stun_failures_total": total}})
}
