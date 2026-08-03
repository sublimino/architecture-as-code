package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	spireAgent  = "/usr/local/bin/spire-agent"
	maxAttempts = 30
)

var openBaoClient = &http.Client{Timeout: 30 * time.Second}

type commandRunner func(name string, args ...string) ([]byte, error)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, combinedOutput))
}

func combinedOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

func run(args []string, stdout, stderr io.Writer, invoke commandRunner) int {
	return runWithPause(args, stdout, stderr, invoke, time.Sleep)
}

func runWithPause(args []string, stdout, stderr io.Writer, invoke commandRunner, pause func(time.Duration)) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: signalloom-spire-proof <write|exchange|expect-denied> [flags]")
		return 64
	}

	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	audience := flags.String("audience", "openbao", "JWT-SVID audience")
	socket := flags.String("socket", "/run/spire/sockets/agent.sock", "SPIRE agent socket")
	output := flags.String("output", "/work/jwt", "JWT-SVID output file")
	address := flags.String("address", "http://openbao.inf-bao.svc.cluster.local:8200", "OpenBao address")
	role := flags.String("role", "signalloom-fe-signalloom", "OpenBao JWT role")
	jwtPath := flags.String("jwt", "/work/jwt", "JWT-SVID input file")
	expectedSubject := flags.String("expected-subject", "", "exact caller SPIFFE ID")
	listen := flags.String("listen", ":8080", "A2A receiver listen address")
	target := flags.String("target", "http://agent-trust-triage:8080/a2a", "A2A receiver URL")
	privateKeyPath := flags.String("signing-key", "/run/agent-trust/private.pem", "request signing key")
	publicKeyPath := flags.String("public-key", "/run/agent-trust/public.pem", "request verification key")
	if err := flags.Parse(args[1:]); err != nil {
		return 64
	}
	if args[0] == "exchange" {
		if err := exchangeJWT(openBaoClient, *address, *role, *jwtPath, *output); err != nil {
			fmt.Fprintf(stderr, "exchange JWT-SVID: %v\n", err)
			return 1
		}
		return 0
	}
	if args[0] == "serve-a2a" {
		if *expectedSubject == "" {
			fmt.Fprintln(stderr, "serve-a2a requires -expected-subject")
			return 64
		}
		publicKey, err := loadPublicKey(*publicKeyPath)
		if err != nil {
			fmt.Fprintf(stderr, "load A2A public key: %v\n", err)
			return 1
		}
		server := &http.Server{Addr: *listen, Handler: newA2AHandler(openBaoClient, *address, *role, *expectedSubject, publicKey), ReadHeaderTimeout: 5 * time.Second}
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Fprintf(stderr, "serve A2A: %v\n", err)
			return 1
		}
		return 0
	}

	fetchArgs := []string{"api", "fetch", "jwt", "-audience", *audience, "-socketPath", *socket, "-output", "json"}
	switch args[0] {
	case "write":
		var result []byte
		var err error
		for attempt := 1; attempt <= maxAttempts; attempt++ {
			result, err = invoke(spireAgent, fetchArgs...)
			if err == nil {
				break
			}
			if attempt < maxAttempts {
				pause(time.Second)
			}
		}
		if err != nil {
			fmt.Fprint(stderr, string(result))
			return 1
		}
		jwt, extractErr := extractJWT(result)
		if extractErr != nil {
			fmt.Fprintf(stderr, "invalid SPIRE JWT-SVID response: %v\n", extractErr)
			return 1
		}
		if writeErr := os.WriteFile(*output, []byte(jwt), 0o600); writeErr != nil {
			fmt.Fprintf(stderr, "write JWT-SVID: %v\n", writeErr)
			return 1
		}
		return 0
	case "expect-denied":
		var result []byte
		for attempt := 1; attempt <= maxAttempts; attempt++ {
			var err error
			result, err = invoke(spireAgent, fetchArgs...)
			if err == nil {
				fmt.Fprintln(stderr, "unexpected identity")
				return 1
			}
			message := string(result)
			if strings.Contains(message, "PermissionDenied") || strings.Contains(message, "no identity issued") {
				fmt.Fprintln(stdout, "denied as expected")
				return 0
			}
			if attempt < maxAttempts {
				pause(time.Second)
			}
		}
		fmt.Fprint(stderr, string(result))
		return 1
	case "call-a2a":
		result, err := invoke(spireAgent, fetchArgs...)
		if err != nil {
			fmt.Fprint(stderr, string(result))
			return 1
		}
		jwt, extractErr := extractJWT(result)
		if extractErr != nil {
			fmt.Fprintf(stderr, "invalid SPIRE JWT-SVID response: %v\n", extractErr)
			return 1
		}
		privateKey, keyErr := loadPrivateKey(*privateKeyPath)
		if keyErr != nil {
			fmt.Fprintf(stderr, "load A2A signing key: %v\n", keyErr)
			return 1
		}
		if err := callA2A(openBaoClient, *target, jwt, privateKey); err != nil {
			fmt.Fprintf(stderr, "call A2A: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "authenticated A2A request allowed")
		return 0
	default:
		fmt.Fprintf(stderr, "unknown mode %q\n", args[0])
		return 64
	}
}

func exchangeJWT(client *http.Client, address, role, jwtPath, output string) error {
	jwt, err := os.ReadFile(jwtPath)
	if err != nil {
		return fmt.Errorf("read JWT-SVID: %w", err)
	}
	token, err := loginJWT(client, address, role, strings.TrimSpace(string(jwt)))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(output), 0o700); err != nil {
		return fmt.Errorf("create token directory: %w", err)
	}
	if err := os.WriteFile(output, []byte(token), 0o600); err != nil {
		return fmt.Errorf("write OpenBao token: %w", err)
	}
	return nil
}

func loginJWT(client *http.Client, address, role, jwt string) (string, error) {
	payload, err := json.Marshal(map[string]string{"role": role, "jwt": jwt})
	if err != nil {
		return "", fmt.Errorf("encode login request: %w", err)
	}
	request, err := http.NewRequest(http.MethodPost, strings.TrimRight(address, "/")+"/v1/auth/jwt/login", bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("create login request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("OpenBao login: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("read OpenBao response: %w", err)
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return "", fmt.Errorf("OpenBao login returned %s: %s", response.Status, strings.TrimSpace(string(body)))
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
		return "", errors.New("OpenBao response contains no client token")
	}
	return result.Auth.ClientToken, nil
}

var a2aResource = regexp.MustCompile(`^case/[A-Za-z0-9_-]{1,123}$`)

type replayCache struct {
	mu   sync.Mutex
	seen map[string]int64
	max  int
}

func newReplayCache(max int) *replayCache {
	return &replayCache{seen: make(map[string]int64), max: max}
}

func (cache *replayCache) consume(nonce string, expires, now int64) bool {
	if nonce == "" || expires <= now {
		return false
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	for key, expiry := range cache.seen {
		if expiry <= now {
			delete(cache.seen, key)
		}
	}
	if _, exists := cache.seen[nonce]; exists || len(cache.seen) >= cache.max {
		return false
	}
	cache.seen[nonce] = expires
	return true
}

func newA2AHandler(client *http.Client, address, role, expectedSubject string, publicKey ed25519.PublicKey) http.Handler {
	instanceBytes := make([]byte, 16)
	if _, err := rand.Read(instanceBytes); err != nil {
		panic("generate receiver instance nonce: " + err.Error())
	}
	return newA2AHandlerWithInstance(client, address, role, expectedSubject, publicKey, base64.RawURLEncoding.EncodeToString(instanceBytes))
}

func newA2AHandlerWithInstance(client *http.Client, address, role, expectedSubject string, publicKey ed25519.PublicKey, instanceNonce string) http.Handler {
	mux := http.NewServeMux()
	replay := newReplayCache(10000)
	mux.HandleFunc("/readyz", func(response http.ResponseWriter, _ *http.Request) { response.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/challenge", func(response http.ResponseWriter, _ *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(map[string]string{"instanceNonce": instanceNonce})
	})
	mux.HandleFunc("/a2a", func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost {
			http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		jwt := request.Header.Get("X-SPIFFE-JWT-SVID")
		if jwt == "" {
			http.Error(response, "missing SPIFFE JWT-SVID", http.StatusForbidden)
			return
		}
		if _, err := loginJWT(client, address, role, jwt); err != nil {
			log.Printf("OpenBao JWT-SVID validation denied: %v", err)
			http.Error(response, "OpenBao identity denied", http.StatusForbidden)
			return
		}
		if jwtSubject(jwt) != expectedSubject {
			http.Error(response, "SPIFFE subject denied", http.StatusForbidden)
			return
		}
		bodyBytes, err := io.ReadAll(io.LimitReader(request.Body, 4097))
		if err != nil || len(bodyBytes) > 4096 {
			http.Error(response, "invalid request", http.StatusForbidden)
			return
		}
		timestamp, err := strconv.ParseInt(request.Header.Get("X-Agent-Trust-Timestamp"), 10, 64)
		nonce := request.Header.Get("X-Agent-Trust-Nonce")
		instance := request.Header.Get("X-Agent-Trust-Instance")
		signature, signatureErr := base64.RawURLEncoding.DecodeString(request.Header.Get("X-Agent-Trust-Signature"))
		now := time.Now().Unix()
		if err != nil || signatureErr != nil || instance != instanceNonce || timestamp < now-30 || timestamp > now+30 || !ed25519.Verify(publicKey, authorizationMessage(jwt, timestamp, nonce, instance, bodyBytes), signature) {
			http.Error(response, "authorization context denied", http.StatusForbidden)
			return
		}
		var body struct{ Action, Resource string }
		decoder := json.NewDecoder(bytes.NewReader(bodyBytes))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&body); err != nil || body.Action != "triage.analyze" || !a2aResource.MatchString(body.Resource) {
			http.Error(response, "authorization denied", http.StatusForbidden)
			return
		}
		if !replay.consume(nonce, now+60, now) {
			http.Error(response, "replayed authorization context", http.StatusForbidden)
			return
		}
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(map[string]string{"caller": expectedSubject, "decision": "allow"})
	})
	return mux
}

func jwtSubject(jwt string) string {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Subject string `json:"sub"`
	}
	if json.Unmarshal(payload, &claims) != nil {
		return ""
	}
	return claims.Subject
}

func callA2A(client *http.Client, target, jwt string, privateKey ed25519.PrivateKey) error {
	body := []byte(`{"Action":"triage.analyze","Resource":"case/runtime-proof"}`)
	instance, err := fetchReceiverChallenge(client, target)
	if err != nil {
		return err
	}
	nonceBytes := make([]byte, 16)
	if _, err := rand.Read(nonceBytes); err != nil {
		return err
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	timestamp := time.Now().Unix()
	request, err := http.NewRequest(http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-SPIFFE-JWT-SVID", jwt)
	request.Header.Set("X-Agent-Trust-Timestamp", strconv.FormatInt(timestamp, 10))
	request.Header.Set("X-Agent-Trust-Nonce", nonce)
	request.Header.Set("X-Agent-Trust-Instance", instance)
	request.Header.Set("X-Agent-Trust-Signature", base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, authorizationMessage(jwt, timestamp, nonce, instance, body))))
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return fmt.Errorf("receiver returned %s: %s", response.Status, strings.TrimSpace(string(message)))
	}
	return nil
}

func fetchReceiverChallenge(client *http.Client, target string) (string, error) {
	challengeURL, err := url.Parse(target)
	if err != nil {
		return "", err
	}
	challengeURL.Path = "/challenge"
	challengeURL.RawQuery = ""
	response, err := client.Get(challengeURL.String())
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("challenge returned %s", response.Status)
	}
	var challenge struct {
		InstanceNonce string `json:"instanceNonce"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&challenge) != nil || challenge.InstanceNonce == "" {
		return "", errors.New("invalid receiver challenge")
	}
	return challenge.InstanceNonce, nil
}

func authorizationMessage(jwt string, timestamp int64, nonce, instance string, body []byte) []byte {
	jwtDigest := sha256.Sum256([]byte(jwt))
	bodyDigest := sha256.Sum256(body)
	return []byte(fmt.Sprintf("%x\n%d\n%s\n%s\n%x", jwtDigest, timestamp, nonce, instance, bodyDigest))
}

func loadPrivateKey(path string) (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("invalid private key PEM")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	privateKey, ok := key.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not Ed25519")
	}
	return privateKey, nil
}

func loadPublicKey(path string) (ed25519.PublicKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("invalid public key PEM")
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	publicKey, ok := key.(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("public key is not Ed25519")
	}
	return publicKey, nil
}

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
		return "", errors.New("svid is empty")
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
