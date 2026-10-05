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

// newCgroupFreezer builds the freezer the reconciler and the correlator share.
//
// extra is appended AFTER the defaults, so a caller can override one of them
// without restating the rest and without changing any default. Production
// (main.go) passes none. The only current use is the test harness raising
// cgroup.WithDeadline: its fake kernel mirrors cgroup.freeze into cgroup.events
// from a polling goroutine, and on a loaded host that goroutine is not
// scheduled inside the 50ms DefaultFreezeDeadline, so the freeze is reported as
// ErrFreezeDeadline for a scheduling reason rather than a product one.
func newCgroupFreezer(root string, dryRun bool, freezeToken, resumeToken string, extra ...cgroup.Option) *cgroupFreezer {
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

	opts := []cgroup.Option{
		cgroup.WithDryRun(dryRun),
		cgroup.WithFreezeCredentialValidator(validator(freezeToken)),
		cgroup.WithResumeCredentialValidator(validator(resumeToken)),
	}
	opts = append(opts, extra...)
	engine := cgroup.New(root, opts...)

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
