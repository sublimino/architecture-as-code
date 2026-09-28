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

func (a *agent) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", a.handleQuote)
	mux.HandleFunc("/{$}", a.handleQuote)
	mux.HandleFunc("/stats", a.handleStats)
	mux.HandleFunc("/healthz", handleHealthz)
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
