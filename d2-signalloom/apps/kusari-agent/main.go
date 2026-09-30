// kusari-agent is a stub Signal Loom swarm agent standing in for the Kusari
// pilot workload until real Kusari software is integrated.
//
// It exposes a small HTTP API:
//
//	GET /quote?input=<text>  fetch a quote from ZenQuotes (the same endpoint and
//	                         key handling the PAI status line uses) and echo the
//	                         input back; falls back to a bundled quote when the
//	                         API is unreachable or rate-limited.
//	GET /stats               request and hostile-write counters (ground truth).
//	GET /healthz             liveness.
//
//	POST /act/read-passwd    provocation: open(2) /etc/passwd from the request
//	                         thread, read it, hold the descriptor ACT_HOLD
//	                         (default 100ms) so an in-kernel openat probe sees
//	                         the live fd, and answer a JSON envelope
//	                         {"action":"read-passwd","ok":true,...}. The file
//	                         content is never returned.
//	POST /act/read-shadow    same, against /etc/shadow; reports attempted=true
//	                         even when the file is absent (distroless), because
//	                         the sys_enter_openat is the signal, not the bytes.
//	POST /act/cpu-burn       provocation: busy-loop ?threads=N (default
//	                         GOMAXPROCS) for ?duration=D (default 5s, clamped
//	                         to ACT_BURN_MAX, default 60s).
//
// The /act/* routes are the deliberate adversarial triggers the SLDC five-step
// containment suite (test/e2e-dual-cluster-containment.bats) fires.
//
// Every HOSTILE_EVERY-th request (default 5) also writes HOSTILE_PATH
// (default /tmp/hostile-test.txt) inside the container. That write is the
// known-hostile action runtime monitoring is expected to catch. It is never
// advertised in the /quote response; only the structured stdout log and
// /stats record it, so a detector has to observe it independently.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultPort         = "8080"
	defaultQuoteURL     = "https://zenquotes.io/api/random"
	defaultQuoteTimeout = 3 * time.Second
	// defaultQuoteCooldown: after an upstream failure, answer from the fallback
	// list without dialling for this long. Egress is default-deny in
	// fe-signalloom-agents, so without it every request would burn the full
	// quoteTimeout on a dropped SYN.
	defaultQuoteCooldown = 60 * time.Second
	defaultHostileEvery  = 5
	defaultHostilePath   = "/tmp/hostile-test.txt"

	// rateLimitAuthor is the author ZenQuotes returns on its keyless
	// rate-limit response ("Too many requests..."). The status line discards
	// those so a rate limit never clobbers a cached quote; so do we.
	rateLimitAuthor = "zenquotes.io"

	sourceUpstream = "zenquotes"
	sourceFallback = "fallback"

	maxUpstreamBody = 64 << 10

	defaultPasswdPath   = "/etc/passwd"
	defaultShadowPath   = "/etc/shadow"
	defaultActHold      = 100 * time.Millisecond
	defaultBurnDuration = 5 * time.Second
	defaultBurnMax      = 60 * time.Second
	maxBurnThreads      = 64
	maxActReadBytes     = 1 << 20
)

// fallbackQuotes keep the agent answering when egress is denied, which it is
// by default in fe-signalloom-agents.
var fallbackQuotes = []quote{
	{Text: "The universe is indifferent; the ritual is ours.", Author: "Straw Dogs, paraphrased"},
	{Text: "Simplicity is prerequisite for reliability.", Author: "Edsger W. Dijkstra"},
	{Text: "Trust, but verify.", Author: "Russian proverb"},
	{Text: "What gets measured gets managed.", Author: "Peter Drucker"},
	{Text: "Make it work, make it right, make it fast.", Author: "Kent Beck"},
}

type config struct {
	listenAddr    string
	quoteURL      string
	apiKey        string
	quoteTimeout  time.Duration
	quoteCooldown time.Duration
	hostileEvery  int64
	hostilePath   string

	// /act/* provocation settings
	passwdPath string
	shadowPath string
	actHold    time.Duration
	burnMax    time.Duration
}

func envOr(getenv func(string) string, key, fallback string) string {
	if v := getenv(key); v != "" {
		return v
	}
	return fallback
}

func configFromEnv(getenv func(string) string) (config, error) {
	cfg := config{
		listenAddr:    ":" + defaultPort,
		quoteURL:      envOr(getenv, "QUOTE_URL", defaultQuoteURL),
		apiKey:        getenv("ZENQUOTES_API_KEY"),
		quoteTimeout:  defaultQuoteTimeout,
		quoteCooldown: defaultQuoteCooldown,
		hostileEvery:  defaultHostileEvery,
		hostilePath:   envOr(getenv, "HOSTILE_PATH", defaultHostilePath),
		passwdPath:    defaultPasswdPath,
		shadowPath:    defaultShadowPath,
		actHold:       defaultActHold,
		burnMax:       defaultBurnMax,
	}
	if v := getenv("ACT_HOLD"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			return cfg, fmt.Errorf("ACT_HOLD must be a non-negative duration, got %q", v)
		}
		cfg.actHold = d
	}
	if v := getenv("ACT_BURN_MAX"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return cfg, fmt.Errorf("ACT_BURN_MAX must be a positive duration, got %q", v)
		}
		cfg.burnMax = d
	}
	if v := getenv("HOSTILE_EVERY"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return cfg, fmt.Errorf("HOSTILE_EVERY must be a non-negative integer, got %q", v)
		}
		cfg.hostileEvery = n
	}
	if v := getenv("QUOTE_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return cfg, fmt.Errorf("QUOTE_TIMEOUT must be a positive duration, got %q", v)
		}
		cfg.quoteTimeout = d
	}
	if v := getenv("QUOTE_COOLDOWN"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			return cfg, fmt.Errorf("QUOTE_COOLDOWN must be a non-negative duration, got %q", v)
		}
		cfg.quoteCooldown = d
	}
	if port := envOr(getenv, "PORT", defaultPort); port != defaultPort {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return cfg, fmt.Errorf("PORT must be an integer in 1..65535, got %q", port)
		}
		cfg.listenAddr = ":" + port
	}
	return cfg, nil
}

// sanitizeErr strips the request URL from transport errors so a keyed
// upstream URL (/random/{ZENQUOTES_API_KEY}) never reaches the log.
func sanitizeErr(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Op + ": " + ue.Err.Error()
	}
	return err.Error()
}

// upstreamURL mirrors the status line: keyless endpoint by default, keyed
// endpoint (/random/{key}) when ZENQUOTES_API_KEY is set.
func (c config) upstreamURL() string {
	if c.apiKey == "" {
		return c.quoteURL
	}
	return strings.TrimRight(c.quoteURL, "/") + "/" + c.apiKey
}

type quote struct {
	Text   string `json:"quote"`
	Author string `json:"author"`
	Source string `json:"source"`
}

type zenQuote struct {
	Q string `json:"q"`
	A string `json:"a"`
}

type quoteResponse struct {
	Input   string `json:"input"`
	Request int64  `json:"request"`
	quote
}

type statsResponse struct {
	Requests      int64  `json:"requests"`
	HostileWrites int64  `json:"hostile_writes"`
	HostileEvery  int64  `json:"hostile_every"`
	HostilePath   string `json:"hostile_path"`
}

type agent struct {
	cfg      config
	upstream string
	client   *http.Client
	now      func() time.Time
	hostname string

	logMu sync.Mutex
	logW  io.Writer

	requests      atomic.Int64
	hostileWrites atomic.Int64
	skipUntil     atomic.Int64 // unix nanos; upstream is not dialled before this
}

var errCoolingDown = errors.New("upstream cooling down after failure")

func newAgent(cfg config, logW io.Writer) *agent {
	host, _ := os.Hostname()
	return &agent{
		cfg:      cfg,
		upstream: cfg.upstreamURL(),
		client:   &http.Client{Timeout: cfg.quoteTimeout},
		now:      time.Now,
		hostname: host,
		logW:     logW,
	}
}

// logEvent writes one JSON line per event so log shippers and the runbook can
// grep for event=hostile_write without parsing free text.
func (a *agent) logEvent(event string, fields map[string]any) {
	rec := map[string]any{
		"ts":    a.now().UTC().Format(time.RFC3339Nano),
		"agent": "kusari-agent",
		"event": event,
	}
	for k, v := range fields {
		rec[k] = v
	}
	b, err := json.Marshal(rec)
	if err != nil {
		return
	}
	a.logMu.Lock()
	defer a.logMu.Unlock()
	_, _ = a.logW.Write(append(b, '\n'))
}

func (a *agent) fetchQuote(ctx context.Context) (quote, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.upstream, nil)
	if err != nil {
		return quote{}, err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return quote{}, err
	}
	defer resp.Body.Close()
	body := io.LimitReader(resp.Body, maxUpstreamBody)
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, body) // drain so the keep-alive connection is reused
		return quote{}, fmt.Errorf("upstream status %d", resp.StatusCode)
	}
	var zq []zenQuote
	if err := json.NewDecoder(body).Decode(&zq); err != nil {
		return quote{}, fmt.Errorf("decode upstream: %w", err)
	}
	if len(zq) == 0 || zq[0].Q == "" {
		return quote{}, errors.New("upstream returned no quote")
	}
	if zq[0].A == rateLimitAuthor {
		return quote{}, errors.New("upstream rate-limited")
	}
	return quote{Text: zq[0].Q, Author: zq[0].A, Source: sourceUpstream}, nil
}

// quoteOrFallback dials upstream unless a recent failure put it in cooldown.
// The returned error is nil on upstream success; otherwise it explains why the
// fallback quote was served.
func (a *agent) quoteOrFallback(ctx context.Context, n int64) (quote, error) {
	now := a.now()
	if now.UnixNano() < a.skipUntil.Load() {
		return fallbackQuote(n), errCoolingDown
	}
	q, err := a.fetchQuote(ctx)
	if err != nil {
		if a.cfg.quoteCooldown > 0 {
			a.skipUntil.Store(now.Add(a.cfg.quoteCooldown).UnixNano())
		}
		return fallbackQuote(n), err
	}
	return q, nil
}

func fallbackQuote(n int64) quote {
	q := fallbackQuotes[int((n-1)%int64(len(fallbackQuotes)))]
	q.Source = sourceFallback
	return q
}

// maybeHostile performs the deliberate hostile action on every Nth request.
// Deterministic (not random) so five requests always yield exactly one write.
func (a *agent) maybeHostile(n int64) bool {
	if a.cfg.hostileEvery <= 0 || n%a.cfg.hostileEvery != 0 {
		return false
	}
	content := fmt.Sprintf("kusari-agent hostile-test\nrequest=%d\ntime=%s\nhost=%s\n",
		n, a.now().UTC().Format(time.RFC3339), a.hostname)
	err := os.WriteFile(a.cfg.hostilePath, []byte(content), 0o644)
	fields := map[string]any{"request": n, "path": a.cfg.hostilePath}
	if err != nil {
		fields["error"] = err.Error()
		a.logEvent("hostile_write_failed", fields)
		return false
	}
	a.hostileWrites.Add(1)
	a.logEvent("hostile_write", fields)
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (a *agent) handleQuote(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET only"})
		return
	}
	n := a.requests.Add(1)
	input := r.URL.Query().Get("input")

	q, err := a.quoteOrFallback(r.Context(), n)
	if err != nil {
		a.logEvent("quote_fallback", map[string]any{"request": n, "reason": sanitizeErr(err)})
	}
	a.maybeHostile(n)
	a.logEvent("quote", map[string]any{"request": n, "source": q.Source, "input_len": len(input)})

	writeJSON(w, http.StatusOK, quoteResponse{Input: input, Request: n, quote: q})
}

func (a *agent) handleStats(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, statsResponse{
		Requests:      a.requests.Load(),
		HostileWrites: a.hostileWrites.Load(),
		HostileEvery:  a.cfg.hostileEvery,
		HostilePath:   a.cfg.hostilePath,
	})
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// actResult is the envelope every /act/* route answers with. action and ok are
// always present; the remaining fields describe what was done.
type actResult struct {
	Action     string `json:"action"`
	OK         bool   `json:"ok"`
	Error      string `json:"error,omitempty"`
	Path       string `json:"path,omitempty"`
	Attempted  bool   `json:"attempted,omitempty"`
	Bytes      int    `json:"bytes,omitempty"`
	Lines      int    `json:"lines,omitempty"`
	HeldMS     int64  `json:"held_ms,omitempty"`
	PID        int    `json:"pid"`
	TID        int    `json:"tid,omitempty"`
	Threads    int    `json:"threads,omitempty"`
	DurationMS int64  `json:"duration_ms,omitempty"`
	Iterations uint64 `json:"iterations,omitempty"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at"`
}

func (a *agent) postOnly(action string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeJSON(w, http.StatusMethodNotAllowed, actResult{Action: action, Error: "POST only", PID: os.Getpid()})
			return
		}
		h(w, r)
	}
}

// readAndHold opens path directly from the calling OS thread (so the openat is
// attributed to the traced thread, not a helper that exits before a probe can
// correlate it), reads up to maxActReadBytes, and keeps the descriptor open for
// hold. The content is counted, never returned.
func (a *agent) readAndHold(action, path string) (actResult, int) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	res := actResult{Action: action, Path: path, Attempted: true, PID: os.Getpid(), TID: syscall.Gettid()}
	start := a.now()
	res.StartedAt = start.UTC().Format(time.RFC3339Nano)
	status := http.StatusOK
	f, err := os.Open(path)
	if err != nil {
		res.Error = err.Error()
		if action == "read-passwd" {
			status = http.StatusInternalServerError
		}
	} else {
		data, rerr := io.ReadAll(io.LimitReader(f, maxActReadBytes))
		held := time.Now()
		if a.cfg.actHold > 0 {
			time.Sleep(a.cfg.actHold)
		}
		res.HeldMS = time.Since(held).Milliseconds()
		_ = f.Close()
		if rerr != nil {
			res.Error = rerr.Error()
			status = http.StatusInternalServerError
		} else {
			res.OK = true
			res.Bytes = len(data)
			res.Lines = strings.Count(string(data), "\n")
		}
	}
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{"action": action, "path": path, "ok": res.OK, "tid": res.TID, "error": res.Error})
	return res, status
}

func (a *agent) handleReadPasswd(w http.ResponseWriter, _ *http.Request) {
	res, status := a.readAndHold("read-passwd", a.cfg.passwdPath)
	writeJSON(w, status, res)
}

func (a *agent) handleReadShadow(w http.ResponseWriter, _ *http.Request) {
	res, status := a.readAndHold("read-shadow", a.cfg.shadowPath)
	writeJSON(w, status, res)
}

// handleCPUBurn busy-loops threads goroutines, each locked to its own OS thread,
// for the requested duration. It answers only when the burn is over.
func (a *agent) handleCPUBurn(w http.ResponseWriter, r *http.Request) {
	res := actResult{Action: "cpu-burn", PID: os.Getpid()}
	q := r.URL.Query()
	d := defaultBurnDuration
	if v := q.Get("duration"); v != "" {
		pd, err := time.ParseDuration(v)
		if err != nil || pd <= 0 {
			res.Error = fmt.Sprintf("duration must be a positive Go duration, got %q", v)
			writeJSON(w, http.StatusBadRequest, res)
			return
		}
		d = pd
	}
	if d > a.cfg.burnMax {
		d = a.cfg.burnMax
	}
	threads := runtime.GOMAXPROCS(0)
	if v := q.Get("threads"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > maxBurnThreads {
			res.Error = fmt.Sprintf("threads must be an integer in 1..%d, got %q", maxBurnThreads, v)
			writeJSON(w, http.StatusBadRequest, res)
			return
		}
		threads = n
	}
	res.StartedAt = a.now().UTC().Format(time.RFC3339Nano)
	deadline := time.Now().Add(d)
	var iterations atomic.Uint64
	var wg sync.WaitGroup
	for i := 0; i < threads; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			var n uint64
			for time.Now().Before(deadline) {
				for j := 0; j < 4096; j++ {
					n++
				}
			}
			iterations.Add(n)
		}()
	}
	wg.Wait()
	res.OK = true
	res.Threads = threads
	res.DurationMS = d.Milliseconds()
	res.Iterations = iterations.Load()
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{"action": "cpu-burn", "threads": threads, "duration_ms": res.DurationMS})
	writeJSON(w, http.StatusOK, res)
}

func (a *agent) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", a.handleQuote)
	mux.HandleFunc("/{$}", a.handleQuote)
	mux.HandleFunc("/stats", a.handleStats)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/act/read-passwd", a.postOnly("read-passwd", a.handleReadPasswd))
	mux.HandleFunc("/act/read-shadow", a.postOnly("read-shadow", a.handleReadShadow))
	mux.HandleFunc("/act/cpu-burn", a.postOnly("cpu-burn", a.handleCPUBurn))
	return mux
}

func run(ctx context.Context, cfg config, logW io.Writer) error {
	a := newAgent(cfg, logW)
	srv := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	a.logEvent("start", map[string]any{
		"listen": cfg.listenAddr, "upstream": cfg.quoteURL, "keyed": cfg.apiKey != "",
		"cooldown":      cfg.quoteCooldown.String(),
		"hostile_every": cfg.hostileEvery, "hostile_path": cfg.hostilePath,
	})
	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	}
}

func main() {
	cfg, err := configFromEnv(os.Getenv)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kusari-agent:", err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, cfg, os.Stdout); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, "kusari-agent:", err)
		os.Exit(1)
	}
}
