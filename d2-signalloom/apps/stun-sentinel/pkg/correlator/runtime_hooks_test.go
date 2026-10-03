// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Live, 2026-10-03 09:17:27: the recreated cpai-engineer-0 produced two
// /etc/passwd detections in its sidecar scopes, named by the opener field as
// comm "mount-product-f", exe ino 86807820 / 1298416 bytes -- the node's
// /usr/bin/bash running kind's createContainer OCI hook
// /kind/bin/mount-product-files.sh (#!/bin/bash), which the node's containerd
// configures through base_runtime_spec /etc/containerd/cri-base.json. Node
// code, run by the runtime inside the new container's cgroup, never workload
// code; the earlier cpai-engineer-0 freeze was the same opener after the pod
// left Pending. The runtime exemption now covers the OCI hooks the node
// actually configures, discovered from its containerd config, each identified
// by inode and size -- for a script hook, its interpreter's, AND the comm the
// kernel derives from the script name, since the interpreter alone is not the
// hook.

// The sentinel cannot read the node's /etc/containerd: kind ships it mode
// 0644 (no search bit, even for its root owner) and the sentinel holds no
// CAP_DAC_OVERRIDE/CAP_DAC_READ_SEARCH. Each container's OCI bundle
// (/run/containerd/io.containerd.runtime.v2.task/k8s.io/<id>/config.json,
// root-owned 0700/0644) IS readable, and lists exactly the hooks run for that
// container -- so the hooks are read from the event's own container bundle,
// with the containerd config as a second source where it can be read.

const fixtureContainerID = "715d69b888c61368" // kindCgroupTree's scope

const kindHookSpec = `{"ociVersion":"1.1.0","hooks":{"createContainer":[{"path":"/kind/bin/mount-product-files.sh"}]}}`

// hookFixture lays kind's layout out under the fixture node root, with the
// hook spec in the named sources: "bundle" (this container's OCI bundle)
// and/or "config" (containerd config -> base_runtime_spec).
func hookFixture(t *testing.T, m *SentinelProbeManager, sources ...string) (bash string) {
	t.Helper()
	root := filepath.Join(m.procRoot, "1", "root")
	bash = filepath.Join(root, "usr", "bin", "bash")
	files := map[string]string{
		"kind/bin/mount-product-files.sh": "#!/bin/bash\nset -e\n",
		"usr/bin/bash":                    "GNU bash ELF stand-in, distinct size",
	}
	for _, src := range sources {
		switch src {
		case "bundle":
			files["run/containerd/io.containerd.runtime.v2.task/k8s.io/"+fixtureContainerID+"/config.json"] = kindHookSpec
		case "config":
			files["etc/containerd/config.toml"] = `version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    base_runtime_spec = "/etc/containerd/cri-base.json"
    runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.test-handler]
    base_runtime_spec = "/etc/containerd/cri-base.json"
`
			files["etc/containerd/cri-base.json"] = kindHookSpec
		default:
			t.Fatalf("unknown hook source %q", src)
		}
	}
	for rel, body := range files {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// /bin is a symlink to usr/bin on the node, as on kind.
	if err := os.Symlink("usr/bin", filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	return bash
}

var hookSources = []string{"bundle", "config"}

// withComm stamps the caller's comm (16-byte field at offset 56).
func withComm(b []byte, comm string) []byte {
	for i := 56; i < 72; i++ {
		b[i] = 0
	}
	copy(b[56:71], comm)
	return b
}

func TestKindsMountProductFilesHookIsTheRuntime(t *testing.T) {
	for _, tc := range []struct{ src, target string }{
		{"bundle", "/etc/passwd"}, {"bundle", "/var/run/secrets/kubernetes.io/serviceaccount"},
		{"config", "/etc/passwd"}, {"config", "/var/run/secrets/kubernetes.io/serviceaccount"},
	} {
		target := tc.target
		agentBin := filepath.Join(t.TempDir(), "agent")
		if err := os.WriteFile(agentBin, []byte("agent"), 0o755); err != nil {
			t.Fatal(err)
		}
		m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: agentBin})
		bash := hookFixture(t, m, tc.src)
		bIno, bSize := inoSize(t, bash)
		rec := withComm(withExe(cgroupRecord(ino, target), bIno, bSize), "mount-product-f")
		if obs, ok := m.handleRecord(rec); ok || *calls != 0 {
			t.Fatalf("%s via %s: reported=%v (%+v) freezes=%d: the node's own OCI hook froze the pod", target, tc.src, ok, obs, *calls)
		}
		if s := m.Stats(); s.RuntimeLookups != 1 || s.RuntimeLookupsAtEvent != 1 {
			t.Fatalf("%s: runtime_lookups=%d at_event=%d", target, s.RuntimeLookups, s.RuntimeLookupsAtEvent)
		}
	}
}

// The interpreter is not the hook: the node's bash under any other comm is
// not exempt (it is not what the runtime runs in a container's cgroup).
func TestTheNodeInterpreterUnderAnotherNameIsNotTheHook(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	bIno, bSize := inoSize(t, bash)
	for _, comm := range []string{"bash", "mount-product-x", "sh"} {
		if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), bIno, bSize), comm)); !ok {
			t.Fatalf("comm %q with the node's bash was exempted", comm)
		}
	}
	if *calls != 3 {
		t.Fatalf("freezes = %d, want 3", *calls)
	}
}

// A copy of the interpreter shipped in the image has its own inode.
func TestAnImageCopyOfTheHookInterpreterIsDetected(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	_, bSize := inoSize(t, bash)
	copyPath := filepath.Join(t.TempDir(), "bash")
	b, err := os.ReadFile(bash)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(copyPath, b, 0o755); err != nil {
		t.Fatal(err)
	}
	cIno, _ := inoSize(t, copyPath)
	if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), cIno, bSize), "mount-product-f")); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: an image copy of the hook interpreter is not the node's", ok, *calls)
	}
}

func TestTheHookReadingShadowIsStillDetected(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	bIno, bSize := inoSize(t, bash)
	if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/shadow"), bIno, bSize), "mount-product-f")); !ok || *calls != 1 {
		t.Fatalf("ok=%v freezes=%d: /etc/shadow is never a setup open", ok, *calls)
	}
}

// Fail closed: a hook the node does not configure for THIS container is not
// exempt, and nothing is exempt when its source cannot be read or verified.
func TestAnUnverifiableHookFailsClosed(t *testing.T) {
	bundle := "run/containerd/io.containerd.runtime.v2.task/k8s.io/" + fixtureContainerID + "/config.json"
	cases := map[string]struct {
		src     string
		breakIt func(root string)
	}{
		"bundle missing":       {"bundle", func(r string) { os.Remove(filepath.Join(r, bundle)) }},
		"bundle without hooks": {"bundle", func(r string) { os.WriteFile(filepath.Join(r, bundle), []byte(`{}`), 0o644) }},
		"bundle unparseable":   {"bundle", func(r string) { os.WriteFile(filepath.Join(r, bundle), []byte(`{`), 0o644) }},
		"hook only in another container's bundle": {"bundle", func(r string) {
			other := filepath.Join(r, "run/containerd/io.containerd.runtime.v2.task/k8s.io/0000aaaa0000bbbb/config.json")
			os.MkdirAll(filepath.Dir(other), 0o755)
			os.WriteFile(other, []byte(kindHookSpec), 0o644)
			os.WriteFile(filepath.Join(r, bundle), []byte(`{}`), 0o644)
		}},
		"no containerd config":    {"config", func(r string) { os.Remove(filepath.Join(r, "etc/containerd/config.toml")) }},
		"no base runtime spec":    {"config", func(r string) { os.Remove(filepath.Join(r, "etc/containerd/cri-base.json")) }},
		"base spec without hooks": {"config", func(r string) { os.WriteFile(filepath.Join(r, "etc/containerd/cri-base.json"), []byte(`{}`), 0o644) }},
		"hook script missing":     {"bundle", func(r string) { os.Remove(filepath.Join(r, "kind/bin/mount-product-files.sh")) }},
		"interpreter missing":     {"bundle", func(r string) { os.Remove(filepath.Join(r, "usr/bin/bash")) }},
	}
	for name, tc := range cases {
		m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
		bash := hookFixture(t, m, tc.src)
		bIno, bSize := inoSize(t, bash)
		tc.breakIt(filepath.Join(m.procRoot, "1", "root"))
		if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), bIno, bSize), "mount-product-f")); !ok || *calls != 1 {
			t.Fatalf("%s: ok=%v freezes=%d: an unverifiable hook must fail closed", name, ok, *calls)
		}
	}
}

// As live: the containerd config is unreadable to the sentinel (kind's
// /etc/containerd is 0644, no search bit; no DAC capability), the bundle is
// not -- the hook is still recognised, from the bundle.
func TestAnUnreadableContainerdConfigStillLeavesTheBundle(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads through a 0644 directory")
	}
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	dir := filepath.Join(m.procRoot, "1", "root", "etc", "containerd")
	if err := os.Chmod(dir, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	if _, err := os.ReadFile(filepath.Join(dir, "config.toml")); err == nil {
		t.Fatal("precondition: the config should be unreadable")
	}
	bIno, bSize := inoSize(t, bash)
	if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), bIno, bSize), "mount-product-f")); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: the bundle names the hook", ok, *calls)
	}
}

// A binary (not a script) hook is identified by its own inode and size.
func TestABinaryHookIsIdentifiedByItsOwnInode(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	hookFixture(t, m, "config")
	root := filepath.Join(m.procRoot, "1", "root")
	hook := filepath.Join(root, "usr/local/bin/nvidia-ctk-hook")
	if err := os.MkdirAll(filepath.Dir(hook), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hook, []byte("\x7fELF hook stand-in"), 0o755); err != nil {
		t.Fatal(err)
	}
	spec := `{"hooks":{"createContainer":[{"path":"/kind/bin/mount-product-files.sh"}],"createRuntime":[{"path":"/usr/local/bin/nvidia-ctk-hook","args":["nvidia-ctk-hook","x"]}]}}`
	if err := os.WriteFile(filepath.Join(root, "etc/containerd/cri-base.json"), []byte(spec), 0o644); err != nil {
		t.Fatal(err)
	}
	hIno, hSize := inoSize(t, hook)
	if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), hIno, hSize), "nvidia-ctk-hook")); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: a configured binary hook is the runtime", ok, *calls)
	}
}

// The detection's node_runtime lists the hooks the exemption compared against.
func TestTheDetectionListsTheNodeHooksItWasComparedTo(t *testing.T) {
	m, _, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	bIno, bSize := inoSize(t, bash)
	obs, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), 1, 2), "agent"))
	if !ok || obs.Opener == nil {
		t.Fatalf("ok=%v opener=%v", ok, obs.Opener)
	}
	var sawHook bool
	for _, b := range obs.Opener.NodeRuntime {
		if b.Ino == bIno && b.Size == uint64(bSize) && b.Comm == "mount-product-f" && strings.HasSuffix(b.Path, "/bin/bash") {
			sawHook = true
		}
	}
	if !sawHook {
		t.Fatalf("node_runtime = %+v: the hook's interpreter identity is missing", obs.Opener.NodeRuntime)
	}
}

// Node paths are resolved inside the node root: an ABSOLUTE symlink there
// (/bin -> /usr/bin) must not be followed into the sentinel's own root,
// where /usr/bin/bash is a different file.
func TestNodePathsResolveAbsoluteSymlinksInsideTheNodeRoot(t *testing.T) {
	m, calls, ino, _ := kindRuntimeFixture(t, map[int]string{3610999: "/nonexistent"})
	bash := hookFixture(t, m, hookSources...)
	root := filepath.Join(m.procRoot, "1", "root")
	if err := os.Remove(filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/usr/bin", filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	bIno, bSize := inoSize(t, bash)
	if _, ok := m.handleRecord(withComm(withExe(cgroupRecord(ino, "/etc/passwd"), bIno, bSize), "mount-product-f")); ok || *calls != 0 {
		t.Fatalf("ok=%v freezes=%d: /bin/bash must resolve to the NODE's /usr/bin/bash", ok, *calls)
	}
}
