// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"bytes"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"
)

// The probe now drops non-candidate opens before they reach the ring buffer
// (bpf/path_prefilter.h). A path it drops never reaches IsSensitivePath, so a
// disagreement is a silent miss. These tests compile the probe's own C header
// natively and hold it to the userspace decision.

const bpfDir = "../../bpf"

// kernelDecisions runs bpf/path_prefilter.h, compiled with the host C
// compiler, over paths. It fails, never skips, without a compiler: the
// agreement is the whole safety argument for filtering in the kernel.
func kernelDecisions(t *testing.T, paths []string) []bool {
	t.Helper()
	cc := os.Getenv("CC")
	if cc == "" {
		cc = "cc"
	}
	bin := filepath.Join(t.TempDir(), "prefilter")
	out, err := exec.Command(cc, "-std=c11", "-nostdinc", "-O2", "-Wall", "-Werror", "-I", bpfDir,
		"-o", bin, filepath.Join(bpfDir, "prefilter_harness.c")).CombinedOutput()
	if err != nil {
		t.Fatalf("compile the probe prefilter with %s: %v\n%s", cc, err, out)
	}
	var in bytes.Buffer
	for _, p := range paths {
		in.WriteString(p)
		in.WriteByte(0)
	}
	cmd := exec.Command(bin)
	cmd.Stdin = &in
	got, err := cmd.Output()
	if err != nil {
		t.Fatalf("run prefilter harness: %v", err)
	}
	if len(got) != len(paths) {
		t.Fatalf("harness answered %d of %d paths", len(got), len(paths))
	}
	res := make([]bool, len(paths))
	for i, c := range got {
		res[i] = c == '1'
	}
	return res
}

// probeView is the string the probe actually sees: bpf_probe_read_user_str
// keeps at most 255 bytes, and userspace decodes the same truncated buffer.
func probeView(p string) string {
	if i := strings.IndexByte(p, 0); i >= 0 {
		p = p[:i]
	}
	if len(p) > 255 {
		p = p[:255]
	}
	return p
}

// userspaceMayFlag: could the correlator call this path sensitive? A relative
// path depends on the cwd it is resolved against, so it always might.
func userspaceMayFlag(m *SentinelProbeManager, p string) bool {
	return !path.IsAbs(p) || m.IsSensitivePath(p)
}

func agreementTable() []string {
	long := "/" + strings.Repeat("a/", 126) + "x" // 254 bytes: the scan must reach the end of the buffer
	return []string{
		// sensitive, canonical
		"/etc/passwd", "/etc/shadow", "/root/.ssh", "/root/.ssh/id_rsa",
		"/var/run/secrets/kubernetes.io/serviceaccount/token",
		"/run/secrets/kubernetes.io/serviceaccount/namespace",
		// sensitive after path.Clean
		"/etc/passwd/", "//etc/passwd", "/etc//passwd", "/etc/./passwd", "/tmp/../etc/passwd",
		"/root/.ssh/.", "/etc/passwd/..", "/proc/../../etc/shadow",
		// relative: resolved against the cwd in userspace
		"etc/passwd", "../../etc/shadow", "passwd", "./id_rsa", ".",
		// empty: an unreadable user pointer still emits
		"",
		// not sensitive: component boundary, case, homoglyphs, siblings
		"/etc/passwdX", "/etc/passwd-", "/etc/shadowed", "/ETC/PASSWD", "/etc/pаsswd", "/еtc/passwd",
		"/root/.sshx/id_rsa", "/root/ssh", "/var/run/secrets/kubernetes.io/serviceaccountX",
		"/run/secrets", "/etc", "/",
		// ordinary noise the filter exists to drop
		"/proc/self/stat", "/usr/lib/x86_64-linux-gnu/libc.so.6", "/etc/ld.so.cache",
		"/sys/fs/cgroup/kubepods.slice/cpu.stat", "/home/u/.bashrc", "/tmp/.X11-unix",
		// truncation at 255 bytes
		long, "/etc/passwd/" + strings.Repeat("z", 300),
	}
}

func generatedPaths() []string {
	segs := []string{"etc", "passwd", "shadow", "..", ".", "", "root", ".ssh", "run", "var",
		"secrets", "kubernetes.io", "serviceaccount", "passwdX", "pаsswd", "tmp"}
	var out []string
	for _, lead := range []string{"/", ""} {
		for _, a := range segs {
			for _, b := range segs {
				for _, c := range segs {
					out = append(out, lead+a+"/"+b+"/"+c)
				}
			}
		}
	}
	return out
}

func TestKernelPrefilterNeverDropsAPathUserspaceCouldFlag(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil)
	paths := append(agreementTable(), generatedPaths()...)
	kernel := kernelDecisions(t, paths)
	for i, raw := range paths {
		p := probeView(raw)
		if userspaceMayFlag(m, p) && !kernel[i] {
			t.Errorf("kernel drops %q, which userspace could call sensitive", p)
		}
	}
}

// On a lexically clean absolute path there is nothing for userspace to
// resolve, so the kernel must decide exactly as IsSensitivePath does: no
// silent misses, and no noise either.
func TestKernelPrefilterMatchesUserspaceOnCleanAbsolutePaths(t *testing.T) {
	m := NewSentinelProbeManager(nil, "", nil)
	paths := append(agreementTable(), generatedPaths()...)
	kernel := kernelDecisions(t, paths)
	checked := 0
	for i, raw := range paths {
		p := probeView(raw)
		if !path.IsAbs(p) || path.Clean(p) != p || len(raw) > 255 {
			continue
		}
		checked++
		if kernel[i] != m.IsSensitivePath(p) {
			t.Errorf("%q: kernel=%v userspace=%v", p, kernel[i], m.IsSensitivePath(p))
		}
	}
	if checked < 100 {
		t.Fatalf("only %d clean absolute paths were compared", checked)
	}
}

func TestKernelPrefilterDropsTheOrdinaryFirehose(t *testing.T) {
	noise := []string{"/proc/self/stat", "/usr/lib/x86_64-linux-gnu/libc.so.6", "/etc/ld.so.cache",
		"/etc/passwdX", "/etc/pаsswd", "/ETC/PASSWD", "/sys/fs/cgroup/kubepods.slice/cpu.stat", "/home/u/.bashrc"}
	for i, emitted := range kernelDecisions(t, noise) {
		if emitted {
			t.Errorf("kernel emits %q, which no rule makes a candidate", noise[i])
		}
	}
}

func TestSensitivePrefixesHeaderIsGeneratedFromTheGoTable(t *testing.T) {
	want, err := RenderSensitivePrefixesHeader(DefaultSensitivePrefixes)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(bpfDir, "sensitive_prefixes.h"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatal("bpf/sensitive_prefixes.h is stale: run `go run ./cmd/gen-sensitive-prefixes` then `bpf/build.sh sentinel`")
	}
}

func TestRenderSensitivePrefixesHeaderRefusesWhatTheProbeCannotMatch(t *testing.T) {
	for _, tc := range []struct{ name, prefix, want string }{
		{"relative", "etc/passwd", "absolute"},
		{"root", "/", "absolute"},
		{"homoglyph", "/etc/pаsswd", "non-ASCII"},
		{"control byte", "/etc/pass\twd", "non-printable"},
		{"too long", "/" + strings.Repeat("a", 251), "longer"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := RenderSensitivePrefixesHeader([]string{tc.prefix})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want one naming %q", err, tc.want)
			}
		})
	}
	if _, err := RenderSensitivePrefixesHeader(nil); err == nil {
		t.Fatal("an empty table must be refused: the probe would pass no absolute path at all")
	}
}
