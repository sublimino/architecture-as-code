// mapping-stub is the IO Mapping Service stand-in. It carries the routing
// contract and holds the only ServiceNow write path in the whole
// replica:
//
//   - Routing: consumes the NOI Event Queue, applies the Self-Healing
//     subscription gate, and (declining automation for every event in the
//     replica) publishes declined events to the IO-Declined topic, which is
//     what routes work to Olly.
//   - Writing: consumes the event_response topic, validates enrichment
//     payloads against the contract, and updates the ticket. With a PDI wired
//     it upserts a real ServiceNow incident keyed by correlation_id (create
//     once, then PATCH the work note) and captures its sys_id for dashboard
//     deep links; otherwise the in-memory store stands in.
//   - Feeding the dashboards: every ticket change is mirrored into the
//     Elasticsearch `olly-incidents` index, so Eye in the Sky can list the
//     individual incidents (per tenant and across the estate) and link each
//     row straight to its ServiceNow record.
//   - Seeding: on startup it opens a realistic spread of incidents across the
//     tenant apps (new, in-progress, and already-enriched) so the dashboards
//     show Olly's value before any live event flows.
//
// This service holds the write path; Olly Sentinel is read-only.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v5"
	"github.com/segmentio/kafka-go"

	"github.com/acme-co/osramp/olly-replica/apps/internal/contracts"
	"github.com/acme-co/osramp/olly-replica/apps/internal/model"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }

type ticket struct {
	IncNumber     string          `json:"inc_number"`
	SysID         string          `json:"sys_id,omitempty"`
	CorrelationID string          `json:"correlation_id"`
	AppID         string          `json:"app_id"`
	State         string          `json:"state"` // new -> in_progress -> enriched
	ShortDesc     string          `json:"short_description,omitempty"`
	Description   string          `json:"description,omitempty"`
	AlertType     string          `json:"alert_type,omitempty"`
	Category      string          `json:"category,omitempty"`
	Subcategory   string          `json:"subcategory,omitempty"`
	Service       string          `json:"service,omitempty"`
	CI            string          `json:"ci,omitempty"`
	Caller        string          `json:"caller,omitempty"`
	Impact        string          `json:"impact,omitempty"`
	Urgency       string          `json:"urgency,omitempty"`
	Priority      string          `json:"priority,omitempty"`
	FaultDomain   string          `json:"fault_domain,omitempty"`
	Confidence    float64         `json:"confidence_score,omitempty"`
	RcaSummary    string          `json:"rca_summary,omitempty"`
	CreatedAt     string          `json:"created_at"`
	EnrichedAt    string          `json:"enriched_at,omitempty"`
	Enrichment    json.RawMessage `json:"enrichment,omitempty"`
}

type store struct {
	mu      sync.RWMutex
	byCorr  map[string]*ticket
	nextInc int
}

// stateRank orders the lifecycle so a transition only ever moves forward. The
// sentinel can beat the mapping stub to the response topic (it consumes the raw
// event and publishes an enrichment before the decline is written), so a
// decline that lands after enrichment must not knock the ticket back to
// in_progress. All ticket mutation goes through the store under its lock; the
// two Kafka consumers and the seeder run concurrently.
// "raw" shares rank 1 with in_progress: an unsubscribed app never reaches the
// declined topic, so raw and in_progress can never race for the same
// correlation-ID.
var stateRank = map[string]int{"": -1, "new": 0, "raw": 1, "in_progress": 1, "enriched": 2, "auto_remediated": 3}

func advance(t *ticket, state string) {
	if stateRank[state] > stateRank[t.State] {
		t.State = state
	}
}

// ensureLocked returns the ticket for corr, creating it on first sight. The
// caller must hold s.mu.
func (s *store) ensureLocked(corr, appID string) *ticket {
	if t, ok := s.byCorr[corr]; ok {
		if t.AppID == "" && appID != "" {
			t.AppID = appID
		}
		return t
	}
	s.nextInc++
	t := &ticket{
		IncNumber:     fmt.Sprintf("INC%07d", 10000+s.nextInc),
		CorrelationID: corr,
		AppID:         appID,
		State:         "new",
		CreatedAt:     now(),
	}
	s.byCorr[corr] = t
	return t
}

// markDeclined opens or refreshes the ticket for a declined event and returns a
// snapshot. It only advances the state, so a decline arriving after enrichment
// leaves the ticket enriched.
func (s *store) markDeclined(corr, appID, alertType string) ticket {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.ensureLocked(corr, appID)
	advance(t, "in_progress")
	t.AlertType = alertType
	t.ShortDesc = fmt.Sprintf("[%s] %s", appID, alertType)
	applyProfile(t)
	return *t
}

// markAutoRemediated opens the ticket for an eligible event that IO Self-Healing
// resolves through automation, so it never reaches Olly, and returns a snapshot.
func (s *store) markAutoRemediated(corr, appID, alertType string) ticket {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.ensureLocked(corr, appID)
	advance(t, "auto_remediated")
	t.AlertType = alertType
	t.ShortDesc = fmt.Sprintf("[%s] %s", appID, alertType)
	applyProfile(t)
	return *t
}

// markRawIncident opens the ticket for an app with no Self-Healing
// subscription. This is the diagram's "ServiceNow Incident created (raw INC),
// no Olly enrichment" node: the incident is real and visible to the SRE, it
// simply never reaches the agent. Terminal: a raw incident is never enriched,
// because the event was never forwarded.
func (s *store) markRawIncident(corr, appID, alertType string) ticket {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.ensureLocked(corr, appID)
	advance(t, "raw")
	t.AlertType = alertType
	t.ShortDesc = fmt.Sprintf("[%s] %s (no Self-Healing subscription)", appID, alertType)
	applyProfile(t)
	return *t
}

// markEnriched records the RCA on the ticket and returns a snapshot.
func (s *store) markEnriched(corr string, enr *model.Enrichment, raw []byte) ticket {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.ensureLocked(corr, "")
	advance(t, "enriched")
	t.EnrichedAt = now()
	t.FaultDomain = enr.RCA.FaultDomain
	t.Confidence = enr.RCA.ConfidenceScore
	t.RcaSummary = enr.RCA.Summary
	t.Enrichment = append([]byte(nil), raw...)
	if t.ShortDesc == "" {
		t.ShortDesc = fmt.Sprintf("[%s] Olly RCA: %s", firstNonEmpty(t.AppID, "unknown"), truncate(enr.RCA.Summary, 80))
	}
	tagEnriched(t)
	applyProfile(t)
	return *t
}

// tagEnriched marks the short description so ServiceNow shows Olly enriched the
// incident. The Mapping Service owns every ticket write; Olly is read-only and
// never patches ServiceNow. Idempotent, so a re-enrichment does not stack tags.
func tagEnriched(t *ticket) {
	const tag = " [Olly-enriched]"
	if !strings.Contains(t.ShortDesc, "[Olly-enriched]") {
		t.ShortDesc += tag
	}
}

// seedTicket opens a demo incident from the seed set and returns a snapshot.
func (s *store) seedTicket(sd seed, corr string) ticket {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.ensureLocked(corr, sd.app)
	advance(t, sd.state)
	t.AlertType = sd.alertType
	t.ShortDesc = fmt.Sprintf("[%s] %s", sd.app, sd.shortDesc)
	if sd.state == "enriched" {
		t.FaultDomain = sd.faultDomain
		t.Confidence = sd.confidence
		t.RcaSummary = sd.rca
		t.EnrichedAt = now()
		tagEnriched(t)
	} else {
		t.FaultDomain = sd.faultDomain
	}
	applyProfile(t)
	return *t
}

// setServiceNow records the ServiceNow number and sys_id captured on write.
func (s *store) setServiceNow(corr, number, sysID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.byCorr[corr]
	if !ok {
		return
	}
	if number != "" {
		t.IncNumber = number
	}
	if sysID != "" {
		t.SysID = sysID
	}
}

// snapshot returns a copy of the current ticket for corr.
func (s *store) snapshot(corr string) (ticket, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	t, ok := s.byCorr[corr]
	if !ok {
		return ticket{}, false
	}
	return *t, true
}

func (s *store) get(corr string) (*ticket, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	t, ok := s.byCorr[corr]
	return t, ok
}

// list returns every ticket, newest INC first, optionally filtered by app_id.
func (s *store) list(appID string) []*ticket {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*ticket, 0, len(s.byCorr))
	for _, t := range s.byCorr {
		if appID == "" || t.AppID == appID {
			out = append(out, t)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].IncNumber > out[j].IncNumber })
	return out
}

// syncTicket mirrors a ticket to ServiceNow (capturing sys_id) and
// Elasticsearch, returning the updated snapshot. Best-effort: the in-memory
// store stays the source of truth for the tests. It re-snapshots after the
// ServiceNow write so the ES doc carries the merged current state (for example
// the app_id a concurrent decline just filled in), independent of the order the
// two consumers reach this function.
// --- Automation results ---------------------------------------------------

// automationResult is what the IO Automation branch writes to the response
// topic. The flow diagram has both branches converge on Event Response, and
// the PlantUML names it "the same topic used by IO automation results", so
// that topic carries two shapes: this one, and rca-enrichment.v1 from Olly.
// The `result_type` discriminator lets the write loop tell them apart instead
// of failing the automation shape against the enrichment schema.
type automationResult struct {
	SchemaVersion string `json:"schema_version"`
	ResultType    string `json:"result_type"`
	CorrelationID string `json:"correlation_id"`
	EventID       string `json:"event_id"`
	AppID         string `json:"app_id"`
	AlertType     string `json:"alert_type,omitempty"`
	Provider      string `json:"provider"`
	Outcome       string `json:"outcome"`
	IncNumber     string `json:"inc_number,omitempty"`
	TS            string `json:"ts"`
}

func publishAutomationResult(w *kafka.Writer, ev *model.Event, incNumber string) {
	if w == nil {
		return
	}
	res := automationResult{
		SchemaVersion: "v1",
		ResultType:    "automation",
		CorrelationID: ev.CorrelationID,
		EventID:       ev.EventID,
		AppID:         ev.AppID,
		AlertType:     ev.AlertType,
		Provider:      "ansible_aap",
		Outcome:       "remediated",
		IncNumber:     incNumber,
		TS:            now(),
	}
	raw, err := json.Marshal(res)
	if err != nil {
		log.Printf("automation result marshal failed for %s: %v", ev.CorrelationID, err)
		return
	}
	if err := w.WriteMessages(context.Background(),
		kafka.Message{Key: []byte(ev.CorrelationID), Value: raw}); err != nil {
		log.Printf("automation result publish failed for %s: %v", ev.CorrelationID, err)
	}
}

// --- Decision emission ----------------------------------------------------

// decisionEmitter publishes one pipeline-decision.v1 record per gate this
// service evaluates. Observability only: the record is written after the gate
// has already decided, and a publish failure is logged and swallowed so that
// the routing path can never be taken down by the audit path.
type decisionEmitter struct {
	w      *kafka.Writer
	schema *jsonschema.Schema

	// A bounded in-memory ring of what this service has decided, so the
	// io_events_query MCP tool can read orchestration history over HTTP
	// without every caller having to become a Kafka consumer. Kafka remains
	// the durable record; this is a convenience view of the same records.
	mu     sync.Mutex
	recent []model.Decision
}

const decisionRingSize = 500

func (d *decisionEmitter) remember(rec model.Decision) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.recent = append(d.recent, rec)
	if len(d.recent) > decisionRingSize {
		d.recent = d.recent[len(d.recent)-decisionRingSize:]
	}
}

// list returns the retained decisions, newest first, optionally by app.
func (d *decisionEmitter) list(appID string) []model.Decision {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]model.Decision, 0, len(d.recent))
	for i := len(d.recent) - 1; i >= 0; i-- {
		if appID == "" || d.recent[i].AppID == appID {
			out = append(out, d.recent[i])
		}
	}
	return out
}

func (d *decisionEmitter) emit(ev *model.Event, gate, branch, reason string, detail map[string]any) {
	if d == nil || d.w == nil {
		return
	}
	rec := model.Decision{
		SchemaVersion: "v1",
		CorrelationID: firstNonEmpty(ev.CorrelationID, "unknown"),
		EventID:       firstNonEmpty(ev.EventID, "unknown"),
		AppID:         ev.AppID,
		Component:     "noi_mapping_service",
		Gate:          gate,
		Branch:        branch,
		Reason:        truncate(reason, 512),
		TS:            now(),
		Detail:        detail,
	}
	raw, err := json.Marshal(rec)
	if err != nil {
		log.Printf("decision marshal failed (gate=%s branch=%s): %v", gate, branch, err)
		return
	}
	if d.schema != nil {
		if err := contracts.ValidateJSON(d.schema, raw); err != nil {
			log.Printf("decision failed its own contract (gate=%s branch=%s): %v", gate, branch, err)
			return
		}
	}
	d.remember(rec)
	if err := d.w.WriteMessages(context.Background(),
		kafka.Message{Key: []byte(rec.CorrelationID), Value: raw}); err != nil {
		log.Printf("decision publish failed (gate=%s branch=%s): %v", gate, branch, err)
	}
}

func syncTicket(st *store, sn *snClient, es *esClient, snap ticket, workNote, snState string) ticket {
	if sn != nil {
		if num, sysID, err := sn.upsert(&snap, workNote, snState); err != nil {
			log.Printf("servicenow upsert for %s failed (continuing): %v", snap.CorrelationID, err)
		} else {
			st.setServiceNow(snap.CorrelationID, num, sysID)
		}
	}
	if fresh, ok := st.snapshot(snap.CorrelationID); ok {
		snap = fresh
	}
	if es != nil {
		es.index(&snap)
	}
	return snap
}

func main() {
	brokers := strings.Split(env("KAFKA_BROKERS", "redpanda.olly-replica.svc.cluster.local:9093"), ",")
	eventsTopic := env("EVENTS_TOPIC", "netcool.io.events")
	declinedTopic := env("DECLINED_TOPIC", "netcool.io.events.declined")
	responseTopic := env("RESPONSE_TOPIC", "ideas-172472-sn30.167564-impact.event_response")
	decisionsTopic := env("DECISIONS_TOPIC", "olly.pipeline.decisions")
	subscribed := map[string]bool{}
	for _, app := range strings.Split(env("SUBSCRIBED_APPS", "inventory-service,payments-api,customer-portal"), ",") {
		if app = strings.TrimSpace(app); app != "" {
			subscribed[app] = true
		}
	}

	eventSchema, err := contracts.Load(contracts.EligibleEvent)
	if err != nil {
		log.Fatalf("load event contract: %v", err)
	}
	enrichmentSchema, err := contracts.Load(contracts.RcaEnrichment)
	if err != nil {
		log.Fatalf("load enrichment contract: %v", err)
	}

	st := &store{byCorr: map[string]*ticket{}}
	sn := newSNClient()
	es := newESClient()
	// Prepare the ES index (0 replicas) and seed the demo incidents in the
	// background, so the HTTP server (readiness probe) comes up immediately and
	// startup does not block on Elasticsearch being ready.
	go func() {
		if es != nil {
			es.ensureSchema()
		}
		seedIncidents(st, sn, es)
	}()

	declinedWriter := &kafka.Writer{
		Addr:         kafka.TCP(brokers...),
		Topic:        declinedTopic,
		Balancer:     &kafka.LeastBytes{},
		RequiredAcks: kafka.RequireOne,
	}
	defer declinedWriter.Close()

	// The automation branch writes its result to the same response topic Olly
	// publishes enrichments to, so both diagram branches converge there.
	responseWriter := &kafka.Writer{
		Addr:         kafka.TCP(brokers...),
		Topic:        responseTopic,
		Balancer:     &kafka.LeastBytes{},
		RequiredAcks: kafka.RequireOne,
	}
	defer responseWriter.Close()

	// Decision bus: one record per gate this service evaluates. Best-effort.
	decisionSchema, err := contracts.Load(contracts.PipelineDecision)
	if err != nil {
		log.Printf("load decision contract (decisions will not be emitted): %v", err)
	}
	dec := &decisionEmitter{
		w: &kafka.Writer{
			Addr:         kafka.TCP(brokers...),
			Topic:        decisionsTopic,
			Balancer:     &kafka.LeastBytes{},
			RequiredAcks: kafka.RequireOne,
		},
		schema: decisionSchema,
	}
	defer dec.w.Close()

	// Routing loop: queue -> subscription gate -> decline -> IO-Declined.
	go func() {
		r := kafka.NewReader(kafka.ReaderConfig{
			Brokers: brokers, GroupID: "io-mapping", Topic: eventsTopic,
			MaxWait: 2 * time.Second,
		})
		defer r.Close()
		for {
			msg, err := r.ReadMessage(context.Background())
			if err != nil {
				log.Printf("events reader: %v (retrying)", err)
				time.Sleep(2 * time.Second)
				continue
			}
			if err := contracts.ValidateJSON(eventSchema, msg.Value); err != nil {
				log.Printf("DROP invalid event (schema validation failed, never forwarded): %v", err)
				var partial model.Event
				_ = json.Unmarshal(msg.Value, &partial)
				dec.emit(&partial, "schema_validate", "reject",
					fmt.Sprintf("schema validation failed, never forwarded: %v", err), nil)
				continue
			}
			var ev model.Event
			_ = json.Unmarshal(msg.Value, &ev)
			dec.emit(&ev, "schema_validate", "pass", "event validates against eligible-event.v1", nil)

			// Subscription gate. The diagram's non-subscribed branch is
			// "ServiceNow Incident created (raw INC), no Olly enrichment":
			// the raw ticket is opened here, producing a real ServiceNow
			// record and a dashboard row.
			if !subscribed[ev.AppID] {
				snap := st.markRawIncident(ev.CorrelationID, ev.AppID, ev.AlertType)
				snap = syncTicket(st, sn, es, snap,
					"App is not subscribed to IO Self-Healing: raw incident raised, no Olly enrichment.", "1")
				log.Printf("app %s not subscribed to Self-Healing: raw incident %s raised, flow ends (correlation_id=%s)",
					ev.AppID, snap.IncNumber, ev.CorrelationID)
				dec.emit(&ev, "subscription", "reject",
					"app not subscribed to Self-Healing: raw INC raised, flow ends",
					map[string]any{"inc_number": snap.IncNumber})
				continue
			}
			dec.emit(&ev, "subscription", "pass", "app is subscribed to Self-Healing", nil)

			// Automation-eligibility decision (a real mapping service does this
			// against runbook coverage; the replica reads a per-event marker).
			// Eligible events are auto-remediated by IO and never reach Olly.
			if elig, _ := ev.Payload["automation_eligible"].(bool); elig {
				snap := st.markAutoRemediated(ev.CorrelationID, ev.AppID, ev.AlertType)
				snap = syncTicket(st, sn, es, snap,
					"IO Self-Healing auto-remediated this event (automation eligible); Olly not invoked.", "6")
				// Both diagram branches converge on Event Response. The
				// automation path publishes its result to the same response
				// topic Olly uses, so the eligible branch is visible in the
				// pipeline stream.
				publishAutomationResult(responseWriter, &ev, snap.IncNumber)
				log.Printf("eligible event %s (app=%s, correlation_id=%s, ticket=%s): auto-remediated by IO automation, not routed to Olly",
					ev.EventID, ev.AppID, ev.CorrelationID, snap.IncNumber)
				dec.emit(&ev, "automation_eligibility", "auto_remediated",
					"automation eligible: IO Self-Healing remediated, Olly not invoked",
					map[string]any{"inc_number": snap.IncNumber})
				continue
			}
			dec.emit(&ev, "automation_eligibility", "pass",
				"automation declined by policy: routing to Olly Sentinel", nil)
			// Open/refresh the ticket. markDeclined only advances the state, so
			// a decline that lands after the sentinel already enriched (it can
			// beat us to the response topic) never resets it to in_progress.
			snap := st.markDeclined(ev.CorrelationID, ev.AppID, ev.AlertType)
			// The replica declines every eligible event so the Olly branch is
			// always exercised; a real mapping service evaluates automation
			// eligibility here.
			ev.Source = "io_declined"
			ev.DeclinedReason = "replica: automation declined by policy"
			out, _ := json.Marshal(ev)
			if err := declinedWriter.WriteMessages(context.Background(),
				kafka.Message{Key: []byte(ev.CorrelationID), Value: out}); err != nil {
				log.Printf("publish to declined topic: %v", err)
				continue
			}
			// Mirror to ServiceNow + ES so the incident shows as in-progress
			// before Olly's RCA lands.
			snap = syncTicket(st, sn, es, snap, "", "2")
			log.Printf("declined event %s (app=%s, correlation_id=%s, ticket=%s): published to %s",
				ev.EventID, ev.AppID, ev.CorrelationID, snap.IncNumber, declinedTopic)
		}
	}()

	// Write loop: event_response -> validate -> ticket update.
	go func() {
		r := kafka.NewReader(kafka.ReaderConfig{
			Brokers: brokers, GroupID: "io-mapping-writer", Topic: responseTopic,
			MaxWait: 2 * time.Second,
		})
		defer r.Close()
		for {
			msg, err := r.ReadMessage(context.Background())
			if err != nil {
				log.Printf("response reader: %v (retrying)", err)
				time.Sleep(2 * time.Second)
				continue
			}
			// The response topic carries two shapes (see automationResult):
			// IO automation results and Olly enrichments. Discriminate before
			// validating, so an automation result is not reported as a
			// contract violation of a schema it was never meant to satisfy.
			var probe struct {
				ResultType string `json:"result_type"`
			}
			_ = json.Unmarshal(msg.Value, &probe)
			if probe.ResultType == "automation" {
				var res automationResult
				_ = json.Unmarshal(msg.Value, &res)
				log.Printf("AUDIT automation result on response topic (correlation_id=%s, app=%s, provider=%s, outcome=%s, ticket=%s): ticket already auto-remediated, no enrichment expected",
					res.CorrelationID, firstNonEmpty(res.AppID, "unknown"), res.Provider, res.Outcome, res.IncNumber)
				continue
			}
			if err := contracts.ValidateJSON(enrichmentSchema, msg.Value); err != nil {
				log.Printf("DROP invalid enrichment payload (never written to the ticket): %v", err)
				continue
			}
			var enr model.Enrichment
			_ = json.Unmarshal(msg.Value, &enr)
			snap := st.markEnriched(enr.CorrelationID, &enr, msg.Value)
			snap = syncTicket(st, sn, es, snap, enr.RCA.Summary, "2")
			log.Printf("AUDIT ticket %s updated with RCA enrichment (correlation_id=%s, app=%s, fault_domain=%s, agent=%s/%s, confidence=%.2f, secrets_redacted=%d)",
				snap.IncNumber, enr.CorrelationID, firstNonEmpty(snap.AppID, "unknown"), enr.RCA.FaultDomain, enr.Agent.Name, enr.Agent.Version, enr.RCA.ConfidenceScore, enr.Redaction.SecretsFound)
			dec.emit(&model.Event{
				CorrelationID: enr.CorrelationID,
				EventID:       enr.IdempotencyKey,
				AppID:         snap.AppID,
			}, "ticket_write", "complete",
				fmt.Sprintf("ticket %s updated with RCA enrichment", snap.IncNumber),
				map[string]any{"inc_number": snap.IncNumber, "fault_domain": enr.RCA.FaultDomain})
		}
	}()

	mux := http.NewServeMux()
	// GET /incidents        -> all tickets (optionally ?app_id=<app>)
	// GET /incidents/<corr> -> one ticket by correlation-ID
	mux.HandleFunc("/incidents/", func(w http.ResponseWriter, r *http.Request) {
		corr := strings.TrimPrefix(r.URL.Path, "/incidents/")
		t, ok := st.get(corr)
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, t)
	})
	mux.HandleFunc("/incidents", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, st.list(r.URL.Query().Get("app_id")))
	})
	// GET /events[?app_id=<app>] -> this service's orchestration decisions,
	// newest first. Backs the io_events_query MCP tool.
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, dec.list(r.URL.Query().Get("app_id")))
	})
	// GET /metrics -> incident counts per app and state, so the estate
	// dashboard reads ticket counts from Prometheus instead of a cross-datasource
	// Elasticsearch join.
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		total := map[string]int{}
		byState := map[[2]string]int{}
		for _, t := range st.list("") {
			app := firstNonEmpty(t.AppID, "unknown")
			total[app]++
			byState[[2]string{app, firstNonEmpty(t.State, "new")}]++
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		fmt.Fprint(w, "# HELP olly_incidents Incidents tracked by the mapping service, by app.\n# TYPE olly_incidents gauge\n")
		apps := make([]string, 0, len(total))
		for a := range total {
			apps = append(apps, a)
		}
		sort.Strings(apps)
		for _, a := range apps {
			fmt.Fprintf(w, "olly_incidents{app_id=%q} %d\n", a, total[a])
		}
		fmt.Fprint(w, "# HELP olly_incidents_state Incidents by app and lifecycle state.\n# TYPE olly_incidents_state gauge\n")
		keys := make([][2]string, 0, len(byState))
		for k := range byState {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			if keys[i][0] != keys[j][0] {
				return keys[i][0] < keys[j][0]
			}
			return keys[i][1] < keys[j][1]
		})
		for _, k := range keys {
			fmt.Fprintf(w, "olly_incidents_state{app_id=%q,state=%q} %d\n", k[0], k[1], byState[k])
		}
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	listen := env("LISTEN", ":8080")
	log.Printf("io-mapping-stub listening on %s (events=%s declined=%s response=%s servicenow=%t elasticsearch=%t)",
		listen, eventsTopic, declinedTopic, responseTopic, sn != nil, es != nil)
	log.Fatal(http.ListenAndServe(listen, mux))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

// --- ServiceNow -----------------------------------------------------------

// snClient is the ServiceNow Table API client for the free PDI. It keys every
// incident on the stock correlation_id field so the same external key that
// flows through the pipeline resolves the ticket; no INC number leaves
// ServiceNow into the agent's world.
type snClient struct {
	base, user, pass string
	http             *http.Client
	// mu serializes upserts: the decline and the enrichment for one
	// correlation_id can arrive concurrently, and without this both would
	// find-miss-then-create, opening two incidents for the same event.
	mu sync.Mutex
}

func newSNClient() *snClient {
	base := os.Getenv("SERVICENOW_URL")
	if base == "" {
		return nil
	}
	return &snClient{
		base: strings.TrimRight(base, "/"),
		user: os.Getenv("SERVICENOW_USER"),
		pass: os.Getenv("SERVICENOW_PASSWORD"),
		http: &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *snClient) do(method, u string, body []byte) (*http.Response, error) {
	var rdr io.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, u, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.SetBasicAuth(c.user, c.pass)
	return c.http.Do(req)
}

func (c *snClient) findByCorrelation(corr string) (sysID, number string, found bool) {
	u := fmt.Sprintf("%s/api/now/table/incident?sysparm_query=correlation_id=%s&sysparm_fields=sys_id,number&sysparm_limit=1",
		c.base, url.QueryEscape(corr))
	resp, err := c.do(http.MethodGet, u, nil)
	if err != nil {
		log.Printf("servicenow lookup for %s failed: %v", corr, err)
		return "", "", false
	}
	defer resp.Body.Close()
	var out struct {
		Result []struct {
			SysID  string `json:"sys_id"`
			Number string `json:"number"`
		} `json:"result"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if len(out.Result) > 0 {
		return out.Result[0].SysID, out.Result[0].Number, true
	}
	return "", "", false
}

// snImpact maps the store's impact/urgency labels to ServiceNow's numeric
// choice values (1 High, 2 Medium, 3 Low).
func snImpact(label string) string {
	switch label {
	case "High":
		return "1"
	case "Medium":
		return "2"
	case "Low":
		return "3"
	default:
		return ""
	}
}

// upsert creates the incident on first sight of a correlation_id and PATCHes
// it after. Fields that describe the incident (short/long description,
// category, impact, urgency) are set on every write because they overwrite in
// place. work_notes is a journal field, so it is written only when workNote
// carries new content; comments is written once, on create, to avoid stacking
// the same line on every state transition. Returns the incident number and
// sys_id (the latter powers the dashboard deep links).
func (c *snClient) upsert(t *ticket, workNote, snState string) (number, sysID string, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	body := map[string]any{
		"short_description": t.ShortDesc,
		"description":       t.Description,
		"correlation_id":    t.CorrelationID,
		"category":          strings.ToLower(t.Category),
		"cmdb_ci":           t.CI,
	}
	if imp := snImpact(t.Impact); imp != "" {
		body["impact"] = imp
	}
	if urg := snImpact(t.Urgency); urg != "" {
		body["urgency"] = urg
	}
	if workNote != "" {
		body["work_notes"] = workNote
	}
	if snState != "" {
		body["state"] = snState
		// Resolved (6) and Closed (7) trip a ServiceNow data policy that
		// requires a close code and notes, so supply them.
		if snState == "6" || snState == "7" {
			body["close_code"] = "Solved (Permanently)"
			body["close_notes"] = firstNonEmpty(workNote, "Auto-remediated by IO Self-Healing.")
		}
	}

	sysID, number, found := c.findByCorrelation(t.CorrelationID)
	method, u := http.MethodPost, c.base+"/api/now/table/incident"
	if found {
		method, u = http.MethodPatch, fmt.Sprintf("%s/api/now/table/incident/%s", c.base, sysID)
	} else {
		body["comments"] = fmt.Sprintf("Opened by Olly for %s (%s). Caller: %s.",
			t.Service, t.AppID, t.Caller)
	}
	raw, _ := json.Marshal(body)
	resp, err := c.do(method, u, raw)
	if err != nil {
		return number, sysID, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return number, sysID, fmt.Errorf("%s %s -> %d: %s", method, u, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var out struct {
		Result struct {
			Number string `json:"number"`
			SysID  string `json:"sys_id"`
		} `json:"result"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Result.Number != "" {
		number = out.Result.Number
	}
	if out.Result.SysID != "" {
		sysID = out.Result.SysID
	}
	return number, sysID, nil
}

// --- Elasticsearch --------------------------------------------------------

// esClient mirrors tickets into the olly-incidents index so the dashboards can
// list them and link each row to its ServiceNow record. Write-only and
// best-effort; the sentinel keeps its own read-only, scoped ELK access.
type esClient struct {
	base, user, pass string
	http             *http.Client
}

func newESClient() *esClient {
	pass := os.Getenv("ELASTIC_PASSWORD")
	if pass == "" {
		return nil // no credential mounted; skip ES mirroring
	}
	return &esClient{
		base: strings.TrimRight(env("ELASTIC_URL", "http://olly-es-http:9200"), "/"),
		user: env("ELASTIC_USER", "elastic"),
		pass: pass,
		http: &http.Client{Timeout: 10 * time.Second},
	}
}

func (c *esClient) put(path string, body []byte) (int, error) {
	req, err := http.NewRequest(http.MethodPut, c.base+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(c.user, c.pass)
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 512))
	resp.Body.Close()
	return resp.StatusCode, nil
}

// ensureSchema waits for Elasticsearch, then installs an index template so
// olly-incidents* is created with 0 replicas (single-node ES cannot allocate a
// replica, which would leave the cluster yellow, matching the convention the
// seed job uses for the log data streams), and fixes any index a prior run left
// at the default 1 replica. Best-effort; runs before the first ticket is mirrored.
func (c *esClient) ensureSchema() {
	tmpl := []byte(`{"index_patterns":["olly-incidents*"],"template":{"settings":{"number_of_replicas":0}}}`)
	for i := 0; i < 20; i++ {
		if code, err := c.put("/_index_template/olly-incidents", tmpl); err == nil && code < 300 {
			break
		}
		time.Sleep(3 * time.Second)
	}
	// Correct an already-existing index (no-op / 404 if it isn't there yet).
	_, _ = c.put("/olly-incidents/_settings", []byte(`{"index":{"number_of_replicas":0}}`))
}

func (c *esClient) index(t *ticket) {
	doc := map[string]any{
		"@timestamp":        now(),
		"correlation_id":    t.CorrelationID,
		"inc_number":        t.IncNumber,
		"sys_id":            t.SysID,
		"app_id":            t.AppID,
		"state":             t.State,
		"short_description": t.ShortDesc,
		"description":       t.Description,
		"alert_type":        t.AlertType,
		"category":          t.Category,
		"subcategory":       t.Subcategory,
		"service":           t.Service,
		"ci":                t.CI,
		"caller":            t.Caller,
		"impact":            t.Impact,
		"urgency":           t.Urgency,
		"priority":          t.Priority,
		"fault_domain":      t.FaultDomain,
		"confidence_score":  t.Confidence,
		"rca_summary":       t.RcaSummary,
		"created_at":        t.CreatedAt,
	}
	// Only send enriched_at once it is set: ES maps it as a date and rejects an
	// empty string, which would drop every new/in-progress incident from the
	// index (and so from the dashboards' incident tables).
	if t.EnrichedAt != "" {
		doc["enriched_at"] = t.EnrichedAt
	}
	body, _ := json.Marshal(doc)
	u := fmt.Sprintf("%s/olly-incidents/_doc/%s", c.base, url.PathEscape(t.CorrelationID))
	req, _ := http.NewRequest(http.MethodPut, u, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(c.user, c.pass)
	resp, err := c.http.Do(req)
	if err != nil {
		log.Printf("es index for %s failed (continuing): %v", t.CorrelationID, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		log.Printf("es index for %s -> %d: %s", t.CorrelationID, resp.StatusCode, strings.TrimSpace(string(b)))
	}
}

// --- Seed -----------------------------------------------------------------

// seed is a demo incident. Enriched entries carry a synthesized RCA so the
// dashboards show completed vs open work per tenant before any live replay.
type seed struct {
	app, alertType, shortDesc, state, faultDomain, rca string
	confidence                                         float64
}

// serviceProfile carries the business context an incident inherits from its
// tenant application: the CMDB service and CI, the ITIL category, and the
// on-call roster incidents are attributed to.
type serviceProfile struct {
	service  string
	ci       string
	category string
	callers  []string
}

var serviceProfiles = map[string]serviceProfile{
	"inventory-service": {
		service: "Positions & Stock Ledger", ci: "INVENTORY-APP-01", category: "Software",
		callers: []string{"Priya Nair", "Marcus Feld", "Ledger On-Call"},
	},
	"payments-api": {
		service: "Card Payments & Settlement", ci: "PAYMENTS-APP-07", category: "Software",
		callers: []string{"Dana Okoro", "Sven Alvarez", "Payments On-Call"},
	},
	"customer-portal": {
		service: "Retail Banking Portal", ci: "PORTAL-APP-03", category: "Software",
		callers: []string{"Ana Costa", "Ruben Halapua", "Portal On-Call"},
	},
}

func profileFor(app string) serviceProfile {
	if p, ok := serviceProfiles[app]; ok {
		return p
	}
	return serviceProfile{service: app, ci: strings.ToUpper(app) + "-APP-01", category: "Software", callers: []string{"SRE On-Call"}}
}

// subcategoryFor maps a fault domain to an ITIL subcategory.
func subcategoryFor(faultDomain string) string {
	switch faultDomain {
	case "dependency":
		return "Application - Dependency"
	case "infrastructure":
		return "Infrastructure - Compute"
	case "application":
		return "Application - Defect"
	case "change":
		return "Change - Regression"
	case "data":
		return "Data - Quality"
	default:
		return "Application - Triage"
	}
}

// impactUrgency assigns ITIL impact and urgency from the service and fault
// shape. Settlement and ledger faults move money, so they carry higher impact
// than a portal rendering defect; a not-yet-triaged incident carries lower
// urgency until an analyst picks it up.
func impactUrgency(app, faultDomain, state string) (impact, urgency string) {
	switch faultDomain {
	case "infrastructure":
		impact, urgency = "High", "High"
	case "change":
		impact, urgency = "High", "Medium"
	case "dependency":
		impact, urgency = "Medium", "High"
	case "application":
		impact, urgency = "High", "Medium"
	case "data":
		impact, urgency = "Medium", "Low"
	default:
		impact, urgency = "Medium", "Medium"
	}
	if app == "payments-api" && (faultDomain == "infrastructure" || faultDomain == "change" || faultDomain == "") {
		urgency = "High"
	}
	if state == "new" {
		urgency = map[string]string{"High": "Medium", "Medium": "Low", "Low": "Low"}[urgency]
	}
	return impact, urgency
}

// priorityFor is the stock ServiceNow impact x urgency matrix.
func priorityFor(impact, urgency string) string {
	rank := map[string]int{"High": 1, "Medium": 2, "Low": 3}
	matrix := map[int]map[int]string{
		1: {1: "P1 - Critical", 2: "P2 - High", 3: "P3 - Moderate"},
		2: {1: "P2 - High", 2: "P3 - Moderate", 3: "P4 - Low"},
		3: {1: "P3 - Moderate", 2: "P4 - Low", 3: "P5 - Planning"},
	}
	i, u := rank[impact], rank[urgency]
	if i == 0 || u == 0 {
		return "P3 - Moderate"
	}
	return matrix[i][u]
}

// callerFor picks a stable caller from the app roster, keyed by correlation-ID.
func callerFor(app, corr string) string {
	callers := profileFor(app).callers
	if len(callers) == 0 {
		return "SRE On-Call"
	}
	var sum int
	for _, b := range corr {
		sum += int(b)
	}
	return callers[sum%len(callers)]
}

// describe builds the incident long description from the ticket's business
// context and, when present, the analyst RCA.
func describe(t *ticket) string {
	lines := []string{
		t.ShortDesc,
		"",
		fmt.Sprintf("Business service: %s (CI %s)", t.Service, t.CI),
		fmt.Sprintf("Reported by: %s", t.Caller),
		fmt.Sprintf("Category: %s / %s", t.Category, t.Subcategory),
		fmt.Sprintf("Impact %s, Urgency %s, Priority %s", t.Impact, t.Urgency, t.Priority),
		fmt.Sprintf("Alert type: %s", t.AlertType),
	}
	if t.FaultDomain != "" {
		lines = append(lines, fmt.Sprintf("Fault domain: %s", t.FaultDomain))
	}
	if t.RcaSummary != "" {
		lines = append(lines, "", "Root cause: "+t.RcaSummary)
	} else {
		lines = append(lines, "", "Awaiting root-cause analysis.")
	}
	return strings.Join(lines, "\n")
}

// applyProfile fills a ticket's business and ITIL fields from its app profile
// and fault shape. Called on every state transition so a live incident carries
// the same context a seeded one does. The caller must hold the store lock.
func applyProfile(t *ticket) {
	prof := profileFor(t.AppID)
	t.Service = prof.service
	t.CI = prof.ci
	t.Category = prof.category
	t.Subcategory = subcategoryFor(t.FaultDomain)
	if t.Caller == "" {
		t.Caller = callerFor(t.AppID, t.CorrelationID)
	}
	t.Impact, t.Urgency = impactUrgency(t.AppID, t.FaultDomain, t.State)
	t.Priority = priorityFor(t.Impact, t.Urgency)
	t.Description = describe(t)
}

// seedIncidentSet is the demo's historical incident spread: 10-20 per tenant
// app, specific to that app, across every fault domain the contract enum names
// (dependency, infrastructure, application, change, data). Enriched entries
// carry a synthesized RCA and confidence so the dashboards and ServiceNow show
// completed work to compare against a live deterministic or LLM re-run; open
// entries (new / in_progress) are the ones a live replay still has to work.
var seedIncidentSet = []seed{
	// --- inventory-service: positions / stock ledger ---
	{"inventory-service", "app_failure_burst", "stock-db connection pool exhausted", "enriched", "dependency",
		"Connection pool to positions-ledger-db exhausted under load (30+ waiters, 5s acquire timeouts). Raise pool size or add a read replica; a config change cut max connections from 50 to 20.", 0.82},
	{"inventory-service", "latency_regression", "positions-ledger read replica lag 40s", "enriched", "dependency",
		"Read replica lag hit 40s during revaluation, so position reads served stale rows. Throttle the revaluation batch or promote a fresh replica; upstream, not application code.", 0.74},
	{"inventory-service", "latency_regression", "pricing-service p99 8s, breaker half-open", "enriched", "dependency",
		"Upstream pricing-service p99 climbed to 8s and the circuit breaker is half-open. Confirm pricing-service health before clearing the breaker.", 0.77},
	{"inventory-service", "app_failure_burst", "revaluation worker OOMKilled", "enriched", "infrastructure",
		"Nightly revaluation worker OOMKilled at the 512Mi limit (rss 548Mi). Raise the memory limit or shard the batch; not a dependency or code fault.", 0.80},
	{"inventory-service", "app_failure_burst", "node disk pressure evicting cache pod", "enriched", "infrastructure",
		"Node under DiskPressure evicted the inventory cache pod, forcing cold reads against the ledger. Reclaim node disk or move the cache to a dedicated node pool.", 0.72},
	{"inventory-service", "error_rate_spike", "SKU lookup NPE after v3.1.0", "enriched", "application",
		"Unhandled NullPointerException in the SKU lookup path introduced by release v3.1.0 returns 500s for unmapped SKUs. Roll back or guard the null branch.", 0.75},
	{"inventory-service", "error_rate_spike", "negative-quantity guard regression", "enriched", "application",
		"A regression dropped the negative-quantity guard, so oversell attempts 500 instead of rejecting cleanly. Restore the guard; no infra or dependency involvement.", 0.73},
	{"inventory-service", "config_change", "connection_pool.max cut 50 to 20", "enriched", "change",
		"Change CHG0044821 cut connection_pool.max from 50 to 20, which is the proximate cause of the pool-exhaustion burst. Revert the change or right-size the pool.", 0.85},
	{"inventory-service", "data_quality", "duplicate SKU rows break positions uniqueness", "enriched", "data",
		"Duplicate SKU rows violate the positions uniqueness assumption, double-counting a handful of holdings. De-dupe the source extract; not a code or infra fault.", 0.68},
	{"inventory-service", "latency_regression", "reservation API latency creeping", "in_progress", "", "", 0},
	{"inventory-service", "latency_regression", "warehouse sync lag climbing", "in_progress", "", "", 0},
	{"inventory-service", "error_rate_spike", "nightly revaluation running long", "in_progress", "", "", 0},
	{"inventory-service", "error_rate_spike", "SKU lookup 5xx after deploy", "new", "", "", 0},
	{"inventory-service", "app_failure_burst", "intermittent 502 from ledger gateway", "new", "", "", 0},

	// --- payments-api: card auth + settlement ---
	{"payments-api", "app_failure_burst", "card-network auth gateway timeouts", "enriched", "dependency",
		"Card-network authorization gateway p99 spiked to 8s and the breaker is opening. Confirm acquirer health before retrying; no code change on our side.", 0.79},
	{"payments-api", "app_failure_burst", "acquirer connection resets mid-auth", "enriched", "dependency",
		"Acquirer gateway is resetting connections mid-authorization, stranding in-flight auths. Fail over to the secondary acquirer endpoint; upstream fault.", 0.72},
	{"payments-api", "error_rate_spike", "tokenization service 5xx burst", "enriched", "dependency",
		"Tokenization service returned a 5xx burst, blocking card captures. Retry against the tokenization replica; not application code.", 0.70},
	{"payments-api", "app_failure_burst", "settlement worker OOMKilled in EOD batch", "enriched", "infrastructure",
		"Settlement worker OOMKilled mid end-of-day batch at the 512Mi limit (rss 548Mi), stalling settlement. Raise the memory limit or shard the batch.", 0.83},
	{"payments-api", "app_failure_burst", "node MemoryPressure evicted settlement pod", "enriched", "infrastructure",
		"Node MemoryPressure evicted the settlement pod, restarting the batch from checkpoint. Move settlement to a memory-guaranteed node pool.", 0.74},
	{"payments-api", "app_failure_burst", "batch spool PVC full", "enriched", "infrastructure",
		"The settlement spool PVC filled, so the batch could not checkpoint and crash-looped. Expand the volume or prune old spool files.", 0.71},
	{"payments-api", "error_rate_spike", "idempotency-key collision, capture guard tripped", "enriched", "application",
		"An idempotency-key collision tripped the double-capture guard, rejecting valid captures. Widen the key space; the guard behaved correctly, the key derivation did not.", 0.76},
	{"payments-api", "error_rate_spike", "NPE in refund path after v2.9", "enriched", "application",
		"Release v2.9 introduced a NullPointerException on partial refunds with no original settlement row. Guard the null path or roll back.", 0.72},
	{"payments-api", "config_change", "worker memory_limit cut 1Gi to 512Mi", "enriched", "change",
		"Change CHG0044907 cut settlement.worker.memory_limit from 1Gi to 512Mi, the proximate cause of the EOD OOM kills. Revert or right-size the limit.", 0.84},
	{"payments-api", "config_change", "retry policy change causing duplicate captures", "enriched", "change",
		"Change CHG0045012 loosened the capture retry policy, producing duplicate captures under acquirer latency. Restore the prior backoff and idempotency window.", 0.80},
	{"payments-api", "error_rate_spike", "settlement batch partial failures", "in_progress", "", "", 0},
	{"payments-api", "latency_regression", "FX rate refresh lag", "in_progress", "", "", 0},
	{"payments-api", "error_rate_spike", "chargeback webhook backlog", "in_progress", "", "", 0},
	{"payments-api", "error_rate_spike", "intermittent 3DS callback 5xx", "new", "", "", 0},

	// --- customer-portal: retail banking portal ---
	{"customer-portal", "error_rate_spike", "NullPointerException in AccountSummary after v2.4.1", "enriched", "application",
		"Release v2.4.1 dereferences a null account object in AccountSummaryController, returning 500s on the signed-in summary view. Roll back v2.4.1 or guard the null branch.", 0.80},
	{"customer-portal", "error_rate_spike", "statement download 500s, template error", "enriched", "application",
		"A template render error in the statement PDF path 500s on download. Fix the template binding; not a downstream dependency.", 0.74},
	{"customer-portal", "error_rate_spike", "balance calc off-by-one after v2.4.1", "enriched", "application",
		"An off-by-one in pending-transaction rollup after v2.4.1 misstates displayed balances. Correct the rollup window; application-only.", 0.71},
	{"customer-portal", "latency_regression", "session-store (Redis) latency, login p95 up", "enriched", "dependency",
		"Session-store Redis latency spiked and the login p95 regressed with it. Check the Redis node and connection pool; upstream, not portal code.", 0.75},
	{"customer-portal", "latency_regression", "accounts-service downstream timeout", "enriched", "dependency",
		"Downstream accounts-service timed out serving balances, cascading to portal 504s. Confirm accounts-service health before retrying.", 0.73},
	{"customer-portal", "latency_regression", "SSO IdP slow token exchange", "enriched", "dependency",
		"The SSO IdP token exchange slowed, so login latency climbed at the auth hop. Escalate to the IdP owners; not a portal fault.", 0.70},
	{"customer-portal", "app_failure_burst", "pod restart loop after image bump", "enriched", "infrastructure",
		"A base-image bump left the portal pod crash-looping on a missing native lib. Roll back the image; infrastructure, not request handling.", 0.72},
	{"customer-portal", "app_failure_burst", "ingress cert renewal blip", "enriched", "infrastructure",
		"An ingress TLS cert renewal blip briefly failed handshakes for signed-in users. Renewal completed; add a pre-expiry alert.", 0.69},
	{"customer-portal", "config_change", "release v2.4.1 rollout regression", "enriched", "change",
		"Release v2.4.1 is the change window that opened the account-summary error burst. Roll back v2.4.1 to confirm and clear.", 0.82},
	{"customer-portal", "config_change", "CSP header change broke static assets", "enriched", "change",
		"Change CHG0044933 tightened the CSP header and blocked portal static assets, blanking the dashboard. Restore the asset origin in the policy.", 0.78},
	{"customer-portal", "data_quality", "stale account cache serving old balances", "enriched", "data",
		"A stale account cache served outdated balances after a ledger update. Invalidate the cache key on ledger change; a data-freshness fault, not code.", 0.68},
	{"customer-portal", "latency_regression", "CDN cache-miss storm", "in_progress", "", "", 0},
	{"customer-portal", "error_rate_spike", "intermittent logout on refresh", "in_progress", "", "", 0},
	{"customer-portal", "error_rate_spike", "mobile deep-link 404s", "in_progress", "", "", 0},
	{"customer-portal", "error_rate_spike", "profile-photo upload 500", "new", "", "", 0},
}

func seedIncidents(st *store, sn *snClient, es *esClient) {
	perApp := map[string]int{}
	for _, s := range seedIncidentSet {
		corr := fmt.Sprintf("seed-%s-%02d", s.app, perApp[s.app])
		perApp[s.app]++
		snap := st.seedTicket(s, corr)
		snState := "1" // New
		if s.state == "in_progress" || s.state == "enriched" {
			snState = "2" // In Progress
		}
		snap = syncTicket(st, sn, es, snap, s.rca, snState)
		log.Printf("seeded incident %s for %s (state=%s, ticket=%s)", corr, s.app, s.state, snap.IncNumber)
	}
}
