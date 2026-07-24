// Estate 95 broker: the single local backend behind the Windows-95 demo GUI.
//
// It serves ui/ and runs steps.json actions over SSE, and provides a single
// view over the live OSRAMP / olly cluster: it runs make/scripts, proxies
// in-cluster services through a supervised kubectl port-forward pool, streams
// the real Kafka pipeline, reads the ServiceNow ticket store and the committed
// A2A agent card, summarises the ADK eval history, and bridges a scoped
// read-only terminal into the cluster.
//
// Everything is stdlib-only so it builds offline. Read-only endpoints run off
// the single-run lock, so live panels never block the destructive lifecycle
// actions (and vice versa).
//
//	go run ./tools/demo-console      # or: make console  ->  http://localhost:8675
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const namespace = "olly-replica"

// ----------------------------------------------------------------------------
// steps.json model + action registry
// ----------------------------------------------------------------------------

type action struct {
	ID      string   `json:"id"`
	Label   string   `json:"label"`
	Command []string `json:"command"`
	Class   string   `json:"class"` // lifecycle (serialized) | readonly | background
}

type step struct {
	ID      string   `json:"id"`
	Actions []action `json:"actions"`
}

type lane struct {
	Steps []step `json:"steps"`
}

type stepsModel struct {
	Lanes []lane `json:"lanes"`
}

// classOf resolves an action's concurrency class: the explicit field wins,
// otherwise a read-only kubectl query runs unlocked and everything else
// (make/scripts) serializes.
func classOf(a action) string {
	if a.Class != "" {
		return a.Class
	}
	if len(a.Command) > 0 && a.Command[0] == "kubectl" {
		for _, tok := range a.Command[1:] {
			switch tok {
			case "get", "logs", "describe", "top", "version", "api-resources":
				return "readonly"
			}
		}
	}
	return "lifecycle"
}

func loadActions(path string) (map[string]action, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var model stepsModel
	if err := json.Unmarshal(raw, &model); err != nil {
		return nil, err
	}
	actions := map[string]action{}
	for _, l := range model.Lanes {
		for _, s := range l.Steps {
			for _, a := range s.Actions {
				if len(a.Command) == 0 {
					return nil, fmt.Errorf("action %q has an empty command", a.ID)
				}
				actions[a.ID] = a
			}
		}
	}
	return actions, nil
}

// ----------------------------------------------------------------------------
// run tracking (streamed command output over SSE)
// ----------------------------------------------------------------------------

type run struct {
	mu       sync.Mutex
	lines    []string
	done     bool
	exitCode int
	waiters  []chan struct{}
}

func (r *run) append(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, line)
	r.notify()
}

func (r *run) finish(code int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.done = true
	r.exitCode = code
	r.notify()
}

func (r *run) notify() {
	for _, w := range r.waiters {
		close(w)
	}
	r.waiters = nil
}

func (r *run) snapshot(offset int) ([]string, bool, int, <-chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	fresh := append([]string(nil), r.lines[offset:]...)
	var wait chan struct{}
	if !r.done {
		wait = make(chan struct{})
		r.waiters = append(r.waiters, wait)
	}
	return fresh, r.done, r.exitCode, wait
}

// ----------------------------------------------------------------------------
// port-forward pool: lazily forward an in-cluster service to a local port and
// keep it alive, so JSON fetches, reverse proxies and Kafka tails have a
// stable address. Forwards die; each get() re-checks and restarts.
// ----------------------------------------------------------------------------

type svcRef struct {
	ns, svc string
	port    int
}

var services = map[string]svcRef{
	"io-mapping-stub": {namespace, "io-mapping-stub", 8080},
	"olly-sentinel":   {namespace, "olly-sentinel", 8080},
	"elk-search-mcp":  {namespace, "elk-search-mcp", 8080},
	"grafana":         {namespace, "eye-in-the-sky-grafana", 80},
	"llm-guard":       {namespace, "llm-guard", 8000},
	// Prometheus lives in the monitoring namespace, not olly-replica; it backs
	// the native Eye in the Sky overview's PromQL.
	"prometheus": {"monitoring", "kube-prometheus-stack-prometheus", 9090},
}

type forward struct {
	local string // 127.0.0.1:PORT
	cmd   *exec.Cmd
}

type pforward struct {
	mu    sync.Mutex
	fwds  map[string]*forward
	rootD string
}

func newPForward(root string) *pforward { return &pforward{fwds: map[string]*forward{}, rootD: root} }

// get returns a local "127.0.0.1:PORT" that proxies to the named service,
// starting (or restarting) the port-forward as needed.
func (p *pforward) get(name string) (string, error) {
	ref, ok := services[name]
	if !ok {
		return "", fmt.Errorf("unknown service %q", name)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if f := p.fwds[name]; f != nil && f.cmd.ProcessState == nil {
		if reachable(f.local) {
			return f.local, nil
		}
		_ = f.cmd.Process.Kill()
		delete(p.fwds, name)
	}
	cmd := exec.Command("kubectl", "-n", ref.ns, "port-forward",
		"svc/"+ref.svc, fmt.Sprintf(":%d", ref.port))
	cmd.Dir = p.rootD
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return "", err
	}
	// kubectl prints "Forwarding from 127.0.0.1:PORT -> N"; read the local port.
	local := ""
	done := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			line := sc.Text()
			if local == "" && strings.Contains(line, "Forwarding from 127.0.0.1:") {
				if i := strings.Index(line, "127.0.0.1:"); i >= 0 {
					rest := line[i+len("127.0.0.1:"):]
					if j := strings.IndexAny(rest, " \t-"); j >= 0 {
						local = "127.0.0.1:" + rest[:j]
					}
					close(done)
				}
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(12 * time.Second):
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("port-forward to %s timed out (cluster not ready?)", name)
	}
	if !waitReachable(local, 5*time.Second) {
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("port-forward to %s never became reachable", name)
	}
	p.fwds[name] = &forward{local: local, cmd: cmd}
	return local, nil
}

func reachable(addr string) bool {
	c, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func waitReachable(addr string, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if reachable(addr) {
			return true
		}
		time.Sleep(150 * time.Millisecond)
	}
	return false
}

// ----------------------------------------------------------------------------
// console: HTTP surface
// ----------------------------------------------------------------------------

type console struct {
	actions map[string]action
	rootDir string
	stepsP  string
	pf      *pforward

	mu       sync.Mutex
	runs     map[string]*run
	nextID   int
	lifeLock bool // held by a running lifecycle action
}

func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "ui", "steps.json")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("ui/steps.json not found above the working directory")
		}
		dir = parent
	}
}

func (c *console) startRun(actionID string) (string, error) {
	a, ok := c.actions[actionID]
	if !ok {
		return "", fmt.Errorf("unknown action %q", actionID)
	}
	lifecycle := classOf(a) == "lifecycle"

	c.mu.Lock()
	if lifecycle && c.lifeLock {
		c.mu.Unlock()
		return "", fmt.Errorf("a lifecycle action is already running; wait for it to finish")
	}
	if lifecycle {
		c.lifeLock = true
	}
	c.nextID++
	id := fmt.Sprintf("run-%d", c.nextID)
	current := &run{}
	c.runs[id] = current
	c.mu.Unlock()

	cmd := exec.Command(a.Command[0], a.Command[1:]...)
	cmd.Dir = c.rootDir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		c.release(current, -1, lifecycle)
		return "", err
	}
	cmd.Stderr = cmd.Stdout

	current.append("$ " + strings.Join(a.Command, " "))
	if err := cmd.Start(); err != nil {
		current.append(err.Error())
		c.release(current, -1, lifecycle)
		return id, nil
	}
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			current.append(sc.Text())
		}
		code := 0
		if err := cmd.Wait(); err != nil {
			if ex, ok := err.(*exec.ExitError); ok {
				code = ex.ExitCode()
			} else {
				current.append(err.Error())
				code = -1
			}
		}
		c.release(current, code, lifecycle)
	}()
	return id, nil
}

func (c *console) release(r *run, code int, lifecycle bool) {
	r.finish(code)
	c.mu.Lock()
	if lifecycle {
		c.lifeLock = false
	}
	c.mu.Unlock()
}

func (c *console) handleRuns(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Action string `json:"action"`
	}
	if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	id, err := c.startRun(body.Action)
	if err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	writeJSON(w, map[string]string{"id": id})
}

func (c *console) handleEvents(w http.ResponseWriter, req *http.Request) {
	id := strings.TrimSuffix(strings.TrimPrefix(req.URL.Path, "/api/runs/"), "/events")
	c.mu.Lock()
	current, ok := c.runs[id]
	c.mu.Unlock()
	if !ok {
		http.Error(w, "unknown run", http.StatusNotFound)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	sseHeaders(w)
	offset := 0
	for {
		lines, done, code, wait := current.snapshot(offset)
		for _, line := range lines {
			sseSend(w, flusher, "line", line)
		}
		offset += len(lines)
		if done {
			sseSend(w, flusher, "exit", code)
			return
		}
		select {
		case <-wait:
		case <-req.Context().Done():
			return
		}
	}
}

// ----------------------------------------------------------------------------
// cluster overview: pods + Flux reconciliation, read-only
// ----------------------------------------------------------------------------

type podRow struct {
	NS       string `json:"ns"`
	Name     string `json:"name"`
	Ready    string `json:"ready"`
	Status   string `json:"status"`
	Restarts int    `json:"restarts"`
}

type fluxRow struct {
	Kind   string `json:"kind"`
	NS     string `json:"ns"`
	Name   string `json:"name"`
	Ready  string `json:"ready"`
	Status string `json:"status"`
}

func (c *console) kubectlJSON(args ...string) (map[string]any, error) {
	cmd := exec.Command("kubectl", args...)
	cmd.Dir = c.rootDir
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(errb.String()))
	}
	var parsed map[string]any
	if err := json.Unmarshal(out.Bytes(), &parsed); err != nil {
		return nil, err
	}
	return parsed, nil
}

func (c *console) handleClusterOverview(w http.ResponseWriter, _ *http.Request) {
	resp := map[string]any{"pods": []podRow{}, "flux": []fluxRow{}, "ready": false}

	if data, err := c.kubectlJSON("get", "pods", "-A", "-o", "json"); err == nil {
		pods := []podRow{}
		for _, it := range items(data) {
			meta := m(it["metadata"])
			status := m(it["status"])
			phase, _ := status["phase"].(string)
			ready, restarts := containerReadiness(status)
			pods = append(pods, podRow{
				NS: str(meta["namespace"]), Name: str(meta["name"]),
				Ready: ready, Status: phase, Restarts: restarts,
			})
		}
		sort.Slice(pods, func(i, j int) bool {
			if pods[i].NS != pods[j].NS {
				return pods[i].NS < pods[j].NS
			}
			return pods[i].Name < pods[j].Name
		})
		resp["pods"] = pods
		resp["ready"] = true
	}

	if data, err := c.kubectlJSON("get", "kustomizations,ocirepositories,resourcesets", "-A", "-o", "json"); err == nil {
		rows := []fluxRow{}
		for _, it := range items(data) {
			meta := m(it["metadata"])
			kind := str(it["kind"])
			ready, msg := conditionReady(m(it["status"]))
			rows = append(rows, fluxRow{Kind: kind, NS: str(meta["namespace"]), Name: str(meta["name"]), Ready: ready, Status: msg})
		}
		resp["flux"] = rows
	}
	writeJSON(w, resp)
}

func containerReadiness(status map[string]any) (string, int) {
	cs, _ := status["containerStatuses"].([]any)
	total, ready, restarts := 0, 0, 0
	for _, c := range cs {
		cm := m(c)
		total++
		if b, _ := cm["ready"].(bool); b {
			ready++
		}
		if r, ok := cm["restartCount"].(float64); ok {
			restarts += int(r)
		}
	}
	return fmt.Sprintf("%d/%d", ready, total), restarts
}

func conditionReady(status map[string]any) (string, string) {
	conds, _ := status["conditions"].([]any)
	for _, c := range conds {
		cm := m(c)
		if str(cm["type"]) == "Ready" {
			return str(cm["status"]), str(cm["message"])
		}
	}
	return "Unknown", ""
}

// ----------------------------------------------------------------------------
// ServiceNow ticket store + A2A agent card (committed + live)
// ----------------------------------------------------------------------------

func (c *console) proxyGet(svc, path string) ([]byte, int, error) {
	local, err := c.pf.get(svc)
	if err != nil {
		return nil, http.StatusServiceUnavailable, err
	}
	resp, err := http.Get("http://" + local + path)
	if err != nil {
		return nil, http.StatusBadGateway, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return body, resp.StatusCode, nil
}

func (c *console) handleIncidents(w http.ResponseWriter, req *http.Request) {
	path := "/incidents"
	if corr := strings.TrimPrefix(req.URL.Path, "/api/incidents/"); corr != "" && corr != req.URL.Path {
		path = "/incidents/" + corr
	} else if req.URL.RawQuery != "" {
		path += "?" + req.URL.RawQuery
	}
	body, code, err := c.proxyGet("io-mapping-stub", path)
	if err != nil {
		clusterUnavailable(w, "ServiceNow ticket store (io-mapping-stub)", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// agentCards maps a short name to its committed contract file and the live
// well-known path that serves the running service's card. Both cards are
// served by the same sentinel process (orbit is a component of it), so the
// live path differs by suffix. A card not in this table returns 404 and does
// not reach the file server.
var agentCards = map[string]struct{ file, wellKnown string }{
	"olly-sentinel":   {"agent-card.olly-sentinel.v1.json", "/.well-known/agent-card.json"},
	"orbit":           {"agent-card.orbit.v1.json", "/orbit/.well-known/agent-card.json"},
	"incident-triage": {"agent-card.incident-triage.v1.json", ""},
	"knowledge-mcp":   {"agent-card.knowledge-mcp.v1.json", ""},
}

// cardName resolves the card selector from a path suffix, defaulting to the
// sentinel so the bare /api/agent-card endpoint maps to the sentinel card.
func cardName(path, prefix string) string {
	name := strings.Trim(strings.TrimPrefix(path, prefix), "/")
	if name == "" {
		return "olly-sentinel"
	}
	return name
}

func (c *console) handleAgentCardCommitted(w http.ResponseWriter, r *http.Request) {
	name := cardName(r.URL.Path, "/api/agent-card")
	card, ok := agentCards[name]
	if !ok {
		http.Error(w, "unknown agent card: "+name, http.StatusNotFound)
		return
	}
	p := filepath.Join(c.rootDir, "olly-replica", "contracts", card.file)
	http.ServeFile(w, &http.Request{URL: &url.URL{}}, p)
}

func (c *console) handleAgentCardLive(w http.ResponseWriter, r *http.Request) {
	name := cardName(r.URL.Path, "/api/agent-card/live")
	card, ok := agentCards[name]
	if !ok {
		http.Error(w, "unknown agent card: "+name, http.StatusNotFound)
		return
	}
	// orbit has no separately-served live card in Phase 1 (it is a component of
	// the sentinel), so its committed card is the live card. The sentinel's own
	// card is served live from its well-known path.
	if name != "olly-sentinel" {
		p := filepath.Join(c.rootDir, "olly-replica", "contracts", card.file)
		http.ServeFile(w, &http.Request{URL: &url.URL{}}, p)
		return
	}
	body, code, err := c.proxyGet("olly-sentinel", card.wellKnown)
	if err != nil {
		clusterUnavailable(w, "the running sentinel A2A card", err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// ----------------------------------------------------------------------------
// ADK eval history + agent-vs-human scorecard
// ----------------------------------------------------------------------------

func (c *console) handleEvalHistory(w http.ResponseWriter, _ *http.Request) {
	dir := filepath.Join(c.rootDir, "olly-replica", "apps", "sentinel", "olly_sentinel", ".adk", "eval_history")
	type evalRun struct {
		File   string `json:"file"`
		Name   string `json:"name"`
		Cases  int    `json:"cases"`
		Passed int    `json:"passed"`
		Failed int    `json:"failed"`
	}
	runs := []evalRun{}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var parsed map[string]any
		if json.Unmarshal(raw, &parsed) != nil {
			continue
		}
		er := evalRun{File: e.Name(), Name: str(parsed["eval_set_id"])}
		for _, r := range asSlice(parsed["eval_case_results"]) {
			er.Cases++
			if strings.Contains(strings.ToUpper(fmt.Sprint(m(r)["final_eval_status"])), "PASS") || fmt.Sprint(m(r)["final_eval_status"]) == "1" {
				er.Passed++
			} else {
				er.Failed++
			}
		}
		runs = append(runs, er)
	}
	// The agent-vs-human scorecard: agent numbers are ground truth from the
	// signal-check gate; the human baseline is client-owed until a labelled
	// closed-INC set + ServiceNow timestamps arrive.
	scorecard := []map[string]any{
		{"metric": "Time to enriched RCA", "agent": "~5-15 s", "human": "awaiting baseline", "source": "enriched_at - created_at"},
		{"metric": "Fault-domain accuracy", "agent": "3 / 3 seeded", "human": "awaiting baseline", "source": "test_rca_signals"},
		{"metric": "Secret-leak rate", "agent": "0", "human": "n/a", "source": "redaction.secrets_found"},
		{"metric": "Evidence trajectory", "agent": "3 patterns", "human": "n/a", "source": "evidence[] scope"},
	}
	writeJSON(w, map[string]any{
		"runs":      runs,
		"scorecard": scorecard,
		"note":      "Runs accumulate here after `make olly-eval` / adk web. The human column stays 'awaiting baseline' until labelled incident data lands.",
	})
}

// ----------------------------------------------------------------------------
// Pipeline theater: real per-topic Kafka flow via `rpk topic consume`
// ----------------------------------------------------------------------------

var topicStage = map[string]string{
	"netcool.io.events":                              "received",
	"netcool.io.events.declined":                     "declined",
	"ideas-172472-sn30.167564-impact.event_response": "enriched",
}

const decisionsTopic = "olly.pipeline.decisions"

func (c *console) handlePipelineEvents(w http.ResponseWriter, req *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	sseHeaders(w)
	ctx := req.Context()
	events := make(chan map[string]any, 128)

	// One rpk consumer per data topic, tailing new messages from the end with
	// partition/offset/key metadata. A separate consumer tails the decision bus
	// so the UI can render the branch every gate took.
	for topic, stage := range topicStage {
		go c.tailTopic(ctx, topic, stage, events)
	}
	go c.tailDecisions(ctx, events)
	go c.pollTickets(ctx, events)

	sseSend(w, flusher, "hello", map[string]string{"ns": namespace})
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()
	for {
		select {
		case ev := <-events:
			kind, _ := ev["_kind"].(string)
			if kind == "" {
				kind = "stage"
			}
			delete(ev, "_kind")
			sseSend(w, flusher, kind, ev)
		case <-keepalive.C:
			sseSend(w, flusher, "ping", time.Now().Unix())
		case <-ctx.Done():
			return
		}
	}
}

// consumeFormat is the rpk output format: partition|offset|key|value, one
// message per line. SplitN on the first three separators keeps a value that
// itself contains "|" intact.
const consumeFormat = "%p|%o|%k|%v\n"

func splitKafkaLine(line string) (partition, offset, key, value string, ok bool) {
	parts := strings.SplitN(line, "|", 4)
	if len(parts) != 4 {
		return "", "", "", "", false
	}
	return parts[0], parts[1], parts[2], parts[3], true
}

func (c *console) tailTopic(ctx context.Context, topic, stage string, out chan<- map[string]any) {
	cmd := exec.CommandContext(ctx, "kubectl", "-n", namespace, "exec", "redpanda-0", "-c", "redpanda",
		"--", "rpk", "topic", "consume", topic, "-o", "end", "-f", consumeFormat, "-X", "brokers=localhost:9093")
	cmd.Dir = c.rootDir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	defer func() { _ = cmd.Process.Kill() }()
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		partition, offset, key, value, ok := splitKafkaLine(line)
		if !ok {
			continue
		}
		corr, app := extractCorr(value)
		select {
		case out <- map[string]any{
			"stage": stage, "topic": topic, "correlation_id": corr, "app_id": app,
			"partition": partition, "offset": offset, "key": key, "payload": value,
			"ts": time.Now().UnixMilli(),
		}:
		case <-ctx.Done():
			return
		}
	}
}

// tailDecisions streams the pipeline-decision.v1 records: one per gate the flow
// evaluated, so the UI can light the branch each incident took across the whole
// architecture rather than only the happy path.
func (c *console) tailDecisions(ctx context.Context, out chan<- map[string]any) {
	cmd := exec.CommandContext(ctx, "kubectl", "-n", namespace, "exec", "redpanda-0", "-c", "redpanda",
		"--", "rpk", "topic", "consume", decisionsTopic, "-o", "end", "-f", consumeFormat, "-X", "brokers=localhost:9093")
	cmd.Dir = c.rootDir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	defer func() { _ = cmd.Process.Kill() }()
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		partition, offset, key, value, ok := splitKafkaLine(line)
		if !ok {
			continue
		}
		var rec map[string]any
		if json.Unmarshal([]byte(value), &rec) != nil {
			continue
		}
		ev := map[string]any{
			"_kind": "decision", "topic": decisionsTopic,
			"partition": partition, "offset": offset, "key": key,
			"correlation_id": str(rec["correlation_id"]), "event_id": str(rec["event_id"]),
			"app_id": str(rec["app_id"]), "component": str(rec["component"]),
			"gate": str(rec["gate"]), "branch": str(rec["branch"]), "reason": str(rec["reason"]),
			"fault_domain": str(rec["fault_domain"]), "detail": rec["detail"],
			"ts": time.Now().UnixMilli(),
		}
		select {
		case out <- ev:
		case <-ctx.Done():
			return
		}
	}
}

func (c *console) pollTickets(ctx context.Context, out chan<- map[string]any) {
	seen := map[string]string{} // corr -> state
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		body, code, err := c.proxyGet("io-mapping-stub", "/incidents")
		if err != nil || code != 200 {
			continue
		}
		var tickets []map[string]any
		if json.Unmarshal(body, &tickets) != nil {
			continue
		}
		for _, tk := range tickets {
			corr, state := str(tk["correlation_id"]), str(tk["state"])
			if seen[corr] == state {
				continue
			}
			seen[corr] = state
			out <- map[string]any{"_kind": "stage", "stage": "ticket", "correlation_id": corr, "app_id": str(tk["app_id"]),
				"state": state, "inc": str(tk["inc_number"]), "ts": time.Now().UnixMilli()}
		}
	}
}

// ----------------------------------------------------------------------------
// Node inspection: clicking a decision-tree node fetches the real data behind
// it, so the flow can be proven against live Kafka topics, pod logs, and the
// ticket store rather than described.
// ----------------------------------------------------------------------------

type nodeSource struct {
	title, kind, target, grep string
}

var pipelineNodes = map[string]nodeSource{
	"event":    {"Estate app error logs (Elasticsearch via elk-search-mcp)", "elk", "app-logs-*", "level:ERROR"},
	"noi":      {"NOI / Mapping Service logs", "logs", "io-mapping-stub", ""},
	"queue":    {"NOI event queue (Kafka: netcool.io.events)", "topic", "netcool.io.events", ""},
	"raw":      {"Raw incidents (no subscription)", "incidents", "", "raw"},
	"auto":     {"IO Automation / self-heal (mapping logs)", "logs", "io-mapping-stub", "auto-remediated"},
	"declined": {"IO-Declined topic (Kafka: netcool.io.events.declined)", "topic", "netcool.io.events.declined", ""},
	"drop":     {"Schema-validation drops (sentinel logs)", "logs", "olly-sentinel", "DROP"},
	"skip":     {"Source-filter skips (sentinel logs)", "logs", "olly-sentinel", "skip non-declined"},
	"dupe":     {"Dedup / loop-guard (sentinel logs)", "logs", "olly-sentinel", "skipping"},
	"olly":     {"Olly Sentinel MCP tool audit trail", "logs", "olly-sentinel", "AUDIT"},
	"parked":   {"Orbit parked proposals (sentinel logs)", "logs", "olly-sentinel", "orbit"},
	"response": {"Event response topic (Kafka)", "topic", "ideas-172472-sn30.167564-impact.event_response", ""},
	"ticket":   {"ServiceNow incident store", "incidents", "", ""},
	// A2A identity-chain nodes: the real pod-log audit trail behind each step of
	// the Olly -> Orbit hand-off, so clicking a node or edge on the dashboard's
	// A2A diagram proves it against live logs, the same way the decision flow does.
	"a2a-authz":  {"olly-authz issuance: COIN M2M mint OBO (PlainID + EEMS)", "logs", "olly-sentinel", "token_minted"},
	"a2a-olly":   {"Olly (agent-a): read fan-out under the COIN token", "logs", "olly-sentinel", "gco-sentinel-read"},
	"a2a-send":   {"Olly -> Orbit A2A message/send (hand-off)", "logs", "olly-sentinel", "orbit A2A"},
	"a2a-orbit":  {"Orbit (agent-b): AuthZ-CTX re-validate + narrow", "logs", "olly-sentinel", "authz_ctx_validated"},
	"a2a-broker": {"HITL: parked proposal -> signed approval / reject", "logs", "olly-sentinel", "orbit:"},
}

func (c *console) handlePipelineNode(w http.ResponseWriter, r *http.Request) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/pipeline/node/"), "/")
	src, ok := pipelineNodes[id]
	if !ok {
		http.Error(w, "unknown node "+id, http.StatusNotFound)
		return
	}
	var lines []string
	switch src.kind {
	case "topic":
		lines = c.rpkTail(src.target, 12)
	case "logs":
		// A deep tail so recent matches survive transient log bursts (e.g. a
		// broker reconnect storm) rather than being pushed out of the window.
		lines = c.podLogs(src.target, 1000, src.grep, 40)
	case "incidents":
		lines = c.incidentLines(src.grep)
	case "elk":
		lines = c.elkLines(src.target, src.grep)
	}
	if len(lines) == 0 {
		lines = []string{"(no records yet; replay an incident to populate this node)"}
	}
	writeJSON(w, map[string]any{"id": id, "title": src.title, "kind": src.kind, "source": src.target, "lines": lines})
}

// rpkTail returns the last n messages on a topic, decoded to a compact line.
func (c *console) rpkTail(topic string, n int) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "kubectl", "-n", namespace, "exec", "redpanda-0", "-c", "redpanda",
		"--", "rpk", "topic", "consume", topic, "-o", fmt.Sprintf("-%d", n), "-n", fmt.Sprintf("%d", n),
		"-f", "%o|%k|%v\n", "-X", "brokers=localhost:9093")
	out, _ := cmd.Output()
	var lines []string
	for _, ln := range strings.Split(string(out), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		parts := strings.SplitN(ln, "|", 3)
		if len(parts) == 3 {
			lines = append(lines, fmt.Sprintf("offset %-5s key=%-24s %s", parts[0], truncateStr(parts[1], 24), truncateStr(parts[2], 300)))
		} else {
			lines = append(lines, truncateStr(ln, 320))
		}
	}
	return lines
}

// podLogs returns up to keep lines of a deployment's logs, optionally filtered
// to those containing grep.
func (c *console) podLogs(deploy string, tail int, grep string, keep int) []string {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "kubectl", "-n", namespace, "logs", "deploy/"+deploy,
		"--tail", fmt.Sprintf("%d", tail))
	out, _ := cmd.Output()
	var lines []string
	for _, ln := range strings.Split(string(out), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		if grep != "" && !strings.Contains(ln, grep) {
			continue
		}
		lines = append(lines, truncateStr(ln, 320))
	}
	if len(lines) > keep {
		lines = lines[len(lines)-keep:]
	}
	return lines
}

// incidentLines reads the ticket store and renders each incident as a line,
// optionally filtered to a lifecycle state.
func (c *console) incidentLines(state string) []string {
	body, code, err := c.proxyGet("io-mapping-stub", "/incidents")
	if err != nil || code != 200 {
		return nil
	}
	var tickets []map[string]any
	if json.Unmarshal(body, &tickets) != nil {
		return nil
	}
	var lines []string
	for _, tk := range tickets {
		if state != "" && str(tk["state"]) != state {
			continue
		}
		lines = append(lines, fmt.Sprintf("%s  %-16s  %-14s  %s",
			str(tk["inc_number"]), str(tk["app_id"]), str(tk["state"]), truncateStr(str(tk["short_description"]), 90)))
		if len(lines) >= 40 {
			break
		}
	}
	return lines
}

// elkLines fetches recent estate logs live from the elk-search-mcp, the same
// read-only tool Olly queries, so the event node reflects the real incident
// evidence in Elasticsearch rather than a tenant pod's stdout. pattern is one
// of the allowed index patterns; query is an ES query_string.
func (c *console) elkLines(pattern, query string) []string {
	reqBody, _ := json.Marshal(map[string]any{
		"index_pattern": pattern, "query": query, "size": 40, "time_range_minutes": 1440,
	})
	body, code, err := c.proxyPost("elk-search-mcp", "/tools/elk_search_logs", reqBody)
	if err != nil || code != 200 {
		return nil
	}
	var resp struct {
		Hits []struct {
			Timestamp string `json:"timestamp"`
			AppID     string `json:"app_id"`
			Level     string `json:"level"`
			Message   string `json:"message"`
		} `json:"hits"`
	}
	if json.Unmarshal(body, &resp) != nil {
		return nil
	}
	var lines []string
	for _, h := range resp.Hits {
		ts := h.Timestamp
		if len(ts) >= 19 {
			ts = ts[11:19] // HH:MM:SS from the ISO-8601 @timestamp
		}
		lines = append(lines, fmt.Sprintf("%s  [%-5s %-16s]  %s",
			ts, h.Level, h.AppID, truncateStr(h.Message, 220)))
		if len(lines) >= 40 {
			break
		}
	}
	return lines
}

func truncateStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func extractCorr(line string) (string, string) {
	var msg map[string]any
	if json.Unmarshal([]byte(line), &msg) == nil {
		return str(msg["correlation_id"]), str(msg["app_id"])
	}
	return "", ""
}

// ----------------------------------------------------------------------------
// reverse proxy for embeddable UIs (Grafana in-cluster, adk web on localhost)
// ----------------------------------------------------------------------------

func (c *console) handleProxy(w http.ResponseWriter, req *http.Request) {
	rest := strings.TrimPrefix(req.URL.Path, "/proxy/")
	name := rest
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		name = rest[:i]
	}
	var target string
	if name == "adk" {
		target = "127.0.0.1:" + envOr("ADK_PORT", "8000") // adk web runs on the host
	} else {
		local, err := c.pf.get(name)
		if err != nil {
			clusterUnavailable(w, name, err)
			return
		}
		target = local
	}
	proxy := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = "http"
			r.URL.Host = target
			r.URL.Path = "/" + strings.TrimPrefix(rest[len(name):], "/")
			r.Host = target
		},
		ModifyResponse: func(resp *http.Response) error {
			// Allow same-origin embedding in a win95 iframe.
			resp.Header.Del("X-Frame-Options")
			resp.Header.Del("Content-Security-Policy")
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			clusterUnavailable(w, name, err)
		},
	}
	proxy.ServeHTTP(w, req)
}

// ----------------------------------------------------------------------------
// scoped terminal: a minimal stdlib WebSocket bridging an allow-listed,
// read-only command runner into the cluster. No shell (no injection), each
// command exec'd fresh under the read-only kubeconfig if one is provided.
// ----------------------------------------------------------------------------

var termAllow = map[string]bool{
	"kubectl": true, "flux": true, "helm": true, "rpk": true,
	"kubectx": true, "kubens": true, "echo": true, "clear": true,
}

func (c *console) handleTerm(w http.ResponseWriter, req *http.Request) {
	if req.Header.Get("Origin") != "" && !sameHost(req) {
		http.Error(w, "cross-origin terminal refused", http.StatusForbidden)
		return
	}
	conn, buf, err := wsUpgrade(w, req)
	if err != nil {
		return
	}
	defer conn.Close()
	kubeconfig := os.Getenv("CONSOLE_READONLY_KUBECONFIG")
	banner := "Estate 95 scoped terminal: read-only, allow-listed (kubectl, flux, helm, rpk).\r\n"
	if kubeconfig == "" {
		banner += "note: no read-only kubeconfig set (CONSOLE_READONLY_KUBECONFIG); using the default context.\r\n"
	}
	_ = wsWriteText(conn, banner+prompt())
	for {
		op, payload, err := wsRead(buf)
		if err != nil {
			return
		}
		if op == wsClose {
			return
		}
		if op != wsText {
			continue
		}
		cmdline := strings.TrimSpace(string(payload))
		if cmdline == "" {
			_ = wsWriteText(conn, prompt())
			continue
		}
		toks := tokenize(cmdline)
		if len(toks) == 0 {
			_ = wsWriteText(conn, prompt())
			continue
		}
		if toks[0] == "clear" {
			_ = wsWriteText(conn, "\x1b[2J\x1b[H"+prompt())
			continue
		}
		if !termAllow[toks[0]] {
			_ = wsWriteText(conn, fmt.Sprintf("\x1b[31mrefused: %q is not in the read-only allow-list\x1b[0m\r\n%s", toks[0], prompt()))
			continue
		}
		c.runTermCommand(conn, toks, kubeconfig)
		_ = wsWriteText(conn, prompt())
	}
}

func (c *console) runTermCommand(conn net.Conn, toks []string, kubeconfig string) {
	cmd := exec.Command(toks[0], toks[1:]...)
	cmd.Dir = c.rootDir
	if kubeconfig != "" {
		cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	}
	out, err := cmd.CombinedOutput()
	text := strings.ReplaceAll(string(out), "\n", "\r\n")
	if err != nil {
		text += "\x1b[31m" + strings.ReplaceAll(err.Error(), "\n", "\r\n") + "\x1b[0m\r\n"
	}
	_ = wsWriteText(conn, text)
}

func prompt() string { return "\x1b[36mosramp\x1b[0m$ " }

// tokenize splits a command line on whitespace, honoring double quotes so a
// jsonpath argument survives. No shell metacharacters are interpreted.
func tokenize(s string) []string {
	var toks []string
	var cur strings.Builder
	inQ := false
	for _, r := range s {
		switch {
		case r == '"':
			inQ = !inQ
		case (r == ' ' || r == '\t') && !inQ:
			if cur.Len() > 0 {
				toks = append(toks, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteRune(r)
		}
	}
	if cur.Len() > 0 {
		toks = append(toks, cur.String())
	}
	return toks
}

// ----------------------------------------------------------------------------
// minimal WebSocket (RFC 6455): text frames only, dep-free
// ----------------------------------------------------------------------------

const (
	wsText  = 0x1
	wsClose = 0x8
	wsPing  = 0x9
	wsPong  = 0xA
)

func wsUpgrade(w http.ResponseWriter, req *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	if !strings.EqualFold(req.Header.Get("Upgrade"), "websocket") {
		http.Error(w, "expected websocket", http.StatusBadRequest)
		return nil, nil, fmt.Errorf("not a websocket request")
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack unsupported", http.StatusInternalServerError)
		return nil, nil, fmt.Errorf("no hijacker")
	}
	conn, buf, err := hj.Hijack()
	if err != nil {
		return nil, nil, err
	}
	key := req.Header.Get("Sec-WebSocket-Key")
	h := sha1.New()
	h.Write([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	accept := base64.StdEncoding.EncodeToString(h.Sum(nil))
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	if _, err := buf.WriteString(resp); err != nil {
		conn.Close()
		return nil, nil, err
	}
	if err := buf.Flush(); err != nil {
		conn.Close()
		return nil, nil, err
	}
	return conn, buf, nil
}

func wsRead(buf *bufio.ReadWriter) (int, []byte, error) {
	h := make([]byte, 2)
	if _, err := io.ReadFull(buf, h); err != nil {
		return 0, nil, err
	}
	op := int(h[0] & 0x0F)
	masked := h[1]&0x80 != 0
	length := int(h[1] & 0x7F)
	switch length {
	case 126:
		e := make([]byte, 2)
		if _, err := io.ReadFull(buf, e); err != nil {
			return 0, nil, err
		}
		length = int(e[0])<<8 | int(e[1])
	case 127:
		e := make([]byte, 8)
		if _, err := io.ReadFull(buf, e); err != nil {
			return 0, nil, err
		}
		length = 0
		for _, b := range e {
			length = length<<8 | int(b)
		}
	}
	var mask []byte
	if masked {
		mask = make([]byte, 4)
		if _, err := io.ReadFull(buf, mask); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(buf, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return op, payload, nil
}

func wsWriteText(conn net.Conn, s string) error {
	payload := []byte(s)
	var header []byte
	header = append(header, 0x80|wsText)
	n := len(payload)
	switch {
	case n < 126:
		header = append(header, byte(n))
	case n < 65536:
		header = append(header, 126, byte(n>>8), byte(n))
	default:
		header = append(header, 127)
		for i := 7; i >= 0; i-- {
			header = append(header, byte(n>>(8*i)))
		}
	}
	if _, err := conn.Write(header); err != nil {
		return err
	}
	_, err := conn.Write(payload)
	return err
}

// ----------------------------------------------------------------------------
// small helpers
// ----------------------------------------------------------------------------

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func sseHeaders(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
}

func sseSend(w io.Writer, f http.Flusher, event string, payload any) {
	data, _ := json.Marshal(payload)
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
	f.Flush()
}

func clusterUnavailable(w http.ResponseWriter, what string, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusServiceUnavailable)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error": fmt.Sprintf("%s is unavailable; is the cluster up and reconciled?", what),
		"detail": func() string {
			if err != nil {
				return err.Error()
			}
			return ""
		}(),
	})
}

func sameHost(req *http.Request) bool {
	o, err := url.Parse(req.Header.Get("Origin"))
	if err != nil {
		return false
	}
	return o.Host == req.Host
}

func items(data map[string]any) []map[string]any {
	out := []map[string]any{}
	for _, it := range asSlice(data["items"]) {
		out = append(out, m(it))
	}
	return out
}
func asSlice(v any) []any { s, _ := v.([]any); return s }
func m(v any) map[string]any {
	mm, _ := v.(map[string]any)
	if mm == nil {
		return map[string]any{}
	}
	return mm
}
func str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	addr := envOr("CONSOLE_ADDR", "localhost:8675")
	root, err := findRepoRoot()
	if err != nil {
		log.Fatal(err)
	}
	stepsP := filepath.Join(root, "ui", "steps.json")
	actions, err := loadActions(stepsP)
	if err != nil {
		log.Fatal("loading ui/steps.json: ", err)
	}
	c := &console{actions: actions, rootDir: root, stepsP: stepsP, pf: newPForward(root), runs: map[string]*run{}}

	// Orbit approval signer: the broker holds the PRIVATE approval key so it
	// can mint tokens the sentinel (public key only) cannot. Absent key =>
	// minting disabled, approve returns 503.
	orbitKey := envOr("APPROVAL_KEY_FILE", filepath.Join(root, ".keys", "orbit-approval.pem"))
	signer := newOrbitSigner(orbitKey)
	log.Printf("orbit approval signer: minting %s (key %s)",
		map[bool]string{true: "enabled", false: "disabled"}[signer.enabled()], orbitKey)

	mux := http.NewServeMux()
	mux.HandleFunc("/api/steps", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		http.ServeFile(w, &http.Request{URL: &url.URL{}}, stepsP)
	})
	mux.HandleFunc("/api/runs", c.handleRuns)
	mux.HandleFunc("/api/runs/", c.handleEvents)
	mux.HandleFunc("/api/cluster/overview", c.handleClusterOverview)
	mux.HandleFunc("/api/incidents", c.handleIncidents)
	mux.HandleFunc("/api/incidents/", c.handleIncidents)
	// Live routes first (more specific), then committed. Go 1.22+ ServeMux
	// gives the longer pattern precedence, so /api/agent-card/live[/orbit]
	// routes to the live handler.
	mux.HandleFunc("/api/agent-card/live", c.handleAgentCardLive)
	mux.HandleFunc("/api/agent-card/live/", c.handleAgentCardLive)
	mux.HandleFunc("/api/agent-card", c.handleAgentCardCommitted)
	mux.HandleFunc("/api/agent-card/", c.handleAgentCardCommitted)
	c.registerOrbit(mux, signer)
	c.registerSecurity(mux)
	c.registerMetrics(mux)
	mux.HandleFunc("/api/eval-history", c.handleEvalHistory)
	mux.HandleFunc("/api/pipeline/events", c.handlePipelineEvents)
	mux.HandleFunc("/api/pipeline/node/", c.handlePipelineNode)
	mux.HandleFunc("/proxy/", c.handleProxy)
	mux.HandleFunc("/ws/term", c.handleTerm)
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "ns": namespace})
	})
	mux.Handle("/", http.FileServer(http.Dir(filepath.Join(root, "ui"))))

	log.Printf("Estate 95 broker on http://%s (%d actions)", addr, len(actions))
	log.Fatal(http.ListenAndServe(addr, mux))
}
