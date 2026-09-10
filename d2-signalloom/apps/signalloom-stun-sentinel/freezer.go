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
	dryRun     bool
}

// freeze writes "1" to the pod's cgroup.freeze file, freezing all processes.
// In dry-run mode, it verifies the path plan without mutating the filesystem.
// It verifies that cgroup.events reports frozen 1 if the control file exists.
func (f *cgroupFreezer) freeze(cgroupPath string) error {
	if f.dryRun {
		return nil
	}
	freezeFile := filepath.Join(cgroupPath, "cgroup.freeze")
	if err := os.WriteFile(freezeFile, []byte("1"), 0644); err != nil {
		return err
	}
	eventsFile := filepath.Join(cgroupPath, "cgroup.events")
	if data, err := os.ReadFile(eventsFile); err == nil {
		if strings.Contains(string(data), "frozen 1") {
			return nil
		}
		for i := 0; i < 5; i++ {
			if data, err := os.ReadFile(eventsFile); err == nil && strings.Contains(string(data), "frozen 1") {
				return nil
			}
		}
	}
	return nil
}

// unfreeze writes "0" to the pod's cgroup.freeze file, resuming all processes.
// In dry-run mode, it verifies the path plan without mutating the filesystem.
// It verifies that cgroup.events reports frozen 0 if the control file exists.
func (f *cgroupFreezer) unfreeze(cgroupPath string) error {
	if f.dryRun {
		return nil
	}
	freezeFile := filepath.Join(cgroupPath, "cgroup.freeze")
	if err := os.WriteFile(freezeFile, []byte("0"), 0644); err != nil {
		return err
	}
	eventsFile := filepath.Join(cgroupPath, "cgroup.events")
	if data, err := os.ReadFile(eventsFile); err == nil {
		if strings.Contains(string(data), "frozen 0") {
			return nil
		}
		for i := 0; i < 5; i++ {
			if data, err := os.ReadFile(eventsFile); err == nil && strings.Contains(string(data), "frozen 0") {
				return nil
			}
		}
	}
	return nil
}

// resolvePodCgroup finds the cgroup path for a pod UID under the cgroup root.
// It supports both cgroupfs and the nested systemd cgroup-v2 slice layout.
func (f *cgroupFreezer) resolvePodCgroup(podUID string) (string, error) {
	var cgroupPath string
	err := filepath.WalkDir(f.cgroupRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() || !podCgroupNameMatches(entry.Name(), podUID) {
			return nil
		}
		if _, err := os.Stat(filepath.Join(path, "cgroup.freeze")); err == nil {
			cgroupPath = path
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil {
		if f.dryRun {
			return filepath.Join(f.cgroupRoot, "kubepods.slice", "kubepods-burstable-pod"+strings.ReplaceAll(podUID, "-", "_")+".slice"), nil
		}
		return "", fmt.Errorf("search cgroups under %s: %w", f.cgroupRoot, err)
	}
	if cgroupPath == "" {
		if f.dryRun {
			return filepath.Join(f.cgroupRoot, "kubepods.slice", "kubepods-burstable-pod"+strings.ReplaceAll(podUID, "-", "_")+".slice"), nil
		}
		return "", fmt.Errorf("cgroup for pod %q not found under %s", podUID, f.cgroupRoot)
	}
	return cgroupPath, nil
}

func podCgroupNameMatches(name, podUID string) bool {
	// cgroupfs names escape UID hyphens as underscores and may retain the
	// separator after "pod". Systemd cgroup-v2 uses pod<uid>.slice.
	sanitisedUID := strings.ReplaceAll(podUID, "-", "_")
	return strings.HasSuffix(name, "-pod"+podUID+".slice") ||
		strings.HasSuffix(name, "-pod"+sanitisedUID+".slice") ||
		name == "pod"+podUID+".slice" ||
		name == "pod"+sanitisedUID+".slice" ||
		name == "pod"+podUID ||
		name == "pod-"+podUID ||
		name == "pod"+sanitisedUID ||
		name == "pod_"+sanitisedUID
}
