package api

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/signal-ingest/audit"
)

// RouteRegisteredLogMessage is a contract with d2-signalloom/test/api-route-liveness.bats, which
// reads the RUNNING process's route table out of its startup log. That is the only readback that
// needs no request: behind ProtectedRouter an anonymous probe is a 401 on every path, a GET on a
// POST-only route is 403 unregistered_route (ServeMux reports no pattern for a method mismatch),
// and an authenticated POST would execute side-effecting handlers such as collectors/seed.
const RouteRegisteredLogMessage = "HTTP authorization route registered"

// TestEveryRegisteredRouteIsAnnouncedInTheStartupLog: one JSON log line per route, carrying the
// method and pattern, so the live suite's reading of the log is the router's own inventory.
func TestEveryRegisteredRouteIsAnnouncedInTheStartupLog(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	h, _ := newTestHandlers(t)
	router, err := NewProtectedRouter(h, stubDenyAuthenticator{}, audit.NewFakeWriter(), http.NotFoundHandler(), RouterOptions{})
	if err != nil {
		t.Fatal(err)
	}

	logged := map[string]bool{}
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var line struct{ Msg, Method, Route string }
		if json.Unmarshal(sc.Bytes(), &line) == nil && line.Msg == RouteRegisteredLogMessage {
			logged[line.Method+" "+line.Route] = true
		}
	}
	inventory := router.Inventory()
	if len(inventory) == 0 {
		t.Fatal("router inventory is empty; this test asserted nothing")
	}
	for _, rr := range inventory {
		if !logged[rr.Method+" "+rr.Path] {
			t.Errorf("route %s %s is registered but not announced as %q with method and route fields",
				rr.Method, rr.Path, RouteRegisteredLogMessage)
		}
	}
	if len(logged) != len(inventory) {
		t.Errorf("announced %d routes, registered %d", len(logged), len(inventory))
	}
}

type stubDenyAuthenticator struct{}

func (stubDenyAuthenticator) Authenticate(*http.Request) (Principal, error) {
	return Principal{}, ErrMissingCredential
}
