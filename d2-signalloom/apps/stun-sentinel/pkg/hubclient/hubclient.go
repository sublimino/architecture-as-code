// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package hubclient builds the HTTP clients the warden uses to reach the hub
// (signal-ingest and fleet-manager through the gateway). It is the one place
// TLS trust is decided, so the observation sender and the fleet client cannot
// disagree about which certificate authority they believe.
//
// Three modes, from docs/EAP/remote-contract.md:
//
//   - system roots (neither variable set): the container's trust store;
//   - SIGNAL_TLS_CA_FILE: a PEM bundle (mounted from a Secret) appended to the
//     system roots, so a hub behind a private ClusterIssuer validates while
//     public endpoints still do;
//   - SIGNAL_TLS_INSECURE_SKIP_VERIFY=true: no verification at all. Only a
//     development setting, so it is refused unless SIGNAL_DEV_MODE=true.
//
// The module boundary puts this here rather than in the warden binary:
// signalloom-stun-sentinel depends on stun-sentinel via replace, never the
// reverse, and the correlator's sender lives in this module.
package hubclient

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// Environment variables read by FromEnv.
const (
	EnvCAFile             = "SIGNAL_TLS_CA_FILE"
	EnvInsecureSkipVerify = "SIGNAL_TLS_INSECURE_SKIP_VERIFY"
	EnvDevMode            = "SIGNAL_DEV_MODE"
)

// Mode names which trust applies. It is what the warden logs at start.
type Mode string

const (
	ModeSystemRoots        Mode = "system_roots"
	ModeCAFile             Mode = "ca_file"
	ModeInsecureSkipVerify Mode = "insecure_skip_verify"
)

// ErrInsecureWithoutDevMode is returned when verification is switched off
// outside development. The process must not start in that state.
var ErrInsecureWithoutDevMode = errors.New("hubclient: " + EnvInsecureSkipVerify + "=true requires " + EnvDevMode + "=true")

// Config is the resolved TLS policy.
type Config struct {
	CAFile             string
	InsecureSkipVerify bool
	DevMode            bool
}

// FromEnv reads the three variables. Values are not validated here; Build
// does that, so a refusal carries the reason.
func FromEnv() Config {
	return Config{
		CAFile:             strings.TrimSpace(os.Getenv(EnvCAFile)),
		InsecureSkipVerify: truthy(os.Getenv(EnvInsecureSkipVerify)),
		DevMode:            truthy(os.Getenv(EnvDevMode)),
	}
}

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "true", "1", "yes", "t", "on":
		return true
	}
	return false
}

// Mode reports which of the three applies to this configuration, before any
// validation. Skip-verify takes precedence over a CA file because it makes
// the CA file irrelevant.
func (c Config) Mode() Mode {
	switch {
	case c.InsecureSkipVerify:
		return ModeInsecureSkipVerify
	case c.CAFile != "":
		return ModeCAFile
	default:
		return ModeSystemRoots
	}
}

// TLSConfig builds the tls.Config for the mode, or refuses.
func (c Config) TLSConfig() (*tls.Config, error) {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	switch c.Mode() {
	case ModeInsecureSkipVerify:
		if !c.DevMode {
			return nil, ErrInsecureWithoutDevMode
		}
		cfg.InsecureSkipVerify = true //nolint:gosec // development only, gated on SIGNAL_DEV_MODE above
	case ModeCAFile:
		pem, err := os.ReadFile(c.CAFile)
		if err != nil {
			return nil, fmt.Errorf("hubclient: read %s: %w", EnvCAFile, err)
		}
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("hubclient: %s %q holds no PEM certificate", EnvCAFile, c.CAFile)
		}
		cfg.RootCAs = pool
	case ModeSystemRoots:
		// RootCAs nil: Go uses the system roots.
	}
	return cfg, nil
}

// Transport returns an http.Transport carrying the policy, with the idle-pool
// settings the observation sender has always used.
func (c Config) Transport() (*http.Transport, error) {
	tlsCfg, err := c.TLSConfig()
	if err != nil {
		return nil, err
	}
	return &http.Transport{
		TLSClientConfig:     tlsCfg,
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	}, nil
}

// Client returns an http.Client with the policy and the given timeout. Each
// caller gets its own client (its own timeout) over its own transport; the
// trust decision is shared because the Config is.
func (c Config) Client(timeout time.Duration) (*http.Client, error) {
	tr, err := c.Transport()
	if err != nil {
		return nil, err
	}
	return &http.Client{Timeout: timeout, Transport: tr}, nil
}
