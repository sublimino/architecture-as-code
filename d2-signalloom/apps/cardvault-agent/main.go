package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

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
	spireSocket  string
	audience     string
	invoke       commandRunner
	pause        func(time.Duration)
	client       *http.Client
}

func main() {
	os.Exit(entry(os.Args[1:], os.Stdout, os.Stderr))
}

func defaultHTTPClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Second}
}

func combinedOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
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
	socket := fs.String("socket", "/run/spire/sockets/agent.sock", "SPIRE agent socket path")
	audience := fs.String("audience", "openbao", "JWT-SVID audience")

	if err := fs.Parse(args); err != nil {
		return 64
	}

	app := &agent{
		baoAddr:      *baoAddr,
		baoRole:      *baoRole,
		cardvaultURL: *cardvaultURL,
		spireSocket:  *socket,
		audience:     *audience,
		invoke:       combinedOutput,
		pause:        time.Sleep,
		client:       defaultHTTPClient(),
	}

	switch *mode {
	case "run":
		return app.runDemo(stdout, stderr)
	case "status":
		return app.runStatus(stdout)
	default:
		fmt.Fprintf(stderr, "unknown mode %q (use run or status)\n", *mode)
		return 64
	}
}

func (a *agent) runDemo(stdout, stderr io.Writer) int {
	// Step 1: Fetch SPIFFE identity via SPIRE
	jwt, err := a.fetchSPIFFEIdentity()
	if err != nil {
		fmt.Fprintf(stderr, "[step-1] FAILED: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "[step-1] SPIFFE identity acquired: spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent")

	// Step 2: Exchange JWT for OpenBao token
	token, err := a.exchangeForBaoToken(jwt)
	if err != nil {
		fmt.Fprintf(stderr, "[step-2] FAILED: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "[step-2] OpenBao token acquired (policies: signalloom-cardvault-agent)")

	// Step 3: Read credentials from OpenBao KV
	username, password, err := a.readCredentials(token)
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
	payload, err := json.Marshal(map[string]string{"role": a.baoRole, "jwt": jwt})
	if err != nil {
		return "", fmt.Errorf("encode login request: %w", err)
	}

	url := strings.TrimRight(a.baoAddr, "/") + "/v1/auth/jwt/login"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("create login request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("OpenBao login: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("read OpenBao response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("OpenBao login returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var result struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("decode OpenBao response: %w", err)
	}
	if result.Auth.ClientToken == "" {
		return "", fmt.Errorf("OpenBao response contains no client_token")
	}
	return result.Auth.ClientToken, nil
}

// readCredentials fetches username/password from OpenBao KV v2.
func (a *agent) readCredentials(token string) (string, string, error) {
	url := strings.TrimRight(a.baoAddr, "/") + "/v1/kv/data/signalloom/cardvault-agent"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", "", fmt.Errorf("create KV request: %w", err)
	}
	req.Header.Set("X-Vault-Token", token)

	resp, err := a.client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("OpenBao KV read: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", "", fmt.Errorf("read KV response: %w", err)
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
	url := strings.TrimRight(a.cardvaultURL, "/") + "/api/v1/cards"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("create cardvault request: %w", err)
	}
	req.SetBasicAuth(username, password)

	resp, err := a.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("cardvault request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read cardvault response: %w", err)
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
