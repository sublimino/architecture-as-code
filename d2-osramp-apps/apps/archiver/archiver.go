package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type TaskResult struct {
	TaskID        string                 `json:"task_id"`
	CorrelationID string                 `json:"correlation_id"`
	WorkerID      string                 `json:"worker_id"`
	Status        string                 `json:"status"`
	ResultType    string                 `json:"result_type"`
	CompletedAt   string                 `json:"completed_at"`
	ResultData    map[string]interface{} `json:"result_data"`
}

type TaskSignature struct {
	TaskID    string `json:"task_id"`
	Signature string `json:"signature"`
	Algorithm string `json:"algorithm"`
	PublicKey string `json:"public_key"`
}

type SBOMData struct {
	SBOMId         string                 `json:"sbom_id"`
	TaskID         string                 `json:"task_id"`
	PackageName    string                 `json:"package_name"`
	PackageVersion string                 `json:"package_version"`
	SBOMFormat     string                 `json:"sbom_format"`
	ComponentCount int                    `json:"component_count"`
	FilePath       string                 `json:"file_path"`
	SBOMJson       map[string]interface{} `json:"sbom_json"`
	CorrelationID  string                 `json:"correlation_id"`
	WorkerID       string                 `json:"worker_id"`
	Timestamp      int64                  `json:"timestamp"`
}

type NATSArchiver struct {
	nc                *nats.Conn
	js                jetstream.JetStream
	resultConsumer    jetstream.Consumer
	sbomConsumer      jetstream.Consumer
	signatureConsumer jetstream.Consumer
	db                *sql.DB
	workerID          string
}

func main() {
	// Configuration from environment
	natsURL := getEnv("NATS_URL", "nats://nats.backend.svc.cluster.local:4222")
	workerID := getEnv("WORKER_ID", "archiver-1")
	streamName := getEnv("STREAM_NAME", "TASK_RESULTS")
	consumerName := getEnv("CONSUMER_NAME", "task-archiver")
	resultSubject := getEnv("RESULT_SUBJECT", "tasks.results")
	sbomSubject := getEnv("SBOM_SUBJECT", "tasks.sbom")
	signatureSubject := getEnv("SIGNATURE_SUBJECT", "tasks.signatures")

	// Postgres configuration
	dbHost := getEnv("DB_HOST", "postgres")
	dbPort := getEnv("DB_PORT", "5432")
	dbName := getEnv("DB_NAME", "task_archive")
	dbUser := getEnv("DB_USER", "archiver")
	dbPassword := getEnv("DB_PASSWORD", "")
	sslMode := getEnv("DB_SSL_MODE", "disable")

	archiver := &NATSArchiver{
		workerID: workerID,
	}

	// Connect to Postgres
	if err := archiver.connectDB(dbHost, dbPort, dbName, dbUser, dbPassword, sslMode); err != nil {
		log.Fatal("Failed to connect to Postgres:", err)
	}
	defer archiver.db.Close()

	// Initialize database schema
	if err := archiver.initializeSchema(); err != nil {
		log.Fatal("Failed to initialize database schema:", err)
	}

	// Connect to NATS
	if err := archiver.connectNATS(natsURL); err != nil {
		log.Fatal("Failed to connect to NATS:", err)
	}
	defer archiver.nc.Close()

	// Setup JetStream and consumers for the archived subjects
	if err := archiver.setupJetStream(streamName, consumerName, resultSubject, sbomSubject, signatureSubject); err != nil {
		log.Fatal("Failed to setup JetStream:", err)
	}

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Printf("NATS Archiver started - Worker ID: %s", workerID)
	log.Printf("Listening on subjects: %s, %s, %s", resultSubject, sbomSubject, signatureSubject)
	log.Printf("Database: %s@%s:%s/%s", dbUser, dbHost, dbPort, dbName)

	// Start consuming messages
	go archiver.startConsuming()

	// Wait for shutdown signal
	<-sigChan
	log.Println("Shutting down gracefully...")
	archiver.cleanup()
}

func (na *NATSArchiver) connectDB(host, port, dbName, user, password, sslMode string) error {
	dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		user, password, host, port, dbName, sslMode)

	var err error
	na.db, err = sql.Open("pgx", dsn)
	if err != nil {
		return err
	}

	// Test connection
	if err := na.db.Ping(); err != nil {
		return err
	}

	// Configure connection pool
	na.db.SetMaxOpenConns(10)
	na.db.SetMaxIdleConns(5)
	na.db.SetConnMaxLifetime(time.Hour)

	log.Printf("Connected to Postgres: %s@%s:%s/%s", user, host, port, dbName)
	return nil
}

func (na *NATSArchiver) initializeSchema() error {
	// Create task_results table
	// task_id is UNIQUE so the signature and SBOM tables can reference it;
	// task ids embed a timestamp so collisions do not occur in practice
	createTaskResults := `
	CREATE TABLE IF NOT EXISTS task_results (
		id BIGSERIAL PRIMARY KEY,
		task_id VARCHAR(255) NOT NULL UNIQUE,
		correlation_id VARCHAR(255),
		worker_id VARCHAR(255),
		status VARCHAR(50) NOT NULL,
		result_type VARCHAR(100),
		completed_at TIMESTAMP WITHOUT TIME ZONE,
		result_data JSONB,
		archived_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
	);

	CREATE INDEX IF NOT EXISTS idx_task_results_task_id ON task_results (task_id);
	CREATE INDEX IF NOT EXISTS idx_task_results_status ON task_results (status);
	CREATE INDEX IF NOT EXISTS idx_task_results_completed_at ON task_results (completed_at);
	CREATE INDEX IF NOT EXISTS idx_task_results_archived_at ON task_results (archived_at);`

	if _, err := na.db.Exec(createTaskResults); err != nil {
		return err
	}

	// Create task_signatures table for future use
	createTaskSignatures := `
	CREATE TABLE IF NOT EXISTS task_signatures (
		id BIGSERIAL PRIMARY KEY,
		task_id VARCHAR(255) NOT NULL,
		signature TEXT NOT NULL,
		algorithm VARCHAR(50) NOT NULL,
		public_key TEXT,
		created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

		CONSTRAINT fk_signature_task_result
			FOREIGN KEY (task_id)
			REFERENCES task_results (task_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS idx_task_signatures_task_id ON task_signatures (task_id);
	CREATE INDEX IF NOT EXISTS idx_task_signatures_algorithm ON task_signatures (algorithm);`

	if _, err := na.db.Exec(createTaskSignatures); err != nil {
		return err
	}

	// Create sbom_data table for storing complete SBOM JSON
	createSBOMData := `
	CREATE TABLE IF NOT EXISTS sbom_data (
		id BIGSERIAL PRIMARY KEY,
		task_id VARCHAR(255) NOT NULL,
		sbom_id VARCHAR(255) NOT NULL UNIQUE,
		package_name VARCHAR(255) NOT NULL,
		package_version VARCHAR(255) NOT NULL,
		sbom_format VARCHAR(50) NOT NULL DEFAULT 'spdx-json',
		component_count INTEGER DEFAULT 0,
		sbom_json TEXT NOT NULL,
		file_path VARCHAR(500),
		created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,

		CONSTRAINT fk_sbom_task_result
			FOREIGN KEY (task_id)
			REFERENCES task_results (task_id)
			ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS idx_sbom_data_task_id ON sbom_data (task_id);
	CREATE INDEX IF NOT EXISTS idx_sbom_data_package_name ON sbom_data (package_name);
	CREATE INDEX IF NOT EXISTS idx_sbom_data_package_version ON sbom_data (package_version);
	CREATE INDEX IF NOT EXISTS idx_sbom_data_sbom_format ON sbom_data (sbom_format);`

	if _, err := na.db.Exec(createSBOMData); err != nil {
		return err
	}

	log.Println("Database schema initialized successfully")
	return nil
}

func (na *NATSArchiver) connectNATS(url string) error {
	var err error
	na.nc, err = nats.Connect(url,
		nats.Name("task-archiver-"+na.workerID),
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

func (na *NATSArchiver) setupJetStream(streamName, consumerName, resultSubject, sbomSubject, signatureSubject string) error {
	var err error
	na.js, err = jetstream.New(na.nc)
	if err != nil {
		return err
	}

	// Get existing stream (created by listener)
	stream, err := na.js.Stream(context.Background(), streamName)
	if err != nil {
		log.Printf("Stream %s not found, will try to use existing streams", streamName)
		// List available streams to find the right one
		streams := na.js.ListStreams(context.Background())
		for info := range streams.Info() {
			log.Printf("Available stream: %s with subjects: %v", info.Config.Name, info.Config.Subjects)
			// Check if this stream handles our subjects
			for _, subj := range info.Config.Subjects {
				if subj == "tasks.*" || subj == resultSubject || subj == sbomSubject {
					log.Printf("Using existing stream: %s", info.Config.Name)
					stream, err = na.js.Stream(context.Background(), info.Config.Name)
					if err != nil {
						continue
					}
					goto createConsumers
				}
			}
		}
		if stream == nil {
			return fmt.Errorf("no suitable stream found for subjects %s, %s", resultSubject, sbomSubject)
		}
	}

createConsumers:

	// Create consumer for task results
	na.resultConsumer, err = stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Name:          consumerName + "-results",
		FilterSubject: resultSubject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		ReplayPolicy:  jetstream.ReplayInstantPolicy,
		MaxDeliver:    5,                // More retries for archival
		AckWait:       60 * time.Second, // Longer timeout for DB operations
	})
	if err != nil {
		return err
	}

	// Create consumer for SBOM data
	na.sbomConsumer, err = stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Name:          consumerName + "-sbom",
		FilterSubject: sbomSubject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		ReplayPolicy:  jetstream.ReplayInstantPolicy,
		MaxDeliver:    5,                // More retries for archival
		AckWait:       60 * time.Second, // Longer timeout for DB operations
	})
	if err != nil {
		return err
	}

	// Create consumer for witness attestation signatures
	na.signatureConsumer, err = stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Name:          consumerName + "-signatures",
		FilterSubject: signatureSubject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverAllPolicy,
		ReplayPolicy:  jetstream.ReplayInstantPolicy,
		MaxDeliver:    5,
		AckWait:       60 * time.Second,
	})
	if err != nil {
		return err
	}

	log.Printf("JetStream setup complete - Stream: %s, Consumers: %s-results, %s-sbom, %s-signatures", streamName, consumerName, consumerName, consumerName)
	return nil
}

func (na *NATSArchiver) startConsuming() {
	go na.consumeFromConsumer(na.resultConsumer, "results")
	go na.consumeFromConsumer(na.sbomConsumer, "sbom")
	go na.consumeFromConsumer(na.signatureConsumer, "signatures")
}

func (na *NATSArchiver) consumeFromConsumer(consumer jetstream.Consumer, consumerType string) {
	for {
		// Create message iterator (or recreate after connection errors)
		iter, err := consumer.Messages()
		if err != nil {
			log.Printf("Failed to create message iterator for %s consumer: %v. Retrying in 5 seconds...", consumerType, err)
			time.Sleep(5 * time.Second)
			continue
		}

		log.Printf("Message iterator created successfully for %s consumer, starting to consume messages", consumerType)

		// Consume messages from this iterator until it fails
		for {
			msg, err := iter.Next()
			if err != nil {
				log.Printf("Error receiving message from %s consumer: %v", consumerType, err)
				// Check if this is a connection/heartbeat error that requires iterator recreation
				if isConnectionError(err) {
					log.Printf("Connection error detected for %s consumer, recreating iterator...", consumerType)
					iter.Stop()
					time.Sleep(2 * time.Second)
					break // Break inner loop to recreate iterator
				}
				log.Println("NO CONNECTION ERROR")
				// For other errors, just retry
				time.Sleep(time.Second)
				continue
			}

			// Process message based on subject
			if err := na.processMessage(msg); err != nil {
				log.Printf("Error processing %s message: %v", consumerType, err)
				// Negative acknowledgment - requeue message
				msg.Nak()
			} else {
				// Acknowledge successful processing
				msg.Ack()
			}
		}
	}
}

func (na *NATSArchiver) processMessage(msg jetstream.Msg) error {
	log.Printf("Received message on subject: %s", msg.Subject())

	switch msg.Subject() {
	case "tasks.results":
		return na.processTaskResult(msg.Data())
	case "tasks.signatures":
		return na.processTaskSignature(msg.Data())
	case "tasks.sbom":
		return na.processSBOMData(msg.Data())
	default:
		log.Printf("Unknown subject: %s", msg.Subject())
		return nil
	}
}

func (na *NATSArchiver) processTaskResult(data []byte) error {
	var result TaskResult
	if err := json.Unmarshal(data, &result); err != nil {
		log.Printf("Invalid JSON in task result: %v", err)
		return err
	}

	// Convert result_data to JSON string for storage
	resultDataJSON, err := json.Marshal(result.ResultData)
	if err != nil {
		return err
	}

	// Parse completed_at timestamp
	var completedAt *time.Time
	if result.CompletedAt != "" {
		if t, err := time.Parse(time.RFC3339, result.CompletedAt); err == nil {
			completedAt = &t
		}
	}

	// Insert into database
	query := `
		INSERT INTO task_results (
			task_id, correlation_id, worker_id, status, result_type, completed_at, result_data
		)
		VALUES (
			$1, $2, $3, $4, $5, $6, $7
		)`

	_, err = na.db.Exec(query, result.TaskID, result.CorrelationID, result.WorkerID,
		result.Status, result.ResultType, completedAt, string(resultDataJSON))

	if err != nil {
		return err
	}

	log.Printf("Archived task result: %s (status: %s, type: %s)", result.TaskID, result.Status, result.ResultType)
	return nil
}

func (na *NATSArchiver) processTaskSignature(data []byte) error {
	var signature TaskSignature
	if err := json.Unmarshal(data, &signature); err != nil {
		log.Printf("Invalid JSON in task signature: %v", err)
		return err
	}

	// Insert signature into database
	query := `
		INSERT INTO task_signatures (
			task_id, signature, algorithm, public_key
		)
		VALUES (
			$1, $2, $3, $4
		)`

	_, err := na.db.Exec(query, signature.TaskID, signature.Signature, signature.Algorithm, signature.PublicKey)
	if err != nil {
		return err
	}

	log.Printf("Archived task signature: %s (algorithm: %s)", signature.TaskID, signature.Algorithm)
	return nil
}

func (na *NATSArchiver) processSBOMData(data []byte) error {
	var sbomData SBOMData
	if err := json.Unmarshal(data, &sbomData); err != nil {
		log.Printf("Invalid JSON in SBOM data: %v", err)
		return err
	}

	// Convert sbom_json to JSON string for storage
	sbomJsonBytes, err := json.Marshal(sbomData.SBOMJson)
	if err != nil {
		return err
	}

	// Insert SBOM data into database with a retry mechanism
	query := `
		INSERT INTO sbom_data (
			task_id, sbom_id, package_name, package_version, sbom_format, component_count, sbom_json, file_path
		)
		VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8
		)`

	const maxRetries = 5
	for i := 0; i < maxRetries; i++ {
		_, err = na.db.Exec(query, sbomData.TaskID, sbomData.SBOMId, sbomData.PackageName,
			sbomData.PackageVersion, sbomData.SBOMFormat, sbomData.ComponentCount,
			string(sbomJsonBytes), sbomData.FilePath)

		if err == nil {
			log.Printf("Archived SBOM data: %s (package: %s@%s, components: %d, format: %s)",
				sbomData.SBOMId, sbomData.PackageName, sbomData.PackageVersion,
				sbomData.ComponentCount, sbomData.SBOMFormat)
			return nil
		}

		// The SBOM message can arrive before the task result it references;
		// retry on the Postgres foreign key violation until the parent row lands.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23503" {
			log.Printf("Foreign key constraint failed for SBOM, retrying in 2 seconds (attempt %d/%d): %v", i+1, maxRetries, err)
			time.Sleep(2 * time.Second)
			continue
		}

		// If it's another error, log and fail
		log.Printf("Error inserting SBOM data after retries: %v", err)
		return err
	}

	// If all retries fail, return an error
	return fmt.Errorf("failed to archive SBOM data after %d retries", maxRetries)
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

func (na *NATSArchiver) cleanup() {
	// Close database connection
	if na.db != nil {
		na.db.Close()
	}

	// Close NATS connection
	if na.nc != nil {
		na.nc.Close()
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}
