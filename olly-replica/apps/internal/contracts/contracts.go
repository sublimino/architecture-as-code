// Package contracts loads and enforces the versioned JSON Schemas every
// component imports. The schemas are baked into each image at /contracts.
// A payload that fails validation is dropped and counted.
package contracts

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/santhosh-tekuri/jsonschema/v5"
)

const (
	EligibleEvent    = "eligible-event.v1.schema.json"
	RcaEnrichment    = "rca-enrichment.v1.schema.json"
	PipelineDecision = "pipeline-decision.v1.schema.json"
)

// Dir returns the contracts directory (CONTRACTS_DIR, default /contracts).
func Dir() string {
	if d := os.Getenv("CONTRACTS_DIR"); d != "" {
		return d
	}
	return "/contracts"
}

// Load compiles one schema by file name.
func Load(name string) (*jsonschema.Schema, error) {
	path := filepath.Join(Dir(), name)
	compiler := jsonschema.NewCompiler()
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open schema %s: %w", path, err)
	}
	defer f.Close()
	if err := compiler.AddResource(path, f); err != nil {
		return nil, fmt.Errorf("add schema %s: %w", path, err)
	}
	return compiler.Compile(path)
}

// ValidateJSON validates raw JSON bytes against a compiled schema.
func ValidateJSON(schema *jsonschema.Schema, raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return fmt.Errorf("not valid JSON: %w", err)
	}
	return schema.Validate(doc)
}
