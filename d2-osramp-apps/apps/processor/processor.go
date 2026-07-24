package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/text/language"
)

type TaskMessage struct {
	ID      string                 `json:"id"`
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload"`
}

func main() {
	socketPath := os.Getenv("SOCKET_PATH")
	if socketPath == "" {
		socketPath = "/shared/tasks.sock"
	}

	// WORKER_LOCALE tags this worker's log output. x/text is pinned to v0.3.7,
	// which CVE-2022-32149 marks as vulnerable in language.ParseAcceptLanguage,
	// a function this program never calls. The Phase 1 VEX demo depends on this
	// exact module version to show govulncheck separating an SBOM finding from
	// reachable risk. Do not bump the pin without updating the VEX demo.
	workerLocale, err := language.Parse(envOr("WORKER_LOCALE", "en"))
	if err != nil {
		log.Fatal("Invalid WORKER_LOCALE:", err)
	}

	log.Printf("Starting processor service (locale %s), waiting for socket: %s", workerLocale, socketPath)

	// Wait for socket to exist
	for {
		if _, err := os.Stat(socketPath); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	log.Printf("Connecting to socket: %s", socketPath)
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		log.Fatal("Failed to connect to socket:", err)
	}
	defer conn.Close()

	log.Println("Connected to socket, waiting for tasks...")
	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		var task TaskMessage
		if err := json.Unmarshal(scanner.Bytes(), &task); err != nil {
			log.Printf("Invalid JSON: %v", err)
			continue
		}

		log.Printf("Received task: %s (type: %s)", task.ID, task.Type)
		// Execute command with JSON context
		go processTask(task)
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Scanner error: %v", err)
	}
}

func processTask(task TaskMessage) {
	log.Printf("Processing task %s...", task.ID)

	// Pass JSON as environment variable (secure)
	cmd := exec.Command("/app/processor")
	cmd.Env = append(os.Environ(),
		"TASK_JSON="+string(mustMarshal(task)),
		"TASK_ID="+task.ID,
	)

	// Only drop privileges if running as root
	if os.Getuid() == 0 {
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Credential: &syscall.Credential{
				Uid: 65532,
				Gid: 65532,
			},
		}
	}

	if output, err := cmd.CombinedOutput(); err != nil {
		log.Printf("Task %s failed: %v, output: %s", task.ID, err, output)
	} else {
		log.Printf("Task %s completed successfully, output: %s", task.ID, string(output))
	}
}

func mustMarshal(v interface{}) []byte {
	data, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return data
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
