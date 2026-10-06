package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Helper to construct a projected secret directory matching kubelet semantics:
// dir/..timestamp_dir
// dir/..data -> ..timestamp_dir
// dir/<name> -> ..data/<name>
// dir/<name>.expires -> ..data/<name>.expires
type projectedDir struct {
	rootDir string
	seq     int
}

func newProjectedDir(t *testing.T, initialFiles map[string]string) *projectedDir {
	t.Helper()
	root := t.TempDir()
	p := &projectedDir{rootDir: root}
	p.swap(t, initialFiles)
	return p
}

func (p *projectedDir) swap(t *testing.T, files map[string]string) {
	t.Helper()
	p.seq++
	tsDirName := fmt.Sprintf("..%d_%d", time.Now().UnixNano(), p.seq)
	tsDirPath := filepath.Join(p.rootDir, tsDirName)
	if err := os.MkdirAll(tsDirPath, 0o700); err != nil {
		t.Fatal(err)
	}

	for name, content := range files {
		filePath := filepath.Join(tsDirPath, name)
		if err := os.WriteFile(filePath, []byte(content), 0o400); err != nil {
			t.Fatal(err)
		}
	}

	// Create temp symlink to tsDirName
	tmpLink := filepath.Join(p.rootDir, fmt.Sprintf("..data_tmp_%d", p.seq))
	if err := os.Symlink(tsDirName, tmpLink); err != nil {
		t.Fatal(err)
	}

	// Rename temp link over ..data atomically
	finalLink := filepath.Join(p.rootDir, "..data")
	if err := os.Rename(tmpLink, finalLink); err != nil {
		t.Fatal(err)
	}

	// Ensure top-level symlinks exist: <name> -> ..data/<name>
	for name := range files {
		topFile := filepath.Join(p.rootDir, name)
		if _, err := os.Lstat(topFile); os.IsNotExist(err) {
			_ = os.Symlink(filepath.Join("..data", name), topFile)
		}
	}
}

func (p *projectedDir) removeKey(t *testing.T, name string, remainingFiles map[string]string) {
	t.Helper()
	p.swap(t, remainingFiles)
	// Remove top-level symlink if desired or let it dangle pointing through ..data (which is what kubelet does)
	_ = os.Remove(filepath.Join(p.rootDir, name))
	_ = os.Remove(filepath.Join(p.rootDir, name+StaticKeyExpirySuffix))
}

func TestKeyReloadDeletedKeyIs401WithoutRestart(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken
	tokenB := testGatewayToken
	expiry := testKeyExpiry()

	files := map[string]string{
		"stun-sentinel":                        tokenA,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
		"fe-gateway":                           tokenB,
		"fe-gateway" + StaticKeyExpirySuffix:   expiry,
	}
	proj := newProjectedDir(t, files)

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
		{Name: "fe-gateway", Subject: "static-key/fe-gateway", Tenant: "kusari", Permissions: []Permission{PermissionObservationRead}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	// Before reload: tokenA is valid
	p, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", tokenA))
	if err != nil || p.Subject != "static-key/stun-sentinel" {
		t.Fatalf("before reload: tokenA failed auth: %v, p=%+v", err, p)
	}

	// Delete stun-sentinel via projected swap
	proj.removeKey(t, "stun-sentinel", map[string]string{
		"fe-gateway":                         tokenB,
		"fe-gateway" + StaticKeyExpirySuffix: expiry,
	})

	// Perform reload
	authn.Reload(time.Now())

	// After reload: tokenA must fail auth (revoked)
	_, err = authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", tokenA))
	if err == nil {
		t.Fatal("after reload: revoked tokenA was accepted, want 401/error")
	}

	// fe-gateway must still be valid
	p2, err := authn.Authenticate(bearerRequest(http.MethodGet, "/api/v1/observations", tokenB))
	if err != nil || p2.Subject != "static-key/fe-gateway" {
		t.Fatalf("after reload: tokenB failed auth: %v, p=%+v", err, p2)
	}
}

func TestKeyReloadRotatedKeyOldIs401NewIs201(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	oldToken := testSentinelToken
	newToken := "NewRotatedTokenWithAtLeast32RandomBytesLong!"
	expiry := testKeyExpiry()

	files := map[string]string{
		"stun-sentinel":                        oldToken,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	}
	proj := newProjectedDir(t, files)

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	// Old token works initially
	p, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", oldToken))
	if err != nil || p.Subject != "static-key/stun-sentinel" {
		t.Fatalf("initial auth failed: %v", err)
	}

	// Rotate key
	proj.swap(t, map[string]string{
		"stun-sentinel":                        newToken,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})

	authn.Reload(time.Now())

	// Old token fails
	if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", oldToken)); err == nil {
		t.Fatal("old token accepted after rotation, want failure")
	}

	// New token succeeds
	pNew, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", newToken))
	if err != nil || pNew.Subject != "static-key/stun-sentinel" {
		t.Fatalf("new token failed auth after rotation: %v", err)
	}
}

func TestKeyReloadMalformedUpdateKeepsLastGoodAndIsLoud(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	goodToken := testSentinelToken
	expiry := testKeyExpiry()

	cases := []struct {
		name      string
		badFiles  map[string]string
		logReason string
	}{
		{
			name: "key under 32 bytes",
			badFiles: map[string]string{
				"stun-sentinel":                        "short-token",
				"stun-sentinel" + StaticKeyExpirySuffix: expiry,
			},
			logReason: "at least 32 bytes",
		},
		{
			name: "expiry more than 90 days out",
			badFiles: map[string]string{
				"stun-sentinel":                        goodToken,
				"stun-sentinel" + StaticKeyExpirySuffix: time.Now().UTC().Add(100 * 24 * time.Hour).Format(time.DateOnly),
			},
			logReason: "90 days away",
		},
		{
			name: "unparseable expires",
			badFiles: map[string]string{
				"stun-sentinel":                        goodToken,
				"stun-sentinel" + StaticKeyExpirySuffix: "not-a-date",
			},
			logReason: "not a YYYY-MM-DD date",
		},
		{
			name: "missing expires file",
			badFiles: map[string]string{
				"stun-sentinel": goodToken,
			},
			logReason: "no expiry beside the value",
		},
		{
			name: "whitespace inside value",
			badFiles: map[string]string{
				"stun-sentinel":                        goodToken[:15] + " " + goodToken[15:],
				"stun-sentinel" + StaticKeyExpirySuffix: expiry,
			},
			logReason: "whitespace",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			proj := newProjectedDir(t, map[string]string{
				"stun-sentinel":                        goodToken,
				"stun-sentinel" + StaticKeyExpirySuffix: expiry,
			})

			specs := []StaticKeySpec{
				{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
			}

			authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
			if err != nil {
				t.Fatalf("failed to create authenticator: %v", err)
			}

			// Validate good token works
			if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", goodToken)); err != nil {
				t.Fatalf("initial auth failed: %v", err)
			}

			logs := captureLogs(t)

			// Swap to bad files
			proj.swap(t, tc.badFiles)
			authn.Reload(time.Now())

			// Old good token must STILL work (keeping last good value!)
			p, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", goodToken))
			if err != nil || p.Subject != "static-key/stun-sentinel" {
				t.Fatalf("last good value rejected after malformed update: %v", err)
			}

			// Log verification
			logOutput := logs.String()
			if !strings.Contains(logOutput, `"level":"ERROR"`) {
				t.Fatalf("expected ERROR level log, got: %s", logOutput)
			}
			if !strings.Contains(logOutput, "static key update rejected; keeping last good value") {
				t.Fatalf("expected rejection message in log, got: %s", logOutput)
			}
			if !strings.Contains(logOutput, `"key":"stun-sentinel"`) {
				t.Fatalf("expected key name in log, got: %s", logOutput)
			}
			if strings.Contains(logOutput, goodToken) || strings.Contains(logOutput, "short-token") {
				t.Fatalf("log leaked key token: %s", logOutput)
			}
		})
	}
}

func TestKeyReloadIsRaceFree(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	expiry := testKeyExpiry()
	tokenA := testSentinelToken
	tokenB := "AnotherValidTokenOfSufficientLength12345678"

	proj := newProjectedDir(t, map[string]string{
		"stun-sentinel":                        tokenA,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	router, _ := newStaticBearerRouter(t, authn)

	var wg sync.WaitGroup
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// 100 concurrent workers sending requests
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
					token := tokenA
					if workerID%2 == 1 {
						token = tokenB
					}
					w := httptest.NewRecorder()
					router.ServeHTTP(w, observationRequest(token))
					if w.Code != http.StatusCreated && w.Code != http.StatusUnauthorized && w.Code != http.StatusTooManyRequests {
						t.Errorf("unexpected status code during race: %d", w.Code)
						return
					}
				}
			}
		}(i)
	}

	// 20 swaps concurrently
	for s := 0; s < 20; s++ {
		tok := tokenA
		if s%2 == 1 {
			tok = tokenB
		}
		proj.swap(t, map[string]string{
			"stun-sentinel":                        tok,
			"stun-sentinel" + StaticKeyExpirySuffix: expiry,
		})
		authn.Reload(time.Now())
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	wg.Wait()
}

func TestKeyReloadNeverLogsKeyValues(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	token1 := testSentinelToken
	token2 := "RotatedTokenSecretMaterial1234567890"
	badToken := "short"
	expiry := testKeyExpiry()

	proj := newProjectedDir(t, map[string]string{
		"stun-sentinel":                        token1,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	logs := captureLogs(t)
	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	// 1. Rotate
	proj.swap(t, map[string]string{
		"stun-sentinel":                        token2,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})
	authn.Reload(time.Now())

	// 2. Malformed
	proj.swap(t, map[string]string{
		"stun-sentinel":                        badToken,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})
	authn.Reload(time.Now())

	// 3. Revoke
	proj.removeKey(t, "stun-sentinel", map[string]string{})
	authn.Reload(time.Now())

	logOutput := logs.String()
	for _, secret := range []string{token1, token2, badToken} {
		if strings.Contains(logOutput, secret) {
			t.Fatalf("log contains secret %q: %s", secret, logOutput)
		}
	}
	if !strings.Contains(logOutput, `"key":"stun-sentinel"`) {
		t.Fatalf("log missing key name: %s", logOutput)
	}
}

func TestKeyReloadSharedValuesDisableBoth(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	sharedToken := testSentinelToken
	expiry := testKeyExpiry()

	proj := newProjectedDir(t, map[string]string{
		"key-a":                        sharedToken,
		"key-a" + StaticKeyExpirySuffix: expiry,
		"key-b":                        sharedToken,
		"key-b" + StaticKeyExpirySuffix: expiry,
	})

	specs := []StaticKeySpec{
		{Name: "key-a", Subject: "static-key/key-a", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
		{Name: "key-b", Subject: "static-key/key-b", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	// Both should be disabled because they share a value
	if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", sharedToken)); err == nil {
		t.Fatal("shared token was accepted, want failure")
	}
}

func TestKeyReloadNeverGoodKeyStaysDisabled(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	expiry := testKeyExpiry()

	proj := newProjectedDir(t, map[string]string{
		"key-a":                        "short",
		"key-a" + StaticKeyExpirySuffix: expiry,
	})

	specs := []StaticKeySpec{
		{Name: "key-a", Subject: "static-key/key-a", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	// Still bad
	proj.swap(t, map[string]string{
		"key-a":                        "also-too-short",
		"key-a" + StaticKeyExpirySuffix: expiry,
	})
	authn.Reload(time.Now())

	if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", "also-too-short")); err == nil {
		t.Fatal("defective key accepted, want failure")
	}
}

func TestKeyReloadWatchReloadDetectsSymlinkSwap(t *testing.T) {
	delegate, _, _ := testJWTDelegate(t)
	tokenA := testSentinelToken
	tokenB := testGatewayToken
	expiry := testKeyExpiry()

	proj := newProjectedDir(t, map[string]string{
		"stun-sentinel":                        tokenA,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})

	specs := []StaticKeySpec{
		{Name: "stun-sentinel", Subject: "static-key/stun-sentinel", Tenant: "kusari", Permissions: []Permission{PermissionObservationWrite}},
	}

	authn, err := NewStaticKeyAuthenticatorWithSpecs(specs, proj.rootDir, delegate)
	if err != nil {
		t.Fatalf("failed to create authenticator: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go authn.WatchReload(ctx, 1*time.Second)

	if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", tokenA)); err != nil {
		t.Fatalf("tokenA failed auth: %v", err)
	}

	proj.swap(t, map[string]string{
		"stun-sentinel":                        tokenB,
		"stun-sentinel" + StaticKeyExpirySuffix: expiry,
	})

	// 10 s, not 3: fsnotify delivery on a loaded host (parallel image builds during
	// the 2026-10-03 cold rebuild) missed 3 s in 3 of 5 runs; the reload itself is
	// sub-millisecond, the wait is for the kernel event.
	deadline := time.Now().Add(10 * time.Second)
	var swapped bool
	for time.Now().Before(deadline) {
		if _, err := authn.Authenticate(bearerRequest(http.MethodPost, "/api/v1/observations", tokenB)); err == nil {
			swapped = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if !swapped {
		t.Fatal("WatchReload did not detect atomic symlink swap within deadline")
	}
}

