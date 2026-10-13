package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/pkg/fair"
)

// partialFleetSource is a fleet whose middle agent cannot be assessed: it is
// listed by AgentIDs but has no telemetry, so Assess returns ErrUnknownAgent.
// This is not a contrived state -- an agent registered but not yet reporting,
// or evicted between the two calls, produces exactly it.
type partialFleetSource struct {
	ids       []string
	unhealthy map[string]bool
}

func (s partialFleetSource) AgentIDs() []string { return s.ids }

func (s partialFleetSource) AgentTelemetry(id string) (fair.Telemetry, bool) {
	if s.unhealthy[id] {
		return fair.Telemetry{}, false
	}
	return fair.Telemetry{
		AgentID:               id,
		RuntimeViolations:     2,
		NetworkAnomalies:      1,
		CredentialState:       "healthy",
		CVECritical:           1,
		CVEHigh:               2,
		CVEMedium:             3,
		ObservationWindowDays: 30,
		ObservationCount:      400,
	}, true
}

func fleetRiskRequest() *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/api/v1/risk/fleet", nil)
	return r.WithContext(context.WithValue(r.Context(), principalContextKey{},
		Principal{
			Subject:     "auditor",
			Permissions: map[Permission]bool{PermissionCrossTenantRead: true},
		}))
}

// A fleet exposure total is the single most quotable number this service
// publishes. The handler summed only the agents that assessed successfully --
// `continue` on error -- while reporting agentCount as the full fleet size, so
// a fleet of 3 with 1 unassessable agent returned a 2-agent total labelled as
// covering 3. Nothing in the response said coverage was partial, so the figure
// understated exposure and read as complete. An HTTP 200 carrying a total that
// silently omits part of its population is the failure mode this sweep exists
// to remove: it is quoted out loud as "our fleet carries £X".
func TestFleetRiskDeclaresAssessmentCoverage(t *testing.T) {
	src := partialFleetSource{
		ids:       []string{"agent-a", "agent-b", "agent-c"},
		unhealthy: map[string]bool{"agent-b": true},
	}
	h := &Handlers{FairService: fair.NewService(src)}

	w := httptest.NewRecorder()
	h.handleGetFleetRisk(w, fleetRiskRequest())

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}

	// The response must state how many agents the totals actually cover, so a
	// consumer can tell a complete total from a partial one.
	assessed, ok := resp["agentsAssessed"]
	if !ok {
		t.Fatal("response does not report agentsAssessed: a total whose coverage " +
			"is unstated cannot be distinguished from a complete one")
	}
	if got := assessed.(float64); got != 2 {
		t.Errorf("agentsAssessed = %v, want 2 (agent-b cannot be assessed)", got)
	}

	// And it must name the agents missing from the total, so the gap is
	// actionable rather than merely disclosed as a count.
	failed, ok := resp["agentsUnassessed"]
	if !ok {
		t.Fatal("response does not report agentsUnassessed")
	}
	names, ok := failed.([]any)
	if !ok || len(names) != 1 || names[0].(string) != "agent-b" {
		t.Errorf("agentsUnassessed = %v, want [agent-b]", failed)
	}

	// agentCount keeps meaning fleet size, so the discrepancy is visible rather
	// than hidden by quietly redefining the field.
	if got := resp["agentCount"].(float64); got != 3 {
		t.Errorf("agentCount = %v, want 3 (the fleet size)", got)
	}

	// The totals must still be real, not nulled to dodge the problem: two
	// healthy agents carry a positive exposure.
	exposure := resp["exposure"].(map[string]any)
	ale := exposure["ale"].(map[string]any)["amount"].(float64)
	if ale <= 0 {
		t.Errorf("ale = %v, want a positive total from the 2 assessable agents", ale)
	}
}

// The companion case: when every agent assesses, coverage equals the fleet and
// the gap list is empty. Without this, nulling or zeroing the new fields would
// satisfy the test above.
func TestFleetRiskReportsFullCoverageWhenAllAgentsAssess(t *testing.T) {
	src := partialFleetSource{ids: []string{"agent-a", "agent-b"}}
	h := &Handlers{FairService: fair.NewService(src)}

	w := httptest.NewRecorder()
	h.handleGetFleetRisk(w, fleetRiskRequest())

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got := resp["agentsAssessed"].(float64); got != 2 {
		t.Errorf("agentsAssessed = %v, want 2", got)
	}
	if got := resp["agentCount"].(float64); got != 2 {
		t.Errorf("agentCount = %v, want 2", got)
	}
	if names := resp["agentsUnassessed"].([]any); len(names) != 0 {
		t.Errorf("agentsUnassessed = %v, want empty", names)
	}
}

func TestFleetRisk_MethodGatesAndHEAD(t *testing.T) {
	src := partialFleetSource{ids: []string{"agent-a"}}
	h := &Handlers{FairService: fair.NewService(src)}

	// handleGetFleetRisk: POST returns 405 with Allow: GET, HEAD, OPTIONS
	reqPost := httptest.NewRequest(http.MethodPost, "/api/v1/risk/fleet", nil)
	wPost := httptest.NewRecorder()
	h.handleGetFleetRisk(wPost, reqPost)
	if wPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST handleGetFleetRisk: want 405, got %d", wPost.Code)
	}
	if allow := wPost.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("POST handleGetFleetRisk: want Allow 'GET, HEAD, OPTIONS', got %q", allow)
	}

	// handleGetFleetRisk: HEAD returns 200 with 0 body bytes
	reqHead := httptest.NewRequest(http.MethodHead, "/api/v1/risk/fleet", nil)
	reqHead = reqHead.WithContext(context.WithValue(reqHead.Context(), principalContextKey{},
		Principal{
			Subject:     "auditor",
			Permissions: map[Permission]bool{PermissionCrossTenantRead: true},
		}))
	wHead := httptest.NewRecorder()
	h.handleGetFleetRisk(wHead, reqHead)
	if wHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleGetFleetRisk: want 200, got %d", wHead.Code)
	}
	if wHead.Body.Len() != 0 {
		t.Errorf("HEAD handleGetFleetRisk: want 0 body bytes, got %d", wHead.Body.Len())
	}
	if ct := wHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD handleGetFleetRisk: want Content-Type 'application/json', got %q", ct)
	}

	// handleGetAgentRisk: POST returns 405 with Allow: GET, HEAD, OPTIONS
	reqAgentPost := httptest.NewRequest(http.MethodPost, "/api/v1/risk/agents/agent-a", nil)
	wAgentPost := httptest.NewRecorder()
	h.handleGetAgentRisk(wAgentPost, reqAgentPost)
	if wAgentPost.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST handleGetAgentRisk: want 405, got %d", wAgentPost.Code)
	}
	if allow := wAgentPost.Header().Get("Allow"); allow != "GET, HEAD, OPTIONS" {
		t.Errorf("POST handleGetAgentRisk: want Allow 'GET, HEAD, OPTIONS', got %q", allow)
	}

	// handleGetAgentRisk: HEAD returns 200 with 0 body bytes
	reqAgentHead := httptest.NewRequest(http.MethodHead, "/api/v1/risk/agents/agent-a", nil)
	reqAgentHead.SetPathValue("id", "agent-a")
	reqAgentHead = reqAgentHead.WithContext(context.WithValue(reqAgentHead.Context(), principalContextKey{},
		Principal{
			Subject:     "auditor",
			Permissions: map[Permission]bool{PermissionCrossTenantRead: true},
		}))
	wAgentHead := httptest.NewRecorder()
	h.handleGetAgentRisk(wAgentHead, reqAgentHead)
	if wAgentHead.Code != http.StatusOK {
		t.Fatalf("HEAD handleGetAgentRisk: want 200, got %d", wAgentHead.Code)
	}
	if wAgentHead.Body.Len() != 0 {
		t.Errorf("HEAD handleGetAgentRisk: want 0 body bytes, got %d", wAgentHead.Body.Len())
	}
	if ct := wAgentHead.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("HEAD handleGetAgentRisk: want Content-Type 'application/json', got %q", ct)
	}
}
