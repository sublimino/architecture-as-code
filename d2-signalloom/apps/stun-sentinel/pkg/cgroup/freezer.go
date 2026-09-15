// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package cgroup implements Tier 0 containment: in-kernel execution halt of a
// compromised agent container via the cgroup-v2 freezer.
//
// # Why the freezer, and why it is not a controller
//
// In cgroup v2 the freezer is a *core* interface, not a controller. It is
// exposed as two files present on every non-root cgroup — `cgroup.freeze`
// (write "1" to freeze, "0" to thaw) and `cgroup.events` (read back a
// `frozen 0|1` line) — and it therefore requires no entry in
// `cgroup.controllers` and no `cgroup.subtree_control` enablement. Any
// preflight that greps `cgroup.controllers` for the string "freezer" will
// find nothing on a perfectly capable host; that is expected, not a fault.
//
// The root cgroup is the one exception: it cannot be frozen, so
// `/sys/fs/cgroup/cgroup.freeze` does not exist at the true hierarchy root.
//
// Freezing is enforced by the kernel scheduler rather than by signal
// delivery. A frozen task cannot observe, trap, mask, or race the transition
// the way it could a SIGSTOP, which is what makes this an execution-state
// control rather than a cooperative one.
//
// # Design rule
//
// A containment control that cannot fail cannot be trusted. Every Freeze
// either observes `frozen 1` read back from the kernel inside its deadline,
// or it returns a typed error naming which stage failed. Writing the control
// file successfully is never, on its own, treated as success.
package cgroup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/quarantine"
)

// DefaultFreezeDeadline is the hard budget for a freeze to be observed as
// settled. CRKC-P1-2 requires container processes to reach the frozen state
// in under 50ms.
const DefaultFreezeDeadline = 50 * time.Millisecond

// DefaultCgroupRoot is the conventional cgroup-v2 unified hierarchy mount.
const DefaultCgroupRoot = "/sys/fs/cgroup"

// Control file names within a cgroup-v2 directory.
const (
	freezeFile = "cgroup.freeze"
	eventsFile = "cgroup.events"
	procsFile  = "cgroup.procs"
)

// healthProbeDir is the transient cgroup created by HealthCheck to prove the
// hierarchy is genuinely writable rather than merely present.
const healthProbeDir = "stun-sentinel-healthprobe"

// maxDiscoveryDepth bounds the fallback filesystem walk so an unexpected
// layout costs a bounded search rather than a traversal of all of /sys.
const maxDiscoveryDepth = 6

// Typed errors. Callers distinguish these with errors.Is. Collapsing them
// into a single error value would make "the path is absent", "I am not
// permitted to write" and "it did not freeze in time" indistinguishable —
// three outcomes with three different operational responses.
var (
	// ErrCgroupNotFound means no cgroup directory carrying a cgroup.freeze
	// file could be resolved for the pod, or the control file is absent.
	ErrCgroupNotFound = errors.New("cgroup: freezer path not found")

	// ErrPermission means the control file exists but the process may not
	// write it — almost always a missing hostPath mount or a non-privileged
	// securityContext on the DaemonSet.
	ErrPermission = errors.New("cgroup: permission denied writing freezer control file")

	// ErrFreezeDeadline means the write succeeded but cgroup.events did not
	// report the requested state before the deadline expired.
	ErrFreezeDeadline = errors.New("cgroup: freeze deadline exceeded before frozen state observed")

	// ErrUnauthorized means a freeze or unfreeze was attempted without a governance
	// credential or with one that failed validation.
	ErrUnauthorized = errors.New("cgroup: governance credential did not validate")

	// ErrInvalidPodUID means the supplied pod UID is empty or contains a
	// path separator or traversal element.
	ErrInvalidPodUID = errors.New("cgroup: invalid pod UID")

	// ErrCgroupEmpty means the cgroup held no processes, so the freeze
	// contained nothing.
	//
	// This is the vacuous-success trap: an EMPTY cgroup reports `frozen 1`
	// immediately and unconditionally. Without this check, freezing the
	// wrong cgroup, a cgroup whose target already exited, or a cgroup the
	// target escaped from all return success in ~0ms with a perfect-looking
	// latency — the most convincing possible evidence for a containment that
	// contained nothing.
	ErrCgroupEmpty = errors.New("cgroup: no processes in cgroup, freeze contained nothing")

	// ErrAncestorFrozen means the cgroup is frozen by an ancestor, so
	// writing 0 to its own cgroup.freeze cannot thaw it.
	//
	// cgroup.events reports the EFFECTIVE frozen state, which includes a
	// freeze inherited from any ancestor, whereas cgroup.freeze holds only
	// this cgroup's own setting. When the two disagree the freeze is held
	// higher up the tree and must be released there.
	ErrAncestorFrozen = errors.New("cgroup: frozen by an ancestor cgroup, cannot be thawed here")
)

// CredentialValidator authorises a freeze or resume action.
type CredentialValidator func(credential string) bool

// DenyAllCredentials is the default validator. An operator who has not wired
// a governance check gets refusal, not silent permissiveness.
func DenyAllCredentials(string) bool { return false }

// FreezeResult records what actually happened, so callers and telemetry can
// report measured facts rather than intentions.
type FreezeResult struct {
	// PodUID is set when the freeze was reached via FreezePod.
	PodUID string `json:"pod_uid,omitempty"`
	// CgroupPath is the absolute directory whose cgroup.freeze was written.
	CgroupPath string `json:"cgroup_path"`
	// Frozen is the state read back from cgroup.events, never inferred.
	Frozen bool `json:"frozen"`
	// Populated is the cgroup.events `populated` flag observed at the same
	// read that settled the frozen state. An unpopulated cgroup freezes
	// instantly and vacuously, so this travels with the result.
	Populated bool `json:"populated"`
	// Latency is the elapsed time from the start of the write to the read
	// that first observed the requested state.
	Latency time.Duration `json:"-"`
	// LatencyMS is Latency in milliseconds, for JSON consumers.
	LatencyMS float64 `json:"latency_ms"`
	// Polls counts cgroup.events reads performed before settling.
	Polls int `json:"polls"`
	// PIDs is the process set read from cgroup.procs *after* the frozen
	// state was confirmed. Reading it post-confirmation is what closes the
	// fork race: a child created while the freeze was being asserted is
	// frozen by the kernel along with its parent and appears here.
	PIDs []int `json:"pids"`
	// Deadline is the budget this operation was given.
	Deadline time.Duration `json:"-"`
	// Quarantine holds the captured forensic snapshot if quarantine was requested.
	Quarantine *quarantine.QuarantineManifest `json:"quarantine,omitempty"`
}

// FreezeOptions allows optional configuration for a containment operation.
type FreezeOptions struct {
	// CaptureQuarantine instructs the freezer to perform forensic snapshotting immediately post-freeze.
	CaptureQuarantine bool
	// PodUID optionally passes the pod UID for forensic manifest scoping.
	PodUID string
	// PodName optionally passes the pod name for forensic manifest scoping.
	PodName string
	// Namespace optionally passes the pod namespace for forensic manifest scoping.
	Namespace string
}

// PostFreezeHook is an extension point executed immediately after a cgroup is
// confirmed frozen and its process census has settled, before Freeze returns.
//
// This hook provides Phase 4's forensic memory snapshotting (SLER-P4-2) and
// process inspection a race-free boundary: all target processes are verified
// frozen in-kernel, the PID census is settled, and the freezer has not yet
// released control back to the caller.
type PostFreezeHook func(res *FreezeResult) error

// Freezer performs cgroup-v2 freeze and thaw operations against a hierarchy
// root. The root is injected rather than fixed so the whole package is
// testable against a temporary directory without a live cluster.
type Freezer struct {
	root               string
	deadline           time.Duration
	dryRun             bool
	freezeValidator    CredentialValidator
	resumeValidator    CredentialValidator
	postFreezeHook     PostFreezeHook
	quarantineCapturer *quarantine.Capturer
}

// Option configures a Freezer.
type Option func(*Freezer)

// WithDeadline overrides DefaultFreezeDeadline.
func WithDeadline(d time.Duration) Option {
	return func(f *Freezer) {
		if d > 0 {
			f.deadline = d
		}
	}
}

// WithDryRun configures dry-run execution mode. In dry-run mode, path resolution
// and credential verification execute normally, but no writes to cgroup.freeze
// are performed.
func WithDryRun(dryRun bool) Option {
	return func(f *Freezer) {
		f.dryRun = dryRun
	}
}

// WithPostFreezeHook registers an extension point hook executed after freeze confirmation.
func WithPostFreezeHook(hook PostFreezeHook) Option {
	return func(f *Freezer) {
		f.postFreezeHook = hook
	}
}

// WithQuarantineCapturer installs a forensic quarantine snapshot engine.
func WithQuarantineCapturer(c *quarantine.Capturer) Option {
	return func(f *Freezer) {
		f.quarantineCapturer = c
	}
}

// WithFreezeCredentialValidator installs the governance check consulted by Freeze.
func WithFreezeCredentialValidator(v CredentialValidator) Option {
	return func(f *Freezer) {
		if v != nil {
			f.freezeValidator = v
		}
	}
}

// WithFreezeValidator is an alias for WithFreezeCredentialValidator.
func WithFreezeValidator(v CredentialValidator) Option {
	return WithFreezeCredentialValidator(v)
}

// WithCredentialValidator installs the governance check consulted by Unfreeze.
func WithCredentialValidator(v CredentialValidator) Option {
	return func(f *Freezer) {
		if v != nil {
			f.resumeValidator = v
		}
	}
}

// WithResumeCredentialValidator is an alias for WithCredentialValidator.
func WithResumeCredentialValidator(v CredentialValidator) Option {
	return WithCredentialValidator(v)
}

// New constructs a Freezer rooted at the given cgroup-v2 hierarchy. An empty
// root defaults to DefaultCgroupRoot.
func New(root string, opts ...Option) *Freezer {
	if root == "" {
		root = DefaultCgroupRoot
	}
	f := &Freezer{
		root:            root,
		deadline:        DefaultFreezeDeadline,
		freezeValidator: DenyAllCredentials,
		resumeValidator: DenyAllCredentials,
	}
	for _, opt := range opts {
		opt(f)
	}
	return f
}

// Root returns the configured hierarchy root.
func (f *Freezer) Root() string { return f.root }

// Deadline returns the configured freeze deadline.
func (f *Freezer) Deadline() time.Duration { return f.deadline }

// DryRun returns whether the freezer is configured in dry-run mode.
func (f *Freezer) DryRun() bool { return f.dryRun }

// ─────────────────────────────────────────────────────────────────────────────
// Discovery
// ─────────────────────────────────────────────────────────────────────────────

// normaliseUID validates a pod UID and returns its systemd-mangled form
// (dashes replaced by underscores) alongside the literal form.
func normaliseUID(podUID string) (dashed, underscored string, err error) {
	if podUID == "" {
		return "", "", fmt.Errorf("%w: empty", ErrInvalidPodUID)
	}
	if strings.ContainsAny(podUID, `/\`) || strings.Contains(podUID, "..") {
		return "", "", fmt.Errorf("%w: %q contains a path separator or traversal element", ErrInvalidPodUID, podUID)
	}
	return podUID, strings.ReplaceAll(podUID, "-", "_"), nil
}

// kubepodsRoots enumerates the parent directories under which a kubelet may
// place pod cgroups. The list is plural on purpose.
//
// The cgroup path of a pod is a function of the runtime's cgroup driver AND
// the systemd slice the kubelet itself runs in — neither of which is derivable
// from the pod UID. On a stock systemd-driver node the root is
// `kubepods.slice`; on a Kind node the kubelet runs inside a `kubelet.slice`
// unit so the root becomes `kubelet.slice/kubelet-kubepods.slice`; with the
// cgroupfs driver it is a plain `kubepods` directory. Hardcoding any one of
// them yields an implementation that is correct on exactly one cluster.
func kubepodsRoots() []struct {
	rel string // path relative to the hierarchy root
	// base is the systemd slice basename used to build child slice names,
	// or "" for the cgroupfs driver.
	base string
} {
	return []struct {
		rel  string
		base string
	}{
		// systemd driver, kubelet in its own slice (Kind, kubeadm with
		// KubeletCgroups set).
		{rel: "kubelet.slice/kubelet-kubepods.slice", base: "kubelet-kubepods"},
		// systemd driver, stock layout.
		{rel: "kubepods.slice", base: "kubepods"},
		// cgroupfs driver.
		{rel: "kubepods", base: ""},
		// cgroupfs driver nested under a kubelet directory.
		{rel: "kubelet/kubepods", base: ""},
	}
}

// candidatePaths builds the ordered matrix of directories that could hold the
// pod's cgroup: root x QoS tier x driver naming convention.
func (f *Freezer) candidatePaths(dashed, underscored string) []string {
	var out []string
	// Guaranteed pods sit directly under the kubepods root; burstable and
	// besteffort sit under a QoS child.
	qos := []string{"", "burstable", "besteffort"}

	for _, r := range kubepodsRoots() {
		rootDir := filepath.Join(f.root, filepath.FromSlash(r.rel))
		for _, q := range qos {
			if r.base != "" {
				// systemd driver: parent-child.slice mangling, pod UID
				// underscored.
				var parentDir, podName string
				if q == "" {
					parentDir = rootDir
					podName = r.base + "-pod" + underscored + ".slice"
				} else {
					parentDir = filepath.Join(rootDir, r.base+"-"+q+".slice")
					podName = r.base + "-" + q + "-pod" + underscored + ".slice"
				}
				out = append(out, filepath.Join(parentDir, podName))
				continue
			}
			// cgroupfs driver: plain nesting, pod UID dashed.
			parentDir := rootDir
			if q != "" {
				parentDir = filepath.Join(rootDir, q)
			}
			out = append(out, filepath.Join(parentDir, "pod"+dashed))
		}
	}
	return out
}

// isFreezableCgroup reports whether dir is a cgroup-v2 directory exposing the
// freezer control file. Presence of cgroup.freeze — not merely of the
// directory — is the selection criterion, because an empty directory of the
// right name proves nothing.
func isFreezableCgroup(dir string) bool {
	st, err := os.Stat(filepath.Join(dir, freezeFile))
	return err == nil && !st.IsDir()
}

// ResolvePodCgroup returns the cgroup-v2 directory holding the pod's freezer
// control file.
//
// It first tries the ordered candidate matrix, which resolves every layout
// this code knows about in a handful of stat calls. If none matches it falls
// back to a depth-bounded walk looking for a directory whose name embeds the
// pod UID in either mangled or literal form, so an unanticipated layout costs
// a slower lookup rather than an outright failure.
func (f *Freezer) ResolvePodCgroup(podUID string) (string, error) {
	dashed, underscored, err := normaliseUID(podUID)
	if err != nil {
		return "", err
	}

	for _, candidate := range f.candidatePaths(dashed, underscored) {
		if isFreezableCgroup(candidate) {
			return candidate, nil
		}
	}

	if found, err := f.walkForPod(dashed, underscored); err == nil && found != "" {
		return found, nil
	}

	if f.dryRun {
		return filepath.Join(f.root, "kubepods.slice", "kubepods-burstable-pod"+underscored+".slice"), nil
	}

	return "", fmt.Errorf("%w: pod %s under %s", ErrCgroupNotFound, podUID, f.root)
}

// podCgroupNameMatches reports whether a cgroup directory name matches the pod UID
// without falsely matching partial UIDs (such as pod<uid>-extra.slice).
func podCgroupNameMatches(name, dashed, underscored string) bool {
	for _, u := range []string{underscored, dashed} {
		idx := 0
		for {
			pos := strings.Index(name[idx:], u)
			if pos == -1 {
				break
			}
			absPos := idx + pos
			prefix := name[:absPos]
			suffix := name[absPos+len(u):]

			suffixValid := suffix == "" || strings.HasPrefix(suffix, ".")
			prefixValid := prefix == "" ||
				strings.HasSuffix(prefix, "pod") ||
				strings.HasSuffix(prefix, "pod-") ||
				strings.HasSuffix(prefix, "pod_") ||
				strings.HasSuffix(prefix, "-") ||
				strings.HasSuffix(prefix, "/")

			if prefixValid && suffixValid {
				return true
			}

			idx = absPos + len(u)
		}
	}
	return false
}

// walkForPod performs the depth-bounded fallback search.
func (f *Freezer) walkForPod(dashed, underscored string) (string, error) {
	rootDepth := strings.Count(filepath.Clean(f.root), string(os.PathSeparator))
	var match string

	err := filepath.WalkDir(f.root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// An unreadable subtree is not fatal to the search; skip it.
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if strings.Count(filepath.Clean(path), string(os.PathSeparator))-rootDepth > maxDiscoveryDepth {
			return fs.SkipDir
		}
		name := d.Name()
		if !podCgroupNameMatches(name, dashed, underscored) {
			return nil
		}
		if isFreezableCgroup(path) {
			match = path
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil && !errors.Is(err, filepath.SkipAll) {
		return "", err
	}
	if match == "" {
		return "", ErrCgroupNotFound
	}
	return match, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// State parsing
// ─────────────────────────────────────────────────────────────────────────────

// parseEventsKey extracts one "key value" flag from a cgroup.events body.
//
// The body is a sequence of "key value" lines, e.g.:
//
//	populated 1
//	frozen 0
//
// Parsing is field-exact rather than substring-based. A naive
// strings.Contains(body, "frozen 1") would also match a line reading
// "unfrozen 1", inverting the answer.
func parseEventsKey(body []byte, key string) (value bool, present bool) {
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || fields[0] != key {
			continue
		}
		return fields[1] == "1", true
	}
	return false, false
}

// parseFrozenState extracts the `frozen` flag from a cgroup.events body.
func parseFrozenState(body []byte) (frozen bool, present bool) {
	return parseEventsKey(body, "frozen")
}

// parsePopulatedState extracts the `populated` flag, which reports whether
// the subtree contains any live process.
func parsePopulatedState(body []byte) (populated bool, present bool) {
	return parseEventsKey(body, "populated")
}

// cgroupState is one observation of cgroup.events.
type cgroupState struct {
	frozen        bool
	frozenPresent bool
	populated     bool
}

// readCgroupState reads and parses cgroup.events for the given cgroup.
func readCgroupState(cgroupPath string) (cgroupState, error) {
	body, err := os.ReadFile(filepath.Join(cgroupPath, eventsFile))
	if err != nil {
		return cgroupState{}, err
	}
	frozen, present := parseFrozenState(body)
	populated, _ := parsePopulatedState(body)
	return cgroupState{frozen: frozen, frozenPresent: present, populated: populated}, nil
}

// ownFreezeSetting reads this cgroup's own cgroup.freeze value, as distinct
// from the effective state reported by cgroup.events.
func ownFreezeSetting(cgroupPath string) (string, error) {
	body, err := os.ReadFile(filepath.Join(cgroupPath, freezeFile))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(body)), nil
}

// classifyWriteErr maps a control-file write failure onto a typed error.
func classifyWriteErr(err error, cgroupPath string) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, fs.ErrNotExist):
		return fmt.Errorf("%w: %s/%s", ErrCgroupNotFound, cgroupPath, freezeFile)
	case errors.Is(err, fs.ErrPermission):
		return fmt.Errorf("%w: %s/%s", ErrPermission, cgroupPath, freezeFile)
	default:
		return fmt.Errorf("cgroup: writing %s/%s: %w", cgroupPath, freezeFile, err)
	}
}

// writeControl writes a single-byte value to the freezer control file.
func writeControl(cgroupPath, value string) error {
	path := filepath.Join(cgroupPath, freezeFile)
	// O_WRONLY without O_CREATE: the control file must already exist. If it
	// does not, this cgroup is not freezable and we want ENOENT rather than
	// a stray regular file created in its place.
	fh, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return classifyWriteErr(err, cgroupPath)
	}
	if _, err := fh.Write([]byte(value)); err != nil {
		fh.Close()
		return classifyWriteErr(err, cgroupPath)
	}
	if err := fh.Close(); err != nil {
		return classifyWriteErr(err, cgroupPath)
	}
	return nil
}

// awaitState polls cgroup.events until the frozen flag equals want or the
// deadline expires.
//
// The first read happens immediately with no sleep, because on an idle cgroup
// the transition is frequently complete before the write syscall returns and
// any fixed initial sleep would floor the measured latency at that interval.
// Subsequent polls back off geometrically from 25µs to 1ms.
func awaitState(cgroupPath string, want bool, deadline time.Duration, start time.Time) (settled bool, last cgroupState, polls int, elapsed time.Duration, err error) {
	backoff := 25 * time.Microsecond
	const maxBackoff = time.Millisecond

	for {
		state, readErr := readCgroupState(cgroupPath)
		polls++
		if readErr != nil {
			// cgroup.events vanishing mid-poll means the pod terminated
			// underneath us. That is a real outcome, not a transient.
			if errors.Is(readErr, fs.ErrNotExist) {
				return false, state, polls, time.Since(start), fmt.Errorf("%w: %s/%s disappeared during poll", ErrCgroupNotFound, cgroupPath, eventsFile)
			}
			return false, state, polls, time.Since(start), fmt.Errorf("cgroup: reading %s/%s: %w", cgroupPath, eventsFile, readErr)
		}
		if state.frozenPresent && state.frozen == want {
			return true, state, polls, time.Since(start), nil
		}
		if time.Since(start) >= deadline {
			return false, state, polls, time.Since(start), nil
		}
		time.Sleep(backoff)
		if backoff < maxBackoff {
			backoff *= 2
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Freeze / Unfreeze
// ─────────────────────────────────────────────────────────────────────────────

// Freeze halts every process in the cgroup subtree by writing "1" to
// cgroup.freeze, then proves the halt by reading `frozen 1` back from
// cgroup.events inside the configured deadline.
//
// It is gated on a governance credential. It returns ErrUnauthorized if the
// credential fails validation, and ErrFreezeDeadline if the state was not
// observed in time. It never returns nil on the strength of a successful write alone.
func (f *Freezer) Freeze(cgroupPath, credential string) (*FreezeResult, error) {
	return f.FreezeWithOptions(context.Background(), cgroupPath, credential, FreezeOptions{})
}

// FreezeWithOptions halts every process in the cgroup subtree and optionally performs
// forensic quarantine snapshotting while processes are safely frozen in-kernel.
func (f *Freezer) FreezeWithOptions(ctx context.Context, cgroupPath, credential string, opts FreezeOptions) (*FreezeResult, error) {
	res := &FreezeResult{CgroupPath: cgroupPath, Deadline: f.deadline, PodUID: opts.PodUID}

	if f.freezeValidator == nil || !f.freezeValidator(credential) {
		return res, fmt.Errorf("%w: %s", ErrUnauthorized, cgroupPath)
	}

	if f.dryRun {
		res.Frozen = true
		res.Populated = true
		res.Latency = 100 * time.Microsecond
		res.LatencyMS = 0.1
		res.Polls = 1
		res.PIDs = []int{1}
		if f.postFreezeHook != nil {
			if err := f.postFreezeHook(res); err != nil {
				return res, fmt.Errorf("cgroup: post-freeze hook: %w", err)
			}
		}
		return res, nil
	}

	start := time.Now()
	if err := writeControl(cgroupPath, "1"); err != nil {
		res.LatencyMS = msOf(time.Since(start))
		res.Latency = time.Since(start)
		return res, err
	}

	settled, state, polls, elapsed, err := awaitState(cgroupPath, true, f.deadline, start)
	res.Polls = polls
	res.Latency = elapsed
	res.LatencyMS = msOf(elapsed)
	res.Populated = state.populated
	if err != nil {
		return res, err
	}
	if !settled {
		return res, fmt.Errorf("%w: %s still reports frozen 0 after %s (deadline %s, %d polls)",
			ErrFreezeDeadline, cgroupPath, elapsed.Round(time.Microsecond), f.deadline, polls)
	}
	res.Frozen = true

	// Post-freeze process census. Reading cgroup.procs only after the frozen
	// state is confirmed is what makes the fork race safe to report on: the
	// kernel freezes the whole subtree atomically, so a child forked while
	// the freeze was being asserted is already frozen and shows up here.
	// Reading before confirmation would produce a list that is stale by
	// construction.
	pids, procErr := ListProcs(cgroupPath)
	if procErr == nil {
		res.PIDs = pids
	}

	// Emptiness gate. An empty cgroup reports `frozen 1` immediately, so
	// without this the most vacuous possible outcome — freezing a cgroup
	// with nothing in it — returns success with a flawless sub-millisecond
	// latency. The census is therefore load-bearing, not informational:
	// containment that contained no process is a failure, and the caller
	// needs to know so it can escalate rather than stand down.
	if !state.populated && len(res.PIDs) == 0 {
		return res, fmt.Errorf("%w: %s reports populated 0 and cgroup.procs is empty (frozen in %s)",
			ErrCgroupEmpty, cgroupPath, elapsed.Round(time.Microsecond))
	}

	if f.postFreezeHook != nil {
		if err := f.postFreezeHook(res); err != nil {
			return res, fmt.Errorf("cgroup: post-freeze hook: %w", err)
		}
	}

	// Optional Forensic Quarantine Capture (post-freeze execution halt confirmed).
	// Capturing while the process is confirmed frozen guarantees atomic consistency
	// of memory pages and prevents races on open file descriptors / sockets.
	if opts.CaptureQuarantine && f.quarantineCapturer != nil && len(res.PIDs) > 0 {
		target := quarantine.TargetInfo{
			PodUID:     opts.PodUID,
			PodName:    opts.PodName,
			Namespace:  opts.Namespace,
			CgroupPath: cgroupPath,
		}
		manifest, qErr := f.quarantineCapturer.Capture(ctx, target, res.PIDs)
		if manifest != nil {
			res.Quarantine = manifest
		}
		if qErr != nil && res.Quarantine == nil {
			res.Quarantine = &quarantine.QuarantineManifest{
				Version:       quarantine.ManifestVersion,
				Kind:          quarantine.ManifestKind,
				Target:        target,
				Partial:       true,
				PartialReason: "quarantine_capture_failed: " + qErr.Error(),
			}
		}
	}

	return res, nil
}

// FreezePod resolves the pod's cgroup and freezes it.
func (f *Freezer) FreezePod(podUID, credential string) (*FreezeResult, error) {
	return f.FreezePodWithOptions(context.Background(), podUID, credential, FreezeOptions{PodUID: podUID})
}

// FreezePodWithOptions resolves the pod's cgroup and freezes it with optional quarantine capture.
func (f *Freezer) FreezePodWithOptions(ctx context.Context, podUID, credential string, opts FreezeOptions) (*FreezeResult, error) {
	opts.PodUID = podUID
	path, err := f.ResolvePodCgroup(podUID)
	if err != nil {
		return &FreezeResult{PodUID: podUID, Deadline: f.deadline}, err
	}
	res, err := f.FreezeWithOptions(ctx, path, credential, opts)
	res.PodUID = podUID
	return res, err
}

// Unfreeze resumes execution by writing "0" to cgroup.freeze, and verifies
// `frozen 0` by read-back.
//
// It is gated on a governance credential. Freeze and Unfreeze are both gated on
// distinct governance credentials to prevent unauthenticated containment actions
// and unauthorized capability returns.
func (f *Freezer) Unfreeze(cgroupPath, credential string) (*FreezeResult, error) {
	res := &FreezeResult{CgroupPath: cgroupPath, Frozen: true, Deadline: f.deadline}

	if f.resumeValidator == nil || !f.resumeValidator(credential) {
		return res, fmt.Errorf("%w: %s", ErrUnauthorized, cgroupPath)
	}

	if f.dryRun {
		res.Frozen = false
		res.Populated = true
		res.Latency = 100 * time.Microsecond
		res.LatencyMS = 0.1
		res.Polls = 1
		res.PIDs = []int{1}
		return res, nil
	}

	start := time.Now()
	if err := writeControl(cgroupPath, "0"); err != nil {
		res.Latency = time.Since(start)
		res.LatencyMS = msOf(res.Latency)
		return res, err
	}

	settled, state, polls, elapsed, err := awaitState(cgroupPath, false, f.deadline, start)
	res.Polls = polls
	res.Latency = elapsed
	res.LatencyMS = msOf(elapsed)
	res.Populated = state.populated
	if err != nil {
		return res, err
	}
	if !settled {
		// Distinguish "the kernel is slow" from "this cgroup is not ours to
		// thaw". cgroup.events reports the EFFECTIVE state, which inherits a
		// freeze from any ancestor, while cgroup.freeze holds only this
		// cgroup's own setting. If our write landed (own setting is 0) and
		// the effective state is still frozen, the freeze is held higher up
		// the tree and no amount of waiting here will clear it.
		if own, ownErr := ownFreezeSetting(cgroupPath); ownErr == nil && own == "0" {
			return res, fmt.Errorf("%w: %s has cgroup.freeze=0 but cgroup.events still reports frozen 1 after %s",
				ErrAncestorFrozen, cgroupPath, elapsed.Round(time.Microsecond))
		}
		return res, fmt.Errorf("%w: %s still reports frozen 1 after %s (deadline %s, %d polls)",
			ErrFreezeDeadline, cgroupPath, elapsed.Round(time.Microsecond), f.deadline, polls)
	}
	res.Frozen = false

	// Record which processes were returned to running state. This is the
	// audit counterpart of the freeze census: an operator reviewing a resume
	// needs to know what was resumed, not merely that something was.
	if pids, procErr := ListProcs(cgroupPath); procErr == nil {
		res.PIDs = pids
	}

	return res, nil
}

// UnfreezePod resolves the pod's cgroup and thaws it.
func (f *Freezer) UnfreezePod(podUID, credential string) (*FreezeResult, error) {
	path, err := f.ResolvePodCgroup(podUID)
	if err != nil {
		return &FreezeResult{PodUID: podUID, Deadline: f.deadline}, err
	}
	res, err := f.Unfreeze(path, credential)
	res.PodUID = podUID
	return res, err
}

// ─────────────────────────────────────────────────────────────────────────────
// Process census
// ─────────────────────────────────────────────────────────────────────────────

// ListProcs returns every PID in the cgroup subtree, reading cgroup.procs
// recursively. A pod cgroup holds one child cgroup per container, so a
// non-recursive read of the pod-level file returns an empty list on most
// runtimes.
//
// The result is sorted and de-duplicated so callers and telemetry get a stable
// value.
func ListProcs(cgroupPath string) ([]int, error) {
	seen := make(map[int]struct{})

	err := filepath.WalkDir(cgroupPath, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() || d.Name() != procsFile {
			return nil
		}
		body, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		for _, line := range strings.Fields(string(body)) {
			pid, convErr := strconv.Atoi(line)
			if convErr != nil || pid <= 0 {
				continue
			}
			seen[pid] = struct{}{}
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("cgroup: listing procs under %s: %w", cgroupPath, err)
	}

	pids := make([]int, 0, len(seen))
	for pid := range seen {
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	return pids, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// Health
// ─────────────────────────────────────────────────────────────────────────────

// HealthCheck proves the daemon can actually write the host cgroup hierarchy,
// rather than merely reach it.
//
// It creates and removes a transient cgroup directory. That is the only check
// that distinguishes a correctly mounted read-write hostPath from a read-only
// one: a read-only bind mount of /sys/fs/cgroup passes every stat, every read,
// and every "does the path exist" probe, and fails only on write. The probe
// cgroup holds no processes and is removed immediately.
func (f *Freezer) HealthCheck() error {
	st, err := os.Stat(f.root)
	if err != nil {
		return fmt.Errorf("cgroup: hierarchy root %s not reachable: %w", f.root, err)
	}
	if !st.IsDir() {
		return fmt.Errorf("cgroup: hierarchy root %s is not a directory", f.root)
	}

	if f.dryRun {
		return nil
	}

	probe := filepath.Join(f.root, healthProbeDir)
	// Clear a probe left behind by a previous crashed check. rmdir on a
	// cgroup directory is how cgroups are deleted; it fails harmlessly if
	// the directory is absent.
	_ = os.Remove(probe)

	if err := os.Mkdir(probe, 0o755); err != nil {
		return fmt.Errorf("cgroup: hierarchy root %s is not writable (probe cgroup %s): %w", f.root, healthProbeDir, err)
	}
	if err := os.Remove(probe); err != nil {
		return fmt.Errorf("cgroup: probe cgroup %s created but could not be removed: %w", probe, err)
	}
	return nil
}

// msOf converts a duration to fractional milliseconds.
func msOf(d time.Duration) float64 {
	return float64(d.Nanoseconds()) / 1e6
}
