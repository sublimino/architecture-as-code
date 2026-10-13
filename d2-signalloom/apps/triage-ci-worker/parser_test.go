package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestParseFailures_GoTestOutput(t *testing.T) {
	log := `=== RUN   TestLogin
--- FAIL: TestLogin (0.45s)
    login_test.go:42: expected 200 got 401
=== RUN   TestSignup
--- PASS: TestSignup (0.12s)
=== RUN   TestLogout
--- FAIL: TestLogout (0.30s)
    logout_test.go:18: session not invalidated
FAIL	github.com/example/auth	0.87s`

	failures := ParseFailures(log)
	if len(failures) != 2 {
		t.Fatalf("expected 2 failures, got %d: %v", len(failures), failures)
	}
	if failures[0].Name != "TestLogin" {
		t.Errorf("expected TestLogin, got %s", failures[0].Name)
	}
	if failures[0].Detail != "login_test.go:42: expected 200 got 401" {
		t.Errorf("unexpected detail: %s", failures[0].Detail)
	}
	if failures[1].Name != "TestLogout" {
		t.Errorf("expected TestLogout, got %s", failures[1].Name)
	}
}

func TestParseFailures_PytestOutput(t *testing.T) {
	log := `FAILED tests/test_auth.py::test_login - AssertionError: 401 != 200
PASSED tests/test_auth.py::test_signup
FAILED tests/test_auth.py::test_refresh - TimeoutError`

	failures := ParseFailures(log)
	if len(failures) != 2 {
		t.Fatalf("expected 2 failures, got %d", len(failures))
	}
	if failures[0].Name != "tests/test_auth.py::test_login" {
		t.Errorf("unexpected name: %s", failures[0].Name)
	}
}

func TestParseFailures_EmptyLog(t *testing.T) {
	failures := ParseFailures("")
	if len(failures) != 0 {
		t.Fatalf("expected 0 failures, got %d", len(failures))
	}
}

func TestDeduplicateFlaky(t *testing.T) {
	failures := []TestFailure{
		{Name: "TestLogin", Detail: "timeout"},
		{Name: "TestFlaky", Detail: "intermittent"},
		{Name: "TestLogout", Detail: "session error"},
	}
	knownFlaky := []string{"TestFlaky", "TestKnownBad"}

	real, flaky := DeduplicateFlaky(failures, knownFlaky)
	if len(real) != 2 {
		t.Fatalf("expected 2 real failures, got %d", len(real))
	}
	if len(flaky) != 1 {
		t.Fatalf("expected 1 flaky, got %d", len(flaky))
	}
	if flaky[0].Name != "TestFlaky" {
		t.Errorf("expected TestFlaky, got %s", flaky[0].Name)
	}
}

func TestFormatTriageComment(t *testing.T) {
	real := []TestFailure{{Name: "TestLogin", Detail: "expected 200 got 401"}}
	flaky := []TestFailure{{Name: "TestFlaky", Detail: "intermittent"}}

	comment := FormatTriageComment(real, flaky)
	if comment == "" {
		t.Fatal("expected non-empty comment")
	}
	// Should contain the failure name
	if !containsString(comment, "TestLogin") {
		t.Error("comment should mention TestLogin")
	}
	// Should mention flaky
	if !containsString(comment, "TestFlaky") {
		t.Error("comment should mention flaky test")
	}
}

func TestFormatTriageComment_Truncation(t *testing.T) {
	var real []TestFailure
	for i := 0; i < 120; i++ {
		real = append(real, TestFailure{Name: fmt.Sprintf("TestFailure_%d", i), Detail: "assertion error at line 42"})
	}

	comment := FormatTriageComment(real, nil)
	if !containsString(comment, "more real failure(s) omitted") {
		t.Error("expected truncation notice for >50 failures")
	}
	if len(comment) > maxCommentLength {
		t.Errorf("comment length %d exceeds max %d", len(comment), maxCommentLength)
	}
}

func TestSuggestLabels(t *testing.T) {
	real := []TestFailure{{Name: "TestLogin", Detail: "timeout"}}
	flaky := []TestFailure{{Name: "TestFlaky", Detail: "intermittent"}}

	labels := SuggestLabels(real, flaky)
	if len(labels) == 0 {
		t.Fatal("expected at least one label")
	}
	hasTriageLabel := false
	for _, l := range labels {
		if l == "triage:ci-failure" {
			hasTriageLabel = true
		}
	}
	if !hasTriageLabel {
		t.Error("expected triage:ci-failure label")
	}
}

func containsString(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && stringContains(s, substr))
}

func stringContains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func TestHealthEndpoints(t *testing.T) {
	mux := newMux()
	paths := []string{"/health", "/healthz", "/readyz"}
	for _, p := range paths {
		req := httptest.NewRequest(http.MethodGet, p, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("%s returned status %d, want 200", p, rec.Code)
		}
	}
}
