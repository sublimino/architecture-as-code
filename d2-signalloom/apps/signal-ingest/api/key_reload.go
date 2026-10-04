package api

import (
	"context"
	"crypto/sha256"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// Static key hot-reload constants.
const (
	// DefaultStaticKeysReloadInterval is the default polling period for detecting key file changes.
	DefaultStaticKeysReloadInterval = 10 * time.Second

	// MinStaticKeysReloadInterval is the lower bound for the reload polling interval.
	MinStaticKeysReloadInterval = 1 * time.Second

	// StaticKeysReloadIntervalEnv names the environment variable to configure the polling interval.
	StaticKeysReloadIntervalEnv = "SIGNAL_AUTH_STATIC_KEYS_RELOAD_INTERVAL"
)

// Reload re-reads the projected static key Secrets from the configured directory for all configured
// static key specs and atomically updates the active key snapshot.
//
// Reloading rules:
//  1. Value file absent: Key is REVOKED. It is dropped from the active key set, logged at WARN
//     by name ("static key revoked"), and any registered revoke callback is notified.
//  2. Valid and different: Key is ROTATED. The new key value and expiry replace the previous one,
//     and is logged at INFO ("static key rotated").
//  3. Present but invalid (too short, whitespace, bad or past expiry, expiry > 90 days): Key is
//     REJECTED. The last good value is retained if one was previously active, logged at ERROR
//     ("static key update rejected; keeping last good value"). If never valid, it remains disabled.
//  4. Shared values: If two or more keys resolve to the exact same token digest, all of them are
//     DISABLED, logged at ERROR ("static key DISABLED: keys share one value; every caller needs its own key").
//
// Key names only are logged, never raw key values or digests.
// Adding a brand-new key name still requires updating SIGNAL_AUTH_STATIC_KEYS and restarting the service.
func (a *StaticBearerAuthenticator) Reload(now time.Time) {
	// Taken before the files are read: a swap that lands mid-read differs from this
	// fingerprint and is picked up on the next tick rather than lost.
	fp := a.fingerprint()
	currentMap := map[string]staticKey{}
	if ptr := a.keys.Load(); ptr != nil {
		for _, k := range *ptr {
			currentMap[k.name] = k
		}
	}

	var candidates []staticKey
	for _, spec := range a.specs {
		cfg := StaticBearerConfig{
			Name:        spec.Name,
			Subject:     spec.Subject,
			TenantID:    spec.Tenant,
			Permissions: spec.Permissions,
			ActorIDs:    spec.ActorIDs,
		}

		err := readKeySecret(a.dir, &cfg, now)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) || os.IsNotExist(err) {
				// Key file is absent -> REVOKED
				if _, wasActive := currentMap[spec.Name]; wasActive {
					slog.Warn("static key revoked", "key", spec.Name)
					if a.onRevoke != nil {
						a.onRevoke(spec.Subject)
					}
				}
				continue
			}

			// Present but invalid/malformed -> REJECTED, keep last good value if present
			if curr, exists := currentMap[spec.Name]; exists {
				slog.Error("static key update rejected; keeping last good value",
					"key", spec.Name, "reason", err.Error())
				candidates = append(candidates, curr)
			} else {
				slog.Error("static key disabled; secret is unusable",
					"key", spec.Name, "reason", err.Error())
			}
			continue
		}

		// Valid key secret
		digest := sha256.Sum256([]byte(cfg.Token))
		cand := staticKey{
			name:      cfg.Name,
			digest:    digest,
			subject:   cfg.Subject,
			binding:   PrincipalBinding{TenantID: cfg.TenantID, Permissions: cfg.Permissions, ActorIDs: cfg.ActorIDs},
			expiresAt: cfg.ExpiresAt,
		}

		if curr, exists := currentMap[spec.Name]; exists {
			if curr.digest != digest || !curr.expiresAt.Equal(cfg.ExpiresAt) {
				slog.Info("static key rotated", "key", spec.Name)
			}
		} else {
			slog.Info("static key enabled", "key", spec.Name)
		}

		if left := cfg.ExpiresAt.Sub(now); left < StaticKeyExpiryWarning {
			slog.Warn("static key expires soon; rotate it with scripts/sldc-ingest-bearer.sh --rotate",
				"key", spec.Name, "expires", cfg.ExpiresAt.UTC().Format(time.DateOnly))
		}

		candidates = append(candidates, cand)
	}

	// Two callers holding one value cannot be told apart, so neither is trusted.
	byDigest := map[[sha256.Size]byte][]string{}
	for _, k := range candidates {
		byDigest[k.digest] = append(byDigest[k.digest], k.name)
	}
	var kept []staticKey
	for _, k := range candidates {
		if names := byDigest[k.digest]; len(names) > 1 {
			slog.Error("static key DISABLED: keys share one value; every caller needs its own key",
				"key", k.name, "shared_with", names)
			continue
		}
		kept = append(kept, k)
	}

	if len(kept) == 0 && len(a.specs) > 0 {
		slog.Error("every configured static key is disabled; only JWT-SVIDs can authenticate", "dir", a.dir)
	}

	a.keys.Store(&kept)
	a.loadedFp.Store(&fp)
}

// WatchReload polls the key secret directory periodically and calls Reload whenever the directory
// state changes. It observes both the target of the kubelet's `..data` symlink and the size/mtime
// of each key file, ensuring atomic projected Secret volume swaps are reliably detected.
func (a *StaticBearerAuthenticator) WatchReload(ctx context.Context, interval time.Duration) {
	if interval < MinStaticKeysReloadInterval {
		interval = DefaultStaticKeysReloadInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case t := <-ticker.C:
			curFp := a.fingerprint()
			last := a.loadedFp.Load()
			if last == nil || !curFp.equal(*last) {
				a.Reload(t)
			}
		}
	}
}

type fileFingerprint struct {
	size    int64
	modTime time.Time
	exists  bool
}

type dirFingerprint struct {
	dataSymlink string
	files       map[string]fileFingerprint
}

func (d dirFingerprint) equal(o dirFingerprint) bool {
	if d.dataSymlink != o.dataSymlink {
		return false
	}
	if len(d.files) != len(o.files) {
		return false
	}
	for k, v := range d.files {
		ov, ok := o.files[k]
		if !ok || v != ov {
			return false
		}
	}
	return true
}

func (a *StaticBearerAuthenticator) fingerprint() dirFingerprint {
	fp := dirFingerprint{
		files: make(map[string]fileFingerprint, len(a.specs)*2),
	}
	if a.dir == "" {
		return fp
	}

	// Read ..data symlink target
	if link, err := os.Readlink(filepath.Join(a.dir, "..data")); err == nil {
		fp.dataSymlink = link
	}

	for _, spec := range a.specs {
		for _, name := range []string{spec.Name, spec.Name + StaticKeyExpirySuffix} {
			targetPath := filepath.Join(a.dir, name)
			info, err := os.Stat(targetPath)
			if err != nil {
				fp.files[name] = fileFingerprint{exists: false}
			} else {
				fp.files[name] = fileFingerprint{
					size:    info.Size(),
					modTime: info.ModTime(),
					exists:  true,
				}
			}
		}
	}
	return fp
}
