package a2a

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestClient_DiscoverCard(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(AgentCard{
			Name:        "test-agent",
			Description: "A test agent",
			Version:     "1.0.0",
		})
	})

	server := httptest.NewServer(mux)
	defer server.Close()

	client := NewClient()
	card, err := client.DiscoverCard(context.Background(), server.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if card.Name != "test-agent" {
		t.Errorf("expected test-agent, got %s", card.Name)
	}
	if card.URL != server.URL {
		t.Errorf("expected URL to default to %s, got %s", server.URL, card.URL)
	}
}

func TestClient_DiscoverCard_Non200(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})

	server := httptest.NewServer(mux)
	defer server.Close()

	client := NewClient()
	_, err := client.DiscoverCard(context.Background(), server.URL)
	if err == nil {
		t.Fatal("expected error on 404, got nil")
	}
	if !strings.Contains(err.Error(), "status 404") {
		t.Errorf("expected status 404 in error, got: %v", err)
	}
}

func TestClient_SendTask_HTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("internal server error"))
	}))
	defer server.Close()

	client := NewClient()
	_, err := client.SendTask(context.Background(), server.URL, Task{ID: "task-1"})
	if err == nil {
		t.Fatal("expected error on 500, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP status 500") {
		t.Errorf("expected HTTP status 500 in error, got: %v", err)
	}
}

func TestClient_GetTask_HTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("bad gateway"))
	}))
	defer server.Close()

	client := NewClient()
	_, err := client.GetTask(context.Background(), server.URL, "task-1")
	if err == nil {
		t.Fatal("expected error on 502, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP status 502") {
		t.Errorf("expected HTTP status 502 in error, got: %v", err)
	}
}

func TestClient_SendTask_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := JSONRPCResponse{
			JSONRPC: "2.0",
			ID:      "task-1",
			Result: TaskResult{
				TaskID: "task-1",
				Status: "completed",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient()
	res, err := client.SendTask(context.Background(), server.URL, Task{ID: "task-1"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Status != "completed" {
		t.Errorf("expected completed, got %s", res.Status)
	}
}
