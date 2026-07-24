// Security Sandbox, broker side.
//
// Three endpoints backing the Estate 95 Security Sandbox app. All of them talk
// to the in-cluster LLM Guard pod (and, for the probe, to Olly's A2A endpoint)
// through the same supervised port-forward pool the rest of the console uses.
//
//	GET  /api/security/status  - is the LLM Guard pod reachable, and what does it scan?
//	POST /api/security/scan    - run one string through LLM Guard, return the raw verdict (a live preview).
//	POST /api/security/probe   - forward a message to Olly with the guard on or off, so promptfoo and the
//	                             app can measure guarded vs unguarded against the real agent.
//
// The probe is the red-team target: promptfoo posts {message, llm_guard_enabled}
// and grades the returned agent text. With the guard on, the message is scanned
// before Olly sees it and Olly's reply is scanned on the way out; a tripped
// input scan short-circuits and Olly is never called.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// llmGuardToken is the bearer the LLM Guard pod expects (AUTH_TOKEN in the
// deployment). A local demo token, not a production secret.
const llmGuardToken = "llm-guard-token"

// scannerNames is the lightweight scanner set enabled in scanners.yml, surfaced
// so the app can show what the guard is actually checking.
var scannerNames = map[string][]string{
	"input":  {"Anonymize (PII)", "Gibberish", "PromptInjection", "Secrets", "Toxicity"},
	"output": {"Deanonymize", "Gibberish", "MaliciousURLs", "NoRefusal", "Sensitive (PII)", "Toxicity"},
}

// analyzeResp is LLM Guard's /analyze/{prompt,output} reply.
type analyzeResp struct {
	IsValid         bool               `json:"is_valid"`
	SanitizedPrompt string             `json:"sanitized_prompt"`
	SanitizedOutput string             `json:"sanitized_output"`
	Scanners        map[string]float64 `json:"scanners"`
}

// proxyPostAuth is proxyPost with a bearer token, for the LLM Guard scan API.
func (c *console) proxyPostAuth(svc, path string, body []byte, bearer string) ([]byte, int, error) {
	local, err := c.pf.get(svc)
	if err != nil {
		return nil, http.StatusServiceUnavailable, err
	}
	req, err := http.NewRequest(http.MethodPost, "http://"+local+path, bytes.NewReader(body))
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	client := &http.Client{Timeout: 90 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, http.StatusBadGateway, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return out, resp.StatusCode, nil
}

func (c *console) scanPrompt(text string) (*analyzeResp, error) {
	body, _ := json.Marshal(map[string]string{"prompt": text})
	out, code, err := c.proxyPostAuth("llm-guard", "/analyze/prompt", body, llmGuardToken)
	if err != nil {
		return nil, err
	}
	if code >= 300 {
		return nil, fmt.Errorf("llm-guard /analyze/prompt returned %d: %s", code, strings.TrimSpace(string(out)))
	}
	var r analyzeResp
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, fmt.Errorf("bad guard reply: %w", err)
	}
	return &r, nil
}

func (c *console) scanOutput(prompt, output string) (*analyzeResp, error) {
	body, _ := json.Marshal(map[string]string{"prompt": prompt, "output": output})
	out, code, err := c.proxyPostAuth("llm-guard", "/analyze/output", body, llmGuardToken)
	if err != nil {
		return nil, err
	}
	if code >= 300 {
		return nil, fmt.Errorf("llm-guard /analyze/output returned %d: %s", code, strings.TrimSpace(string(out)))
	}
	var r analyzeResp
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, fmt.Errorf("bad guard reply: %w", err)
	}
	return &r, nil
}

// a2aPart / a2aResult cover the shapes Olly's A2A message/send can return: a
// Task (status.message.parts, artifacts) or a bare Message (top-level parts).
type a2aPart struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

type a2aResult struct {
	ID     string    `json:"id"`
	Parts  []a2aPart `json:"parts"`
	Status struct {
		State   string `json:"state"`
		Message struct {
			Parts []a2aPart `json:"parts"`
		} `json:"message"`
	} `json:"status"`
	Artifacts []struct {
		Parts []a2aPart `json:"parts"`
	} `json:"artifacts"`
}

func (r a2aResult) text() string {
	var chunks []string
	collect := func(parts []a2aPart) {
		for _, p := range parts {
			if t := strings.TrimSpace(p.Text); t != "" {
				chunks = append(chunks, t)
			}
		}
	}
	collect(r.Parts)
	collect(r.Status.Message.Parts)
	for _, a := range r.Artifacts {
		collect(a.Parts)
	}
	return strings.Join(chunks, "\n")
}

// ollyTriage sends one message to Olly's A2A endpoint (the direct read-only
// TROUBLESHOOT skill) and returns the agent's reply text.
func (c *console) ollyTriage(message string) (string, string, error) {
	rpc := map[string]any{
		"jsonrpc": "2.0",
		"id":      fmt.Sprintf("sandbox-%d", time.Now().UnixNano()),
		"method":  "message/send",
		"params": map[string]any{
			"message": map[string]any{
				"role":      "user",
				"messageId": fmt.Sprintf("sandbox-%d", time.Now().UnixNano()),
				"parts":     []map[string]any{{"kind": "text", "text": message}},
			},
		},
	}
	body, _ := json.Marshal(rpc)
	out, code, err := c.proxyPost("olly-sentinel", "/", body)
	if err != nil {
		return "", "", err
	}
	if code >= 300 {
		return "", "", fmt.Errorf("olly A2A returned %d", code)
	}
	var env struct {
		Result a2aResult `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return "", "", fmt.Errorf("bad A2A reply: %w", err)
	}
	if env.Error != nil {
		return "", "", fmt.Errorf("olly A2A error: %s", env.Error.Message)
	}
	reply := env.Result.text()
	if reply == "" {
		reply = "(agent returned a task with state " + env.Result.Status.State + ")"
	}
	return reply, env.Result.Status.State, nil
}

func (c *console) registerSecurity(mux *http.ServeMux) {
	// GET /api/security/status -> LLM Guard reachability + the scanner set.
	mux.HandleFunc("/api/security/status", func(w http.ResponseWriter, _ *http.Request) {
		reachable := false
		detail := ""
		if local, err := c.pf.get("llm-guard"); err != nil {
			detail = err.Error()
		} else {
			client := &http.Client{Timeout: 5 * time.Second}
			if resp, e := client.Get("http://" + local + "/healthz"); e != nil {
				detail = e.Error()
			} else {
				reachable = resp.StatusCode == http.StatusOK
				resp.Body.Close()
			}
		}
		writeJSON(w, map[string]any{
			"guard_reachable": reachable,
			"detail":          detail,
			"scanners":        scannerNames,
		})
	})

	// POST /api/security/scan {text, direction} -> raw guard verdict (preview).
	mux.HandleFunc("/api/security/scan", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Text      string `json:"text"`
			Direction string `json:"direction"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		var res *analyzeResp
		var err error
		if req.Direction == "output" {
			res, err = c.scanOutput(req.Text, req.Text)
		} else {
			res, err = c.scanPrompt(req.Text)
		}
		if err != nil {
			clusterUnavailable(w, "the LLM Guard scanner", err)
			return
		}
		sanitized := res.SanitizedPrompt
		if req.Direction == "output" {
			sanitized = res.SanitizedOutput
		}
		writeJSON(w, map[string]any{
			"is_valid":  res.IsValid,
			"scanners":  res.Scanners,
			"sanitized": sanitized,
			"direction": req.Direction,
		})
	})

	// POST /api/security/probe {message, llm_guard_enabled} -> forward to Olly,
	// scanning input and output when the guard is on. The red-team target.
	mux.HandleFunc("/api/security/probe", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Message         string `json:"message"`
			LLMGuardEnabled bool   `json:"llm_guard_enabled"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		out := map[string]any{"blocked": false, "stage": "", "guard_enabled": req.LLMGuardEnabled}

		// 1. Input scan. A tripped scan short-circuits: Olly is never called.
		if req.LLMGuardEnabled {
			if res, err := c.scanPrompt(req.Message); err != nil {
				out["guard_error"] = err.Error()
			} else {
				out["input_scanners"] = res.Scanners
				if !res.IsValid {
					out["blocked"] = true
					out["stage"] = "input"
					out["response"] = "[blocked by LLM Guard on input: " + topScanner(res.Scanners) + "]"
					writeJSON(w, out)
					return
				}
			}
		}

		// 2. Forward to the live Olly agent.
		reply, state, err := c.ollyTriage(req.Message)
		if err != nil {
			clusterUnavailable(w, "the Olly A2A endpoint", err)
			return
		}
		out["response"] = reply
		out["agent_state"] = state

		// 3. Output scan (informational; the reply is already returned).
		if req.LLMGuardEnabled {
			if res, err := c.scanOutput(req.Message, reply); err == nil {
				out["output_scanners"] = res.Scanners
				if !res.IsValid {
					out["blocked"] = true
					out["stage"] = "output"
				}
			}
		}
		writeJSON(w, out)
	})
}

// topScanner names the highest-scoring scanner for a short block reason.
func topScanner(scanners map[string]float64) string {
	best, bestScore := "", -1.0
	for name, score := range scanners {
		if score > bestScore {
			best, bestScore = name, score
		}
	}
	if best == "" {
		return "scan tripped"
	}
	return fmt.Sprintf("%s %.2f", best, bestScore)
}
