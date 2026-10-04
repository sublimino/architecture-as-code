// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package hubclient

import (
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// hub is a TLS server with a self-signed certificate, as the central
// cluster's cert-manager ClusterIssuer presents one.
func hub(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(srv.Close)
	caFile := filepath.Join(t.TempDir(), "ca.pem")
	block := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	if err := os.WriteFile(caFile, block, 0o600); err != nil {
		t.Fatal(err)
	}
	return srv, caFile
}

func get(t *testing.T, c Config, url string) error {
	t.Helper()
	client, err := c.Client(2 * time.Second)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func TestSystemRootsRejectTheSelfSignedHub(t *testing.T) {
	srv, _ := hub(t)
	c := Config{}
	if c.Mode() != ModeSystemRoots {
		t.Fatalf("mode = %s", c.Mode())
	}
	err := get(t, c, srv.URL)
	var unknown x509.UnknownAuthorityError
	if !errors.As(err, &unknown) {
		t.Fatalf("want x509 unknown authority, got %v", err)
	}
}

func TestCAFileAppendsTheHubIssuerToTheSystemRoots(t *testing.T) {
	srv, caFile := hub(t)
	c := Config{CAFile: caFile}
	if c.Mode() != ModeCAFile {
		t.Fatalf("mode = %s", c.Mode())
	}
	if err := get(t, c, srv.URL); err != nil {
		t.Fatalf("GET with CA file: %v", err)
	}
	tlsCfg, err := c.TLSConfig()
	if err != nil {
		t.Fatal(err)
	}
	if tlsCfg.InsecureSkipVerify || tlsCfg.RootCAs == nil {
		t.Fatalf("CA file mode must verify against a pool: %+v", tlsCfg)
	}
}

// The CA Secret is optional in the manifests: an absent file is system roots
// (named as such), not a refusal.
func TestCAFileAbsentFallsBackToSystemRoots(t *testing.T) {
	srv, _ := hub(t)
	c := Config{CAFile: filepath.Join(t.TempDir(), "absent.pem")}
	if !c.CAFileMissing() || c.Mode() != ModeSystemRoots {
		t.Fatalf("missing=%v mode=%s", c.CAFileMissing(), c.Mode())
	}
	err := get(t, c, srv.URL)
	var unknown x509.UnknownAuthorityError
	if !errors.As(err, &unknown) {
		t.Fatalf("system roots must apply (x509 unknown authority), got %v", err)
	}
	if (Config{}).CAFileMissing() {
		t.Fatal("no CA file configured is not a missing one")
	}
}

func TestCAFileWithoutACertificateIsAStartupError(t *testing.T) {
	empty := filepath.Join(t.TempDir(), "empty.pem")
	if err := os.WriteFile(empty, []byte("not pem\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := (Config{CAFile: empty}).Client(time.Second); err == nil {
		t.Fatal("CA file without a certificate must fail")
	}
}

func TestInsecureSkipVerifyNeedsDevMode(t *testing.T) {
	srv, _ := hub(t)
	c := Config{InsecureSkipVerify: true}
	if c.Mode() != ModeInsecureSkipVerify {
		t.Fatalf("mode = %s", c.Mode())
	}
	if _, err := c.Client(time.Second); !errors.Is(err, ErrInsecureWithoutDevMode) {
		t.Fatalf("want refusal without dev mode, got %v", err)
	}
	c.DevMode = true
	if err := get(t, c, srv.URL); err != nil {
		t.Fatalf("GET with skip-verify in dev mode: %v", err)
	}
}

func TestSkipVerifyOutranksACAFileInModeNaming(t *testing.T) {
	c := Config{CAFile: "/x", InsecureSkipVerify: true, DevMode: true}
	if c.Mode() != ModeInsecureSkipVerify {
		t.Fatalf("mode = %s", c.Mode())
	}
}

func TestFromEnvReadsTheThreeVariables(t *testing.T) {
	t.Setenv(EnvCAFile, " /etc/signalloom/ca.pem ")
	t.Setenv(EnvInsecureSkipVerify, "TRUE")
	t.Setenv(EnvDevMode, "1")
	c := FromEnv()
	if c.CAFile != "/etc/signalloom/ca.pem" || !c.InsecureSkipVerify || !c.DevMode {
		t.Fatalf("FromEnv = %+v", c)
	}
	t.Setenv(EnvInsecureSkipVerify, "false")
	t.Setenv(EnvDevMode, "")
	if c := FromEnv(); c.InsecureSkipVerify || c.DevMode {
		t.Fatalf("FromEnv = %+v", c)
	}
}
