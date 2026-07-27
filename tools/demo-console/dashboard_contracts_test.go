package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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

func TestDashboardAPIInventoryDocumentsFixtureEndpoints(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "dashboard-api-contracts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var contracts []dashboardContract
	if err := json.Unmarshal(raw, &contracts); err != nil {
		t.Fatal(err)
	}
	document, err := os.ReadFile(filepath.Join("..", "..", "docs", "signalloom", "api-contract-inventory.md"))
	if err != nil {
		t.Fatal(err)
	}
	content := string(document)
	if !strings.Contains(content, "Estate95 plain-JavaScript client") {
		t.Fatal("inventory must state the effective dashboard implementation")
	}
	for _, contract := range contracts {
		if !strings.HasPrefix(contract.Path, "/api/") || strings.ContainsAny(contract.Path, "[") {
			continue
		}
		rowPrefix := "| `" + contract.Method + "` | `" + contract.Path + "` |"
		if !strings.Contains(content, rowPrefix) {
			t.Fatalf("inventory missing fixture endpoint %s %s", contract.Method, contract.Path)
		}
	}
}

func TestDashboardAPIInventoryRowsDeclareRequiredContractFields(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "dashboard-api-contracts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var contracts []dashboardContract
	if err := json.Unmarshal(raw, &contracts); err != nil {
		t.Fatal(err)
	}
	document, err := os.ReadFile(filepath.Join("..", "..", "docs", "signalloom", "api-contract-inventory.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, contract := range contracts {
		if !strings.HasPrefix(contract.Path, "/api/") || strings.ContainsAny(contract.Path, "[") {
			continue
		}
		rowPrefix := "| `" + contract.Method + "` | `" + contract.Path + "` |"
		found := false
		for _, line := range strings.Split(string(document), "\n") {
			if !strings.HasPrefix(line, rowPrefix) {
				continue
			}
			found = true
			cells := strings.Split(line, "|")
			if len(cells) != 10 {
				t.Fatalf("inventory row has unexpected column count: %q", line)
			}
			for index, field := range cells[3:9] {
				if strings.TrimSpace(field) == "" {
					t.Fatalf("inventory row misses required contract field %d: %q", index+1, line)
				}
			}
			break
		}
		if !found {
			t.Fatalf("inventory missing fixture endpoint %s %s", contract.Method, contract.Path)
		}
	}
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
