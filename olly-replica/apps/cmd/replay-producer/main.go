// replay-producer emits a synthetic Netcool/BigPanda-style event onto the
// NOI Event Queue and exits. Source is always "replay" so production
// consumers can refuse to act on synthetic events; the replica's pipeline
// processes them like any other. The event is validated against the
// contract before publishing; the producer cannot emit drifted payloads.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/segmentio/kafka-go"

	"github.com/acme-co/osramp/olly-replica/apps/internal/contracts"
	"github.com/acme-co/osramp/olly-replica/apps/internal/model"
)

func main() {
	app := flag.String("app", "inventory-service", "app_id for the event")
	corr := flag.String("correlation-id", "", "correlation-ID (generated when empty)")
	severity := flag.Int("severity", 2, "severity 1-5")
	alertType := flag.String("alert-type", "app_failure_burst", "alert type")
	message := flag.String("message", "synthetic failure burst for replay", "raw payload message")
	eligible := flag.Bool("eligible", false, "mark the event automation-eligible (IO auto-remediates it; it is not routed to Olly)")
	flag.Parse()

	if *corr == "" {
		*corr = fmt.Sprintf("replay-%d", time.Now().UnixNano())
	}
	payload := map[string]any{"raw": *message}
	if *eligible {
		payload["automation_eligible"] = true
	}
	ev := model.Event{
		SchemaVersion: "v1",
		EventID:       fmt.Sprintf("evt-%d", time.Now().UnixNano()),
		CorrelationID: *corr,
		AppID:         *app,
		Source:        "replay",
		AlertType:     *alertType,
		Severity:      *severity,
		OccurredAt:    time.Now().UTC().Format(time.RFC3339),
		Payload:       payload,
	}
	raw, _ := json.Marshal(ev)

	schema, err := contracts.Load(contracts.EligibleEvent)
	if err != nil {
		log.Fatalf("load contract: %v", err)
	}
	if err := contracts.ValidateJSON(schema, raw); err != nil {
		log.Fatalf("refusing to publish: event does not validate against the contract: %v", err)
	}

	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" {
		brokers = "redpanda.olly-replica.svc.cluster.local:9093"
	}
	topic := os.Getenv("EVENTS_TOPIC")
	if topic == "" {
		topic = "netcool.io.events"
	}
	w := &kafka.Writer{
		Addr:         kafka.TCP(strings.Split(brokers, ",")...),
		Topic:        topic,
		RequiredAcks: kafka.RequireOne,
	}
	defer w.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := w.WriteMessages(ctx, kafka.Message{Key: []byte(*corr), Value: raw}); err != nil {
		log.Fatalf("publish: %v", err)
	}
	fmt.Printf("published replay event %s to %s (correlation_id=%s app=%s)\n", ev.EventID, topic, *corr, *app)
}
