package frameworks

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"strings"
)

// BuiltinFS embeds the canonical framework definitions.
//
//go:embed builtin/*/*/framework.json
var BuiltinFS embed.FS

// ListEmbeddedFrameworks returns the framework IDs and versions available in BuiltinFS.
func ListEmbeddedFrameworks() (map[string][]string, error) {
	sub, err := fs.Sub(BuiltinFS, "builtin")
	if err != nil {
		return nil, fmt.Errorf("accessing embedded frameworks: %w", err)
	}
	return ListFromFS(sub)
}

// LoadEmbeddedFramework loads a framework definition from BuiltinFS.
func LoadEmbeddedFramework(frameworkID, version string) (*Framework, error) {
	if frameworkID == "k8s-cis-benchmark" {
		frameworkID = "cis-kubernetes"
	}
	sub, err := fs.Sub(BuiltinFS, "builtin")
	if err != nil {
		return nil, fmt.Errorf("accessing embedded frameworks: %w", err)
	}
	return LoadFromFS(sub, frameworkID, version)
}

// LoadEmbeddedFrameworks loads all canonical framework definitions from BuiltinFS.
func LoadEmbeddedFrameworks() ([]*Framework, error) {
	sub, err := fs.Sub(BuiltinFS, "builtin")
	if err != nil {
		return nil, fmt.Errorf("accessing embedded frameworks: %w", err)
	}
	available, err := ListFromFS(sub)
	if err != nil {
		return nil, fmt.Errorf("listing embedded frameworks: %w", err)
	}

	var fws []*Framework
	for fwID, versions := range available {
		for _, ver := range versions {
			fw, err := LoadFromFS(sub, fwID, ver)
			if err != nil {
				return nil, fmt.Errorf("loading embedded framework %s/%s: %w", fwID, ver, err)
			}
			fws = append(fws, fw)
		}
	}
	return fws, nil
}

// LoadFromFS reads a framework definition from a filesystem rooted at frameworks directory:
// <frameworkID>/<version>/framework.json (or framework.yaml).
func LoadFromFS(sys fs.FS, frameworkID, version string) (*Framework, error) {
	if frameworkID == "k8s-cis-benchmark" {
		frameworkID = "cis-kubernetes"
	}
	dir := frameworkID + "/" + version

	var (
		fw   Framework
		name string
		err  error
	)
	for _, name = range []string{"framework.json", "framework.yaml"} {
		var data []byte
		data, err = fs.ReadFile(sys, dir+"/"+name)
		if err != nil {
			if name == "framework.json" && errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return nil, fmt.Errorf("loading framework %s/%s/%s: %w", frameworkID, version, name, err)
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

// ListFromFS returns available framework IDs and versions from an fs.FS.
func ListFromFS(sys fs.FS) (map[string][]string, error) {
	entries, err := fs.ReadDir(sys, ".")
	if err != nil {
		return nil, fmt.Errorf("listing frameworks: %w", err)
	}

	result := make(map[string][]string)
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		fwID := e.Name()
		versions, err := fs.ReadDir(sys, fwID)
		if err != nil {
			continue
		}
		for _, v := range versions {
			if !v.IsDir() || strings.HasPrefix(v.Name(), ".") {
				continue
			}
			vDir := fwID + "/" + v.Name()
			if _, err := fs.Stat(sys, vDir+"/framework.json"); err == nil {
				result[fwID] = append(result[fwID], v.Name())
			} else if _, err := fs.Stat(sys, vDir+"/framework.yaml"); err == nil {
				result[fwID] = append(result[fwID], v.Name())
			}
		}
	}
	return result, nil
}
