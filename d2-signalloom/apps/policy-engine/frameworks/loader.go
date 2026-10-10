package frameworks

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Load reads a framework definition from policyRoot/frameworks/<frameworkID>/<version>/.
// framework.json wins; framework.yaml is read only when no framework.json exists.
//
// Both files must use the canonical shape (see types.go): an unknown key is an
// error, not a silently dropped field, and every check must carry an id and a
// non-empty celExpression. A pack either loads whole and evaluable or does not
// load at all.
func Load(policyRoot, frameworkID, version string) (*Framework, error) {
	dir := filepath.Join(policyRoot, "frameworks", frameworkID, version)

	var (
		fw   Framework
		name string
		err  error
	)
	for _, name = range []string{"framework.json", "framework.yaml"} {
		var data []byte
		data, err = os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		if name == "framework.json" {
			err = decodeJSON(data, &fw)
		} else {
			err = decodeYAML(data, &fw)
		}
		if err != nil {
			return nil, fmt.Errorf("parsing framework %s/%s/%s: %w", frameworkID, version, name, err)
		}
		break
	}
	if err != nil {
		return nil, fmt.Errorf("loading framework %s/%s: %w", frameworkID, version, err)
	}

	if err := validate(&fw); err != nil {
		return nil, fmt.Errorf("framework %s/%s/%s: %w", frameworkID, version, name, err)
	}

	if fw.ID == "" {
		fw.ID = frameworkID
	}
	if fw.Version == "" {
		fw.Version = version
	}

	return &fw, nil
}

func decodeJSON(data []byte, fw *Framework) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(fw); err != nil {
		return err
	}
	if dec.More() {
		return fmt.Errorf("trailing data after the framework object")
	}
	return nil
}

func decodeYAML(data []byte, fw *Framework) error {
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	return dec.Decode(fw)
}

// validate rejects a pack that would evaluate checks it cannot run: a check
// with no id cannot be reported, a duplicate id shadows another check's
// result, and an empty expression can only ever error.
func validate(fw *Framework) error {
	seen := map[string]string{}
	for _, cs := range fw.ControlSets {
		for _, ctrl := range cs.Controls {
			for i, chk := range ctrl.Checks {
				if strings.TrimSpace(chk.ID) == "" {
					return fmt.Errorf("control %q check #%d has no id", ctrl.ID, i)
				}
				if prev, dup := seen[chk.ID]; dup {
					return fmt.Errorf("duplicate check id %q in controls %q and %q", chk.ID, prev, ctrl.ID)
				}
				seen[chk.ID] = ctrl.ID
				if strings.TrimSpace(chk.CELExpression) == "" {
					return fmt.Errorf("control %q check %q has empty celExpression", ctrl.ID, chk.ID)
				}
			}
		}
	}
	return nil
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
