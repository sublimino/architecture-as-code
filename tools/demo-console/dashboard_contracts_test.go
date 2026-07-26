package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type dashboardContract struct {
	Method   string `json:"method"`
	Path     string `json:"path"`
	Response string `json:"response"`
	Owner    string `json:"owner"`
	Location string `json:"location"`
	Gap      string `json:"gap"`
}

func TestDashboardAPIContractFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "dashboard-api-contracts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var contracts []dashboardContract
	if err := json.Unmarshal(raw, &contracts); err != nil {
		t.Fatal(err)
	}
	if len(contracts) == 0 {
		t.Fatal("dashboard contract fixture is empty")
	}
	for _, contract := range contracts {
		if contract.Method == "" || contract.Path == "" || contract.Response == "" || contract.Location == "" {
			t.Fatalf("incomplete contract fixture: %#v", contract)
		}
		switch contract.Owner {
		case "handler", "adapter", "persistence", "waiver":
		default:
			t.Fatalf("unsupported owner %q for %s %s", contract.Owner, contract.Method, contract.Path)
		}
		if contract.Owner == "waiver" && contract.Gap == "" {
			t.Fatalf("waiver lacks explicit gap: %s %s", contract.Method, contract.Path)
		}
	}
}
