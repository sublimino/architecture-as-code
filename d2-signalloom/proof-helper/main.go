package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	spireAgent  = "/usr/local/bin/spire-agent"
	maxAttempts = 30
)

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
		fmt.Fprintln(stderr, "usage: signalloom-spire-proof <write|expect-denied> [flags]")
		return 64
	}

	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(stderr)
	audience := flags.String("audience", "openbao", "JWT-SVID audience")
	socket := flags.String("socket", "/run/spire/sockets/agent.sock", "SPIRE agent socket")
	output := flags.String("output", "/work/jwt", "JWT-SVID output file")
	if err := flags.Parse(args[1:]); err != nil {
		return 64
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
				return 1
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
