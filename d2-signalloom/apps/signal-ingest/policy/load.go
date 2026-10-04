// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package policy

import (
	"fmt"
	"log/slog"
	"os"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/pkg/obscel"
)

// BundlesDirEnv names the boot-loaded bundle tree (D6). Bundles are
// Flux-reconciled files, not API registrations.
const BundlesDirEnv = "POLICY_BUNDLES_DIR"

// DefaultBundlesDir is the ConfigMap mount point, matching
// apps/policy-engine/base/deployment.yaml so both apps read the same path from
// the same object.
const DefaultBundlesDir = "/etc/policy-engine/bundles"

// BundlesDirFromEnv returns the configured bundle directory.
func BundlesDirFromEnv() string {
	if dir := os.Getenv(BundlesDirEnv); dir != "" {
		return dir
	}
	return DefaultBundlesDir
}

// LoadBundles loads and conforms every bundle under dir (ISC-51).
//
// The asymmetry here is deliberate and is the whole of the fail-open/fail-closed
// decision for this card:
//
//   - A MISSING directory is zero bundles and a WARNING, not an error. Every
//     deployment predates this feature, and no estate has shipped a bundle yet;
//     refusing to boot without one would turn a new detection control into an
//     estate-wide outage of the ingest path.
//   - A directory that exists but cannot be read, or ANY bundle that fails to
//     parse, validate or conform, IS an error. That is a broken deployment
//     rather than an empty one, and a half-loaded policy set is
//     indistinguishable at runtime from a policy set that chose not to detect
//     anything. obscel.LoadBundleDir already enforces this; this function keeps
//     the distinction visible at the call site.
//
// What is NOT permitted is booting with zero bundles silently. The warning names
// the directory, so "we deployed policy and nothing fired" has an answer in the
// log rather than requiring a bisect.
func LoadBundles(dir string, log *slog.Logger) ([]*obscel.Bundle, error) {
	if log == nil {
		log = slog.Default()
	}
	if dir == "" {
		log.Warn("no observation-policy bundle directory configured; stage 1 will evaluate nothing",
			"env", BundlesDirEnv)
		return nil, nil
	}

	if _, err := os.Stat(dir); err != nil {
		if os.IsNotExist(err) {
			log.Warn("observation-policy bundle directory does not exist; stage 1 will evaluate nothing",
				"dir", dir, "env", BundlesDirEnv,
				"consequence", "no finding and no decision will be produced by any collector")
			return nil, nil
		}
		return nil, fmt.Errorf("policy: stat bundle dir %s: %w", dir, err)
	}

	bundles, err := obscel.LoadBundleDir(dir)
	if err != nil {
		return nil, fmt.Errorf("policy: loading bundles from %s: %w", dir, err)
	}
	if len(bundles) == 0 {
		log.Warn("observation-policy bundle directory is empty; stage 1 will evaluate nothing",
			"dir", dir, "env", BundlesDirEnv)
		return nil, nil
	}

	for _, b := range bundles {
		log.Info("observation-policy bundle loaded",
			"bundle", b.ID, "tenant", b.TenantID, "version", b.Version,
			"mode", string(b.Mode), "rules", len(b.Rules), "windows", len(b.Windows))
	}
	return bundles, nil
}
