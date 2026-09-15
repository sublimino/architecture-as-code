// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestAdmissionClient_BlockAdmission_Success(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	client := NewK8sAdmissionClient(clientset, "fe-signalloom")

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-block-1",
		AgentID:        "agent-cardvault",
		Namespace:      "fe-signalloom-agents",
		SPIFFEID:       "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-cardvault",
		Reason:         "containment cascade",
	}

	resp, err := client.BlockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.Outcome != OutcomeContained {
		t.Fatalf("expected outcome %s, got %s", OutcomeContained, resp.Outcome)
	}
	if !resp.BlockEnforced {
		t.Fatalf("expected BlockEnforced=true")
	}

	// Verify ConfigMap was created and populated
	cm, err := clientset.CoreV1().ConfigMaps("fe-signalloom").Get(context.Background(), DefaultContainedAgentsConfigMap, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("failed to get configmap: %v", err)
	}

	data := cm.Data[ContainedAgentsDataKey]
	if !strings.Contains(data, "agent-cardvault") {
		t.Fatalf("expected configmap to contain agent-cardvault, got: %s", data)
	}
}

func TestAdmissionClient_UnblockAdmission_Success(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	client := NewK8sAdmissionClient(clientset, "fe-signalloom")

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-block-2",
		AgentID:        "agent-target",
		Namespace:      "fe-signalloom-agents",
	}

	// Block first
	_, err := client.BlockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("block failed: %v", err)
	}

	// Unblock
	unblockResp, err := client.UnblockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("unblock failed: %v", err)
	}
	if unblockResp.Outcome != OutcomeContained {
		t.Fatalf("expected outcome %s, got %s", OutcomeContained, unblockResp.Outcome)
	}
	if unblockResp.BlockEnforced {
		t.Fatalf("expected BlockEnforced=false")
	}

	// Verify ConfigMap no longer contains agent
	cm, err := clientset.CoreV1().ConfigMaps("fe-signalloom").Get(context.Background(), DefaultContainedAgentsConfigMap, metav1.GetOptions{})
	if err != nil {
		t.Fatalf("failed to get configmap: %v", err)
	}

	data := cm.Data[ContainedAgentsDataKey]
	if strings.Contains(data, "agent-target") {
		t.Fatalf("expected configmap to not contain agent-target after unblock, got: %s", data)
	}
}

func TestAdmissionClient_Idempotency(t *testing.T) {
	clientset := fake.NewSimpleClientset()
	client := NewK8sAdmissionClient(clientset, "fe-signalloom")

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-idem",
		AgentID:        "agent-idem",
		Namespace:      "fe-signalloom-agents",
	}

	resp1, err := client.BlockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("first block failed: %v", err)
	}

	resp2, err := client.BlockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("second block failed: %v", err)
	}

	if resp1.Outcome != resp2.Outcome {
		t.Fatalf("expected matching outcomes, got %s and %s", resp1.Outcome, resp2.Outcome)
	}
}

func TestAdmissionClient_StructuredLogging(t *testing.T) {
	var loggedEntries []AdmissionBlockAuditLogEntry
	var mu sync.Mutex

	logger := func(entry AdmissionBlockAuditLogEntry) {
		mu.Lock()
		defer mu.Unlock()
		loggedEntries = append(loggedEntries, entry)
	}

	clientset := fake.NewSimpleClientset()
	client := NewK8sAdmissionClientWithLogger(clientset, "fe-signalloom", time.Now, logger)

	req := AdmissionBlockRequest{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "test-log-key",
		AgentID:        "agent-logged",
		Namespace:      "fe-signalloom-agents",
	}

	_, err := client.BlockAdmission(context.Background(), req)
	if err != nil {
		t.Fatalf("block failed: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()

	if len(loggedEntries) == 0 {
		t.Fatalf("expected structured log entry to be emitted")
	}

	entry := loggedEntries[0]
	if entry.Event != AdmissionBlockEventName {
		t.Errorf("expected event %s, got %s", AdmissionBlockEventName, entry.Event)
	}
	if entry.Outcome != OutcomeContained {
		t.Errorf("expected outcome %s, got %s", OutcomeContained, entry.Outcome)
	}
	if entry.WorstCaseResidualMs != 0 {
		t.Errorf("expected worst_case_residual_ms=0 for admission block")
	}

	// Verify marshalled JSON contains all SharedAttestationEventKeys
	raw, err := json.Marshal(entry)
	if err != nil {
		t.Fatalf("failed to marshal log entry: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to unmarshal log entry: %v", err)
	}

	for _, key := range SharedAttestationEventKeys {
		if _, ok := parsed[key]; !ok {
			t.Errorf("missing shared attestation event key: %s", key)
		}
	}
}

func TestAdmissionResponseToPlaneResult(t *testing.T) {
	resp := &AdmissionBlockResponse{
		SchemaVersion:  CurrentSchemaVersion,
		IdempotencyKey: "key-123",
		AgentID:        "agent-cardvault",
		Plane:          PlaneAdmission,
		Outcome:        OutcomeContained,
		RuleID:         "rule-cardvault",
		BlockEnforced:  true,
		LatencyMs:      2,
		Timestamp:      time.Now().UTC().Format(time.RFC3339),
	}

	res := AdmissionResponseToPlaneResult(resp, "fe-signalloom-agents")
	if res.Plane != PlaneAdmission {
		t.Errorf("expected plane %s, got %s", PlaneAdmission, res.Plane)
	}
	if res.Outcome != OutcomeContained {
		t.Errorf("expected outcome %s, got %s", OutcomeContained, res.Outcome)
	}
	if res.Details["block_enforced"] != true {
		t.Errorf("expected details.block_enforced=true")
	}
	if res.Details["failure_policy"] != "Fail" {
		t.Errorf("expected details.failure_policy=Fail")
	}
}
