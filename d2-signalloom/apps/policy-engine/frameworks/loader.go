package frameworks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Load reads a framework definition from policyRoot/frameworks/<frameworkID>/<version>/.
// It tries framework.json first (JSON format used by the compliance scanner), falling
// back to framework.yaml (which must also be valid JSON — real YAML support would
// require a third-party dependency).
func Load(policyRoot, frameworkID, version string) (*Framework, error) {
	dir := filepath.Join(policyRoot, "frameworks", frameworkID, version)

	var data []byte
	var err error

	// Prefer .json, fall back to .yaml.
	for _, name := range []string{"framework.json", "framework.yaml"} {
		data, err = os.ReadFile(filepath.Join(dir, name))
		if err == nil {
			break
		}
	}
	if err != nil {
		return nil, fmt.Errorf("loading framework %s/%s: %w", frameworkID, version, err)
	}

	var fw Framework
	if err := json.Unmarshal(data, &fw); err != nil {
		return nil, fmt.Errorf("parsing framework %s/%s: %w", frameworkID, version, err)
	}

	if fw.ID == "" {
		fw.ID = frameworkID
	}
	if fw.Version == "" {
		fw.Version = version
	}

	return &fw, nil
}

// ListFrameworks returns available framework IDs and their versions by scanning
// the policyRoot/frameworks/ directory tree.
func ListFrameworks(policyRoot string) (map[string][]string, error) {
	fwDir := filepath.Join(policyRoot, "frameworks")
	entries, err := os.ReadDir(fwDir)
	if err != nil {
		return nil, fmt.Errorf("listing frameworks: %w", err)
	}

	result := make(map[string][]string)
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		fwID := e.Name()
		versions, err := os.ReadDir(filepath.Join(fwDir, fwID))
		if err != nil {
			continue
		}
		for _, v := range versions {
			if !v.IsDir() || strings.HasPrefix(v.Name(), ".") {
				continue
			}
			// Include if framework.json or framework.yaml exists.
			vDir := filepath.Join(fwDir, fwID, v.Name())
			if _, err := os.Stat(filepath.Join(vDir, "framework.json")); err == nil {
				result[fwID] = append(result[fwID], v.Name())
			} else if _, err := os.Stat(filepath.Join(vDir, "framework.yaml")); err == nil {
				result[fwID] = append(result[fwID], v.Name())
			}
		}
	}
	return result, nil
}

// ChecksForVersion returns all checks from a framework that include the given
// policy version in their PolicyVersions list. If policyVersion is empty, all
// checks are returned.
func ChecksForVersion(fw *Framework, policyVersion string) []CheckWithContext {
	var out []CheckWithContext
	for _, cs := range fw.ControlSets {
		for _, ctrl := range cs.Controls {
			for _, chk := range ctrl.Checks {
				if policyVersion != "" && !contains(chk.PolicyVersions, policyVersion) {
					continue
				}
				out = append(out, CheckWithContext{
					Framework:  fw.ID,
					ControlSet: cs.Name,
					Control:    ctrl.Name,
					Check:      chk,
				})
			}
		}
	}
	return out
}

// CheckWithContext pairs a Check with its position in the framework hierarchy.
type CheckWithContext struct {
	Framework  string
	ControlSet string
	Control    string
	Check      Check
}

func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}
