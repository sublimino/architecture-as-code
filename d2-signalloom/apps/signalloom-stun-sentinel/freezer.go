package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// cgroupFreezer manages cgroup2 freeze/unfreeze operations for pods.
type cgroupFreezer struct {
	cgroupRoot string // typically /sys/fs/cgroup
}

// freeze writes "1" to the pod's cgroup.freeze file, freezing all processes.
func (f *cgroupFreezer) freeze(cgroupPath string) error {
	return os.WriteFile(filepath.Join(cgroupPath, "cgroup.freeze"), []byte("1"), 0644)
}

// unfreeze writes "0" to the pod's cgroup.freeze file, resuming all processes.
func (f *cgroupFreezer) unfreeze(cgroupPath string) error {
	return os.WriteFile(filepath.Join(cgroupPath, "cgroup.freeze"), []byte("0"), 0644)
}

// resolvePodCgroup finds the cgroup path for a pod UID under the cgroup root.
// Kubernetes places pods under kubepods/{qos-class}/pod-{uid} or kubepods/pod-{uid}.
func (f *cgroupFreezer) resolvePodCgroup(podUID string) (string, error) {
	// Normalise: Kubernetes uses underscores in cgroup paths for UIDs with hyphens.
	// The cgroup directory is named "pod-{uid}" or "pod{uid}" depending on the
	// container runtime. We normalise both sides for matching.
	sanitised := strings.ReplaceAll(podUID, "-", "_")
	podPrefixDash := "pod_" + sanitised  // matches "pod-{uid}" after normalisation
	podPrefixPlain := "pod" + sanitised   // matches "pod{uid}" after normalisation

	// Search order: guaranteed (kubepods/pod-*), burstable, besteffort.
	searchDirs := []string{
		filepath.Join(f.cgroupRoot, "kubepods"),
		filepath.Join(f.cgroupRoot, "kubepods", "burstable"),
		filepath.Join(f.cgroupRoot, "kubepods", "besteffort"),
	}

	for _, dir := range searchDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			name := entry.Name()
			// Match pod-{uid} with both hyphenated and underscored forms.
			nameNorm := strings.ReplaceAll(name, "-", "_")
			if nameNorm == podPrefixDash || nameNorm == podPrefixPlain {
				candidate := filepath.Join(dir, name)
				if _, err := os.Stat(filepath.Join(candidate, "cgroup.freeze")); err == nil {
					return candidate, nil
				}
			}
		}
	}

	return "", fmt.Errorf("cgroup for pod %q not found under %s", podUID, f.cgroupRoot)
}
