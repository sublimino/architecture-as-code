// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package cgroup

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// ─────────────────────────────────────────────────────────────────────────────
// Mock cgroupfs
//
// Every test in this file runs against a temp directory shaped like a
// cgroup-v2 hierarchy. Nothing here needs a cluster, a kernel feature, or
// root. The one behaviour a temp directory cannot reproduce is the kernel
// flipping `frozen 0` to `frozen 1` in response to a write, so the mock
// provides that transition explicitly — which is precisely what lets us test
// the "it never froze" path that a real kernel makes hard to produce on
// demand.
// ─────────────────────────────────────────────────────────────────────────────

// mockCgroup creates a cgroup directory with the given events body and,
// optionally, a cgroup.freeze control file.
func mockCgroup(t *testing.T, dir, eventsBody string, withFreezeFile bool) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	if withFreezeFile {
		if err := os.WriteFile(filepath.Join(dir, freezeFile), []byte("0"), 0o644); err != nil {
			t.Fatalf("write cgroup.freeze: %v", err)
		}
	}
	if eventsBody != "" {
		if err := os.WriteFile(filepath.Join(dir, eventsFile), []byte(eventsBody), 0o644); err != nil {
			t.Fatalf("write cgroup.events: %v", err)
		}
	}
	return dir
}

// freezableCgroup is the common case: a cgroup that reports frozen 0 and can
// be written.
func freezableCgroup(t *testing.T, dir string) string {
	t.Helper()
	return mockCgroup(t, dir, "populated 1\nfrozen 0\n", true)
}

// settleAfter rewrites cgroup.events to report `frozen <want>` after the
// given delay, standing in for the kernel completing the transition.
func settleAfter(t *testing.T, dir string, want bool, delay time.Duration) {
	t.Helper()
	state := "0"
	if want {
		state = "1"
	}
	go func() {
		time.Sleep(delay)
		_ = os.WriteFile(filepath.Join(dir, eventsFile), []byte("populated 1\nfrozen "+state+"\n"), 0o644)
	}()
}

func readFreezeControl(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, freezeFile))
	if err != nil {
		t.Fatalf("read cgroup.freeze: %v", err)
	}
	return string(b)
}

func allowCredential(want string) CredentialValidator {
	return func(got string) bool { return got == want && got != "" }
}

// ─────────────────────────────────────────────────────────────────────────────
// Construction (ISC-3, ISC-16)
// ─────────────────────────────────────────────────────────────────────────────

func TestNewDefaultsRootAndDeadline(t *testing.T) {
	f := New("")
	if f.Root() != DefaultCgroupRoot {
		t.Errorf("Root() = %q, want %q", f.Root(), DefaultCgroupRoot)
	}
	if f.Deadline() != DefaultFreezeDeadline {
		t.Errorf("Deadline() = %v, want %v", f.Deadline(), DefaultFreezeDeadline)
	}
}

// ISC-16: the deadline required by the card is 50ms.
func TestDefaultFreezeDeadlineIsFiftyMilliseconds(t *testing.T) {
	if DefaultFreezeDeadline != 50*time.Millisecond {
		t.Fatalf("DefaultFreezeDeadline = %v, want 50ms", DefaultFreezeDeadline)
	}
}

// ISC-3: the root is injectable, not a package constant baked into the paths.
func TestNewAcceptsInjectedRoot(t *testing.T) {
	dir := t.TempDir()
	f := New(dir, WithDeadline(7*time.Millisecond))
	if f.Root() != dir {
		t.Errorf("Root() = %q, want %q", f.Root(), dir)
	}
	if f.Deadline() != 7*time.Millisecond {
		t.Errorf("Deadline() = %v, want 7ms", f.Deadline())
	}
}

func TestOptionsIgnoreZeroAndNilValues(t *testing.T) {
	f := New(t.TempDir(), WithDeadline(0), WithCredentialValidator(nil))
	if f.Deadline() != DefaultFreezeDeadline {
		t.Errorf("zero deadline overrode default: %v", f.Deadline())
	}
	if f.validator == nil {
		t.Fatal("nil validator overrode the deny-all default")
	}
	if f.validator("anything") {
		t.Error("default validator permitted a credential; want deny-all")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// UID normalisation (ISC-9)
// ─────────────────────────────────────────────────────────────────────────────

func TestNormaliseUIDMangling(t *testing.T) {
	dashed, underscored, err := normaliseUID("e4fc67c7-054b-4934-bfdd-d13b6390e2c3")
	if err != nil {
		t.Fatalf("normaliseUID: %v", err)
	}
	if dashed != "e4fc67c7-054b-4934-bfdd-d13b6390e2c3" {
		t.Errorf("dashed = %q", dashed)
	}
	if underscored != "e4fc67c7_054b_4934_bfdd_d13b6390e2c3" {
		t.Errorf("underscored = %q", underscored)
	}
}

func TestNormaliseUIDRejectsBadInput(t *testing.T) {
	for _, uid := range []string{"", "../escape", "a/b", `a\b`, "..", "pod/../../etc"} {
		if _, _, err := normaliseUID(uid); !errors.Is(err, ErrInvalidPodUID) {
			t.Errorf("normaliseUID(%q) error = %v, want ErrInvalidPodUID", uid, err)
		}
	}
}

// ISC-9: a traversal attempt must not reach outside the hierarchy root.
func TestResolvePodCgroupRejectsTraversal(t *testing.T) {
	f := New(t.TempDir())
	if _, err := f.ResolvePodCgroup("../../../../sys/fs/cgroup"); !errors.Is(err, ErrInvalidPodUID) {
		t.Fatalf("error = %v, want ErrInvalidPodUID", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Discovery (ISC-4..8)
// ─────────────────────────────────────────────────────────────────────────────

const testUID = "e4fc67c7-054b-4934-bfdd-d13b6390e2c3"
const testUIDUnderscored = "e4fc67c7_054b_4934_bfdd_d13b6390e2c3"

func TestResolvePodCgroupAcrossDriverLayouts(t *testing.T) {
	cases := []struct {
		name string
		// rel is the layout-specific path, relative to the hierarchy root.
		rel string
		isc string
	}{
		{
			name: "systemd_stock_besteffort",
			rel:  "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod" + testUIDUnderscored + ".slice",
			isc:  "ISC-4",
		},
		{
			name: "systemd_stock_burstable",
			rel:  "kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod" + testUIDUnderscored + ".slice",
			isc:  "ISC-7",
		},
		{
			name: "systemd_stock_guaranteed",
			rel:  "kubepods.slice/kubepods-pod" + testUIDUnderscored + ".slice",
			isc:  "ISC-7",
		},
		{
			name: "kind_kubelet_slice_besteffort",
			rel: "kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-besteffort.slice/" +
				"kubelet-kubepods-besteffort-pod" + testUIDUnderscored + ".slice",
			isc: "ISC-6",
		},
		{
			name: "kind_kubelet_slice_burstable",
			rel: "kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-burstable.slice/" +
				"kubelet-kubepods-burstable-pod" + testUIDUnderscored + ".slice",
			isc: "ISC-6",
		},
		{
			name: "kind_kubelet_slice_guaranteed",
			rel:  "kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-pod" + testUIDUnderscored + ".slice",
			isc:  "ISC-6",
		},
		{
			name: "cgroupfs_besteffort",
			rel:  "kubepods/besteffort/pod" + testUID,
			isc:  "ISC-5",
		},
		{
			name: "cgroupfs_burstable",
			rel:  "kubepods/burstable/pod" + testUID,
			isc:  "ISC-5",
		},
		{
			name: "cgroupfs_guaranteed",
			rel:  "kubepods/pod" + testUID,
			isc:  "ISC-5",
		},
		{
			name: "cgroupfs_nested_under_kubelet",
			rel:  "kubelet/kubepods/besteffort/pod" + testUID,
			isc:  "ISC-5",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			want := freezableCgroup(t, filepath.Join(root, filepath.FromSlash(tc.rel)))

			got, err := New(root).ResolvePodCgroup(testUID)
			if err != nil {
				t.Fatalf("%s ResolvePodCgroup: %v", tc.isc, err)
			}
			if got != want {
				t.Errorf("%s ResolvePodCgroup() = %q, want %q", tc.isc, got, want)
			}
		})
	}
}

// ISC-8: absence returns a typed error, not a bare one and not an empty string.
func TestResolvePodCgroupNotFoundIsTyped(t *testing.T) {
	root := t.TempDir()
	// A plausible-looking but unrelated pod, to prove we do not match loosely.
	freezableCgroup(t, filepath.Join(root, "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-podffffffff_0000_0000_0000_000000000000.slice"))

	path, err := New(root).ResolvePodCgroup(testUID)
	if !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
	if path != "" {
		t.Errorf("path = %q on failure, want empty", path)
	}
}

// A directory of the right name without a cgroup.freeze file is not a
// freezable cgroup. Selecting on the directory alone would resolve to a path
// that then fails at write time with a much less useful error.
func TestResolvePodCgroupRequiresFreezeControlFile(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod"+testUIDUnderscored+".slice")
	mockCgroup(t, dir, "populated 1\nfrozen 0\n", false) // no cgroup.freeze

	if _, err := New(root).ResolvePodCgroup(testUID); !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound for a directory lacking cgroup.freeze", err)
	}
}

// The fallback walk covers layouts the candidate matrix does not predict.
func TestResolvePodCgroupFallbackWalkFindsUnknownLayout(t *testing.T) {
	root := t.TempDir()
	want := freezableCgroup(t, filepath.Join(root, "some-vendor.slice/nested/pod"+testUIDUnderscored+".scope"))

	got, err := New(root).ResolvePodCgroup(testUID)
	if err != nil {
		t.Fatalf("ResolvePodCgroup: %v", err)
	}
	if got != want {
		t.Errorf("ResolvePodCgroup() = %q, want %q", got, want)
	}
}

func TestResolvePodCgroupFallbackWalkIsDepthBounded(t *testing.T) {
	root := t.TempDir()
	deep := root
	for i := 0; i <= maxDiscoveryDepth+2; i++ {
		deep = filepath.Join(deep, "d")
	}
	freezableCgroup(t, filepath.Join(deep, "pod"+testUIDUnderscored))

	if _, err := New(root).ResolvePodCgroup(testUID); !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v; a cgroup beyond maxDiscoveryDepth should not be found", err)
	}
}

// The candidate matrix must be consulted before the walk: it is the fast path
// and it is deterministic.
func TestCandidatePathsCoversEveryKnownLayout(t *testing.T) {
	f := New("/root")
	got := f.candidatePaths(testUID, testUIDUnderscored)
	if len(got) != len(kubepodsRoots())*3 {
		t.Fatalf("candidatePaths returned %d entries, want %d (roots x 3 QoS tiers)", len(got), len(kubepodsRoots())*3)
	}
	for _, p := range got {
		if !strings.HasPrefix(p, "/root/") {
			t.Errorf("candidate %q escaped the injected root", p)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// cgroup.events parsing (ISC-17, ISC-18)
// ─────────────────────────────────────────────────────────────────────────────

func TestParseFrozenState(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		wantFrozen  bool
		wantPresent bool
	}{
		{"frozen_one", "populated 1\nfrozen 1\n", true, true},
		{"frozen_zero", "populated 1\nfrozen 0\n", false, true},
		{"frozen_first_line", "frozen 1\npopulated 1\n", true, true},
		{"no_trailing_newline", "populated 1\nfrozen 1", true, true},
		{"extra_keys", "populated 1\nfrozen 1\nkill 0\n", true, true},
		{"absent", "populated 1\n", false, false},
		{"empty", "", false, false},
		// ISC-18: substring traps. A strings.Contains(body, "frozen 1")
		// implementation returns true for every one of these.
		{"unfrozen_one", "populated 1\nunfrozen 1\n", false, false},
		{"unfrozen_and_frozen_zero", "unfrozen 1\nfrozen 0\n", false, true},
		{"prefixed_key", "notfrozen 1\n", false, false},
		{"value_not_exactly_one", "frozen 10\n", false, true},
		{"too_many_fields", "frozen 1 extra\n", false, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frozen, present := parseFrozenState([]byte(tc.body))
			if frozen != tc.wantFrozen || present != tc.wantPresent {
				t.Errorf("parseFrozenState(%q) = (%v, %v), want (%v, %v)",
					tc.body, frozen, present, tc.wantFrozen, tc.wantPresent)
			}
		})
	}
}

func TestReadCgroupStateMissingFile(t *testing.T) {
	_, err := readCgroupState(t.TempDir())
	if err == nil {
		t.Fatal("readCgroupState on a directory without cgroup.events returned nil error")
	}
}

func TestParsePopulatedState(t *testing.T) {
	cases := []struct {
		body            string
		want, wantFound bool
	}{
		{"populated 1\nfrozen 0\n", true, true},
		{"populated 0\nfrozen 1\n", false, true},
		{"frozen 1\n", false, false},
		{"unpopulated 1\n", false, false},
	}
	for _, tc := range cases {
		got, found := parsePopulatedState([]byte(tc.body))
		if got != tc.want || found != tc.wantFound {
			t.Errorf("parsePopulatedState(%q) = (%v,%v), want (%v,%v)", tc.body, got, found, tc.want, tc.wantFound)
		}
	}
}

func TestOwnFreezeSettingReadsTheControlFileNotEvents(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	// cgroup.freeze says 0 while cgroup.events says frozen 1 — the exact
	// signature of an ancestor-held freeze.
	if err := os.WriteFile(filepath.Join(dir, freezeFile), []byte("0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ownFreezeSetting(dir)
	if err != nil {
		t.Fatalf("ownFreezeSetting: %v", err)
	}
	if got != "0" {
		t.Errorf("ownFreezeSetting() = %q, want \"0\" (trimmed)", got)
	}
	if _, err := ownFreezeSetting(t.TempDir()); err == nil {
		t.Error("ownFreezeSetting on a directory without cgroup.freeze returned nil error")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// The vacuous-freeze trap (ErrCgroupEmpty)
// ─────────────────────────────────────────────────────────────────────────────

// An EMPTY cgroup reports `frozen 1` immediately and unconditionally. Freezing
// the wrong cgroup, or one whose target already exited, therefore produces the
// most convincing possible evidence — instant success, flawless latency — for
// a containment that contained nothing.
func TestFreezeRefusesToClaimSuccessOnAnEmptyCgroup(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 0\nfrozen 1\n", true)

	res, err := New("").Freeze(dir)
	if !errors.Is(err, ErrCgroupEmpty) {
		t.Fatalf("error = %v, want ErrCgroupEmpty", err)
	}
	// The kernel really did report frozen; we are not disputing that. What
	// we refuse to do is call it containment.
	if !res.Frozen {
		t.Error("Frozen = false; the state was genuinely observed and should be reported")
	}
	if res.Populated {
		t.Error("Populated = true on a cgroup reporting populated 0")
	}
}

func TestFreezeSucceedsWhenPopulatedFlagIsSetEvenIfProcsUnreadable(t *testing.T) {
	// populated 1 alone is sufficient: the cgroup holds processes even if we
	// cannot enumerate them.
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	res, err := New("").Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if !res.Populated {
		t.Error("Populated = false despite populated 1")
	}
}

// A cgroup whose events file omits `populated` but which demonstrably holds
// PIDs must not be rejected — the census is the fallback evidence.
func TestFreezeAcceptsCgroupWithPIDsButNoPopulatedFlag(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "frozen 1\n", true)
	if err := os.WriteFile(filepath.Join(dir, procsFile), []byte("4242\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := New("").Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if len(res.PIDs) != 1 {
		t.Errorf("PIDs = %v, want one entry", res.PIDs)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Ancestor-held freeze (ErrAncestorFrozen)
// ─────────────────────────────────────────────────────────────────────────────

// cgroup.events reports the EFFECTIVE frozen state, inheriting a freeze from
// any ancestor; cgroup.freeze holds only this cgroup's own setting. When our
// write lands but the effective state stays frozen, the freeze is held higher
// up the tree — waiting longer cannot help, and reporting a generic timeout
// would send an operator to the wrong place.
func TestUnfreezeReportsAncestorHeldFreeze(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	f := New("", WithDeadline(20*time.Millisecond), WithCredentialValidator(allowCredential("t")))

	res, err := f.Unfreeze(dir, "t")
	if !errors.Is(err, ErrAncestorFrozen) {
		t.Fatalf("error = %v, want ErrAncestorFrozen", err)
	}
	// It must NOT be reported as a plain deadline: the operational response
	// is different (release the ancestor, not retry).
	if errors.Is(err, ErrFreezeDeadline) {
		t.Error("an ancestor-held freeze must not also satisfy ErrFreezeDeadline")
	}
	if !res.Frozen {
		t.Error("Frozen = false although the cgroup is still effectively frozen")
	}
}

// If our own write did NOT land, the fault is a plain timeout, not an
// ancestor. Without this the ancestor branch would swallow every deadline.
func TestUnfreezeReportsPlainDeadlineWhenOwnSettingStillOne(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	f := New("", WithDeadline(20*time.Millisecond), WithCredentialValidator(allowCredential("t")))

	// Re-assert 1 in the control file after the write, simulating our write
	// not taking effect.
	go func() {
		for i := 0; i < 200; i++ {
			_ = os.WriteFile(filepath.Join(dir, freezeFile), []byte("1"), 0o644)
			time.Sleep(100 * time.Microsecond)
		}
	}()

	_, err := f.Unfreeze(dir, "t")
	if !errors.Is(err, ErrFreezeDeadline) {
		t.Fatalf("error = %v, want ErrFreezeDeadline", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Concurrency
// ─────────────────────────────────────────────────────────────────────────────

// -race is only evidence about paths that executed. Without a genuinely
// concurrent exercise of the same cgroup, "race detector clean" means "no
// concurrency was tested".
func TestConcurrentFreezeAndUnfreezeOnTheSameCgroupIsRaceFree(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	if err := os.WriteFile(filepath.Join(dir, procsFile), []byte("4242\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f := New("", WithDeadline(10*time.Millisecond), WithCredentialValidator(allowCredential("t")))

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); _, _ = f.Freeze(dir) }()
		go func() { defer wg.Done(); _, _ = f.Unfreeze(dir, "t") }()
	}
	wg.Wait()

	// The Freezer holds no mutable state, so concurrent use must leave it
	// usable rather than wedged.
	if f.Deadline() != 10*time.Millisecond {
		t.Errorf("Deadline mutated under concurrency: %v", f.Deadline())
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Freeze (ISC-10..15, ISC-42)
// ─────────────────────────────────────────────────────────────────────────────

// ISC-10 + ISC-13: writes "1" and returns nil only once frozen 1 is read back.
func TestFreezeWritesOneAndConfirmsFrozen(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)

	res, err := New("").Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if got := readFreezeControl(t, dir); got != "1" {
		t.Errorf("cgroup.freeze = %q, want \"1\"", got)
	}
	if !res.Frozen {
		t.Error("FreezeResult.Frozen = false after a successful freeze")
	}
	if res.CgroupPath != dir {
		t.Errorf("CgroupPath = %q, want %q", res.CgroupPath, dir)
	}
	if res.Polls < 1 {
		t.Errorf("Polls = %d, want at least 1", res.Polls)
	}
}

// ISC-15: the result carries a measured latency, and it is bounded by the
// deadline it was given.
func TestFreezeReportsMeasuredLatency(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)

	res, err := New("", WithDeadline(DefaultFreezeDeadline)).Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if res.Latency <= 0 {
		t.Errorf("Latency = %v, want a positive measurement", res.Latency)
	}
	if res.Latency > DefaultFreezeDeadline {
		t.Errorf("Latency = %v exceeds the deadline %v", res.Latency, DefaultFreezeDeadline)
	}
	if res.LatencyMS <= 0 {
		t.Errorf("LatencyMS = %v, want positive", res.LatencyMS)
	}
	if res.Deadline != DefaultFreezeDeadline {
		t.Errorf("Deadline = %v, want %v", res.Deadline, DefaultFreezeDeadline)
	}
}

// ISC-13 with a transition: the state arrives late but inside the deadline.
func TestFreezeWaitsForLateTransition(t *testing.T) {
	dir := freezableCgroup(t, filepath.Join(t.TempDir(), "cg"))
	settleAfter(t, dir, true, 5*time.Millisecond)

	res, err := New("", WithDeadline(200*time.Millisecond)).Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if !res.Frozen {
		t.Error("Frozen = false despite the transition landing inside the deadline")
	}
	if res.Polls < 2 {
		t.Errorf("Polls = %d; a late transition should require more than one read", res.Polls)
	}
}

// ISC-14 + ISC-42: THE defining test for this card.
//
// The pre-existing implementation this card replaces writes "1", spins a fixed
// number of times over cgroup.events, and then returns nil regardless of what
// it read. That is a containment control that cannot fail. This test asserts
// the opposite contract: a cgroup that never reports frozen 1 must produce
// ErrFreezeDeadline, and Frozen must stay false.
func TestFreezeReturnsDeadlineErrorWhenNeverFrozen(t *testing.T) {
	dir := freezableCgroup(t, filepath.Join(t.TempDir(), "cg")) // stays "frozen 0"

	res, err := New("", WithDeadline(20*time.Millisecond)).Freeze(dir)
	if !errors.Is(err, ErrFreezeDeadline) {
		t.Fatalf("error = %v, want ErrFreezeDeadline", err)
	}
	if res.Frozen {
		t.Error("Frozen = true although cgroup.events never reported frozen 1")
	}
	if res.Latency < 20*time.Millisecond {
		t.Errorf("Latency = %v, want at least the 20ms deadline", res.Latency)
	}
	if !strings.Contains(err.Error(), "frozen 0") {
		t.Errorf("error %q should name the observed state", err)
	}
	// The write still happened — the failure is in confirmation, not in the
	// attempt, and the error must not imply otherwise.
	if got := readFreezeControl(t, dir); got != "1" {
		t.Errorf("cgroup.freeze = %q, want \"1\"; the write should still have been attempted", got)
	}
}

// ISC-12: an absent control file is ErrCgroupNotFound, not a bare error, and
// no stray file is created in its place.
func TestFreezeMissingControlFileIsNotFound(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 0\n", false)

	if _, err := New("").Freeze(dir); !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
	if _, err := os.Stat(filepath.Join(dir, freezeFile)); err == nil {
		t.Error("Freeze created cgroup.freeze; it must never create the control file")
	}
}

// ISC-11: EACCES is distinguishable from ENOENT. Conflating them sends an
// operator hunting for a missing pod when the actual fault is a missing
// hostPath mount or securityContext.
func TestFreezePermissionDeniedIsTyped(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: file mode bits do not deny writes")
	}
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 0\n", true)
	if err := os.Chmod(filepath.Join(dir, freezeFile), 0o444); err != nil {
		t.Fatalf("chmod: %v", err)
	}

	_, err := New("").Freeze(dir)
	if !errors.Is(err, ErrPermission) {
		t.Fatalf("error = %v, want ErrPermission", err)
	}
	if errors.Is(err, ErrCgroupNotFound) {
		t.Error("a permission failure must not also satisfy ErrCgroupNotFound")
	}
}

// A cgroup.events that disappears mid-poll means the pod terminated. That is
// a distinct outcome from a deadline expiry.
func TestFreezeReportsVanishedCgroup(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "", true) // no events file

	_, err := New("", WithDeadline(20*time.Millisecond)).Freeze(dir)
	if !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// FreezePod (discovery + freeze)
// ─────────────────────────────────────────────────────────────────────────────

func TestFreezePodResolvesThenFreezes(t *testing.T) {
	root := t.TempDir()
	dir := mockCgroup(t,
		filepath.Join(root, "kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod"+testUIDUnderscored+".slice"),
		"populated 1\nfrozen 1\n", true)

	res, err := New(root).FreezePod(testUID)
	if err != nil {
		t.Fatalf("FreezePod: %v", err)
	}
	if res.PodUID != testUID {
		t.Errorf("PodUID = %q, want %q", res.PodUID, testUID)
	}
	if res.CgroupPath != dir {
		t.Errorf("CgroupPath = %q, want %q", res.CgroupPath, dir)
	}
	if !res.Frozen {
		t.Error("Frozen = false")
	}
}

func TestFreezePodPropagatesResolutionFailure(t *testing.T) {
	res, err := New(t.TempDir()).FreezePod(testUID)
	if !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
	if res == nil || res.PodUID != testUID {
		t.Error("a failed FreezePod must still return a result identifying the pod")
	}
	if res.Frozen {
		t.Error("Frozen = true on a resolution failure")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Unfreeze and governance (ISC-19..22)
// ─────────────────────────────────────────────────────────────────────────────

// ISC-20: the default posture refuses.
func TestUnfreezeDefaultsToRefusal(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	_ = os.WriteFile(filepath.Join(dir, freezeFile), []byte("1"), 0o644)

	_, err := New("").Unfreeze(dir, "any-credential")
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("error = %v, want ErrUnauthorized from the deny-all default", err)
	}
	if got := readFreezeControl(t, dir); got != "1" {
		t.Errorf("cgroup.freeze = %q; a refused unfreeze must not write the control file", got)
	}
}

func TestUnfreezeRejectsWrongCredential(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	f := New("", WithCredentialValidator(allowCredential("governor-token")))

	for _, cred := range []string{"", "wrong", "governor-token-x"} {
		if _, err := f.Unfreeze(dir, cred); !errors.Is(err, ErrUnauthorized) {
			t.Errorf("Unfreeze(%q) error = %v, want ErrUnauthorized", cred, err)
		}
	}
}

// ISC-19 + ISC-21 + ISC-22.
func TestUnfreezeWithValidCredentialWritesZeroAndVerifies(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 0\n", true)
	_ = os.WriteFile(filepath.Join(dir, freezeFile), []byte("1"), 0o644)

	f := New("", WithCredentialValidator(allowCredential("governor-token")))
	res, err := f.Unfreeze(dir, "governor-token")
	if err != nil {
		t.Fatalf("Unfreeze: %v", err)
	}
	if got := readFreezeControl(t, dir); got != "0" {
		t.Errorf("cgroup.freeze = %q, want \"0\"", got)
	}
	if res.Frozen {
		t.Error("Frozen = true after a verified unfreeze")
	}
	if res.Latency <= 0 {
		t.Error("Unfreeze did not report a latency")
	}
}

// ISC-22: read-back is real. If the cgroup keeps reporting frozen 1, the
// unfreeze fails rather than claiming success from the write.
func TestUnfreezeFailsWhenStateNeverClears(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	f := New("", WithDeadline(20*time.Millisecond), WithCredentialValidator(allowCredential("t")))

	res, err := f.Unfreeze(dir, "t")
	if !errors.Is(err, ErrAncestorFrozen) && !errors.Is(err, ErrFreezeDeadline) {
		t.Fatalf("error = %v, want ErrAncestorFrozen or ErrFreezeDeadline", err)
	}
	if !res.Frozen {
		t.Error("Frozen = false although the cgroup still reports frozen 1")
	}
}

func TestUnfreezeWaitsForLateTransition(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", true)
	settleAfter(t, dir, false, 5*time.Millisecond)

	f := New("", WithDeadline(200*time.Millisecond), WithCredentialValidator(allowCredential("t")))
	res, err := f.Unfreeze(dir, "t")
	if err != nil {
		t.Fatalf("Unfreeze: %v", err)
	}
	if res.Frozen {
		t.Error("Frozen = true after the state cleared")
	}
}

func TestUnfreezeMissingControlFileIsNotFound(t *testing.T) {
	dir := mockCgroup(t, filepath.Join(t.TempDir(), "cg"), "populated 1\nfrozen 1\n", false)
	f := New("", WithCredentialValidator(allowCredential("t")))

	if _, err := f.Unfreeze(dir, "t"); !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
}

func TestUnfreezePodResolvesThenThaws(t *testing.T) {
	root := t.TempDir()
	dir := mockCgroup(t,
		filepath.Join(root, "kubepods/besteffort/pod"+testUID),
		"populated 1\nfrozen 0\n", true)
	_ = os.WriteFile(filepath.Join(dir, freezeFile), []byte("1"), 0o644)

	f := New(root, WithCredentialValidator(allowCredential("t")))
	res, err := f.UnfreezePod(testUID, "t")
	if err != nil {
		t.Fatalf("UnfreezePod: %v", err)
	}
	if res.PodUID != testUID || res.Frozen {
		t.Errorf("result = %+v, want PodUID %q and Frozen false", res, testUID)
	}
}

func TestUnfreezePodPropagatesResolutionFailure(t *testing.T) {
	f := New(t.TempDir(), WithCredentialValidator(allowCredential("t")))
	if _, err := f.UnfreezePod(testUID, "t"); !errors.Is(err, ErrCgroupNotFound) {
		t.Fatalf("error = %v, want ErrCgroupNotFound", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Process census and the fork race (ISC-23..25)
// ─────────────────────────────────────────────────────────────────────────────

// ISC-23: recursive read. A pod cgroup delegates to one child cgroup per
// container, so its own cgroup.procs is typically empty.
func TestListProcsIsRecursiveSortedAndDeduplicated(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, procsFile), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"container-a": "3300\n1100\n",
		"container-b": "2200\n1100\n", // 1100 duplicated across children
	} {
		child := filepath.Join(root, name)
		if err := os.MkdirAll(child, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(child, procsFile), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	pids, err := ListProcs(root)
	if err != nil {
		t.Fatalf("ListProcs: %v", err)
	}
	if want := []int{1100, 2200, 3300}; !reflect.DeepEqual(pids, want) {
		t.Errorf("ListProcs() = %v, want %v", pids, want)
	}
}

func TestListProcsIgnoresMalformedEntries(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, procsFile), []byte("42\nnot-a-pid\n-7\n0\n\n99\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pids, err := ListProcs(root)
	if err != nil {
		t.Fatalf("ListProcs: %v", err)
	}
	if want := []int{42, 99}; !reflect.DeepEqual(pids, want) {
		t.Errorf("ListProcs() = %v, want %v", pids, want)
	}
}

func TestListProcsEmptyCgroupReturnsEmptySlice(t *testing.T) {
	pids, err := ListProcs(t.TempDir())
	if err != nil {
		t.Fatalf("ListProcs: %v", err)
	}
	if len(pids) != 0 {
		t.Errorf("ListProcs() = %v, want empty", pids)
	}
}

// ISC-24 + ISC-25: the fork race.
//
// The scenario: a process forks a child while the freeze is being asserted.
// cgroup-v2 freezes the whole subtree atomically in-kernel, so the child is
// frozen too — but only a census taken AFTER the frozen state is confirmed
// will contain it. This test reproduces that ordering: the child PID is
// written into cgroup.procs at the same moment the state settles, and it must
// appear in FreezeResult.PIDs.
func TestFreezeCensusIsTakenAfterConfirmationAndSeesForkedChild(t *testing.T) {
	dir := freezableCgroup(t, filepath.Join(t.TempDir(), "cg"))
	container := filepath.Join(dir, "container-a")
	if err := os.MkdirAll(container, 0o755); err != nil {
		t.Fatal(err)
	}
	// Pre-freeze census would see only the parent.
	if err := os.WriteFile(filepath.Join(container, procsFile), []byte("4242\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The child appears at the same time the kernel reports frozen 1.
	go func() {
		time.Sleep(4 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(container, procsFile), []byte("4242\n4243\n"), 0o644)
		_ = os.WriteFile(filepath.Join(dir, eventsFile), []byte("populated 1\nfrozen 1\n"), 0o644)
	}()

	res, err := New("", WithDeadline(200*time.Millisecond)).Freeze(dir)
	if err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if !res.Frozen {
		t.Fatal("Frozen = false")
	}
	if want := []int{4242, 4243}; !reflect.DeepEqual(res.PIDs, want) {
		t.Errorf("post-freeze PIDs = %v, want %v — the census must run after confirmation, "+
			"or a process forked during the freeze is missing from the audit record", res.PIDs, want)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Health probe (ISC-26, ISC-27)
// ─────────────────────────────────────────────────────────────────────────────

func TestHealthCheckPassesOnWritableRoot(t *testing.T) {
	f := New(t.TempDir())
	if err := f.HealthCheck(); err != nil {
		t.Fatalf("HealthCheck: %v", err)
	}
	// The probe cgroup must not be left behind.
	if _, err := os.Stat(filepath.Join(f.Root(), healthProbeDir)); !os.IsNotExist(err) {
		t.Error("HealthCheck left its probe cgroup on disk")
	}
}

func TestHealthCheckIsIdempotentAndClearsStaleProbe(t *testing.T) {
	f := New(t.TempDir())
	// Simulate a probe left by a crashed previous check.
	if err := os.Mkdir(filepath.Join(f.Root(), healthProbeDir), 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if err := f.HealthCheck(); err != nil {
			t.Fatalf("HealthCheck run %d: %v", i, err)
		}
	}
}

// ISC-27: a read-only hierarchy is the failure this probe exists to catch. It
// passes every stat and every read; only a write distinguishes it.
func TestHealthCheckFailsOnReadOnlyRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: directory mode bits do not deny writes")
	}
	root := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })

	err := New(root).HealthCheck()
	if err == nil {
		t.Fatal("HealthCheck passed on a read-only hierarchy root")
	}
	if !strings.Contains(err.Error(), "not writable") {
		t.Errorf("error %q should name writability as the fault", err)
	}
}

func TestHealthCheckFailsOnAbsentRoot(t *testing.T) {
	err := New(filepath.Join(t.TempDir(), "absent")).HealthCheck()
	if err == nil {
		t.Fatal("HealthCheck passed on an absent hierarchy root")
	}
	if !strings.Contains(err.Error(), "not reachable") {
		t.Errorf("error %q should name reachability as the fault", err)
	}
}

func TestHealthCheckFailsWhenRootIsAFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := New(path).HealthCheck(); err == nil {
		t.Fatal("HealthCheck passed on a regular file")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

func TestMsOf(t *testing.T) {
	if got := msOf(1500 * time.Microsecond); got != 1.5 {
		t.Errorf("msOf(1.5ms) = %v, want 1.5", got)
	}
	if got := msOf(0); got != 0 {
		t.Errorf("msOf(0) = %v, want 0", got)
	}
}

func TestClassifyWriteErrPassesThroughNil(t *testing.T) {
	if err := classifyWriteErr(nil, "/x"); err != nil {
		t.Errorf("classifyWriteErr(nil) = %v, want nil", err)
	}
}

func TestClassifyWriteErrUnknownErrorIsWrapped(t *testing.T) {
	sentinel := errors.New("some other failure")
	err := classifyWriteErr(sentinel, "/x")
	if !errors.Is(err, sentinel) {
		t.Errorf("unknown error was not wrapped: %v", err)
	}
	if errors.Is(err, ErrCgroupNotFound) || errors.Is(err, ErrPermission) {
		t.Error("an unknown error must not be classified as not-found or permission")
	}
}

func TestErrorsAreDistinct(t *testing.T) {
	all := []error{ErrCgroupNotFound, ErrPermission, ErrFreezeDeadline, ErrUnauthorized, ErrInvalidPodUID, ErrCgroupEmpty, ErrAncestorFrozen}
	for i, a := range all {
		for j, b := range all {
			if i != j && errors.Is(a, b) {
				t.Errorf("errors[%d] and errors[%d] are not distinct: %v / %v", i, j, a, b)
			}
		}
	}
}
