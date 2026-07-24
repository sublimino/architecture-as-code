package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type TaskMessage struct {
	ID            string                 `json:"id"`
	Type          string                 `json:"type"`
	Payload       map[string]interface{} `json:"payload"`
	CorrelationID string                 `json:"correlation_id"`
	WorkerID      string                 `json:"worker_id,omitempty"`
	Timestamp     int64                  `json:"timestamp"`
}

type NATSListener struct {
	nc         *nats.Conn
	js         jetstream.JetStream
	consumer   jetstream.Consumer
	socketPath string
	workerID   string
}

func main() {
	// Configuration from environment
	natsURL := getEnv("NATS_URL", "nats://nats.backend.svc.cluster.local:4222")
	socketPath := getEnv("SOCKET_PATH", "/shared/tasks.sock")
	workerID := getEnv("WORKER_ID", "worker-1")
	streamName := getEnv("STREAM_NAME", "TASKS")
	consumerName := getEnv("CONSUMER_NAME", "task-workers")
	subject := getEnv("TASK_SUBJECT", "tasks.input")

	listener := &NATSListener{
		socketPath: socketPath,
		workerID:   workerID,
	}

	// Connect to NATS
	if err := listener.connectNATS(natsURL); err != nil {
		log.Fatal("Failed to connect to NATS:", err)
	}
	defer listener.nc.Close()

	// Setup JetStream and consumer
	if err := listener.setupJetStream(streamName, consumerName, subject); err != nil {
		log.Fatal("Failed to setup JetStream:", err)
	}

	// Create Unix domain socket
	if err := listener.createSocket(); err != nil {
		log.Fatal("Failed to create socket:", err)
	}

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Printf("NATS Listener started - Worker ID: %s", workerID)
	log.Printf("Listening on subject: %s", subject)
	log.Printf("Socket path: %s", socketPath)

	// Start consuming messages
	go listener.startConsuming()

	// Wait for shutdown signal
	<-sigChan
	log.Println("Shutting down gracefully...")
	listener.cleanup()
}

func (nl *NATSListener) connectNATS(url string) error {
	var err error
	nl.nc, err = nats.Connect(url,
		nats.Name("task-worker-"+nl.workerID),
		nats.Timeout(5*time.Second),
		nats.ReconnectWait(500*time.Millisecond),
		nats.MaxReconnects(-1),             // Infinite reconnects
		nats.ReconnectBufSize(5*1024*1024), // 5MB buffer for reconnect
		nats.PingInterval(2*time.Second),   // Send ping every 2 seconds
		nats.MaxPingsOutstanding(5),        // Reconnect after 10 seconds (2s * 5) of no heartbeat
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			log.Printf("NATS disconnected: %v", err)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			log.Printf("NATS reconnected to %s", nc.ConnectedUrl())
		}),
	)
	return err
}

func (nl *NATSListener) setupJetStream(streamName, consumerName, subject string) error {
	var err error
	nl.js, err = jetstream.New(nl.nc)
	if err != nil {
		return err
	}

	// Try to get existing stream first
	stream, err := nl.js.Stream(context.Background(), streamName)
	if err != nil {
		log.Printf("Stream %s not found, attempting to create: %v", streamName, err)
		// Create stream if it doesn't exist
		stream, err = nl.js.CreateStream(context.Background(), jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{"tasks.*"},
			Storage:  jetstream.MemoryStorage,
			MaxAge:   time.Hour,
			Replicas: 1,
		})
		if err != nil {
			log.Printf("Failed to create stream, trying to get existing stream: %v", err)
			// If creation fails (likely due to overlap), try to get any existing stream with tasks.* subjects
			streams := nl.js.ListStreams(context.Background())
			for info := range streams.Info() {
				for _, subject := range info.Config.Subjects {
					if subject == "tasks.*" {
						log.Printf("Found existing stream with tasks.* subjects: %s", info.Config.Name)
						stream, err = nl.js.Stream(context.Background(), info.Config.Name)
						if err == nil {
							goto streamFound
						}
					}
				}
			}
			return fmt.Errorf("no suitable stream found for tasks.* subjects: %v", err)
		}
	}
streamFound:

	// Create or get consumer with work queue delivery
	nl.consumer, err = stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Name:          consumerName,
		FilterSubject: subject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		ReplayPolicy:  jetstream.ReplayInstantPolicy,
		MaxDeliver:    3,
		AckWait:       30 * time.Second,
	})
	if err != nil {
		return err
	}

	log.Printf("JetStream setup complete - Stream: %s, Consumer: %s", streamName, consumerName)
	return nil
}

func (nl *NATSListener) createSocket() error {
	// Remove socket if it exists
	os.Remove(nl.socketPath)

	listener, err := net.Listen("unix", nl.socketPath)
	if err != nil {
		return err
	}

	// Set restrictive permissions (owner read/write only)
	if err := os.Chmod(nl.socketPath, 0600); err != nil {
		listener.Close()
		return err
	}

	// Accept connections in background
	go func() {
		defer listener.Close()
		for {
			conn, err := listener.Accept()
			if err != nil {
				log.Printf("Socket accept error: %v", err)
				break
			}
			// Store connection for sending messages
			nl.handleSocketConnection(conn)
		}
	}()

	return nil
}

var socketConn net.Conn

func (nl *NATSListener) handleSocketConnection(conn net.Conn) {
	socketConn = conn
	log.Println("Socket client connected")

	// Keep connection alive, handle disconnections
	go func() {
		defer conn.Close()
		for {
			// Simple keepalive - read any data and ignore
			buffer := make([]byte, 1024)
			_, err := conn.Read(buffer)
			if err != nil {
				log.Println("Socket client disconnected")
				socketConn = nil
				break
			}
		}
	}()
}

func (nl *NATSListener) startConsuming() {
	for {
		// Create message iterator (or recreate after connection errors)
		iter, err := nl.consumer.Messages()
		if err != nil {
			log.Printf("Failed to create message iterator: %v. Retrying in 5 seconds...", err)
			time.Sleep(5 * time.Second)
			continue
		}

		log.Println("Message iterator created successfully, starting to consume messages")

		// Consume messages from this iterator until it fails
		for {
			msg, err := iter.Next()
			if err != nil {
				log.Printf("Error receiving message: %v", err)
				// Check if this is a connection/heartbeat error that requires iterator recreation
				if isConnectionError(err) {
					log.Println("Connection error detected, recreating iterator...")
					iter.Stop()
					time.Sleep(2 * time.Second)
					break // Break inner loop to recreate iterator
				}
				log.Println("NO CONNECTION ERROR")
				// For other errors, just retry
				time.Sleep(time.Second)
				continue
			}

			// Process message
			if err := nl.processMessage(msg); err != nil {
				log.Printf("Error processing message: %v", err)
				// Negative acknowledgment - requeue message
				msg.Nak()
			} else {
				// Acknowledge successful processing
				msg.Ack()
			}
		}
	}
}

func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	log.Printf("Validating NATS connection error: %v", err)

	// Check error message strings for connection-related errors
	errMsg := err.Error()
	if errMsg == "nats: no heartbeat received" ||
		errMsg == "nats: connection closed" ||
		errMsg == "nats: timeout" ||
		errMsg == "nats: connection disconnected" {
		return true
	}

	// Use errors.Is to check for known NATS/JetStream connection errors
	return errors.Is(err, nats.ErrNoHeartbeat) ||
		errors.Is(err, nats.ErrConnectionClosed) ||
		errors.Is(err, nats.ErrTimeout) ||
		errors.Is(err, nats.ErrDisconnected) ||
		errors.Is(err, jetstream.ErrConsumerDeleted) ||
		errors.Is(err, jetstream.ErrConsumerLeadershipChanged)
}

func (nl *NATSListener) processMessage(msg jetstream.Msg) error {
	log.Printf("Received message on subject: %s", msg.Subject())

	// Parse the task message
	var task TaskMessage
	if err := json.Unmarshal(msg.Data(), &task); err != nil {
		log.Printf("Invalid JSON in message: %v", err)
		return err
	}

	// Add worker ID and processing timestamp
	task.WorkerID = nl.workerID
	task.Timestamp = time.Now().Unix()

	// Send to socket if connected
	if socketConn != nil {
		taskJSON, err := json.Marshal(task)
		if err != nil {
			return err
		}

		// Send JSON line to socket
		if _, err := socketConn.Write(append(taskJSON, '\n')); err != nil {
			log.Printf("Failed to write to socket: %v", err)
			socketConn = nil
			return err
		}

		log.Printf("Sent task %s to processor via socket", task.ID)
	} else {
		log.Printf("No socket connection available for task %s", task.ID)
		return fmt.Errorf("no socket connection")
	}

	return nil
}

func (nl *NATSListener) cleanup() {
	// Remove socket file
	os.Remove(nl.socketPath)

	// Close NATS connection
	if nl.nc != nil {
		nl.nc.Close()
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
