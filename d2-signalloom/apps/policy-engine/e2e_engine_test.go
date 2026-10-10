package main

// ISC-11: the real policy-engine binary, built from this package and started
// on a free port against the repo's policy/ root, scans every conformance
// fixture and reports /summary and /frameworks that reflect the scan.
//
// Go rather than bats: the binary is driven by the same fixtureScanMismatches
// walk as the in-process ISC-10 test, so the two layers cannot drift apart in
// how they read fixtures or attribute results. It runs in plain `go test ./...`
// (no build tag) and skips only when no Go toolchain is on PATH, saying so.

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

type httpTransport struct {
	base, key string
}

func (ht httpTransport) do(method, path string, body []byte) ([]byte, error) {
	req, err := http.NewRequest(method, ht.base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+ht.key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s %s: HTTP %d: %s", method, path, resp.StatusCode, raw)
	}
	return raw, nil
}

func (ht httpTransport) scan(body []byte) ([]ComplianceScanResult, error) {
	raw, err := ht.do(http.MethodPost, "/api/v1/compliance/scan", body)
	if err != nil {
		return nil, err
	}
	var out []ComplianceScanResult
	return out, json.Unmarshal(raw, &out)
}

func (ht httpTransport) summary() (ComplianceSummary, error) {
	raw, err := ht.do(http.MethodGet, "/api/v1/compliance/summary", nil)
	if err != nil {
		return ComplianceSummary{}, err
	}
	var s ComplianceSummary
	return s, json.Unmarshal(raw, &s)
}

// syncBuffer collects the child's output for failure diagnostics.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func buildEngine(t *testing.T) string {
	t.Helper()
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skipf("E2E SKIPPED LOUDLY: no Go toolchain on PATH, cannot build the policy-engine binary: %v", err)
	}
	bin := filepath.Join(t.TempDir(), "policy-engine")
	cmd := exec.Command(goBin, "build", "-o", bin, ".")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build failed (a real failure, not a skip): %v\n%s", err, out)
	}
	return bin
}

// startEngine runs the binary against policyRoot with key auth configured the
// way production configures it, and returns a transport once /healthz answers.
func startEngine(t *testing.T, bin, policyRoot string) httpTransport {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()

	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		t.Fatal(err)
	}
	key := hex.EncodeToString(keyBytes)

	logs := &syncBuffer{}
	cmd := exec.Command(bin)
	cmd.Env = []string{
		fmt.Sprintf("PORT=%d", port),
		"POLICY_ROOT=" + policyRoot,
		BundlesDirEnv + "=" + t.TempDir(),
		APIKeysEnv + "=" + key,
	}
	cmd.Stdout, cmd.Stderr = logs, logs
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-exited
		if t.Failed() {
			t.Logf("policy-engine output:\n%s", logs.String())
		}
	})

	tr := httpTransport{base: fmt.Sprintf("http://127.0.0.1:%d", port), key: key}
	deadline := time.Now().Add(15 * time.Second)
	for {
		select {
		case err := <-exited:
			exited <- err
			t.Fatalf("policy-engine exited before serving: %v\n%s", err, logs.String())
		default:
		}
		if _, err := tr.do(http.MethodGet, "/healthz", nil); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("policy-engine did not answer /healthz within 15s\n%s", logs.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !strings.Contains(logs.String(), "compliance scanner enabled") {
		t.Fatalf("compliance scanner not enabled for %s\n%s", policyRoot, logs.String())
	}
	return tr
}

func TestE2E_EngineBinary(t *testing.T) {
	bin := buildEngine(t)

	t.Run("real policy root", func(t *testing.T) {
		root := conformancePolicyRoot(t)
		tr := startEngine(t, bin, root)
		packs := loadConformancePacks(t, root)

		problems, scanned := fixtureScanMismatches(t, tr, packs)
		for _, p := range problems {
			t.Error(p)
		}
		t.Logf("e2e scanned %d conformance fixtures via the binary", scanned)

		// The headline bug over the wire: agent is bound in the real binary.
		body, _ := json.Marshal(map[string]any{"frameworks": []string{"finos-aigf"}, "agent": map[string]any{
			"registry":   map[string]any{"model_registered": true},
			"guardrails": map[string]any{"prompt_injection_filter": true},
			"governance": map[string]any{"decision_explainability": true},
		}})
		results, err := tr.scan(body)
		if err != nil {
			t.Fatal(err)
		}
		status := map[string]Verdict{}
		tally := map[Verdict]int{}
		for _, r := range results {
			status[r.Check] = r.Status
			tally[r.Status]++
		}
		for _, id := range []string{"registered-model-registry-entry", "prompt-injection-guardrail-active", "decision-explainability-metadata"} {
			if status[id] != VerdictPass {
				t.Errorf("finos-aigf %q over the binary: status %q, want pass", id, status[id])
			}
		}
		s, err := tr.summary()
		if err != nil {
			t.Fatal(err)
		}
		if s.TotalControls != len(results) || s.Passed != tally[VerdictPass] || s.Failed != tally[VerdictFail] || s.Errored != tally[VerdictError] {
			t.Errorf("summary %d/%d/%d/%d does not reflect the finos-aigf scan %d/%d/%d/%d",
				s.TotalControls, s.Passed, s.Failed, s.Errored, len(results), tally[VerdictPass], tally[VerdictFail], tally[VerdictError])
		}

		// /frameworks lists exactly the pack directories that load.
		raw, err := tr.do(http.MethodGet, "/api/v1/compliance/frameworks", nil)
		if err != nil {
			t.Fatal(err)
		}
		var listed map[string][]string
		if err := json.Unmarshal(raw, &listed); err != nil {
			t.Fatal(err)
		}
		var want, got []string
		for _, p := range packs {
			want = append(want, p.fw.ID+"/"+filepath.Base(p.dir))
		}
		for id, vers := range listed {
			for _, v := range vers {
				got = append(got, id+"/"+v)
			}
		}
		sort.Strings(want)
		sort.Strings(got)
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("/frameworks = %v, want every loading pack %v", got, want)
		}
	})

	// The same walk over the binary must catch a wrong expectation.
	t.Run("throwaway pack detects wrong expectation", func(t *testing.T) {
		root := throwawayRoot(t)
		tr := startEngine(t, bin, root)
		problems, scanned := fixtureScanMismatches(t, tr, loadConformancePacks(t, root))
		want := `throwaway/v1.0/wrong-expectation: check "agent-registered": got pass, want fail (error="")`
		if scanned != 4 || len(problems) != 1 || problems[0] != want {
			t.Fatalf("scanned %d; problems:\n%s\nwant exactly:\n%s", scanned, strings.Join(problems, "\n"), want)
		}
	})
}
