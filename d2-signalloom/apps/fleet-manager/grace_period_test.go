package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestGracePeriod_BatchVsPIICalculations(t *testing.T) {
	evaluator := NewGracePeriodEvaluator()

	tests := []struct {
		name            string
		agentType       string
		riskClass       string
		dataSensitivity string
		wantGrace       time.Duration
	}{
		// 72h for batch data processing agents (e.g. agent-txn-pipeline with medium risk)
		{
			name:            "agent-txn-pipeline medium risk data-pipeline",
			agentType:       "data-pipeline",
			riskClass:       "medium",
			dataSensitivity: "transaction",
			wantGrace:       72 * time.Hour,
		},
		{
			name:            "batch processing medium risk unspecified sensitivity",
			agentType:       "batch",
			riskClass:       "medium",
			dataSensitivity: "",
			wantGrace:       72 * time.Hour,
		},
		{
			name:            "batch-data-processing medium risk standard sensitivity",
			agentType:       "batch-data-processing",
			riskClass:       "medium",
			dataSensitivity: "standard",
			wantGrace:       72 * time.Hour,
		},
		{
			name:            "data-processing low risk",
			agentType:       "data-processing",
			riskClass:       "low",
			dataSensitivity: "internal",
			wantGrace:       72 * time.Hour,
		},
		// 0h (immediate enforcement) for high-risk customer PII workloads (e.g. agent-llm-classifier)
		{
			name:            "agent-llm-classifier high risk customer-pii",
			agentType:       "llm-inference",
			riskClass:       "high",
			dataSensitivity: "customer-pii",
			wantGrace:       0,
		},
		{
			name:            "agent-llm-classifier high risk pii shorthand",
			agentType:       "llm-inference",
			riskClass:       "high",
			dataSensitivity: "pii",
			wantGrace:       0,
		},
		{
			name:            "llm-inference high risk default sensitivity",
			agentType:       "llm-inference",
			riskClass:       "high",
			dataSensitivity: "",
			wantGrace:       0,
		},
		{
			name:            "generic service high risk with customer-pii",
			agentType:       "service",
			riskClass:       "high",
			dataSensitivity: "customer-pii",
			wantGrace:       0,
		},
		{
			name:            "agent-cardvault high risk pci",
			agentType:       "data-vault",
			riskClass:       "high",
			dataSensitivity: "pci",
			wantGrace:       0,
		},
		{
			name:            "batch data processing with customer-pii overrides to 0h",
			agentType:       "data-pipeline",
			riskClass:       "high",
			dataSensitivity: "customer-pii",
			wantGrace:       0,
		},
		// Critical risk is always 0h immediate enforcement
		{
			name:            "critical risk batch agent",
			agentType:       "data-pipeline",
			riskClass:       "critical",
			dataSensitivity: "",
			wantGrace:       0,
		},
		{
			name:            "critical risk observability agent",
			agentType:       "observability",
			riskClass:       "critical",
			dataSensitivity: "",
			wantGrace:       0,
		},
		// Observability agents (168h)
		{
			name:            "observability agent low risk",
			agentType:       "observability",
			riskClass:       "low",
			dataSensitivity: "",
			wantGrace:       168 * time.Hour,
		},
		{
			name:            "monitor agent low risk",
			agentType:       "monitor",
			riskClass:       "low",
			dataSensitivity: "",
			wantGrace:       168 * time.Hour,
		},
		// API Gateway / Ingress agents
		{
			name:            "api-gateway medium risk",
			agentType:       "api-gateway",
			riskClass:       "medium",
			dataSensitivity: "",
			wantGrace:       24 * time.Hour,
		},
		{
			name:            "api-gateway low risk",
			agentType:       "api-gateway",
			riskClass:       "low",
			dataSensitivity: "",
			wantGrace:       168 * time.Hour,
		},
		{
			name:            "api-gateway high risk non-pii",
			agentType:       "api-gateway",
			riskClass:       "high",
			dataSensitivity: "internal",
			wantGrace:       12 * time.Hour,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := evaluator.CalculateGracePeriod(tt.agentType, tt.riskClass, tt.dataSensitivity)
			if got != tt.wantGrace {
				t.Errorf("CalculateGracePeriod(%q, %q, %q) = %v, want %v",
					tt.agentType, tt.riskClass, tt.dataSensitivity, got, tt.wantGrace)
			}

			// Also verify Evaluate alias
			gotAlias := evaluator.Evaluate(tt.agentType, tt.riskClass, tt.dataSensitivity)
			if gotAlias != tt.wantGrace {
				t.Errorf("Evaluate alias returned %v, want %v", gotAlias, tt.wantGrace)
			}

			// Verify EvaluateAgent with AgentProfile struct
			profile := &AgentProfile{
				Type:            tt.agentType,
				RiskClass:       tt.riskClass,
				DataSensitivity: tt.dataSensitivity,
			}
			gotAgent := evaluator.EvaluateAgent(profile)
			if gotAgent != tt.wantGrace {
				t.Errorf("EvaluateAgent returned %v, want %v", gotAgent, tt.wantGrace)
			}
		})
	}
}

func TestGracePeriod_DurationParsing(t *testing.T) {
	evaluator := NewGracePeriodEvaluator()

	validTests := []struct {
		input     string
		wantGrace time.Duration
	}{
		{"72h", 72 * time.Hour},
		{"0h", 0},
		{"0", 0},
		{"", 0},
		{"0s", 0},
		{"0m", 0},
		{"24h", 24 * time.Hour},
		{"168h", 168 * time.Hour},
		{"12h", 12 * time.Hour},
		{"30m", 30 * time.Minute},
		{"1h30m", 90 * time.Minute},
		{" 72H ", 72 * time.Hour},
		{"\t24h\n", 24 * time.Hour},
		{"0H", 0},
	}

	for _, tt := range validTests {
		t.Run("valid_"+tt.input, func(t *testing.T) {
			got, err := ParseGracePeriod(tt.input)
			if err != nil {
				t.Fatalf("ParseGracePeriod(%q) unexpected error: %v", tt.input, err)
			}
			if got != tt.wantGrace {
				t.Errorf("ParseGracePeriod(%q) = %v, want %v", tt.input, got, tt.wantGrace)
			}

			// Test instance method
			gotInst, err := evaluator.ParseDuration(tt.input)
			if err != nil {
				t.Fatalf("evaluator.ParseDuration(%q) unexpected error: %v", tt.input, err)
			}
			if gotInst != tt.wantGrace {
				t.Errorf("evaluator.ParseDuration(%q) = %v, want %v", tt.input, gotInst, tt.wantGrace)
			}
		})
	}

	invalidTests := []string{
		"-5h",
		"-1s",
		"invalid",
		"abc",
		"72hours",
		"2 days",
	}

	for _, input := range invalidTests {
		t.Run("invalid_"+input, func(t *testing.T) {
			_, err := ParseGracePeriod(input)
			if err == nil {
				t.Errorf("ParseGracePeriod(%q) expected error for invalid input, got nil", input)
			}
		})
	}

	formatTests := []struct {
		duration time.Duration
		want     string
	}{
		{72 * time.Hour, "72h"},
		{0, "0h"},
		{-1 * time.Hour, "0h"},
		{24 * time.Hour, "24h"},
		{168 * time.Hour, "168h"},
		{30 * time.Minute, "30m"},
	}

	for _, tt := range formatTests {
		t.Run("format_"+tt.want, func(t *testing.T) {
			got := FormatDuration(tt.duration)
			if got != tt.want {
				t.Errorf("FormatDuration(%v) = %q, want %q", tt.duration, got, tt.want)
			}
		})
	}
}

func TestGracePeriod_StateMachine(t *testing.T) {
	evaluator := NewGracePeriodEvaluator()
	baseTime := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

	t.Run("compliant agents remain active", func(t *testing.T) {
		batchAgent := &AgentProfile{
			ID:              "agent-txn-pipeline",
			Type:            "data-pipeline",
			RiskClass:       "medium",
			DataSensitivity: "transaction",
		}

		res := evaluator.EvaluateState(batchAgent, true, baseTime, baseTime)
		if res.State != AgentStateActive {
			t.Errorf("expected compliant agent state %q, got %q", AgentStateActive, res.State)
		}
		if !res.IsCompliant {
			t.Errorf("expected IsCompliant true")
		}
		if res.InGracePeriod {
			t.Errorf("compliant agent should not be in grace period")
		}
		if res.RemainingHours != 0 {
			t.Errorf("compliant agent should have 0 remaining hours, got %v", res.RemainingHours)
		}

		piiAgent := &AgentProfile{
			ID:              "agent-llm-classifier",
			Type:            "llm-inference",
			RiskClass:       "high",
			DataSensitivity: "customer-pii",
		}
		resPII := evaluator.EvaluateState(piiAgent, true, baseTime, baseTime)
		if resPII.State != AgentStateActive {
			t.Errorf("expected compliant PII agent state %q, got %q", AgentStateActive, resPII.State)
		}
	})

	t.Run("non-compliant agent within grace period transitions to grace-period", func(t *testing.T) {
		batchAgent := &AgentProfile{
			ID:              "agent-txn-pipeline",
			Type:            "data-pipeline",
			RiskClass:       "medium",
			DataSensitivity: "transaction",
		}

		detectedAt := baseTime
		// Evaluated 10 hours after non-compliance detection (62 hours remaining of 72h)
		now := detectedAt.Add(10 * time.Hour)

		res := evaluator.EvaluateState(batchAgent, false, detectedAt, now)
		if res.State != AgentStateGracePeriod {
			t.Fatalf("expected state %q, got %q", AgentStateGracePeriod, res.State)
		}
		if res.IsCompliant {
			t.Errorf("expected IsCompliant false")
		}
		if !res.InGracePeriod {
			t.Errorf("expected InGracePeriod true")
		}
		if res.IsExpired {
			t.Errorf("expected IsExpired false")
		}
		if res.GracePeriod != 72*time.Hour {
			t.Errorf("expected GracePeriod 72h, got %v", res.GracePeriod)
		}

		wantExpiry := detectedAt.Add(72 * time.Hour).Format(time.RFC3339)
		if res.GracePeriodExpiry != wantExpiry {
			t.Errorf("expected GracePeriodExpiry %q, got %q", wantExpiry, res.GracePeriodExpiry)
		}

		wantRemaining := 62.0
		if res.RemainingHours != wantRemaining {
			t.Errorf("expected RemainingHours %v, got %v", wantRemaining, res.RemainingHours)
		}
	})

	t.Run("non-compliant agent with zero grace period transitions immediately to non-compliant", func(t *testing.T) {
		piiAgent := &AgentProfile{
			ID:              "agent-llm-classifier",
			Type:            "llm-inference",
			RiskClass:       "high",
			DataSensitivity: "customer-pii",
		}

		detectedAt := baseTime
		now := detectedAt // evaluated immediately upon detection

		res := evaluator.EvaluateState(piiAgent, false, detectedAt, now)
		if res.State != AgentStateNonCompliant {
			t.Fatalf("expected state %q for 0h grace period, got %q", AgentStateNonCompliant, res.State)
		}
		if res.InGracePeriod {
			t.Errorf("0h grace period workload should not be InGracePeriod")
		}
		if !res.IsExpired {
			t.Errorf("0h grace period workload should be IsExpired true")
		}
		if res.GracePeriod != 0 {
			t.Errorf("expected GracePeriod 0, got %v", res.GracePeriod)
		}
		if res.RemainingHours != 0 {
			t.Errorf("expected RemainingHours 0, got %v", res.RemainingHours)
		}
	})

	t.Run("non-compliant agent after grace period elapses transitions to non-compliant", func(t *testing.T) {
		batchAgent := &AgentProfile{
			ID:              "agent-txn-pipeline",
			Type:            "data-pipeline",
			RiskClass:       "medium",
			DataSensitivity: "transaction",
		}

		detectedAt := baseTime
		// Evaluated 73 hours after non-compliance (past 72h grace period)
		now := detectedAt.Add(73 * time.Hour)

		res := evaluator.EvaluateState(batchAgent, false, detectedAt, now)
		if res.State != AgentStateNonCompliant {
			t.Fatalf("expected state %q after expiry, got %q", AgentStateNonCompliant, res.State)
		}
		if res.InGracePeriod {
			t.Errorf("expired workload should not be InGracePeriod")
		}
		if !res.IsExpired {
			t.Errorf("expired workload should be IsExpired true")
		}
		if res.RemainingHours != 0 {
			t.Errorf("expected RemainingHours 0 after expiry, got %v", res.RemainingHours)
		}
	})

	t.Run("boundary condition at exact grace period expiry", func(t *testing.T) {
		batchAgent := &AgentProfile{
			ID:        "agent-txn-pipeline",
			Type:      "data-pipeline",
			RiskClass: "medium",
		}

		detectedAt := baseTime
		exactExpiry := detectedAt.Add(72 * time.Hour)

		res := evaluator.EvaluateState(batchAgent, false, detectedAt, exactExpiry)
		if res.State != AgentStateNonCompliant {
			t.Fatalf("expected non-compliant at exact expiry, got %q", res.State)
		}
		if res.InGracePeriod {
			t.Errorf("should not be in grace period at exact expiry")
		}
	})
}

func TestGracePeriod_ApplyEvaluation(t *testing.T) {
	evaluator := NewGracePeriodEvaluator()
	baseTime := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)

	agent := &AgentProfile{
		ID:        "agent-txn-pipeline",
		Type:      "data-pipeline",
		RiskClass: "medium",
		State:     AgentStateActive,
	}

	// Apply non-compliant evaluation within grace period
	now := baseTime.Add(12 * time.Hour)
	res := evaluator.ApplyEvaluation(agent, false, baseTime, now)

	if agent.State != AgentStateGracePeriod {
		t.Errorf("ApplyEvaluation failed to set agent.State to %q, got %q", AgentStateGracePeriod, agent.State)
	}
	if agent.RemainingHours != 60.0 {
		t.Errorf("expected RemainingHours 60.0, got %v", agent.RemainingHours)
	}
	wantExpiry := baseTime.Add(72 * time.Hour).Format(time.RFC3339)
	if agent.GracePeriodExpiry != wantExpiry {
		t.Errorf("expected GracePeriodExpiry %q, got %q", wantExpiry, agent.GracePeriodExpiry)
	}
	if res.State != AgentStateGracePeriod {
		t.Errorf("result state mismatch: %q", res.State)
	}

	// Apply compliant evaluation
	evaluator.ApplyEvaluation(agent, true, baseTime, now)
	if agent.State != AgentStateActive {
		t.Errorf("expected agent.State active after compliant evaluation, got %q", agent.State)
	}
}

func TestGracePeriod_DAGIntegration(t *testing.T) {
	dag, err := BuildDAG([]Agent{
		{
			ID:              "agent-txn-pipeline",
			Name:            "Transaction Pipeline",
			Type:            "data-pipeline",
			Team:            "payments",
			TrustProfile:    "medium",
			RiskClass:       "medium",
			DataSensitivity: "transaction",
		},
		{
			ID:              "agent-llm-classifier",
			Name:            "LLM Classifier",
			Type:            "llm-inference",
			Team:            "ml-ops",
			TrustProfile:    "high",
			RiskClass:       "high",
			DataSensitivity: "customer-pii",
		},
	})
	if err != nil {
		t.Fatalf("failed to build test DAG: %v", err)
	}

	baseTime := time.Date(2026, 10, 8, 10, 0, 0, 0, time.UTC)

	// Set batch agent non-compliant at baseTime, evaluated at baseTime + 2h
	err = dag.SetAgentCompliance("agent-txn-pipeline", false, baseTime, baseTime.Add(2*time.Hour))
	if err != nil {
		t.Fatalf("SetAgentCompliance failed: %v", err)
	}

	txnAgent := dag.GetAgent("agent-txn-pipeline")
	if txnAgent.State != AgentStateGracePeriod {
		t.Errorf("expected txn-pipeline in %q, got %q", AgentStateGracePeriod, txnAgent.State)
	}
	if txnAgent.GracePeriodExpiry == "" {
		t.Errorf("expected non-empty GracePeriodExpiry")
	}
	if txnAgent.RemainingHours != 70.0 {
		t.Errorf("expected RemainingHours 70.0, got %v", txnAgent.RemainingHours)
	}

	// Set PII agent non-compliant -> immediate 0h enforcement
	err = dag.SetAgentCompliance("agent-llm-classifier", false, baseTime, baseTime)
	if err != nil {
		t.Fatalf("SetAgentCompliance failed on PII agent: %v", err)
	}

	llmAgent := dag.GetAgent("agent-llm-classifier")
	if llmAgent.State != AgentStateNonCompliant {
		t.Errorf("expected llm-classifier in %q, got %q", AgentStateNonCompliant, llmAgent.State)
	}
	if llmAgent.RemainingHours != 0 {
		t.Errorf("expected RemainingHours 0 on PII agent, got %v", llmAgent.RemainingHours)
	}
}

func TestTopology_GracePeriodExposedInAPI(t *testing.T) {
	s := newTestServer(t)

	// Set agent-txn-pipeline to grace-period state
	err := s.dag.SetAgentState("agent-txn-pipeline", AgentStateGracePeriod)
	if err != nil {
		t.Fatalf("SetAgentState failed: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/fleet/topology", nil)
	w := httptest.NewRecorder()
	s.handleTopology(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from /api/v1/fleet/topology, got %d", w.Code)
	}

	var resp struct {
		Agents []struct {
			ID                string  `json:"id"`
			State             string  `json:"state"`
			GracePeriod       string  `json:"gracePeriod"`
			GracePeriodExpiry string  `json:"gracePeriodExpiry"`
			RemainingHours    float64 `json:"remainingHours"`
		} `json:"agents"`
	}

	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode topology response: %v", err)
	}

	var foundTxn bool
	for _, a := range resp.Agents {
		if a.ID == "agent-txn-pipeline" {
			foundTxn = true
			if a.State != AgentStateGracePeriod {
				t.Errorf("expected state %q, got %q", AgentStateGracePeriod, a.State)
			}
			if a.GracePeriodExpiry == "" {
				t.Errorf("expected non-empty gracePeriodExpiry for agent in grace-period")
			}
			if a.RemainingHours <= 0 {
				t.Errorf("expected remainingHours > 0 for agent in grace-period, got %v", a.RemainingHours)
			}
			// Verify RFC3339 format of expiry
			if _, err := time.Parse(time.RFC3339, a.GracePeriodExpiry); err != nil {
				t.Errorf("gracePeriodExpiry is not valid RFC3339: %v", err)
			}
		}
	}

	if !foundTxn {
		t.Fatalf("agent-txn-pipeline not found in topology response")
	}
}
