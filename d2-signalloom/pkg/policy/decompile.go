package policy

import (
	"encoding/json"
	"fmt"
	"sort"
)

// Bidirectional decompilation.
//
// Round-tripping a policy compiler is how you find out whether the emitted
// artefacts still carry the whole semantic content of the manifest, or whether
// a generator has quietly started dropping something. The fixpoint property
// asserted by the tests is:
//
//	Compile(Decompile(Compile(m))) == Compile(m)   -- byte for byte
//
// Note what is deliberately NOT claimed. Decompile(Compile(m)) != m in general,
// because titles, descriptions, severities and per-invariant grouping are prose
// that the artefacts do not carry. Claiming full source round-tripping would be
// a lie that the first non-trivial manifest would expose; claiming a semantic
// fixpoint is both true and the property that actually matters.

// DecompileSource holds the artefacts to reverse.
type DecompileSource struct {
	Bundles []VAPBundle
	Profile *NonoProfile
}

// decompiledInvariantID is the single synthetic invariant the decompiler emits.
// Original invariant grouping is not recoverable from the artefacts, so the
// decompiler says so in the id rather than inventing plausible groupings.
const decompiledInvariantID = "DECOMPILED-000"

// Decompile reconstructs the semantic core of an InvariantSet from generated
// artefacts.
//
// The nono profile is the primary source: it carries the access lattice
// losslessly, one list per level. The VAP bundles contribute the tier targeting,
// since a rule that produced a VAP validation must have targeted vap.
func Decompile(src DecompileSource, meta Metadata, def Defaults) (*InvariantSet, error) {
	if src.Profile == nil {
		return nil, fmt.Errorf("decompile: a nono profile is required; the VAP artefacts alone do not carry the access lattice")
	}

	vapDomains := map[Domain]bool{}
	for _, b := range src.Bundles {
		vapDomains[b.Domain] = true
	}

	fsTargets := []Target{TargetLandlock}
	if vapDomains[DomainFilesystem] {
		fsTargets = []Target{TargetLandlock, TargetVAP}
	}
	netTargets := []Target{TargetLandlock}
	if vapDomains[DomainNetwork] {
		netTargets = []Target{TargetLandlock, TargetVAP}
	}
	procTargets := []Target{TargetLandlock}
	if vapDomains[DomainProcess] {
		procTargets = []Target{TargetLandlock, TargetVAP}
	}

	inv := Invariant{
		ID:       decompiledInvariantID,
		Title:    "Decompiled security invariants",
		Severity: SeverityHigh,
		Description: "Reconstructed from generated artefacts by policy-compiler. Invariant " +
			"grouping, titles and severities are not carried by the artefacts and are not recoverable; " +
			"this set is a semantic equivalent of the original, not a source-level copy.",
	}

	add := func(paths []string, a Access) {
		for _, p := range paths {
			inv.Filesystem = append(inv.Filesystem, FilesystemRule{Path: p, Access: a})
		}
	}
	add(src.Profile.Filesystem.Allow, AccessReadWrite)
	add(src.Profile.Filesystem.Read, AccessRead)
	add(src.Profile.Filesystem.Write, AccessWrite)
	add(src.Profile.Filesystem.Deny, AccessNone)
	sort.Slice(inv.Filesystem, func(i, j int) bool { return inv.Filesystem[i].Path < inv.Filesystem[j].Path })

	for _, d := range src.Profile.Network.DenyDomain {
		inv.Network = append(inv.Network, NetworkRule{Domain: d, Action: ActionDeny, Direction: DirectionConnect})
	}
	for _, d := range src.Profile.Network.AllowDomain {
		inv.Network = append(inv.Network, NetworkRule{Domain: d, Action: ActionAllow, Direction: DirectionConnect})
	}
	for _, p := range src.Profile.Network.ConnectPort {
		inv.Network = append(inv.Network, NetworkRule{Port: p, Action: ActionAllow, Direction: DirectionConnect})
	}
	for _, p := range src.Profile.Network.ListenPort {
		inv.Network = append(inv.Network, NetworkRule{Port: p, Action: ActionAllow, Direction: DirectionListen})
	}
	for _, c := range src.Profile.Commands.Deny {
		inv.Process = append(inv.Process, ProcessRule{Binary: "/usr/bin/" + c, Action: ActionDeny})
	}
	for _, c := range src.Profile.Commands.Allow {
		inv.Process = append(inv.Process, ProcessRule{Binary: "/usr/bin/" + c, Action: ActionAllow})
	}

	// Every rule in one synthetic invariant needs one target list, so the
	// decompiled set splits by domain into up to three invariants when the tier
	// targeting differs between domains.
	set := &InvariantSet{APIVersion: APIVersion, Kind: Kind, Metadata: meta, Defaults: def}

	if len(inv.Filesystem) > 0 {
		fs := inv
		fs.ID = decompiledInvariantID + "-FS"
		fs.Targets = fsTargets
		fs.Network, fs.Process = nil, nil
		set.Invariants = append(set.Invariants, fs)
	}
	if len(inv.Network) > 0 {
		nw := inv
		nw.ID = decompiledInvariantID + "-NET"
		nw.Targets = netTargets
		nw.Filesystem, nw.Process = nil, nil
		set.Invariants = append(set.Invariants, nw)
	}
	if len(inv.Process) > 0 {
		pr := inv
		pr.ID = decompiledInvariantID + "-PROC"
		pr.Targets = procTargets
		pr.Filesystem, pr.Network = nil, nil
		set.Invariants = append(set.Invariants, pr)
	}

	if err := set.Validate(); err != nil {
		return nil, fmt.Errorf("decompiled set is not valid: %w", err)
	}
	return set, nil
}

// InputJSONSchema returns a JSON Schema describing the invariant manifest.
//
// It is hand-written rather than reflected, because the schema is a contract
// with manifest authors and editors; deriving it from struct tags would make an
// unrelated refactor silently change what authors are allowed to write.
func InputJSONSchema() []byte {
	strArray := map[string]any{"type": "array", "items": map[string]any{"type": "string"}}

	schema := map[string]any{
		"$schema":              "https://json-schema.org/draft/2020-12/schema",
		"$id":                  "https://signalloom.io/schemas/security-invariants.v1alpha1.json",
		"title":                "Signal Loom Security Invariants",
		"description":          "Canonical declarative security invariants compiled by policy-compiler into Kubernetes ValidatingAdmissionPolicy CEL and nono Landlock profiles.",
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"apiVersion", "kind", "metadata", "invariants"},
		"properties": map[string]any{
			"apiVersion": map[string]any{"const": APIVersion},
			"kind":       map[string]any{"const": Kind},
			"metadata": map[string]any{
				"type": "object", "additionalProperties": false,
				"required": []string{"name", "version"},
				"properties": map[string]any{
					"name":        map[string]any{"type": "string", "minLength": 1},
					"version":     map[string]any{"type": "string", "minLength": 1},
					"description": map[string]any{"type": "string"},
				},
			},
			"defaults": map[string]any{
				"type": "object", "additionalProperties": false,
				"properties": map[string]any{
					"maxPathDepth":          map[string]any{"type": "integer", "minimum": 1},
					"maxExprDepth":          map[string]any{"type": "integer", "minimum": 1},
					"maxExprNodes":          map[string]any{"type": "integer", "minimum": 1},
					"maxComprehensionDepth": map[string]any{"type": "integer", "minimum": 1},
					"landlockAbi":           map[string]any{"type": "integer", "minimum": 1},
					"failurePolicy":         map[string]any{"enum": []string{"Fail", "Ignore"}},
				},
			},
			"invariants": map[string]any{
				"type": "array", "minItems": 1,
				"items": map[string]any{
					"type": "object", "additionalProperties": false,
					"required": []string{"id", "title", "severity", "targets"},
					"properties": map[string]any{
						"id":          map[string]any{"type": "string", "minLength": 1},
						"title":       map[string]any{"type": "string", "minLength": 1},
						"description": map[string]any{"type": "string"},
						"severity":    map[string]any{"enum": []string{"critical", "high", "medium", "low"}},
						"targets": map[string]any{
							"type": "array", "minItems": 1,
							"items": map[string]any{"enum": []string{"vap", "landlock"}},
						},
						"filesystem": map[string]any{
							"type": "array",
							"items": map[string]any{
								"type": "object", "additionalProperties": false,
								"required": []string{"path", "access"},
								"properties": map[string]any{
									"path":   map[string]any{"type": "string", "pattern": "^/"},
									"access": map[string]any{"enum": []string{"none", "read", "write", "readwrite"}},
									"note":   map[string]any{"type": "string"},
								},
							},
						},
						"process": map[string]any{
							"type": "array",
							"items": map[string]any{
								"type": "object", "additionalProperties": false,
								"required": []string{"binary", "action"},
								"properties": map[string]any{
									"binary":     map[string]any{"type": "string", "pattern": "^/"},
									"action":     map[string]any{"enum": []string{"allow", "deny"}},
									"deniedArgs": strArray,
									"note":       map[string]any{"type": "string"},
								},
							},
						},
						"network": map[string]any{
							"type": "array",
							"items": map[string]any{
								"type": "object", "additionalProperties": false,
								"required": []string{"action"},
								"properties": map[string]any{
									"domain":    map[string]any{"type": "string"},
									"port":      map[string]any{"type": "integer", "minimum": 0, "maximum": 65535},
									"action":    map[string]any{"enum": []string{"allow", "deny"}},
									"direction": map[string]any{"enum": []string{"connect", "listen"}},
									"note":      map[string]any{"type": "string"},
								},
							},
						},
					},
				},
			},
		},
	}

	out, err := json.MarshalIndent(schema, "", "  ")
	if err != nil {
		panic(fmt.Sprintf("input json schema: %v", err))
	}
	return append(out, '\n')
}
