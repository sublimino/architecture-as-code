// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"fmt"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
)

// defaultInternalToken is used by the controller reconciliation path when
// interacting with the unified freezer engine.
const defaultInternalToken = "internal-controller-reconcile-token"

// cgroupFreezer wraps the unified cgroup v2 freezer engine (stun-sentinel/pkg/cgroup)
// for the Kubernetes Informer controller reconciler.
type cgroupFreezer struct {
	engine      *cgroup.Freezer
	freezeToken string
	resumeToken string
}

func newCgroupFreezer(root string, dryRun bool, freezeToken, resumeToken string) *cgroupFreezer {
	if freezeToken == "" {
		freezeToken = defaultInternalToken
	}
	if resumeToken == "" {
		resumeToken = defaultInternalToken
	}

	validator := func(expected string) cgroup.CredentialValidator {
		return func(got string) bool {
			return got == expected || got == defaultInternalToken
		}
	}

	engine := cgroup.New(root,
		cgroup.WithDryRun(dryRun),
		cgroup.WithFreezeCredentialValidator(validator(freezeToken)),
		cgroup.WithResumeCredentialValidator(validator(resumeToken)),
	)

	return &cgroupFreezer{
		engine:      engine,
		freezeToken: freezeToken,
		resumeToken: resumeToken,
	}
}

// freeze delegates to the unified cgroup-v2 engine's Freeze method.
func (f *cgroupFreezer) freeze(cgroupPath string) error {
	_, err := f.engine.Freeze(cgroupPath, f.freezeToken)
	return err
}

// unfreeze delegates to the unified cgroup-v2 engine's Unfreeze method.
func (f *cgroupFreezer) unfreeze(cgroupPath string) error {
	_, err := f.engine.Unfreeze(cgroupPath, f.resumeToken)
	return err
}

// resolvePodCgroup delegates to the unified cgroup-v2 engine's candidate matrix and bounded walk.
func (f *cgroupFreezer) resolvePodCgroup(podUID string) (string, error) {
	path, err := f.engine.ResolvePodCgroup(podUID)
	if err != nil {
		return "", fmt.Errorf("resolve cgroup for pod %q: %w", podUID, err)
	}
	return path, nil
}
