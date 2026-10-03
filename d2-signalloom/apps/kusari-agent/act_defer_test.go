package main

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

// Live, 2026-10-03: e2e Step 3 failed both runs with "connection reset by
// peer". The sentinel froze the stub ~1 ms after its openat, inside the
// request, so the synchronous answer could never be written; earlier greens
// only got one because the freeze used to be thawed by a resync. With the
// freeze now held until an authorised release, a provocation that must be
// answered has to answer BEFORE it acts: ?defer=D returns 202 with the order
// and performs the open D later.

func logged(a *agent) string {
	a.logMu.Lock()
	defer a.logMu.Unlock()
	return a.logW.(interface{ String() string }).String()
}

func TestActDeferAnswersBeforeItOpens(t *testing.T) {
	a, _, passwd := actAgent(t)
	a.hostname = "agent-kusari-5685ff664b-f9zxz"
	a.now = time.Now // scheduled_for is checked against the wall clock
	before := time.Now()
	rec, body := post(t, a.routes(), "/act/read-passwd?defer=300ms")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202: %s", rec.Code, rec.Body.String())
	}
	if body["action"] != "read-passwd" || body["ok"] != true || body["scheduled"] != true {
		t.Fatalf("envelope = %v", body)
	}
	if body["pod"] != a.hostname || body["path"] != passwd || body["defer_ms"] != float64(300) {
		t.Fatalf("order = %v", body)
	}
	at, err := time.Parse(time.RFC3339Nano, body["scheduled_for"].(string))
	if err != nil {
		t.Fatalf("scheduled_for: %v", err)
	}
	if d := at.Sub(before); d < 300*time.Millisecond || d > 2*time.Second {
		t.Fatalf("scheduled_for is %v after the request, want ~300ms", d)
	}
	// Answered, and nothing opened yet: the act has not run.
	if strings.Contains(logged(a), `"event":"act"`) {
		t.Fatalf("the open ran before the answer: %s", logged(a))
	}
	// Then it does run, on a traced thread, and reads the file.
	deadline := time.Now().Add(3 * time.Second)
	for !strings.Contains(logged(a), `"event":"act"`) {
		if time.Now().After(deadline) {
			t.Fatalf("the deferred open never ran: %s", logged(a))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if ran := time.Now(); ran.Before(at) {
		t.Fatalf("ran at %v, before scheduled_for %v", ran, at)
	}
	l := logged(a)
	if !strings.Contains(l, `"action":"read-passwd"`) || !strings.Contains(l, `"ok":true`) || strings.Contains(l, `"tid":0`) {
		t.Fatalf("act log = %s", l)
	}
	if strings.Contains(rec.Body.String(), "root:x:0") {
		t.Fatalf("leaked file content: %s", rec.Body.String())
	}
}

func TestActDeferWorksForShadowToo(t *testing.T) {
	a, _, _ := actAgent(t)
	rec, body := post(t, a.routes(), "/act/read-shadow?defer=10ms")
	if rec.Code != http.StatusAccepted || body["action"] != "read-shadow" || body["scheduled"] != true {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
}

func TestActDeferRejectsABadDelay(t *testing.T) {
	a, _, _ := actAgent(t)
	for _, v := range []string{"soon", "0s", "-1s", "11s"} {
		rec, body := post(t, a.routes(), "/act/read-passwd?defer="+v)
		if rec.Code != http.StatusBadRequest || body["ok"] != false || body["scheduled"] == true {
			t.Fatalf("defer=%s: code %d body %v", v, rec.Code, body)
		}
	}
	time.Sleep(50 * time.Millisecond)
	if strings.Contains(logged(a), `"event":"act"`) {
		t.Fatalf("a rejected order still opened the file: %s", logged(a))
	}
}

// Without ?defer the provocation is the synchronous one it always was.
func TestActWithoutDeferStillAnswersAfterTheOpen(t *testing.T) {
	a, _, _ := actAgent(t)
	rec, body := post(t, a.routes(), "/act/read-passwd")
	if rec.Code != http.StatusOK || body["scheduled"] != nil || body["lines"] != float64(2) {
		t.Fatalf("code %d body %v", rec.Code, body)
	}
}
