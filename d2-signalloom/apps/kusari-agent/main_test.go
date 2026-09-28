package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const goodBody = `[{"q":"Be water, my friend.","a":"Bruce Lee"}]`

func envFrom(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func upstream(t *testing.T, body string, status int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func testAgent(t *testing.T, quoteURL string, hostileEvery int64) (*agent, *bytes.Buffer) {
	t.Helper()
	cfg := config{
		quoteURL:     quoteURL,
		quoteTimeout: 2 * time.Second,
		hostileEvery: hostileEvery,
		hostilePath:  filepath.Join(t.TempDir(), "hostile-test.txt"),
	}
	logs := &bytes.Buffer{}
	a := newAgent(cfg, logs)
	a.now = func() time.Time { return time.Date(2026, 9, 28, 9, 0, 0, 0, time.UTC) }
	return a, logs
}

func get(t *testing.T, h http.Handler, target string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
	var body map[string]any
	if rec.Body.Len() > 0 && strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") {
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode %s: %v: %s", target, err, rec.Body.String())
		}
	}
	return rec, body
}

func TestQuoteFromUpstreamEchoesInput(t *testing.T) {
	a, _ := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 5)

	rec, body := get(t, a.routes(), "/quote?input=hello")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if body["quote"] != "Be water, my friend." || body["author"] != "Bruce Lee" {
		t.Fatalf("unexpected quote payload: %v", body)
	}
	if body["input"] != "hello" {
		t.Fatalf("input not echoed: %v", body["input"])
	}
	if body["source"] != sourceUpstream {
		t.Fatalf("source = %v, want %s", body["source"], sourceUpstream)
	}
}

func TestRootRoutesToQuote(t *testing.T) {
	a, _ := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 0)
	rec, body := get(t, a.routes(), "/?input=x")
	if rec.Code != http.StatusOK || body["quote"] != "Be water, my friend." {
		t.Fatalf("root did not serve a quote: %d %v", rec.Code, body)
	}
}

func TestConfigFromEnv(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want config
	}{
		{
			name: "defaults",
			env:  map[string]string{},
			want: config{listenAddr: ":8080", quoteURL: defaultQuoteURL, quoteTimeout: 3 * time.Second,
				quoteCooldown: time.Minute, hostileEvery: 5, hostilePath: "/tmp/hostile-test.txt"},
		},
		{
			name: "keyed upstream",
			env:  map[string]string{"ZENQUOTES_API_KEY": "abc123"},
			want: config{listenAddr: ":8080", quoteURL: defaultQuoteURL, apiKey: "abc123", quoteTimeout: 3 * time.Second,
				quoteCooldown: time.Minute, hostileEvery: 5, hostilePath: "/tmp/hostile-test.txt"},
		},
		{
			name: "overrides",
			env: map[string]string{"PORT": "9090", "QUOTE_URL": "http://q.local/api", "QUOTE_TIMEOUT": "500ms",
				"QUOTE_COOLDOWN": "0", "HOSTILE_EVERY": "3", "HOSTILE_PATH": "/tmp/elsewhere.txt"},
			want: config{listenAddr: ":9090", quoteURL: "http://q.local/api", quoteTimeout: 500 * time.Millisecond,
				quoteCooldown: 0, hostileEvery: 3, hostilePath: "/tmp/elsewhere.txt"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := configFromEnv(envFrom(tc.env))
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("config = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestUpstreamURL(t *testing.T) {
	if got := (config{quoteURL: defaultQuoteURL}).upstreamURL(); got != defaultQuoteURL {
		t.Fatalf("keyless URL = %s", got)
	}
	if got := (config{quoteURL: defaultQuoteURL + "/", apiKey: "abc123"}).upstreamURL(); got != defaultQuoteURL+"/abc123" {
		t.Fatalf("keyed URL = %s", got)
	}
}

func TestConfigRejectsBadValues(t *testing.T) {
	for _, env := range []map[string]string{
		{"HOSTILE_EVERY": "-1"}, {"HOSTILE_EVERY": "five"}, {"HOSTILE_EVERY": "1.5"},
		{"QUOTE_TIMEOUT": "0"}, {"QUOTE_TIMEOUT": "soon"}, {"QUOTE_COOLDOWN": "-1s"},
		{"PORT": "0.0.0.0:8080"}, {"PORT": "http"}, {"PORT": "0"}, {"PORT": "70000"},
	} {
		if _, err := configFromEnv(envFrom(env)); err == nil {
			t.Fatalf("%v accepted", env)
		}
	}
}

// Anything but a clean 200 with a real quote falls back to a bundled quote and
// still answers 200 with the input echoed.
func TestQuoteFallsBack(t *testing.T) {
	cases := []struct {
		name  string
		url   func(t *testing.T) string
		check func(t *testing.T, body map[string]any, logs *bytes.Buffer)
	}{
		{
			name: "rate-limited author",
			url: func(t *testing.T) string {
				return upstream(t, `[{"q":"Too many requests. Obtain an auth key for unlimited access.","a":"zenquotes.io"}]`, http.StatusOK).URL
			},
			check: func(t *testing.T, body map[string]any, logs *bytes.Buffer) {
				if body["author"] == rateLimitAuthor {
					t.Fatalf("rate-limit author leaked into response")
				}
				if !strings.Contains(logs.String(), `"event":"quote_fallback"`) {
					t.Fatalf("no quote_fallback log line: %s", logs.String())
				}
			},
		},
		{
			name: "upstream down",
			url: func(t *testing.T) string {
				srv := httptest.NewServer(http.NotFoundHandler())
				srv.Close()
				return srv.URL
			},
		},
		{
			name: "upstream non-200",
			url:  func(t *testing.T) string { return upstream(t, "oops", http.StatusBadGateway).URL },
		},
		{
			name: "empty upstream array",
			url:  func(t *testing.T) string { return upstream(t, "[]", http.StatusOK).URL },
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a, logs := testAgent(t, tc.url(t), 0)
			rec, body := get(t, a.routes(), "/quote?input=offline")
			if rec.Code != http.StatusOK {
				t.Fatalf("status %d, want 200", rec.Code)
			}
			if body["source"] != sourceFallback || body["quote"] == "" {
				t.Fatalf("expected a fallback quote, got %v", body)
			}
			if body["input"] != "offline" {
				t.Fatalf("input not echoed on fallback path")
			}
			if tc.check != nil {
				tc.check(t, body, logs)
			}
		})
	}
}

func TestCooldownSkipsUpstreamAfterFailure(t *testing.T) {
	var dials atomic.Int32
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		dials.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	}))
	t.Cleanup(up.Close)
	a, logs := testAgent(t, up.URL, 0)
	a.cfg.quoteCooldown = time.Minute
	h := a.routes()

	base := a.now()
	get(t, h, "/quote")
	get(t, h, "/quote")
	if got := dials.Load(); got != 1 {
		t.Fatalf("upstream dialled %d times inside cooldown, want 1", got)
	}
	if !strings.Contains(logs.String(), errCoolingDown.Error()) {
		t.Fatalf("second request did not log the cooldown reason: %s", logs.String())
	}
	a.now = func() time.Time { return base.Add(2 * time.Minute) }
	get(t, h, "/quote")
	if got := dials.Load(); got != 2 {
		t.Fatalf("upstream not re-dialled after cooldown expired, dials=%d", got)
	}
}

func TestCooldownZeroDialsEveryTime(t *testing.T) {
	var dials atomic.Int32
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		dials.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	}))
	t.Cleanup(up.Close)
	a, _ := testAgent(t, up.URL, 0)
	h := a.routes()
	for i := 0; i < 3; i++ {
		get(t, h, "/quote")
	}
	if got := dials.Load(); got != 3 {
		t.Fatalf("QUOTE_COOLDOWN=0 should dial every request, dials=%d", got)
	}
}

func TestFallbackLogNeverContainsAPIKey(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	srv.Close() // upstream down: the transport error carries the full URL
	const key = "sekrit-key-123"
	cfg := config{quoteURL: srv.URL, apiKey: key, quoteTimeout: time.Second,
		hostilePath: filepath.Join(t.TempDir(), "h.txt")}
	logs := &bytes.Buffer{}
	a := newAgent(cfg, logs)
	get(t, a.routes(), "/quote")
	if strings.Contains(logs.String(), key) {
		t.Fatalf("API key leaked into logs: %s", logs.String())
	}
	if !strings.Contains(logs.String(), `"event":"quote_fallback"`) {
		t.Fatalf("expected a quote_fallback line: %s", logs.String())
	}
}

func TestHostileWriteOnExactlyFifthRequest(t *testing.T) {
	a, logs := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 5)
	h := a.routes()

	for i := 1; i <= 4; i++ {
		get(t, h, "/quote")
		if _, err := os.Stat(a.cfg.hostilePath); err == nil {
			t.Fatalf("hostile file exists after request %d", i)
		}
	}
	get(t, h, "/quote")
	raw, err := os.ReadFile(a.cfg.hostilePath)
	if err != nil {
		t.Fatalf("hostile file missing after 5th request: %v", err)
	}
	content := string(raw)
	if !strings.Contains(content, "request=5") {
		t.Fatalf("hostile file lacks request number: %q", content)
	}
	if !strings.Contains(content, "time=2026-09-28T09:00:00Z") {
		t.Fatalf("hostile file lacks timestamp: %q", content)
	}
	if !strings.Contains(logs.String(), `"event":"hostile_write"`) {
		t.Fatalf("no hostile_write log line: %s", logs.String())
	}

	for i := 6; i <= 10; i++ {
		get(t, h, "/quote")
	}
	_, stats := get(t, h, "/stats")
	if stats["requests"].(float64) != 10 || stats["hostile_writes"].(float64) != 2 {
		t.Fatalf("stats after 10 requests = %v, want requests=10 hostile_writes=2", stats)
	}
}

func TestHostileDisabledWhenZero(t *testing.T) {
	a, logs := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 0)
	h := a.routes()
	for i := 0; i < 10; i++ {
		get(t, h, "/quote")
	}
	if _, err := os.Stat(a.cfg.hostilePath); err == nil {
		t.Fatalf("hostile file written with HOSTILE_EVERY=0")
	}
	if strings.Contains(logs.String(), "hostile_write") {
		t.Fatalf("hostile log emitted with HOSTILE_EVERY=0")
	}
}

func TestQuoteResponseNeverAdvertisesHostileWrite(t *testing.T) {
	a, _ := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 1) // every request is hostile
	rec, body := get(t, a.routes(), "/quote")
	for k := range body {
		if strings.Contains(strings.ToLower(k), "hostile") {
			t.Fatalf("response leaks hostile indicator field %q: %s", k, rec.Body.String())
		}
	}
	if _, err := os.Stat(a.cfg.hostilePath); err != nil {
		t.Fatalf("hostile write did not happen with HOSTILE_EVERY=1: %v", err)
	}
}

func TestHostileLogLineIsStructuredJSON(t *testing.T) {
	a, logs := testAgent(t, upstream(t, goodBody, http.StatusOK).URL, 1)
	get(t, a.routes(), "/quote")
	var found bool
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line is not JSON: %q", line)
		}
		if rec["event"] == "hostile_write" {
			found = true
			if rec["path"] != a.cfg.hostilePath || rec["request"].(float64) != 1 || rec["agent"] != "kusari-agent" {
				t.Fatalf("hostile_write log missing fields: %v", rec)
			}
		}
	}
	if !found {
		t.Fatalf("no hostile_write event in logs: %s", logs.String())
	}
}

func TestStatsEndpoint(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	rec, body := get(t, a.routes(), "/stats")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	for _, k := range []string{"requests", "hostile_writes", "hostile_every", "hostile_path"} {
		if _, ok := body[k]; !ok {
			t.Fatalf("stats missing %q: %v", k, body)
		}
	}
}

func TestHealthz(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	rec, body := get(t, a.routes(), "/healthz")
	if rec.Code != http.StatusOK || body["status"] != "ok" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}
}

func TestQuoteRejectsNonGet(t *testing.T) {
	a, _ := testAgent(t, "http://127.0.0.1:1", 5)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/quote", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /quote = %d, want 405", rec.Code)
	}
	if a.requests.Load() != 0 {
		t.Fatalf("rejected request counted towards hostile cadence")
	}
}
