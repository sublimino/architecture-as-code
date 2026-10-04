// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package main

import (
	"bytes"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/hubclient"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// tlsHub is a self-signed fleet-manager stand-in, as the central cluster's
// ClusterIssuer presents one, recording whether a stun reached it.
func tlsHub(t *testing.T) (*httptest.Server, string, *int) {
	t.Helper()
	hits := 0
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw}), 0o600); err != nil {
		t.Fatal(err)
	}
	return srv, ca, &hits
}

func stunPod() *corev1.Pod {
	return &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "fe-signalloom-agents", Name: "agent-x", UID: "uid-1"}}
}

func TestHubTLSModeIsLoggedOnceAndBothClientsCarryIt(t *testing.T) {
	_, ca, _ := tlsHub(t)
	hub, ev, err := newHubClients(hubclient.Config{CAFile: ca})
	if err != nil {
		t.Fatal(err)
	}
	if ev.Event != "hub_tls_mode" || ev.Details["mode"] != "ca_file" || ev.Details["ca_file"] != ca {
		t.Fatalf("startup event = %+v", ev)
	}
	for name, c := range map[string]*http.Client{"ingest": hub.ingest, "fleet": hub.fleet} {
		tr, ok := c.Transport.(*http.Transport)
		if !ok || tr.TLSClientConfig == nil || tr.TLSClientConfig.RootCAs == nil || tr.TLSClientConfig.InsecureSkipVerify {
			t.Fatalf("%s client does not carry the CA pool: %+v", name, c.Transport)
		}
	}
	if hub.ingest.Timeout == hub.fleet.Timeout {
		t.Fatalf("ingest and fleet keep their own timeouts: %s vs %s", hub.ingest.Timeout, hub.fleet.Timeout)
	}
}

func TestHubTLSRefusesSkipVerifyOutsideDevMode(t *testing.T) {
	_, _, err := newHubClients(hubclient.Config{InsecureSkipVerify: true})
	if !errors.Is(err, hubclient.ErrInsecureWithoutDevMode) {
		t.Fatalf("want ErrInsecureWithoutDevMode, got %v", err)
	}
	hub, ev, err := newHubClients(hubclient.Config{InsecureSkipVerify: true, DevMode: true})
	if err != nil {
		t.Fatal(err)
	}
	if ev.Details["mode"] != "insecure_skip_verify" || ev.Details["dev_mode"] != true {
		t.Fatalf("startup event = %+v", ev)
	}
	if tr := hub.fleet.Transport.(*http.Transport); !tr.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("dev-mode skip-verify client must skip verification")
	}
}

// The fleet stunner over the hub client: system roots refuse the self-signed
// hub (every attempt is a transport failure), the CA file reaches it.
func TestFleetStunnerUsesTheHubTLSPolicy(t *testing.T) {
	srv, ca, hits := tlsHub(t)
	var log bytes.Buffer
	SetAuditOutput(&log)
	t.Cleanup(func() { SetAuditOutput(os.Stdout) })

	sys, _, err := newHubClients(hubclient.Config{})
	if err != nil {
		t.Fatal(err)
	}
	st := newFleetStunner(srv.URL, testStunKey, sys.fleet)
	st.backoff = func(int) time.Duration { return 0 }
	st.stun(stunPod(), "r")
	if *hits != 0 {
		t.Fatalf("system roots must not reach a self-signed hub; hits=%d", *hits)
	}
	if !strings.Contains(log.String(), "unknown authority") {
		t.Fatalf("failure must name the x509 cause:\n%s", log.String())
	}

	withCA, _, err := newHubClients(hubclient.Config{CAFile: ca})
	if err != nil {
		t.Fatal(err)
	}
	log.Reset()
	st = newFleetStunner(srv.URL, testStunKey, withCA.fleet)
	st.stun(stunPod(), "r")
	if *hits != 1 {
		t.Fatalf("CA file must reach the hub; hits=%d", *hits)
	}
	var ev stunEvent
	if err := json.Unmarshal(bytes.TrimSpace(log.Bytes()), &ev); err != nil || ev.Event != "fleet_stun_delivered" {
		t.Fatalf("want fleet_stun_delivered, got %s (%v)", log.String(), err)
	}
}
