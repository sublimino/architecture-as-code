package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

func validateEndpointURL(raw, name string) error {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return fmt.Errorf("%s must not be empty", name)
	}
	u, err := url.Parse(trimmed)
	if err != nil {
		return fmt.Errorf("invalid %s URL: %w", name, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("invalid %s URL scheme %q: must be http or https", name, u.Scheme)
	}
	if u.Host == "" {
		return fmt.Errorf("invalid %s URL: host must not be empty", name)
	}
	return nil
}

const (
	spireAgentBin = "/usr/local/bin/spire-agent"
	maxAttempts   = 30
)

type commandRunner func(name string, args ...string) ([]byte, error)

type card struct {
	Cardholder string `json:"cardholder"`
	PANMasked  string `json:"pan_masked"`
	Expiry     string `json:"expiry"`
}

type agent struct {
	baoAddr      string
	baoRole      string
	cardvaultURL string
	claimURL     string
	spireSocket  string
	audience     string
	invoke       commandRunner
	pause        func(time.Duration)
	client       *http.Client
	now          func() time.Time // nil: time.Now

	// The OpenBao token is reused across runs until tokenReuseMargin before
	// it expires. Live, 2026-10-03, a fresh login every 60 s run had left
	// 3,188 tokens for this policy in OpenBao.
	token       string
	tokenExpiry time.Time
}

// tokenReuseMargin: a cached token closer than this to its expiry is
// replaced rather than used, so a run never starts on a token about to die.
const tokenReuseMargin = 30 * time.Second

// errBaoDenied marks an OpenBao answer of 401/403.
var errBaoDenied = errors.New("OpenBao refused the token")

func (a *agent) clock() time.Time {
	if a.now != nil {
		return a.now()
	}
	return time.Now()
}

// baoToken returns a usable OpenBao token: the cached one while it has more
// than tokenReuseMargin left, else a fresh login (SPIRE JWT-SVID first). A
// token with no reported lease is never cached. reused says which.
func (a *agent) baoToken(stdout, stderr io.Writer) (token string, reused bool, ok bool) {
	if a.token != "" && a.clock().Before(a.tokenExpiry.Add(-tokenReuseMargin)) {
		fmt.Fprintf(stdout, "[step-2] OpenBao token reused (expires in %s)\n", a.tokenExpiry.Sub(a.clock()).Round(time.Second))
		return a.token, true, true
	}
	a.token, a.tokenExpiry = "", time.Time{}
	jwt, err := a.fetchSPIFFEIdentity()
	if err != nil {
		fmt.Fprintf(stderr, "[step-1] FAILED: %v\n", err)
		return "", false, false
	}
	fmt.Fprintln(stdout, "[step-1] SPIFFE identity acquired: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent")
	token, ttl, err := a.login(jwt)
	if err != nil {
		fmt.Fprintf(stderr, "[step-2] FAILED: %v\n", err)
		return "", false, false
	}
	if ttl > 0 {
		a.token, a.tokenExpiry = token, a.clock().Add(ttl)
	}
	fmt.Fprintln(stdout, "[step-2] OpenBao token acquired (policies: signalloom-cardvault-agent)")
	return token, false, true
}

func main() {
	os.Exit(entry(os.Args[1:], os.Stdout, os.Stderr))
}

func defaultHTTPClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Second}
}

func combinedOutput(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

func envOr(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func entry(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("cardvault-agent", flag.ContinueOnError)
	fs.SetOutput(stderr)

	mode := fs.String("mode", "run", "operating mode: run or status")
	baoAddr := fs.String("bao-addr", envOr("BAO_ADDR", "http://openbao.inf-bao.svc.cluster.local:8200"), "OpenBao address")
	baoRole := fs.String("bao-role", envOr("BAO_ROLE", "signalloom-cardvault-agent"), "OpenBao JWT role")
	cardvaultURL := fs.String("cardvault-url", envOr("CARDVAULT_URL", "http://cardvault.inf-signalloom.svc.cluster.local:8080"), "Cardvault service URL")
	claimURL := fs.String("claim-url", envOr("CLAIM_URL", ""), "Signal Loom claim API base URL")
	socket := fs.String("socket", "/run/spire/sockets/agent.sock", "SPIRE agent socket path")
	audience := fs.String("audience", "openbao", "JWT-SVID audience")
	var defaultInterval time.Duration
	if v := os.Getenv("INTERVAL"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			defaultInterval = d
		}
	}
	interval := fs.Duration("interval", defaultInterval, "interval between runs (0 runs once and exits)")

	if err := fs.Parse(args); err != nil {
		return 64
	}

	if err := validateEndpointURL(*baoAddr, "OpenBao address"); err != nil {
		fmt.Fprintln(stderr, err)
		return 64
	}
	if err := validateEndpointURL(*cardvaultURL, "Cardvault URL"); err != nil {
		fmt.Fprintln(stderr, err)
		return 64
	}
	if *claimURL != "" {
		if err := validateEndpointURL(*claimURL, "Claim URL"); err != nil {
			fmt.Fprintln(stderr, err)
			return 64
		}
	}

	app := &agent{
		baoAddr:      *baoAddr,
		baoRole:      *baoRole,
		cardvaultURL: *cardvaultURL,
		claimURL:     *claimURL,
		spireSocket:  *socket,
		audience:     *audience,
		invoke:       combinedOutput,
		pause:        time.Sleep,
		client:       defaultHTTPClient(),
	}

	switch *mode {
	case "run":
		if *interval > 0 {
			for {
				app.runDemo(stdout, stderr)
				app.pause(*interval)
			}
		}
		return app.runDemo(stdout, stderr)
	case "status":
		return app.runStatus(stdout)
	default:
		fmt.Fprintf(stderr, "unknown mode %q (use run or status)\n", *mode)
		return 64
	}
}

func (a *agent) runDemo(stdout, stderr io.Writer) int {
	// Steps 1-2: SPIFFE identity via SPIRE, exchanged for an OpenBao token,
	// or the token from an earlier run while it is still good.
	token, reused, ok := a.baoToken(stdout, stderr)
	if !ok {
		return 1
	}

	// Step 2a: Auto-claim with Signal Loom (best-effort — does not block the demo)
	spiffeID := "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent"
	if a.claimURL != "" {
		if claimErr := a.autoClaim(spiffeID, token); claimErr != nil {
			fmt.Fprintf(stdout, "[step-2a] auto-claim skipped: %v\n", claimErr)
		} else {
			fmt.Fprintln(stdout, "[step-2a] auto-claim registered with Signal Loom")
		}
	}

	// Step 3: Read credentials from OpenBao KV. A reused token that OpenBao
	// now refuses (revoked, e.g. by a fleet-manager stun) is dropped and
	// replaced once; a fresh token refused is a real failure.
	username, password, err := a.readCredentials(token)
	if err != nil && reused && errors.Is(err, errBaoDenied) {
		fmt.Fprintln(stdout, "[step-3] cached OpenBao token refused; logging in again")
		a.token, a.tokenExpiry = "", time.Time{}
		if token, _, ok = a.baoToken(stdout, stderr); !ok {
			return 1
		}
		username, password, err = a.readCredentials(token)
	}
	if err != nil {
		fmt.Fprintf(stderr, "[step-3] FAILED: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "[step-3] Credentials retrieved from OpenBao KV (username: %s)\n", username)

	// Step 4: Access cardvault service
	cards, err := a.accessCardvault(username, password)
	if err != nil {
		fmt.Fprintf(stderr, "[step-4] FAILED: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "[step-4] Cardvault access successful — retrieved %d card records\n", len(cards))
	for _, c := range cards {
		fmt.Fprintf(stdout, "  → %s (%s, expires %s)\n", c.Cardholder, c.PANMasked, c.Expiry)
	}

	fmt.Fprintln(stdout, "[complete] SuperCred identity chain verified")
	return 0
}

func (a *agent) runStatus(stdout io.Writer) int {
	fmt.Fprintln(stdout, "cardvault-agent status")
	fmt.Fprintf(stdout, "  BAO_ADDR:      %s\n", a.baoAddr)
	fmt.Fprintf(stdout, "  CARDVAULT_URL:  %s\n", a.cardvaultURL)
	fmt.Fprintf(stdout, "  BAO_ROLE:       %s\n", a.baoRole)
	fmt.Fprintf(stdout, "  SPIRE_SOCKET:   %s\n", a.spireSocket)

	if _, err := os.Stat(a.spireSocket); err == nil {
		fmt.Fprintln(stdout, "  SPIRE socket:   present")
	} else {
		fmt.Fprintln(stdout, "  SPIRE socket:   not found")
	}
	return 0
}

// fetchSPIFFEIdentity shells out to spire-agent and extracts the JWT-SVID.
func (a *agent) fetchSPIFFEIdentity() (string, error) {
	fetchArgs := []string{
		"api", "fetch", "jwt",
		"-audience", a.audience,
		"-socketPath", a.spireSocket,
		"-output", "json",
	}

	var result []byte
	var err error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		result, err = a.invoke(spireAgentBin, fetchArgs...)
		if err == nil {
			break
		}
		if attempt < maxAttempts {
			a.pause(time.Second)
		}
	}
	if err != nil {
		return "", fmt.Errorf("SPIRE agent failed after %d attempts: %s", maxAttempts, strings.TrimSpace(string(result)))
	}

	jwt, extractErr := extractJWT(result)
	if extractErr != nil {
		return "", fmt.Errorf("invalid SPIRE JWT-SVID response: %v", extractErr)
	}
	return jwt, nil
}

// exchangeForBaoToken posts the JWT-SVID to OpenBao's JWT auth endpoint.
func (a *agent) exchangeForBaoToken(jwt string) (string, error) {
	token, _, err := a.login(jwt)
	return token, err
}

func (a *agent) sleep(d time.Duration) {
	if a.pause != nil {
		a.pause(d)
	} else {
		time.Sleep(d)
	}
}

func isTransientHTTPStatus(code int) bool {
	return code == http.StatusBadGateway || code == http.StatusServiceUnavailable || code == http.StatusGatewayTimeout
}

// login is exchangeForBaoToken that also returns the token's lease (0 when
// OpenBao reports none).
func (a *agent) login(jwt string) (string, time.Duration, error) {
	payload, err := json.Marshal(map[string]string{"role": a.baoRole, "jwt": jwt})
	if err != nil {
		return "", 0, fmt.Errorf("encode login request: %w", err)
	}

	urlStr := strings.TrimRight(a.baoAddr, "/") + "/v1/auth/jwt/login"
	if err := validateEndpointURL(urlStr, "OpenBao login endpoint"); err != nil {
		return "", 0, err
	}

	var resp *http.Response
	var body []byte
	const maxRetries = 3

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, reqErr := http.NewRequest(http.MethodPost, urlStr, bytes.NewReader(payload))
		if reqErr != nil {
			return "", 0, fmt.Errorf("create login request: %w", reqErr)
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err = a.client.Do(req)
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return "", 0, fmt.Errorf("OpenBao login: %w", err)
		}

		body, err = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return "", 0, fmt.Errorf("read OpenBao response: %w", err)
		}

		if isTransientHTTPStatus(resp.StatusCode) && attempt < maxRetries {
			a.sleep(500 * time.Millisecond)
			continue
		}
		break
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", 0, fmt.Errorf("OpenBao login returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var result struct {
		Auth struct {
			ClientToken   string `json:"client_token"`
			LeaseDuration int64  `json:"lease_duration"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", 0, fmt.Errorf("decode OpenBao response: %w", err)
	}
	if result.Auth.ClientToken == "" {
		return "", 0, fmt.Errorf("OpenBao response contains no client_token")
	}
	return result.Auth.ClientToken, time.Duration(result.Auth.LeaseDuration) * time.Second, nil
}

// readCredentials fetches username/password from OpenBao KV v2.
func (a *agent) readCredentials(token string) (string, string, error) {
	urlStr := strings.TrimRight(a.baoAddr, "/") + "/v1/kv/data/signalloom/cardvault-agent"
	if err := validateEndpointURL(urlStr, "OpenBao KV endpoint"); err != nil {
		return "", "", err
	}

	var resp *http.Response
	var body []byte
	var err error
	const maxRetries = 3

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, reqErr := http.NewRequest(http.MethodGet, urlStr, nil)
		if reqErr != nil {
			return "", "", fmt.Errorf("create KV request: %w", reqErr)
		}
		req.Header.Set("X-Vault-Token", token)

		resp, err = a.client.Do(req)
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return "", "", fmt.Errorf("OpenBao KV read: %w", err)
		}

		body, err = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return "", "", fmt.Errorf("read KV response: %w", err)
		}

		if isTransientHTTPStatus(resp.StatusCode) && attempt < maxRetries {
			a.sleep(500 * time.Millisecond)
			continue
		}
		break
	}

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return "", "", fmt.Errorf("%w: OpenBao KV returned %d: %s", errBaoDenied, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", "", fmt.Errorf("OpenBao KV returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var result struct {
		Data struct {
			Data struct {
				Username string `json:"username"`
				Password string `json:"password"`
			} `json:"data"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", "", fmt.Errorf("decode KV response: %w", err)
	}
	if result.Data.Data.Username == "" {
		return "", "", fmt.Errorf("KV response missing username")
	}
	return result.Data.Data.Username, result.Data.Data.Password, nil
}

// accessCardvault calls the cardvault API with Basic Auth.
func (a *agent) accessCardvault(username, password string) ([]card, error) {
	urlStr := strings.TrimRight(a.cardvaultURL, "/") + "/api/v1/cards"
	if err := validateEndpointURL(urlStr, "Cardvault endpoint"); err != nil {
		return nil, err
	}

	var resp *http.Response
	var body []byte
	var err error
	const maxRetries = 3

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, reqErr := http.NewRequest(http.MethodGet, urlStr, nil)
		if reqErr != nil {
			return nil, fmt.Errorf("create cardvault request: %w", reqErr)
		}
		req.SetBasicAuth(username, password)

		resp, err = a.client.Do(req)
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return nil, fmt.Errorf("cardvault request: %w", err)
		}

		body, err = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		if err != nil {
			if attempt < maxRetries {
				a.sleep(500 * time.Millisecond)
				continue
			}
			return nil, fmt.Errorf("read cardvault response: %w", err)
		}

		if isTransientHTTPStatus(resp.StatusCode) && attempt < maxRetries {
			a.sleep(500 * time.Millisecond)
			continue
		}
		break
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("cardvault returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var cards []card
	if err := json.Unmarshal(body, &cards); err != nil {
		return nil, fmt.Errorf("decode cardvault response: %w", err)
	}
	return cards, nil
}

// extractJWT recursively searches for the "svid" field in the SPIRE JSON output.
func extractJWT(data []byte) (string, error) {
	var value any
	if err := json.Unmarshal(data, &value); err != nil {
		return "", err
	}
	var svids []string
	collectSVIDs(value, &svids)
	if len(svids) != 1 {
		return "", fmt.Errorf("expected one svid, got %d", len(svids))
	}
	if svids[0] == "" {
		return "", fmt.Errorf("svid is empty")
	}
	return svids[0], nil
}

func collectSVIDs(value any, found *[]string) {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if key == "svid" {
				if text, ok := child.(string); ok {
					*found = append(*found, text)
				}
				continue
			}
			collectSVIDs(child, found)
		}
	case []any:
		for _, child := range typed {
			collectSVIDs(child, found)
		}
	}
}
