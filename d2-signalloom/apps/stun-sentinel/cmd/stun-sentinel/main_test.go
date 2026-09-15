// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/telemetry"
)

const uid = "e4fc67c7-054b-4934-bfdd-d13b6390e2c3"
const uidUnderscored = "e4fc67c7_054b_4934_bfdd_d13b6390e2c3"

// mockPodCgroup builds a cgroup-v2 pod directory under root in the systemd
// layout, reporting the given frozen state.
func mockPodCgroup(t *testing.T, root string, frozen bool) string {
	t.Helper()
	dir := filepath.Join(root, "kubepods.slice", "kubepods-besteffort.slice",
		"kubepods-besteffort-pod"+uidUnderscored+".slice")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	state := "0"
	if frozen {
		state = "1"
	}
	for name, body := range map[string]string{
		"cgroup.freeze": state,
		"cgroup.events": "populated 1\nfrozen " + state + "\n",
		"cgroup.procs":  "4242\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func newTestServer(t *testing.T, root, freezeToken, resumeToken string) (*server, *bytes.Buffer) {
	t.Helper()
	buf := &bytes.Buffer{}
	freezeValidate := constantTimeTokenValidator(freezeToken)
	resumeValidate := constantTimeTokenValidator(resumeToken)
	return &server{
		freezer: cgroup.New(root,
			cgroup.WithDeadline(30*time.Millisecond),
			cgroup.WithFreezeCredentialValidator(freezeValidate),
			cgroup.WithCredentialValidator(resumeValidate),
		),
		emitter:        telemetry.NewEmitter(buf),
		freezeValidate: freezeValidate,
		resumeValidate: resumeValidate,
	}, buf
}

func postJSON(t *testing.T, h http.Handler, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// ─────────────────────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────────────────────

func TestLoadConfigDefaults(t *testing.T) {
	t.Setenv("CGROUP_ROOT", "")
	t.Setenv("LISTEN_ADDR", "")
	t.Setenv("STUN_FREEZE_TOKEN", "")
	t.Setenv("STUN_RESUME_TOKEN", "")

	cfg, err := loadConfig(nil)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.cgroupRoot != cgroup.DefaultCgroupRoot {
		t.Errorf("cgroupRoot = %q", cfg.cgroupRoot)
	}
	if cfg.listenAddr != ":8080" {
		t.Errorf("listenAddr = %q", cfg.listenAddr)
	}
	if cfg.deadline != cgroup.DefaultFreezeDeadline {
		t.Errorf("deadline = %v, want %v", cfg.deadline, cgroup.DefaultFreezeDeadline)
	}
	if cfg.freezeToken != "" {
		t.Errorf("freezeToken = %q, want empty", cfg.freezeToken)
	}
	if cfg.resumeToken != "" {
		t.Errorf("resumeToken = %q, want empty", cfg.resumeToken)
	}
}

func TestLoadConfigFlagsBeatEnvironment(t *testing.T) {
	t.Setenv("CGROUP_ROOT", "/from-env")
	t.Setenv("LISTEN_ADDR", ":9999")

	cfg, err := loadConfig([]string{"--cgroup-root=/from-flag", "--listen-addr=:7777", "--freeze-deadline=25ms"})
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if cfg.cgroupRoot != "/from-flag" {
		t.Errorf("cgroupRoot = %q, want the flag value", cfg.cgroupRoot)
	}
	if cfg.listenAddr != ":7777" {
		t.Errorf("listenAddr = %q, want the flag value", cfg.listenAddr)
	}
	if cfg.deadline != 25*time.Millisecond {
		t.Errorf("deadline = %v, want 25ms", cfg.deadline)
	}
}

// The freeze and resume credentials must never be flags: flags are visible in `ps` and
// in the pod spec.
func TestTokensComeFromEnvironmentOnly(t *testing.T) {
	t.Setenv("STUN_FREEZE_TOKEN", "freeze-secret-token")
	t.Setenv("STUN_RESUME_TOKEN", "resume-governor-token")
	cfg, err := loadConfig(nil)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.freezeToken != "freeze-secret-token" {
		t.Errorf("freezeToken = %q", cfg.freezeToken)
	}
	if cfg.resumeToken != "resume-governor-token" {
		t.Errorf("resumeToken = %q", cfg.resumeToken)
	}
	if _, err := loadConfig([]string{"--resume-token=x"}); err == nil {
		t.Error("a --resume-token flag was accepted; the credential must not be settable on the command line")
	}
	if _, err := loadConfig([]string{"--freeze-token=x"}); err == nil {
		t.Error("a --freeze-token flag was accepted; the credential must not be settable on the command line")
	}
}

func TestLoadConfigRejectsUnknownFlag(t *testing.T) {
	if _, err := loadConfig([]string{"--nope"}); err == nil {
		t.Fatal("loadConfig accepted an unknown flag")
	}
}

func TestEnvOr(t *testing.T) {
	t.Setenv("STUN_TEST_KEY", "")
	if got := envOr("STUN_TEST_KEY", "fallback"); got != "fallback" {
		t.Errorf("envOr on empty = %q, want fallback", got)
	}
	t.Setenv("STUN_TEST_KEY", "set")
	if got := envOr("STUN_TEST_KEY", "fallback"); got != "set" {
		t.Errorf("envOr = %q, want set", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Credential validation
// ─────────────────────────────────────────────────────────────────────────────

// An unconfigured token must deny, not permit. The failure mode of the
// opposite default is that a daemon deployed without governance wiring hands
// capability back to anyone who asks.
func TestEmptyConfiguredTokenDeniesEverything(t *testing.T) {
	v := constantTimeTokenValidator("")
	for _, cred := range []string{"", "anything", "admin"} {
		if v(cred) {
			t.Errorf("empty configured token accepted %q", cred)
		}
	}
}

func TestTokenValidatorMatchesOnlyExact(t *testing.T) {
	v := constantTimeTokenValidator("governor-token")
	if !v("governor-token") {
		t.Error("the exact token was rejected")
	}
	for _, cred := range []string{"", "governor-toke", "governor-tokenX", "GOVERNOR-TOKEN", "x"} {
		if v(cred) {
			t.Errorf("validator accepted %q", cred)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Error to HTTP status mapping
// ─────────────────────────────────────────────────────────────────────────────

func TestStatusForDistinguishesEveryContainmentOutcome(t *testing.T) {
	cases := map[error]int{
		cgroup.ErrInvalidPodUID:    http.StatusBadRequest,
		cgroup.ErrUnauthorized:     http.StatusUnauthorized,
		cgroup.ErrCgroupNotFound:   http.StatusNotFound,
		cgroup.ErrPermission:       http.StatusInternalServerError,
		cgroup.ErrFreezeDeadline:   http.StatusGatewayTimeout,
		errors.New("unclassified"): http.StatusInternalServerError,
	}
	for err, want := range cases {
		if got := statusFor(err); got != want {
			t.Errorf("statusFor(%v) = %d, want %d", err, got, want)
		}
	}
	// Wrapped errors must classify the same as bare ones.
	wrapped := fmt.Errorf("context: %w", cgroup.ErrFreezeDeadline)
	if got := statusFor(wrapped); got != http.StatusGatewayTimeout {
		t.Errorf("statusFor(wrapped deadline) = %d, want 504", got)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// /healthz
// ─────────────────────────────────────────────────────────────────────────────

func TestHealthzReportsWritableHierarchy(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-tok", "resume-tok")
	rec := httptest.NewRecorder()
	srv.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "ok" || body["cgroup_write"] != true {
		t.Errorf("body = %v", body)
	}
	if body["deadline_ms"] != float64(30) {
		t.Errorf("deadline_ms = %v, want 30", body["deadline_ms"])
	}
}

func TestHealthzReports503OnUnwritableHierarchy(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: directory mode bits do not deny writes")
	}
	root := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })

	srv, _ := newTestServer(t, root, "freeze-tok", "resume-tok")
	rec := httptest.NewRecorder()
	srv.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["cgroup_write"] != false {
		t.Errorf("cgroup_write = %v, want false", body["cgroup_write"])
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// /stun
// ─────────────────────────────────────────────────────────────────────────────

// authHeader presents the governance credential the way a real caller does — in a
// header, never in the URL.
func authHeader(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

// /stun requires a valid freeze credential. Without one it rejects with 401 Unauthorized
// before executing any freeze logic.
func TestStunRefusesWithoutCredential(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, telem := newTestServer(t, root, "freeze-token", "resume-token")

	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, nil)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401: %s", rec.Code, rec.Body)
	}
	// A refused request must not reach the freezer, so it must emit no halt event.
	if strings.TrimSpace(telem.String()) != "" {
		t.Errorf("refused freeze still emitted telemetry: %q", telem.String())
	}
}

func TestStunRefusesWrongCredential(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, _ := newTestServer(t, root, "freeze-token", "resume-token")

	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, authHeader("not-the-freeze-token"))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

// Calling /stun with resume token must be refused: distinct token scopes.
func TestStunRefusesResumeToken(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, _ := newTestServer(t, root, "freeze-token", "resume-token")

	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, authHeader("resume-token"))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 for cross-token stun attempt", rec.Code)
	}
}

// An unconfigured daemon must refuse to freeze, not accept everything.
func TestStunRefusesWhenNoTokenConfigured(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, _ := newTestServer(t, root, "", "")

	for _, h := range []map[string]string{nil, authHeader(""), authHeader("anything")} {
		rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, h)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("unconfigured daemon accepted a freeze: status = %d", rec.Code)
		}
	}
}

// Probes carry no credential and must stay reachable, or the kubelet marks the
// daemon unhealthy and containment capacity disappears.
func TestHealthRoutesStayOpen(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	for _, path := range []string{"/healthz", "/readyz"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		srv.routes().ServeHTTP(rec, req)
		if rec.Code == http.StatusUnauthorized || rec.Code == http.StatusForbidden {
			t.Errorf("%s requires a credential; kubelet probes cannot present one", path)
		}
	}
}

func TestStunFreezesAndEmitsHaltedEvent(t *testing.T) {
	root := t.TempDir()
	dir := mockPodCgroup(t, root, true)
	srv, telem := newTestServer(t, root, "freeze-token", "resume-token")

	rec := postJSON(t, srv.routes(), "/stun",
		`{"pod_uid":"`+uid+`","pod":"agent-arthur","namespace":"fe-signalloom-agents"}`, authHeader("freeze-token"))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}
	var res cgroup.FreezeResult
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if !res.Frozen || res.CgroupPath != dir {
		t.Errorf("result = %+v", res)
	}

	var ev map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(telem.String())), &ev); err != nil {
		t.Fatalf("telemetry line is not JSON: %q", telem.String())
	}
	if ev["event"] != telemetry.EventStunExecutionHalted {
		t.Errorf("event = %v, want %s", ev["event"], telemetry.EventStunExecutionHalted)
	}
	if ev["pod"] != "agent-arthur" || ev["namespace"] != "fe-signalloom-agents" {
		t.Errorf("pod identity missing from telemetry: %v", ev)
	}
}

// A freeze that cannot be proven must publish a failure event. A silent
// failure shows the control plane a contained agent that is still running.
func TestStunEmitsFailureEventWhenFreezeCannotBeProven(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, false) // never reports frozen 1
	srv, telem := newTestServer(t, root, "freeze-token", "resume-token")

	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, authHeader("freeze-token"))
	if rec.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want 504", rec.Code)
	}

	var ev map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(telem.String())), &ev); err != nil {
		t.Fatal(err)
	}
	if ev["event"] != telemetry.EventStunExecutionHaltFailed {
		t.Errorf("event = %v, want %s", ev["event"], telemetry.EventStunExecutionHaltFailed)
	}
	if ev["frozen"] != false {
		t.Errorf("frozen = %v, want false", ev["frozen"])
	}
}

func TestStunUnknownPodIs404(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"`+uid+`"}`, authHeader("freeze-token"))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestStunMalformedBodyIs400(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	if rec := postJSON(t, srv.routes(), "/stun", `{`, authHeader("freeze-token")); rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestStunTraversalPodUIDIs400(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	rec := postJSON(t, srv.routes(), "/stun", `{"pod_uid":"../../etc"}`, authHeader("freeze-token"))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestStunRejectsNonPost(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/stun", nil)
	req.Header.Set("Authorization", "Bearer freeze-token")
	srv.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rec.Code)
	}
}

func TestStunRefusesUnauthenticatedBeforeParsing(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "resume-token")
	rec := httptest.NewRecorder()
	srv.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/stun", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 — the gate must precede method and body checks", rec.Code)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// /resume
// ─────────────────────────────────────────────────────────────────────────────

func TestResumeRequiresGovernanceCredential(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, telem := newTestServer(t, root, "freeze-token", "governor-token")

	for _, hdr := range []map[string]string{
		nil,
		{},
		{"Authorization": "Bearer wrong"},
		{"Authorization": "Bearer "},
		{"Authorization": "wrong"},
		{"Authorization": "Bearer governor-tokenX"},
	} {
		rec := postJSON(t, srv.routes(), "/resume", `{"pod_uid":"`+uid+`"}`, hdr)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("headers %v: status = %d, want 401", hdr, rec.Code)
		}
	}
	if strings.Contains(telem.String(), telemetry.EventStunExecutionResumed) {
		t.Error("a refused resume published a Resumed event")
	}

	// The bare token without a Bearer prefix is accepted — TrimPrefix is a
	// no-op when the prefix is absent.
	rec := postJSON(t, srv.routes(), "/resume", `{"pod_uid":"`+uid+`"}`,
		map[string]string{"Authorization": "governor-token"})
	if rec.Code == http.StatusUnauthorized {
		t.Error("a valid bare token was refused; the refusals above may be testing header shape, not credentials")
	}
}

// Calling /resume with freeze token must be refused: distinct token scopes.
func TestResumeRefusesFreezeToken(t *testing.T) {
	root := t.TempDir()
	mockPodCgroup(t, root, true)
	srv, _ := newTestServer(t, root, "freeze-token", "governor-token")

	rec := postJSON(t, srv.routes(), "/resume", `{"pod_uid":"`+uid+`"}`, authHeader("freeze-token"))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 for cross-token resume attempt", rec.Code)
	}
}

func TestResumeWithValidCredentialThawsAndEmits(t *testing.T) {
	root := t.TempDir()
	dir := mockPodCgroup(t, root, false) // cgroup.events already reports frozen 0
	if err := os.WriteFile(filepath.Join(dir, "cgroup.freeze"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, telem := newTestServer(t, root, "freeze-token", "governor-token")

	rec := postJSON(t, srv.routes(), "/resume", `{"pod_uid":"`+uid+`"}`,
		map[string]string{"Authorization": "Bearer governor-token"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body)
	}

	body, err := os.ReadFile(filepath.Join(dir, "cgroup.freeze"))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "0" {
		t.Errorf("cgroup.freeze = %q, want \"0\"", body)
	}

	var ev map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(telem.String())), &ev); err != nil {
		t.Fatal(err)
	}
	if ev["event"] != telemetry.EventStunExecutionResumed || ev["frozen"] != false {
		t.Errorf("telemetry = %v", ev)
	}
}

func TestResumeMalformedBodyIs400(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "governor-token")
	if rec := postJSON(t, srv.routes(), "/resume", `nope`, authHeader("governor-token")); rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestResumeRejectsNonPost(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "governor-token")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/resume", nil)
	req.Header.Set("Authorization", "Bearer governor-token")
	srv.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rec.Code)
	}
}

func TestResumeRefusesUnauthenticatedBeforeParsing(t *testing.T) {
	srv, _ := newTestServer(t, t.TempDir(), "freeze-token", "governor-token")
	rec := httptest.NewRecorder()
	srv.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/resume", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401 — the gate must precede method and body checks", rec.Code)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Startup
// ─────────────────────────────────────────────────────────────────────────────

func TestRunRefusesWhenFreezeTokenUnsetOrEmpty(t *testing.T) {
	t.Setenv("STUN_FREEZE_TOKEN", "")
	t.Setenv("STUN_RESUME_TOKEN", "resume-token")

	err := run([]string{"--cgroup-root=" + t.TempDir(), "--listen-addr=127.0.0.1:0"})
	if err == nil {
		t.Fatal("run() started without STUN_FREEZE_TOKEN")
	}
	if !strings.Contains(err.Error(), "STUN_FREEZE_TOKEN is required") {
		t.Errorf("expected error mentioning STUN_FREEZE_TOKEN, got: %v", err)
	}
}

func TestRunRefusesWhenResumeTokenUnsetOrEmpty(t *testing.T) {
	t.Setenv("STUN_FREEZE_TOKEN", "freeze-token")
	t.Setenv("STUN_RESUME_TOKEN", "")

	err := run([]string{"--cgroup-root=" + t.TempDir(), "--listen-addr=127.0.0.1:0"})
	if err == nil {
		t.Fatal("run() started without STUN_RESUME_TOKEN")
	}
	if !strings.Contains(err.Error(), "STUN_RESUME_TOKEN is required") {
		t.Errorf("expected error mentioning STUN_RESUME_TOKEN, got: %v", err)
	}
}

func TestRunRefusesWhenFreezeAndResumeTokensAreEqual(t *testing.T) {
	t.Setenv("STUN_FREEZE_TOKEN", "shared-token")
	t.Setenv("STUN_RESUME_TOKEN", "shared-token")

	err := run([]string{"--cgroup-root=" + t.TempDir(), "--listen-addr=127.0.0.1:0"})
	if err == nil {
		t.Fatal("run() started with identical freeze and resume tokens")
	}
	if !strings.Contains(err.Error(), "distinct credentials") {
		t.Errorf("expected error mentioning distinct credentials, got: %v", err)
	}
}

// run() must refuse to start against a hierarchy it cannot write, so the
// misconfiguration surfaces at deploy time rather than during an incident.
func TestRunRefusesToStartOnUnwritableHierarchy(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: directory mode bits do not deny writes")
	}
	t.Setenv("STUN_FREEZE_TOKEN", "freeze-token")
	t.Setenv("STUN_RESUME_TOKEN", "resume-token")

	root := filepath.Join(t.TempDir(), "ro")
	if err := os.Mkdir(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })

	err := run([]string{"--cgroup-root=" + root, "--listen-addr=127.0.0.1:0"})
	if err == nil {
		t.Fatal("run() started against a read-only cgroup hierarchy")
	}
}

func TestRunPropagatesConfigError(t *testing.T) {
	if err := run([]string{"--nope"}); err == nil {
		t.Fatal("run() ignored a config error")
	}
}
