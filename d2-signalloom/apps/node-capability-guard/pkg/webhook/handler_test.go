package webhook_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/node-capability-guard/pkg/webhook"
)

func TestNonAgentPodAllowed(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name: "normal-app",
		},
	}
	allowed, _ := webhook.ValidatePod(pod)
	if !allowed {
		t.Fatalf("expected non-agent pod to be allowed")
	}
}

func TestUnconfinedAgentPodRejected(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name: "rogue-agent",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
			},
		},
	}
	allowed, msg := webhook.ValidatePod(pod)
	if allowed {
		t.Fatalf("expected unconfined agent pod to be rejected")
	}
	if !strings.Contains(msg, "cgroup-v2=true, landlock=true") {
		t.Fatalf("expected message to mention containment capabilities, got: %s", msg)
	}
}

func TestCompliantAgentPodAllowed(t *testing.T) {
	pod := &webhook.Pod{
		Metadata: webhook.Metadata{
			Name: "compliant-agent",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
			},
		},
		Spec: webhook.PodSpec{
			NodeSelector: map[string]string{
				"node.signalloom.ai/cgroup-v2": "true",
				"node.signalloom.ai/landlock":  "true",
			},
		},
	}
	allowed, _ := webhook.ValidatePod(pod)
	if !allowed {
		t.Fatalf("expected compliant agent pod to be allowed")
	}
}

func TestHTTPWebhookValidation(t *testing.T) {
	pod := webhook.Pod{
		Metadata: webhook.Metadata{
			Name: "unconfined-pod",
			Labels: map[string]string{
				"signalloom.ai/agent": "true",
			},
		},
	}
	rawPod, _ := json.Marshal(pod)

	reqReview := webhook.AdmissionReview{
		APIVersion: "admission.k8s.io/v1",
		Kind:       "AdmissionReview",
		Request: &webhook.AdmissionRequest{
			UID:    "test-uid-1234",
			Object: rawPod,
		},
	}
	body, _ := json.Marshal(reqReview)

	req := httptest.NewRequest(http.MethodPost, "/validate", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	webhook.HandleValidate(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d", rec.Code)
	}

	var respReview webhook.AdmissionReview
	if err := json.Unmarshal(rec.Body.Bytes(), &respReview); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if respReview.Response == nil {
		t.Fatalf("expected admission response, got nil")
	}
	if respReview.Response.Allowed {
		t.Fatalf("expected request to be denied")
	}
	if respReview.Response.Result.Code != 403 {
		t.Fatalf("expected 403 status code, got %d", respReview.Response.Result.Code)
	}
}
