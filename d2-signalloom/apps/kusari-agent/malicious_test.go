package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ── /act/* GPU, egress, kube-enum and recon provocations ─────────────────────
//
// These mirror the read-passwd/read-shadow/cpu-burn tests: a POST returns the
// shared actResult envelope, a GET is 405 with Allow: POST, every call emits one
// event=act stdout line, an atomic counter ticks, and no sensitive bytes ever
// reach the wire. Dial targets and path sets are pointed at local fixtures so
// the suite is deterministic without real /dev/nvidia*, a token mount, or the
// internet.

// makeProbeSet builds a temp path set with `present` openable files followed by
// `absent` missing paths, and returns the set and how many are present.
func makeProbeSet(t *testing.T, present, absent int) ([]string, int) {
	t.Helper()
	dir := t.TempDir()
	var paths []string
	for i := 0; i < present; i++ {
		p := filepath.Join(dir, fmt.Sprintf("present-%d", i))
		if err := os.WriteFile(p, []byte("fixture"), 0o644); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	for i := 0; i < absent; i++ {
		paths = append(paths, filepath.Join(dir, fmt.Sprintf("absent-%d", i)))
	}
	return paths, present
}

// listener starts a local TCP server that accepts connections and records how
// many bytes it reads, so a test can prove /act/exfil uploads nothing.
func listener(t *testing.T) (string, *atomic.Int64) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	var read atomic.Int64
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
				buf := make([]byte, 512)
				if n, _ := c.Read(buf); n > 0 {
					read.Add(int64(n))
				}
			}(c)
		}
	}()
	return ln.Addr().String(), &read
}

// closedPort returns an address that nothing listens on, so a dial is refused.
func closedPort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

func TestActGPUOpenHoldsAndReports(t *testing.T) {
	a, logs, _ := actAgent(t)
	dev := filepath.Join(t.TempDir(), "nvidiactl")
	if err := os.WriteFile(dev, []byte("fakedevice"), 0o644); err != nil {
		t.Fatal(err)
	}
	a.cfg.gpuDevicePath = dev
	a.cfg.actHold = 20 * time.Millisecond

	start := time.Now()
	rec, body := post(t, a.routes(), "/act/gpu-open")
	if rec.Code != http.StatusOK || body["action"] != "gpu-open" || body["ok"] != true || body["attempted"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["path"] != dev {
		t.Fatalf("path = %v, want %v", body["path"], dev)
	}
	if body["write_mode"] != nil {
		t.Fatalf("read-only open reported write_mode: %v", body["write_mode"])
	}
	if el := time.Since(start); el < 20*time.Millisecond || body["held_ms"].(float64) < 20 {
		t.Fatalf("fd not held: elapsed %v held_ms %v", el, body["held_ms"])
	}
	for _, k := range []string{"started_at", "finished_at", "pid", "tid"} {
		if _, ok := body[k]; !ok {
			t.Fatalf("missing %q in %v", k, body)
		}
	}
	if !strings.Contains(logs.String(), `"event":"act"`) || !strings.Contains(logs.String(), `"action":"gpu-open"`) {
		t.Fatalf("no structured act log: %s", logs.String())
	}
	_, stats := get(t, a.routes(), "/stats")
	if stats["gpu_opens"].(float64) != 1 {
		t.Fatalf("gpu_opens = %v, want 1", stats["gpu_opens"])
	}
}

func TestActGPUOpenWriteIntent(t *testing.T) {
	a, _, _ := actAgent(t)
	dev := filepath.Join(t.TempDir(), "nvidiactl")
	if err := os.WriteFile(dev, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	a.cfg.gpuDevicePath = dev
	rec, body := post(t, a.routes(), "/act/gpu-open?write=1")
	if rec.Code != http.StatusOK || body["ok"] != true || body["write_mode"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
}

func TestActGPUOpenAbsentDeviceStillSignals(t *testing.T) {
	a, _, _ := actAgent(t)
	a.cfg.gpuDevicePath = filepath.Join(t.TempDir(), "no-such-nvidiactl")
	rec, body := post(t, a.routes(), "/act/gpu-open")
	// The openat is the signal, not the bytes: attempted even when absent, and
	// a missing device node answers 200 (like read-shadow), not 500.
	if rec.Code != http.StatusOK || body["attempted"] != true || body["ok"] != false {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["error"] == nil || body["error"] == "" {
		t.Fatalf("no error field for absent device: %v", body)
	}
}

func TestActGPUOpenNeverLeaksDeviceBytes(t *testing.T) {
	a, _, _ := actAgent(t)
	dev := filepath.Join(t.TempDir(), "nvidiactl")
	if err := os.WriteFile(dev, []byte("SENTINEL-GPU-BYTES"), 0o644); err != nil {
		t.Fatal(err)
	}
	a.cfg.gpuDevicePath = dev
	rec, _ := post(t, a.routes(), "/act/gpu-open?write=1")
	if strings.Contains(rec.Body.String(), "SENTINEL-GPU-BYTES") {
		t.Fatalf("response leaked device bytes: %s", rec.Body.String())
	}
}

func TestActGPUProbeCountsOpenable(t *testing.T) {
	a, logs, _ := actAgent(t)
	paths, present := makeProbeSet(t, 3, 2)
	a.gpuProbePaths = paths

	rec, body := post(t, a.routes(), "/act/gpu-probe")
	if rec.Code != http.StatusOK || body["action"] != "gpu-probe" || body["ok"] != true || body["attempted"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["count"].(float64) != float64(len(paths)) || body["found"].(float64) != float64(present) {
		t.Fatalf("count/found = %v/%v, want %d/%d", body["count"], body["found"], len(paths), present)
	}
	probes, ok := body["probes"].([]any)
	if !ok || len(probes) != len(paths) {
		t.Fatalf("probes = %v, want %d entries", body["probes"], len(paths))
	}
	if !strings.Contains(logs.String(), `"event":"act"`) || !strings.Contains(logs.String(), `"action":"gpu-probe"`) {
		t.Fatalf("no structured act log: %s", logs.String())
	}
	_, stats := get(t, a.routes(), "/stats")
	if stats["gpu_probes"].(float64) != 1 {
		t.Fatalf("gpu_probes = %v, want 1", stats["gpu_probes"])
	}
}

func TestActReconCountsOpenableAndNeverLeaks(t *testing.T) {
	a, logs, _ := actAgent(t)
	dir := t.TempDir()
	secret := filepath.Join(dir, "shadow")
	if err := os.WriteFile(secret, []byte("root:$6$SENTINEL-HASH:::"), 0o600); err != nil {
		t.Fatal(err)
	}
	a.reconPaths = []string{secret, filepath.Join(dir, "admin.conf-absent")}

	rec, body := post(t, a.routes(), "/act/recon")
	if rec.Code != http.StatusOK || body["action"] != "recon" || body["ok"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["count"].(float64) != 2 || body["found"].(float64) != 1 {
		t.Fatalf("count/found = %v/%v, want 2/1", body["count"], body["found"])
	}
	if strings.Contains(rec.Body.String(), "SENTINEL-HASH") {
		t.Fatalf("recon leaked file contents: %s", rec.Body.String())
	}
	if !strings.Contains(logs.String(), `"action":"recon"`) {
		t.Fatalf("no structured act log: %s", logs.String())
	}
	_, stats := get(t, a.routes(), "/stats")
	if stats["recons"].(float64) != 1 {
		t.Fatalf("recons = %v, want 1", stats["recons"])
	}
}

func TestActExfilConnectedUploadsNothing(t *testing.T) {
	a, logs, _ := actAgent(t)
	addr, read := listener(t)
	a.cfg.exfilTarget = addr
	a.cfg.dialTimeout = 2 * time.Second

	rec, body := post(t, a.routes(), "/act/exfil")
	if rec.Code != http.StatusOK || body["action"] != "exfil" || body["ok"] != true || body["attempted"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["connected"] != true || body["dial_outcome"] != "connected" {
		t.Fatalf("dial outcome = connected:%v outcome:%v", body["connected"], body["dial_outcome"])
	}
	if body["host"] != addr {
		t.Fatalf("host = %v, want %v", body["host"], addr)
	}
	time.Sleep(50 * time.Millisecond) // let the server observe the (empty) connection
	if n := read.Load(); n != 0 {
		t.Fatalf("exfil uploaded %d bytes, want 0 — the connect is the signal, no payload", n)
	}
	if !strings.Contains(logs.String(), `"action":"exfil"`) {
		t.Fatalf("no structured act log: %s", logs.String())
	}
	_, stats := get(t, a.routes(), "/stats")
	if stats["exfils"].(float64) != 1 {
		t.Fatalf("exfils = %v, want 1", stats["exfils"])
	}
}

func TestActExfilRefusedIsStillSuccessfulProvocation(t *testing.T) {
	a, _, _ := actAgent(t)
	a.cfg.exfilTarget = closedPort(t)
	a.cfg.dialTimeout = 2 * time.Second

	rec, body := post(t, a.routes(), "/act/exfil")
	if rec.Code != http.StatusOK || body["ok"] != true || body["attempted"] != true {
		t.Fatalf("a refused dial is still a provocation: code %d body %v", rec.Code, body)
	}
	if body["connected"] == true {
		t.Fatalf("reported connected to a closed port: %v", body)
	}
	if body["dial_outcome"] != "refused" {
		t.Fatalf("dial_outcome = %v, want refused", body["dial_outcome"])
	}
	if body["dial_error"] == nil || body["dial_error"] == "" {
		t.Fatalf("no dial_error for a refused connect: %v", body)
	}
}

func TestActKubeEnumReadsTokenMetaAndDials(t *testing.T) {
	a, logs, _ := actAgent(t)
	tok := filepath.Join(t.TempDir(), "token")
	const tokenVal = "SENTINEL.JWT.aaaaaaaaaaaaaaaaaaaaaaaa"
	if err := os.WriteFile(tok, []byte(tokenVal), 0o600); err != nil {
		t.Fatal(err)
	}
	a.cfg.saTokenPath = tok
	addr, _ := listener(t)
	a.cfg.kubeAPITarget = addr
	a.cfg.dialTimeout = 2 * time.Second

	rec, body := post(t, a.routes(), "/act/kube-enum")
	if rec.Code != http.StatusOK || body["action"] != "kube-enum" || body["ok"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["token_readable"] != true || body["token_bytes"].(float64) != float64(len(tokenVal)) {
		t.Fatalf("token meta = readable:%v bytes:%v want true/%d", body["token_readable"], body["token_bytes"], len(tokenVal))
	}
	if body["token_path"] != tok {
		t.Fatalf("token_path = %v, want %v", body["token_path"], tok)
	}
	if body["connected"] != true || body["dial_outcome"] != "connected" || body["host"] != addr {
		t.Fatalf("dial = connected:%v outcome:%v host:%v", body["connected"], body["dial_outcome"], body["host"])
	}
	if strings.Contains(rec.Body.String(), "SENTINEL") {
		t.Fatalf("kube-enum leaked the token value: %s", rec.Body.String())
	}
	if strings.Contains(logs.String(), "SENTINEL") {
		t.Fatalf("kube-enum leaked the token value into logs: %s", logs.String())
	}
	if !strings.Contains(logs.String(), `"action":"kube-enum"`) {
		t.Fatalf("no structured act log: %s", logs.String())
	}
	_, stats := get(t, a.routes(), "/stats")
	if stats["kube_enums"].(float64) != 1 {
		t.Fatalf("kube_enums = %v, want 1", stats["kube_enums"])
	}
}

func TestActKubeEnumTokenAbsentAndDialRefused(t *testing.T) {
	a, _, _ := actAgent(t)
	a.cfg.saTokenPath = filepath.Join(t.TempDir(), "no-token")
	a.cfg.kubeAPITarget = closedPort(t)
	a.cfg.dialTimeout = 2 * time.Second

	rec, body := post(t, a.routes(), "/act/kube-enum")
	if rec.Code != http.StatusOK || body["ok"] != true || body["attempted"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
	if body["token_readable"] == true {
		t.Fatalf("reported a readable token that does not exist: %v", body)
	}
	if body["token_bytes"] != nil {
		t.Fatalf("token_bytes present for an unreadable token: %v", body["token_bytes"])
	}
	if body["connected"] == true || body["dial_outcome"] != "refused" {
		t.Fatalf("dial = connected:%v outcome:%v, want refused", body["connected"], body["dial_outcome"])
	}
}

func TestMaliciousActRoutesRejectGet(t *testing.T) {
	a, _, _ := actAgent(t)
	for _, p := range []string{"/act/gpu-open", "/act/gpu-probe", "/act/exfil", "/act/kube-enum", "/act/recon"} {
		rec, body := get(t, a.routes(), p)
		if rec.Code != http.StatusMethodNotAllowed || body["ok"] != false {
			t.Fatalf("%s: code %d body %v, want 405 ok=false", p, rec.Code, body)
		}
		if rec.Header().Get("Allow") != http.MethodPost {
			t.Fatalf("%s: Allow = %q, want POST", p, rec.Header().Get("Allow"))
		}
	}
}

func TestMaliciousConfigFromEnv(t *testing.T) {
	cfg, err := configFromEnv(envFrom(map[string]string{
		"GPU_DEVICE_PATH":  "/dev/custom-gpu",
		"EXFIL_TARGET":     "paste.example:9999",
		"SA_TOKEN_PATH":    "/var/run/token",
		"KUBE_API_TARGET":  "api.local:6443",
		"ACT_DIAL_TIMEOUT": "750ms",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.gpuDevicePath != "/dev/custom-gpu" || cfg.exfilTarget != "paste.example:9999" ||
		cfg.saTokenPath != "/var/run/token" || cfg.kubeAPITarget != "api.local:6443" ||
		cfg.dialTimeout != 750*time.Millisecond {
		t.Fatalf("overrides not applied: %+v", cfg)
	}

	def, err := configFromEnv(envFrom(nil))
	if err != nil {
		t.Fatal(err)
	}
	if def.gpuDevicePath != defaultGPUDevicePath || def.exfilTarget != defaultExfilTarget ||
		def.saTokenPath != defaultSATokenPath || def.kubeAPITarget != defaultKubeAPITarget ||
		def.dialTimeout != defaultDialTimeout {
		t.Fatalf("defaults wrong: %+v", def)
	}

	for _, env := range []map[string]string{
		{"ACT_DIAL_TIMEOUT": "0"}, {"ACT_DIAL_TIMEOUT": "-1s"}, {"ACT_DIAL_TIMEOUT": "nope"},
	} {
		if _, err := configFromEnv(envFrom(env)); err == nil {
			t.Fatalf("%v accepted", env)
		}
	}
}

func TestMaliciousStatsCountersAllIncrement(t *testing.T) {
	a, _, _ := actAgent(t)
	dev := filepath.Join(t.TempDir(), "gpu")
	if err := os.WriteFile(dev, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	a.cfg.gpuDevicePath = dev
	a.gpuProbePaths, _ = makeProbeSet(t, 1, 1)
	a.reconPaths, _ = makeProbeSet(t, 1, 1)
	a.cfg.saTokenPath = filepath.Join(t.TempDir(), "absent-token")
	a.cfg.dialTimeout = time.Second
	a.cfg.exfilTarget = closedPort(t)
	a.cfg.kubeAPITarget = closedPort(t)

	h := a.routes()
	for _, p := range []string{"/act/gpu-open", "/act/gpu-probe", "/act/exfil", "/act/kube-enum", "/act/recon"} {
		if rec, _ := post(t, h, p); rec.Code != http.StatusOK {
			t.Fatalf("%s: code %d", p, rec.Code)
		}
	}
	_, stats := get(t, h, "/stats")
	for _, k := range []string{"gpu_opens", "gpu_probes", "exfils", "kube_enums", "recons"} {
		if stats[k] == nil || stats[k].(float64) != 1 {
			t.Fatalf("%s = %v, want 1", k, stats[k])
		}
	}
}
