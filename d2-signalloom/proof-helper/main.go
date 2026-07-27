package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	payload, err := json.Marshal(map[string]string{"role": role, "jwt": strings.TrimSpace(string(jwt))})
	if err != nil {
		return fmt.Errorf("encode login request: %w", err)
	}
	request, err := http.NewRequest(http.MethodPost, strings.TrimRight(address, "/")+"/v1/auth/jwt/login", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create login request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("OpenBao login: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("read OpenBao response: %w", err)
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("OpenBao login returned %s: %s", response.Status, strings.TrimSpace(string(body)))
	}
	var result struct {
		Auth struct {
			ClientToken string `json:"client_token"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return fmt.Errorf("decode OpenBao response: %w", err)
	}
	if result.Auth.ClientToken == "" {
		return errors.New("OpenBao response contains no client token")
	}
	if err := os.MkdirAll(filepath.Dir(output), 0o700); err != nil {
		return fmt.Errorf("create token directory: %w", err)
	}
	if err := os.WriteFile(output, []byte(result.Auth.ClientToken), 0o600); err != nil {
		return fmt.Errorf("write OpenBao token: %w", err)
	}
	return nil
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
