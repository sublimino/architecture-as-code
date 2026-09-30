// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package correlator

import (
	"errors"
	"testing"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup"
)

func TestFreezeManagerPresentsItsConfiguredCredential(t *testing.T) {
	f := cgroup.New(t.TempDir(), cgroup.WithDryRun(true),
		cgroup.WithFreezeCredentialValidator(func(c string) bool { return c == "freeze-secret" }))
	if err := NewFreezeManager(f, "freeze-secret").FreezePod(agentPod("tenant-kusari")); err != nil {
		t.Fatalf("freeze with the configured credential: %v", err)
	}
	err := NewFreezeManager(f, "wrong").FreezePod(agentPod("tenant-kusari"))
	if !errors.Is(err, cgroup.ErrUnauthorized) {
		t.Fatalf("freeze with a wrong credential: err = %v, want ErrUnauthorized", err)
	}
}
