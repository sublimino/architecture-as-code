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
//	     ?defer=D            on either read: answer 202 at once with the order
//	                         (pod, scheduled_for) and open D later (0 < D <=
//	                         10s). A sentinel freezes the stub ~1 ms after the
//	                         openat, inside the request, so only an answer
//	                         given BEFORE the act can reach the caller.
//	POST /act/cpu-burn       provocation: busy-loop ?threads=N (default
//	                         GOMAXPROCS) for ?duration=D (default 5s, clamped
//	                         to ACT_BURN_MAX, default 60s).
//	POST /act/gpu-open       provocation: openat(2) a GPU control device (default
//	                         /dev/nvidiactl, GPU_DEVICE_PATH) read-only and hold
//	                         the fd like read-passwd does. ?write=1 opens it
//	                         O_RDWR (falling back to O_WRONLY) to signal WRITE
//	                         INTENT and reports write_mode:true. attempted=true
//	                         even when the device node is absent (distroless) —
//	                         the openat is the signal; device bytes are never
//	                         returned.
//	POST /act/gpu-probe      provocation: stat+open each of the NVIDIA discovery
//	                         set (/dev/nvidiactl, /dev/nvidia-uvm, /dev/nvidia0,
//	                         /proc/driver/nvidia/version, /proc/driver/nvidia/gpus)
//	                         on one traced thread and report how many exist
//	                         (count + the paths touched). GPU-mount discovery.
//	POST /act/exfil          provocation: TCP-dial a paste service (default
//	                         pastebin.com:443, EXFIL_TARGET) with a short,
//	                         overridable timeout (ACT_DIAL_TIMEOUT). The outbound
//	                         connect attempt is the signal, so a refused or
//	                         timed-out dial is still ok=true. No data is uploaded.
//	POST /act/kube-enum      provocation: open the service-account token (default
//	                         /var/run/secrets/kubernetes.io/serviceaccount/token,
//	                         SA_TOKEN_PATH) and record whether it was readable and
//	                         its byte length (never the token value), then TCP-dial
//	                         the in-cluster apiserver (default
//	                         kubernetes.default.svc:443, KUBE_API_TARGET).
//	POST /act/recon          provocation: open each of a container-escape recon
//	                         set (/proc/1/root, /proc/sys/kernel/core_pattern,
//	                         /proc/self/environ, /etc/kubernetes/admin.conf,
//	                         /etc/shadow) on one traced thread and report how many
//	                         were openable (count + list). Contents are never
//	                         returned.
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
	"net"
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
	maxActDefer         = 10 * time.Second

	// Additional /act/* provocation defaults. Each target/path is overridable
	// via the env var named alongside it so tests can point at local fixtures
	// and the SLDC suite can retarget without a rebuild.
	defaultGPUDevicePath = "/dev/nvidiactl"                                      // GPU_DEVICE_PATH
	defaultExfilTarget   = "pastebin.com:443"                                    // EXFIL_TARGET
	defaultSATokenPath   = "/var/run/secrets/kubernetes.io/serviceaccount/token" // SA_TOKEN_PATH
	defaultKubeAPITarget = "kubernetes.default.svc:443"                          // KUBE_API_TARGET
	defaultDialTimeout   = 2 * time.Second                                       // ACT_DIAL_TIMEOUT
)

// defaultGPUProbePaths is the NVIDIA mount-discovery set /act/gpu-probe walks.
var defaultGPUProbePaths = []string{
	"/dev/nvidiactl",
	"/dev/nvidia-uvm",
	"/dev/nvidia0",
	"/proc/driver/nvidia/version",
	"/proc/driver/nvidia/gpus",
}

// defaultReconPaths is the container-escape recon set /act/recon walks.
var defaultReconPaths = []string{
	"/proc/1/root",
	"/proc/sys/kernel/core_pattern",
	"/proc/self/environ",
	"/etc/kubernetes/admin.conf",
	"/etc/shadow",
}

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

	// additional /act/* provocation settings (scalars only, so config stays
	// comparable with ==; the gpu-probe/recon path sets live on the agent)
	gpuDevicePath string
	exfilTarget   string
	saTokenPath   string
	kubeAPITarget string
	dialTimeout   time.Duration
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
		gpuDevicePath: envOr(getenv, "GPU_DEVICE_PATH", defaultGPUDevicePath),
		exfilTarget:   envOr(getenv, "EXFIL_TARGET", defaultExfilTarget),
		saTokenPath:   envOr(getenv, "SA_TOKEN_PATH", defaultSATokenPath),
		kubeAPITarget: envOr(getenv, "KUBE_API_TARGET", defaultKubeAPITarget),
		dialTimeout:   defaultDialTimeout,
	}
	if v := getenv("ACT_DIAL_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return cfg, fmt.Errorf("ACT_DIAL_TIMEOUT must be a positive duration, got %q", v)
		}
		cfg.dialTimeout = d
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
	// per-provocation counters, same ground-truth role as hostile_writes
	GPUOpens  int64 `json:"gpu_opens"`
	GPUProbes int64 `json:"gpu_probes"`
	Exfils    int64 `json:"exfils"`
	KubeEnums int64 `json:"kube_enums"`
	Recons    int64 `json:"recons"`
}

type agent struct {
	cfg      config
	upstream string
	client   *http.Client
	now      func() time.Time
	hostname string

	logMu sync.Mutex
	logW  io.Writer

	// gpu-probe/recon discovery sets; seeded from the package defaults so tests
	// can point them at fixtures without mutating package state.
	gpuProbePaths []string
	reconPaths    []string

	requests      atomic.Int64
	hostileWrites atomic.Int64
	skipUntil     atomic.Int64 // unix nanos; upstream is not dialled before this

	gpuOpens  atomic.Int64
	gpuProbes atomic.Int64
	exfils    atomic.Int64
	kubeEnums atomic.Int64
	recons    atomic.Int64
}

var errCoolingDown = errors.New("upstream cooling down after failure")

func newAgent(cfg config, logW io.Writer) *agent {
	host, _ := os.Hostname()
	return &agent{
		cfg:           cfg,
		upstream:      cfg.upstreamURL(),
		client:        &http.Client{Timeout: cfg.quoteTimeout},
		now:           time.Now,
		hostname:      host,
		logW:          logW,
		gpuProbePaths: append([]string(nil), defaultGPUProbePaths...),
		reconPaths:    append([]string(nil), defaultReconPaths...),
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

// getOnly refuses every method but GET with 405 and an Allow header.
func getOnly(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET only"})
			return
		}
		h(w, r)
	}
}

func (a *agent) handleQuote(w http.ResponseWriter, r *http.Request) {
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
		GPUOpens:      a.gpuOpens.Load(),
		GPUProbes:     a.gpuProbes.Load(),
		Exfils:        a.exfils.Load(),
		KubeEnums:     a.kubeEnums.Load(),
		Recons:        a.recons.Load(),
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
	// A deferred read (?defer=D) answers with the order, not the result.
	Scheduled    bool   `json:"scheduled,omitempty"`
	DeferMS      int64  `json:"defer_ms,omitempty"`
	ScheduledFor string `json:"scheduled_for,omitempty"`
	Pod          string `json:"pod,omitempty"`
	StartedAt    string `json:"started_at"`
	FinishedAt   string `json:"finished_at"`

	// gpu-open: whether the device was opened for write (WRITE INTENT signal).
	WriteMode bool `json:"write_mode,omitempty"`

	// gpu-probe / recon: how many paths were touched and how many were openable,
	// with the per-path outcomes. Contents are never read into the envelope.
	Count  int          `json:"count,omitempty"`
	Found  int          `json:"found,omitempty"`
	Probes []probeEntry `json:"probes,omitempty"`

	// exfil / kube-enum: the outbound TCP dial outcome.
	Host        string `json:"host,omitempty"`         // the dial target (host:port)
	Address     string `json:"address,omitempty"`      // resolved addr on success, attempted target otherwise
	Connected   bool   `json:"connected,omitempty"`    // true only when the TCP connect succeeded
	DialOutcome string `json:"dial_outcome,omitempty"` // connected | refused | timeout | error
	DialError   string `json:"dial_error,omitempty"`

	// kube-enum: the service-account token read outcome. The token value is
	// never recorded — only whether it was readable and how many bytes it was.
	TokenPath     string `json:"token_path,omitempty"`
	TokenReadable bool   `json:"token_readable,omitempty"`
	TokenBytes    int    `json:"token_bytes,omitempty"`
}

// probeEntry is one path visited by /act/gpu-probe or /act/recon. It carries the
// discovery signal (did it exist, could it be opened) but never any contents.
type probeEntry struct {
	Path     string `json:"path"`
	Exists   bool   `json:"exists"`
	Openable bool   `json:"openable,omitempty"`
	Error    string `json:"error,omitempty"`
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

func (a *agent) handleReadPasswd(w http.ResponseWriter, r *http.Request) {
	a.readAct(w, r, "read-passwd", a.cfg.passwdPath)
}

func (a *agent) handleReadShadow(w http.ResponseWriter, r *http.Request) {
	a.readAct(w, r, "read-shadow", a.cfg.shadowPath)
}

// readAct performs a read provocation now, answering with its result, or with
// ?defer=D answers 202 with the order and performs it D later.
func (a *agent) readAct(w http.ResponseWriter, r *http.Request, action, path string) {
	v := r.URL.Query().Get("defer")
	if v == "" {
		res, status := a.readAndHold(action, path)
		writeJSON(w, status, res)
		return
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 || d > maxActDefer {
		writeJSON(w, http.StatusBadRequest, actResult{Action: action, PID: os.Getpid(),
			Error: fmt.Sprintf("defer must be a Go duration in (0, %s], got %q", maxActDefer, v)})
		return
	}
	now := a.now()
	res := actResult{
		Action: action, OK: true, Scheduled: true, Path: path, Pod: a.hostname, PID: os.Getpid(),
		DeferMS: d.Milliseconds(), StartedAt: now.UTC().Format(time.RFC3339Nano),
		ScheduledFor: now.Add(d).UTC().Format(time.RFC3339Nano),
	}
	res.FinishedAt = res.StartedAt
	a.logEvent("act_scheduled", map[string]any{"action": action, "path": path, "defer_ms": res.DeferMS, "scheduled_for": res.ScheduledFor})
	writeJSON(w, http.StatusAccepted, res)
	go func() {
		time.Sleep(d)
		a.readAndHold(action, path) // locks its own OS thread
	}()
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

// handleGPUOpen opens a GPU control device and holds the descriptor, like
// readAndHold, but never reads it. ?write=1 opens it for write to signal intent.
func (a *agent) handleGPUOpen(w http.ResponseWriter, r *http.Request) {
	a.gpuOpens.Add(1)
	write := r.URL.Query().Get("write") == "1"
	res := a.openAndHoldDevice("gpu-open", a.cfg.gpuDevicePath, write)
	writeJSON(w, http.StatusOK, res)
}

// openAndHoldDevice opens path from the calling OS thread (so the openat is
// attributed to the traced thread) and holds the descriptor for actHold. With
// write set it opens O_RDWR, falling back to O_WRONLY, to signal write intent.
// The openat is the signal: attempted is always true, even when the node is
// absent (distroless), and the device is never read.
func (a *agent) openAndHoldDevice(action, path string, write bool) actResult {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	res := actResult{
		Action: action, Path: path, Attempted: true, WriteMode: write,
		PID: os.Getpid(), TID: syscall.Gettid(),
	}
	res.StartedAt = a.now().UTC().Format(time.RFC3339Nano)

	var (
		f   *os.File
		err error
	)
	if write {
		if f, err = os.OpenFile(path, os.O_RDWR, 0); err != nil {
			// A control node may reject O_RDWR but allow O_WRONLY; either way the
			// openat with a write flag is the write-intent signal we want traced.
			f, err = os.OpenFile(path, os.O_WRONLY, 0)
		}
	} else {
		f, err = os.OpenFile(path, os.O_RDONLY, 0)
	}
	if err != nil {
		res.Error = err.Error()
	} else {
		held := time.Now()
		if a.cfg.actHold > 0 {
			time.Sleep(a.cfg.actHold)
		}
		res.HeldMS = time.Since(held).Milliseconds()
		_ = f.Close()
		res.OK = true
	}
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{
		"action": action, "path": path, "write_mode": write,
		"ok": res.OK, "tid": res.TID, "error": res.Error,
	})
	return res
}

func (a *agent) handleGPUProbe(w http.ResponseWriter, _ *http.Request) {
	a.gpuProbes.Add(1)
	writeJSON(w, http.StatusOK, a.probePaths("gpu-probe", a.gpuProbePaths))
}

func (a *agent) handleRecon(w http.ResponseWriter, _ *http.Request) {
	a.recons.Add(1)
	writeJSON(w, http.StatusOK, a.probePaths("recon", a.reconPaths))
}

// probePaths stats and opens every path in the set on a single traced OS thread
// so each openat can be attributed, and reports how many were openable. Found
// counts the openable paths; Count is the number touched. Contents are never
// read into the envelope.
func (a *agent) probePaths(action string, paths []string) actResult {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	res := actResult{
		Action: action, Attempted: true, OK: true,
		PID: os.Getpid(), TID: syscall.Gettid(),
	}
	res.StartedAt = a.now().UTC().Format(time.RFC3339Nano)
	for _, p := range paths {
		entry := probeEntry{Path: p}
		if _, serr := os.Stat(p); serr == nil {
			entry.Exists = true
		}
		if f, oerr := os.Open(p); oerr == nil {
			entry.Openable = true
			res.Found++
			_ = f.Close()
		} else {
			entry.Error = oerr.Error()
		}
		res.Probes = append(res.Probes, entry)
	}
	res.Count = len(paths)
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{
		"action": action, "count": res.Count, "found": res.Found, "tid": res.TID,
	})
	return res
}

func (a *agent) handleExfil(w http.ResponseWriter, _ *http.Request) {
	a.exfils.Add(1)
	res := actResult{Action: "exfil", Attempted: true, OK: true, PID: os.Getpid()}
	res.StartedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.dial(&res, a.cfg.exfilTarget)
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{
		"action": "exfil", "host": res.Host, "connected": res.Connected,
		"dial_outcome": res.DialOutcome, "dial_error": res.DialError,
	})
	writeJSON(w, http.StatusOK, res)
}

func (a *agent) handleKubeEnum(w http.ResponseWriter, _ *http.Request) {
	a.kubeEnums.Add(1)
	res := actResult{Action: "kube-enum", Attempted: true, OK: true, PID: os.Getpid()}
	res.StartedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.readSATokenMeta(&res, a.cfg.saTokenPath)
	a.dial(&res, a.cfg.kubeAPITarget)
	res.FinishedAt = a.now().UTC().Format(time.RFC3339Nano)
	a.logEvent("act", map[string]any{
		"action": "kube-enum", "token_path": res.TokenPath,
		"token_readable": res.TokenReadable, "token_bytes": res.TokenBytes,
		"host": res.Host, "connected": res.Connected, "dial_outcome": res.DialOutcome,
	})
	writeJSON(w, http.StatusOK, res)
}

// readSATokenMeta opens the service-account token on a traced OS thread and
// records whether it was readable and its byte length. The token value is
// counted, never returned or logged.
func (a *agent) readSATokenMeta(res *actResult, tokenPath string) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	res.TokenPath = tokenPath
	res.TID = syscall.Gettid()
	f, err := os.Open(tokenPath)
	if err != nil {
		res.TokenReadable = false
		return
	}
	data, rerr := io.ReadAll(io.LimitReader(f, maxActReadBytes))
	_ = f.Close()
	if rerr != nil {
		res.TokenReadable = false
		return
	}
	res.TokenReadable = true
	res.TokenBytes = len(data)
}

// dial makes one short, bounded outbound TCP connect to target and records the
// outcome on res. The connect attempt is the provocation, so a refused or
// timed-out dial is reported without clearing ok. No payload is ever sent.
func (a *agent) dial(res *actResult, target string) {
	res.Host = target
	res.Address = target // attempted address unless a successful connect resolves one
	conn, err := net.DialTimeout("tcp", target, a.cfg.dialTimeout)
	if err != nil {
		res.Connected = false
		res.DialError = err.Error()
		res.DialOutcome = classifyDial(err)
		return
	}
	res.Connected = true
	res.DialOutcome = "connected"
	res.Address = conn.RemoteAddr().String()
	_ = conn.Close()
}

// classifyDial labels a failed dial for the envelope without leaking the target.
func classifyDial(err error) string {
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "refused"
	}
	return "error"
}

func (a *agent) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/quote", getOnly(a.handleQuote))
	mux.HandleFunc("/{$}", getOnly(a.handleQuote))
	mux.HandleFunc("/stats", getOnly(a.handleStats))
	mux.HandleFunc("/health", getOnly(handleHealthz))
	mux.HandleFunc("/healthz", getOnly(handleHealthz))
	mux.HandleFunc("/readyz", getOnly(handleHealthz))
	mux.HandleFunc("/act/read-passwd", a.postOnly("read-passwd", a.handleReadPasswd))
	mux.HandleFunc("/act/read-shadow", a.postOnly("read-shadow", a.handleReadShadow))
	mux.HandleFunc("/act/cpu-burn", a.postOnly("cpu-burn", a.handleCPUBurn))
	mux.HandleFunc("/act/gpu-open", a.postOnly("gpu-open", a.handleGPUOpen))
	mux.HandleFunc("/act/gpu-probe", a.postOnly("gpu-probe", a.handleGPUProbe))
	mux.HandleFunc("/act/exfil", a.postOnly("exfil", a.handleExfil))
	mux.HandleFunc("/act/kube-enum", a.postOnly("kube-enum", a.handleKubeEnum))
	mux.HandleFunc("/act/recon", a.postOnly("recon", a.handleRecon))
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
