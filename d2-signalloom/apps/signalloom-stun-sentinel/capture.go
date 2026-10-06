// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

// Capture on freeze. Every freeze that takes a hold, local (eBPF detection)
// or remote (fleet-manager stun record), runs the quarantine capturer over
// the frozen cgroup's processes and writes a "warden-capture" artifact set
// under SPOOL_DIR/captures/<stun-id>/:
//
//	manifest.json                  kind: warden-capture, digests of the rest
//	step4-ebpf-observation.json    what triggered the freeze
//	step5-cgroup-freeze.txt        cgroup.events, cgroup.procs, cpu.stat
//	quarantine/                    pkg/quarantine snapshot (process memory,
//	                               fds, sockets, locks); never served
//
// Why this is NOT the eight-artifact evidence bundle of
// docs/eap/FORENSIC-BUNDLE-SPECIFICATION.md. That bundle describes one whole
// pilot run, packaged by an operator with both clusters' kubeconfigs: the
// preflight manifest (git commit, tool versions, tenant hash), Flux
// reconcile state, the registry claim row from PostgreSQL, the dashboard's
// agent card, cAdvisor samples from the kubelet, and an Ed25519 signature
// over a header that binds the seven. The warden sees none of that: it has
// the node's cgroup filesystem, /proc and the kernel events, and nothing
// else. What it can produce are analogues of exactly two of the eight
// artifacts, 5 (the observation that caused the freeze) and 6 (the kernel's
// own frozen state), so the two files here carry those names and shapes.
// They are a subordinate artifact kind an operator folds INTO a bundle,
// not a partial fill of its schema: the manifest says kind warden-capture,
// there is no bundle-header.json and no signature, and nothing here claims
// to satisfy $defs/preflightManifest or the cAdvisor proof.
//
// The set is served read-only on the health listener (health.go
// /captures/<id>); the quarantine/ subtree, which holds process memory,
// is written to disk only.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/quarantine"
	corev1 "k8s.io/api/core/v1"
)

const (
	captureKind            = "warden-capture"
	captureVersion         = "signalloom.io/v1alpha1"
	captureSubdir          = "captures"
	captureManifestFile    = "manifest.json"
	captureObservationFile = "step4-ebpf-observation.json" // analogue of bundle artifact 5
	captureFreezeFile      = "step5-cgroup-freeze.txt"     // analogue of bundle artifact 6
	captureQuarantineDir   = "quarantine"
	captureTimeout         = 5 * time.Second
	// captureFreezeConfirmWait bounds the wait for cgroup.events to report
	// `frozen 1` after cgroup.freeze was written.
	captureFreezeConfirmWait = 2 * time.Second
)

// captureIDPattern bounds a stun id to a safe directory name.
var captureIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// captureTrigger is what froze the pod.
type captureTrigger struct {
	Kind    string `json:"kind"`              // "local" (eBPF detection) or "remote" (fleet-manager record)
	StunID  string `json:"stun_id"`           // fleet-manager record id, or a local id
	Syscall string `json:"syscall,omitempty"` // local: the detection
	Target  string `json:"target,omitempty"`
	Reason  string `json:"reason,omitempty"` // remote: the record's reason
}

type captureArtifact struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type captureQuarantine struct {
	CaptureID     string `json:"capture_id,omitempty"`
	StoragePath   string `json:"storage_path,omitempty"`
	ProcessCount  int    `json:"process_count"`
	Partial       bool   `json:"partial"`
	PartialReason string `json:"partial_reason,omitempty"`
	Error         string `json:"error,omitempty"`
}

// wardenCaptureManifest is manifest.json.
type wardenCaptureManifest struct {
	Version    string            `json:"version"`
	Kind       string            `json:"kind"`
	StunID     string            `json:"stun_id"`
	Trigger    captureTrigger    `json:"trigger"`
	ClusterID  string            `json:"cluster_id,omitempty"`
	Node       string            `json:"node,omitempty"`
	Pod        capturePodRef     `json:"pod"`
	CgroupPath string            `json:"cgroup_path"`
	CapturedAt string            `json:"captured_at"`
	Artifacts  []captureArtifact `json:"artifacts"`
	Quarantine captureQuarantine `json:"quarantine"`
	// Relationship records, in the artifact itself, that this is not the
	// eight-artifact bundle (see the package comment).
	Relationship string `json:"relationship"`
}

type capturePodRef struct {
	Namespace      string `json:"namespace"`
	Name           string `json:"name"`
	UID            string `json:"uid"`
	ServiceAccount string `json:"service_account,omitempty"`
}

const captureRelationship = "subordinate to docs/eap/FORENSIC-BUNDLE-SPECIFICATION.md: analogues of artifacts 5 and 6 only; not a bundle, unsigned"

// captureWriter writes one artifact set per freeze.
type captureWriter struct {
	dir       string // SPOOL_DIR/captures
	clusterID string
	node      string
	tenantFor func(*corev1.Pod) string
	capturer  func(storageDir string) *quarantine.Capturer // per-capture, so the snapshot lands under the set
	listProcs func(cgroupPath string) ([]int, error)
	now       func() time.Time

	mu sync.Mutex // one capture at a time: the capturer is memory-bounded per run, not globally
}

func newCaptureWriter(spoolDir, clusterID, node, procRoot string) *captureWriter {
	return &captureWriter{
		dir:       filepath.Join(spoolDir, captureSubdir),
		clusterID: clusterID,
		node:      node,
		tenantFor: func(*corev1.Pod) string { return "" },
		capturer: func(storageDir string) *quarantine.Capturer {
			return quarantine.New(quarantine.CaptureConfig{StorageDir: storageDir, ProcRoot: procRoot, DumpAnonymousOnly: true})
		},
		listProcs: cgroup.ListProcs,
		now:       time.Now,
	}
}

// localStunID names a local detection's capture: no fleet-manager record
// exists at freeze time (the stun POST follows), so the id is the pod uid
// and the freeze instant.
func localStunID(uid string, at time.Time) string {
	short := uid
	if i := strings.IndexByte(uid, '-'); i > 0 {
		short = uid[:i]
	}
	return "local-" + short + "-" + strconv.FormatInt(at.UnixNano(), 10)
}

// capture writes the set for one freeze. It never returns an error to the
// freeze path: the freeze is already in the kernel, and a failed capture is
// an event, not a reason to thaw.
func (w *captureWriter) capture(ctx context.Context, pod *corev1.Pod, res *cgroup.FreezeResult, trig captureTrigger) {
	if w == nil || pod == nil || res == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	manifest, err := w.write(ctx, pod, res, trig)
	ev := stunEvent{Timestamp: now(), Event: "warden_capture_written", Pod: pod.Name, Namespace: pod.Namespace,
		UID: string(pod.UID), CgroupPath: res.CgroupPath, Decision: "artifacts_on_node",
		Details: map[string]interface{}{"stun_id": trig.StunID, "trigger": trig.Kind, "kind": captureKind}}
	if manifest != nil {
		ev.Details["path"] = filepath.Join(w.dir, trig.StunID)
		ev.Details["quarantine_partial"] = manifest.Quarantine.Partial
		ev.Details["process_count"] = manifest.Quarantine.ProcessCount
	}
	if err != nil {
		ev.Event, ev.Decision, ev.Error = "warden_capture_failed", "freeze_held_uncaptured", err.Error()
	}
	logEvent(ev)
}

func (w *captureWriter) write(ctx context.Context, pod *corev1.Pod, res *cgroup.FreezeResult, trig captureTrigger) (*wardenCaptureManifest, error) {
	if !captureIDPattern.MatchString(trig.StunID) {
		return nil, fmt.Errorf("stun id %q is not a safe capture name", trig.StunID)
	}
	dir := filepath.Join(w.dir, trig.StunID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	at := w.now().UTC()
	m := &wardenCaptureManifest{
		Version: captureVersion, Kind: captureKind, StunID: trig.StunID, Trigger: trig,
		ClusterID: w.clusterID, Node: w.node,
		Pod:        capturePodRef{Namespace: pod.Namespace, Name: pod.Name, UID: string(pod.UID), ServiceAccount: pod.Spec.ServiceAccountName},
		CgroupPath: res.CgroupPath, CapturedAt: at.Format(time.RFC3339Nano), Relationship: captureRelationship,
	}

	// Artifact 5 analogue: the observation, in the normalised shape.
	obs := map[string]interface{}{
		"timestamp": at.Format(time.RFC3339Nano), "actor_id": pod.Spec.ServiceAccountName, "pod_name": pod.Name,
		"namespace": pod.Namespace, "tenant_id": w.tenantFor(pod), "cgroup_path": res.CgroupPath,
		"direct_reaction": "cgroup_frozen", "trigger": trig.Kind, "stun_id": trig.StunID, "source": "signalloom-warden",
	}
	if trig.Kind == "remote" {
		obs["syscall"], obs["target"], obs["reason"], obs["severity"] = "remote_stun", "fleet-manager", trig.Reason, "CRITICAL"
	} else {
		obs["syscall"], obs["target"], obs["severity"] = trig.Syscall, trig.Target, "CRITICAL"
	}
	obsBytes, err := json.MarshalIndent(obs, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := w.artifact(m, dir, captureObservationFile, obsBytes); err != nil {
		return nil, err
	}

	// Artifact 6 analogue: the kernel's own state, verbatim where it exists.
	pids := res.PIDs
	if len(pids) == 0 && w.listProcs != nil {
		pids, _ = w.listProcs(res.CgroupPath)
	}
	// cgroup.freeze is written synchronously but the kernel flips the `frozen`
	// line of cgroup.events only once every task has stopped, so a capture
	// taken immediately after the write can read `frozen 0` or a half-written
	// file. Wait, bounded, for the kernel's own confirmation before rendering
	// the artifact; the artifact says so if the confirmation never came.
	confirmed := waitKernelFrozen(res.CgroupPath, captureFreezeConfirmWait)
	if err := w.artifact(m, dir, captureFreezeFile, w.freezeText(res.CgroupPath, pids, at, confirmed)); err != nil {
		return nil, err
	}

	// The process snapshot, while every process is confirmed frozen.
	q := captureQuarantine{ProcessCount: len(pids)}
	if w.capturer != nil {
		cctx, cancel := context.WithTimeout(ctx, captureTimeout)
		snap, qerr := w.capturer(filepath.Join(dir, captureQuarantineDir)).Capture(cctx,
			quarantine.TargetInfo{PodUID: string(pod.UID), PodName: pod.Name, Namespace: pod.Namespace, CgroupPath: res.CgroupPath}, pids)
		cancel()
		if snap != nil {
			q.CaptureID, q.StoragePath, q.Partial, q.PartialReason = snap.CaptureID, snap.StoragePath, snap.Partial, snap.PartialReason
			q.ProcessCount = snap.Summary.ProcessCount
		}
		if qerr != nil {
			q.Partial, q.Error = true, qerr.Error()
		}
	}
	m.Quarantine = q

	body, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	return m, writeFileAtomic(filepath.Join(dir, captureManifestFile), body)
}

func (w *captureWriter) artifact(m *wardenCaptureManifest, dir, name string, body []byte) error {
	if err := writeFileAtomic(filepath.Join(dir, name), body); err != nil {
		return err
	}
	sum := sha256.Sum256(body)
	m.Artifacts = append(m.Artifacts, captureArtifact{Name: name, SHA256: hex.EncodeToString(sum[:]), Bytes: int64(len(body))})
	return nil
}

// freezeText renders the cgroup state as artifact 6 does: the cgroup.events
// lines verbatim (the `frozen 1` line is the proof), the pids, cpu.stat.
func (w *captureWriter) freezeText(cgroupPath string, pids []int, at time.Time, confirmed bool) []byte {
	var b strings.Builder
	fmt.Fprintf(&b, "captured_at: %s\n", at.Format(time.RFC3339Nano))
	fmt.Fprintf(&b, "cgroup_path: %s\n", cgroupPath)
	if !confirmed {
		fmt.Fprintf(&b, "# kernel_frozen_confirmed: false (cgroup.events did not report frozen 1 within %s)\n", captureFreezeConfirmWait)
	}
	for _, f := range []string{"cgroup.events", "cpu.stat"} {
		body, err := os.ReadFile(filepath.Join(cgroupPath, f))
		if err != nil {
			fmt.Fprintf(&b, "# %s: %v\n", f, err)
			continue
		}
		fmt.Fprintf(&b, "# %s\n%s", f, strings.TrimRight(string(body), "\n")+"\n")
	}
	sorted := append([]int(nil), pids...)
	sort.Ints(sorted)
	parts := make([]string, len(sorted))
	for i, p := range sorted {
		parts[i] = strconv.Itoa(p)
	}
	fmt.Fprintf(&b, "cgroup.procs: %s\n", strings.Join(parts, " "))
	return []byte(b.String())
}

func writeFileAtomic(path string, body []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// servedArtifacts are the files /captures/<id>/<name> may return: the
// manifest and the two spec analogues. The quarantine snapshot is not.
var servedArtifacts = map[string]string{
	captureManifestFile:    "application/json",
	captureObservationFile: "application/json",
	captureFreezeFile:      "text/plain; charset=utf-8",
}

// ids lists capture ids on disk, newest directory name last.
func (w *captureWriter) ids() ([]string, error) {
	entries, err := os.ReadDir(w.dir)
	if errors.Is(err, os.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	ids := []string{}
	for _, e := range entries {
		if e.IsDir() && captureIDPattern.MatchString(e.Name()) {
			ids = append(ids, e.Name())
		}
	}
	sort.Strings(ids)
	return ids, nil
}

// open returns an artifact of a capture by id, refusing anything outside
// the served set or the id pattern (no traversal, no quarantine dumps).
func (w *captureWriter) open(id, name string) ([]byte, string, error) {
	if !captureIDPattern.MatchString(id) {
		return nil, "", os.ErrNotExist
	}
	ctype, ok := servedArtifacts[name]
	if !ok {
		return nil, "", os.ErrNotExist
	}
	body, err := os.ReadFile(filepath.Join(w.dir, id, name))
	if err != nil {
		return nil, "", err
	}
	return body, ctype, nil
}

// waitKernelFrozen polls cgroup.events until it reports `frozen 1` or the
// bound passes. It returns whether the kernel confirmed the freeze.
func waitKernelFrozen(cgroupPath string, bound time.Duration) bool {
	deadline := time.Now().Add(bound)
	for {
		if frozen, err := readKernelFrozen(cgroupPath); err == nil && frozen {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}
