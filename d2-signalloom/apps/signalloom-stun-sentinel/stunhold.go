// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Correlator freeze hold (Step 5). The eBPF correlator freezes a pod's cgroup
// the moment it sees a sensitive syscall, but leaves no stun record, so the
// next informer resync read the frozen cgroup as drift and thawed it (measured
// live: ~14 s).
//
// A correlator freeze now takes an in-process hold on the pod UID BEFORE it
// freezes, under the same mutex the reconciler takes before any thaw. No API
// object can change a hold. It is released only by an authorised resume:
//
//  1. the pod has been seen stunned (labels or owner record: the stun was
//     recorded by whoever records stuns), the hold is then "adopted"; and
//  2. the pod is then affirmatively resumed (signalloom.io/stunned=false or a
//     non-stunned signalloom.ai/state, as fleet-manager Recover writes),
//     confirmed against the API server, not the informer cache.
//
// Labels that are merely absent or removed never release a hold, so a forged
// or stale "resumed" pod cannot thaw a freeze nobody recorded. A detection
// that lands after a release decision wins. The hold dies with the process:
// persistence across a restart is the stun record's job.

import (
	"fmt"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
)

type stunHold struct {
	reason  string
	at      time.Time
	adopted bool   // the pod has been seen stunned since the freeze
	gen     uint64 // bumped by every correlator freeze
}

type holdVerdict int

const (
	verdictNone    holdVerdict = iota // no hold: the legacy release path applies
	verdictKeep                       // stay frozen
	verdictRelease                    // authorised resume confirmed: thaw
)

type stunHolds struct {
	freezer *cgroupFreezer
	// getPod reads the pod from the API server; nil means a release can
	// never be confirmed, so a held pod stays frozen.
	getPod func(namespace, name string) (*corev1.Pod, error)
	notify func(key string) // enqueues the pod on the controller after a freeze
	// recordStun hands a NEW hold to the stun recorder (fleet-manager); it
	// runs on its own goroutine so the ring-buffer loop never waits on HTTP.
	recordStun func(pod *corev1.Pod, reason string)
	now        func() time.Time

	mu   sync.Mutex
	held map[types.UID]*stunHold
}

func newStunHolds(freezer *cgroupFreezer) *stunHolds {
	return &stunHolds{freezer: freezer, now: time.Now, held: map[types.UID]*stunHold{}}
}

// freezeFor is the correlator's freeze: hold, then freeze, under the thaw lock.
func (s *stunHolds) freezeFor(pod *corev1.Pod, syscall, target string) error {
	s.mu.Lock()
	h, existed := s.held[pod.UID]
	if !existed {
		h = &stunHold{reason: syscall + " " + target, at: s.now().UTC()}
		s.held[pod.UID] = h
	}
	h.gen++
	_, err := s.freezer.engine.FreezePod(string(pod.UID), s.freezer.freezeToken)
	if err != nil && !existed {
		delete(s.held, pod.UID)
	}
	s.mu.Unlock()
	if err != nil {
		return err
	}
	logEvent(stunEvent{Timestamp: now(), Event: "correlator_freeze_held", Pod: pod.Name, Namespace: pod.Namespace,
		UID: string(pod.UID), Decision: "hold_until_authorised_resume", Details: map[string]interface{}{"reason": h.reason}})
	if s.notify != nil {
		s.notify(pod.Namespace + "/" + pod.Name)
	}
	if !existed && s.recordStun != nil {
		go s.recordStun(pod.DeepCopy(), stunReasonFor(syscall, target))
	}
	return nil
}

// awaitingRecord reports whether pod still has a hold nobody has recorded:
// the condition under which a failed stun delivery is worth retrying.
func (s *stunHolds) awaitingRecord(pod *corev1.Pod) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	h, ok := s.held[pod.UID]
	return ok && !h.adopted
}

// observeStunned adopts a hold once the pod is seen stunned: from here an
// affirmative resume may release it.
func (s *stunHolds) observeStunned(pod *corev1.Pod) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if h, ok := s.held[pod.UID]; ok {
		h.adopted = true
	}
}

// isAffirmativeRelease: a resume was written, not just stun labels removed.
func isAffirmativeRelease(pod *corev1.Pod) bool {
	if isPodStunned(pod, nil) {
		return false
	}
	state := pod.Labels[labelStunnedAI]
	return pod.Labels[labelStunnedIO] == "false" || (state != "" && state != stunnedValue)
}

// decide is called for a pod that is not stunned (labels and owner record).
func (s *stunHolds) decide(pod *corev1.Pod) (holdVerdict, uint64, error) {
	if s == nil {
		return verdictNone, 0, nil
	}
	s.mu.Lock()
	h, held := s.held[pod.UID]
	var hold stunHold
	if held {
		hold = *h
	}
	s.mu.Unlock()
	if !held {
		return verdictNone, 0, nil
	}
	if !hold.adopted {
		// Nothing on the pod can release a freeze no one has recorded.
		s.refused(pod, hold, "unrecorded")
		return verdictKeep, 0, nil
	}
	if s.getPod == nil {
		s.refused(pod, hold, "release_unconfirmable")
		return verdictKeep, 0, nil
	}
	// The informer cache may lag the stun record; ask the API server.
	live, err := s.getPod(pod.Namespace, pod.Name)
	if err != nil {
		return verdictKeep, 0, fmt.Errorf("confirm release of held pod: %w", err)
	}
	if live.UID != pod.UID || !isAffirmativeRelease(live) {
		s.refused(pod, hold, "no_affirmative_resume")
		return verdictKeep, 0, nil
	}
	return verdictRelease, hold.gen, nil
}

func (s *stunHolds) refused(pod *corev1.Pod, h stunHold, why string) {
	logEvent(stunEvent{Timestamp: now(), Event: "thaw_refused_correlator_hold", Pod: pod.Name, Namespace: pod.Namespace,
		UID: string(pod.UID), Decision: why, Details: map[string]interface{}{
			"reason": h.reason, "held_since": h.at.Format(time.RFC3339), "adopted": h.adopted}})
}

// thaw runs unfreeze unless a hold forbids it. A release verdict carries the
// hold generation it confirmed; a correlator freeze since then wins.
func (s *stunHolds) thaw(uid types.UID, release bool, gen uint64, unfreeze func() error) (bool, error) {
	if s == nil {
		return true, unfreeze()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if h, held := s.held[uid]; held {
		if !release || h.gen != gen {
			return false, nil
		}
		delete(s.held, uid)
	}
	return true, unfreeze()
}
